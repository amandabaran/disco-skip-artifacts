#!/bin/bash
set -euo pipefail

MEM_NODE="${MEM_NODE:-w1}"
MEMC_IP="${MEMC_IP:-10.10.1.1}"
MEMC_PORT="${MEMC_PORT:-18888}"
PIDFILE="/tmp/memcached_dlsm.pid"

echo "Restarting memcached on $MEM_NODE ($MEMC_IP:$MEMC_PORT)..."

ssh "$MEM_NODE" "bash -s" <<EOF
set -euo pipefail

if [ -f $PIDFILE ]; then
    OLD_PID=\$(cat $PIDFILE 2>/dev/null || echo "")
    if [ -n "\$OLD_PID" ] && kill -0 "\$OLD_PID" 2>/dev/null; then
        kill "\$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f $PIDFILE
fi

fuser -k -9 $MEMC_PORT/tcp 2>/dev/null || true
sleep 1

setsid nohup memcached -l $MEMC_IP -p $MEMC_PORT -c 10000 -d \
    -P $PIDFILE </dev/null >/dev/null 2>&1

for i in 1 2 3 4 5; do
    if nc -z $MEMC_IP $MEMC_PORT 2>/dev/null; then break; fi
    sleep 1
done
if ! nc -z $MEMC_IP $MEMC_PORT 2>/dev/null; then
    echo "[ERROR] memcached failed to bind $MEMC_IP:$MEMC_PORT"
    exit 1
fi

printf 'set serverNum 0 0 1\r\n0\r\nquit\r\n' | nc $MEMC_IP $MEMC_PORT
printf 'set clientNum 0 0 1\r\n0\r\nquit\r\n' | nc $MEMC_IP $MEMC_PORT

echo "memcached PID: \$(cat $PIDFILE 2>/dev/null || echo unknown)"
echo "Listening on $MEMC_IP:$MEMC_PORT"
EOF

echo "Done."