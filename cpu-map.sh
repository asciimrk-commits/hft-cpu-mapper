#!/bin/bash

# HFT CPU Mapper Data Collection Script
# Usage: ./cpu-map.sh <HOSTNAME> [DURATION]
# Example: ./cpu-map.sh trade0526 15

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default duration for mpstat
DEFAULT_DURATION=15

# Check arguments
if [ $# -lt 1 ]; then
    echo -e "${RED}Error: Missing hostname argument${NC}"
    echo "Usage: $0 <HOSTNAME> [DURATION]"
    echo "Example: $0 trade0526 15"
    exit 1
fi

HOSTNAME=$1
DURATION=${2:-$DEFAULT_DURATION}

echo -e "${BLUE}=== HFT CPU Mapper Data Collection ===${NC}"
echo -e "${BLUE}Target: ${HOSTNAME}${NC}"
echo -e "${BLUE}Duration: ${DURATION}s${NC}"
echo -e "${BLUE}Timestamp: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""

# Check host availability
echo -e "${YELLOW}Checking host availability...${NC}"
if ! ping -c 1 -W 2 "$HOSTNAME" &>/dev/null; then
    echo -e "${RED}✗ Host $HOSTNAME is not reachable${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Host is reachable${NC}"

# Prompt for password
echo -e "${YELLOW}Enter password for $HOSTNAME:${NC}"
read -s PASSWORD
echo ""

# Test SSH connection and sudo access
echo -e "${YELLOW}Validating SSH and sudo access...${NC}"
if ! sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${HOSTNAME}" "sudo -n true" 2>/dev/null; then
    echo -e "${RED}✗ Failed to connect or sudo access denied${NC}"
    exit 1
fi
echo -e "${GREEN}✓ SSH and sudo access validated${NC}"
echo ""

# Start data collection
echo -e "${GREEN}=== Starting data collection ===${NC}"
echo ""

# Function to execute remote command
remote_exec() {
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "root@${HOSTNAME}" "$1"
}

echo "=== Подключение к $HOSTNAME ==="
echo ""

# 1. LSCPU
echo ">>> 1. LSCPU"
remote_exec "lscpu -p=CPU,NODE,SOCKET,CORE,CACHE,ONLINE | grep -v '^#'"
echo ""

# 2. NUMA TOPOLOGY
echo ">>> 2. NUMA TOPOLOGY"
remote_exec "numactl -H"
echo ""

# 3. ISOLATED CORES
echo ">>> 3. ISOLATED CORES"
remote_exec "cat /sys/devices/system/cpu/isolated 2>/dev/null || echo 'none'"
echo ""

# 4. NETWORK INFORMATION
echo ">>> 4. NETWORK"
echo "--- Network Interfaces ---"
remote_exec "
for iface in \$(ls /sys/class/net/ | grep -E '^(eth|ens|enp)'); do
    echo \"Interface: \$iface\"
    
    # Get NUMA node
    numa_node=\$(cat /sys/class/net/\$iface/device/numa_node 2>/dev/null || echo 'N/A')
    echo \"  NUMA Node: \$numa_node\"
    
    # Get driver
    driver=\$(readlink /sys/class/net/\$iface/device/driver 2>/dev/null | xargs basename || echo 'N/A')
    echo \"  Driver: \$driver\"
    
    # Get IRQ CPUs
    if [ -d \"/sys/class/net/\$iface/device/msi_irqs\" ]; then
        irqs=\$(ls /sys/class/net/\$iface/device/msi_irqs 2>/dev/null | head -n 1)
        if [ -n \"\$irqs\" ]; then
            for irq in \$irqs; do
                smp_affinity=\$(cat /proc/irq/\$irq/smp_affinity_list 2>/dev/null || echo 'N/A')
                echo \"  IRQ CPUs: \$smp_affinity\"
                break
            done
        fi
    fi
    echo ""
done
"

# 5. RUNTIME CONFIG
echo ">>> 5. RUNTIME CONFIG"
remote_exec "
if [ -f /etc/qb-robot-runtime.conf ]; then
    cat /etc/qb-robot-runtime.conf
else
    echo 'Overview:'
    cat /proc/cmdline | grep -o 'isolcpus=[^ ]*' || echo 'No isolcpus'
    echo ''
    echo 'System cpus: '
    cat /sys/devices/system/cpu/online
fi
"
echo ""

# 6. TOP INTERRUPTS
echo ">>> 6. TOP INTERRUPTS"
echo "Top 10 interrupt sources:"
remote_exec "
cat /proc/interrupts | awk 'NR>1 {
    sum=0;
    for(i=2; i<=NF-1; i++) {
        if(\$i ~ /^[0-9]+$/) sum+=\$i
    }
    if(sum>0) print sum, \$0
}' | sort -rn | head -10 | awk '{first=\$1; \$1=\"\"; print \$0, \"(Total:\", first, \")\"}'
"
echo ""

# 7. CPU LOAD
echo ">>> 7. CPU LOAD (mpstat ${DURATION}s)"
echo -e "${YELLOW}Collecting CPU load data (${DURATION}s)...${NC}"
remote_exec "mpstat -P ALL $DURATION 1 | tail -n +3"
echo ""

echo -e "${GREEN}=== Data collection completed ===${NC}"
