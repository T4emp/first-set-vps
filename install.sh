#!/bin/bash
# =============================================================================
# install.sh — universal installer
# Все параметры передаются через переменные окружения
# =============================================================================
set -e

# -----------------------------------------------------------------------------
# Обязательные переменные
# -----------------------------------------------------------------------------
GITHUB_REPO="${GITHUB_REPO:?'Ошибка: укажи GITHUB_REPO'}"
GITHUB_BRANCH="${GITHUB_BRANCH:?'Ошибка: укажи GITHUB_BRANCH'}"
MINIO_HOST="${MINIO_HOST:?'Ошибка: укажи MINIO_HOST'}"
MINIO_BUCKET="${MINIO_BUCKET:?'Ошибка: укажи MINIO_BUCKET'}"
MINIO_ACCESS="${MINIO_ACCESS:?'Ошибка: укажи MINIO_ACCESS'}"
MINIO_SECRET="${MINIO_SECRET:?'Ошибка: укажи MINIO_SECRET'}"
TGUARD_PATH="${TGUARD_PATH:?'Ошибка: укажи TGUARD_PATH'}"
OPTIMIZE_PATH="${OPTIMIZE_PATH:?'Ошибка: укажи OPTIMIZE_PATH'}"

# -----------------------------------------------------------------------------
# Производные переменные
# -----------------------------------------------------------------------------
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH"
GITHUB_API="https://api.github.com/repos/$GITHUB_REPO"

MC_BIN="/tmp/mc_installer"
VERSION_FILE="/root/.vps_install_version"

# -----------------------------------------------------------------------------
# Цвета
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Функция: git blob SHA1 (как считает GitHub)
# -----------------------------------------------------------------------------
git_blob_hash() {
    local file="$1"
    local size
    size=$(wc -c < "$file")
    printf "blob %s\0" "$size" | cat - "$file" | sha1sum | cut -d' ' -f1
}

# -----------------------------------------------------------------------------
# Функция: получить список ТОЛЬКО файлов (blob) в папке через GitHub API
# Возвращает: путь|sha для каждого файла
# -----------------------------------------------------------------------------
github_list_blobs() {
    local folder="$1"
    curl -s "$GITHUB_API/git/trees/$GITHUB_BRANCH?recursive=1" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('tree', []):
    if item['type'] == 'blob' and item['path'].startswith('$folder/'):
        print(item['path'] + '|' + item['sha'])
"
}

# -----------------------------------------------------------------------------
# Функция: скачать файл с GitHub если изменился (сравнение по blob SHA1)
# -----------------------------------------------------------------------------
sync_github_file() {
    local repo_path="$1"
    local remote_sha="$2"
    local local_path="$3"

    if [[ -f "$local_path" ]]; then
        local local_hash
        local_hash=$(git_blob_hash "$local_path")
        if [[ "$local_hash" == "$remote_sha" ]]; then
            warn "Без изменений: $repo_path"
            return 0
        fi
    fi

    mkdir -p "$(dirname "$local_path")"
    curl -s "$GITHUB_RAW/$repo_path" -o "$local_path"
    log "Обновлён: $repo_path"
}

# -----------------------------------------------------------------------------
# Установка mc
# -----------------------------------------------------------------------------
install_mc() {
    if [[ ! -f "$MC_BIN" ]]; then
        log "Скачиваем mc..."
        curl -s https://dl.min.io/client/mc/release/linux-amd64/mc -o "$MC_BIN"
        chmod +x "$MC_BIN"
    fi
    "$MC_BIN" alias set minio "$MINIO_HOST" "$MINIO_ACCESS" "$MINIO_SECRET" \
        --insecure 2>/dev/null
}

# -----------------------------------------------------------------------------
# Функция: скачать файл с MinIO (всегда перезаписывает)
# -----------------------------------------------------------------------------
sync_minio_file() {
    local minio_path="$1"
    local local_path="$2"

    mkdir -p "$(dirname "$local_path")"
    "$MC_BIN" cp "minio/$MINIO_BUCKET/$minio_path" "$local_path" 2>/dev/null \
        && log "Конфиг получен: $minio_path" \
        || warn "Не найден в MinIO: $minio_path"
}

# -----------------------------------------------------------------------------
# Функция: скачать папку с MinIO (очищает содержимое перед заменой)
# -----------------------------------------------------------------------------
sync_minio_folder() {
    local minio_path="$1"
    local local_path="$2"

    if [[ -d "$local_path" ]]; then
        rm -f "$local_path"/*
        warn "Очищена папка: $local_path"
    fi

    mkdir -p "$local_path"
    "$MC_BIN" cp --recursive "minio/$MINIO_BUCKET/$minio_path/" "$local_path/" 2>/dev/null \
        && log "Папка получена: $minio_path" \
        || warn "Не найдена в MinIO: $minio_path"
}

# -----------------------------------------------------------------------------
# Очистка (выполняется при любом выходе)
# -----------------------------------------------------------------------------
cleanup() {
    "$MC_BIN" alias rm minio 2>/dev/null || true
    rm -f "$MC_BIN"
    unset MINIO_ACCESS MINIO_SECRET MINIO_HOST MINIO_BUCKET
    unset GITHUB_REPO GITHUB_BRANCH TGUARD_PATH OPTIMIZE_PATH
    # Удаляем последнюю запись из истории (команду запуска этого скрипта)
    history -d $(history 1 | awk '{print $1}') 2>/dev/null || true
    log "Временные файлы и credentials очищены"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
echo ""
echo "================================================="
echo "  Installer: $GITHUB_REPO ($GITHUB_BRANCH)"
echo "================================================="
echo ""

# --- tguard: файлы с GitHub ---
log "Синхронизируем tguard с GitHub..."
while IFS='|' read -r repo_path remote_sha; do
    local_file="$TGUARD_PATH/${repo_path#tguard/}"
    sync_github_file "$repo_path" "$remote_sha" "$local_file"
done < <(github_list_blobs "tguard")

chmod +x "$TGUARD_PATH/tguard.sh"       2>/dev/null || true
chmod +x "$TGUARD_PATH/setup-cron.sh"   2>/dev/null || true
chmod +x "$TGUARD_PATH/lib/"*.sh        2>/dev/null || true

# --- optimize: файлы с GitHub ---
log "Синхронизируем optimize с GitHub..."
while IFS='|' read -r repo_path remote_sha; do
    local_file="$OPTIMIZE_PATH/${repo_path#optimize/}"
    sync_github_file "$repo_path" "$remote_sha" "$local_file"
done < <(github_list_blobs "optimize")

chmod +x "$OPTIMIZE_PATH/optimize-standalone.sh" 2>/dev/null || true

# --- Конфиги и листы с MinIO ---
log "Получаем конфиги с MinIO..."
install_mc

sync_minio_file   "tguard/tguard.conf"    "$TGUARD_PATH/tguard.conf"
sync_minio_folder "tguard/lists"           "$TGUARD_PATH/lists"
sync_minio_folder "tguard/providers"       "$TGUARD_PATH/providers"
sync_minio_file   "optimize/optimize.conf" "$OPTIMIZE_PATH/optimize.conf"

# --- Сохраняем версию ---
CURRENT_COMMIT=$(curl -s "$GITHUB_API/commits/$GITHUB_BRANCH" \
    | grep '"sha"' | head -1 | cut -d'"' -f4)
echo "$CURRENT_COMMIT" > "$VERSION_FILE"
log "Версия сохранена: ${CURRENT_COMMIT:0:7}"

echo ""
echo "================================================="
log "Готово!"
echo "================================================="
echo ""
