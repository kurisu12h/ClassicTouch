#!/usr/bin/env python3
"""Summarize the stats.csv of one app run (called by sim-boot.sh and device-boot.sh).
Usage: summarize-run.py RUN_DIR LOCK_SECONDS HOME_SECONDS IDLE_SECONDS (pass an empty string for a screen not reached)"""
import csv
import sys

run, lock, home, idle = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rows = [{k: float(v) for k, v in r.items()} for r in csv.DictReader(open(run + "/stats.csv"))]


def at(t):
    return min(rows, key=lambda r: abs(r["wall_s"] - t))


print("run", run.rstrip("/").rsplit("/", 1)[-1])
for name, t in (("lock", lock), ("home", home)):
    if not t:
        print(name, "not reached")
        continue
    r = at(float(t))
    print("%s_s %.0f  cpu_s %.1f  avg_cpu_pct %.0f  footprint_mb %.0f  available_mb %.0f" % (
        name, float(t), r["cpu_s"], r["cpu_s"] / max(r["wall_s"], 1) * 100, r["footprint_mb"], r["available_mb"]))
# The idle stretch is cut at control quit: QEMU has stopped after that, and counting it would pull the idle CPU down
# (the stage 1 numbers came out low that way).
# From step 4 on, autodrive still taps Settings after the idle stretch; it logs idle_end then, and the stretch is cut
# there too
quit_at = 1e9
for line in open(run + "/events.log"):
    t, _, event = line.strip().partition(" ")
    if event.startswith(("control quit", "auto_quit", "idle_end")):
        quit_at = float(t)
        break
if home:
    tail = [r for r in rows if float(home) + 3 < r["wall_s"] < quit_at]
    if len(tail) > 1:
        print("home_idle_cpu_pct %.0f over %.0f s" % (
            (tail[-1]["cpu_s"] - tail[0]["cpu_s"]) / max(tail[-1]["wall_s"] - tail[0]["wall_s"], 1) * 100,
            tail[-1]["wall_s"] - tail[0]["wall_s"]))
print("max_footprint_mb %.0f" % max(r["footprint_mb"] for r in rows))
print("min_available_mb %.0f" % min(r["available_mb"] for r in rows))
