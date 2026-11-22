# omarchy-m1-touchbar-cpu-monitor

CPU temperatures and a live system monitor on the Touch Bar of a **13-inch M1
MacBook Pro (j293)** running [Omarchy](https://omarchy.org) on Asahi Linux.

On Asahi, the M1 MacBook Pro exposes **no CPU temperature at all**: the stock
device tree gives the SMC hardware-monitor driver only four board sensors (NAND,
battery hotspot, charge regulator, Wi-Fi). This repo has two parts:

1. **`smc-cpu-temps/`**: a pacman package with a device tree overlay. It makes
   the kernel expose the SMC's CPU temperature sensors (CPU package, four P-cores
   and the E-cluster) through `hwmon`, so `sensors`, btop and scripts can read
   them.
2. **`barux-monitor/`**: a Touch Bar system monitor for the
   [barux](https://github.com/peteloaf/barux/tree/new-features) Touch Bar daemon.
   A button on the main bar shows the live CPU temperature, and a tap opens a page
   of colored cells with CPU, GPU, fan, RAM, disk and network.

`research/` holds the stress-test scripts and logs used to work out which SMC
sensors are which.

> **⚠️ More research is needed to identify the correct CPU temperature sensors on
> the M1 MacBook Pro.** The sensors used here were chosen by how they react to load,
> not from any documentation. Their absolute readings are not verified, and other
> choices may be more accurate. See
> [Open questions about the CPU sensors](#open-questions-about-the-cpu-sensors).

```
Main bar:
[brightness] [kbd-] [kbd+]  ·····  [prev] [play] [next]  [volume] [wifi] [battery 87%]  [📈 45°]
                                                                                          └─ tap
Monitor page:
[◀ Back]  [CPU 12%   45°] [GPU 3%   41°] [fan 0%] [RAM 3.3/15.1 GB] [disk 5% · 10/234 GB] [net 🡳 1.2 Mb/s 🡱 80 Kb/s]
```

## Tested on

| | |
|---|---|
| Machine | MacBook Pro 13" M1, 2020 (`j293`, SoC `t8103`) |
| OS | Omarchy on Asahi (Arch Linux ARM) |
| Kernel | `linux-aurora` 7.2.11 (Asahi-based; its `macsmc-hwmon` driver reads temperature sensors from the device tree) |
| Boot | `omarchy-mac-boot` 20261104 (applies device tree overlays when m1n1 is rebuilt) |
| Touch Bar | barux, `new-features` branch |

Only one machine has been tested. Other M1 models (MacBook Air `j313`, Mac mini
`j274`, iMac `j456`/`j457`) use different device trees, and the overlay targets
`t8103-j293` only. Their SMC keys may differ too.

## Repo layout

```
smc-cpu-temps/
  PKGBUILD              pacman package: builds and installs the overlay
  smc-cpu-temps.dts     the device tree overlay (source)
barux-monitor/
  barux-monitor         the script that feeds the Touch Bar (bash, reads sysfs)
  barux-monitor.service systemd user service for it
  barux-config.toml     the barux config pieces: battery, chart button, monitor layer
research/
  stress-log.sh         phased CPU stress test that logs every temperature sensor
  analyze.py            ranks sensors by how they respond to each phase
  fan-stress.sh         maximum CPU + GPU load until the fan spins
  data/                 the logs from this machine (CSV)
```

---

## Part 1: `smc-cpu-temps` (the CPU temperature overlay)

### What it adds

The overlay adds six sensors under the SMC's `hwmon` node. The stock four stay as
they are:

| Label (in `hwmon`) | SMC key | What it tracks (from the stress tests) |
|---|---|---|
| CPU Package | `TCMb` | The hottest P-core area. Reads the same as `TVD0`. |
| CPU P-core 4 | `Tp2b` | Rose most when only cpu4 was loaded |
| CPU P-core 5 | `Tp3b` | cpu5 (`Tp4b` was close behind) |
| CPU P-core 6 | `Tp7b` | cpu6 |
| CPU P-core 7 | `Tp8b` | cpu7 (`Tp9b` was close behind) |
| CPU E-cluster | `Te3b` | Rose most under E-core-only load, but isn't specific to the E-cores |

The SMC has no live GPU temperature key: `Tg1b` and `Tg4b` read 0. The GPU
temperature comes from the Asahi GPU driver instead (see
[GPU temperature](#gpu-temperature)).

### Install

Requirements: `omarchy-mac-boot` and `dtc` (in the `dtc` package).

```sh
cd smc-cpu-temps
makepkg -si      # builds the .dtbo, checks it against your kernel's j293 DTB, installs it
reboot
```

The package installs
`/usr/lib/omarchy-mac-boot/dtb-overlays/t8103-j293/50-smc-cpu-temps.dtbo`.
Omarchy's pacman hook (`95-omarchy-mac-dtb-overlays.hook`) rebuilds m1n1 stage 2
with the overlay applied. The hook runs again on every kernel and m1n1 update, so
the overlay survives system updates. `makepkg`'s `check()` step applies the overlay
to the installed kernel's `t8103-j293.dtb` and confirms every sensor node is
present before anything is installed.

### Check it

The `hwmon` number changes between boots, so find the device by its name:

```sh
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat $h/name)" = macsmc_hwmon ] || continue
  for l in $h/temp*_label; do
    printf '%-26s %s °C\n' "$(cat $l)" $(( $(cat ${l%_label}_input) / 1000 ))
  done
done
```

You should see the six CPU labels above plus NAND Flash Temperature, Battery
Hotspot, Charge Regulator Temp and WiFi/BT Module Temp. `sensors` shows them too.

### Remove

```sh
sudo pacman -R smc-cpu-temps    # the hook rebuilds m1n1 without the overlay
reboot
```

### How the overlay was arrived at (pkgrel 1 to 4)

1. **pkgrel 1** listed the M1 CPU keys that macOS tools use (from
   [exelban/stats](https://github.com/exelban/stats): `Tp01`, `Tp05`, `Tp09`, …,
   `Tg05`, …). None of them exist on this SMC under Asahi: the driver logged
   "Failed to retrieve key info" for all 14.
2. **pkgrel 2** turned on the driver's `apple,discover-temperatures` property,
   which lists every temperature key the SMC has. Probing then failed completely
   ("Temperature discovery failed", `-EINVAL`, no `macsmc_hwmon` at all). Discovery
   refuses to run if the device tree already lists any temperature sensor, and the
   stock j293 tree lists four.
3. **pkgrel 3** pointed the stock four at a key that doesn't exist (so they are
   skipped), and turned discovery on. That worked: **142 temperature keys**,
   labelled by their raw key names.
4. **pkgrel 4** (current): stress tests mapped keys to cores (below). Discovery is
   off again, the stock four are back, and only the six chosen keys are added,
   with readable labels.

To debug the driver, turn on its debug messages and re-probe it:

```sh
echo 'module macsmc_hwmon +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
# then unbind/bind the device in /sys/bus/platform/drivers/macsmc-hwmon/ and read dmesg
```

---

## Part 2: the barux Touch Bar monitor

### Requirements

- **barux, `new-features` branch**:
  [peteloaf/barux](https://github.com/peteloaf/barux/tree/new-features). The
  monitor relies on that branch's `layer` action, left alignment, tab-split values,
  colors sent over the socket, battery level colors and fallback fonts. Its
  `install.sh` copies the icons (`monitoring.svg`, `mon_*.svg`,
  `battery_charging_bolt.svg`) to `/etc/barux/icons/`.
- `socat` (the script talks to `/run/barux.sock`).
- `noto-fonts`: Noto Sans Symbols 2 draws the arrows (🡳 🡱) and the Back
  triangle (⯇).
- `smc-cpu-temps` (Part 1) for the CPU temperature. Without it, the CPU cell shows
  "–" for temperature.

### Install

```sh
install -Dm755 barux-monitor/barux-monitor ~/.local/bin/barux-monitor
install -Dm644 barux-monitor/barux-monitor.service ~/.config/systemd/user/barux-monitor.service
systemctl --user daemon-reload
systemctl --user enable --now barux-monitor
```

Then merge `barux-monitor/barux-config.toml` into `/etc/barux/config.toml`: the
first part goes at the end of your main layer, and the second is a new
`[[layers]]` block. Then run `sudo systemctl reload barux`. barux caches icons by
path, so if you replace an icon file in place, restart barux instead of reloading
it.

To print one reading to the terminal:

```sh
barux-monitor --print
```

### What it shows and where the numbers come from

| Cell | Example | Source |
|---|---|---|
| Chart button (main bar) | `45°` | SMC "CPU Package" (`TCMb`), every 2 s. Gray under 65 °C, orange 65–90 °C, red from 91 °C. |
| CPU | `12%   45°` | Usage from `/proc/stat`, temperature from SMC "CPU Package" |
| GPU | `3%   41°` | `/sys/class/drm/renderD128/device/agx_stats`: `busy_ns` for usage, `temperature_raw` for temperature |
| Fan | `0%` | SMC `Fan` speed as a share of its maximum (`fan1_max`, 7199 RPM) |
| RAM | `3.3/15.1 GB` | `/proc/meminfo`: total minus available (like `free` and btop) |
| Disk | `5% · 10/234 GB` | `df` on `/` (`DISK_MOUNT`), every 30 s |
| Network | `🡳 1.2 Mb/s  🡱 80 Kb/s` | All interfaces except `lo`, in bits per second (decimal units) |

Settings are at the top of the script: `INTERVAL`, `CHART_INTERVAL`, `WARM_C`,
`HOT_C`, the warning colors, `DISK_MOUNT` and `DISK_EVERY`.

### Low overhead

- barux tells the script which layer is showing. **The script reads sensors only
  while the monitor page is open** (once a second), or while the main bar is
  showing (only the CPU temperature, every 2 s). When the bar is off or on another
  layer, it waits on the socket and reads nothing.
- Each sample uses bash builtins only and starts no processes. The one exception is
  `df`, every 30 samples.
- It finds sensors by name and label each time the page opens, so changing `hwmon`
  numbers don't break it.
- The chart button is sent an update only when its text or color changes.
- Cell widths are fixed and sized for the widest realistic value, so cells don't
  change width as digits come and go.

### GPU temperature

`agx_stats` reports `temperature_raw` and `temperature_scale`. The temperature in
°C is `temperature_raw / temperature_scale / 64`: a sum of `temperature_scale`
readings in 1/64 °C. **This formula is inferred from the values**, not from driver
documentation. It gives readings that agree with the SSD and Wi-Fi sensors next
to the GPU.

---

## Stress test findings

All logs are in `research/data/`.

- `baseline-before-overlay.csv` (`stress-log.sh`, before the overlay): with only the
  stock sensors, the GPU's `agx_stats` temperature was the best stand-in for chip
  temperature.
- `after-overlay.csv` (`stress-log.sh` with pkgrel 3's 142 keys; run
  `research/analyze.py research/data/after-overlay.csv`):
  - 111 keys are live. 31 always read 0.0: `Tc1*`–`Tc6*`, `Tg1b`, `Tg4b`,
    `Ta1a`/`Ta1x`, `Tarc`, `Ts5a`/`Ts5x`.
  - Under all-core load, the `Tp*`, `Tc8*`, `Tca*` and `TCM*` keys rise the most
    (+34 to +37 °C).
  - Loading one P-core at a time: cpu4 raises `Tp2` most, cpu5 `Tp3` (`Tp4` and
    `Tc8` close), cpu6 `Tp7` (`Tca` close), cpu7 `Tp8` (`Tca`, `Tp9` close).
  - Under E-core-only load, the largest rise is only about +6 °C (`Te3*`, `Tc7*`,
    `Tp3x`). No key is specific to the E-cores.
- `fan-stress-*.csv` (`fan-stress.sh`: `stress-ng --cpu 0 --cpu-method fft` plus
  `vkmark` effect2d with a 5×5 blur, full screen):
  - System power peaks around **56 W**.
  - CPU Package reaches about **108–110 °C** within 5–10 s. The P-cores stay at
    2988 MHz.
  - The SMC turns the fan on only then: target 1200 RPM at first, rising about
    60 RPM/s to about **5200–5300 RPM** (of 7199) after a minute.
  - The SMC holds CPU Package at about 110 °C by cutting the **GPU** from about
    10 W to 3 W, not the CPU.
  - At light and moderate loads the fan stays at 0 RPM. That's normal: the fan
    reading is correct.

Running the tests needs `stress-ng` and `vkmark` (`sudo pacman -S stress-ng
vkmark`).

```sh
research/stress-log.sh research/data/my-run.csv    # about 17 min: idle, E-only, P-only, each P-core, all cores
research/analyze.py research/data/my-run.csv
research/fan-stress.sh                             # stops 60 s after the fan starts (or at 15 min)
```

`stress-log.sh` logs every sensor `hwmon` exposes, so it's most useful with
discovery turned on (the pkgrel 3 overlay setup).

---

## Open questions about the CPU sensors

**More research is needed to identify the correct CPU temperature sensors on the
M1 MacBook Pro.** What's known and what isn't:

- **Apple doesn't document SMC keys.** The names here were matched to cores only by
  which sensor heated up most under which load. Some of the single-core margins are
  small (cpu5: `Tp3` +11.4 °C vs `Tp4` +10.7 °C vs `Tc8` +11.1 °C), so another key
  may fit a core better.
- **The variant suffixes are unexplained.** Each key comes in `a`, `b`, `x` and `z`
  variants that respond the same way but sit at fixed offsets: `b` ≈ `a` + 9 °C and
  `z` ≈ `x` + 15 °C, and `a`/`b` react a little faster than `x`/`z`. This repo uses
  `b` throughout, but it hasn't been checked which variant (if any) is the true die
  temperature. **Absolute values could be off by roughly 10 °C either way**: at all-core
  load, `Tp*a` peaked around 74 °C, `Tp*b` around 83 °C and `Tp*z` around 93 °C.
- **"CPU Package" is a label chosen here.** `TCMb` tracks the hottest P-core
  sensor and reads the same as `TVD0`. Whether it's a real package or die sensor,
  or a maximum the SMC computes, is unknown.
- **P-cores 4–7 only.** Pairs of keys (`Tp2`/`Tp3`/`Tp4`, `Tp7`/`Tp8`/`Tp9`) may be
  several sensors per core, or sensors placed between cores.
- **No E-core sensor.** E-core-only load raises everything by only about 6 °C.
  `Te3b` is a best guess, and the E-cores (cpu0–3) have no individual sensors.
- **Keys from macOS tools don't match.** The M1 keys used by stats and similar
  tools (`Tp01`, `Tp05`, `Tp09`, `Tp0T`, `Tg05`, …) don't exist on this SMC under
  Asahi. The reason is unclear: different firmware, a different model, or those
  tools' tables are wrong for the j293.
- **No SMC GPU temperature.** The GPU keys read 0, and the `agx_stats` formula is
  inferred.

Ways to settle this:

- Boot macOS on the same machine, run the same load, and compare these keys
  with what macOS tools that read SMC keys report (for example stats or iStat
  Menus). The list of SMC keys macOS reads on the j293 would settle which ones
  are the CPU sensors.
- Ask the Asahi Linux developers (the `macsmc-hwmon` maintainers). The driver in
  this kernel has built-in sensor lists for M2/M3 machines but none for `t8103`, so
  a proper j293 list would help there too.
- Look for thermal sensor tables in Apple's device tree (ADT) for the j293, which
  m1n1 can dump.
- Look at what the SMC regulates on. Under full load it held `TCMb` steady at
  about 110 °C, and it turned the fan on when `TCMb` reached about 108–110 °C. That
  suggests `TCMb` is close to the value the SMC uses itself, but this isn't proven.

If you find out more, issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
