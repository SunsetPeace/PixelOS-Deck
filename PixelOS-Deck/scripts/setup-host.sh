#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Подготовка хоста: пакеты, udev-правила для fastboot/adb, модули ядра для
# сборки образов (loop, dm, erofs, f2fs) и qemu-user для arm64-шагов сборки.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $EUID -eq 0 ]] || die "запустите с sudo"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    android-sdk-platform-tools adbfastboot curl ca-certificates python3 rsync \
    build-essential git repo cpio device-tree-compiler lz4 zstd pxz liblz4-tool \
    erofs-utils f2fs-tools e2fsprogs dosfstools mtools squashfs-tools \
    qemu-user-static binfmt-support \
    aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ \
    clang lld llvm \
    libvulkan1 vulkan-tools meson ninja-build pkg-config \
    libdrm-dev libgbm-dev libegl1-mesa-dev libgles-dev libx11-dev \
    openjdk-17-jdk-headless docker.io

# Модули, без которых не смонтировать erofs/f2fs/squashfs loop-образы
for m in loop erofs f2fs dm_snapshot dm_verity overlay; do
    modprobe "$m" 2>/dev/null || warn "модуль $m не загрузился (на облачном ядре возможно)"
done
cat >/etc/modules-load.d/pixelos-deck.conf <<'EOF'
loop
erofs
f2fs
dm_snapshot
dm_verity
overlay
EOF

# udev: fastboot (Google 18d1:4ee0 / 18d1:d00d) и adb без sudo
cat >/etc/udev/rules.d/51-pixelos-deck.rules <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"
KERNEL=="ttyUSB*", ATTRS{idVendor}=="0525", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger --subsystem-match=usb || true

getent group plugdev >/dev/null || groupadd plugdev
usermod -aG plugdev,adbusers,docker "${SUDO_USER:-$USER}" 2>/dev/null || true

log "хост готов; перелогиньтесь, чтобы применились группы udev/docker"
