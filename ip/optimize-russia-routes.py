#!/usr/bin/env python3

import ipaddress
import sys
from collections import defaultdict

SOURCE = sys.argv[1] if len(sys.argv) > 1 else "russia-cidr.txt"
OUTPUT = sys.argv[2] if len(sys.argv) > 2 else "russia-routes.conf"

RU_COVERAGE = 0.99
FOREIGN_RATIO = 0.01


def load_networks(filename):
    networks = []

    with open(filename) as f:
        for line in f:
            line = line.strip()

            if not line:
                continue

            try:
                net = ipaddress.ip_network(line, strict=False)

                if net.version == 4:
                    networks.append(net)

            except ValueError:
                print(f"WARNING: invalid network: {line}")

    return list(ipaddress.collapse_addresses(networks))


def build_prefix_stats(networks):
    """
    Для каждого prefix от /0 до /32 считаем:
      ru - сколько российских адресов внутри
      total - сколько всего адресов
    """

    stats = {}

    for net in networks:
        start = int(net.network_address)
        end = int(net.broadcast_address)

        # Добавляем информацию о каждом предке.
        prefix = net.prefixlen

        for p in range(0, prefix + 1):
            parent = ipaddress.ip_network(
                f"{net.network_address}/{p}",
                strict=False
            )

            key = str(parent)

            if key not in stats:
                stats[key] = {
                    "network": parent,
                    "ru": 0,
                }

            stats[key]["ru"] += net.num_addresses

    return stats


def generate_candidates(stats):
    """
    Для каждого prefix считаем:
      total - размер prefix
      ru    - российские адреса
      foreign - нероссийские адреса
      ratio - доля нероссийских адресов

    Отбрасываем prefix, который содержит слишком мало RU.
    """

    candidates = []

    for data in stats.values():

        net = data["network"]
        ru = data["ru"]
        total = net.num_addresses
        foreign = total - ru

        if ru == 0:
            continue

        ratio = foreign / total

        candidates.append({
            "network": net,
            "ru": ru,
            "total": total,
            "foreign": foreign,
            "ratio": ratio,
        })

    return candidates


def optimize(networks):
    total_ru = sum(n.num_addresses for n in networks)

    required_ru = int(total_ru * RU_COVERAGE)

    print(f"Всего RU адресов : {total_ru:,}")
    print(f"Нужно покрыть     : {required_ru:,}")

    stats = build_prefix_stats(networks)
    candidates = generate_candidates(stats)

    print(f"Кандидатов        : {len(candidates):,}")

    # Начинаем с исходных точных сетей.
    selected = set(str(n) for n in networks)

    covered_ru = total_ru
    selected_total = total_ru
    selected_foreign = 0

    # Допустимое количество чужих адресов.
    #
    # Условие:
    # foreign / (ru + foreign) <= 1%
    #
    # => foreign <= selected_total * 0.01
    max_foreign = int(total_ru * FOREIGN_RATIO)

    print(f"Лимит чужих IP    : {max_foreign:,}")

    # Кандидаты сортируем по эффективности:
    #
    # сколько маршрутов мы потенциально убираем
    # на один добавленный чужой IP.
    #
    # Сначала выгодные крупные объединения.
    candidates.sort(
        key=lambda x: (
            x["foreign"] / x["ru"]
            if x["ru"] else float("inf")
        )
    )

    # Для каждого кандидата проверяем,
    # можно ли заменить содержащиеся в нём
    # текущие маршруты одним маршрутом.
    for candidate in candidates:

        net = candidate["network"]
        net_str = str(net)

        if net_str in selected:
            continue

        contained = []

        for item in selected:
            current = ipaddress.ip_network(item)

            if current.subnet_of(net):
                contained.append(item)

        if len(contained) < 2:
            continue

        # Сколько российских адресов уже покрывается
        # этими маршрутами.
        current_ru = sum(
            ipaddress.ip_network(x).num_addresses
            for x in contained
        )

        new_foreign = selected_foreign + (
            net.num_addresses - current_ru
        )

        # Не превышаем глобальный лимит.
        if new_foreign > max_foreign:
            continue

        # Убираем старые маршруты.
        for item in contained:
            selected.remove(item)

        selected.add(net_str)

        selected_foreign = new_foreign

        # Проверяем размер.
        selected_total = sum(
            ipaddress.ip_network(x).num_addresses
            for x in selected
        )

        selected_ru = selected_total - selected_foreign

        if selected_ru < required_ru:
            # Откатываем.
            selected.remove(net_str)

            for item in contained:
                selected.add(item)

            selected_foreign = sum(
                ipaddress.ip_network(x).num_addresses
                for x in selected
            )

    return selected


def write_routes(selected):
    networks = [
        ipaddress.ip_network(x)
        for x in selected
    ]

    networks.sort(key=lambda x: int(x.network_address))

    with open(OUTPUT, "w") as f:

        f.write("# Russia IPv4 - optimized\n")
        f.write("# OpenVPN direct routes\n\n")

        for net in networks:
            f.write(
                f"route {net.network_address} "
                f"{net.netmask} net_gateway\n"
            )

    return networks


def main():
    print("Загружаю RU CIDR...")

    networks = load_networks(SOURCE)

    print(f"Исходных сетей : {len(networks):,}")

    selected = optimize(networks)

    result = write_routes(selected)

    original_ru = sum(n.num_addresses for n in networks)

    result_total = sum(n.num_addresses for n in result)

    # Считаем реальное RU-покрытие.
    #
    # Для этого суммируем пересечение результата
    # с исходными российскими сетями.
    covered_ru = 0

    for ru_net in networks:
        for route in result:

            if route.overlaps(ru_net):

                intersection_start = max(
                    int(route.network_address),
                    int(ru_net.network_address)
                )

                intersection_end = min(
                    int(route.broadcast_address),
                    int(ru_net.broadcast_address)
                )

                if intersection_start <= intersection_end:
                    covered_ru += (
                        intersection_end
                        - intersection_start
                        + 1
                    )

    foreign = result_total - covered_ru

    coverage = covered_ru / original_ru * 100
    foreign_ratio = foreign / result_total * 100

    import os

    size = os.path.getsize(OUTPUT)

    print()
    print("========================================")
    print("Результат")
    print("========================================")
    print()
    print(f"Исходных CIDR : {len(networks):,}")
    print(f"Итоговых CIDR  : {len(result):,}")
    print()
    print(f"RU всего       : {original_ru:,}")
    print(f"RU покрыто     : {covered_ru:,}")
    print(f"RU покрытие    : {coverage:.4f}%")
    print()
    print(f"Всего адресов  : {result_total:,}")
    print(f"Чужих адресов  : {foreign:,}")
    print(f"Чужих доля     : {foreign_ratio:.4f}%")
    print()
    print(f"Размер файла   : {size:,} байт")
    print(f"Размер файла   : {size / 1024:.1f} KB")
    print()
    print(f"Файл: {OUTPUT}")
    print()

    if coverage >= 99 and foreign_ratio <= 1:
        print("OK: условия 99% / 1% выполнены.")
    else:
        print("WARNING: условия 99% / 1% НЕ выполнены.")


if __name__ == "__main__":
    main()