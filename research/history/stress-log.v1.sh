#!/bin/bash
# CPU stress test that logs every temperature source once a second to a CSV.
# Phases: idle, P-cores only, cool, all 8 cores, cool.
set -u
OUT=${1:?output csv}

# Every hwmon temp*_input, named "<hwmon name>/<label>" (hwmon dir to keep tas2770s apart).
COLS=() FILES=()
for h in /sys/class/hwmon/hwmon*; do
    name=$(cat "$h/name")
    for f in "$h"/temp*_input; do
        [ -e "$f" ] || continue
        base=${f%_input}
        label=$(cat "${base}_label" 2>/dev/null || basename "$base")
        COLS+=("$(basename "$h"):$name/$label")
        FILES+=("$f")
    done
done
SMC=$(grep -l macsmc_hwmon /sys/class/hwmon/hwmon*/name | xargs dirname)
power_file=$(grep -l "Total System Power" "$SMC"/power*_label | sed 's/_label/_input/')
heat_file=$(grep -l "Heatpipe Power" "$SMC"/power*_label | sed 's/_label/_input/')
AGX=/sys/class/drm/renderD128/device/agx_stats

{
    printf 't,phase,cpu_busy_pct,freq_e_mhz,freq_p_mhz,sys_power_w,heatpipe_w,fan_rpm,gpu_temp_c,gpu_power_mw,thermal_zone0'
    printf ',%s' "${COLS[@]}"
    printf '\n'
} > "$OUT"

PHASE=idle
prev_total=0 prev_idle=0
sample() {
    local t=$1
    read -r _ u n s i w q sq st _ < /proc/stat
    local total=$((u + n + s + i + w + q + sq + st)) idl=$((i + w)) busy=0
    ((prev_total > 0)) && busy=$((100 * ((total - prev_total) - (idl - prev_idle)) / (total - prev_total)))
    prev_total=$total prev_idle=$idl
    local fe fp pw hp fan
    fe=$(($(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq) / 1000))
    fp=$(($(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq) / 1000))
    pw=$(awk '{printf "%.2f", $1/1e6}' "$power_file")
    hp=$(awk '{printf "%.2f", $1/1e6}' "$heat_file")
    fan=$(cat "$SMC/fan1_input")
    local gt gp
    read -r gt gp < <(awk '/^temperature_raw/{r=$2} /^temperature_scale/{s=$2} /^power_mw/{p=$2} END{printf "%.2f %d", (s>0? r/s/64 : 0), p}' "$AGX")
    local tz=$(awk '{printf "%.2f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    local row="$t,$PHASE,$busy,$fe,$fp,$pw,$hp,$fan,$gt,$gp,$tz" f
    for f in "${FILES[@]}"; do
        row+=",$(awk '{printf "%.2f", $1/1000}' "$f")"
    done
    printf '%s\n' "$row" >> "$OUT"
}

PIDS=()
load() { # cpus...
    local c
    for c in "$@"; do
        taskset -c "$c" sha256sum /dev/zero >/dev/null &
        PIDS+=($!)
    done
}
unload() {
    kill "${PIDS[@]}" 2>/dev/null
    wait "${PIDS[@]}" 2>/dev/null
    PIDS=()
}
trap unload EXIT

t=0
run_phase() { # name seconds
    PHASE=$1
    local end=$((t + $2))
    while ((t < end)); do
        sample "$t"
        sleep 1
        t=$((t + 1))
    done
}

run_phase idle 30
load 4 5 6 7;          run_phase p_cores 90
unload;                run_phase cool1 60
load 0 1 2 3 4 5 6 7;  run_phase all_cores 120
unload;                run_phase cool2 90
echo "done: $t samples -> $OUT"
