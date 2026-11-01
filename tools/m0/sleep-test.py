#!/usr/bin/env python3
"""M0: does a restored iPod touch 2G come back from sleep with the placeholder SecureROM?
Restore a run's snapshot, lock with the power button (Command+L), wait, wake with Home, ask the agent what is
frontmost, and read the serial log for the PMU's AP power-off (a wake from that runs the boot ROM).
usage: sleep-test.py RUN OUT [WAIT_S]"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench

run, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
wait = float(sys.argv[3]) if len(sys.argv) > 3 else 120
dev = bench.ROOT + "/work/devices/n72ap-7E18"
if os.path.exists(out):
    bench.shutil.rmtree(out)
os.makedirs(out)
state = os.path.join(out, "state")
bench.clone_state(os.path.join(run, "state"), state)
m = bench.Machine("jit", dev, state, os.path.join(out, "vm"), incoming=os.path.join(run, "snapshot.bin"))
while m.status() not in ("running", "paused", "postmigrate"):
    time.sleep(0.02)
if m.status() != "running":
    m.qmp.cmd("cont")
bench.log("restored; frontmost %s" % (m.frontmost(10),))


def power():
    for k, down in (("meta_l", True), ("l", True), ("l", False), ("meta_l", False)):
        m.qmp.cmd("input-send-event", events=[{"type": "key", "data": {"down": down,
                  "key": {"type": "qcode", "data": k}}}])
        time.sleep(0.1)


power()
bench.log("power pressed (lock); waiting %.0f s" % wait)
t0 = time.time()
while time.time() - t0 < wait:
    time.sleep(5)
    bench.log("  %3.0f s: status %s, agent %s, cpu %.1f s" % (time.time() - t0, m.status(), m.agent_status(), m.cpu()))
m.screenshot(os.path.join(out, "asleep.png"))


def pc(tag):
    """The ARM core's r15 (HMP info registers): 0 after the wake means it reset into the SecureROM image."""
    r = m.qmp.cmd("human-monitor-command", **{"command-line": "info registers"})
    bench.log(tag, " | ".join(x.strip() for x in r.splitlines() if "R12=" in x or "PSR=" in x))


pc("asleep:")
m.home()
time.sleep(3)
f = m.frontmost(20)
bench.log("after Home: frontmost %s, agent %s" % (f, m.agent_status()))
pc("after Home:")
m.screenshot(os.path.join(out, "after-wake.png"))
m.quit()
