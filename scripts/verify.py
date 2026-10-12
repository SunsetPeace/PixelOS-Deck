#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Проверка «рабочести» прошивки.

Два режима:
  --offline   валидирует каркас сборки на хосте (конфиг, скрипты, overlay,
              recipes, синтаксис shell/python) — без устройства;
  --device    подключается к запущенной PixelOS-Deck через adb и проверяет,
              что система реально загрузилась в Steam-сессию: GPU-драйвер,
              devfreq, erofs rootfs, сессия, память.

Выход: 0 — всё зелёное, 1 — есть FAIL'ы, 2 — окружение не позволяет проверить.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GREEN, RED, YEL, END = "\x1b[32m", "\x1b[31m", "\x1b[33m", "\x1b[0m"

results = []
def check(name, ok, detail="", level="FAIL"):
    results.append((name, ok, detail))
    tag = f"{GREEN}PASS{END}" if ok else (f"{RED}{level}{END}")
    print(f"[{tag}] {name}" + (f" — {detail}" if detail else ""))
    return ok


# --------------------------- offline ---------------------------------------
def load_conf():
    """Парсит KEY=value из конфига: снимает inline-комментарии и вычисляет
    арифметику $((...)) через bash, чтобы PART_* стали числами."""
    path = REPO / "configs/blueline.conf"
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not re.match(r"^[A-Z_][A-Z0-9_]*=", stripped):
            continue
        # обрезаем комментарий вне кавычек/скобок (упрощённо: первый ' # ')
        parts = stripped.split(" # ", 1)
        value = parts[0]
        if value.endswith('"') and '"' in value[2:]:
            key, _, rest = value.partition("=")
            inner = rest.strip('"')
            value = f'{key}="{inner}"'
        lines.append(value)
    keys = [ln.split("=", 1)[0] for ln in lines]
    dump = "".join(f'printf "%s=%s\\n" "{k}" "${{{k}}}"\n' for k in keys)
    script = "\n".join(lines) + "\n" + dump
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    conf = {}
    for out_line in r.stdout.splitlines():
        k, _, v = out_line.partition("=")
        if re.match(r"^[A-Z_][A-Z0-9_]*$", k):
            conf[k] = v
    return conf


def offline_checks():
    conf = load_conf()
    check("configs/blueline.conf парсится", len(conf) > 20, f"{len(conf)} переменных")
    for key in ("PRODUCT_DEVICE", "GPU_ARCH", "PART_DECK_A_SIZE", "EROSFS_COMPRESS",
                "SESSION_UID", "DD_RUNTIME_DIR"):
        check(f"config: {key}", bool(conf.get(key)), conf.get(key, "ОТСУТСТВУЕТ"))

    # Каждая PART_* должна быть числом
    bad = [k for k, v in conf.items() if k.startswith("PART_") and not v.isdigit()]
    check("размеры разделов — целые числа", not bad, ",".join(bad))

    scripts = list((REPO / "scripts").glob("*.sh")) + list((REPO / "recipes").glob("*.sh"))
    missing_shebang = [s.name for s in scripts if not s.read_text().startswith("#!")]
    check("все .sh имеют shebang", not missing_shebang, str(missing_shebang))
    not_exec = [s.name for s in scripts if not os.access(s, os.X_OK)]
    check("скрипты исполняемые", not not_exec, str(not_exec))

    # bash -n на каждом скрипте
    syntax_fail = []
    for s in scripts:
        r = subprocess.run(["bash", "-n", str(s)], capture_output=True, text=True)
        if r.returncode != 0:
            syntax_fail.append(f"{s.name}: {r.stderr.strip().splitlines()[-1] if r.stderr else ''}")
    check("bash -n (синтаксис) всех скриптов", not syntax_fail, "; ".join(syntax_fail))

    init = REPO / "initramfs/init"
    r = subprocess.run(["sh", "-n", str(init)], capture_output=True, text=True)
    check("initramfs/init синтаксис", r.returncode == 0, r.stderr[:120])

    # Overlay: systemd unit'ы должны иметь [Unit]/[Service] или [Slice]/[Install]/[Target]
    units = list((REPO / "overlay/etc/systemd/system").iterdir())
    broken_units = [u.name for u in units if u.suffix in (".service", ".slice", ".target")
                    and not re.search(r"^\[(Unit|Service|Slice|Install|Target)\]", u.read_text(), re.M)]
    check("systemd-units валидны", not broken_units, str(broken_units))

    # Thermal guard: пороги blueline.conf отсортированы и лежат в безопасной полосе;
    # overlay-дефолты синхронизированы с конфигом (known-issues п.3 закрыт).
    th = {k[len("THERMAL_"):]: int(v) for k, v in conf.items()
          if k.startswith("THERMAL_")}
    order_ok = (th.get("WARN_CPU_M", 0) < th.get("HOT_CPU_M", 0) < th.get("CRIT_CPU_M", 10**9)
                and th.get("WARN_BATT_M", 0) < th.get("HOT_BATT_M", 0) < th.get("CRIT_BATT_M", 10**9)
                and th.get("WARN_GPU_M", 0) < th.get("HOT_GPU_M", 0) <= th.get("CRIT_CPU_M", 10**9))
    bounds_ok = all(0 < th[k] < 120000 for k in
                    ("WARN_CPU_M", "HOT_CPU_M", "CRIT_CPU_M", "WARN_BATT_M", "CRIT_BATT_M"))
    check("thermal-пороги отсортированы (warn<hot<crit)", order_ok and bounds_ok, str(th))
    defaults = REPO / "overlay/etc/default/deck-thermal"
    sync_bad = []
    if defaults.exists():
        dv = dict(re.findall(r"^([A-Z_]+)=(\d+)", defaults.read_text(), re.M))
        mapping = {"POLL_MS": "poll_ms", "HYST": "hysteresis_m", "STEP_PCT": "step_down_pct",
                   "MIN_BIG_PCT": "min_big_pct", "MIN_GPU_PCT": "min_gpu_pct",
                   "WARN_CPU": "warn_cpu_m", "HOT_CPU": "hot_cpu_m", "CRIT_CPU": "crit_cpu_m",
                   "WARN_GPU": "warn_gpu_m", "HOT_GPU": "hot_gpu_m",
                   "WARN_BATT": "warn_batt_m", "HOT_BATT": "hot_batt_m",
                   "CRIT_BATT": "crit_batt_m", "QUIET": "quiet_m", "PERF_OFF": "perf_offset_m",
                   "REARM_MARGIN": "rearm_margin_m"}
        for dkey, ckey in mapping.items():
            cv = conf.get(f"THERMAL_{ckey.upper()}")
            if cv is None or dv.get(dkey) != cv:
                sync_bad.append(dkey)
    else:
        sync_bad.append("overlay/etc/default/deck-thermal отсутствует")
    check("deck-thermal defaults синхронны с blueline.conf", not sync_bad, ",".join(sync_bad))
    tg = REPO / "overlay/usr/local/bin/deck-thermal-guard"
    r = subprocess.run(["sh", "-n", str(tg)], capture_output=True, text=True) if tg.exists() else None
    check("deck-thermal-guard: скрипт + unit + синтаксис",
          tg.exists() and os.access(tg, os.X_OK) and r is not None and r.returncode == 0
          and (REPO / "overlay/etc/systemd/system/deck-thermal-guard.service").exists(),
          r.stderr[:120] if r else "файл отсутствует")

    # Каждый recipe ссылается на ROOTFS (иначе укладка некуда)
    no_rootfs = [s.name for s in (REPO / "recipes").glob("*.sh")
                 if "ROOTFS" not in s.read_text()]
    check("recipes используют ROOTFS", not no_rootfs, str(no_rootfs))

    # ARM-кроссы: не ссылаемся ли мы случайно на SVE (запрещено для 845)
    sve_hits = []
    for p in (REPO / "arm-optimizations").rglob("*"):
        if p.is_file() and p.suffix in (".ini", ".cmake", ".conf", ".config"):
            txt = p.read_text(errors="ignore")
            if "+sve" in txt.lower().replace(" ", ""):
                sve_hits.append(p.name)
    check("нет +sve в флагах компиляции", not sve_hits, str(sve_hits))

    # README ссылается на существующие файлы
    readme = (REPO / "README.md").read_text(encoding="utf-8")
    dead_links = [l for l in re.findall(r"\]\((docs/[^)]+)\)", readme) if not (REPO / l).exists()]
    check("ссылки README живые", not dead_links, str(dead_links))


# --------------------------- device ----------------------------------------
def adb_serial(auto):
    if not auto:
        return os.environ.get("DECK_ADB_SERIAL", "")
    out = subprocess.run(["adb", "devices"], capture_output=True, text=True).stdout
    lines = [l.split("\t") for l in out.splitlines()[1:] if l.strip() and "\tdevice" in l]
    return lines[0][0] if lines else ""


def sh(serial, cmd):
    r = subprocess.run(["adb", "-s", serial, "shell", cmd],
                       capture_output=True, text=True, timeout=30)
    return r.returncode, (r.stdout + r.stderr).strip()


def device_checks(serial):
    rc, _ = sh(serial, "true")
    if rc != 0:
        check("adb доступен", False, "устройство не отвечает")
        return 2

    rc, out = sh(serial, "cat /proc/mounts | grep -c 'erofs.*ro'")
    check("rootfs смонтирован erofs ro", out.strip().startswith("1"), out[:60])

    rc, out = sh(serial, "getent group deck >/dev/null && echo yes")
    check("пользователь deck существует", out.strip() == "yes")

    rc, out = sh(serial, "ls /dev/kgsl-3d0 /dev/dri 2>/dev/null | head -1")
    check("GPU-узел виден", bool(out), out)

    rc, out = sh(serial, "vulkaninfo --summary 2>/dev/null | grep -o 'deviceName.*' | head -1")
    turnip = "Adreno (TM) 630" in out or "Turnip" in out or "A630" in out.upper()
    check("Vulkan: Turnip/A630 (не llvmpipe)", turnip, out[:80])

    rc, out = sh(serial, "systemctl is-active steamdeck-session.service")
    check("сессия Big Picture активна", out.strip() == "active", out)

    rc, out = sh(serial, "swapon --noheadings | grep -c zram")
    check("zram swap поднят", int(out or 0) >= 1, out)

    rc, out = sh(serial, "cat /sys/class/devfreq/*kgsl*/governor 2>/dev/null || cat /sys/class/kgsl/kgsl-3d0/gpuclk")
    check("GPU devfreq управляется", bool(out), out[:60])

    rc, out = sh(serial, "free -m | awk '/Mem/{print $2}'")
    try:
        check("RAM видна системе (~2048 MiB)", 1900 <= int(out) <= 2200, f"{out} MiB")
    except ValueError:
        check("RAM видна системе", False, out)

    rc, out = sh(serial, "test -x /opt/droiddeck/gamescope/bin/gamescope && echo ok")
    check("gamescope установлен", out.strip() == "ok")

    rc, out = sh(serial, "pgrep -f 'steam.*-bigpicture' >/dev/null && echo running")
    check("Steam процесс запущен", out.strip() == "running", out)

    rc, out = sh(serial, "/usr/local/bin/deck-thermal-guard test balanced 2>/dev/null | grep -c '='")
    try:
        check("deck-thermal-guard: tick работает на железе", int(out or 0) >= 6, f"{out} полей статуса")
    except ValueError:
        check("deck-thermal-guard: tick работает на железе", False, out[:60])

    rc, out = sh(serial, "systemctl is-active deck-thermal-guard.service")
    check("deck-thermal-guard.service активен", out.strip() == "active", out)

    rc, out = sh(serial, "cat /sys/class/thermal/thermal_zone*/type 2>/dev/null | head -3 | tr '\\n' ','")
    check("thermal zones видны", bool(out.strip(",")), out[:80])
    return 0 if all(ok for _, ok, _ in results) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--offline", action="store_true", help="проверить каркас сборки")
    mode.add_argument("--device", nargs="?", const="auto", default=None,
                      help="проверить устройство по adb (serial или auto)")
    args = ap.parse_args()

    if args.offline:
        offline_checks()
    else:
        serial = adb_serial(args.device == "auto")
        if not serial:
            print(f"{YEL}устройство не найдено{END}; используйте --offline или DECK_ADB_SERIAL")
            sys.exit(2)
        sys.exit(device_checks(serial))

    failed = [n for n, ok, _ in results if not ok]
    print(f"\n{len(results)-len(failed)}/{len(results)} проверок пройдено")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
