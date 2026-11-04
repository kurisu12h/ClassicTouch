"""The E2 debugger: attach to the app on the phone that is "waiting for a debugger" (-waitdebugger YES) and answer
QEMU's requests to prepare the JIT code region.

Two protocols (tcg/region.c, patches/ios-txm-jit-protocol.patch):
- Universal protocol (default): brk #0xf00d, x16 is the command. x16=1 prepares the code region: when x0 is 0 the
  debugger allocates it, here with SBProcess.AllocateMemory (debugserver's _M packet, which returns executable
  memory), then has the debugger write every page (TXM only accepts pages the debugger has written; without the writes
  the generated code does not run on iOS 27.2, as measured), and writes the address back to x0.
  x16=0 detaches: the debugger detaches and exits, and the app then runs without a debugger.
  JIT_TOUCH picks how to write: bulk (default) writes zeros over the whole block, limited by bandwidth, about 2 MB/s
  over Wi-Fi; page writes 1 byte per 16 KiB page like StikDebug's prepare_memory_region, limited by the round trip,
  about 29 ms per page over Wi-Fi; none only allocates.
- Legacy protocol: brk #0x69; like upstream's lldb_jit.py (same directory, recovered as is), read the whole range
  that x0/x1 point at and write it back.

Written as a standalone script on LLDB's SB API, in synchronous mode, handling every stop itself, instead of a stop
hook in the lldb command line: Xcode 27.2's lldb command-line driver crashes in the event thread with this kind of use
(ProcessGDBRemote::WillPublicStop), and also when loading modules in parallel
(PlatformDarwinDevice::GetDeviceSupportDirectoryForOSVersion).

Usage: xcrun python3 scripts/ios/lldb_jit_runner.py <CoreDevice identifier> <PID>
(Use the Python that comes with Xcode; the script adds the LLDB module path that `xcrun lldb -P` gives.)
SPDX-License-Identifier: GPL-2.0-or-later
"""

import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, subprocess.check_output(["xcrun", "lldb", "-P"], text=True).strip())
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lldb  # noqa: E402
import lldb_jit  # noqa: E402

# Signals QEMU uses itself (kicking vCPU threads, sigaltstack coroutines and so on) must reach the process as usual
PASS = ["SIGUSR1", "SIGUSR2", "SIGALRM", "SIGPIPE", "SIGURG", "SIGVTALRM", "SIGPROF"]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Stream:
    def Print(self, text):
        log(text.rstrip())


PAGE = 16384


def brk_immediate(word):
    """AArch64 BRK #imm16 is 1101 0100 001 imm16 00000; returns None if it is not a brk."""
    if (word & 0xFFE0001F) != 0xD4200000:
        return None
    return (word >> 5) & 0xFFFF


INTERP = None  # set in main(), for write_regs' fallback


def write_regs(thread, values):
    """Change registers (x0, pc) of the stopped thread and read them back to check. Writing through SBValue sometimes
    does not take (seen in stage 2: pc did not skip the brk, and the same brk fired over and over); if so, select this
    thread and write them again with the register write command."""
    frame = thread.GetFrameAtIndex(0)
    for name, value in values.items():
        err = lldb.SBError()
        frame.FindRegister(name).SetValueFromCString("%#x" % value, err)
    frame = thread.GetFrameAtIndex(0)
    bad = sorted(n for n, v in values.items() if frame.FindRegister(n).GetValueAsUnsigned() != v)
    if not bad:
        return True
    thread.GetProcess().SetSelectedThread(thread)
    for name in bad:
        r = lldb.SBCommandReturnObject()
        INTERP.HandleCommand("register write %s %#x" % (name, values[name]), r)
    frame = thread.GetFrameAtIndex(0)
    still = sorted(n for n, v in values.items() if frame.FindRegister(n).GetValueAsUnsigned() != v)
    log("registers %s did not take on the first write; rewriting with register write: %s" % (bad, "still wrong %s" % still if still else "fixed"))
    return not still


def prepare_region(process, frame):
    """brk #0xf00d, x16=1: allocate (when x0 is 0) and write 1 byte per page, write the address back to x0, skip the brk."""
    addr = frame.FindRegister("x0").GetValueAsUnsigned()
    size = frame.FindRegister("x1").GetValueAsUnsigned()
    err = lldb.SBError()
    t0 = time.time()
    if addr == 0:
        addr = process.AllocateMemory(size, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, err)
        if not err.Success() or addr in (0, lldb.LLDB_INVALID_ADDRESS):
            log("failed to allocate %d MiB of executable memory: %s" % (size >> 20, err))
            addr = 0
    t1 = time.time()
    pages = 0
    if addr and os.environ.get("JIT_TOUCH", "bulk") == "page":
        total = (size + PAGE - 1) // PAGE
        for off in range(0, size, PAGE):
            process.WriteMemory(addr + off, b"\x69", err)
            if not err.Success():
                log("write at %#x failed: %s" % (addr + off, err))
                break
            pages += 1
            if pages % 512 == 0:
                dt = time.time() - t1
                log("page writes %d/%d pages, %.1f s, %.1f ms per page" % (pages, total, dt, dt / pages * 1000))
    elif addr and os.environ.get("JIT_TOUCH", "bulk") == "bulk":
        # Zeros over the whole block: limited by bandwidth, not by the round trip (page writes over Wi-Fi take about
        # 29 ms per page)
        chunk = 4 << 20
        zeros = bytes(chunk)
        for off in range(0, size, chunk):
            n = min(chunk, size - off)
            process.WriteMemory(addr + off, zeros[:n], err)
            if not err.Success():
                log("write at %#x failed: %s" % (addr + off, err))
                break
            pages += n // PAGE
            if (off + n) % (16 << 20) == 0:
                dt = time.time() - t1
                log("bulk write %d/%d MiB, %.1f s, %.2f MB/s" % ((off + n) >> 20, size >> 20, dt, (off + n) / dt / 1e6))
    t2 = time.time()
    write_regs(frame.GetThread(), {"x0": addr, "pc": frame.GetPC() + 4})
    log("code region: %d MiB at %#x, allocated in %.2f s, page writes %d pages in %.2f s" % (size >> 20, addr, t1 - t0, pages, t2 - t1))
    return addr != 0


def main():
    core, pid = sys.argv[1], sys.argv[2]
    lldb.SBDebugger.Initialize()
    dbg = lldb.SBDebugger.Create()
    dbg.SetAsync(False)
    interp = dbg.GetCommandInterpreter()
    global INTERP
    INTERP = interp

    def run(cmd):
        r = lldb.SBCommandReturnObject()
        interp.HandleCommand(cmd, r)
        log(cmd, "->", "ok" if r.Succeeded() else "failed", ((r.GetOutput() or "") + (r.GetError() or "")).strip()[:300])
        return r.Succeeded()

    # Without a symbol cache for the phone's current OS version on this machine, reading each system module's symbol
    # table goes over the network and attaching gets slow enough to time out; segment information alone is enough
    run("settings set target.memory-module-load-level minimal")
    run("settings set target.parallel-module-load false")
    # Over Wi-Fi the default gdb-remote packet timeout is too short; continuing reports Resume timed out and then stays
    # stuck
    run("settings set plugin.process.gdb-remote.packet-timeout 60")
    if os.environ.get("LLDB_PACKET_LOG"):  # for debugging: detailed log of gdb-remote packets and process state
        run("log enable -f %s gdb-remote packets process" % os.environ["LLDB_PACKET_LOG"])
    # Do not attach unless the device is selected: without a selection the default device is attached, the wrong one
    # when another phone is connected too. While the phone is locked, device select reports "Device needs to be
    # unlocked." and attaching is followed by a run of Resume timed out: wait for the user to unlock, at most 2 minutes
    # (docs/reports/ios-device-14pro.md section 7). An error without text counts as selected (seen on the 14 Pro, where
    # attaching then worked normally).
    for i in range(60):
        r = lldb.SBCommandReturnObject()
        interp.HandleCommand("device select " + core, r)
        err = (r.GetError() or "").strip()
        if r.Succeeded() or not err:
            log("device select ->", "ok" if r.Succeeded() else "no error (treated as selected)")
            break
        if i % 10 == 0:
            log("device select failed: %s" % err[:200])
        if "unlocked" not in err:
            run("device list")
        time.sleep(2)
    else:
        log("cannot select device %s; not attaching" % core)
        sys.exit(1)
    t0 = time.time()
    if not run("device process attach -p " + pid):
        sys.exit(1)
    process = dbg.GetSelectedTarget().GetProcess()
    log("attached in %.1f s, state %s" % (time.time() - t0, dbg.StateAsCString(process.GetState())))
    signals = process.GetUnixSignals()
    # Signals QEMU uses itself (the sigaltstack coroutines switch stacks on SIGUSR2; without it QEMU waits in
    # sigsuspend forever) must reach the process as usual. They cannot be set to "do not stop, handled inside LLDB":
    # then the Continue in the loop below runs into LLDB's internal resume, which sends a plain c without the signal,
    # SIGUSR2 is swallowed, QEMU never gets to the brk, and a run of Resume timed out follows (most attach failures in
    # stage 2 were this, clearly visible in the packet log). So let them stop, without notifying, and have the loop
    # continue each one; LLDB passes the signal along when continuing (vCont;C1f).
    for name in PASS:
        n = signals.GetSignalNumberFromName(name)
        signals.SetShouldStop(n, True)
        signals.SetShouldNotify(n, True)  # without notifying, the stop reason is hidden in synchronous mode and it looks like a "stop with no reason"
        signals.SetShouldSuppress(n, False)
    # SIGSTOP, which the system uses to suspend background apps: stop, but do not deliver it to the process on continue
    n = signals.GetSignalNumberFromName("SIGSTOP")
    signals.SetShouldStop(n, True)
    signals.SetShouldNotify(n, True)
    signals.SetShouldSuppress(n, True)

    def stop(*_):
        log("ending: detach")
        process.Detach()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    blessed = 0
    unhandled = 0
    timeouts = 0
    while True:
        err = process.Continue()  # synchronous mode: returns only when the process stops again or exits
        if not err.Success():
            # On Resume timed out the process is often actually running: wait until it really stops or exits rather
            # than continuing again right away
            log("continue failed: %s; waiting for the process state" % err)
            timeouts += 1
            if timeouts >= 3:
                # device-boot.sh kills the app and starts over; flush the packet log first and exit on our own, so a
                # SIGKILL does not lose the log
                run("log disable gdb-remote packets process")
                log("Resume timed out %d times in a row; exiting" % timeouts)
                os._exit(3)
            deadline = time.time() + 30
            while time.time() < deadline and process.GetState() in (lldb.eStateRunning, lldb.eStateStepping):
                time.sleep(0.5)
            log("state now %s" % dbg.StateAsCString(process.GetState()))
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateInvalid):
            log("process ended: %s, exit code %d" % (dbg.StateAsCString(state), process.GetExitStatus()))
            return
        handled = False
        reasons = 0
        for thread in process.threads:
            reason = thread.GetStopReason()
            if reason == lldb.eStopReasonNone:
                continue
            reasons += 1
            frame = thread.GetFrameAtIndex(0)
            err = lldb.SBError()
            word = process.ReadUnsignedFromMemory(frame.GetPC(), 4, err)
            log("thread %d stopped: %s, PC %#x, instruction %s" % (
                thread.GetThreadID(), thread.GetStopDescription(256), frame.GetPC(),
                ("%#010x" % word) if err.Success() else "unreadable (%s)" % err))
            imm = brk_immediate(word) if err.Success() else None
            if reason == lldb.eStopReasonException and imm == 0xF00D:
                command = frame.FindRegister("x16").GetValueAsUnsigned()
                if command == 1:
                    blessed += 1
                    if blessed > 2:
                        # QEMU maps the code region only once; the same request coming again means pc did not skip
                        # the brk, and doing it again would only allocate over and over with the phone frozen
                        log("prepare request number %d: pc did not skip the brk; killing the process" % blessed)
                        process.Kill()
                        sys.exit(4)
                    handled = prepare_region(process, frame)
                elif command == 0:
                    write_regs(thread, {"pc": frame.GetPC() + 4})
                    log("the app asked to detach: detaching, the debugger exits")
                    process.Detach()
                    return
                else:
                    log("unknown command x16=%d; skipping it" % command)
                    write_regs(thread, {"pc": frame.GetPC() + 4})
                    handled = True
            elif reason == lldb.eStopReasonException and lldb_jit._is_jit_brk(process, frame.GetPC()):
                t = time.time()
                if lldb_jit._bless(frame, Stream()):
                    blessed += 1
                    log("code region ready (legacy protocol) in %.1f s (#%d)" % (time.time() - t, blessed))
                    handled = True
            elif reason == lldb.eStopReasonSignal:
                handled = True  # stopped by a signal: continue (LLDB passes the signals in PASS along; SIGSTOP is not delivered)
            else:
                for f in thread.frames[:12]:
                    log("   ", f)
        if reasons == 0:
            # An internal LLDB stop (a dyld load notification or the like) leaked out; continuing right away tends to
            # collide with its internal resume, so wait a moment
            t = process.GetSelectedThread()
            log("stopped, but no thread has a stop reason (selected thread %d: reason %d, %s); continuing after 0.5 s" % (
                t.GetThreadID(), t.GetStopReason(), t.GetStopDescription(200)))
            time.sleep(0.5)
            continue
        if handled:
            unhandled = 0
            continue
        # For example the EXC_BAD_ACCESS on the first jump into generated code when TXM does not accept the code
        # pages: continuing only stops in the same place again, so give up after a few in a row
        unhandled += 1
        if unhandled >= 3:
            log("%d unhandled stops in a row; killing the process" % unhandled)
            process.Kill()
            sys.exit(2)


if __name__ == "__main__":
    main()
