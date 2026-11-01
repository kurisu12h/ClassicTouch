#!/usr/bin/env python3
"""M0 benchmark driver: boot a FirmwareKit-prepared device headless in qemu-system-arm (QMP, -display none,
-audio driver=none) and measure boot, idle, interaction and snapshot save/restore, for the JIT and TCI builds.

  bench.py setup  --device work/devices/n88ap-10B500 --golden work/states/n88ap-10B500
      Fresh boot of the prepared base (JIT build), walk Setup Assistant to the Home screen (OCR of screendumps,
      LightTouchMac SessionKit SetupPlan's rules), take a Home screenshot, power off cleanly. The NOR and NAND
      overlay it leaves are the golden post-Setup state every benchmark run starts from (a clone).
  bench.py run    --device ... --golden ... --build jit|tci --out work/runs/<name>
      One measured run: boot to the lock screen, settle, unlock, idle on Home, page flips, open Settings and Clock,
      snapshot save (stop + migrate file:), quit, restore (-incoming file:), check the restored guest answers.

Every measurement is process CPU (user+sys, all threads, proc_pid_rusage) over wall time; "% of one core" is
CPU seconds / wall seconds * 100.
"""
import argparse
import base64
import ctypes
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time

ROOT = "/path/to/classic-ios"
BUILDS = {"jit": ROOT + "/work/build-jit/qemu-system-arm", "tci": ROOT + "/work/build-tci/qemu-system-arm"}
MACHINES = ROOT + "/upstream/LightTouchMac/tests/fixtures/machines.json"
OCR = ROOT + "/work/tools/ocr/ocr"
# The n72's machine stages a SecureROM image before it enters the direct iBoot, and never runs it on a cold boot
# (ipod_touch_cpu_reset). Apple's ROM is not in the IPSW; this is a 4-byte placeholder ("b ."), see the M0 report.
IPOD_BOOTROM = ROOT + "/work/m0-placeholder/bootrom_240_4"
IPOD_BOOT_ARGS = "amfi_allow_any_signature=1 cs_enforcement_disable=1"  # the app's default (DeviceOptions.bootArgs)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---------------------------------------------------------------- process CPU ----

class RusageInfoV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64),
                ("pkg_idle_wkups", ctypes.c_uint64), ("interrupt_wkups", ctypes.c_uint64),
                ("pageins", ctypes.c_uint64), ("wired_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64),
                ("phys_footprint", ctypes.c_uint64), ("proc_start_abstime", ctypes.c_uint64),
                ("proc_exit_abstime", ctypes.c_uint64), ("child_user_time", ctypes.c_uint64),
                ("child_system_time", ctypes.c_uint64), ("child_pkg_idle_wkups", ctypes.c_uint64),
                ("child_interrupt_wkups", ctypes.c_uint64), ("child_pageins", ctypes.c_uint64),
                ("child_elapsed_abstime", ctypes.c_uint64), ("diskio_bytesread", ctypes.c_uint64),
                ("diskio_byteswritten", ctypes.c_uint64)]


class TimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libsys = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_tb = TimebaseInfo()
_libsys.mach_timebase_info(ctypes.byref(_tb))


def proc_usage(pid):
    """(cpu seconds user+sys, phys_footprint bytes) of a live process; ri_*_time are Mach time units."""
    ri = RusageInfoV2()
    if _libproc.proc_pid_rusage(pid, 2, ctypes.byref(ri)) != 0:
        return None
    ns = (ri.user_time + ri.system_time) * _tb.numer / _tb.denom
    return ns / 1e9, ri.phys_footprint


class ProcThreadInfo(ctypes.Structure):
    _fields_ = [("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64), ("cpu_usage", ctypes.c_int32),
                ("policy", ctypes.c_int32), ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                ("sleep_time", ctypes.c_int32), ("curpri", ctypes.c_int32), ("priority", ctypes.c_int32),
                ("maxpriority", ctypes.c_int32), ("name", ctypes.c_char * 64)]


def thread_times(pid):
    """{thread name: cpu seconds} (PROC_PIDLISTTHREADS + PROC_PIDTHREADINFO; times in ns), same names summed."""
    buf = (ctypes.c_uint64 * 512)()
    n = _libproc.proc_pidinfo(pid, 6, ctypes.c_uint64(0), buf, ctypes.sizeof(buf))
    out = {}
    for i in range(max(0, n) // 8):
        ti = ProcThreadInfo()
        if _libproc.proc_pidinfo(pid, 5, ctypes.c_uint64(buf[i]), ctypes.byref(ti), ctypes.sizeof(ti)) <= 0:
            continue
        name = ti.name.decode("utf-8", "replace") or "(unnamed)"
        out[name] = out.get(name, 0.0) + (ti.user_time + ti.system_time) / 1e9
    return out


def thread_delta(a, b, seconds):
    """Per-thread % of a core between two thread_times snapshots, busiest first, threads above 0.5 %."""
    d = {k: (b.get(k, 0.0) - a.get(k, 0.0)) / seconds * 100 for k in set(a) | set(b)}
    return {k: round(v, 1) for k, v in sorted(d.items(), key=lambda kv: -kv[1]) if v >= 0.5}


def loadavg():
    return os.getloadavg()


# ---------------------------------------------------------------------- QMP ----

class QMP:
    def __init__(self, path, timeout=60):
        deadline = time.time() + timeout
        while True:
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                self.s.close()
                if time.time() > deadline:
                    raise
                time.sleep(0.05)
        self.f = self.s.makefile("rwb", buffering=0)
        self.events = []
        self.lock = threading.Lock()
        self._read()
        self.cmd("qmp_capabilities")

    def _read(self):
        line = self.f.readline()
        if not line:
            raise EOFError("QMP closed")
        return json.loads(line)

    def cmd(self, name, **args):
        with self.lock:
            msg = {"execute": name}
            if args:
                msg["arguments"] = args
            self.f.write((json.dumps(msg) + "\n").encode())
            while True:
                r = self._read()
                if "event" in r:
                    self.events.append(r)
                    continue
                if "error" in r:
                    raise RuntimeError("%s: %s" % (name, r["error"]))
                return r.get("return")

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


# ------------------------------------------------------------------ machine ----

def esc(v):
    return str(v).replace(",", ",,")


def board_info(board):
    for m in json.load(open(MACHINES)):
        if m["board"] == board:
            return m
    raise SystemExit("no machine for " + board)


class Machine:
    """One qemu-system-arm process booting `base` (a firmwarekit create output) on the writable `state`
    (nor.bin + overlay/), as HostRuntime BootRecipe.iPad builds the app's argv."""

    def __init__(self, build, base, state, run, incoming=None, restrict=True):
        self.base, self.state, self.run = base, state, run
        os.makedirs(run, exist_ok=True)
        lock = json.load(open(os.path.join(base, "device.lock.json")))
        self.lock = lock
        hw = board_info(lock["board"])
        self.hw = hw
        self.ipod = hw["machine"] == "iPod-Touch"
        env = dict(os.environ)
        if self.ipod:
            # BootRecipe.iPod (the n72's direct-iBoot 3.x boot): the base NAND is an image store, so the emulator
            # writes a live clone under the overlay (PreparedDeviceBoot.liveNAND), not a page overlay.
            m = "%s,boot-args=%s,direct-iboot=%s,direct-llb=,bootrom=%s" % (
                hw["machine"], esc(IPOD_BOOT_ARGS), esc(os.path.join(base, "iBoot.bin")), esc(IPOD_BOOTROM))
            m += ",nand=%s,nor=%s,nor-rw=%s,wifi=on,gid-blobs=%s" % (
                esc(os.path.join(state, "overlay", "nand")), esc(os.path.join(base, "nor.bin")),
                esc(os.path.join(state, "nor.bin")), esc(os.path.join(base, "gid-blobs.bin")))
            env["IT_TVOUT_READY"] = "1"  # BootRecipe.iPod: 3.1.3 does not boot without it
        else:
            m = "%s,kboot=%s,nor-rw=%s" % (hw["machine"], esc(os.path.join(base, "kboot.bin")),
                                          esc(os.path.join(state, "nor.bin")))
            m += ",nand=%s,nand-overlay=%s" % (esc(os.path.join(base, "nand")), esc(os.path.join(state, "overlay")))
            m += ",die-id=%s" % esc(lock["identity"]["die_id"])
            if hw["hasCellular"]:
                m += ",baseband=on"
        for k, v in sorted((lock.get("machine") or {}).items()):
            m += ",%s=%s" % (k, esc(v))
        net = "user,id=wifi0" + (",restrict=on" if restrict else "") + ",lan=off"
        self.qmp_path = os.path.join(run, "qmp.sock")
        if os.path.exists(self.qmp_path):
            os.unlink(self.qmp_path)
        argv = [BUILDS[build], "-M", m] + (["-m", "128M"] if self.ipod else []) + [
                "-display", "none", "-no-shutdown", "-audio", "driver=none",
                "-serial", "file:" + os.path.join(run, "serial.log"),
                "-qmp", "unix:%s,server=on,wait=off" % self.qmp_path]
        if hw["hasUSBHost"]:
            argv += ["-device", "usb-kbd,bus=usb-bus.0,max-power=20"]
        argv += ["-netdev", net]
        if hw["hasCellular"]:
            argv += ["-netdev", net.replace("id=wifi0", "id=cell0")]
        if incoming:
            argv += ["-incoming", "file:" + incoming]
        self.argv = argv
        with open(os.path.join(run, "argv.json"), "w") as f:
            json.dump(argv, f, indent=1)
        self.qlog = open(os.path.join(run, "qemu.log"), "ab")
        self.t0 = time.time()
        self.p = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=self.qlog, stderr=self.qlog)
        self.qmp = QMP(self.qmp_path)
        self.seq = 0
        self.samples = []
        self._stop = False
        self.sampler = threading.Thread(target=self._sample, daemon=True)
        self.sampler.start()

    # CPU time series, every 0.5 s
    def _sample(self):
        while not self._stop and self.p.poll() is None:
            u = proc_usage(self.p.pid)
            if u:
                self.samples.append((time.time() - self.t0, u[0], u[1]))
            time.sleep(0.5)

    def cpu(self):
        u = proc_usage(self.p.pid)
        return u[0] if u else None

    def footprint(self):
        u = proc_usage(self.p.pid)
        return u[1] if u else None

    def elapsed(self):
        return time.time() - self.t0

    # input
    def touch(self, x, y, down):
        X, Y = int(max(0, min(1, x)) * 32767), int(max(0, min(1, y)) * 32767)
        ev = [{"type": "abs", "data": {"axis": "x", "value": X}}, {"type": "abs", "data": {"axis": "y", "value": Y}}]
        if down is not None:
            ev.append({"type": "btn", "data": {"down": down, "button": "left"}})
        self.qmp.cmd("input-send-event", events=ev)

    def tap(self, x, y, hold=0.06):
        self.touch(x, y, None)
        self.touch(x, y, True)
        time.sleep(hold)
        self.touch(x, y, False)

    def drag(self, x0, y0, x1, y1, seconds=0.35, steps=14):
        self.touch(x0, y0, None)
        self.touch(x0, y0, True)
        for i in range(1, steps + 1):
            time.sleep(seconds / steps)
            t = i / steps
            self.touch(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, True)
        time.sleep(0.05)
        self.touch(x1, y1, False)

    def home(self):
        if self.ipod:  # the n72 has no button-home property: Command+Shift+H (ipod_touch_kbd_button)
            keys = ["meta_l", "shift", "h"]
            for k in keys:
                self.qmp.cmd("input-send-event", events=[{"type": "key", "data": {"down": True,
                             "key": {"type": "qcode", "data": k}}}])
            time.sleep(0.15)
            for k in reversed(keys):
                self.qmp.cmd("input-send-event", events=[{"type": "key", "data": {"down": False,
                             "key": {"type": "qcode", "data": k}}}])
            return
        self.qmp.cmd("qom-set", path="/machine", property="button-home", value=True)
        time.sleep(0.15)
        self.qmp.cmd("qom-set", path="/machine", property="button-home", value=False)

    def power(self):
        """A short press of the hold (power) button: locks an unlocked screen, wakes a dark one."""
        if self.ipod:  # Command+L (ipod_touch_kbd_button)
            for k, down in (("meta_l", True), ("l", True), ("l", False), ("meta_l", False)):
                self.qmp.cmd("input-send-event", events=[{"type": "key", "data": {"down": down,
                             "key": {"type": "qcode", "data": k}}}])
                time.sleep(0.08)
            return
        self.qmp.cmd("qom-set", path="/machine", property="button-hold", value=True)
        time.sleep(0.15)
        self.qmp.cmd("qom-set", path="/machine", property="button-hold", value=False)

    def screenshot(self, path):
        self.qmp.cmd("screendump", filename=path, format="png")
        return path

    # guest agent (it_agent through hw/arm/ipod-agent.c: agent-request / agent-result)
    def agent_status(self):
        try:
            return self.qmp.cmd("qom-get", path="/machine", property="agent-status")
        except RuntimeError:
            return "error"

    def agent(self, op, timeout=10.0):
        self.seq += 1
        rid = "b%d" % self.seq
        try:
            self.qmp.cmd("qom-set", path="/machine", property="agent-request", value="%s %s\n" % (rid, op))
        except RuntimeError as e:
            return None, str(e)
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = self.qmp.cmd("qom-get", path="/machine", property="agent-result")
            if r:
                head, _, body = r.partition("\n")
                got, _, status = head.partition(" ")
                if got == rid:
                    return int(status), base64.b64decode(body).decode("utf-8", "replace")
                continue  # a stale result of an earlier, timed-out request
            time.sleep(0.15)
        try:
            self.qmp.cmd("qom-set", path="/machine", property="agent-cancel", value=rid)
        except RuntimeError:
            pass
        return None, "timeout"

    def frontmost(self, timeout=10.0):
        status, body = self.agent("frontmost", timeout)
        if status != 0:
            return None
        lines = body.split("\n")
        return (lines[0], lines[1] if len(lines) > 1 else "")

    def status(self):
        return self.qmp.cmd("query-status")["status"]

    def quit(self, timeout=60):
        self._stop = True
        try:
            self.qmp.cmd("quit")
        except (RuntimeError, EOFError, OSError):
            pass
        try:
            self.p.wait(timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
        self.qmp.close()
        self.dump_samples()

    def dump_samples(self):
        with open(os.path.join(self.run, "cpu-samples.tsv"), "w") as f:
            f.write("t\tcpu_s\tfootprint_bytes\n")
            for t, c, m in self.samples:
                f.write("%.2f\t%.3f\t%d\n" % (t, c, m))


def window(m, seconds, label, results, poll=None):
    """CPU over `seconds` of wall time from now; optional poll() each second."""
    c0, t0, th0 = m.cpu(), time.time(), thread_times(m.p.pid)
    la = loadavg()
    end = t0 + seconds
    while time.time() < end:
        if poll:
            poll()
        time.sleep(min(1.0, max(0.0, end - time.time())))
    c1, t1, th1 = m.cpu(), time.time(), thread_times(m.p.pid)
    pct = (c1 - c0) / (t1 - t0) * 100
    results[label] = {"seconds": round(t1 - t0, 2), "cpu_s": round(c1 - c0, 3), "pct_core": round(pct, 1),
                      "threads_pct": thread_delta(th0, th1, t1 - t0),
                      "loadavg_at_start": [round(x, 2) for x in la]}
    log("%s: %.1f%% of a core over %.0f s" % (label, pct, t1 - t0))
    return pct


def clone_state(src, dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    subprocess.check_call(["/bin/cp", "-cR", src, dst])


# --------------------------------------------------------------- Setup walk ----
# LightTouchMac tests/sessions SessionKit SetupPlan (SetupWalk.swift), on OCR'd labels.

PICKS = ["Start Using iPod touch", "Start Using iPod", "Start Using iPhone", "Get Started",
         "Set Up as New iPod touch", "Set Up as New iPod", "Set Up as New iPhone",
         "Disable Location Services", "Skip This Step", "Agree", "Don't Add Passcode",
         "Don't Use iCloud", "Don't Send", "United States"]
ALERT_YES = ["OK", "Skip", "Agree", "Continue", "Don't Use", "Don't Add"]
NEXT_ARROW = (587.0 / 640, 84.0 / 960)


def ocr(path):
    out = subprocess.run([OCR, path], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        try:
            o = json.loads(line)
        except ValueError:
            continue
        key = o["text"].replace("’", "'")
        while key and not key[0].isalnum():
            key = key[1:]
        if key and key not in found:
            found[key] = (o["x"], o["y"])
    return found


def setup_plan(found, pages):
    if "Cancel" in found and "Start Over" in found:
        return [("tap", found["Cancel"], "(Cancel)")]
    for yes in ALERT_YES:
        if yes in found:
            return [("tap", found[yes], "(%s)" % yes)]
    steps = []
    pick = next((p for p in PICKS if p in found), None)
    is_list = (pages and pages[-1] == "(scroll)") or any("countr" in k.lower() for k in found)
    if pick is None and is_list:
        names = sorted(k for k, v in found.items() if v[1] > 0.06 and k[:1].isupper()
                       and k not in ("Back", "Next") and "countr" not in k.lower() and "region" not in k.lower())
        if names:
            if names[0].lower() > "united states":
                return [("scroll", (0.25, 0.85), "(scroll)")]
            return [("scroll", (0.85, 0.25), "(scroll)")]
    if pick:
        again = pages.count(pick)
        x, y = found[pick]
        steps.append(("tap", (x, y + [0, -14, 14, -24, 24][again % 5] / 960), pick))
        if pick.startswith("Start Using") or pick == "Get Started":
            return steps
        steps.append(("pause", 1.5, None))
    if pick is None and "English" in found:
        steps += [("tap", found["English"], "English"), ("pause", 1.5, None)]
    nxt = found.get("Next") or (NEXT_ARROW if "English" in found else None)
    if nxt:
        steps.append(("tap", nxt, "Next"))
    elif pick is None:
        steps.append(("slide", None, "(slide)"))
    return steps


def walk_setup(m, shots, budget=1500):
    pages = []
    t0 = time.time()
    n = 0
    home_streak = 0
    while time.time() - t0 < budget:
        f = m.frontmost(5)
        if f and f[0] == "com.apple.springboard" and f[1] == "Home Screen":
            home_streak += 1
            if home_streak >= 2:
                log("Setup done: Home Screen after %.0f s, pages %s" % (time.time() - t0, pages))
                return pages
            time.sleep(2)
            continue
        home_streak = 0
        n += 1
        png = m.screenshot(os.path.join(shots, "setup-%03d.png" % n))
        time.sleep(0.3)
        found = ocr(png)
        plan = setup_plan(found, pages)
        log("setup page %d: frontmost %s; labels %s; plan %s" % (n, f, sorted(found)[:12], [s[2] for s in plan]))
        for kind, arg, label in plan:
            if kind == "tap":
                m.tap(arg[0], arg[1])
                pages.append(label)
            elif kind == "pause":
                time.sleep(arg)
            elif kind == "scroll":
                m.drag(0.5, arg[0], 0.5, arg[1], seconds=0.5)
                pages.append(label)
            elif kind == "slide":
                if f and f[1] == "Lock Screen" or not found or len(found) < 6:
                    m.home()
                    time.sleep(1.5)
                    m.drag(0.18, 0.9, 0.92, 0.9, seconds=0.6, steps=20)
                    pages.append(label)
        time.sleep(2.5)
    raise SystemExit("Setup walk ran out of budget; pages %s" % pages)


# ------------------------------------------------------------------ commands ----

def wait_frontmost(m, want, timeout, results=None, key=None, poll=1.0):
    """Wait until frontmost matches want(bundle, title); returns seconds since launch or None."""
    t_end = time.time() + timeout
    while time.time() < t_end:
        if m.p.poll() is not None:
            raise SystemExit("QEMU exited (%s)" % m.p.returncode)
        st = m.agent_status()
        if st == "alive":
            f = m.frontmost(min(10, max(1, t_end - time.time())))
            if f and want(*f):
                return f
        time.sleep(poll)
    return None


def unlock(m, tries=4):
    for i in range(tries):
        m.home()
        time.sleep(2.0)
        m.drag(0.18, 0.9, 0.92, 0.9, seconds=0.6, steps=20)
        time.sleep(2.5)
        f = m.frontmost(10)
        if f and f[1] != "Lock Screen":
            return f
    return m.frontmost(10)


def dismiss_alerts(m, shots, tries=4):
    """Tap OK on iOS 7's modal "Cannot Use Device / QEMU USB Keyboard" (the usb-kbd that BootRecipe.iPad attaches
    for key input on boards with a USB host): left up, it eats every touch and the Home button."""
    dismissed = 0
    for i in range(tries):
        png = m.screenshot(os.path.join(shots, "alert-check-%d.png" % i))
        time.sleep(0.3)
        found = ocr(png)
        if "Cannot Use Device" in found and "OK" in found:
            m.tap(*found["OK"])
            dismissed += 1
            time.sleep(2.0)
            continue
        if dismissed or i >= 1:
            break
        time.sleep(2.0)
    return dismissed


def cmd_setup(a):
    golden = a.golden
    if os.path.exists(golden):
        shutil.rmtree(golden)
    state = os.path.join(golden, "state")
    os.makedirs(os.path.join(state, "overlay"))
    shutil.copy(os.path.join(a.device, "nor.bin"), os.path.join(state, "nor.bin"))
    nand = os.path.join(a.device, "nand")
    if json.load(open(os.path.join(nand, "geometry.json"))).get("storage_format") in ("nand-xor-ff-v2",
                                                                                    "nand-xor-blank-v2"):
        # an image store (PreparedDeviceBoot.liveNAND): clonefile each chip into overlay/nand, made writable
        live = os.path.join(state, "overlay", "nand")
        os.makedirs(live)
        for name in sorted(os.listdir(nand)):
            subprocess.check_call(["/bin/cp", "-c", os.path.join(nand, name), os.path.join(live, name)])
            os.chmod(os.path.join(live, name), 0o644)
    os.chmod(os.path.join(state, "nor.bin"), 0o644)
    run = os.path.join(golden, "setup-run")
    shots = os.path.join(run, "shots")
    os.makedirs(shots, exist_ok=True)
    m = Machine("jit", a.device, state, run)
    log("booting %s for Setup" % a.device)
    f = wait_frontmost(m, lambda b, t: True, 900)
    log("first frontmost after %.0f s: %s" % (m.elapsed(), f))
    pages = walk_setup(m, shots)
    time.sleep(3)
    m.screenshot(os.path.join(golden, "home-after-setup.png"))
    log("powering off (system_powerdown, the machine's gesture)")
    m.qmp.cmd("system_powerdown")
    t = time.time()
    while time.time() - t < 120:
        st = m.status()
        if st in ("shutdown",) or m.p.poll() is not None:
            break
        time.sleep(1)
    log("power-off state %s after %.0f s" % (m.status() if m.p.poll() is None else "exited", time.time() - t))
    m.quit()
    with open(os.path.join(golden, "setup.json"), "w") as fh:
        json.dump({"pages": pages}, fh, indent=1)


def cmd_run(a):
    res = {"device": a.device, "build": a.build, "argv": None, "started": time.strftime("%Y-%m-%dT%H:%M:%S")}
    out = a.out
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)
    state = os.path.join(out, "state")
    clone_state(os.path.join(a.golden, "state"), state)
    boot_timeout = 600 if a.build == "jit" else 3600
    slow = 1 if a.build == "jit" else a.slow
    res["host_loadavg_before"] = [round(x, 2) for x in loadavg()]

    # 1. cold boot to the lock screen
    m = Machine(a.build, a.device, state, os.path.join(out, "boot"))
    res["argv"] = m.argv
    t_agent = None
    while m.elapsed() < boot_timeout:
        if m.p.poll() is not None:
            raise SystemExit("QEMU exited during boot")
        if t_agent is None and m.agent_status() == "alive":
            t_agent = m.elapsed()
            res["agent_alive_s"] = round(t_agent, 2)
            res["agent_alive_cpu_s"] = round(m.cpu(), 2)
            log("agent alive at %.1f s" % t_agent)
        if t_agent is not None:
            f = m.frontmost(10)
            if f and f[0] == "com.apple.springboard" and f[1] in ("Lock Screen", "Home Screen"):
                res["boot_s"] = round(m.elapsed(), 2)
                res["boot_cpu_s"] = round(m.cpu(), 2)
                res["boot_frontmost"] = list(f)
                res["boot_threads_cpu_s"] = {k: round(v, 2) for k, v in thread_times(m.p.pid).items() if v >= 0.05}
                log("boot: %s after %.1f s, %.1f CPU s" % (f[1], res["boot_s"], res["boot_cpu_s"]))
                break
        time.sleep(0.5)
    else:
        m.screenshot(os.path.join(out, "boot-timeout.png"))
        m.quit()
        raise SystemExit("no lock screen within %d s" % boot_timeout)
    m.screenshot(os.path.join(out, "lock.png"))

    # 2. settle: until a 10 s window uses under 60 % of a core (cap)
    cap = 180 if a.build == "jit" else 300  # iOS 7's lock screen shimmer keeps a TCI guest above 60 % for good
    t_s = time.time()
    while time.time() - t_s < cap:
        c0, w0 = m.cpu(), time.time()
        time.sleep(10)
        pct = (m.cpu() - c0) / (time.time() - w0) * 100
        if pct < 60:
            break
    res["settle_s"] = round(m.elapsed(), 2)
    res["settle_cpu_s"] = round(m.cpu(), 2)
    res["settle_threads_cpu_s"] = {k: round(v, 2) for k, v in thread_times(m.p.pid).items() if v >= 0.05}
    log("settled at %.0f s (%.1f CPU s), last 10 s %.0f%%" % (res["settle_s"], res["settle_cpu_s"], pct))

    # 3. unlock, idle on Home
    f = unlock(m)
    res["after_unlock"] = list(f) if f else None
    log("after unlock: %s" % (f,))
    res["alerts_dismissed"] = dismiss_alerts(m, out)
    if res["alerts_dismissed"]:
        log("dismissed %d alert(s)" % res["alerts_dismissed"])
    m.screenshot(os.path.join(out, "home.png"))
    time.sleep(3)
    window(m, 40, "idle_home", res)

    # 4. page flips on Home: five there-and-back swipes
    def flips():
        for i in range(5):
            m.drag(0.85, 0.45, 0.15, 0.45, seconds=0.25, steps=10)
            time.sleep(1.6)
            if i == 2:
                m.screenshot(os.path.join(out, "home-page2.png"))
            m.drag(0.15, 0.45, 0.85, 0.45, seconds=0.25, steps=10)
            time.sleep(1.6)
    c0, t0, th0 = m.cpu(), time.time(), thread_times(m.p.pid)
    flips()
    c1, t1, th1 = m.cpu(), time.time(), thread_times(m.p.pid)
    res["page_flips"] = {"seconds": round(t1 - t0, 2), "cpu_s": round(c1 - c0, 3),
                         "pct_core": round((c1 - c0) / (t1 - t0) * 100, 1),
                         "threads_pct": thread_delta(th0, th1, t1 - t0)}
    log("page flips: %.1f%% over %.0f s" % (res["page_flips"]["pct_core"], t1 - t0))

    # 5. open Settings, then Clock, each by the agent's launch (SBSLaunchApplicationWithIdentifier)
    for bundle, label in (("com.apple.Preferences", "open_settings"), ("com.apple.mobiletimer", "open_clock")):
        c0, t0, th0 = m.cpu(), time.time(), thread_times(m.p.pid)
        st, body = m.agent("launch " + bundle, 15)
        opened = None
        while time.time() - t0 < 60 * slow:
            ff = m.frontmost(10)
            if ff and ff[0] == bundle:
                opened = time.time() - t0
                break
            time.sleep(0.25)
        time.sleep(max(0, 10 - (time.time() - t0)))
        c1, t1, th1 = m.cpu(), time.time(), thread_times(m.p.pid)
        res[label] = {"launch_status": st, "frontmost_after_s": round(opened, 2) if opened else None,
                      "seconds": round(t1 - t0, 2), "cpu_s": round(c1 - c0, 3),
                      "pct_core": round((c1 - c0) / (t1 - t0) * 100, 1),
                      "threads_pct": thread_delta(th0, th1, t1 - t0)}
        m.screenshot(os.path.join(out, label + ".png"))
        log("%s: frontmost after %s s, %.1f%% over %.0f s" % (label, res[label]["frontmost_after_s"],
                                                             res[label]["pct_core"], t1 - t0))
        m.home()
        time.sleep(3)
    f = m.frontmost(10)
    res["before_snapshot_frontmost"] = list(f) if f else None
    time.sleep(5)

    # 6. snapshot: stop, migrate to a file
    snap = os.path.join(out, "snapshot.bin")
    t0 = time.time()
    m.qmp.cmd("stop")
    try:
        m.qmp.cmd("migrate", uri="file:" + snap)
        while True:
            q = m.qmp.cmd("query-migrate")
            if q.get("status") in ("completed", "failed", "cancelled"):
                break
            time.sleep(0.05)
        save_s = time.time() - t0
        res["snapshot_save"] = {"status": q.get("status"), "seconds": round(save_s, 3),
                                "bytes": os.path.getsize(snap) if os.path.exists(snap) else None,
                                "ram": q.get("ram"), "error": q.get("error-desc")}
    except RuntimeError as e:
        res["snapshot_save"] = {"status": "refused", "error": str(e)}
    log("snapshot save: %s" % res["snapshot_save"])
    m.quit()
    res["boot_run_cpu_total_s"] = round(m.samples[-1][1], 2) if m.samples else None

    # 7. restore from the snapshot on a clone of the state it was saved with
    if res["snapshot_save"].get("status") == "completed":
        for r in range(a.restores):
            rstate = os.path.join(out, "restore%d-state" % r)
            clone_state(state, rstate)
            rr = {}
            mr = Machine(a.build, a.device, rstate, os.path.join(out, "restore%d" % r), incoming=snap)
            while True:
                st = mr.status()
                if st in ("running", "paused", "postmigrate") and mr.qmp.cmd("query-migrate").get("status") in (
                        "completed", None):
                    break
                if mr.p.poll() is not None or mr.elapsed() > 300 * slow:
                    break
                time.sleep(0.02)
            rr["loaded_s"] = round(mr.elapsed(), 3)
            rr["state_after_load"] = st
            if st != "running":
                mr.qmp.cmd("cont")
            rr["running_s"] = round(mr.elapsed(), 3)
            rr["running_cpu_s"] = round(mr.cpu(), 3)
            log("restore %d: loaded %.2f s (%s), running at %.2f s" % (r, rr["loaded_s"], st, rr["running_s"]))
            f = None
            t_end = time.time() + 60 * slow
            while time.time() < t_end and f is None:
                f = mr.frontmost(5)
            rr["first_frontmost"] = list(f) if f else None
            rr["first_frontmost_s"] = round(mr.elapsed(), 2)
            mr.screenshot(os.path.join(out, "restore%d.png" % r))
            # does input work after the restore: launch Settings by a tap on its icon (OCR), else the agent
            labels = ocr(os.path.join(out, "restore%d.png" % r))
            if "Settings" in labels:
                x, y = labels["Settings"]
                mr.tap(x, y - 0.045)
                t0 = time.time()
                got = None
                while time.time() - t0 < 30 * slow:
                    ff = mr.frontmost(5)
                    if ff and ff[0] == "com.apple.Preferences":
                        got = time.time() - t0
                        break
                    time.sleep(0.25)
                rr["tap_settings_opened_s"] = round(got, 2) if got else None
                mr.screenshot(os.path.join(out, "restore%d-tap.png" % r))
                mr.home()
                time.sleep(3)
            window(mr, 30, "idle_after_restore", rr)
            mr.quit()
            res.setdefault("restores", []).append(rr)
    res["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open(os.path.join(out, "result.json"), "w") as fh:
        json.dump(res, fh, indent=1)
    log("result: %s" % os.path.join(out, "result.json"))


def cmd_fps(a):
    """Frame rate while SpringBoard redraws continuously: restore a run's snapshot (on a clone of its state, as the
    restores in cmd_run), hold a finger on the Home screen and sway it left and right for `seconds`, and read the
    GL bridge's own frame accounting (IT_GLES_PROF=1: every 60 presents, "[gles] N frames; last 60 in X ms")."""
    out = a.out
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)
    state = os.path.join(out, "state")
    clone_state(os.path.join(a.run, "state"), state)
    os.environ["IT_GLES_PROF"] = "1"
    res = {"run": a.run, "build": a.build, "mode": a.mode, "host_loadavg_before": [round(x, 2) for x in loadavg()]}
    m = Machine(a.build, a.device, state, os.path.join(out, "vm"), incoming=os.path.join(a.run, "snapshot.bin"))
    while m.status() not in ("running", "paused", "postmigrate"):
        time.sleep(0.02)
    if m.status() != "running":
        m.qmp.cmd("cont")
    t_end = time.time() + 60
    while time.time() < t_end and not m.frontmost(5):
        pass
    time.sleep(3)
    m.screenshot(os.path.join(out, "before.png"))
    qlog = os.path.join(out, "vm", "qemu.log")
    m.qlog.flush()
    off = os.path.getsize(qlog)
    c0, w0, th0 = m.cpu(), time.time(), thread_times(m.p.pid)
    import math
    import hashlib
    if a.mode == "lock":
        # the lock screen's "slide to unlock" shimmer: a continuous animation no touch drives
        m.power()
        time.sleep(2)
        m.home()
        time.sleep(a.wake_wait)
        # until the panel is lit (a TCI guest takes seconds to wake), then a beat for the fade-in
        lit_dump = os.path.join(out, "lit.ppm")
        t_wake = time.time()
        while time.time() - t_wake < 20:
            m.qmp.cmd("screendump", filename=lit_dump, format="ppm")
            if max(open(lit_dump, "rb").read()[-200000:]) > 40:
                break
            time.sleep(0.1)
        res["lit_after_home_s"] = round(a.wake_wait + time.time() - t_wake, 2)
        os.unlink(lit_dump)
        time.sleep(0.7)
        m.screenshot(os.path.join(out, "lock.png"))
        qlog_off = os.path.getsize(qlog)
        c0, w0, th0 = m.cpu(), time.time(), thread_times(m.p.pid)
    else:
        m.touch(0.5, 0.45, None)
        m.touch(0.5, 0.45, True)
    t0 = time.time()
    n = 0
    # what the panel shows, sampled as fast as screendump goes: a sample that differs from the one before is a new
    # frame on screen (the visible rate, capped by the sampling rate)
    dump = os.path.join(out, "sample.ppm")
    samples, last, changes = 0, None, []
    while time.time() - t0 < a.seconds:
        t = time.time() - t0
        if a.mode == "drag":
            m.touch(0.5 + 0.3 * math.sin(2 * math.pi * t / 2.0), 0.45, True)
            n += 1
        m.qmp.cmd("screendump", filename=dump, format="ppm")
        h = hashlib.md5(open(dump, "rb").read()).digest()
        samples += 1
        if last is not None and h != last:
            changes.append(time.time() - t0)
        last = h
        time.sleep(max(0.0, t0 + samples / a.sample_hz - time.time()))
    if a.mode == "drag":
        m.touch(0.5, 0.45, False)
    c1, w1, th1 = m.cpu(), time.time(), thread_times(m.p.pid)
    os.unlink(dump)
    time.sleep(1)
    m.screenshot(os.path.join(out, "after.png"))
    m.quit()
    with open(qlog, "rb") as f:
        f.seek(off)
        text = f.read().decode("utf-8", "replace")
    reports = []
    for line in text.splitlines():
        if line.startswith("[gles] ") and " frames; last 60 in " in line:
            frames = int(line.split()[1])
            ms = int(line.split(" last 60 in ")[1].split()[0])
            reports.append((frames, ms))
    # the first report's interval began before the drag; the rest are whole 60-frame spans inside it
    inside = reports[1:]
    res.update({"seconds": round(w1 - w0, 2), "touch_events": n, "cpu_pct_core": round((c1 - c0) / (w1 - w0) * 100, 1),
                "threads_pct": thread_delta(th0, th1, w1 - w0), "reports": reports,
                "fps": round(60 * len(inside) / (sum(ms for _, ms in inside) / 1000), 1) if inside else None,
                "presents_in_window": (reports[-1][0] - reports[0][0] + 60) if reports else 0,
                "screen_samples": samples, "sample_hz": round(samples / (w1 - w0), 1),
                "screen_changes": len(changes), "visible_fps": round(len(changes) / (w1 - w0), 1),
                # the slowest second: the fewest new frames in any whole one-second slice of the drag
                "visible_fps_min_1s": min(sum(1 for c in changes if k <= c < k + 1) for k in range(int(w1 - w0)))})
    with open(os.path.join(out, "fps.json" if a.mode == "drag" else "fps-lock.json"), "w") as fh:
        json.dump(res, fh, indent=1)
    log("fps %s %s: visible %s fps (slowest second %s, sampled at %s Hz), GL reports %s fps, %.1f%% of a core" % (
        a.mode, a.build, res["visible_fps"], res["visible_fps_min_1s"], res["sample_hz"], res["fps"], res["cpu_pct_core"]))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--device", required=True)
    s.add_argument("--golden", required=True)
    r = sub.add_parser("run")
    r.add_argument("--device", required=True)
    r.add_argument("--golden", required=True)
    r.add_argument("--build", choices=BUILDS, required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--restores", type=int, default=2)
    r.add_argument("--slow", type=int, default=6, help="timeout multiplier for the interpreter")
    f = sub.add_parser("fps")
    f.add_argument("--device", required=True)
    f.add_argument("--run", required=True, help="a finished run: its snapshot.bin and state/")
    f.add_argument("--build", choices=BUILDS, required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--seconds", type=float, default=20)
    f.add_argument("--sample-hz", type=float, default=120, help="screendumps per second, at most")
    f.add_argument("--mode", choices=("drag", "lock"), default="drag")
    f.add_argument("--wake-wait", type=float, default=1.5, help="lock mode: seconds from Home to sampling")
    a = ap.parse_args()
    a.device = os.path.abspath(a.device)
    if a.cmd != "fps":
        a.golden = os.path.abspath(a.golden)
    if a.cmd == "setup":
        cmd_setup(a)
    elif a.cmd == "fps":
        a.run = os.path.abspath(a.run)
        a.out = os.path.abspath(a.out)
        cmd_fps(a)
    else:
        a.out = os.path.abspath(a.out)
        cmd_run(a)


if __name__ == "__main__":
    main()
