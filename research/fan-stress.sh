#!/bin/bash
# Maximum CPU + GPU load to see whether (and when) the SMC turns the fan on.
#   CPU: stress-ng fft on all cores (~39 W system power alone on the j293), niced
#        so vkmark still gets CPU time to feed the GPU.
#   GPU: vkmark effect2d with a 5x5 blur kernel, fullscreen, uncapped (~10 W GPU).
# Logs once a second to the CSV given (default data/fan-stress-<time>.csv) and
# stops after MAX_S seconds, or AFTER_FAN_S seconds after the fan first spins.
# Stop early: pkill -f fan-stress.sh (everything it started is cleaned up).
#
# usage: fan-stress.sh [csv] [max_seconds]

set -u
cd "$(dirname "$0")"
CSV=${1:-data/fan-stress-$(date +%Y%m%d-%H%M%S).csv}
MAX_S=${2:-900}
AFTER_FAN_S=60
G=/sys/class/drm/renderD128/device/agx_stats

SMC=''
for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = macsmc_hwmon ] && SMC=$h
done
[ -n "$SMC" ] || { echo "macsmc_hwmon not found" >&2; exit 1; }
by_label() { # label -> its *_input path
    local f
    for f in "$SMC"/*_label; do
        [ "$(cat "$f")" = "$1" ] && { echo "${f%_label}_input"; return; }
    done
}
T_PKG=$(by_label "CPU Package") T_P4=$(by_label "CPU P-core 4") T_P7=$(by_label "CPU P-core 7")
T_E=$(by_label "CPU E-cluster") P_SYS=$(by_label "Total System Power")
FAN=$(by_label Fan) FAN_TGT=${FAN%_input}_target

pids=()
cleanup() {
    kill "${pids[@]}" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

vkmark -p immediate --fullscreen --run-forever \
    -b 'effect2d:kernel=1,1,1,1,1;1,1,1,1,1;1,1,1,1,1;1,1,1,1,1;1,1,1,1,1' >/dev/null 2>&1 &
pids+=($!)
nice -n 10 stress-ng --cpu 0 --cpu-method fft >/dev/null 2>&1 &
pids+=($!)

mc() { awk '{printf "%.1f", $1/1000}' "$1"; }
echo "t,sys_w,cpu_pkg_c,p4_c,p7_c,e_c,gpu_c,gpu_w,p_mhz,fan_rpm,fan_target" > "$CSV"
fan_on_at=''
for ((t = 1; t <= MAX_S; t++)); do
    sleep 1
    traw=0 tscale=0 gmw=0
    while read -r k v; do
        case $k in
            temperature_raw) traw=$v ;; temperature_scale) tscale=$v ;; power_mw) gmw=$v ;;
        esac
    done < "$G"
    gpu_c=$(awk -v r="$traw" -v s="$tscale" 'BEGIN{ if (s > 0) printf "%.1f", r / s / 64; else print "" }')
    rpm=$(cat "$FAN") tgt=$(cat "$FAN_TGT" 2>/dev/null || echo)
    line="$t,$(awk '{printf "%.1f", $1/1e6}' "$P_SYS"),$(mc "$T_PKG"),$(mc "$T_P4"),$(mc "$T_P7"),$(mc "$T_E"),$gpu_c,$(awk -v m="$gmw" 'BEGIN{printf "%.1f", m/1000}'),$(($(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq) / 1000)),$rpm,$tgt"
    echo "$line" >> "$CSV"
    ((t % 30 == 0)) && echo "progress $line"
    if [ -z "$fan_on_at" ] && { ((rpm > 0)) || ((${tgt:-0} > 0)); }; then
        fan_on_at=$t
        echo "FAN ON at ${t}s: $line"
    fi
    [ -n "$fan_on_at" ] && ((t - fan_on_at >= AFTER_FAN_S)) && break
done
echo "done after ${t}s; fan first on at: ${fan_on_at:-never}; log: $PWD/$CSV"
