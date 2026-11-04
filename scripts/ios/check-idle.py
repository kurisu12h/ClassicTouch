#!/usr/bin/env python3
"""Check whether anyone touched the home-screen idle stretch of a run (stage 2 requires idle CPU from undisturbed
data only).

Idle stretch: home-screen time + 3 s, up to control quit (or autodrive's auto_quit, idle_end). Three things are checked:
- events in events.log during that time (the script only sends unlock/home/quit; nothing else should be there);
- changes of the frame number in stats.csv (with the home screen still, only the status bar clock changes, once a
  minute);
- the guest screenshots saved during that time (the app saves one only when the picture changes), for a human to
  look at.
Usage: check-idle.py RUN_DIR HOME_SECONDS
"""
import csv
import os
import sys

run, home = sys.argv[1], float(sys.argv[2])
events = [l.split(" ", 1) for l in open(os.path.join(run, "events.log")).read().splitlines() if l.strip()]
quit_at = next((float(t) for t, e in events if e.startswith(("control quit", "auto_quit", "idle_end"))), None)
end = quit_at if quit_at is not None else 1e9
start = home + 3
rows = [r for r in csv.DictReader(open(os.path.join(run, "stats.csv")))
        if start <= float(r["wall_s"]) < end]
inside = [f"{t} {e}" for t, e in events if start <= float(t) < end]
pngs = sorted(f for f in os.listdir(run) if f.startswith("guest-") and start <= int(f[6:10]) < end)
if rows:
    s0, s1 = int(rows[0]["frame_serial"]), int(rows[-1]["frame_serial"])
    cpu = (float(rows[-1]["cpu_s"]) - float(rows[0]["cpu_s"])) / max(float(rows[-1]["wall_s"]) - float(rows[0]["wall_s"]), 1)
    print("idle %.0f..%.0f s  frames %d -> %d (+%d)  cpu %.0f%%  events %s  guest_png %d %s" % (
        float(rows[0]["wall_s"]), float(rows[-1]["wall_s"]), s0, s1, s1 - s0, cpu * 100,
        inside or "none", len(pngs), " ".join(pngs[:6])))
else:
    print("no idle-stretch data")
