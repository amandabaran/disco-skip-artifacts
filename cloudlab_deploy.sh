#!/bin/bash

set -e #exit on error

#Redeploy to Cloudlab cluster machines after rebuilding

#Build disco-skip conan stack: chimera, swarm-kv, fusee, disco-skip-vec (+ deps)
./bin/disco-skip/build.py distclean buildclean clean
./bin/disco-skip/build.py all
wait

# dLSM: independent CMake build, kept upstream-unmodified
./bin/dlsm/build.sh clean
./bin/dlsm/build.sh build
wait

#Zip Binaries
./bin/zip-binaries.sh
wait

#Prepare Deployment with zip
./prepare-deployment.sh
wait

#Send to cluster machines in parallel
./send-deployment.sh
