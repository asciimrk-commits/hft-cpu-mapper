#!/bin/bash

# ===== HFT CPU Mapper - Data Collection Script v3.0 =====

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$1" ]; then
    echo -e "${RED}Ошибка:  Не указано имя сервера. ${NC}"
    echo "Использование: $0 <HOSTNAME> [DURATION]"
    exit 1
fi

HOST="${1}.qb.loc"
DURATION="${2:-15}"

echo -e "${YELLOW}Проверяю доступность $HOST...${NC}" >&2
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "exit" 2>/dev/null; then
    echo -e "${RED}Ошибка:  Не могу подключиться к $HOST${NC}" >&2
    exit 1
fi
echo -e "${GREEN}OK${NC}" >&2

read -s -p "Введите sudo пароль для $HOST: " SUDO_PASS
echo "" >&2
echo -e "${YELLOW}Собираю данные (~${DURATION}s)...${NC}" >&2

# Передаём пароль и duration через переменные окружения
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "SUDO_PASS='$SUDO_PASS' DURATION='$DURATION' bash -s" << 'REMOTE_SCRIPT'

# Активируем sudo
echo "$SUDO_PASS" | sudo -S -v 2>/dev/null
if [ $? -ne 0 ]; then
    echo "ОШИБКА:  Неверный пароль sudo."
    exit 1
fi

HOSTNAME_SHORT=$(hostname -s)
echo "=== Подключение к ${HOSTNAME_SHORT} ==="

# === 1. LSCPU (CSV формат) ===
echo ""
echo ">>> 1. LSCPU"
lscpu -p=CPU,NODE,SOCKET,CORE,CACHE,ONLINE 2>/dev/null | grep -v '^#'

# === 2. NUMA TOPOLOGY ===
echo ""
echo ">>> 2. NUMA TOPOLOGY"
numactl -H 2>/dev/null || echo "numactl not available"

# === 3. ISOLATED CORES ===
echo ""
echo ">>> 3. ISOLATED CORES"
cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none"

# === 4. NETWORK ===
echo ""
echo ">>> 4. NETWORK"

for iface in $(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|ens|enp|eno|ena)'); do
    echo "--- Interface: $iface ---"
    
    # NUMA node
    numa_node=$(cat /sys/class/net/$iface/device/numa_node 2>/dev/null)
    if [ -n "$numa_node" ] && [ "$numa_node" != "-1" ]; then
        echo "NUMA Node: $numa_node"
    else
        echo "NUMA Node: 0 (default/virtual)"
    fi
    
    # Driver
    driver=$(basename $(readlink /sys/class/net/$iface/device/driver 2>/dev/null) 2>/dev/null)
    echo "Driver: ${driver:-unknown}"
    
    # IRQ affinity
    echo "IRQ Affinity:"
    for irq_dir in /proc/irq/*; do
        irq=$(basename "$irq_dir")
        [[ "$irq" =~ ^[0-9]+$ ]] || continue
        if grep -q "$iface" "$irq_dir"/* 2>/dev/null; then
            affinity=$(cat "$irq_dir/smp_affinity_list" 2>/dev/null)
            echo "  IRQ $irq: CPUs [$affinity]"
        fi
    done
    
    # RPS (Receive Packet Steering)
    echo "RPS CPUs:"
    for queue in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
        if [ -f "$queue" ]; then
            mask=$(cat "$queue" 2>/dev/null)
            queue_name=$(basename $(dirname $queue))
            if [ "$mask" != "0" ] && [ "$mask" != "00000000" ] && [ -n "$mask" ]; then
                echo "  $queue_name: $mask"
            fi
        fi
    done
    echo ""
done

# === 5. RUNTIME CONFIG (bender) ===
echo ""
echo ">>> 5. RUNTIME CONFIG"
if command -v bender-cpuinfo &> /dev/null; then
    sudo -n bender-cpuinfo 2>/dev/null
    echo ""
    echo "Network interfaces cpus:"
    sudo -n bender-cpuinfo -o net 2>/dev/null
else
    echo "# bender-cpuinfo не установлен"
fi

# === 6. TOP INTERRUPTS ===
echo ""
echo ">>> 6. TOP INTERRUPTS"
echo "Network interrupts:"
grep -E 'eth|ena|ens|enp|mlx|ixgbe|i40e|virtio' /proc/interrupts 2>/dev/null | head -20

# === 7. CPU LOAD (MPSTAT) ===
echo ""
echo ">>> 7. CPU LOAD (MPSTAT)"
if command -v mpstat &> /dev/null; then
    LC_ALL=C mpstat -P ALL "$DURATION" 1
else
    echo "# mpstat не установлен"
fi

REMOTE_SCRIPT

echo "" >&2
echo -e "${GREEN}=== Сбор данных завершен ===${NC}" >&2
