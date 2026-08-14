#!/bin/bash
# Мониторинг CPU steal time
# Использование: ./steal_monitor.sh [интервал] [--report]
# --report : сразу собрать данные для письма в саппорт (30 сек)

INTERVAL="${1:-1}"
REPORT_MODE=0
[[ "$*" == *"--report"* ]] && REPORT_MODE=1

# --- Чтение steal из /proc/stat (точнее, чем top) ---
read_steal() {
    awk '/^cpu / {print $9}' /proc/stat
}

read_total() {
    awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat
}

# --- Режим --report: собрать данные и сгенерировать текст для саппорта ---
if [[ $REPORT_MODE -eq 1 ]]; then
    echo "Сбор данных за 30 секунд..."
    echo ""

    STEAL1=$(read_steal)
    TOTAL1=$(read_total)
    UPTIME=$(uptime -p 2>/dev/null || uptime)
    CPU_INFO=$(lscpu | grep -E 'Model name|Socket|CPU\(s\):' | head -3)
    VMSTAT_OUT=$(vmstat 5 6 2>/dev/null | tail -6)

    sleep 30

    STEAL2=$(read_steal)
    TOTAL2=$(read_total)

    DELTA_STEAL=$((STEAL2 - STEAL1))
    DELTA_TOTAL=$((TOTAL2 - TOTAL1))
    PCT=$(awk "BEGIN {printf \"%.1f\", ($DELTA_STEAL/$DELTA_TOTAL)*100}")

    LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    IDLE=$(awk '/^cpu / {printf "%.1f", $5/($2+$3+$4+$5+$6+$7+$8+$9+$10)*100}' /proc/stat)

    echo "========================================"
    echo "  ДАННЫЕ ДЛЯ ПИСЬМА В САППОРТ"
    echo "========================================"
    echo ""
    echo "Steal (30-sec /proc/stat delta): ${PCT}%"
    echo "Load average: $LOAD"
    echo "Uptime: $UPTIME"
    echo ""
    echo "vmstat output (st = steal column):"
    echo "$VMSTAT_OUT"
    echo ""
    echo "--- Готовый текст для письма ---"
    echo ""
    cat <<EOF
Our VM is experiencing CPU steal time degrading performance.

Measured data from inside the VM:
- Current steal time: ${PCT}% (30-second /proc/stat delta)
- Load average: $LOAD
- Uptime: $UPTIME
- Idle: ~${IDLE}%

Memory, disk I/O and network are healthy (see vmstat below),
so this is not caused by our workload.

Please investigate the host node and either resolve the contention
or migrate our VM to a less loaded node.

vmstat output (steal is the "st" column):
$VMSTAT_OUT
EOF
    echo ""
    echo "========================================"
    exit 0
fi

# --- Обычный режим мониторинга ---
echo "Мониторинг CPU steal time (Ctrl+C для остановки)"
echo "Интервал: ${INTERVAL}с | Источник: /proc/stat"
echo ""
printf "%-10s | %-6s %-6s %-6s %-6s | %-18s | %s\n" \
    "Время" "us%" "sy%" "id%" "st%" "load average" "статус"
echo "-----------|--------|--------|--------|--------|--------------------|---------"

COUNT=0
SUM_ST=0
MAX_ST=0

PREV_STEAL=$(read_steal)
PREV_TOTAL=$(read_total)

while true; do
    sleep "$INTERVAL"

    CUR_STEAL=$(read_steal)
    CUR_TOTAL=$(read_total)

    D_STEAL=$((CUR_STEAL - PREV_STEAL))
    D_TOTAL=$((CUR_TOTAL - PREV_TOTAL))

    # Защита от деления на ноль
    if [[ $D_TOTAL -eq 0 ]]; then
        PREV_STEAL=$CUR_STEAL
        PREV_TOTAL=$CUR_TOTAL
        continue
    fi

    ST=$(awk "BEGIN {printf \"%.1f\", ($D_STEAL/$D_TOTAL)*100}")
    US=$(awk '/^cpu / {printf "%.1f", $2/('$D_TOTAL')*100}' /proc/stat)
    SY=$(awk '/^cpu / {printf "%.1f", $4/('$D_TOTAL')*100}' /proc/stat)
    ID=$(awk '/^cpu / {printf "%.1f", $5/('$D_TOTAL')*100}' /proc/stat)

    LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    TS=$(date '+%H:%M:%S')

    # Статус
    STATUS="ok"
    ST_INT=$(awk "BEGIN {printf \"%d\", $ST}")
    if [[ $ST_INT -ge 20 ]]; then
        STATUS="КРИТИЧНО"
    elif [[ $ST_INT -ge 10 ]]; then
        STATUS="ВЫСОКИЙ"
    elif [[ $ST_INT -ge 5 ]]; then
        STATUS="внимание"
    fi

    printf "%-10s | %-6s %-6s %-6s %-6s | %-18s | %s\n" \
        "$TS" "$US" "$SY" "$ID" "$ST" "$LOAD" "$STATUS"

    # Накопление статистики
    COUNT=$((COUNT + 1))
    SUM_ST=$(awk "BEGIN {printf \"%.1f\", $SUM_ST + $ST}")
    MAX_ST=$(awk "BEGIN {m=$MAX_ST; s=$ST; print (s>m)?s:m}")

    PREV_STEAL=$CUR_STEAL
    PREV_TOTAL=$CUR_TOTAL
done
