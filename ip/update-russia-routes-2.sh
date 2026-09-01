#!/usr/bin/env bash

set -euo pipefail

URL="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"

OUTPUT="russia-routes-2.conf"
SOURCE="russia-cidr-2.txt"

TMP_FILE="$(mktemp)"

trap 'rm -f "$TMP_FILE"' EXIT

echo "Скачиваю актуальный список RU CIDR..."
curl -fsSL --retry 3 --connect-timeout 10 "$URL" -o "$TMP_FILE"

if [[ ! -s "$TMP_FILE" ]]; then
    echo "Ошибка: получен пустой файл"
    exit 1
fi

echo "Проверяю CIDR..."

grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
    "$TMP_FILE" > "$SOURCE"

if [[ ! -s "$SOURCE" ]]; then
    echo "Ошибка: в скачанном файле не найдено CIDR"
    exit 1
fi

ORIGINAL_COUNT=$(wc -l < "$SOURCE")

echo "Исходных CIDR: $ORIGINAL_COUNT"

echo "Агрегирую сети..."

python3 - "$SOURCE" "$OUTPUT" "$URL" <<'PY'
import ipaddress
import sys
from datetime import datetime

source = sys.argv[1]
output = sys.argv[2]
url = sys.argv[3]

networks = []

with open(source, "r") as f:
    for line in f:
        line = line.strip()

        if not line:
            continue

        try:
            network = ipaddress.ip_network(line, strict=False)

            if network.version == 4:
                networks.append(network)

        except ValueError:
            print(f"WARNING: пропущена некорректная сеть: {line}")

print(f"Загружено сетей: {len(networks)}")

# Удаляем дубли и сети, которые уже полностью входят
# в более крупные сети, а также объединяем соседние CIDR.
aggregated = list(ipaddress.collapse_addresses(networks))

print(f"После агрегации: {len(aggregated)}")

with open(output, "w") as f:

    f.write("# Россия - IPv4\n")
    f.write(f"# Source: {url}\n")
    f.write(f"# Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    f.write(f"# Networks: {len(aggregated)}\n")
    f.write("#\n")
    f.write("# OpenVPN routes - direct connection (net_gateway)\n")
    f.write("\n")

    for network in aggregated:

        # ipaddress гарантирует корректный network address
        ip = network.network_address
        prefix = network.prefixlen

        # Преобразуем prefix в netmask
        mask = network.netmask

        f.write(f"route {ip} {mask} net_gateway\n")
PY

FINAL_COUNT=$(grep -c '^route ' "$OUTPUT")

SIZE=$(wc -c < "$OUTPUT")

echo
echo "========================================"
echo "Готово"
echo "========================================"
echo
echo "Исходных сетей : $ORIGINAL_COUNT"
echo "После агрегации: $FINAL_COUNT"
echo "Размер файла   : $SIZE байт"
echo "Размер файла   : $((SIZE / 1024)) КБ"
echo
echo "Файл:"
echo "  $OUTPUT"
echo
echo "Первые маршруты:"
echo

head -n 15 "$OUTPUT"

echo
echo "Последние маршруты:"
echo

tail -n 10 "$OUTPUT"

echo