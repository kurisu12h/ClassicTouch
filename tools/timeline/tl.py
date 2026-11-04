#!/usr/bin/env python3
"""Timeline completion (m2-timeline): boot iPhone OS 1.x and 2.x devices on the Mac with M0's native QEMU (JIT).

These two generations of the system have no guest agent (it_agent), and M0's bench.py relies on the agent to tell
what is in the foreground, so here it takes a screendump plus OCR every second instead: recognizing "slide to unlock"
records the lock screen, then it presses Home and slides to unlock, and recognizing home screen icon names records the
home screen. Machine control (QMP, touch, keys, CPU sampling) still uses the Machine from tools/m0/bench.py. iOS 4 and
5 have the agent, so use bench.py setup directly.

  tl.py setup --device work/devices/m68ap-1A543a --golden work/states/m68ap-1A543a
      Cold boot from the base device; on reaching the home screen, take a screenshot, measure 20 seconds of home
      screen idle CPU and shut down. The state/ left behind is the golden state.
  tl.py setup ... --direct-iboot <decrypted iBoot.bin>
      2.x on the iPod touch 2nd gen: FirmwareKit builds the whole chain SecureROM → LLB in NOR → iBoot (boot_strategy
      bootrom), but Apple's SecureROM is not in the IPSW and we only have a placeholder file. This option instead goes
      straight into the decrypted iBoot, as 3.x does.

The golden state's directory layout follows the App (app/ClassicTouch/DeviceProfile.swift): state/nor.bin plus
state/nand/ (the NAND image store, written in place, clonefile'd chip by chip from the base device). The NOR on 1.x
models is pflash (-drive if=pflash), and on 2.x it is nor-rw.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))  # the checkout's root
sys.path.insert(0, ROOT + "/tools/m0")
import bench  # noqa: E402

PLACEHOLDER = ROOT + "/work/timeline/placeholder"
# Placeholder SecureROM: a single ARM "b .". S5L8900 models only put the ROM at 0x20000000 for iBoot's jump table; QEMU
# itself points the jump table's two 8900 verify/decrypt slots at stubs (n45_stage_boot_chain in hw/arm/ipod_touch_1g.c).
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
    """bench.Machine with its argv replaced by one of two ways to boot: BootRecipe.iPod1G (1.x) or BootRecipe.iPod's 2.x."""

    def __init__(self, build, base, state, run, direct_iboot=None):
        self.base, self.state, self.run = base, state, run
        os.makedirs(run, exist_ok=True)
        lock = json.load(open(os.path.join(base, "device.lock.json")))
        self.lock = lock
        hw = bench.board_info(lock["board"])
        self.hw = hw
        # on 1.x and 2.x, Home and the power button both go through keyboard shortcuts (Command+Shift+H, Command+L), as on n72
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
        # unix socket paths are limited to 104 bytes, and the run directory may be too deep
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
            self.p.kill()  # if QMP cannot connect, do not leave an unattended QEMU behind
            raise
        self.seq = 0
        self.samples = []
        self._stop = False
        import threading
        self.sampler = threading.Thread(target=self._sample, daemon=True)
        self.sampler.start()


def fresh_state(device, state):
    """state/nor.bin (writable) plus state/nand/ (a clonefile of each chip file from the base device, made writable)."""
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
    """Take a screenshot and OCR it every second. Returns (lock screen seconds, home screen seconds), None for one not
    reached. Keeps an image whenever the screen changes.
    wake_after: if the lock screen has not been recognized after this many seconds, press Home and slide every 15
    seconds (on 2.x, after the screen turns off, SpringBoard only rereads lockdown's state on wake; qemu-ios
    docs/ipod/from-ipsw.md "2.1.1 home screen")."""
    lock = home = None
    last_wake = 0.0
    last_unlock = 0.0
    last_text = None
    n = 0
    while m.elapsed() < limit:
        if m.p.poll() is not None:
            log("QEMU exited (%s)" % m.p.returncode)
            break
        t = m.elapsed()
        n += 1
        png = os.path.join(shots, "t%04d.png" % int(t))
        try:
            m.screenshot(png)
        except (RuntimeError, OSError, EOFError) as e:
            log("screendump failed: %s" % e)
            time.sleep(1)
            continue
        time.sleep(0.2)
        found = bench.ocr(png)
        text = words(found)
        if text != last_text:
            log("%.0f s: %s" % (t, text[:160]))
            last_text = text
        elif n % 5:
            os.unlink(png)  # while the screen is unchanged, keep only one image every 5 seconds
        low = text.lower()
        if lock is None and home is None and "slide to" not in low and sum(w in found for w in HOME_WORDS) >= 3:
            # on the iPod's 2.x, the first boot after activation skips the lock screen and goes straight to the home screen
            home = t
            log("home screen (lock screen skipped): %.1f s" % t)
            return lock, home
        if lock is None and "slide to unlock" in low:
            lock = t
            log("lock screen: %.1f s" % t)
        if lock is not None and home is None:
            if "slide to" not in low and any(w in found for w in HOME_WORDS):
                home = t
                log("home screen: %.1f s" % t)
                return lock, home
            if time.time() - last_unlock > 15:
                last_unlock = time.time()
                m.home()
                time.sleep(2.0)
                m.drag(0.18, 0.9, 0.92, 0.9, seconds=0.6, steps=20)
        elif lock is None and wake_after is not None and t > wake_after and time.time() - last_wake > 15:
            last_wake = time.time()
            log("%.0f s: no lock screen yet, pressing Home and sliding" % t)
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
        # continue from the state the previous run left (no fresh start); this run's records go in setup-run-<time>
        run = os.path.join(golden, "setup-run-" + time.strftime("%H%M%S"))
    else:
        if os.path.exists(golden):
            shutil.rmtree(golden)
        fresh_state(a.device, state)
        run = os.path.join(golden, "setup-run")
    shots = os.path.join(run, "shots")
    os.makedirs(shots)
    m = OldMachine("jit", a.device, state, run, direct_iboot=a.direct_iboot)
    log("booting %s (%s)" % (a.device, " ".join(m.argv[1:3])))
    res = {"device": a.device, "direct_iboot": a.direct_iboot, "load_start": os.getloadavg()[0]}
    lock, home = watch(m, shots, a.limit, a.wake_after)
    res.update(lock_s=lock, home_s=home, cpu_s_to_home=m.cpu())
    if home is not None:
        time.sleep(10)  # unlock animation, icons settling
        m.screenshot(os.path.join(golden, "home-after-setup.png"))
        res["home_idle_cpu_pct"] = idle_cpu(m, 20)
        res["load_idle"] = os.getloadavg()[0]
        log("home screen idle for 20 seconds: %s%% of one core" % res["home_idle_cpu_pct"])
        log("shutting down (system_powerdown)")
        m.qmp.cmd("system_powerdown")
        t = time.time()
        while time.time() - t < a.powerdown:
            if m.p.poll() is not None or m.status() == "shutdown":
                break
            time.sleep(1)
        res["powerdown"] = "exited" if m.p.poll() is not None else m.status()
        res["powerdown_s"] = round(time.time() - t, 1)
        log("state after shutdown: %s (%.0f s)" % (res["powerdown"], res["powerdown_s"]))
    else:
        m.screenshot(os.path.join(run, "stuck.png"))
        try:
            res["regs"] = m.qmp.cmd("human-monitor-command", **{"command-line": "info registers"})
        except (RuntimeError, OSError, EOFError):
            pass
    m.quit()
    with open(os.path.join(run if a.reuse_state else golden, "setup.json"), "w") as fh:
        json.dump(res, fh, indent=1)
    log("result: %s" % {k: v for k, v in res.items() if k != "regs"})
    if home is None:
        raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--device", required=True)
    s.add_argument("--golden", required=True)
    s.add_argument("--direct-iboot")
    s.add_argument("--limit", type=float, default=300, help="maximum seconds to wait for the home screen")
    s.add_argument("--powerdown", type=float, default=90, help="maximum seconds to wait for shutdown, then QMP quit")
    s.add_argument("--wake-after", type=float, help="if there is no lock screen after this many seconds, press Home and slide periodically")
    s.add_argument("--reuse-state", action="store_true", help="continue from golden/state instead of starting over from the base device")
    a = ap.parse_args()
    a.device, a.golden = os.path.abspath(a.device), os.path.abspath(a.golden)
    if a.direct_iboot:
        a.direct_iboot = os.path.abspath(a.direct_iboot)
    cmd_setup(a)


if __name__ == "__main__":
    main()
