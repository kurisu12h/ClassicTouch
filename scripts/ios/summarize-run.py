#!/usr/bin/env python3
"""汇总 App 一次运行的 stats.csv（sim-boot.sh、device-boot.sh 调用）。
用法：summarize-run.py 运行目录 锁屏秒 主屏秒 待机秒数（没到达的传空串）"""
import csv
import sys

run, lock, home, idle = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rows = [{k: float(v) for k, v in r.items()} for r in csv.DictReader(open(run + "/stats.csv"))]


def at(t):
    return min(rows, key=lambda r: abs(r["wall_s"] - t))


print("run", run.rstrip("/").rsplit("/", 1)[-1])
for name, t in (("lock", lock), ("home", home)):
    if not t:
        print(name, "未到达")
        continue
    r = at(float(t))
    print("%s_s %.0f  cpu_s %.1f  avg_cpu_pct %.0f  footprint_mb %.0f  available_mb %.0f" % (
        name, float(t), r["cpu_s"], r["cpu_s"] / max(r["wall_s"], 1) * 100, r["footprint_mb"], r["available_mb"]))
# 待机段截到 control quit 为止：之后 QEMU 已经停了，算进去会把待机 CPU 拉低（第一阶段的数就偏低了）。
# 第四步起 autodrive 待机结束后还要点「设置」，那时记 idle_end，也截到那里
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
