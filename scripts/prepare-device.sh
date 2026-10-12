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
load_config "${1:-}"

cmd="${TARGET_CMD:-${2:-${1:-help}}}"

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
    if [[ -n "${FACTORY_LOCAL:-}" && -f "${FACTORY_LOCAL}" ]]; then
        log "использую локальный factory-архив ${FACTORY_LOCAL}"
        cp -f "$FACTORY_LOCAL" "$dir/"
    else
        die "положите blueline factory-${ANDROID_BASELINE}.zip в cache/ или задайте FACTORY_LOCAL в configs/blueline.conf.local (страница загрузок: https://developers.google.com/android/images)"
    fi
    local zip
    zip=$(find "$dir" -maxdepth 1 -name '*factory*.zip' | head -1)
    [[ -n "$zip" ]] || die "в $dir нет factory-архива"
    local sumfile="${REPO_ROOT}/checksums/$(basename "$zip").sha256"
    if [[ -f "$sumfile" ]]; then
        (cd "$(dirname "$zip")" && sha256sum -c "$sumfile")
    else
        warn "нет checksums/$(basename "$zip").sha256 — зафиксируйте хеш вручную после первой загрузки"
        sha256sum "$zip" >"$sumfile"
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
