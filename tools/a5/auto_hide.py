#!/usr/bin/env python3
"""Bring-up loop: boot, and while the kernel stalls, hide the device it last touched and boot again.

    auto_hide.py BUILD [ROUNDS] [SECONDS]

Each round builds kboot/n78-BUILD.bin with N78_HIDE (n78_kboot.py), runs QEMU for SECONDS, then:
  - root wait on the console ("Waiting on", "Still waiting for root") -> done;
  - a panic -> stop and report it;
  - otherwise the top-level arm-io node holding the last unimplemented access is hidden, unless it is one
    of the modeled or boot-essential blocks, which stops the loop.
Writes runs/BUILD-auto.log (one line per round) and leaves the last round's serial and unimp logs.
"""
import os, re, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "imgtools"))
import ipad1_kboot as kb  # noqa: E402

KEEP = {"arm-io/aic", "arm-io/pmgr", "arm-io/gpio", "arm-io/i2c0", "arm-io/i2c2", "arm-io/uart1",
        "arm-io/wdt", "arm-io/pl310"}
UNIMP = re.compile(r"unimplemented device (?:read|write) +\(size \d, offset 0x([0-9a-f]+)")
ROOT = re.compile(r"Waiting on|Still waiting for root|waiting for root", re.I)


def node_for(dt, off):
    for path, props in dt.props.items():
        if not path.startswith("arm-io/") or path.count("/") > 1 or "reg" not in props:
            continue
        o, ln = props["reg"]
        regs = struct.unpack_from("<%dI" % (ln // 4), dt.buf, o + 36)
        for i in range(0, len(regs) - 1, 2):
            if regs[i] <= off < regs[i] + max(regs[i + 1], 1):
                return path
    return None


def main(build, rounds=10, seconds=60):
    rounds, seconds = int(rounds), int(seconds)
    dec = os.path.join(HERE, "dec", build)
    dt = kb.DeviceTree(open(os.path.join(dec, "DeviceTree.bin"), "rb").read())
    hidden = [p for p in os.environ.get("N78_HIDE", "").split(",") if p]
    serial, qlog = (os.path.join(HERE, "runs", f"{build}-{x}") for x in ("serial.log", "q.log"))
    out = open(os.path.join(HERE, "runs", f"{build}-auto.log"), "w")

    def say(msg):
        print(msg, flush=True)
        out.write(msg + "\n")
        out.flush()

    for r in range(1, rounds + 1):
        env = dict(os.environ, N78_HIDE=",".join(hidden))
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "n78_kboot.py"), dec,
                        os.path.join(HERE, "kboot", f"n78-{build}.bin")], env=env, check=True,
                       stdout=subprocess.DEVNULL)
        for f in (serial, qlog):
            if os.path.exists(f):
                os.remove(f)
        p = subprocess.Popen([os.path.join(HERE, "build", "qemu-system-arm"), "-M",
                              f"iPod-Touch-5G,kboot={os.path.join(HERE, 'kboot', f'n78-{build}.bin')}",
                              "-display", "none", "-serial", f"file:{serial}", "-monitor", "none",
                              "-d", "unimp,guest_errors", "-D", qlog],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            p.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        con = open(serial, "rb").read().decode("utf-8", "replace") if os.path.exists(serial) else ""
        last = [l for l in con.splitlines() if l.strip()][-1:] or [""]
        if ROOT.search(con):
            say(f"round {r}: ROOT WAIT reached; hidden {hidden}")
            return
        m = re.search(r"panic\(.*", con)
        if m:
            say(f"round {r}: PANIC {m.group(0)[:200]}; hidden {hidden}")
            return
        offs = [int(x, 16) for x in UNIMP.findall(open(qlog).read())] if os.path.exists(qlog) else []
        node = next((n for n in (node_for(dt, o) for o in reversed(offs[-50:])) if n), None)
        if not node or node in KEEP or node in hidden:
            say(f"round {r}: STALL, last device {node}; console ends: {last[0][:150]}; hidden {hidden}")
            return
        hidden.append(node)
        say(f"round {r}: stalled at {node} (console ends: {last[0][:100]}); hiding it")
    say(f"out of rounds; hidden {hidden}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
