# Use the absolute path
ROOT_DIR="$( realpath -sm  "$( dirname "${BASH_SOURCE[0]}" )"/.. )"
BIN_DIR="${ROOT_DIR}"/bin
LOG_DIR="${ROOT_DIR}"/logs
WORKLOAD_DIR="${ROOT_DIR}"/workloads
YCSB_BIN="${ROOT_DIR}"/YCSB/bin/ycsb.sh

# Where the deployed shared libraries live, relative to this checkout.
#
# Set here rather than in the experiment scripts because scripts/invoker.sh
# sources this file *inside the tmux window on the worker*, which is the only
# place it can take effect. The per-experiment `export LD_LIBRARY_PATH=...`
# lines cannot work: they run on the gateway, and remote-invoker.sh forwards
# only DORY_REGISTRY_IP over ssh. (They also point at "/bin/chimera/..." with a
# leading slash, from fix-build.sh interpolating an unset BASE_DIR.)
#
# prepare-deployment.sh ships bin/disco-skip/.deps/, so this is where the libs
# land on every worker. Build type is fixed to relwithdebinfo to match what
# build.py produces.
DEPS_LIB_DIR="${ROOT_DIR}/bin/disco-skip/.deps/gcc/relwithdebinfo/lib"
export LD_LIBRARY_PATH="${DEPS_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

TMUX_SESSION=oops

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
