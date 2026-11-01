#!/usr/bin/env python3
"""核对一次运行的主屏待机段有没有被人碰过（第二阶段要求：待机 CPU 只用没被干扰的数据）。

待机段：主屏时间 + 3 秒，到 control quit（或 autodrive 的 auto_quit、idle_end）之前。看三样：
- events.log 里这段时间的事件（脚本只发 unlock/home/quit，别的都不该有）；
- stats.csv 里帧编号的变化（主屏不动时只有状态栏时钟每分钟变一次）；
- 这段时间存下的客体截图（App 只在画面变了时才存），供人工看。
用法：check-idle.py 运行目录 主屏秒
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
        inside or "无", len(pngs), " ".join(pngs[:6])))
else:
    print("没有待机段数据")
