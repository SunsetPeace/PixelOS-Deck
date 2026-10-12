#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Общие утилиты для всех скриптов сборки.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33mwarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "не найдена команда '$1'; выполните scripts/setup-host.sh"
}

# Загружает configs/<device>.conf и, если есть, configs/<device>.conf.local
# (локальные пути к SDK / factory-архиву, не коммитится).
load_config() {
    local device="${1:-${TARGET_DEVICE:-blueline}}"
    local conf="${REPO_ROOT}/configs/${device}.conf"
    [[ -f "$conf" ]] || die "нет конфига устройства: $conf"
    # shellcheck disable=SC1090
    source "$conf"
    if [[ -f "${REPO_ROOT}/configs/${device}.conf.local" ]]; then
        # shellcheck disable=SC1090
        source "${REPO_ROOT}/configs/${device}.conf.local"
    fi
    export TARGET_DEVICE="$device"
    BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build/${device}}"
    OUT_DIR="${OUT_DIR:-${BUILD_DIR}/out}"
    mkdir -p "$OUT_DIR"
    export BUILD_DIR OUT_DIR
}

# Кэшированная загрузка с проверкой sha256. Файл считается валидным, если
# лежит в cache/ рядом с записью .sha256 — повторные сборки не качают.
fetch_cached() {
    local url="$1" dest_dir="$2" expected_sha="$3" name
    name="$(basename -- "${url%%\?*}")"
    local cache="${CACHE_DIR:-${REPO_ROOT}/cache}"
    mkdir -p "$cache" "$dest_dir"
    local target="${cache}/${name}"
    if [[ ! -f "$target" ]]; then
        log "загрузка ${url}"
        curl -fL --retry 3 --retry-delay 2 -o "${target}.part" "$url"
        mv "${target}.part" "$target"
    fi
    if [[ -n "$expected_sha" && "$expected_sha" != *placeholder* ]]; then
        local actual
        actual="$(sha256sum "$target" | cut -d' ' -f1)"
        [[ "$actual" == "$expected_sha" ]] || die "sha256 не совпал для ${name}: ${actual} != ${expected_sha}"
    else
        warn "для ${name} нет подтверждённого sha256 — заполните checksums/${name}.sha256"
    fi
    cp -f "$target" "${dest_dir}/${name}"
    printf '%s\n' "${dest_dir}/${name}"
}

run_qemu_or_native() {
    # Выполняет arm64-бинарь на хосте: нативно на aarch64 или через qemu-user-static.
    if [[ "$(uname -m)" == "aarch64" ]]; then
        "$@"
    else
        need_cmd qemu-aarch64-static
        qemu-aarch64-static -L "${ARCH_ROOTFS:-$BUILD_DIR/rootfs}" "$@"
    fi
}
