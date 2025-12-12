#!/bin/bash

# ===== HFT CPU Mapper - Data Collection Script v3.0 =====
# Полный сбор данных для HFT Mapper v3.0

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Проверяем аргументы ---
if [ -z "$1" ]; then
    echo -e "${RED}Ошибка: Не указано имя сервера. ${NC}"
    echo "Использование: $0 <HOSTNAME> [DURATION]"
    echo "Пример: $0 trade0526 15"
    exit 1
fi

HOST="${1}.qb.loc"
DURATION="${2:-15}"

# --- Проверка доступности хоста ПЕРЕД запросом пароля ---
echo -e "${YELLOW}Проверяю доступность $HOST...${NC}" >&2
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "exit" 2>/dev/null; then
    echo -e "${RED}Ошибка:  Не могу подключиться к $HOST${NC}" >&2
    echo "Проверьте:  1) Хост существует 2) SSH ключи настроены 3) Сеть доступна" >&2
    exit 1
fi
echo -e "${GREEN}OK${NC}" >&2

# --- Запрашиваем sudo пароль локально (скрытый ввод) ---
read -s -p "Введите sudo пароль для $HOST: " SUDO_PASS
echo "" >&2
echo -e "${YELLOW}Подключаюсь и собираю данные (это займет ~${DURATION} секунд из-за mpstat)...${NC}" >&2

# --- Выполняем подключение и сбор данных ---
ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$HOST" << EOF
    # Активируем sudo тихо
    echo "$SUDO_PASS" | sudo -S -v 2>/dev/null

    if [ \$? -ne 0 ]; then
        echo "ОШИБКА: Неверный пароль или нет прав sudo."
        exit 1
    fi

    # === ЗАГОЛОВОК ===
    echo "=== Подключение к $HOST ==="

    # === 1. LSCPU (CSV FORMAT) ===
    echo ""
    echo ">>> 1. LSCPU"
    # CSV формат: CPU,NODE,SOCKET,CORE,CACHE,ONLINE
    lscpu -p=CPU,NODE,SOCKET,CORE,CACHE,ONLINE 2>/dev/null | grep -v '^#'

    # === 2. NUMA TOPOLOGY ===
    echo ""
    echo ">>> 2. NUMA TOPOLOGY"
    if command -v numactl &> /dev/null; then
        numactl -H 2>/dev/null
    else
        echo "# numactl не установлен"
    fi

    # === 3. ISOLATED CORES ===
    echo ""
    echo ">>> 3. ISOLATED CORES"
    if [ -f /sys/devices/system/cpu/isolated ]; then
        cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none"
    else
        echo "none"
    fi

    # === 4. NETWORK ===
    echo ""
    echo ">>> 4. NETWORK"
    
    # Собираем информацию по всем сетевым интерфейсам
    for iface_path in /sys/class/net/eth* /sys/class/net/ens* /sys/class/net/enp*; do
        [ -e "\$iface_path" ] || continue
        iface=\$(basename "\$iface_path")
        echo ""
        echo "Interface: \$iface"
        
        # NUMA Node
        if [ -f /sys/class/net/\$iface/device/numa_node ]; then
            numa_node=\$(cat /sys/class/net/\$iface/device/numa_node 2>/dev/null)
            echo "NUMA Node: \$numa_node"
        fi
        
        # Driver info
        if [ -L /sys/class/net/\$iface/device/driver ]; then
            driver=\$(readlink /sys/class/net/\$iface/device/driver 2>/dev/null | xargs basename)
            echo "Driver: \$driver"
        fi
        
        # IRQ affinity
        echo "IRQ Affinity:"
        # Находим IRQ для интерфейса из /proc/interrupts
        grep -i "\$iface" /proc/interrupts 2>/dev/null | while IFS=: read irq rest; do
            irq=\$(echo "\$irq" | tr -d ' ')
            if [ -f /proc/irq/\$irq/smp_affinity_list ]; then
                affinity=\$(cat /proc/irq/\$irq/smp_affinity_list 2>/dev/null)
                echo "  IRQ \$irq: \$affinity"
            fi
        done
        
        # RPS CPUs
        if [ -d /sys/class/net/\$iface/queues ]; then
            for queue in /sys/class/net/\$iface/queues/rx-*; do
                if [ -f \$queue/rps_cpus ]; then
                    rps=\$(cat \$queue/rps_cpus 2>/dev/null)
                    if [ ! -z "\$rps" ] && [ "\$rps" != "00000000" ]; then
                        qname=\$(basename \$queue)
                        echo "  \$qname rps_cpus: \$rps"
                    fi
                fi
            done
        fi
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
    # Выводим топ сетевых прерываний
    if [ -f /proc/interrupts ]; then
        echo "Network interrupts (eth, mlx, ixgbe, i40e):"
        grep -iE 'eth|mlx|ixgbe|i40e|ens|enp' /proc/interrupts 2>/dev/null | head -20
    else
        echo "# /proc/interrupts не доступен"
    fi

    # === 7. CPU LOAD (MPSTAT) ===
    echo ""
    echo ">>> 7. CPU LOAD (MPSTAT)"
    if command -v mpstat &> /dev/null; then
        LC_ALL=C mpstat -P ALL $DURATION 1
    else
        echo "# mpstat не установлен (sudo apt install sysstat)"
    fi
EOF

echo "" >&2
echo -e "${GREEN}=== Сбор данных завершен ===${NC}" >&2
