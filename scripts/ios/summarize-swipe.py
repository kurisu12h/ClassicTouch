#!/usr/bin/env python3
"""汇总一次滑动测试（App 的 -swipetest，见 EmulatorViewController.swipeLock/swipeHome）：每段的帧数和 CPU。

events.log 里每段有「seg <名> begin|end serial=<帧编号> cpu=<本进程 CPU 秒>」：
- 帧/秒：帧编号之差 / 段长。帧编号是 QEMU 发布给 App 的、和上一帧不同的画面数（qemu-ios-ui.c 的 ios_capture）；
- CPU：本进程所有线程，占一个核的百分比；
- 线程：threads.csv 里落在这段里的各秒取平均（1% 以下的秒按 0 算）；
- [perf] 行（-perf，IT_PERF=1）：qemu.log 里落在这段里的每秒统计取平均，up= 减掉 events.log 的 clock up0= 对齐。
用法：summarize-swipe.py 运行目录 [--markdown]
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
    """'12/3.4MB/5.6ms(fetch 1.0ms)' 的第 i 个数"""
    return float(re.findall(r"[\d.]+", v)[i])


rows = []
for name in order:
    s = segs[name]
    if "begin" not in s or "end" not in s:
        continue
    (t0, f0, c0), (t1, f1, c1) = s["begin"], s["end"]
    dt = t1 - t0
    row = {"段": name, "秒": dt, "帧/秒": (f1 - f0) / dt, "CPU%": (c1 - c0) / dt * 100}
    secs = [w for w in range(int(t0) + 1, int(t1) + 1)]
    per_thread = {}
    for tname, series in threads.items():
        vals = [series.get(float(w), 0.0) for w in secs]
        if vals and sum(vals) / len(vals) >= 2:
            per_thread[tname] = sum(vals) / len(vals)
    row["线程"] = per_thread
    lines = [p for p in perf if t0 + 0.5 <= p[0] <= t1 + 0.5]
    gl = [p for p in lines if p[1] == "gl"]
    disp = [p for p in lines if p[1] == "disp"]
    ui = [p for p in lines if p[1] == "ui"]
    # 每秒一行，但没有 GL 调用（或没发布帧）的那一秒不打：按这段的秒数平均，缺的算 0
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
    print("| 段 | 秒 | 帧/秒 | CPU% | 线程（%核） | GL 调用/秒 | GL 宿主 ms/秒 | 上传 次/MB/ms | 写回 次/MB/ms（读回 ms） | 重读 次/MB | 换帧/秒 | 合成 ms/秒 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    th = "，".join(f"{k} {v:.0f}" for k, v in sorted(r["线程"].items(), key=lambda kv: -kv[1]))
    g = r.get("gl")
    d = r.get("disp")
    if markdown:
        gl_cols = (f"{g['calls']:.0f} | {g['host-ms']:.0f} | {g['upload']:.1f}/{g['upload-MB']:.1f}/{g['upload-ms']:.0f} | "
                   f"{g['writeback']:.1f}/{g['writeback-MB']:.1f}/{g['writeback-ms']:.0f}（{g['readpixels-ms']:.0f}） | "
                   f"{g['reread']:.1f}/{g['reread-MB']:.1f}") if g else "| | | |"
        disp_cols = f"{d['swaps']:.1f} | {d['latch-ms'] + d['update-ms']:.0f}" if d else " | "
        print(f"| {r['段']} | {r['秒']:.1f} | {r['帧/秒']:.1f} | {r['CPU%']:.0f} | {th} | {gl_cols} | {disp_cols} |")
    else:
        print(f"{r['段']:13s} {r['秒']:5.1f}s  帧/秒 {r['帧/秒']:5.1f}  CPU {r['CPU%']:4.0f}%  线程 {th}")
        if g:
            print(f"{'':13s} gl 调用 {g['calls']:.0f}/s 宿主 {g['host-ms']:.0f} ms/s（glGetError {g['err-ms']:.0f}）"
                  f" 上传 {g['upload']:.1f} 次 {g['upload-MB']:.1f} MB {g['upload-ms']:.0f} ms（读客体 {g['fetch-ms']:.0f}）"
                  f" 写回 {g['writeback']:.1f} 次 {g['writeback-MB']:.1f} MB {g['writeback-ms']:.0f} ms（readpixels {g['readpixels-ms']:.0f}）"
                  f" 重读 {g['reread']:.1f} 次 {g['reread-MB']:.1f} MB")
            print(f"{'':13s} gl 最费时的槽位（中间那秒）：{g['top']}")
            print(f"{'':13s} 其中真正占 CPU：GL 转发 {g['host-cpu-ms']:.0f} ms/s，读回 {g['readpixels-cpu-ms']:.0f} ms/s")
        if d:
            print(f"{'':13s} 显示 vbl {d['vbl']:.0f} 换帧 {d['swaps']:.1f} relatch {d['relatch']:.1f}"
                  f" 合成 {d['latch-ms']:.1f} ms 刷控制台 {d['update-ms']:.1f} ms /s")
        u = r.get("ui")
        if u:
            print(f"{'':13s} 发布 {u['published']:.1f}/{u['captures']:.1f} 帧 {u['capture-ms']:.1f} ms/s")

if flip_fps:
    print(f"翻页动画（按下到 0.6 秒后，{len(flip_fps)} 次）：帧/秒 " + "、".join(f"{v:.0f}" for v in flip_fps)
          + f"，平均 {sum(flip_fps) / len(flip_fps):.1f}")
