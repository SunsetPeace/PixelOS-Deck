#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Интеграционный тест deck-thermal-guard против ФЕЙКОВОГО sysfs (без root,
# без устройства). Guard поддерживает SYS_PREFIX именно для этого теста.
# Запуск: scripts/test-thermal-guard.sh  (выход 0 = все сценарии прошли)
set -u
INTERP="${TG_INTERP:-$(command -v bash || echo sh)}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
R="$(mktemp -d /tmp/tg-test.XXXXXX)"
trap 'rm -rf "$R"' EXIT
TG_REPO="$REPO" TG_R="$R" TG_INTERP_SUB="$INTERP" "$INTERP" - <<'TESTEOF'
PASS=0; FAIL=0
# R и REPO наследуются из окружения родителя (quoted-here-doc)
R="${TG_R:?}"; REPO="${TG_REPO:?}"

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert_eq() { local d=$1 e=$2 a=$3; if [ "$e" = "$a" ]; then ok "$d ($a)"; else bad "$d: ожидалось '$e', получено '$a'"; fi; }

# ВАЖНО: brace-expansion ({0,1,2}) в dash НЕ поддерживается — список каталогов
# разворачиваем явно (тест обязан проходить и под TG_INTERP=dash).
for z in 0 1 2; do mkdir -p "$R/sys/class/thermal/thermal_zone$z"; done
for p in 0 4; do mkdir -p "$R/sys/devices/system/cpu/cpufreq/policy$p"; done
for c in 0 1 2 3; do mkdir -p "$R/sys/devices/system/cpu/cpu$c"; done
mkdir -p "$R/sys/class/devfreq/soc:qcom,gpu-ctx-bw" \
         "$R/sys/class/power_supply/battery" "$R/run" "$R/proc" "$R/etc/default"
echo cpu-cluster0 > "$R/sys/class/thermal/thermal_zone0/type"; echo 55000 > "$R/sys/class/thermal/thermal_zone0/temp"
echo cpu-cluster1 > "$R/sys/class/thermal/thermal_zone1/type"; echo 55000 > "$R/sys/class/thermal/thermal_zone1/temp"
echo a630_pwr     > "$R/sys/class/thermal/thermal_zone2/type"; echo 50000 > "$R/sys/class/thermal/thermal_zone2/temp"
# реальные OPP-шаги SD845/blueline: little policy0 до 1771200, big policy4 до 2457600
echo 1771200 > "$R/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq"
echo 2457600 > "$R/sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq"
echo "300000 403200 499200 576000 672000 748800 844800 940800 1036800 1113600 1209600 1305600 1382400 1478400 1555200 1632000 1713600 1771200" > "$R/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies"
echo "825600 844800 960000 979200 1094400 1209600 1324800 1440000 1555200 1670400 1785600 1900800 1920000 2092800 2284800 2457600" > "$R/sys/devices/system/cpu/cpufreq/policy4/scaling_available_frequencies"
echo 1771200 > "$R/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
echo 2457600 > "$R/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"
DF="$R/sys/class/devfreq/soc:qcom,gpu-ctx-bw"
echo "268800000 355200000 416000000 457600000 504000000 588000000 624000000 653000000 710000000" > "$DF/available_frequencies"
echo 710000000 > "$DF/max_freq"; echo 268800000 > "$DF/min_freq"
echo 30000 > "$R/sys/class/power_supply/battery/temp"
echo USB > "$R/sys/class/power_supply/battery/charge_type"
echo unlimited > "$R/sys/class/power_supply/battery/input_current_limit"
for c in 0 1 2 3; do echo 1 > "$R/sys/devices/system/cpu/cpu$c/online"; done
touch "$R/proc/sysrq-trigger"

GUARD="$REPO/overlay/usr/local/bin/deck-thermal-guard"
# Конфиг для guard'а генерируется ИЗ configs/blueline.conf (секция THERMAL_*) —
# тест проверяет реальные пороги проекта, а не хардкод. Guard читает TG_CONF.
awk '/^THERMAL_/{split($1,a,"="); sub(/^THERMAL_/,"",a[1]); print a[1]"="a[2]}' \
    "$REPO/configs/blueline.conf" | sed -e 's/_M=/=/' > "$R/etc/default/deck-thermal"
export TG_CONF="$R/etc/default/deck-thermal"
grep -q '^WARN_CPU=' "$TG_CONF" || { echo "FATAL: не удалось извлечь THERMAL_* из blueline.conf"; exit 1; }
# ВАЖНО: префикс окружения внутри строковой переменной НЕ раскрывается как
# env-присвоение при unquoted-$ разворачивании — экспорт глобально + функции-обёртки.
export SYS_PREFIX="$R"
INTERP_INNER="${TG_INTERP_SUB:-$(command -v bash || echo sh)}"
run_guard()  { "$INTERP_INNER" "$GUARD" "$@"; }
echo "интерпретатор теста: $INTERP_INNER"
cpu_big() { cat "$R/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"; }
gpu_max() { cat "$DF/max_freq"; }
stage()   { sed -n 's/^stage=//p' "$R/run/deck-thermal-guard.status"; }
set_cpu() { echo "$1" > "$R/sys/class/thermal/thermal_zone1/temp"; }
set_batt(){ echo "$1" > "$R/sys/class/power_supply/battery/temp"; }

echo "== сценарий 1: холодный старт -> stage 0, потолки не тронуты"
run_guard test balanced >/dev/null 2>&1
assert_eq "stage" 0 "$(stage)"; assert_eq "big ceiling" 2457600 "$(cpu_big)"; assert_eq "gpu ceiling" 710000000 "$(gpu_max)"

echo "== сценарий 2: CPU 80000 (warn 78000) -> stage 1, ceiling квантован по OPP-шагам"
set_cpu 80000
run_guard test balanced >/dev/null 2>&1
# big: 2457600*90% = 2211840 -> ближайший OPP <= target = 2092800
assert_eq "stage" 1 "$(stage)"; assert_eq "big ceiling (2211840->OPP)" 2092800 "$(cpu_big)"
# gpu: 710000000*90% = 639000000 -> шаг devfreq 624000000
assert_eq "gpu ceiling (639000000->шаг)" 624000000 "$(gpu_max)"

echo "== сценарий 3: CPU 90000 (hot 88000) -> stage 2 (-2*STEP%)"
set_cpu 90000
run_guard test balanced >/dev/null 2>&1
# big: 2457600*80% = 1966080 -> OPP 1920000
assert_eq "stage" 2 "$(stage)"; assert_eq "big ceiling" 1920000 "$(cpu_big)"

echo "== сценарий 4: CPU 96000 (crit 95000) -> stage 3 + offline little"
set_cpu 96000
run_guard test balanced >/dev/null 2>&1
assert_eq "stage" 3 "$(stage)"
ONL=$(cat "$R/sys/devices/system/cpu/cpu0/online")
assert_eq "cpu0 online" 0 "$ONL"
# floor: 2457600*40% = 983040 -> ближайший OPP <= = 979200
assert_eq "big floor 40%" 979200 "$(sed -n 's/^big_khz=//p' "$R/run/deck-thermal-guard.status")"

echo "== сценарий 5: остывание до 40000 (< QUIET) -> сброс ступеней (REARM: не быстрее 1/тик)"
# ВАЖНО: cmd_test восстанавливает STAGE из STATUS_FILE (эмуляция долгоживущего
# демона), поэтому каждый запуск = ровно ОДИН тик; счётчик тиков не передаём.
set_cpu 40000; set_batt 30000   # zone0 остаётся на 55000 — ниже QUIET, но выше warn+batt-полос
run_guard test balanced >/dev/null 2>&1  # тик 1: stage 3 -> 2 (все датчики < HOT+MARGIN)
assert_eq "REARM tick1: stage 2" 2 "$(stage)"
run_guard test balanced >/dev/null 2>&1  # тик 2: stage 2 -> 1 (все датчики < WARN+MARGIN)
assert_eq "REARM tick2: stage 1" 1 "$(stage)"
run_guard test balanced >/dev/null 2>&1  # тик 3: stage 1 -> 0, полный сброс актуаторов
assert_eq "REARM tick3: stage 0" 0 "$(stage)"
assert_eq "cpu0 online восстановлен" 1 "$(cat "$R/sys/devices/system/cpu/cpu0/online")"
assert_eq "big ceiling восстановлен" 2457600 "$(cpu_big)"; assert_eq "gpu восстановлен" 710000000 "$(gpu_max)"
assert_eq "зарядка unlimited" unlimited "$(cat "$R/sys/class/power_supply/battery/input_current_limit")"

echo "== сценарий 6: пресеты производительности"
run_guard set-preset performance >/dev/null 2>&1
assert_eq "preset в run-файле" performance "$(cat "$R/run/deck-thermal-guard.preset")"
set_cpu 79000   # ниже warn+offset(81000): performance НЕ должен троттлить там, где balanced уже режет
TG_PRESET_OVERRIDE=1 run_guard test performance >/dev/null 2>&1
assert_eq "performance: stage при 79000" 0 "$(stage)"
set_cpu 82000   # выше 78000+3000
TG_PRESET_OVERRIDE=1 run_guard test performance >/dev/null 2>&1
assert_eq "performance: stage при 82000" 1 "$(stage)"
# stage1 + CEIL_ADJ(+HYST): floor = 2457600*90%+3000 = 2214840 -> ближайший OPP <= = 2092800
assert_eq "performance: ceiling квантован (2214840->OPP)" 2092800 "$(cpu_big)"
run_guard set-preset powersave >/dev/null 2>&1
set_cpu 55000   # powersave: warn/hot -PERF_OFF => warn=75000; 55000 < warn -> stage 0
TG_PRESET_OVERRIDE=1 run_guard test powersave >/dev/null 2>&1
assert_eq "powersave: stage при 55000" 0 "$(stage)"
# stage0 ceiling = max + CEIL_ADJ(-2*HYST=-6000) = 2451600 -> ближайший OPP <= = 2284800.
# Запускаем С НУЛЯ (fresh STAGE=0): в cmd_test переход 0->0 не вызывает apply, поэтому
# греем до stage1 и остужаем — REARM-тик применяет powersave-ceiling.
run_guard test powersave >/dev/null 2>&1   # 1 тик: STAGE=0, cpu=55000 -> остаётся 0
assert_eq "powersave: fresh stage при 55000" 0 "$(stage)"
set_cpu 76000   # выше warn-PERF_OFF(75000) -> stage 1
TG_PRESET_OVERRIDE=1 run_guard test powersave >/dev/null 2>&1
assert_eq "powersave: ранний stage 1 при 76000" 1 "$(stage)"
set_cpu 55000   # остывание: REARM 1->0, потолок = snap(2451600)=2284800
TG_PRESET_OVERRIDE=1 run_guard test powersave >/dev/null 2>&1
assert_eq "powersave: ранний троттлинг (2451600->OPP)" 2284800 "$(cpu_big)"
run_guard set-preset quiet >/dev/null 2>&1
set_cpu 76000
TG_PRESET_OVERRIDE=1 run_guard test quiet >/dev/null 2>&1    # quiet: warn=75000 -> stage 1
set_cpu 55000
TG_PRESET_OVERRIDE=1 run_guard test quiet >/dev/null 2>&1    # REARM -> ceiling как powersave
assert_eq "quiet: ceiling как powersave" 2284800 "$(cpu_big)"
run_guard set-preset balanced >/dev/null 2>&1

echo "== сценарий 7: батарея — критический перегрев ограничивает зарядку, shutdown-запрос"
set_cpu 50000; set_batt 30000
run_guard test balanced >/dev/null 2>&1   # сброс ступеней перед сценарием
assert_eq "предусловие: stage 0" 0 "$(stage)"
set_batt 56000   # >= CRIT_BATT 55000
run_guard test balanced >/dev/null 2>&1
assert_eq "stage от батареи" 3 "$(stage)"
assert_eq "input_current_limit" 500 "$(cat "$R/sys/class/power_supply/battery/input_current_limit")"
set_batt 60000                  # >= CRIT+HYST -> sysrq emergency
run_guard test balanced >/dev/null 2>&1
assert_eq "sysrq power запрошен" b "$(cat "$R/proc/sysrq-trigger")"
set_batt 30000; run_guard test balanced >/dev/null 2>&1   # возврат к норме: REARM 3->2 (один тик)
run_guard test balanced >/dev/null 2>&1                    # REARM 2->1
run_guard test balanced >/dev/null 2>&1                    # REARM 1->0 (zone0=55000 < QUIET-HYST)
assert_eq "сценарий 7: полный возврат к stage 0" 0 "$(stage)"

echo "== сценарий 8: daemon start/status/stop (PID-файл, восстановление потолков)"
# POLL_MS=2000 из конфига -> тик каждые 2 с. Демон наследует PRESET_FILE от
# предыдущих сценариев — фиксируем balanced явно, иначе пороги поедут.
run_guard set-preset balanced >/dev/null 2>&1
( sleep 2.5; echo 96000 > "$R/sys/class/thermal/thermal_zone1/temp" ) & SLOWER=$!
run_guard start </dev/null >/dev/null 2>&1   # stdin=/dev/null: демон не висит на терминале
# cmd_start делает sleep 0.2 и fork; pid-файл пишется демоном асинхронно —
# дожидаемся (макс. 3 с), иначе status/проверка pid провалятся по гонке.
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$R/run/deck-thermal-guard.pid" ] && break; sleep 0.3; done
if run_guard status >/dev/null 2>&1; then ok "status=active"; else bad "status inactive"; fi
[ -s "$R/run/deck-thermal-guard.pid" ] && ok "pid-файл создан" || bad "pid-файл пуст"
wait $SLOWER
sleep 4.5   # демон успевает сделать >=2 тика после нагрева -> stage 3
assert_eq "демон отреагировал на нагрев" 3 "$(stage)"
assert_eq "little offline демоном" 0 "$(cat "$R/sys/devices/system/cpu/cpu0/online")"
echo 50000 > "$R/sys/class/thermal/thermal_zone1/temp"
run_guard stop >/dev/null 2>&1
sleep 0.3   # даём SIGTERM обработать trap и убрать pid-файл
assert_eq "после stop: big ceiling" 2457600 "$(cpu_big)"
assert_eq "после stop: little online" 1 "$(cat "$R/sys/devices/system/cpu/cpu0/online")"
if run_guard status >/dev/null 2>&1; then bad "демон не остановился"; else ok "status=inactive после stop"; fi

echo
echo "ИТОГ: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
TESTEOF
