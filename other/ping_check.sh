#!/bin/bash

# Файл с доменами
INPUT_FILE="ip.txt"
LOG_FILE="ping_results.txt"

# Проверка наличия файла
if [ ! -f "$INPUT_FILE" ]; then
    echo "Файл $INPUT_FILE не найден!"
    exit 1
fi

# Извлекаем домены: пропускаем строки с комментариями //
# убираем кавычки, запятые, пробелы — берём только сами домены
DOMAINS=$(grep -v '^\s*//' "$INPUT_FILE" | sed 's|//.*||' | grep -oE '[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')

echo "========================================"
echo " Проверка доступности доменов"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# Счётчики
TOTAL=0
OK=0
FAIL=0

# Очищаем лог
> "$LOG_FILE"
echo "Проверка доступности доменов — $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"

for DOMAIN in $DOMAINS; do
    TOTAL=$((TOTAL + 1))

    # Пингуем: 1 пакет, таймаут 3 секунды
    if ping -c 1 -W 3 "$DOMAIN" > /dev/null 2>&1; then
        STATUS="✅ OK"
        OK=$((OK + 1))
    else
        STATUS="❌ FAIL"
        FAIL=$((FAIL + 1))
    fi

    LINE="$STATUS  $DOMAIN"
    echo "$LINE"
    echo "$LINE" >> "$LOG_FILE"
done

echo ""
echo "========================================"
echo " Итого: $TOTAL | ✅ Доступно: $OK | ❌ Недоступно: $FAIL"
echo "========================================"

echo "" >> "$LOG_FILE"
echo "Итого: $TOTAL | Доступно: $OK | Недоступно: $FAIL" >> "$LOG_FILE"

echo ""
echo "Результаты сохранены в: $LOG_FILE"
