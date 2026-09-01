#!/usr/bin/env bash

set -euo pipefail

URL="https://raw.githubusercontent.com/w1zardz/amnezia-split-route-sync/refs/heads/master/dist/ru-direct-ipv4.txt"
OUTPUT="russia-services-routes.conf"

TMP_FILE="$(mktemp)"

trap 'rm -f "$TMP_FILE"' EXIT

echo "Скачиваю актуальный список российских сервисов..."

curl -fsSL \
    --retry 3 \
    --connect-timeout 10 \
    "$URL" \
    -o "$TMP_FILE"

if [[ ! -s "$TMP_FILE" ]]; then
    echo "Ошибка: получен пустой файл"
    exit 1
fi

COUNT=$(grep -Ec '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$TMP_FILE")

if [[ "$COUNT" -eq 0 ]]; then
    echo "Ошибка: CIDR не найдены"
    exit 1
fi

echo "Найдено CIDR: $COUNT"

echo "Генерирую OpenVPN config..."

{
    echo "# Российские сервисы"
    echo "# Source: $URL"
    echo "# Networks: $COUNT"
    echo

    while IFS= read -r CIDR; do
        [[ -z "$CIDR" ]] && continue
        [[ "$CIDR" =~ ^# ]] && continue

        IP="${CIDR%/*}"
        PREFIX="${CIDR#*/}"

        # CIDR -> netmask
        MASK=$(python3 - "$PREFIX" <<'PY'
import sys

prefix = int(sys.argv[1])

mask = (0xffffffff << (32 - prefix)) & 0xffffffff if prefix else 0

print(".".join(
    str((mask >> shift) & 255)
    for shift in (24, 16, 8, 0)
))
PY
)

        echo "route $IP $MASK net_gateway"

    done < "$TMP_FILE"

} > "$OUTPUT"

ROUTES=$(grep -c '^route ' "$OUTPUT")
SIZE=$(wc -c < "$OUTPUT")

echo
echo "========================================"
echo "Готово"
echo "========================================"
echo
echo "Маршрутов: $ROUTES"
echo "Размер:    $SIZE байт"
echo "Размер:    $((SIZE / 1024)) KB"
echo
echo "Файл: $OUTPUT"
echo