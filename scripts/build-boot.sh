#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Сборка boot.img: GKI-ядро (или Android common kernel 4.9 для msm8998) +
# DTBO-overlay с поправками под turnip/MSM-GPU + minikinit-ramdisk, который
# монтирует erofs targetfs и execвит systemd.
#
# Флаги:
#   --kernel-dir PATH   уже настроенное дерево ядра (пропускает download)
#   --from-gki          скачать android15-6.6 GKI через repo (по умолчанию)
#   --legacy-4.9        собирать msm-4.9 из AOSP (для vendor HAL Pixel 3)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${TARGET_DEVICE:-blueline}"

KERNEL_DIR="${KERNEL_DIR:-${BUILD_DIR}/kernel}"
MODE="from-gki"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        --from-gki) MODE="from-gki"; shift ;;
        --legacy-4.9) MODE="legacy-4.9"; shift ;;
        *) die "неизвестный флаг $1" ;;
    esac
done

fetch_kernel() {
    need_cmd repo git
    mkdir -p "$KERNEL_DIR"
    if [[ "$MODE" == "from-gki" ]]; then
        log "синхронизация GKI ${GKI_KERNEL_BRANCH} (это долго, ~15 GiB)"
        (cd "$KERNEL_DIR" && repo init --git-lfs -u "${GKI_KERNEL_REPO}" -b "${GKI_KERNEL_BRANCH}" -m kernel_manifest_${GKI_KERNEL_BRANCH}.xml && repo sync -c -j"$(nproc)")
    else
        log "клон android-common/msm-4.9"
        git clone --depth 1 -b msm-4.9 https://android.googlesource.com/kernel/msm "$KERNEL_DIR/msm-4.9"
    fi
}

apply_patches() {
    log "применение патчей из patches/kernel/"
    local pdir="${REPO_ROOT}/patches/kernel"
    for p in "$pdir"/*.patch; do
        [[ -e "$p" ]] || continue
        if ! git -C "$KERNEL_DIR" apply --check "$p" 2>/dev/null; then
            warn "патч $(basename "$p") уже применён или не подходит — пропускаю"
            continue
        fi
        git -C "$KERNEL_DIR" am --3way "$p" || git -C "$KERNEL_DIR" apply "$p" || die "патч $(basename "$p") не лёг"
    done
}

build_image() {
    need_cmd make bc cpio lz4 dtc
    export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1
    local defconfig
    if [[ "$MODE" == "from-gki" ]]; then
        defconfig="gki_defconfig"
    else
        defconfig="lineageos_blueline_defconfig"
    fi
    make -C "$KERNEL_DIR" O="${BUILD_DIR}/kout" "$defconfig"
    # Конфиг-фрагменты, без которых targetfs не загрузится/не ускорится:
    while read -r frag; do
        [[ -f "${KERNEL_DIR}/${frag}" ]] || continue
        ./scripts/kconfig/merge_config.sh -m .config "${KERNEL_DIR}/${frag}"
    done < <(find "${KERNEL_DIR}/arch/arm64/configs/fragments" -name '*.config' 2>/dev/null)
    make -C "$KERNEL_DIR" O="${BUILD_DIR}/kout" -j"$(nproc)" Image.gz dtbs dtbo.img
}

build_ramdisk() {
    log "minikinit ramdisk (init -> switch_root в systemd)"
    local rd="${BUILD_DIR}/ramdisk"
    rm -rf "$rd"; mkdir -p "$rd"
    cp -a "${REPO_ROOT}/initramfs/." "$rd/"
    # /init должен быть исполняемым статическим busybox-скриптом
    chmod 755 "$rd/init"
    (cd "$rd" && find . | cpio -o -H newc --quiet | gzip -9) >"${OUT_DIR}/initramfs-deck.gz"
}

assemble_boot() {
    need_cmd mkbootimg
    local kernel="${BUILD_DIR}/kout/arch/arm64/boot/Image.gz"
    [[ -f "$kernel" ]] || die "нет $kernel — сборка ядра не удалась"
    log "сборка boot.img"
    mkbootimg \
        --kernel "$kernel" \
        --ramdisk "${OUT_DIR}/initramfs-deck.gz" \
        --dtb "${BUILD_DIR}/kout/vendor/qcom/proprietary/dtbs/blueline.dtb" \
        --pagesize 4096 \
        --header-version 3 \
        --os-version 12 --os-patch-level 2022-02-05 \
        --cmdline "androidboot.hardware=qcom androidboot.console=ttyMSM0 lpm_levels.sleep_disabled=1 service_locator.enable=1 swiotlb=1 androidboot.configfs=true firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7 kpti=off" \
        --output "${OUT_DIR}/boot.img"
    [[ -f "${OUT_DIR}/boot.img" ]] || die "mkbootimg не создал boot.img"
    log "boot.img готов ($(stat -c%s "${OUT_DIR}/boot.img") байт, лимит PART_BOOT_SIZE=${PART_BOOT_SIZE})"
    awk -v s="$(stat -c%s "${OUT_DIR}/boot.img")" -v lim="$PART_BOOT_SIZE" \
        'BEGIN{if(s>lim){printf "boot.img больше раздела на %d байт\n", s-lim; exit 1}}'
}

[[ -d "${KERNEL_DIR}/.git" || -f "${KERNEL_DIR}/Makefile" ]] || fetch_kernel
apply_patches
build_image
build_ramdisk
assemble_boot
log "готово: ${OUT_DIR}/boot.img"
