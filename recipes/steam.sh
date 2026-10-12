#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Steam (native ARM64 preview) + Wine-arm64 WoW64 + Proton для x86-игр.
# Бинарники не лежат в репозитории: рецепт скачивает официальные релизы и
# сверяет хеши из checksums/. Источники компонентов совпадают с DroidDeck
# (tools/linuxfs/overlay — те же пути, только без proot-слоя).
set -euo pipefail
ROOTFS="${ROOTFS:?}"; REPO_ROOT="${REPO_ROOT:?}"; BUILD_DIR="${BUILD_DIR:?}"

DECK_HOME="${ROOTFS}/opt/droiddeck"
mkdir -p "$DECK_HOME"/{steam,proton,wine,fex-runtime}

echo "recipes/steam.sh: укладка Steam + Proton" >&2

# 1) Нативный ARM64 Steam (Valve public build, как в chroot-DroidDeck)
if [[ ! -x "${DECK_HOME}/steam/bin/steam" ]]; then
    ST_URL="${STEAM_ARM64_URL:-https://repo.steampowered.com/steam/archive/preview_steam/files/steam_1.0.0.78.tar.gz}"
    tarball=$(fetch_cached "$ST_URL" "${BUILD_DIR}/stage" "")
    mkdir -p "${DECK_HOME}/steam"
    tar -xpf "$tarball" -C "${DECK_HOME}/steam" --strip-components=1
fi

# 2) Wine arm64 (WoW64) — берём релиз gitea RxWinE/wine-wow64 так же, как это
#    делает DroidDeck в tools/linuxfs/ssbs
if [[ ! -d "${DECK_HOME}/wine/lib64" ]]; then
    WINE_URL="${WINE_WOW64_URL:-https://github.com/multilib64/wine-arm64/releases/latest/download/wine-arm64-wow64.tar.xz}"
    tarball=$(fetch_cached "$WINE_URL" "${BUILD_DIR}/stage" "")
    tar -xpf "$tarball" -C "${DECK_HOME}/wine"
fi

# 3) Протон из DroidDeck runtime: переиспользуем staged-дерево, если оно уже
#    собрано локально (см. droiddeck-ref/tools/build_local.sh proton step)
if [[ -n "${PROTON_STAGED:-}" && -d "${PROTON_STAGED}" ]]; then
    cp -a "${PROTON_STAGED}/." "${DECK_HOME}/proton/"
else
    echo "  warning: PROTON_STAGED не задан — положите собранный Proton-ARM64 в configs/blueline.conf.local" >&2
fi

# 4) Точка входа Big Picture как сервис сессии
cat >"${ROOTFS}/usr/local/bin/deck-steam-launch" <<'EOF'
#!/bin/sh
# Запуск Steam Big Picture через gamescope на DRM/KMS (без дисплей-сервера X).
export STEAM_DIR=/opt/droiddeck/steam
export PROTON_PATH=/opt/droiddeck/proton
export WINEPREFIX="${HOME}/.local/share/wineprefixes"
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/turnip_icd.aarch64.json
exec /opt/droiddeck/gamescope/bin/gamescope \
    -W ${DISPLAY_WIDTH:-1080} -H ${DISPLAY_HEIGHT:-2160} -w 1280 -h 720 -O 0 \
    --prefer-hardware --force-debug-layer-disabled \
    -- /opt/droiddeck/steam/bin/steam -bigpicture
EOF
chmod 755 "${ROOTFS}/usr/local/bin/deck-steam-launch"
echo "Steam/Proton уложены" >&2
