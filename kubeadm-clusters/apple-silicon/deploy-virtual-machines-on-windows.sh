#!/usr/bin/env bash
# WSL-compatible multipass cluster setup script

ARG=$1
set -euo pipefail

BUILD_MODE="BRIDGE"   # Default mode

# Colors (work in most WSL terminals)
RED="\033[1;31m"
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
NC="\033[0m"

# Check dependencies
if ! command -v jq >/dev/null; then
    echo -e "${RED}'jq' not found. Please install it${NC}"
    exit 1
fi

if ! command -v multipass >/dev/null; then
    echo -e "${RED}'multipass' not found. Please install it${NC}"
    exit 1
fi

NUM_WORKER_NODES=2
MEM_GB=$(( $(free -m | awk '/^Mem:/{print $2}') / 1024 ))
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )/scripts"
VM_MEM_GB=8G

# Memory checks
if [ $MEM_GB -lt 8 ]; then
    echo -e "${RED}System RAM is ${MEM_GB}GB. This is insufficient.${NC}"
    exit 1
elif [ $MEM_GB -lt 16 ]; then
    echo -e "${YELLOW}System RAM is ${MEM_GB}GB. Deploying only one worker.${NC}"
    NUM_WORKER_NODES=1
    VM_MEM_GB=2G
    sleep 1
fi

workers=$(for n in $(seq 1 $NUM_WORKER_NODES); do echo -n "node0$n "; done)

# Detect default interface
interface=""
bridge_arg="--bridged"
for iface in $(multipass networks --format json | jq -r '.list[] | .name'); do
    if netstat -rn | grep "^0.0.0.0.*${iface}" >/dev/null 2>&1; then
        interface=$iface
        break
    fi
done

if [ "$(multipass get local.bridged-network)" = "<empty>" ]; then
    echo -e "${BLUE}Configuring bridge network...${NC}"
    if [ -z "$interface" ]; then
        echo -e "${YELLOW}No suitable interface found. Falling back to NAT.${NC}"
        BUILD_MODE="NAT"
        bridge_arg=""
    else
        echo -e "${GREEN}Using bridged network on: ${interface}${NC}"
        multipass set local.bridged-network="$interface"
    fi
fi

# Check for running nodes
if multipass list --format json | jq -r '.list[].name' | grep -Eq '(controlplane|node01|node02)'; then
    echo -n -e "$RED"
    read -p "VMs already running. Delete and rebuild? (y/n) " ans
    echo -n -e "$NC"
    [ "$ans" != "y" ] && exit 1
fi

# Boot nodes
for node in controlplane $workers; do
    if multipass list --format json | jq -r '.list[].name' | grep -q "$node"; then
        echo -e "${YELLOW}Deleting $node${NC}"
        multipass delete "$node"
        multipass purge
    fi

    echo -e "${BLUE}Launching ${node}${NC}"
    if ! multipass launch $bridge_arg --disk 5G --memory "$VM_MEM_GB" --cpus 2 --name "$node" jammy; then
        sleep 1
        if [ "$(multipass list --format json | jq -r --arg no "$node" '.list[] | select (.name == $no) | .state')" != "Running" ]; then
            echo -e "${RED}$node failed to start!${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}$node booted!${NC}"
done

# Create hostfile entries
echo -e "${BLUE}Setting hostnames${NC}"
hostentries=/tmp/hostentries
rm -f "$hostentries"

if [ "$BUILD_MODE" = "BRIDGE" ] && [ -n "$interface" ]; then
    network=$(netstat -rn | grep "^0.0.0.0.*${interface}" | awk '{print $2}' | cut -d. -f1-3)
fi

for node in controlplane $workers; do
    if [ "$BUILD_MODE" = "BRIDGE" ] && [ -n "$interface" ]; then
        ip=$(multipass info "$node" --format json | jq -r --arg nw "$network" 'first(.info[]).ipv4[] | select(startswith($nw))')
    else
        ip=$(multipass info "$node" --format json | jq -r 'first(.info[]).ipv4[0]')
    fi
    echo "$ip $node" >> "$hostentries"
done

for node in controlplane $workers; do
    multipass transfer "$hostentries" "$node:/tmp/"
    multipass transfer "$SCRIPT_DIR/01-setup-hosts.sh" "$node:/tmp/"
    multipass exec "$node" -- /tmp/01-setup-hosts.sh "$BUILD_MODE" "${network:-}"
done

echo -e "${GREEN}Cluster bootstrap complete!${NC}"

# Optional auto-setup
if [ "${ARG:-}" = "-auto" ]; then
    echo -e "${BLUE}Running automated setup...${NC}"
    join_command=/tmp/join-command.sh

    for node in controlplane $workers; do
        echo -e "${BLUE}- ${node}${NC}"
        multipass transfer "$hostentries" "$node:/tmp/"
        multipass transfer "$SCRIPT_DIR"/*.sh "$node:/tmp/"
        for script in 02-setup-kernel.sh 03-setup-nodes.sh 04-kube-components.sh; do
            multipass exec "$node" -- /tmp/$script
        done
    done

    multipass exec controlplane /tmp/05-deploy-controlplane.sh
    multipass transfer controlplane:/tmp/join-command.sh "$join_command"

    for n in $workers; do
        multipass transfer "$join_command" "$n:/tmp"
        multipass exec "$n" -- sudo "$join_command"
    done
    echo -e "${GREEN}Cluster setup complete!${NC}"
fi
