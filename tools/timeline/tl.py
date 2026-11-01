#!/usr/bin/env python3
"""年表补全（m2-timeline）：在 Mac 上用 M0 的原生 QEMU（JIT）开 iPhone OS 1.x、2.x 的设备。

这两代系统里没有 guest agent（it_agent），M0 的 bench.py 靠 agent 判前台，所以这里改成每秒 screendump 加
OCR：认出「slide to unlock」记锁屏，按 Home 再滑动解锁，认出主屏图标名记主屏。机器控制（QMP、触摸、按键、
CPU 采样）照用 tools/m0/bench.py 的 Machine。iOS 4、5 有 agent，直接用 bench.py setup。

  tl.py setup --device work/devices/m68ap-1A543a --golden work/states/m68ap-1A543a
      从设备本体冷启动，到主屏后截图、量 20 秒主屏静止 CPU，关机，留下的 state/ 就是黄金状态。
  tl.py setup ... --direct-iboot <解密的 iBoot.bin>
      iPod touch 2 代的 2.x：FirmwareKit 做的是 SecureROM → NOR 里的 LLB → iBoot 整条链（boot_strategy
      bootrom），苹果的 SecureROM 不在 IPSW 里，我们只有占位文件。这个选项改成像 3.x 那样直接进解密过的 iBoot。

黄金状态的目录照 App（app/ClassicTouch/DeviceProfile.swift）：state/nor.bin 加 state/nand/（就地写的 NAND
镜像库，从本体逐个 clonefile）。1.x 机型的 NOR 是 pflash（-drive if=pflash），2.x 是 nor-rw。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = "/path/to/classic-ios"
sys.path.insert(0, ROOT + "/tools/m0")
import bench  # noqa: E402

PLACEHOLDER = ROOT + "/work/timeline/placeholder"
# 占位 SecureROM：一条 ARM「b .」。S5L8900 机型只把 ROM 放在 0x20000000 给 iBoot 的跳转表用，跳转表里两个
# 8900 校验/解密的槽 QEMU 自己指到桩上（hw/arm/ipod_touch_1g.c 的 n45_stage_boot_chain）。
B_SELF = bytes([0xFE, 0xFF, 0xFF, 0xEA])
HOME_WORDS = ("Settings", "Safari", "Calendar", "Photos", "Clock", "Weather", "Notes", "Stocks", "Maps")
log = bench.log


def placeholder(name):
    os.makedirs(PLACEHOLDER, exist_ok=True)
    path = os.path.join(PLACEHOLDER, name)
    if not os.path.exists(path):
        with open(path, "wb") as f:
            f.write(B_SELF)
    return path


class OldMachine(bench.Machine):
    """bench.Machine 的 argv 换成 BootRecipe.iPod1G（1.x）或 BootRecipe.iPod 的 2.x 两种开法。"""

    def __init__(self, build, base, state, run, direct_iboot=None):
        self.base, self.state, self.run = base, state, run
        os.makedirs(run, exist_ok=True)
        lock = json.load(open(os.path.join(base, "device.lock.json")))
        self.lock = lock
        hw = bench.board_info(lock["board"])
        self.hw = hw
        # 1.x、2.x 的 Home 和电源键都走键盘组合键（Command+Shift+H、Command+L），和 n72 一样
        self.ipod = True
        env = dict(os.environ)
        esc = bench.esc
        nand = os.path.join(state, "nand")
        opts = "".join(",%s=%s" % (k, esc(v)) for k, v in sorted((lock.get("machine") or {}).items()))
        net = "user,id=wifi0,restrict=on,lan=off"
        if hw["machine"] in ("iPhone-2G", "iPod-Touch-1G"):
            m = "%s,bootrom=%s,iboot=%s,nand=%s" % (hw["machine"], esc(placeholder("bootrom_s5l8900")),
                                                  esc(os.path.join(base, "iBoot.bin")), esc(nand))
            m += opts
            argv_m = ["-M", m, "-drive", "if=pflash,format=raw,file=%s" % esc(os.path.join(state, "nor.bin"))]
        else:
            if direct_iboot is None and lock.get("boot_strategy") == "iboot":
                direct_iboot = os.path.join(base, "iBoot.bin")
            m = "%s,boot-args=%s,direct-iboot=%s,direct-llb=,bootrom=%s" % (
                hw["machine"], esc(bench.IPOD_BOOT_ARGS), esc(direct_iboot or ""), esc(placeholder("bootrom_240_4")))
            m += ",nand=%s,nor=%s,nor-rw=%s,wifi=on,gid-blobs=%s" % (
                esc(nand), esc(os.path.join(base, "nor.bin")), esc(os.path.join(state, "nor.bin")),
                esc(os.path.join(base, "gid-blobs.bin")))
            m += opts
            argv_m = ["-M", m, "-m", "128M"]
            env["IT_TVOUT_READY"] = "1"
        # unix 套接字路径上限 104 字节，运行目录可能太深
        os.makedirs(ROOT + "/work/timeline/sock", exist_ok=True)
        self.qmp_path = ROOT + "/work/timeline/sock/qmp-%d.sock" % os.getpid()
        if os.path.exists(self.qmp_path):
            os.unlink(self.qmp_path)
        argv = [bench.BUILDS[build]] + argv_m + [
            "-display", "none", "-no-shutdown", "-audio", "driver=none",
            "-serial", "file:" + os.path.join(run, "serial.log"),
            "-qmp", "unix:%s,server=on,wait=off" % self.qmp_path, "-netdev", net]
        if hw["hasCellular"]:
            argv += ["-netdev", net.replace("id=wifi0", "id=cell0")]
        self.argv = argv
        with open(os.path.join(run, "argv.json"), "w") as f:
            json.dump({"argv": argv, "env": {k: v for k, v in env.items() if k.startswith("IT_")}}, f, indent=1)
        self.qlog = open(os.path.join(run, "qemu.log"), "ab")
        self.t0 = time.time()
        self.p = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=self.qlog, stderr=self.qlog)
        try:
            self.qmp = bench.QMP(self.qmp_path)
        except BaseException:
            self.p.kill()  # 连不上 QMP 就别留下没人管的 QEMU
            raise
        self.seq = 0
        self.samples = []
        self._stop = False
        import threading
        self.sampler = threading.Thread(target=self._sample, daemon=True)
        self.sampler.start()


def fresh_state(device, state):
    """state/nor.bin（可写）加 state/nand/（本体每个 chip 文件 clonefile 一份，改成可写）。"""
    if os.path.exists(state):
        shutil.rmtree(state)
    os.makedirs(os.path.join(state, "nand"))
    shutil.copy(os.path.join(device, "nor.bin"), os.path.join(state, "nor.bin"))
    os.chmod(os.path.join(state, "nor.bin"), 0o644)
    for name in sorted(os.listdir(os.path.join(device, "nand"))):
        dst = os.path.join(state, "nand", name)
        subprocess.check_call(["/bin/cp", "-c", os.path.join(device, "nand", name), dst])
        os.chmod(dst, 0o644)


def words(found):
    return "|".join(sorted(found))


def watch(m, shots, limit, wake_after=None):
    """每秒截一张、OCR。返回 (锁屏秒, 主屏秒)；没到就是 None。画面一变就留一张图。
    wake_after：过了这么多秒还没认出锁屏，就每 15 秒按一次 Home 再滑动（2.x 熄屏后 SpringBoard 只在唤醒时重读
    lockdown 的状态，qemu-ios docs/ipod/from-ipsw.md「2.1.1 home screen」）。"""
    lock = home = None
    last_wake = 0.0
    last_unlock = 0.0
    last_text = None
    n = 0
    while m.elapsed() < limit:
        if m.p.poll() is not None:
            log("QEMU 退出了（%s）" % m.p.returncode)
            break
        t = m.elapsed()
        n += 1
        png = os.path.join(shots, "t%04d.png" % int(t))
        try:
            m.screenshot(png)
        except (RuntimeError, OSError, EOFError) as e:
            log("screendump 失败：%s" % e)
            time.sleep(1)
            continue
        time.sleep(0.2)
        found = bench.ocr(png)
        text = words(found)
        if text != last_text:
            log("%.0f s：%s" % (t, text[:160]))
            last_text = text
        elif n % 5:
            os.unlink(png)  # 画面没变的只留每 5 秒一张
        low = text.lower()
        if lock is None and home is None and "slide to" not in low and sum(w in found for w in HOME_WORDS) >= 3:
            # iPod 的 2.x 激活后第一次开机不经过锁屏，直接是主屏
            home = t
            log("主屏（没经过锁屏）：%.1f 秒" % t)
            return lock, home
        if lock is None and "slide to unlock" in low:
            lock = t
            log("锁屏：%.1f 秒" % t)
        if lock is not None and home is None:
            if "slide to" not in low and any(w in found for w in HOME_WORDS):
                home = t
                log("主屏：%.1f 秒" % t)
                return lock, home
            if time.time() - last_unlock > 15:
                last_unlock = time.time()
                m.home()
                time.sleep(2.0)
                m.drag(0.18, 0.9, 0.92, 0.9, seconds=0.6, steps=20)
        elif lock is None and wake_after is not None and t > wake_after and time.time() - last_wake > 15:
            last_wake = time.time()
            log("%.0f s：还没锁屏，按 Home 再滑动" % t)
            m.home()
            time.sleep(2.0)
            m.drag(0.18, 0.9, 0.92, 0.9, seconds=0.6, steps=20)
        time.sleep(max(0.0, 1.0 - (m.elapsed() - t)))
    return lock, home


def idle_cpu(m, seconds):
    c0, t0 = m.cpu(), time.time()
    time.sleep(seconds)
    c1, t1 = m.cpu(), time.time()
    return round((c1 - c0) / (t1 - t0) * 100, 1)


def cmd_setup(a):
    golden = a.golden
    state = os.path.join(golden, "state")
    if a.reuse_state:
        # 接着上一次留下的状态开（不重来），本次的记录放 setup-run-<时间>
        run = os.path.join(golden, "setup-run-" + time.strftime("%H%M%S"))
    else:
        if os.path.exists(golden):
            shutil.rmtree(golden)
        fresh_state(a.device, state)
        run = os.path.join(golden, "setup-run")
    shots = os.path.join(run, "shots")
    os.makedirs(shots)
    m = OldMachine("jit", a.device, state, run, direct_iboot=a.direct_iboot)
    log("开机 %s（%s）" % (a.device, " ".join(m.argv[1:3])))
    res = {"device": a.device, "direct_iboot": a.direct_iboot, "load_start": os.getloadavg()[0]}
    lock, home = watch(m, shots, a.limit, a.wake_after)
    res.update(lock_s=lock, home_s=home, cpu_s_to_home=m.cpu())
    if home is not None:
        time.sleep(10)  # 解锁动画、图标落定
        m.screenshot(os.path.join(golden, "home-after-setup.png"))
        res["home_idle_cpu_pct"] = idle_cpu(m, 20)
        res["load_idle"] = os.getloadavg()[0]
        log("主屏静止 20 秒：%s%% 单核" % res["home_idle_cpu_pct"])
        log("关机（system_powerdown）")
        m.qmp.cmd("system_powerdown")
        t = time.time()
        while time.time() - t < a.powerdown:
            if m.p.poll() is not None or m.status() == "shutdown":
                break
            time.sleep(1)
        res["powerdown"] = "exited" if m.p.poll() is not None else m.status()
        res["powerdown_s"] = round(time.time() - t, 1)
        log("关机后状态 %s（%.0f 秒）" % (res["powerdown"], res["powerdown_s"]))
    else:
        m.screenshot(os.path.join(run, "stuck.png"))
        try:
            res["regs"] = m.qmp.cmd("human-monitor-command", **{"command-line": "info registers"})
        except (RuntimeError, OSError, EOFError):
            pass
    m.quit()
    with open(os.path.join(run if a.reuse_state else golden, "setup.json"), "w") as fh:
        json.dump(res, fh, indent=1)
    log("结果：%s" % {k: v for k, v in res.items() if k != "regs"})
    if home is None:
        raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--device", required=True)
    s.add_argument("--golden", required=True)
    s.add_argument("--direct-iboot")
    s.add_argument("--limit", type=float, default=300, help="等到主屏最多几秒")
    s.add_argument("--powerdown", type=float, default=90, help="关机最多等几秒，之后 QMP quit")
    s.add_argument("--wake-after", type=float, help="过了这么多秒还没锁屏就定时按 Home、滑动")
    s.add_argument("--reuse-state", action="store_true", help="接着 golden/state 开，不从本体重来")
    a = ap.parse_args()
    a.device, a.golden = os.path.abspath(a.device), os.path.abspath(a.golden)
    if a.direct_iboot:
        a.direct_iboot = os.path.abspath(a.direct_iboot)
    cmd_setup(a)


if __name__ == "__main__":
    main()
