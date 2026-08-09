#!/bin/bash
# Мониторинг CPU steal time каждую секунду
# Использование: ./steal_monitor.sh [интервал_в_секундах]
# По умолчанию интервал = 1 секунда

INTERVAL="${1:-1}"

echo "Мониторинг CPU steal time (Ctrl+C для остановки)"
echo "Время     | us    sy    id    st    | load average"
echo "----------|----------------------------|------------------"

while true; do
    TS=$(date '+%H:%M:%S')
    LINE=$(top -bn1 | grep '%Cpu(s)')
    LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)

    US=$(echo "$LINE" | awk -F',' '{print $1}' | awk '{print $1}')
    SY=$(echo "$LINE" | awk -F',' '{print $2}' | awk '{print $1}')
    ID=$(echo "$LINE" | awk -F',' '{print $4}' | awk '{print $1}')
    ST=$(echo "$LINE" | awk -F',' '{print $8}' | awk '{print $1}')

    printf "%s | us:%-5s sy:%-5s id:%-5s st:%-5s | load: %s\n" "$TS" "$US" "$SY" "$ID" "$ST" "$LOAD"

    sleep "$INTERVAL"
done
