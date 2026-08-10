#!/bin/sh
# Проверка доступности сертификата домена
# ./check_ssl.sh 360.yandex.ru google.com example.com
# ./check_ssl.sh default
# Список доменов по умолчанию
DEFAULT_DOMAINS="360.yandex.ru google.com example.com"

if [ "$#" -eq 0 ]; then
  echo "Использование: $0 <домен1> [домен2] ... | default"
  exit 1
fi

if [ "$1" = "default" ]; then
  DOMAINS="$DEFAULT_DOMAINS"
else
  DOMAINS="$@"
fi

OK_DOMAINS=""
FAIL_DOMAINS=""

for DOMAIN in $DOMAINS; do
  echo "=== $DOMAIN ==="

  SUCCESS=0

  for i in 1 2 3; do
    RESULT=$(echo | openssl s_client -connect "$DOMAIN":443 -servername "$DOMAIN" 2>/dev/null)
    CERT=$(echo "$RESULT" | openssl x509 -noout -dates -subject -issuer 2>/dev/null)

    if [ -n "$CERT" ]; then
      echo "Попытка $i: OK"
      SUCCESS=1
      LAST_CERT="$CERT"
    else
      echo "Попытка $i: ОШИБКА"
    fi

    sleep 1
  done

  echo ""
  if [ "$SUCCESS" -eq 1 ]; then
    echo "Итог: сертификат успешно получен минимум 1 раз из 3"
    echo "$LAST_CERT"
    OK_DOMAINS="$OK_DOMAINS $DOMAIN"
  else
    echo "Итог: сертификат НЕ удалось получить ни разу из 3 попыток"
    FAIL_DOMAINS="$FAIL_DOMAINS $DOMAIN"
  fi

  echo ""
done

echo "========================================"
echo "ИТОГОВАЯ СВОДКА"
echo "========================================"

if [ -n "$OK_DOMAINS" ]; then
  echo "Ответили (сертификат получен):"
  for D in $OK_DOMAINS; do
    echo "  - $D"
  done
else
  echo "Ответивших доменов нет"
fi

echo ""

if [ -n "$FAIL_DOMAINS" ]; then
  echo "Не ответили:"
  for D in $FAIL_DOMAINS; do
    echo "  - $D"
  done
fi