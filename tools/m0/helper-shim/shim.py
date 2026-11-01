"""M0 stand-in for LightTouchMac's LightTouchDevice helper, for `firmwarekit create --helper`.

firmwarekit only uses two helper modes while preparing a device (HostRuntime HelperLaunch):
  machines  print {"dylibPath", "machines": [DeviceInfo...]}           (DeviceInfo.list)
  oneshot   boot argv until QEMU exits, a serial marker or a timeout;   (Preparer.oneshot, LightTouchDevice
            print {"event":"oneshot","exited","exitCode","marker","seconds"}   main.swift runOneShot)
The real helper runs the emulator in-process from libqemu-arm.dylib; this one runs the same argv through a
qemu-system-arm binary ($LTM_SHIM_QEMU) instead, so the Xcode-built, signed helper is not needed.
The machine listing is LightTouchMac's tests/fixtures/machines.json (the emulator's qemu_ios_device_info table).
"""
import json, os, re, signal, subprocess, sys, time

ROOT = "/path/to/classic-ios"
QEMU = os.environ.get("LTM_SHIM_QEMU", ROOT + "/work/build-jit/qemu-system-arm")
MACHINES = ROOT + "/upstream/LightTouchMac/tests/fixtures/machines.json"

def emit(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=True) + "\n")
    sys.stdout.flush()

def log(msg):
    sys.stderr.write("LightTouchDevice-shim: " + msg + "\n")
    sys.stderr.flush()

def machines():
    with open(MACHINES) as f:
        listing = json.load(f)
    emit({"dylibPath": QEMU, "machines": listing})
    return 0

def oneshot(path):
    signal.pthread_sigmask(signal.SIG_SETMASK, [])
    with open(path) as f:
        cfg = json.load(f)
    boot = cfg["boot"]
    argv = [QEMU] + list(boot["argv"][1:])
    env = dict(os.environ)
    env.update(boot.get("environment") or {})
    serial = cfg["serialLog"]
    marker_text = cfg.get("stopMarker")
    pattern = re.compile(cfg["stopPattern"]) if cfg.get("stopPattern") else None
    timeout = float(cfg["timeout"])
    qlog = open(serial + ".qemu.log", "ab")
    log("argv: " + " ".join(argv))
    start = time.monotonic()
    # firmwarekit spawns its helper from a thread that blocks SIGTERM, and a signal mask survives exec: unblocked
    # here, or QEMU never sees the SIGTERM that stops it at the marker.
    def child_signals():
        signal.pthread_sigmask(signal.SIG_SETMASK, [])
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(s, signal.SIG_DFL)
    p = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=qlog, stderr=qlog, preexec_fn=child_signals)
    marker = False
    stopping = False
    def stop(sig):
        nonlocal stopping
        stopping = True
        try:
            p.send_signal(sig)
        except ProcessLookupError:
            pass
    signal.signal(signal.SIGTERM, lambda *_: stop(signal.SIGTERM))
    signal.signal(signal.SIGINT, lambda *_: stop(signal.SIGTERM))
    while p.poll() is None:
        time.sleep(0.25)
        if (marker_text or pattern) and not marker and os.path.exists(serial):
            with open(serial, "rb") as f:
                text = f.read().decode("latin-1")
            if (marker_text and marker_text in text) or (pattern and pattern.search(text.replace("\n", ""))):
                marker = True
                log("stop marker seen after %.1f s" % (time.monotonic() - start))
                stop(signal.SIGTERM)
        if time.monotonic() - start > timeout and not stopping:
            log("timeout after %.0f s" % timeout)
            stop(signal.SIGTERM)
        if stopping and time.monotonic() - start > timeout + 30:
            p.kill()
    code = p.returncode if p.returncode >= 0 else 128 - p.returncode
    exited = not stopping
    emit({"event": "oneshot", "exited": exited, "exitCode": code, "marker": marker,
          "seconds": time.monotonic() - start})
    return 0 if marker else (code if exited else 124)

def main():
    if len(sys.argv) != 2:
        log("takes one argument, its launch as JSON")
        return 64
    launch = json.loads(sys.argv[1])
    mode = launch["mode"]
    if "machines" in mode:
        return machines()
    if "oneshot" in mode:
        return oneshot(mode["oneshot"]["config"])
    log("unsupported mode: " + json.dumps(mode))
    return 64

sys.exit(main())
