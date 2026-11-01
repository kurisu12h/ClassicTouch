#!/usr/bin/env python3
"""M0: the benchmark runs (work/runs/<name>/result.json, fps-<name>/fps.json) as Markdown tables, plus the iPhone
projection. usage: summarize.py [RUNS_DIR]  ->  Markdown on stdout, and RUNS_DIR/summary.json."""
import glob
import json
import os
import re
import statistics
import struct
import sys

ROOT = "/path/to/classic-ios"
RUNS = sys.argv[1] if len(sys.argv) > 1 else ROOT + "/work/runs"
DEVICES = [("n72", "iPod touch 2 代 · iPhone OS 3.1.3"), ("n88", "iPhone 3GS · iOS 6.1.6"),
           ("n90", "iPhone 4 · iOS 7.1.2")]
# M4 Max core equivalents, sustained (upstream's ipod-touch-2g-on-iphone.md: A19 Pro 0.90 single-thread x 0.75 thermal)
LOAD_MAX = 8.0
PHONES = [("iPhone 18 Pro（A20 Pro，粗算 0.7）", 0.70), ("iPhone 14 Pro（A16，粗算 0.48）", 0.70 * 0.68),
          # M1's interpreter boots on the iPhone 18 Pro (docs/reports/m1-stage1.md): lock screen after 43 s (n72) and
          # 115 s (n88), against this Mac's TCI 45.7 s and 150.7 s: about 1.06 and 1.31 M4 Max cores, short bursts
          ("iPhone 18 Pro（按 M1 真机开机校准 1.2）", 1.2)]


def gles_blob(path):
    """Bytes of the "gles-host" section (gles-host-snapshot.c.inc: be32 len, then the blob) in a migration file."""
    with open(path, "rb") as f:
        data = f.read()
    i = data.find(b"\x09gles-host")
    if i < 0:
        return None
    return struct.unpack(">III", data[i + 10:i + 22])[2]


def uptime_line(log, key):
    try:
        for line in open(log):
            if line.startswith(key):
                m = re.search(r"load averages: ([\d.]+) ([\d.]+) ([\d.]+)", line)
                return [float(x) for x in m.groups()] if m else None
    except OSError:
        return None


def load(run):
    r = json.load(open(os.path.join(run, "result.json")))
    name = os.path.basename(run)
    r["name"] = name
    r["uptime_before"] = uptime_line(run + ".log", "uptime-before")
    r["uptime_after"] = uptime_line(run + ".log", "uptime-after")
    snap = os.path.join(run, "snapshot.bin")
    r["gles_blob"] = gles_blob(snap) if os.path.exists(snap) else None
    fps = os.path.join(RUNS, "fps-" + name, "fps.json")
    r["fps"] = json.load(open(fps)) if os.path.exists(fps) else None
    lock = os.path.join(RUNS, "fpslock-" + name, "fps-lock.json")
    r["fps_lock"] = json.load(open(lock)) if os.path.exists(lock) else None
    return r


def thread(w, name="CPU 0/TCG"):
    return (w or {}).get("threads_pct", {}).get(name, 0.0)


def metrics(r):
    rs = r.get("restores") or []
    m = {
        "boot_s": r["boot_s"],
        "boot_cpu_s": r["boot_cpu_s"],
        "boot_cpu0_s": r["boot_threads_cpu_s"].get("CPU 0/TCG"),
        "idle_pct": r["idle_home"]["pct_core"],
        "idle_cpu0": thread(r["idle_home"]),
        "flips_pct": r["page_flips"]["pct_core"],
        "flips_cpu0": thread(r["page_flips"]),
        "settings_s": r["open_settings"]["frontmost_after_s"],
        "settings_pct": r["open_settings"]["pct_core"],
        "clock_s": r["open_clock"]["frontmost_after_s"],
        "clock_pct": r["open_clock"]["pct_core"],
        "snap_save_s": r["snapshot_save"].get("seconds"),
        "snap_mb": (r["snapshot_save"].get("bytes") or 0) / 1e6,
        "gles_mb": (r["gles_blob"] or 0) / 1e6,
        "restore_s": statistics.mean(x["loaded_s"] for x in rs) if rs else None,
        "restore_tap_s": statistics.mean(x["tap_settings_opened_s"] for x in rs if x.get("tap_settings_opened_s"))
        if any(x.get("tap_settings_opened_s") for x in rs) else None,
        "restore_idle_pct": statistics.mean(x["idle_after_restore"]["pct_core"] for x in rs) if rs else None,
        "load_before": (r.get("uptime_before") or r["host_loadavg_before"])[0],
        "load_idle": r["idle_home"]["loadavg_at_start"][0],
        "load_after": (r.get("uptime_after") or [None])[0],
    }
    if r["fps"]:
        m.update({"fps": r["fps"]["visible_fps"], "fps_min": r["fps"]["visible_fps_min_1s"],
                  "fps_cpu0": r["fps"]["threads_pct"].get("CPU 0/TCG", 0.0)})
    if r.get("fps_lock"):
        m.update({"fps_lock": r["fps_lock"]["visible_fps"], "fps_lock_cpu0": r["fps_lock"]["threads_pct"].get("CPU 0/TCG", 0.0)})
    return m


def fmt(v, nd=1):
    if v is None:
        return "–"
    if isinstance(v, float):
        return ("%." + str(nd) + "f") % v
    return str(v)


def main():
    runs = {}
    for res in sorted(glob.glob(os.path.join(RUNS, "n*-*-*", "result.json"))):
        run = os.path.dirname(res)
        name = os.path.basename(run)
        dev, build, _ = name.split("-")
        runs.setdefault((dev, build), []).append(load(run))
    out = {}
    print("## 每轮原始数据\n")
    cols = [("boot_s", "开机到锁屏 s", 1), ("boot_cpu_s", "开机 CPU s", 1), ("idle_pct", "主屏静置 %核", 1),
            ("flips_pct", "翻页 %核", 1), ("settings_s", "开设置 s", 2), ("settings_pct", "开设置 %核", 1),
            ("clock_s", "开时钟 s", 2), ("clock_pct", "开时钟 %核", 1), ("snap_mb", "快照 MB", 0),
            ("snap_save_s", "存 s", 2), ("restore_s", "恢复 s", 2), ("restore_idle_pct", "恢复后静置 %核", 1),
            ("fps", "拖动可见帧率", 1), ("load_before", "负载 开始", 1), ("load_idle", "负载 静置窗口", 1),
            ("load_after", "负载 结束", 1)]
    print("| 轮次 | " + " | ".join(c[1] for c in cols) + " |")
    print("|---|" + "---:|" * len(cols))
    for (dev, build), rs in sorted(runs.items()):
        for r in rs:
            m = metrics(r)
            out[r["name"]] = m
            mark = " ⚠" if m["load_idle"] > LOAD_MAX or m["load_before"] > LOAD_MAX else ""
            print("| %s%s | " % (r["name"], mark) + " | ".join(fmt(m.get(k), nd) for k, _, nd in cols) + " |")
    print()
    means = {}
    for key, rs in runs.items():
        ms = [metrics(r) for r in rs]
        # a run whose measuring windows began with the host's 1-minute load above LOAD_MAX (M1 compiling, Spotlight)
        # keeps its boot numbers (boot ran before) but not its interactive ones
        def ok(m, k):
            if m.get(k) is None:
                return False
            if k.startswith("boot"):
                return m["load_before"] <= LOAD_MAX
            return m["load_idle"] <= LOAD_MAX
        means[key] = {k: statistics.mean(m[k] for m in ms if ok(m, k)) for k in ms[0] if any(ok(m, k) for m in ms)}
    json.dump({"runs": out, "means": {"%s-%s" % k: v for k, v in means.items()}}, open(
        os.path.join(RUNS, "summary.json"), "w"), indent=1)
    print("## 各机型均值和 TCI/JIT 倍数\n")
    rows = [("boot_s", "开机到锁屏（s）"), ("boot_cpu0_s", "开机时客体主核线程 CPU 秒"), ("idle_pct", "主屏静置（% 单核）"),
            ("flips_pct", "主屏翻页（% 单核）"), ("settings_pct", "开设置的 10 秒（% 单核）"),
            ("settings_s", "点开设置到前台（s）"), ("clock_s", "点开时钟到前台（s）"), ("fps", "主屏拖动可见帧率"), ("fps_cpu0", "　拖动时客体主核 %"), ("fps_lock", "锁屏微光动画可见帧率"),
            ("fps_lock_cpu0", "　锁屏动画时客体主核 %"),
            ("snap_mb", "快照大小（MB）"), ("gles_mb", "其中 GL 状态（MB）"), ("snap_save_s", "存快照（s）"),
            ("restore_s", "恢复快照（s）"), ("restore_tap_s", "恢复后点设置到前台（s）")]
    head = "| 项目 | " + " | ".join("%s JIT | %s TCI | 倍数" % (d, d) for d, _ in DEVICES) + " |"
    print(head)
    print("|---|" + "---:|---:|---:|" * len(DEVICES))
    for k, label in rows:
        cells = []
        for d, _ in DEVICES:
            j, t = means.get((d, "jit"), {}).get(k), means.get((d, "tci"), {}).get(k)
            ratio = (t / j) if (j and t and k not in ("fps", "fps_lock", "snap_mb", "gles_mb", "snap_save_s",
                                                      "restore_s")) else None
            if k in ("fps", "fps_lock") and j and t:
                ratio = j / t
            cells += [fmt(j, 2 if k.endswith("_s") and "boot" not in k else 1), fmt(t, 2 if k.endswith("_s") and "boot" not in k else 1),
                      (fmt(ratio, 1) + "×") if ratio else "–"]
        print("| %s | %s |" % (label, " | ".join(cells)))
    print()
    print("## 推算到 iPhone（粗算）\n")
    print("按「M4 Max 核当量」k 换算：开机秒数 / k，CPU 占比 / k（按手机的一个核算，超过 100% 就是吃满、客体变慢），"
          "拖动帧率 = Mac 帧率 × min(1, k / 客体主核占比)。"
          "Mac 上已吃满（≥90%）的 TCI 格子写成「≥下限（约 估计）」，估计 = JIT 占比 × 开机时客体主核 CPU 的 TCI/JIT 倍数 / k。\n")
    for phone, k in PHONES:
        print("### %s\n" % phone)
        print("| 机型 | 模式 | 开机到锁屏 s | 主屏静置 %核 | 翻页 %核 | 开 App %核 | 主屏拖动帧率 |")
        print("|---|---|---:|---:|---:|---:|---:|")
        for d, label in DEVICES:
            for b in ("jit", "tci"):
                mm = means.get((d, b))
                if not mm:
                    continue
                fps = None
                if mm.get("fps"):
                    fps = min(60.0, mm["fps"] * min(1.0, k * 100 / max(mm["fps_cpu0"], 1e-6)))
                jm = means.get((d, "jit"), {})
                ratio = mm["boot_cpu0_s"] / jm["boot_cpu0_s"] if b == "tci" and jm.get("boot_cpu0_s") else None

                def pct(key):
                    v = statistics.mean([mm["settings_pct"], mm["clock_pct"]]) if key == "app" else mm[key]
                    if b == "tci" and v >= 90 and ratio:
                        # pinned at one core on the Mac: the guest already ran slow there, so v / k understates
                        # the demand; estimate it as the JIT figure times the boot's TCI/JIT guest-CPU ratio
                        jv = statistics.mean([jm["settings_pct"], jm["clock_pct"]]) if key == "app" else jm[key]
                        return "≥%s（约 %s）" % (fmt(v / k, 0), fmt(jv * ratio / k, 0))
                    return fmt(v / k, 0)
                print("| %s | %s | %s | %s | %s | %s | %s |" % (label, b.upper(), fmt(mm["boot_s"] / k, 0),
                      pct("idle_pct"), pct("flips_pct"), pct("app"), fmt(fps, 0)))
        print()

if __name__ == "__main__":
    main()
