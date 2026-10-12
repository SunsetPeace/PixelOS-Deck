#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Интеграционный тест deck-thermal-guard против ФЕЙКОВОГО sysfs (без root,
# без устройства). Guard поддерживает SYS_PREFIX именно для этого теста.
# Запуск: scripts/test-thermal-guard.sh  (выход 0 = все сценарии прошли)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
R="$(mktemp -d /tmp/tg-test.XXXXXX)"; trap 'rm -rf "$R"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert_eq() { local d=$1 e=$2 a=$3; if [ "$e" = "$a" ]; then ok "$d ($a)"; else bad "$d: ожидалось '$e', получено '$a'"; fi; }

mkdir -p "$R"/sys/class/thermal/thermal_zone{0,1,2} \
         "$R"/sys/devices/system/cpu/cpufreq/policy{0,4} \
         "$R"/sys/devices/system/cpu/cpu{0,1,2,3} \
         "$R/sys/class/devfreq/soc:qcom,gpu-ctx-bw" \
         "$R/sys/class/power_supply/battery" "$R/run" "$R/proc" "$R/etc/default"
echo cpu-cluster0 > "$R/sys/class/thermal/thermal_zone0/type"; echo 55000 > "$R/sys/class/thermal/thermal_zone0/temp"
echo cpu-cluster1 > "$R/sys/class/thermal/thermal_zone1/type"; echo 55000 > "$R/sys/class/thermal/thermal_zone1/temp"
echo a630_pwr     > "$R/sys/class/thermal/thermal_zone2/type"; echo 50000 > "$R/sys/class/thermal/thermal_zone2/temp"
for p in 0 4; do
    echo 2457600 > "$R/sys/devices/system/cpu/cpufreq/policy$p/cpuinfo_max_freq"
    echo "2457600 2284800 2092800 1920000 1771200 1555200 1363200 1248000" > "$R/sys/devices/system/cpu/cpufreq/policy$p/scaling_available_frequencies"
    echo 2457600 > "$R/sys/devices/system/cpu/cpufreq/policy$p/scaling_max_freq"
done
DF="$R/sys/class/devfreq/soc:qcom,gpu-ctx-bw"
echo "268800000 355200000 416000000 457600000 504000000 588000000 624000000 653000000 710000000" > "$DF/available_frequencies"
echo 710000000 > "$DF/max_freq"; echo 268800000 > "$DF/min_freq"
echo 30000 > "$R/sys/class/power_supply/battery/temp"
echo USB > "$R/sys/class/power_supply/battery/charge_type"
echo unlimited > "$R/sys/class/power_supply/battery/input_current_limit"
for c in 0 1 2 3; do echo 1 > "$R/sys/devices/system/cpu/cpu$c/online"; done
touch "$R/proc/sysrq-trigger"

TG="SYS_PREFIX=$R sh $REPO/overlay/usr/local/bin/deck-thermal-guard"
cpu_big() { cat "$R/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"; }
gpu_max() { cat "$DF/max_freq"; }
stage()   { sed -n 's/^stage=//p' "$R/run/deck-thermal-guard.status"; }
preset()  { sed -n 's/^preset=//p' "$R/run/deck-thermal-guard.status"; }
set_cpu() { echo "$1" > "$R/sys/class/thermal/thermal_zone1/temp"; }
set_batt(){ echo "$1" > "$R/sys/class/power_supply/battery/temp"; }

echo "== сценарий 1: холодный старт -> stage 0, потолки не тронуты"
$TG test balanced >/dev/null 2>&1
assert_eq "stage" 0 "$(stage)"; assert_eq "big ceiling" 2457600 "$(cpu_big)"; assert_eq "gpu ceiling" 710000000 "$(gpu_max)"

echo "== сценарий 2: CPU 80000 (warn 78000) -> stage 1, ceiling квантован по шагам"
set_cpu 80000
$TG test balanced >/dev/null 2>&1
assert_eq "stage" 1 "$(stage)"; assert_eq "big ceiling (2211840->ближайший шаг)" 1920000 "$(cpu_big)"
assert_eq "gpu ceiling (639000000->шаг)" 624000000 "$(gpu_max)"

echo "== сценарий 3: CPU 90000 (hot 88000) -> stage 2 (-2*STEP%)"
set_cpu 90000
$TG test balanced >/dev/null 2>&1
assert_eq "stage" 2 "$(stage)"; assert_eq "big ceiling" 1771200 "$(cpu_big)"

echo "== сценарий 4: CPU 96000 (crit 95000) -> stage 3 + offline little"
set_cpu 96000
$TG test balanced >/dev/null 2>&1
assert_eq "stage" 3 "$(stage)"
ONL=$(cat "$R/sys/devices/system/cpu/cpu0/online")
assert_eq "cpu0 online" 0 "$ONL"
assert_eq "big floor 40%" 983040 "$(sed -n 's/^big_khz=//p' "$R/run/deck-thermal-guard.status")"

echo "== сценарий 5: остывание до 50000 (< QUIET) -> полный сброс, little снова online"
set_cpu 50000; set_batt 30000
$TG test balanced >/dev/null 2>&1
assert_eq "stage" 0 "$(stage)"
assert_eq "cpu0 online восстановлен" 1 "$(cat "$R/sys/devices/system/cpu/cpu0/online")"
assert_eq "big ceiling восстановлен" 2457600 "$(cpu_big)"; assert_eq "gpu восстановлен" 710000000 "$(gpu_max)"
assert_eq "зарядка unlimited" unlimited "$(cat "$R/sys/class/power_supply/battery/input_current_limit")"

echo "== сценарий 6: пресеты производительности"
$TG set-preset performance >/dev/null 2>&1
assert_eq "preset в run-файле" performance "$(cat "$R/run/deck-thermal-guard.preset")"
set_cpu 79000   # ниже warn+offset(81000): performance НЕ должен троттлить там, где balanced уже режет
$TG test performance >/dev/null 2>&1
assert_eq "performance: stage при 79000" 0 "$(stage)"
set_cpu 82000   # выше 78000+3000
$TG test performance >/dev/null 2>&1
assert_eq "performance: stage при 82000" 1 "$(stage)"
assert_eq "performance: ceiling +HYST квантован" 2284800 "$(cpu_big)"
$TG set-preset powersave >/dev/null 2>&1
set_cpu 55000
$TG test powersave >/dev/null 2>&1
assert_eq "powersave: ранний троттлинг (ceiling-HYST)" 2284800 "$(cpu_big)"
$TG set-preset balanced >/dev/null 2>&1

echo "== сценарий 7: батарея — критический перегрев ограничивает зарядку, shutdown-запрос"
set_cpu 50000; set_batt 56000   # >= CRIT_BATT 55000
$TG test balanced >/dev/null 2>&1
assert_eq "stage от батареи" 3 "$(stage)"
assert_eq "input_current_limit" 500 "$(cat "$R/sys/class/power_supply/battery/input_current_limit")"
set_batt 60000                  # >= CRIT+HYST -> sysrq emergency
$TG test balanced >/dev/null 2>&1
assert_eq "sysrq power запрошен" b "$(cat "$R/proc/sysrq-trigger")"
set_batt 30000; $TG test balanced >/dev/null 2>&1   # возврат к норме

echo "== сценарий 8: daemon start/status/stop (PID-файл, восстановление потолков)"
$TG start >/dev/null 2>&1
sleep 0.3
$TG status >/dev/null 2>&1 && ok "status=active" || bad "status inactive"
[ -s "$R/run/deck-thermal-guard.pid" ] && ok "pid-файл создан" || bad "pid-файл пуст"
$TG stop >/dev/null 2>&1
assert_eq "после stop: big ceiling" 2457600 "$(cpu_big)"
! $TG status >/dev/null 2>&1 && ok "status=inactive после stop" || bad "демон не остановился"

echo
echo "ИТОГ: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
