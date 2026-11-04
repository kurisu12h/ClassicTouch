#!/usr/bin/env python3
"""Summarize one swipe test (the app's -swipetest, see EmulatorViewController.swipeLock/swipeHome): frames and CPU
per segment.

events.log has "seg <name> begin|end serial=<frame number> cpu=<CPU seconds of this process>" for each segment:
- frames/s: difference of the frame numbers / segment length. The frame number counts the pictures QEMU published
  to the app that differ from the previous one (ios_capture in qemu-ios-ui.c);
- CPU: all threads of this process, as a percentage of one core;
- threads: the average over the seconds of threads.csv that fall in the segment (seconds below 1% count as 0);
- [perf] lines (-perf, IT_PERF=1): the average of the per-second stats in qemu.log that fall in the segment, with
  events.log's clock up0= subtracted from up= to line them up.
Usage: summarize-swipe.py RUN_DIR [--markdown]
"""
import csv
import os
import re
import sys
from collections import defaultdict

run = sys.argv[1]
markdown = "--markdown" in sys.argv
events = open(os.path.join(run, "events.log")).read().splitlines()
up0 = None
segs = {}
order = []
for line in events:
    m = re.match(r"([\d.]+) clock up0=([\d.]+)", line)
    if m:
        up0 = float(m.group(2))
    m = re.match(r"([\d.]+) seg (\S+) (begin|end) serial=(\d+) cpu=([\d.]+)", line)
    if m:
        t, name, edge, serial, cpu = float(m.group(1)), m.group(2), m.group(3), int(m.group(4)), float(m.group(5))
        if name not in segs:
            segs[name] = {}
            order.append(name)
        segs[name][edge] = (t, serial, cpu)

threads = defaultdict(dict)   # name -> {wall: pct}
path = os.path.join(run, "threads.csv")
if os.path.exists(path):
    for r in csv.DictReader(open(path)):
        threads[r["thread"]][float(r["wall_s"])] = float(r["cpu_pct"])

perf = []   # (rel_t, kind, fields)
path = os.path.join(run, "qemu.log")
if up0 is not None and os.path.exists(path):
    for line in open(path, errors="replace"):
        m = re.match(r"\[perf\] (\w+) up=([\d.]+) (.*)", line)
        if not m:
            continue
        fields = {}
        rest = m.group(3).split(" top:")[0]
        for k, v in re.findall(r"([\w-]+)=(\S+(?: [^ =]+\))?)", rest):
            fields[k] = v
        top = m.group(3).split(" top:")[1].strip() if " top:" in m.group(3) else ""
        perf.append((float(m.group(2)) - up0, m.group(1), fields, top))


def num(v, i=0):
    """the i-th number of '12/3.4MB/5.6ms(fetch 1.0ms)'"""
    return float(re.findall(r"[\d.]+", v)[i])


rows = []
for name in order:
    s = segs[name]
    if "begin" not in s or "end" not in s:
        continue
    (t0, f0, c0), (t1, f1, c1) = s["begin"], s["end"]
    dt = t1 - t0
    row = {"seg": name, "secs": dt, "fps": (f1 - f0) / dt, "CPU%": (c1 - c0) / dt * 100}
    secs = [w for w in range(int(t0) + 1, int(t1) + 1)]
    per_thread = {}
    for tname, series in threads.items():
        vals = [series.get(float(w), 0.0) for w in secs]
        if vals and sum(vals) / len(vals) >= 2:
            per_thread[tname] = sum(vals) / len(vals)
    row["threads"] = per_thread
    lines = [p for p in perf if t0 + 0.5 <= p[0] <= t1 + 0.5]
    gl = [p for p in lines if p[1] == "gl"]
    disp = [p for p in lines if p[1] == "disp"]
    ui = [p for p in lines if p[1] == "ui"]
    # One line per second, but a second without GL calls (or without published frames) is not printed: average over
    # the segment's seconds, counting the missing ones as 0
    n = max(round(dt), 1)
    if gl:
        row["gl"] = {
            "calls": sum(num(p[2]["calls"]) for p in gl) / n,
            "host-ms": sum(num(p[2]["host-ms"]) for p in gl) / n,
            "err-ms": sum(num(p[2]["err-ms"]) for p in gl) / n,
            "upload": sum(num(p[2]["upload"]) for p in gl) / n,
            "upload-MB": sum(num(p[2]["upload"], 1) for p in gl) / n,
            "upload-ms": sum(num(p[2]["upload"], 2) for p in gl) / n,
            "fetch-ms": sum(num(p[2]["upload"], 3) for p in gl) / n,
            "writeback": sum(num(p[2]["writeback"]) for p in gl) / n,
            "writeback-MB": sum(num(p[2]["writeback"], 1) for p in gl) / n,
            "writeback-ms": sum(num(p[2]["writeback"], 2) for p in gl) / n,
            "readpixels-ms": sum(num(p[2]["writeback"], 3) for p in gl) / n,
            "host-cpu-ms": sum(num(p[2].get("host-cpu-ms", "0")) for p in gl) / n,
            "readpixels-cpu-ms": sum(num(p[2].get("readpixels-cpu-ms", "0")) for p in gl) / n,
            "reread": sum(num(p[2]["reread"]) for p in gl) / n,
            "reread-MB": sum(num(p[2]["reread"], 1) for p in gl) / n,
            "top": gl[len(gl) // 2][3],

        }
    if disp:
        row["disp"] = {k: sum(num(p[2][k]) for p in disp) / n for k in ("vbl", "swaps", "relatch", "latch-ms", "update-ms")}
    if ui:
        row["ui"] = {k: sum(num(p[2][k]) for p in ui) / n for k in ("captures", "published", "capture-ms")}
    rows.append(row)

flips = {}
for line in events:
    m = re.match(r"([\d.]+) flip (\d+) (begin|end) serial=(\d+)", line)
    if m:
        flips.setdefault(m.group(2), {})[m.group(3)] = (float(m.group(1)), int(m.group(4)))
flip_fps = [(f["end"][1] - f["begin"][1]) / (f["end"][0] - f["begin"][0])
            for f in flips.values() if "begin" in f and "end" in f and f["end"][0] > f["begin"][0]]

if markdown:
    print("| Segment | s | frames/s | CPU% | threads (% of a core) | GL calls/s | GL host ms/s | uploads n/MB/ms | writebacks n/MB/ms (readback ms) | rereads n/MB | swaps/s | compositing ms/s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    th = ", ".join(f"{k} {v:.0f}" for k, v in sorted(r["threads"].items(), key=lambda kv: -kv[1]))
    g = r.get("gl")
    d = r.get("disp")
    if markdown:
        gl_cols = (f"{g['calls']:.0f} | {g['host-ms']:.0f} | {g['upload']:.1f}/{g['upload-MB']:.1f}/{g['upload-ms']:.0f} | "
                   f"{g['writeback']:.1f}/{g['writeback-MB']:.1f}/{g['writeback-ms']:.0f} ({g['readpixels-ms']:.0f}) | "
                   f"{g['reread']:.1f}/{g['reread-MB']:.1f}") if g else "| | | |"
        disp_cols = f"{d['swaps']:.1f} | {d['latch-ms'] + d['update-ms']:.0f}" if d else " | "
        print(f"| {r['seg']} | {r['secs']:.1f} | {r['fps']:.1f} | {r['CPU%']:.0f} | {th} | {gl_cols} | {disp_cols} |")
    else:
        print(f"{r['seg']:13s} {r['secs']:5.1f}s  frames/s {r['fps']:5.1f}  CPU {r['CPU%']:4.0f}%  threads {th}")
        if g:
            print(f"{'':13s} gl calls {g['calls']:.0f}/s host {g['host-ms']:.0f} ms/s (glGetError {g['err-ms']:.0f})"
                  f" uploads {g['upload']:.1f} times {g['upload-MB']:.1f} MB {g['upload-ms']:.0f} ms (guest reads {g['fetch-ms']:.0f})"
                  f" writebacks {g['writeback']:.1f} times {g['writeback-MB']:.1f} MB {g['writeback-ms']:.0f} ms (readpixels {g['readpixels-ms']:.0f})"
                  f" rereads {g['reread']:.1f} times {g['reread-MB']:.1f} MB")
            print(f"{'':13s} gl costliest slots (middle second): {g['top']}")
            print(f"{'':13s} actual CPU use: GL forwarding {g['host-cpu-ms']:.0f} ms/s, readback {g['readpixels-cpu-ms']:.0f} ms/s")
        if d:
            print(f"{'':13s} display vbl {d['vbl']:.0f} swaps {d['swaps']:.1f} relatch {d['relatch']:.1f}"
                  f" compositing {d['latch-ms']:.1f} ms console refresh {d['update-ms']:.1f} ms /s")
        u = r.get("ui")
        if u:
            print(f"{'':13s} published {u['published']:.1f}/{u['captures']:.1f} frames {u['capture-ms']:.1f} ms/s")

if flip_fps:
    print(f"page-flip animation (press to 0.6 s later, {len(flip_fps)} times): frames/s " + ", ".join(f"{v:.0f}" for v in flip_fps)
          + f", average {sum(flip_fps) / len(flip_fps):.1f}")
