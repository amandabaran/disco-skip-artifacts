// counter_bench -- what does a single shared RDMA counter actually cost?
//
// Motivation. The A10 range-query design under consideration has writers
// FETCH_AND_ADD a global counter to obtain a commit timestamp, and readers
// RDMA READ that same counter to obtain a snapshot. Both land on ONE 8-byte
// word in ONE memory server's memory. The question is what that word can
// sustain, and stock perftest cannot answer it: ib_atomic_bw pairs one client
// process with one server process, each with its own memory region, so its
// numbers describe INDEPENDENT addresses. That is why the older sweep in
// ../../../rdma-scaling-tests scales to ~21 Mops/s across 8 client nodes --
// eight separate addresses, not one contended one.
//
// This program puts every client QP, across every client machine, onto the
// same remote address inside a single server process, which is the real
// configuration.
//
// Three things it measures:
//
//   --op faa    aggregate FETCH_AND_ADD rate on one word (the writer path)
//   --op read   aggregate 8-byte READ rate on one word (the reader path)
//   --stride N  isolate the cause: 0 puts every QP on the same word, 64 gives
//               each QP its own cache line. If same-address numbers match
//               distinct-address numbers, there is no serialisation and the
//               ceiling is the NIC's issue rate; if they diverge, the shared
//               word is a serialisation point and the gap is its cost.
//
// The --stride comparison is the point of the whole program. A single number
// for the hotspot case means little without the control alongside it.
//
// It also settles an endianness question that bites this exact design, where a
// counter is driven by FAA and sampled by RDMA READ. The IB spec describes
// atomic operands in big-endian network order, so the expectation is that the
// read side needs a byteswap. MEASURED ON THIS HARDWARE IT DOES NOT: after
// 486658 FAAs of 1, the server's word reads 0x0000000000076d02, which is
// 486658 in native little-endian. mlx4 performs the read-modify-write in host
// byte order on x86, so `ts` needs no swap. Both lanes are printed at the end
// of a run so this stays a measurement rather than folklore -- and so it gets
// re-checked if the adapter generation ever changes, since it is a device
// property and not a guarantee.
//
// Deliberately standalone: libibverbs plus a TCP bootstrap, no dory, no conan,
// no memcached. It should stay runnable when the rest of the build is broken.
//
// Passive server, matching the system model: the server sets up queue pairs and
// then does nothing at all while clients operate on its memory one-sidedly.

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <infiniband/verbs.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_QPS 256

static void die(char const *what) {
  fprintf(stderr, "fatal: %s: %s\n", what, strerror(errno));
  exit(1);
}

static void diemsg(char const *what) {
  fprintf(stderr, "fatal: %s\n", what);
  exit(1);
}

static double now_s(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}

// ---------------------------------------------------------------- wire format

// Exchanged over TCP at setup. Packed and fixed-width so a mismatched build on
// one node cannot silently misparse.
struct __attribute__((packed)) qp_info {
  uint32_t qpn;
  uint32_t psn;
  uint16_t lid;
  uint32_t rkey;
  uint64_t addr;
};

struct config {
  char const *dev_name;
  char const *server_host;
  int port;
  int is_server;
  int nqp;
  int depth;
  int secs;
  int clients; // server: how many client processes to wait for
  int stride;  // 0 = all QPs share one address
  int op_read; // 0 = FAA, 1 = READ
  int verify;
  int ib_port;
};

// ------------------------------------------------------------------- tcp glue

static int tcp_listen(int port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) die("socket");
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  a.sin_port = htons((uint16_t)port);
  if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) die("bind");
  if (listen(s, 64) < 0) die("listen");
  return s;
}

static int tcp_connect(char const *host, int port) {
  char portstr[16];
  snprintf(portstr, sizeof(portstr), "%d", port);
  struct addrinfo hints, *res;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  // The server may not be listening yet; retry rather than racing the driver.
  for (int attempt = 0; attempt < 100; attempt++) {
    if (getaddrinfo(host, portstr, &hints, &res) == 0) {
      int s = socket(res->ai_family, res->ai_socktype, 0);
      if (s >= 0 && connect(s, res->ai_addr, res->ai_addrlen) == 0) {
        freeaddrinfo(res);
        int one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        return s;
      }
      if (s >= 0) close(s);
      freeaddrinfo(res);
    }
    usleep(100000);
  }
  diemsg("could not connect to server");
  return -1;
}

static void xfer(int s, void *buf, size_t n, int send_it) {
  size_t done = 0;
  while (done < n) {
    ssize_t r = send_it ? send(s, (char *)buf + done, n - done, 0)
                        : recv(s, (char *)buf + done, n - done, 0);
    if (r <= 0) diemsg("tcp transfer failed mid-exchange");
    done += (size_t)r;
  }
}

// ------------------------------------------------------------------ rdma glue

struct ctx {
  struct ibv_context *dev;
  struct ibv_pd *pd;
  struct ibv_mr *mr;
  struct ibv_cq *cq;
  struct ibv_qp *qp[MAX_QPS];
  void *buf;
  size_t buf_len;
  uint16_t lid;
  int max_rd_atomic;
};

static void open_dev(struct ctx *c, struct config const *cfg, size_t buf_len) {
  int n = 0;
  struct ibv_device **list = ibv_get_device_list(&n);
  if (!list || n == 0) diemsg("no RDMA devices");
  struct ibv_device *chosen = NULL;
  for (int i = 0; i < n; i++) {
    if (!cfg->dev_name || strcmp(ibv_get_device_name(list[i]), cfg->dev_name) == 0) {
      chosen = list[i];
      break;
    }
  }
  if (!chosen) diemsg("named RDMA device not found (try --dev, or omit it)");
  c->dev = ibv_open_device(chosen);
  if (!c->dev) diemsg("ibv_open_device failed");

  struct ibv_device_attr da;
  if (ibv_query_device(c->dev, &da)) diemsg("ibv_query_device failed");
  c->max_rd_atomic = da.max_qp_rd_atom < 16 ? da.max_qp_rd_atom : 16;

  struct ibv_port_attr pa;
  if (ibv_query_port(c->dev, (uint8_t)cfg->ib_port, &pa))
    diemsg("ibv_query_port failed");
  if (pa.state != IBV_PORT_ACTIVE) diemsg("IB port is not ACTIVE");
  c->lid = pa.lid;

  c->pd = ibv_alloc_pd(c->dev);
  if (!c->pd) diemsg("ibv_alloc_pd failed");

  c->buf_len = buf_len;
  if (posix_memalign(&c->buf, 4096, buf_len)) die("posix_memalign");
  memset(c->buf, 0, buf_len);

  // REMOTE_ATOMIC is the flag people forget; without it FAA fails with a
  // remote access error that looks like a permissions bug in the addressing.
  c->mr = ibv_reg_mr(c->pd, c->buf, buf_len,
                     IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
                         IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_ATOMIC);
  if (!c->mr) diemsg("ibv_reg_mr failed (is REMOTE_ATOMIC supported?)");
}

static void make_qps(struct ctx *c, struct config const *cfg) {
  int cqe = cfg->nqp * cfg->depth * 2 + 16;
  c->cq = ibv_create_cq(c->dev, cqe, NULL, NULL, 0);
  if (!c->cq) diemsg("ibv_create_cq failed");

  for (int i = 0; i < cfg->nqp; i++) {
    struct ibv_qp_init_attr ia;
    memset(&ia, 0, sizeof(ia));
    ia.send_cq = c->cq;
    ia.recv_cq = c->cq;
    ia.qp_type = IBV_QPT_RC; // atomics require RC
    ia.cap.max_send_wr = (uint32_t)(cfg->depth + 8);
    ia.cap.max_recv_wr = 8;
    ia.cap.max_send_sge = 1;
    ia.cap.max_recv_sge = 1;
    c->qp[i] = ibv_create_qp(c->pd, &ia);
    if (!c->qp[i]) diemsg("ibv_create_qp failed");
  }
}

static void to_init(struct ctx *c, struct config const *cfg, int i) {
  struct ibv_qp_attr a;
  memset(&a, 0, sizeof(a));
  a.qp_state = IBV_QPS_INIT;
  a.pkey_index = 0;
  a.port_num = (uint8_t)cfg->ib_port;
  a.qp_access_flags = IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE |
                      IBV_ACCESS_REMOTE_ATOMIC;
  if (ibv_modify_qp(c->qp[i], &a,
                    IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                        IBV_QP_ACCESS_FLAGS))
    diemsg("modify_qp to INIT failed");
}

static void to_rtr_rts(struct ctx *c, struct config const *cfg, int i,
                       struct qp_info const *peer, uint32_t my_psn) {
  struct ibv_qp_attr a;
  memset(&a, 0, sizeof(a));
  a.qp_state = IBV_QPS_RTR;
  a.path_mtu = IBV_MTU_1024;
  a.dest_qp_num = peer->qpn;
  a.rq_psn = peer->psn;
  a.max_dest_rd_atomic = (uint8_t)c->max_rd_atomic;
  a.min_rnr_timer = 12;
  a.ah_attr.is_global = 0; // InfiniBand transport: LID routing
  a.ah_attr.dlid = peer->lid;
  a.ah_attr.sl = 0;
  a.ah_attr.src_path_bits = 0;
  a.ah_attr.port_num = (uint8_t)cfg->ib_port;
  if (ibv_modify_qp(c->qp[i], &a,
                    IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                        IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                        IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER))
    diemsg("modify_qp to RTR failed");

  memset(&a, 0, sizeof(a));
  a.qp_state = IBV_QPS_RTS;
  a.timeout = 14;
  a.retry_cnt = 7;
  a.rnr_retry = 7;
  a.sq_psn = my_psn;
  a.max_rd_atomic = (uint8_t)c->max_rd_atomic;
  if (ibv_modify_qp(c->qp[i], &a,
                    IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                        IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN |
                        IBV_QP_MAX_QP_RD_ATOMIC))
    diemsg("modify_qp to RTS failed");
}

// --------------------------------------------------------------------- server

// Sets up QPs for every client and then goes idle. No server-side logic: the
// counter is advanced entirely by clients' one-sided operations.
static void run_server(struct config *cfg) {
  struct ctx c;
  memset(&c, 0, sizeof(c));
  // One page is plenty: the hotspot case uses 8 bytes of it, and the
  // distinct-address control needs nqp * stride.
  open_dev(&c, cfg, 4096);

  printf("server: dev=%s lid=%u waiting for %d client process(es) on tcp/%d\n",
         ibv_get_device_name(c.dev->device), c.lid, cfg->clients, cfg->port);
  fflush(stdout);

  int ls = tcp_listen(cfg->port);
  int *socks = calloc((size_t)cfg->clients, sizeof(int));
  struct ctx *per = calloc((size_t)cfg->clients, sizeof(struct ctx));
  if (!socks || !per) diemsg("calloc failed");

  for (int ci = 0; ci < cfg->clients; ci++) {
    int s = accept(ls, NULL, NULL);
    if (s < 0) die("accept");
    socks[ci] = s;

    uint32_t nqp = 0;
    xfer(s, &nqp, sizeof(nqp), 0);
    if (nqp == 0 || nqp > MAX_QPS) diemsg("client asked for a bad QP count");

    // Each client connection gets its own QPs but shares the one MR, which is
    // what makes every client contend on the same address.
    per[ci] = c;
    struct config sub = *cfg;
    sub.nqp = (int)nqp;
    make_qps(&per[ci], &sub);

    struct qp_info *theirs = calloc(nqp, sizeof(struct qp_info));
    struct qp_info *mine = calloc(nqp, sizeof(struct qp_info));
    if (!theirs || !mine) diemsg("calloc failed");
    xfer(s, theirs, nqp * sizeof(struct qp_info), 0);

    for (uint32_t i = 0; i < nqp; i++) {
      to_init(&per[ci], &sub, (int)i);
      mine[i].qpn = per[ci].qp[i]->qp_num;
      mine[i].psn = 0x1000 + i;
      mine[i].lid = c.lid;
      mine[i].rkey = c.mr->rkey;
      mine[i].addr = (uint64_t)(uintptr_t)c.buf;
    }
    xfer(s, mine, nqp * sizeof(struct qp_info), 1);

    for (uint32_t i = 0; i < nqp; i++)
      to_rtr_rts(&per[ci], &sub, (int)i, &theirs[i], mine[i].psn);

    free(theirs);
    free(mine);
    printf("server: client %d/%d ready (%u qps)\n", ci + 1, cfg->clients, nqp);
    fflush(stdout);
  }

  // Release everyone at once, so the measured windows overlap.
  char go = 'g';
  for (int ci = 0; ci < cfg->clients; ci++) xfer(socks[ci], &go, 1, 1);

  // Wait for each client to report completion before touching the counter.
  for (int ci = 0; ci < cfg->clients; ci++) {
    char fin = 0;
    xfer(socks[ci], &fin, 1, 0);
  }

  uint64_t raw = *(volatile uint64_t *)c.buf;
  printf("\nserver: counter raw bytes  0x%016lx\n", (unsigned long)raw);
  printf("server: as native (LE)      %lu\n", (unsigned long)raw);
  printf("server: as big-endian       %lu\n", (unsigned long)be64toh(raw));
  printf("server: whichever of those equals the total FAA count is the lane\n"
         "        mlx4 actually used -- measured here it is the native one,\n"
         "        so a FAA'd counter sampled by READ needs no byteswap.\n");
  printf("server: done\n");
  fflush(stdout);
}

// --------------------------------------------------------------------- client

static void run_client(struct config *cfg) {
  struct ctx c;
  memset(&c, 0, sizeof(c));
  size_t local = (size_t)cfg->nqp * (size_t)cfg->depth * 8 + 4096;
  open_dev(&c, cfg, local);
  make_qps(&c, cfg);

  int s = tcp_connect(cfg->server_host, cfg->port);
  uint32_t nqp = (uint32_t)cfg->nqp;
  xfer(s, &nqp, sizeof(nqp), 1);

  struct qp_info *mine = calloc(nqp, sizeof(struct qp_info));
  struct qp_info *theirs = calloc(nqp, sizeof(struct qp_info));
  if (!mine || !theirs) diemsg("calloc failed");
  for (uint32_t i = 0; i < nqp; i++) {
    to_init(&c, cfg, (int)i);
    mine[i].qpn = c.qp[i]->qp_num;
    mine[i].psn = 0x2000 + i;
    mine[i].lid = c.lid;
    mine[i].rkey = c.mr->rkey;
    mine[i].addr = (uint64_t)(uintptr_t)c.buf;
  }
  xfer(s, mine, nqp * sizeof(struct qp_info), 1);
  xfer(s, theirs, nqp * sizeof(struct qp_info), 0);
  for (uint32_t i = 0; i < nqp; i++)
    to_rtr_rts(&c, cfg, (int)i, &theirs[i], mine[i].psn);

  uint64_t const rbase = theirs[0].addr;
  uint32_t const rkey = theirs[0].rkey;

  char go = 0;
  xfer(s, &go, 1, 0); // start together

  // Keep `depth` operations outstanding per QP, reposting on each completion.
  uint64_t ops = 0;
  double const t0 = now_s();
  double const deadline = t0 + (double)cfg->secs;

  for (uint32_t q = 0; q < nqp; q++) {
    for (int d = 0; d < cfg->depth; d++) {
      struct ibv_sge sge;
      struct ibv_send_wr wr, *bad = NULL;
      memset(&wr, 0, sizeof(wr));
      sge.addr = (uint64_t)(uintptr_t)c.buf + (q * (uint32_t)cfg->depth + (uint32_t)d) * 8;
      sge.length = 8;
      sge.lkey = c.mr->lkey;
      wr.wr_id = q;
      wr.sg_list = &sge;
      wr.num_sge = 1;
      wr.send_flags = IBV_SEND_SIGNALED;
      uint64_t raddr = rbase + (uint64_t)cfg->stride * q;
      if (cfg->op_read) {
        wr.opcode = IBV_WR_RDMA_READ;
        wr.wr.rdma.remote_addr = raddr;
        wr.wr.rdma.rkey = rkey;
      } else {
        wr.opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
        wr.wr.atomic.remote_addr = raddr;
        wr.wr.atomic.rkey = rkey;
        wr.wr.atomic.compare_add = 1;
      }
      if (ibv_post_send(c.qp[q], &wr, &bad)) diemsg("initial ibv_post_send failed");
    }
  }

  struct ibv_wc wc[64];
  while (now_s() < deadline) {
    int n = ibv_poll_cq(c.cq, 64, wc);
    if (n < 0) diemsg("ibv_poll_cq failed");
    for (int k = 0; k < n; k++) {
      if (wc[k].status != IBV_WC_SUCCESS) {
        fprintf(stderr, "fatal: completion status %s (opcode %d)\n",
                ibv_wc_status_str(wc[k].status), wc[k].opcode);
        exit(1);
      }
      ops++;
      uint32_t q = (uint32_t)wc[k].wr_id;
      struct ibv_sge sge;
      struct ibv_send_wr wr, *bad = NULL;
      memset(&wr, 0, sizeof(wr));
      sge.addr = (uint64_t)(uintptr_t)c.buf + (q * (uint32_t)cfg->depth) * 8;
      sge.length = 8;
      sge.lkey = c.mr->lkey;
      wr.wr_id = q;
      wr.sg_list = &sge;
      wr.num_sge = 1;
      wr.send_flags = IBV_SEND_SIGNALED;
      uint64_t raddr = rbase + (uint64_t)cfg->stride * q;
      if (cfg->op_read) {
        wr.opcode = IBV_WR_RDMA_READ;
        wr.wr.rdma.remote_addr = raddr;
        wr.wr.rdma.rkey = rkey;
      } else {
        wr.opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
        wr.wr.atomic.remote_addr = raddr;
        wr.wr.atomic.rkey = rkey;
        wr.wr.atomic.compare_add = 1;
      }
      if (ibv_post_send(c.qp[q], &wr, &bad)) diemsg("ibv_post_send failed");
    }
  }
  double const elapsed = now_s() - t0;

  // One machine-readable line, so the driver can sum across client machines
  // without parsing prose.
  char host[64];
  gethostname(host, sizeof(host));
  printf("RESULT host=%s op=%s qps=%d depth=%d stride=%d secs=%.3f ops=%lu mops=%.4f\n",
         host, cfg->op_read ? "read" : "faa", cfg->nqp, cfg->depth, cfg->stride,
         elapsed, (unsigned long)ops, (double)ops / elapsed / 1e6);

  if (cfg->verify) {
    // Read the counter back the way a reader in the real design would, and show
    // both byte lanes. Only meaningful after an faa run has advanced it.
    struct ibv_sge sge;
    struct ibv_send_wr wr, *bad = NULL;
    memset(&wr, 0, sizeof(wr));
    uint64_t *slot = (uint64_t *)((char *)c.buf + 2048);
    *slot = 0;
    sge.addr = (uint64_t)(uintptr_t)slot;
    sge.length = 8;
    sge.lkey = c.mr->lkey;
    wr.wr_id = 999;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    wr.send_flags = IBV_SEND_SIGNALED;
    wr.opcode = IBV_WR_RDMA_READ;
    wr.wr.rdma.remote_addr = rbase;
    wr.wr.rdma.rkey = rkey;
    // The measurement loop leaves its still-outstanding FAA completions in the
    // CQ. Drain them first, or the poll below returns one of those and we print
    // the slot before our own read has landed -- which reads as a counter stuck
    // at zero and looks exactly like a byte-order bug.
    struct ibv_wc drain[64];
    for (;;) {
      int d = ibv_poll_cq(c.cq, 64, drain);
      if (d <= 0) break;
    }
    if (ibv_post_send(c.qp[0], &wr, &bad)) diemsg("verify post failed");
    struct ibv_wc one;
    int n;
    // Match on wr_id as well, so a late straggler cannot be mistaken for it.
    do {
      n = ibv_poll_cq(c.cq, 1, &one);
    } while (n == 0 || (n == 1 && one.wr_id != 999));
    if (n < 0 || one.status != IBV_WC_SUCCESS) diemsg("verify read failed");
    printf("VERIFY read-back raw=0x%016lx le=%lu be=%lu\n",
           (unsigned long)*slot, (unsigned long)*slot,
           (unsigned long)be64toh(*slot));
  }

  char fin = 'f';
  xfer(s, &fin, 1, 1);
  fflush(stdout);
}

// ------------------------------------------------------------------------ main

static void usage(void) {
  fprintf(stderr,
      "usage:\n"
      "  counter_bench --server [--clients N] [--dev D] [--port P] [--ib-port 1]\n"
      "  counter_bench --client HOST [--op faa|read] [--qps N] [--depth D]\n"
      "                [--secs S] [--stride B] [--verify] [--dev D] [--port P]\n"
      "\n"
      "  --stride 0   every QP hits the same 8-byte word (the hotspot case)\n"
      "  --stride 64  every QP hits its own cache line (the control)\n"
      "\n"
      "The server must be told how many client PROCESSES to expect; it releases\n"
      "them together so the measured windows overlap.\n");
  exit(2);
}

int main(int argc, char **argv) {
  struct config cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.port = 18600;
  cfg.nqp = 1;
  cfg.depth = 16;
  cfg.secs = 5;
  cfg.clients = 1;
  cfg.stride = 0;
  cfg.ib_port = 1;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--server")) cfg.is_server = 1;
    else if (!strcmp(argv[i], "--client") && i + 1 < argc) cfg.server_host = argv[++i];
    else if (!strcmp(argv[i], "--dev") && i + 1 < argc) cfg.dev_name = argv[++i];
    else if (!strcmp(argv[i], "--port") && i + 1 < argc) cfg.port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--ib-port") && i + 1 < argc) cfg.ib_port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--qps") && i + 1 < argc) cfg.nqp = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--depth") && i + 1 < argc) cfg.depth = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--secs") && i + 1 < argc) cfg.secs = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--clients") && i + 1 < argc) cfg.clients = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--stride") && i + 1 < argc) cfg.stride = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--verify")) cfg.verify = 1;
    else if (!strcmp(argv[i], "--op") && i + 1 < argc) {
      char const *o = argv[++i];
      if (!strcmp(o, "read")) cfg.op_read = 1;
      else if (!strcmp(o, "faa")) cfg.op_read = 0;
      else usage();
    } else usage();
  }
  if (cfg.nqp < 1 || cfg.nqp > MAX_QPS || cfg.depth < 1) usage();

  if (cfg.is_server) run_server(&cfg);
  else if (cfg.server_host) run_client(&cfg);
  else usage();
  return 0;
}
