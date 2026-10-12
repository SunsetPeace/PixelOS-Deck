#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Подготовка входных данных устройства: factory-образ Pixel 3, проприетарные
# blob-ы (GPU/ADSP/Wi-Fi), снятие разметки разделов с реального аппарата.
#
# Использование:
#   scripts/prepare-device.sh download-factory   # качает zip с Google
#   scripts/prepare-device.sh extract-vendor     # извлекает vendor-раздел
#   scripts/prepare-device.sh dump-partitions    # getvar-разметка -> configs/<dev>.partitions
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Аргументы: [download-factory|extract-vendor|dump-partitions] [--device <dev>]
# (или TARGET_DEVICE=<dev> в окружении). Первый позиционный аргумент — команда.
DEV="blueline"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEV="${2:-blueline}"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
export TARGET_DEVICE="$DEV"
load_config "$DEV"

cmd="${TARGET_CMD:-${ARGS[0]:-help}}"

usage() {
    cat <<EOF
usage: $0 <download-factory|extract-vendor|dump-partitions>
EOF
    exit 1
}

download_factory() {
    need_cmd curl unzip sha256sum
    local dir="${BUILD_DIR}/factory"
    mkdir -p "$dir"
    # Google не публикует стабильный URL без токена согласия; скрипт принимает
    # локальный путь через FACTORY_LOCAL в configs/<dev>.conf.local.
    # Допускаются оба написания имени архива: каноническое Google
    # (blueline-sp1a.210812.016.c2-factory-<hash>.zip) и с точками между
    # компонентами build-id (sp1a.210812.016.c2), как их отдаёт зеркало.
    local base
    base=$(printf '%s' "$ANDROID_BASELINE" | tr 'A-Z' 'a-z')          # sp1a.210812.016.c2
    local dotted="${base//./-}"                                        # sp1a-210812-016-c2
    if [[ -n "${FACTORY_LOCAL:-}" ]]; then
        # Windows-пути (C:\...) и MSYS (/c/...) конвертируем, если есть wslpath/msys
        local src="$FACTORY_LOCAL"
        if [[ "$src" == *:\\* || "$src" == *[A-Za-z]:*/* ]] && command -v wslpath >/dev/null 2>&1; then
            src=$(wslpath -u "$src")
        fi
        src=${src//\~/$HOME}
        if [[ ! -f "$src" ]]; then
            die "FACTORY_LOCAL='$FACTORY_LOCAL' → файл не найден ('$src'). Скопируйте zip на сборочный хост (например в cache/) и поправьте configs/blueline.conf.local"
        fi
        case "$(basename "$src")" in
            *factory*.zip) ;;
            *) warn "имен '${src}' не содержит 'factory' — продолжаем, но проверьте, что это factory-архив blueline" ;;
        esac
        log "использую локальный factory-архив $src"
        cp -f "$src" "$dir/"
    else
        # fallback: любой подходящий factory-zip уже в cache/ или build/factory
        local cand
        cand=$(find "${CACHE_DIR:-${REPO_ROOT}/cache}" "$dir" -maxdepth 1 \
                  \( -name "*${base}*factory*.zip" -o -name "*${dotted}*factory*.zip" \) 2>/dev/null | head -1)
        [[ -n "$cand" ]] || die "factory-архив для ${ANDROID_BASELINE} не задан. Скачайте вручную (https://developers.google.com/android/images → Pixel 3 → ${ANDROID_BASELINE}) и укажите путь FACTORY_LOCAL в configs/blueline.conf.local, либо положите zip в cache/"
        log "нашёл factory-архив в кэше: $cand"
        cp -f "$cand" "$dir/"
    fi
    local zip
    zip=$(find "$dir" -maxdepth 1 -name '*factory*.zip' | head -1)
    [[ -n "$zip" ]] || die "в $dir нет factory-архива"
    local sumfile="${REPO_ROOT}/checksums/$(basename "$zip").sha256"
    mkdir -p "${REPO_ROOT}/checksums"
    if [[ -f "$sumfile" ]]; then
        (cd "$(dirname "$zip")" && sha256sum -c "$sumfile")
    else
        warn "нет checksums/$(basename "$zip").sha256 — фиксирую хеш автоматически (сверьте с https://developers.google.com/android/images)"
        (cd "$(dirname "$zip")" && sha256sum "$(basename "$zip")") >"$sumfile"
    fi
    log "распаковка $(basename "$zip")"
    unzip -q -o "$zip" -d "$dir"
    log "готово: $dir"
}

extract_vendor() {
    need_cmd simg2img unsparse
    local dir="${BUILD_DIR}/factory"
    local img
    img=$(find "$dir" -maxdepth 2 -name 'image-blueline-*.img' | head -1)
    [[ -n "$img" ]] || die "сначала download-factory (нет image-*.img)"
    log "извлечение образов из image tar"
    local out="${BUILD_DIR}/vendor-img"
    mkdir -p "$out"
    tar -xf "$img" -C "$out"
    for p in vendor boot dtbo vbmeta; do
        [[ -f "${out}/${p}.img" ]] && log "получен ${p}.img ($(stat -c%s "${out}/${p}.img") байт)"
    done
    export VENDOR_IMG="${out}/vendor.img"
    printf '%s\n' "$VENDOR_IMG"
}

dump_partitions() {
    need_cmd fastboot
    local f="${REPO_ROOT}/configs/${TARGET_DEVICE}.partitions"
    log "снятие разметки с устройства в bootloader-режиме"
    fastboot getvar all >"${f}.raw" 2>&1 || die "устройство не в fastboot? (adb reboot bootloader)"
    grep -E 'partition-size|partition-type' "${f}.raw" >"$f" || true
    log "сохранено: $f — сверьте с configs/${TARGET_DEVICE}.conf и обновите PART_* при расхождении"
}

case "$cmd" in
    download-factory) download_factory ;;
    extract-vendor)   extract_vendor ;;
    dump-partitions)  dump_partitions ;;
    *) usage ;;
esac
