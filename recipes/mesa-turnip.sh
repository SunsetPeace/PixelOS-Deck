#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Сборка Mesa с драйвером Turnip (freedreno a6xx) для aarch64 + укладка в rootfs.
# Это ядро всей графики: без него композитинг падает на llvmpipe (как в
# desktop-режиме DroidDeck). Собираем из upstream Mesa с нашим meson-кроссом,
# оптимизированным под ARM (см. arm-optimizations/meson-aarch64-turnip.ini).
set -euo pipefail
ROOTFS="${ROOTFS:?}"; REPO_ROOT="${REPO_ROOT:?}"; BUILD_DIR="${BUILD_DIR:?}"

echo "recipes/mesa-turnip.sh: сборка Mesa/Turnip" >&2
SRC="${BUILD_DIR}/src/mesa"
[[ -d "$SRC" ]] || git clone --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git "$SRC"

meson setup "${SRC}/build" \
    --cross-file "${REPO_ROOT}/arm-optimizations/meson-aarch64-turnip.ini" \
    -Dgallium-drivers=freedreno,v3d,swrast \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kgsl=true \
    -Dtools=turnip,freedreno \
    -Dplatforms=x11,wayland,gbm \
    -Dglx=dri -Degl=enabled -Dgbm=enabled -Dllvm=false \
    -Dbuildtype=release -Db_ndebug=true -Dcpp_rtti=false || die "meson setup не удался"
ninja -C "${SRC}/build" -j"$(nproc)"
DESTDIR="$ROOTFS" meson install -C "${SRC}/build"

# Разрешаем turnip работать через KGSL-узел Pixel 3 (ядро 4.9 отдаёт /dev/kgsl-3d0;
# на GKI-6.6 — /dev/dri/renderD*, оба варианта поддержаны флагом freedreno-kgsl)
mkdir -p "${ROOTFS}/etc/ld.so.conf.d"
echo "/usr/lib" >"${ROOTFS}/etc/ld.so.conf.d/mesa-turnip.conf"

cat >"${ROOTFS}/etc/profile.d/deck-turnip.sh" <<'EOF'
# Turnip на a630: DXVK 2 требует отключения 8-bit storage (нет в gen7)
export TU_DEBUG=${TU_DEBUG:-noubmc,nosched}
export RADV_PERFTEST=""
export MESA_GL_VERSION_OVERRIDE="4.6"
export MESA_GLSL_VERSION_OVERRIDE="460"
EOF
echo "Mesa/Turnip уложена" >&2
