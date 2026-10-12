#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# FEXCore (x86->ARM64 динамический транслятор) в нативном rootfs.
# В DroidDeck FEX лежит в linuxfs/fex и запускается внутри bwrap; здесь он
# системный пакет + наш wrapper с профилями под a630 (SVE выключен, 845 его
# не имеет; включены LSE atomics и AES/PWM — есть в armv8.2-a).
set -euo pipefail
ROOTFS="${ROOTFS:?}"; REPO_ROOT="${REPO_ROOT:?}"; BUILD_DIR="${BUILD_DIR:?}"

echo "recipes/fex.sh: установка FEX" >&2
if command -v qemu-aarch64-static >/dev/null || [[ "$(uname -m)" == aarch64 ]]; then
    chroot "$ROOTFS" pacman -S --noconfirm --needed fex >= 0 2>/dev/null || \
        echo "  пакет fex недоступен в зеркале — соберу из git" >&2
fi

if [[ ! -e "${ROOTFS}/usr/bin/FEXLoader" ]]; then
    SRC="${BUILD_DIR}/src/FEX"
    [[ -d "$SRC" ]] || git clone --recursive https://github.com/FEX-Emu/FEX.git "$SRC"
    cmake -S "$SRC" -B "${SRC}/build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="${REPO_ROOT}/arm-optimizations/toolchain-aarch64.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_JITSYMBOLS=ON -DBUILD_TESTS=OFF -DENABLE_VIXL_SIMULATOR=OFF
    cmake --build "${SRC}/build" -j"$(nproc)"
    DESTDIR="$ROOTFS" cmake --install "${SRC}/build"
fi

# Профиль under msm8998: без SVE/SVE2, с LSE/AES/SHA/PMULL
mkdir -p "${ROOTFS}/etc/fex"
cat >"${ROOTFS}/etc/fex/a630.json" <<'EOF'
{
  "Core": "ironside",
  "MARCH": "ARMV8_2",
  "TSOEnabled": true,
  "SVEEnabled": false,
  "SVELength": 0,
  "ABITerminologyOptimizations": true,
  "HostFeatures": ["lse", "aes", "pmull", "sha1", "sha2", "crc", "fp16"],
  "SMCCalls": "faultpage",
  "MaxInst": 0,
  "CacheObjectCodeSizeMegabytes": "256",
  "UnifiedCache": true,
  "ConstantPools": true
}
EOF

cat >"${ROOTFS}/usr/local/bin/deck-fex" <<'EOF'
#!/bin/sh
# Единая точка входа для x86-эмуляции в Steam: deck-fex <бинарь> [args]
exec /usr/bin/FEXLoader -c /etc/fex/a630.json --rootfs / "$@"
EOF
chmod 755 "${ROOTFS}/usr/local/bin/deck-fex"
echo "FEX уложен" >&2
