#!/usr/bin/env python3
"""Rank SMC temp keys by how they respond to each stress phase.

For each phase, the response is the mean of the last 10 samples minus the mean of the
last 10 samples of the preceding cool/idle phase.
"""
import csv
import sys
from collections import OrderedDict

rows = list(csv.DictReader(open(sys.argv[1])))
temp_cols = [c for c in rows[0] if c.startswith("hwmon") and "macsmc_hwmon" in c]

phases = OrderedDict()
for r in rows:
    phases.setdefault(r["phase"], []).append(r)


def tail_mean(phase, col, n=10):
    vals = [float(r[col]) for r in phases[phase][-n:]]
    return sum(vals) / len(vals)


names = list(phases)
load_phases = [p for p in names if p != "idle" and not p.startswith("cool")]
baseline = {}
for i, p in enumerate(names):
    if p in load_phases:
        baseline[p] = names[i - 1]

dead = [c for c in temp_cols if all(float(r[c]) == 0.0 for r in rows)]
live = [c for c in temp_cols if c not in dead]
key = lambda c: c.split("/", 1)[1]

delta = {c: {p: tail_mean(p, c) - tail_mean(baseline[p], c) for p in load_phases} for c in live}
peak = {c: max(float(r[c]) for r in rows) for c in live}

print(f"{len(live)} live keys, {len(dead)} always 0.0: {' '.join(key(c) for c in dead)}\n")
hdr = f"{'key':6} {'idle':>6} {'peak':>6} " + " ".join(f"{p:>9}" for p in load_phases)
print(hdr)
for c in sorted(live, key=lambda c: -delta[c]["all_cores"]):
    print(f"{key(c):6} {tail_mean('idle', c):6.1f} {peak[c]:6.1f} "
          + " ".join(f"{delta[c][p]:+9.1f}" for p in load_phases))

# Per-core: which key is hottest relative to its siblings when one P core is loaded.
singles = [p for p in load_phases if p.startswith("cpu")]
if singles:
    print("\nSingle P-core phases: top 6 risers each")
    for p in singles:
        top = sorted(live, key=lambda c: -delta[c][p])[:6]
        print(f"  {p}: " + ", ".join(f"{key(c)} {delta[c][p]:+.1f}" for c in top))

print("\nE-only vs P-only (keys rising >3 °C in either): e_rise p_rise")
for c in sorted(live, key=lambda c: delta[c]["e_cores"] - delta[c]["p_cores"], reverse=True):
    e, pp = delta[c]["e_cores"], delta[c]["p_cores"]
    if max(e, pp) > 3:
        print(f"  {key(c):6} {e:+6.1f} {pp:+6.1f}  {'E' if e > pp else 'P'}")
