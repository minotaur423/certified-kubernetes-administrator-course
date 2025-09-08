#!/usr/bin/env bash
# teardown.sh - remove multipass VMs for the demo cluster

set -euo pipefail

RED="\033[1;31m"
GREEN="\033[1;32m"
NC="\033[0m"

# Default node names
NODES=("controlplane" "node01" "node02")

echo -e "${RED}⚠️  This will permanently delete the cluster VMs:${NC}"
printf '  - %s\n' "${NODES[@]}"
echo

read -p "Proceed? (y/n) " ans
[ "$ans" != "y" ] && { echo "Aborted."; exit 0; }

for node in "${NODES[@]}"; do
    if multipass list --format json | jq -r '.list[].name' | grep -q "$node"; then
        echo -e "${RED}Deleting $node...${NC}"
        multipass delete "$node"
    else
        echo -e "${GREEN}$node not found, skipping.${NC}"
    fi
done

echo -e "${GREEN}Purging deleted instances...${NC}"
multipass purge

echo -e "${GREEN}Cluster teardown complete!${NC}"
