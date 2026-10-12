#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# build-images.sh — финальная сборка прошивочных образов из артефактов
# предыдущих стадий (boot.img от build-boot.sh, steamdeck_a/b.img от
# build-rootfs.sh, vendor/dtbo/vbmeta из factory-архива):
#
#   1) deck-super.img  — динамический super с логическими разделами
#                        system_a/b (= targetfs DECK_PARTITION_A/B), если
#                        baseline использует super.img; иначе режим direct
#                        (отдельные fastboot-образы в flashable/);
#   2) vbmeta-deck.img — пересобранный vbmeta с флагом
#                        verification-disable (AVB_ALGORITHM из конфига),
#                        чтобы разблокированный загрузчик не ругался на
#                        изменённые system/boot;
#   3) flashable/      — плоская директория + manifest.tsv для scripts/flash.sh
#                        (имена слотов берутся из configs/blueline.conf).
#
# Использование:
#   scripts/build-images.sh                 # полный цикл
#   scripts/build-images.sh --dry-run       # только проверка входов и план
#   scripts/build-images.sh --no-super      # принудительно direct-mode
#
# Входы (создаются заранее):
#   ${OUT_DIR}/boot.img                     <- scripts/build-boot.sh
#   ${OUT_DIR}/steamdeck_a.img, _b.img      <- scripts/build-rootfs.sh image
#   ${BUILD_DIR}/factory/image-*/*.img      <- scripts/prepare-device.sh extract-vendor
set -euo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${TARGET_DEVICE:-blueline}"

DRY_RUN=0
ALLOW_SUPER=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --no-super)  ALLOW_SUPER=0; shift ;;
        *) die "неизвестный флаг $1" ;;
    esac
done

FLASH_DIR="${OUT_DIR}/flashable"
SUPER_IMG="${OUT_DIR}/deck-super.img"
VBMETA_IMG="${OUT_DIR}/vbmeta-deck.img"
MANIFEST="${FLASH_DIR}/manifest.tsv"

step() { log "[build-images] $*"; }

# ---------------------------------------------------------------------------
# Входы
# ---------------------------------------------------------------------------
check_inputs() {
    local missing=()
    for f in "${OUT_DIR}/boot.img" \
             "${OUT_DIR}/steamdeck_a.img" \
             "${OUT_DIR}/steamdeck_b.img"; do
        [[ -f "$f" ]] || missing+=("$f")
    done
    if ((${#missing[@]})); then
        printf 'missing inputs:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        die "соберите сначала boot (scripts/build-boot.sh) и targetfs (scripts/build-rootfs.sh image)"
    fi
}

find_factory_img() {
    # vendor/boot/dtbo/vbmeta/radio лежат внутри image-blueline-*.tar
    # (extracted prepare-device.sh в BUILD_DIR/vendor-img) или рядом с ним.
    local name="$1"
    find "${BUILD_DIR}/vendor-img" "${BUILD_DIR}/factory" -maxdepth 2 \
         -name "${name}.img" 2>/dev/null | head -1 || true
}

# ---------------------------------------------------------------------------
# 1) super.img (lpmake) — только если baseline реально использует super
# ---------------------------------------------------------------------------
build_super() {
    local group="deck_group"
    # размеры логических разделов: targetfs фиксированы конфигом; vendor —
    # берём фактический размер из factory, system/product оставляем как в
    # исходном super (мы их затираем своими steamdeck_*, поэтому им хватает
    # минимального размера 0-байтного placeholder в нашем layout).
    local la="system_a:${PART_DECK_A_SIZE}" lb="system_b:${PART_DECK_B_SIZE}"
    local extra="" vimg="" vsize=0
    vimg=$(find_factory_img vendor)
    [[ -n "$vimg" ]] && vsize=$(( $(stat -c%s "$vimg") + 16*1024*1024 ))
    [[ -n "$vimg" ]] && extra="vendor_a:${vsize} vendor_b:${vsize}"

    need_cmd lpmake
    step "super.img: lpmake (группа ${group})"
    log "логические разделы: ${la} ${lb} ${extra}"
    (( DRY_RUN )) && return 0

    local super_dev_size
    super_dev_size=$(getvar_or_default super-partition-size "$((8*1024*1024*1024))")
    local group_size=$(( PART_DECK_A_SIZE + PART_DECK_B_SIZE + 2 * vsize ))
    (( group_size < super_dev_size )) || die "группа ${group} (${group_size}) > super (${super_dev_size}): уменьшите PART_DECK_*_SIZE в configs/${TARGET_DEVICE}.conf"

    # shellcheck disable=SC2086
    lpmake \
        --metadata-slots 3 \
        --virtual-ab \
        --device "super:${super_dev_size}" \
        --group "${group}:${group_size}" \
        --image "${la}=${OUT_DIR}/steamdeck_a.img" \
        --image "${lb}=${OUT_DIR}/steamdeck_b.img" \
        $( [[ -n "$vimg" ]] && echo "--image vendor_a=${vimg} --image vendor_b=${vimg}" ) \
        --output "$SUPER_IMG"
    log "готово: $SUPER_IMG ($(stat -c%s "$SUPER_IMG") байт)"
}

getvar_or_default() {
    # читаем размер из configs/<dev>.partitions (dump-partitions), иначе default
    local key="$1" def="$2" f="${REPO_ROOT}/configs/${TARGET_DEVICE}.partitions"
    if [[ -f "$f" ]]; then
        local v
        v=$(grep -oP "^\s*${key}\s*:\s*\K[0-9]+" "$f" 2>/dev/null | head -1) || true
        [[ -n "${v:-}" ]] && { echo "$v"; return; }
    fi
    echo "$def"
}

# ---------------------------------------------------------------------------
# 2) vbmeta-deck.img — AVB без verification (для unlocked bootloader)
# ---------------------------------------------------------------------------
build_vbmeta() {
    (( DRY_RUN )) || need_cmd avbtool   # dry-run должен работать и без Android-тулзов на хосте
    step "vbmeta-deck.img (${AVB_ALGORITHM}, flag=2 verification-disable)"
    (( DRY_RUN )) && return 0
    # flags=2 = AVB_VBMETA_IMAGE_FLAGS_VERIFICATION_DISABLED: отключает и
    # verity, и верификацию — нужно для unlocked bootloader с изменёнными
    # boot/system. Альтернатива без флага — подписывать своим key (не делаем).
    avbtool make_vbmeta_image \
        --algorithm "$AVB_ALGORITHM" \
        --flags 2 \
        --padding_size 4096 \
        --output "$VBMETA_IMG"
    log "готово: $VBMETA_IMG"
}

# ---------------------------------------------------------------------------
# 3) flashable/ — плоские образы + manifest.tsv для flash.sh
# ---------------------------------------------------------------------------
build_flashable() {
    step "подготовка ${FLASH_DIR}/"
    (( DRY_RUN )) && return 0
    mkdir -p "$FLASH_DIR"
    rm -f "${FLASH_DIR}"/*.img "${MANIFEST}"

    cp "${OUT_DIR}/boot.img"          "${FLASH_DIR}/boot_a.img"
    cp "${OUT_DIR}/boot.img"          "${FLASH_DIR}/boot_b.img"
    cp "${OUT_DIR}/steamdeck_a.img"   "${FLASH_DIR}/${DECK_PARTITION_A}.img"
    cp "${OUT_DIR}/steamdeck_b.img"   "${FLASH_DIR}/${DECK_PARTITION_B}.img"
    printf 'flash\tboot_a\tboot_a.img\n'            >>"$MANIFEST"
    printf 'flash\tboot_b\tboot_b.img\n'            >>"$MANIFEST"
    printf 'flash\t%s\t%s.img\n' "$DECK_PARTITION_A" "$DECK_PARTITION_A" >>"$MANIFEST"
    printf 'flash\t%s\t%s.img\n' "$DECK_PARTITION_B" "$DECK_PARTITION_B" >>"$MANIFEST"

    # vendor НЕ трогаем (docs/known-issues.md п.4): прошиваем оригинальный
    local vimg; vimg=$(find_factory_img vendor)
    if [[ -n "$vimg" ]]; then
        cp "$vimg" "${FLASH_DIR}/vendor.img"
        printf 'flash\tvendor_a\tvendor.img\n' >>"$MANIFEST"
        printf 'flash\tvendor_b\tvendor.img\n' >>"$MANIFEST"
    else
        warn "vendor.img не найден в build/ — presumed уже на устройстве, пропускаю"
    fi
    local rimg; rimg=$(find_factory_img modem)
    [[ -n "$rimg" ]] && { cp "$rimg" "${FLASH_DIR}/modem.img"; printf 'flash\tmodem_a\tmodem.img\nflash\tmodem_b\tmodem.img\n' >>"$MANIFEST"; }

    if [[ -f "$SUPER_IMG" ]]; then
        cp "$SUPER_IMG" "${FLASH_DIR}/super.img"
        printf 'flash\tsuper\tsuper.img\n' >>"$MANIFEST"
    fi
    if [[ -f "$VBMETA_IMG" ]]; then
        cp "$VBMETA_IMG" "${FLASH_DIR}/vbmeta.img"
        printf 'flash-verity\tvbmeta_a\tvbmeta.img\nflash-verity\tvbmeta_b\tvbmeta.img\n' >>"$MANIFEST"
        rm -f "${FLASH_DIR}/vbmeta.tsv"   # легаси-файл больше не используется
    fi
    # dtbo: наш overlay-патч уже вшит в boot/dtbo сборкой ядра — прошиваем,
    # если собран; иначе остаётся заводской.
    local dimg="${BUILD_DIR}/kout/dtbo.img"
    [[ -f "$dimg" ]] && { cp "$dimg" "${FLASH_DIR}/dtbo.img"; printf 'flash\tdtbo_a\tdtbo.img\nflash\tdtbo_b\tdtbo.img\n' >>"$MANIFEST"; }
    log "manifest: ${MANIFEST} ($(wc -l <"$MANIFEST") записей)"
}

# ---------------------------------------------------------------------------
main() {
    check_inputs
    local has_super=0
    local simg; simg=$(find_factory_img super)
    [[ -n "$simg" ]] && has_super=1
    if (( ALLOW_SUPER && has_super )); then
        build_super
    else
        warn "super.img недоступен (--no-super или baseline без dynamic partitions) — direct-mode: отдельные steamdeck_a/b.img в flashable/"
    fi
    build_vbmeta
    build_flashable
    (( DRY_RUN )) && { log "dry-run завершён (ничего не записано)"; return; }
    log "артефакты в ${OUT_DIR}: boot.img, steamdeck_[ab].img, $( [[ -f $SUPER_IMG ]] && echo deck-super.img ) , vbmeta-deck.img"
    log "прошивка: scripts/flash.sh --slots both --wipe-data"
}
main
