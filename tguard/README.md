# tguard — управление iptables-правилами

## Структура

```
/root/tguard/
├── tguard.sh              # точка входа
├── tguard.conf            # конфигурация (порты, IP remnaware) ← редактировать здесь
├── setup-cron.sh          # установка cron (запустить один раз)
├── .last_flags            # автосохранение последнего запуска (для reload)
├── lib/
│   ├── common.sh          # логирование, валидация, утилиты
│   ├── core.sh            # базовые правила (iptables hardening)
│   ├── whitelist.sh       # применение ip.list и providers/
│   └── geoip.sh           # загрузка и применение GeoIP
├── lists/
│   └── ip.list            # статичные IP/CIDR с группами и портами
├── providers/
│   ├── yandex.list        # IP-диапазоны Яндекса
│   ├── beeline.list       # и т.д.
│   └── timeweb.list
├── geoip/                 # кэш GeoIP (создаётся автоматически)
│   ├── ru.zone
│   └── eu.zone
└── backup/                # автобэкапы rules.v4/rules.v6 (создаётся автоматически)
```

## Конфигурация

Все настройки — в файле `tguard.conf` (рядом с `tguard.sh`):

| Переменная       | Описание                                              | Пример           |
|------------------|-------------------------------------------------------|------------------|
| `SSH_PORT`       | Порт SSH (может быть нестандартным)                   | `2222`           |
| `REMNAWARE_IP`   | IP сервера управления (remnaware)                     | `1.2.3.4/32`     |
| `REMNAWARE_PORT` | Порт общения remnaware с нодой                        | `9000`           |
| `USER_PORTS`     | Доп. порты для пользователей (443 уже открыт в core)  | `9443,8443`      |

## Команды

```bash
# Базовые правила
./tguard.sh basic

# Базовые + GeoIP (можно несколько)
./tguard.sh basic geoRU
./tguard.sh basic geoRU geoEU geoDE

# Базовые + провайдер из providers/*.list
./tguard.sh basic yandex

# Базовые + GeoIP + провайдеры (можно комбинировать)
./tguard.sh basic geoRU yandex_cdn cloudflare

# Белый список — все группы из ip.list
./tguard.sh whitelist

# Белый список — только конкретная группа
./tguard.sh whitelist usa
./tguard.sh whitelist ge

# Всё сразу: basic + все providers/ + все geoip/*.zone + весь ip.list
./tguard.sh full

# Добавить IP — порт 443 по умолчанию
./tguard.sh add 1.2.3.4/32

# Добавить IP в группу
./tguard.sh add 1.2.3.4/32 usa

# Добавить IP в группу с дополнительными портами
./tguard.sh add 1.2.3.4/32 usa 9443,8443

# Повторить последний запуск (читает .last_flags)
./tguard.sh reload

# Принудительно обновить GeoIP-файлы
./tguard.sh update-geo

# Скачать/обновить провайдеров из providers/urls.conf
./tguard.sh update-providers
```

## Формат ip.list

```
# это комментарий — игнорируется

##ge
31.177.111.14/32              ← открывает только 443

##usa
31.177.134.14/32 9443,10443   ← открывает 443 + 9443 + 10443
```

Группа — строка начинающаяся с `##`. Всё что ниже относится к ней до следующей группы.

## URL-провайдеры

Заполни `providers/urls.conf` — формат `имя|url`:

```
yandex_cdn|https://tech.cdn.yandex.net/prefixes/yc.json
cloudflare|https://www.cloudflare.com/ips-v4/#
```

Поддерживаемые форматы ответа сервера:
- JSON с полем `prefixes`: `{"prefixes": ["1.2.3.4/24", ...]}`
- JSON массив: `["1.2.3.4/24", ...]`
- Plain text: один CIDR на строку

После добавления URL запусти `./tguard.sh update-providers` — список скачается и сохранится как `providers/имя.list`. Дальше используй как обычный провайдер: `./tguard.sh basic yandex_cdn`.

## Первоначальная настройка

```bash
# 1. Скопировать на сервер
cp -r tguard/ /root/tguard/
chmod +x /root/tguard/tguard.sh /root/tguard/setup-cron.sh

# 2. Заполнить конфиг
nano /root/tguard/tguard.conf

# 3. Первый запуск
/root/tguard/tguard.sh basic

# 4. Установить cron (обновление GeoIP + восстановление после reboot)
/root/tguard/setup-cron.sh
```

## Добавить провайдера

1. Создать файл `providers/beeline.list`
2. Добавить CIDR-диапазоны (один на строку, комментарии с `#`)
3. Применить: `./tguard.sh basic beeline`

## Обновление правил

Скрипт при каждом запуске (кроме `add`) полностью пересбрасывает и пересоздаёт
таблицы — дополнительной очистки не требуется.

`./tguard.sh add` работает «горячо»: вставляет правило перед финальным DROP,
не трогая остальное. При следующем полном запуске IP будет применён из ip.list.

## GeoIP

- Источник: [ipdeny.com](https://www.ipdeny.com/ipblocks/)
- Кэш хранится в `geoip/<cc>.zone`
- Обновляется автоматически раз в 30 дней (через cron)
- При недоступности сервера используется устаревший кэш (с предупреждением)
- Файл проверяется на минимальный размер и формат CIDR перед применением
