#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# flash.sh — прошивка собранных образов на Pixel 3 (blueline).
#
# Использует manifest из build/<device>/out/flashable/, созданный
# scripts/build-images.sh; имена слотов/разделов берутся из
# configs/blueline.conf (TARGET_DEVICE переключает blueline/sargo).
#
# Использование:
#   adb reboot bootloader && scripts/flash.sh [опции]
# Опции:
#   --slots both|a|b     какие A/B-слоты прошивать (по умолчанию both)
#   --wipe-data          стереть userdata + cache (первая установка / сброс)
#   --set-active=a|b     выбрать активный слот после прошивки (default a)
#   --dry-run            показать команды fastboot, ничего не выполнять
#   --skip vendor,modem  не прошивать указанные образы (список через запятую)
#   --images-dir PATH    директория с manifest.tsv (default out/flashable)
#
# Правила безопасности (docs/known-issues.md):
#   * vendor НИКОГДА не форматируется и не стирается — без blob-ов нет
#     GPU/Wi-Fi/modem; при --wipe-data стираются только userdata/cache;
#   * vbmeta прошивается с --disable-verity --disable-verification;
#   * перед записью сверяем фактические размеры разделов (fastboot getvar)
#     с PART_* из конфига — при расхождении отказ.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${TARGET_DEVICE:-blueline}"

SLOTS="both"
WIPE_DATA=0
ACTIVE="a"
DRY_RUN=0
SKIP=""
IMAGES_DIR="${OUT_DIR}/flashable"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slots)      SLOTS="$2"; shift 2 ;;
        --wipe-data)  WIPE_DATA=1; shift ;;
        --set-active) ACTIVE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --skip)       SKIP="$2"; shift 2 ;;
        --images-dir) IMAGES_DIR="$2"; shift 2 ;;
        *) die "неизвестный флаг $1" ;;
    esac
done

(( DRY_RUN )) || need_cmd fastboot   # dry-run печатает план и без SDK на хосте
MANIFEST="${IMAGES_DIR}/manifest.tsv"
[[ -f "$MANIFEST" ]] || die "нет ${MANIFEST} — выполните scripts/build-images.sh"

skipped() { [[ ",${SKIP}," == *",$1,"* ]]; }

fb() {
    # обёртка: печатает команду, выполняет если не --dry-run
    log "fastboot $*"
    (( DRY_RUN )) && return 0
    fastboot "$@"
}

confirm_unlocked() {
    (( DRY_RUN )) && return 0
    local state
    state=$(fastboot oem device-info 2>/dev/null | grep -oP 'Device unlocked:\s*\K\w+' || true)
    # старые fastboot печатают в stderr; fallback на getvar
    [[ -z "$state" ]] && state=$(fastboot getvar unlocked 2>&1 | grep -oP 'unlocked:\s*\Kyes' || true)
    [[ "$state" == "yes" ]] || die "загрузчик заблокирован: сначала разблокировка (https://developers.google.com/android/unlock_device_for_bootloaders), данные будут стёрты"
}

verify_partition_sizes() {
    (( DRY_RUN )) && return 0
    local mismatches=0
    for pair in "boot:${PART_BOOT_SIZE}" "dtbo:${PART_DTBO_SIZE}"; do
        local name="${pair%%:*}" want="${pair##*:}" got
        got=$(fastboot getvar "partition-size:${name}" 2>&1 | grep -oP '0x\K[0-9a-f]+' || true)
        [[ -n "$got" ]] || continue
        got=$(( 0x$got ))
        if (( got < want )); then
            warn "раздел ${name}: на устройстве ${got}, конфиг ждёт ${want} — обновите configs/${TARGET_DEVICE}.conf"
            mismatches=1
        fi
    done
    (( mismatches == 0 )) || die "размеры разделов не совпадают — см. dump-partitions"
}

flash_slot_pair() {
    # $1 = суффикс слота (_a/_b или пусто для non-A/B образов типа super/vbmeta)
    local sfx="$1" line part img target
    while IFS=$'\t' read -r op part img _rest; do
        [[ "$op" == flash || "$op" == flash-verity ]] || continue
        skipped "$img" && { warn "пропускаю ${img} (--skip)"; continue; }
        [[ -f "${IMAGES_DIR}/${img}" ]] || die "нет образа ${IMAGES_DIR}/${img}"
        target="$part"
        # manifest уже содержит имена со слотами (_a/_b); фильтруем по --slots
        if [[ "$part" == *_a || "$part" == *_b ]]; then
            case "$SLOTS:$part" in
                both:*)        : ;;
                a:*_a|b:*_b)   : ;;
                *)             continue ;;
            esac
        fi
        if [[ "$op" == flash-verity ]]; then
            # в manifest для flash-verity поле part = имя раздела (vbmeta_a/vbmeta_b),
            # не режим — защищаемся от мусора: голый "disabled"/пусто заменяем на vbmeta_a/b
            case "$target" in
                ""|disabled) fb --disable-verity --disable-verification flash vbmeta_a "${IMAGES_DIR}/${img}"
                             fb --disable-verity --disable-verification flash vbmeta_b "${IMAGES_DIR}/${img}"
                             continue ;;
            esac
            fb --disable-verity --disable-verification flash "$target" "${IMAGES_DIR}/${img}"
        else
            fb flash "$target" "${IMAGES_DIR}/${img}"
        fi
    done <"$MANIFEST"
}

main() {
    log "цель: ${PRODUCT_NAME} (${TARGET_DEVICE}), baseline ${ANDROID_BASELINE}, слоты=${SLOTS}"
    confirm_unlocked
    verify_partition_sizes

    flash_slot_pair ""

    if (( WIPE_DATA )); then
        log "стираю userdata и cache (внимание: полная потеря данных Android!)"
        fb -w erase userdata
        fb erase cache
    else
        warn "без --wipe-data старый userdata остаётся: при первой установке это ОБЯЗАТЕЛЬНО (AOSP-данные конфликтуют с Linux-runtime)"
    fi

    fb --set-active="$ACTIVE"
    (( DRY_RUN )) || { log "reboot..."; fb reboot; }
    log "готово. Через ~60 c: adb wait-for-device && python3 scripts/verify.py --device auto"
}
main
