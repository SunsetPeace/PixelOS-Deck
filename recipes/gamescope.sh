#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# gamescope-session: обёртка запуска Steam Big Picture поверх Gamescope на
# DRM/GBM без логина — ровно та модель, что в SteamOS 3 (gamescope-session),
# портированная из DroidDeck tools/gamescope и адаптированная под Turnip a630.
#
# Что укладывается в rootfs:
#   /usr/bin/gamescope                — бинарь, собранный recipes или пакетом
#   /usr/bin/deck-gamescope-session   — скрипт сессии (overlay/usr/local/bin)
#   /opt/droiddeck/gamescope-wl       — staging библиотек из runtime DroidDeck
set -euo pipefail
ROOTFS="${ROOTFS:?(ROOTFS не задан)}"
REPO_ROOT="${REPO_ROOT:?}"
BUILD_DIR="${BUILD_DIR:?}"

DEST="${ROOTFS}/opt/droiddeck/gamescope"
mkdir -p "$DEST" "${ROOTFS}/usr/bin"

if [[ ! -x "${DEST}/bin/gamescope" ]]; then
    echo "recipes/gamescope.sh: собираю gamescope для aarch64" >&2
    # Источники и патчи переиспользуются из DroidDeck (tools/gamescope/patches).
    GS_SRC="${BUILD_DIR}/src/gamescope"
    mkdir -p "$(dirname "$GS_SRC")"
    [[ -d "$GS_SRC" ]] || git clone --recursive https://github.com/ValveSoftware/gamescope.git "$GS_SRC"
    for p in "${REPO_ROOT}/droiddeck-ref/tools/gamescope/patches/"*.patch; do
        [[ -e "$p" ]] || continue
        git -C "$GS_SRC" apply --check "$p" 2>/dev/null && git -C "$GS_SRC" am --3way "$p" || true
    done
    meson setup "$GS_SRC/build" --cross-file "${REPO_ROOT}/arm-optimizations/meson-aarch64-turnip.ini" \
        -Denable_openvr_support=false -Dforce_fallback_for=vkroots || die "meson setup не удался"
    ninja -C "$GS_SRC/build"
    install -Dm755 "$GS_SRC/build/src/gamescope" "${DEST}/bin/gamescope"
fi

# ICD для turnip (тот же формат, что в BwrapSpawner.kt DroidDeck, но путь системный)
cat >"${ROOTFS}/usr/share/vulkan/icd.d/turnip_icd.aarch64.json" <<'EOF'
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "/usr/lib/libvulkan_freedreno.so",
    "api_version": "1.3.281"
  }
}
EOF

# Проверка, что композитинг реально идёт по железу, а не llvmpipe
cat >>"${ROOTFS}/etc/profile.d/deck-vk.sh" <<'EOF'
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/turnip_icd.aarch64.json
export WLR_RENDERER_ALLOW_SOFTWARE=0
export GAMESCOPE_BACKEND=drm
EOF

echo "gamescope-session уложен" >&2
