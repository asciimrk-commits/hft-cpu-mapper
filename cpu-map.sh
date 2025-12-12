#!/bin/bash

# ===== HFT CPU Mapper - Data Collection Script v2.1 =====
# Формат вывода совместим с HFT Mapper v2.6 (оригинальный)

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

    # === 1. LSCPU (ОРИГИНАЛЬНЫЙ ФОРМАТ - space separated) ===
    echo ""
    echo ">>> 1. LSCPU -E"
    lscpu -e | grep yes

    # === 2. NETWORK NUMA NODES (ОРИГИНАЛЬНЫЙ ФОРМАТ) ===
    echo ""
    echo ">>> 2. NETWORK NUMA NODES"

    grep -oh '[0-9]*' /sys/class/net/*/device/numa_node 2>/dev/null


    # === 3. RUNTIME CONFIG (bender) ===
    echo ""
    echo ">>> 3. RUNTIME CONFIG"
    if command -v bender-cpuinfo &> /dev/null; then
        sudo -n bender-cpuinfo 2>/dev/null
        echo ""
        echo "Network interfaces cpus:"
        sudo -n bender-cpuinfo -o net 2>/dev/null
    else
        echo "# bender-cpuinfo не установлен"
    fi

    # === 4. CPU LOAD (MPSTAT) ===
    echo ""
    echo ">>> 4. CPU LOAD (MPSTAT)"
    if command -v mpstat &> /dev/null; then
        LC_ALL=C mpstat -P ALL $DURATION 1
    else
        echo "# mpstat не установлен (sudo apt install sysstat)"
    fi
EOF

echo "" >&2
echo -e "${GREEN}=== Сбор данных завершен ===${NC}" >&2
