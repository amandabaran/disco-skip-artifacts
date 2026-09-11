#!/bin/bash
export LD_LIBRARY_PATH="/bin/disco-skip/.deps/gcc/relwithdebinfo/lib:$LD_LIBRARY_PATH"

set -u

SCRIPT_DIR="$( realpath -sm "$( dirname "${BASH_SOURCE[0]}" )"/../scripts )"

# CLIENT_COUNTS=(1 8)
CLIENT_COUNTS=(1 2 3 4 5 6 7 8 10 12 14 16)
#  20 24 28 32 36 40 44 48 52 56 60 64)
# CLIENT_COUNTS=(40 44 48 52 56 60 64)
# CLIENT_COUNTS=(2 4 8 16 32 64)
SERVER_COUNTS=(3)
WORKLOADS=("c" "d")
SKEW=("uniform" "zipfian")


# Extra feature flags specifically for the CHIMERA system
# CHIMERA_EXTRA_FLAGS="--cache 1 --writeback 0 --maxrange 8"

EXP_FOLDER_BASE="YCSB"


for wl in "${WORKLOADS[@]}"; do
    for sk in "${SKEW[@]}"; do
        echo "====> Executing: Workload ${wl} | Skew: ${sk}"
        echo ""
        # Convert workload letters to matching uppercase names for output paths
        WL_UPPER=$(echo "$wl" | tr '[:lower:]' '[:upper:]')
        WORKLOAD_FILE="oops-workload${wl}-${sk}"

        for ns in "${SERVER_COUNTS[@]}"; do
            for nc in "${CLIENT_COUNTS[@]}"; do
                
                # 1. Run CHIMERA Configurations
                # EXP_FOLDER_CHIMERA="${EXP_FOLDER_BASE}/workload-${WL_UPPER}/CHIMERA/${ns}servers/${nc}client"
                
                # echo "====> Executing: CHIMERA | Workload ${WL_UPPER} | Servers: ${ns} | Clients: ${nc}"
                
                # "$SCRIPT_DIR"/run.sh disco-skip-exe "$EXP_FOLDER_CHIMERA" "$WORKLOAD_FILE" "$ns" "$nc" $CHIMERA_EXTRA_FLAGS

                
                # 2. Run SWARM-KV Configurations
                EXP_FOLDER_SWARM="${EXP_FOLDER_BASE}/workload-${WL_UPPER}/SWARM-KV/${ns}servers/${nc}client"
                
                echo "====> Executing: SWARM-KV | Workload ${WL_UPPER} | Servers: ${ns} | Clients: ${nc}"
                
                "$SCRIPT_DIR"/run.sh swarmkv "$EXP_FOLDER_SWARM" "$WORKLOAD_FILE" "$ns" "$nc"

                # 3. Run DM-ABD Configurations
                # EXP_FOLDER_DM_ABD="${EXP_FOLDER_BASE}/workload-${WL_UPPER}/DM-ABD/${nregs}reg/${ns}servers/${nc}client"

                # echo "====> Executing: DM-ABD | Workload ${WL_UPPER} | Servers: ${ns} | Clients: ${nc}"

                # "$SCRIPT_DIR"/run.sh swarmkv "$EXP_FOLDER_DM_ABD" "$WORKLOAD_FILE" "$ns" "$nc" -d=true -g=false --in_place=false

                # 4. Run FUSEE Configurations
                EXP_FOLDER_FUSEE="${EXP_FOLDER_BASE}/workload-${WL_UPPER}/FUSEE/${ns}servers/${nc}client"

                echo "====> Executing: FUSEE | Workload ${WL_UPPER} | Servers: ${ns} | Clients: ${nc}"

                "$SCRIPT_DIR"/run.sh fusee "$EXP_FOLDER_FUSEE" "$WORKLOAD_FILE" "$ns" "$nc"
            done
        done
    done
done
