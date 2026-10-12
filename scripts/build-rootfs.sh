#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Сборка targetfs: базовый Arch Linux ARM (aarch64) + компоненты DroidDeck,
# перенесённые из APK-runtime в нативную систему, упакованные в erofs-образ.
#
# Этапы:
#   1) базовый rootfs из bootstrap-тарбола (pacman --arch aarch64 на хосте
#      через qemu-user, либо нативно на aarch64-хосте);
#   2) установка пакетов окружения (systemd, plasma-wayland, mesa-turnip...);
#   3) сборка и укладка компонентов из recipes/ (gamescope-session, fex,
#      wine-wow64, steam-launcher);
#   4) наложение overlay/etc + overlay/usr;
#   5) mkfs.erofs со сжатием lz4hc.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${TARGET_DEVICE:-blueline}"

ROOTFS="${BUILD_DIR}/rootfs"
STAGE="${BUILD_DIR}/stage"
ARCH_ROOTFS="$ROOTFS"; export ARCH_ROOTFS

step() { log "[$(basename "$0")] $*"; }

bootstrap_rootfs() {
    need_cmd curl tar sha256sum
    [[ -f "${ROOTFS}/bin/sh" ]] && { step "rootfs уже распакован — пропускаю"; return; }
    mkdir -p "$ROOTFS" "$STAGE"
    local tarball
    tarball=$(fetch_cached "$ARCH_ARM_ROOTFS_URL" "$STAGE" "")
    step "распаковка базовой системы"
    tar -xpf "$tarball" -C "$ROOTFS" \
        --exclude='./var/cache/pacman/pkg/*' || die "не удалось распаковать rootfs"
    # Ключи archlinuxarm
    rm -rf "${ROOTFS}/etc/pacman.d/gnupg"
    run_qemu_or_native chroot "$ROOTFS" pacman-key --init
    run_qemu_or_native chroot "$ROOTFS" pacman-key --populate archlinuxarm
}

install_base_packages() {
    local pkgs=(
        systemd linux-aarch64 base base-devel networkmanager bluez
        plasma-desktop plasma-workspace wayland kwin xorg-server-xwayland
        mesa vulkan-tools vulkan-icd-loader lib32-mesa
        pipewire wireplumber pulseaudio-utils
        gamemode game-mode-daemon sdl2 gamecontrollerdb
        gtk3 qt6-base qt6-wayland
        zram-generator iotop htop strace
        flatpak btrfs-progs f2fs-tools e2fsprogs dosfstools
    )
    step "установка ${#pkgs[@]} пакетов (qemu-user или нативно)"
    run_qemu_or_native chroot "$ROOTFS" \
        pacman -Syu --noconfirm --needed "${pkgs[@]}"
}

build_components() {
    for r in "${REPO_ROOT}/recipes/"*.sh; do
        [[ -x "$r" ]] || continue
        step "компонент: $(basename "$r")"
        ROOTFS="$ROOTFS" REPO_ROOT="$REPO_ROOT" BUILD_DIR="$BUILD_DIR" bash "$r"
    done
}

apply_overlay() {
    step "наложение overlay/ (конфиги, systemd-units, udev, скрипты)"
    cp -a "${REPO_ROOT}/overlay/." "$ROOTFS/"
    # Пользователь deck и группы доступа к GPU/input
    cat >>"$ROOTFS/etc/group" <<EOF
video:x:27:deck
render:x:986:deck
input:x:999:deck
EOF
    echo "deck ALL=(ALL) NOPASSWD: /usr/local/bin/deckctl" >>"$ROOTFS/etc/sudoers.d/deck"
    chmod 440 "$ROOTFS/etc/sudoers.d/deck"
    ln -sf /usr/lib/systemd/system/multi-user.target.wants/steamdeck-session.service \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/steamdeck-session.service" 2>/dev/null || true
}

make_image() {
    need_cmd mkfs.erofs
    local slot="${DECK_SLOT:-a}"
    local img="${OUT_DIR}/steamdeck_${slot}.img"
    step "упаковка erofs (${EROSFS_COMPRESS}, cluster=${EROSFS_CLUSTER})"
    # erofs read-only: /var и /home остаются на отдельном rw-разделе (home),
    # поэтому state-директории делаем tmpfs/bind через overlay systemd-юниты.
    mkfs.erofs -z"${EROSFS_COMPRESS}" -T 0 -U "$(uuidgen 2>/dev/null || echo 00000000-deck-0000-0000-00000000000${slot})" \
        --chunk-cluster-size="${EROSFS_CLUSTER}" \
        "$img" "$ROOTFS"
    local size; size=$(stat -c%s "$img")
    local lim="PART_DECK_${slot^^}_SIZE"
    (( size < ${!lim} )) || die "steamdeck_${slot}.img (${size}) больше раздела ${!lim}"
    step "готово: $img (${size} байт, лимит ${!lim})"
}

case "${1:-all}" in
    bootstrap)   bootstrap_rootfs ;;
    packages)    install_base_packages ;;
    components)  build_components ;;
    overlay)     apply_overlay ;;
    image)       make_image ;;
    all)         bootstrap_rootfs; install_base_packages; build_components; apply_overlay; make_image ;;
    *)           die "usage: $0 [bootstrap|packages|components|overlay|image|all]" ;;
esac
