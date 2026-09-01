#!/usr/bin/env bash

set -euo pipefail

URL="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"

OUTPUT="russia-routes.conf"
SOURCE="russia-cidr.txt"

TMP_FILE="$(mktemp)"

trap 'rm -f "$TMP_FILE"' EXIT

echo "Скачиваю актуальный список RU CIDR..."
curl -fsSL --retry 3 --connect-timeout 10 "$URL" -o "$TMP_FILE"

if [[ ! -s "$TMP_FILE" ]]; then
    echo "Ошибка: получен пустой файл"
    exit 1
fi

# Сохраняем исходный CIDR
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
    "$TMP_FILE" > "$SOURCE"

if [[ ! -s "$SOURCE" ]]; then
    echo "Ошибка: в скачанном файле не найдено CIDR"
    exit 1
fi

echo "Генерирую OpenVPN routes..."

{
    echo "# Россия - IPv4"
    echo "# Source: $URL"
    echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo

    while IFS= read -r CIDR; do
        IP="${CIDR%/*}"
        PREFIX="${CIDR#*/}"

        # Преобразуем CIDR prefix в netmask
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

    done < "$SOURCE"

} > "$OUTPUT"

COUNT=$(grep -c '^route ' "$OUTPUT")

echo
echo "Готово."
echo
echo "CIDR:    $SOURCE"
echo "OpenVPN: $OUTPUT"
echo "Маршрутов: $COUNT"
echo
echo "Первые маршруты:"
head -n 10 "$OUTPUT"