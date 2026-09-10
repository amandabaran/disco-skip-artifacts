# Use the absolute path
ROOT_DIR="$( realpath -sm  "$( dirname "${BASH_SOURCE[0]}" )"/.. )"
BIN_DIR="${ROOT_DIR}"/bin
LOG_DIR="${ROOT_DIR}"/logs
WORKLOAD_DIR="${ROOT_DIR}"/workloads
YCSB_BIN="${ROOT_DIR}"/YCSB/bin/ycsb.sh

# No LD_LIBRARY_PATH is set on purpose. conanfile.py builds with shared=False,
# so the binaries link the dory stack statically and `ldd` reports nothing
# missing -- there is no .deps/gcc/*/lib directory to point at. The
# `export LD_LIBRARY_PATH=/bin/chimera/...` lines at the top of experiments/*.sh
# are dead weight twice over: that path has a spurious leading slash (from
# fix-build.sh interpolating an unset BASE_DIR), and they run on the gateway
# while remote-invoker.sh forwards only DORY_REGISTRY_IP over ssh.

TMUX_SESSION=oops

# The memcached registry gets its own tmux session, separate from the one the
# experiment windows live in. memc.sh used to kill and recreate $TMUX_SESSION,
# which on the registry machine destroyed the session setup-all-tmux.sh had just
# made -- and because killing the last session kills the tmux server, that also
# discarded the global `remain-on-exit on`. On that one machine a window then
# vanished the instant its command finished, so a crashed run left no pane to
# read. Splitting the sessions removes the interaction entirely.
REGISTRY_SESSION=${TMUX_SESSION}-registry

FIRST_MACHINE=1
FIRST_SERVER=$FIRST_MACHINE
SERVER_MACHINES=4
FIRST_CLIENT=$(($FIRST_MACHINE + $SERVER_MACHINES))
CLIENT_MACHINES=8
MACHINE_COUNT=$(($SERVER_MACHINES + $CLIENT_MACHINES))
REGISTRY_MACHINE=machine1

# Set ssh names of the machines
#Server Machines
machine1=w1
machine2=w2
machine3=w3
machine4=w4
# Client Machines
machine5=w5
machine6=w6
machine7=w7
machine8=w8
machine9=w9
machine10=w10
machine11=w11
machine12=w12

# Set fqdn names of the machines (use `hostname -f`)
machine1hostname=swarm-${machine1}
machine2hostname=swarm-${machine2}
machine3hostname=swarm-${machine3}
machine4hostname=swarm-${machine4}
machine5hostname=swarm-${machine5}
machine6hostname=swarm-${machine6}
machine7hostname=swarm-${machine7}
machine8hostname=swarm-${machine8}
machine9hostname=swarm-${machine9}
machine10hostname=swarm-${machine10}
machine11hostname=swarm-${machine11}
machine12hostname=swarm-${machine12}


# Memcached does not run with root access
#PONY_HAVE_SUDO_ACCESS=false
#PONY_SUDO_ASKS_PASS=false
#PONY_SUDO_PASS="MyPass"

# Do not edit below this line
machine2ssh () {
    local m=$1
    echo "${!m}"
}

machine2hostname () {
    local m=$1
    local m_hn=${m}hostname
    echo "${!m_hn}"
}

export DORY_REGISTRY_IP=$(machine2hostname $REGISTRY_MACHINE)
