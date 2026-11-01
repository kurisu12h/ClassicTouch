"""E2 的调试器：挂到手机上正在「等调试器」的 App（-waitdebugger YES），应答 QEMU 准备 JIT 代码区的请求。

两种协议（tcg/region.c，patches/ios-txm-jit-protocol.patch）：
- 通用协议（默认）：brk #0xf00d，x16 是命令。x16=1 准备代码区：x0 为 0 时由调试器分配，这里用
  SBProcess.AllocateMemory（debugserver 的 _M 包，分配出来就是可执行的），再让调试器写过每一页
  （TXM 只认调试器写过的页；不写的话实测 iOS 27.2 上生成的代码执行不了），地址写回 x0。
  x16=0 脱离：调试器 detach 后退出，App 之后不带调试器跑。
  写的方式由 JIT_TOUCH 选：bulk（默认）整块写零，受带宽限制，Wi-Fi 下约 2 MB/s；page 照 StikDebug 的
  prepare_memory_region 每个 16 KiB 页写 1 字节，受往返延迟限制，Wi-Fi 下每页约 29 毫秒；none 只分配。
- 旧协议：brk #0x69，照上游 lldb_jit.py（同目录，原样找回）把 x0/x1 指的整段读出再写回。

用 LLDB 的 SB API 写成独立脚本、同步模式、自己处理每一次停止，而不是在 lldb 命令行里装停止钩子：
Xcode 27.2 的 lldb 命令行驱动在这种用法下会在事件线程里崩（ProcessGDBRemote::WillPublicStop），
并行加载模块时也会崩（PlatformDarwinDevice::GetDeviceSupportDirectoryForOSVersion）。

用法：xcrun python3 scripts/ios/lldb_jit_runner.py <CoreDevice 标识> <PID>
（Python 要用 Xcode 自带的那个，LLDB 模块路径由 `xcrun lldb -P` 给出，脚本自己加。）
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

# QEMU 自己用的信号（vCPU 踢线程、sigaltstack 协程等），要照常递给进程
PASS = ["SIGUSR1", "SIGUSR2", "SIGALRM", "SIGPIPE", "SIGURG", "SIGVTALRM", "SIGPROF"]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Stream:
    def Print(self, text):
        log(text.rstrip())


PAGE = 16384


def brk_immediate(word):
    """AArch64 BRK #imm16 是 1101 0100 001 imm16 00000；不是 brk 返回 None。"""
    if (word & 0xFFE0001F) != 0xD4200000:
        return None
    return (word >> 5) & 0xFFFF


INTERP = None  # main() 里设好，给 write_regs 的退路用


def write_regs(thread, values):
    """改停下的线程的寄存器（x0、pc），写完读回核对。SBValue 的写法有时不生效（第二阶段遇到过：pc 没跳过
    brk，同一个 brk 反复触发），没生效就选中这条线程，用 register write 命令再写一遍。"""
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
    log("寄存器 %s 第一次没写进去，用 register write 重写：%s" % (bad, "还是不对 %s" % still if still else "好了"))
    return not still


def prepare_region(process, frame):
    """brk #0xf00d、x16=1：分配（x0 为 0 时）并逐页写 1 字节，地址写回 x0，跳过 brk。"""
    addr = frame.FindRegister("x0").GetValueAsUnsigned()
    size = frame.FindRegister("x1").GetValueAsUnsigned()
    err = lldb.SBError()
    t0 = time.time()
    if addr == 0:
        addr = process.AllocateMemory(size, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, err)
        if not err.Success() or addr in (0, lldb.LLDB_INVALID_ADDRESS):
            log("分配 %d MiB 可执行内存失败：%s" % (size >> 20, err))
            addr = 0
    t1 = time.time()
    pages = 0
    if addr and os.environ.get("JIT_TOUCH", "bulk") == "page":
        total = (size + PAGE - 1) // PAGE
        for off in range(0, size, PAGE):
            process.WriteMemory(addr + off, b"\x69", err)
            if not err.Success():
                log("写 %#x 失败：%s" % (addr + off, err))
                break
            pages += 1
            if pages % 512 == 0:
                dt = time.time() - t1
                log("逐页写 %d/%d 页，%.1f 秒，每页 %.1f 毫秒" % (pages, total, dt, dt / pages * 1000))
    elif addr and os.environ.get("JIT_TOUCH", "bulk") == "bulk":
        # 整块写零：不受往返延迟限制，受带宽限制（Wi-Fi 下逐页写每页约 29 毫秒）
        chunk = 4 << 20
        zeros = bytes(chunk)
        for off in range(0, size, chunk):
            n = min(chunk, size - off)
            process.WriteMemory(addr + off, zeros[:n], err)
            if not err.Success():
                log("写 %#x 失败：%s" % (addr + off, err))
                break
            pages += n // PAGE
            if (off + n) % (16 << 20) == 0:
                dt = time.time() - t1
                log("整块写 %d/%d MiB，%.1f 秒，%.2f MB/s" % ((off + n) >> 20, size >> 20, dt, (off + n) / dt / 1e6))
    t2 = time.time()
    write_regs(frame.GetThread(), {"x0": addr, "pc": frame.GetPC() + 4})
    log("代码区：%d MiB 在 %#x，分配 %.2f 秒，逐页写 %d 页 %.2f 秒" % (size >> 20, addr, t1 - t0, pages, t2 - t1))
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
        log(cmd, "->", "ok" if r.Succeeded() else "失败", ((r.GetOutput() or "") + (r.GetError() or "")).strip()[:300])
        return r.Succeeded()

    # 本机没有手机当前系统版本的符号缓存时，读每个系统模块的符号表要隔着网络，挂载会慢到超时；只读段信息就够用
    run("settings set target.memory-module-load-level minimal")
    run("settings set target.parallel-module-load false")
    # 隔着 Wi-Fi，默认的 gdb-remote 包超时不够，继续时会报 Resume timed out 然后一直卡住
    run("settings set plugin.process.gdb-remote.packet-timeout 60")
    if os.environ.get("LLDB_PACKET_LOG"):  # 排查用：gdb-remote 包和进程状态的详细日志
        run("log enable -f %s gdb-remote packets process" % os.environ["LLDB_PACKET_LOG"])
    run("device select " + core)
    t0 = time.time()
    if not run("device process attach -p " + pid):
        sys.exit(1)
    process = dbg.GetSelectedTarget().GetProcess()
    log("挂上了，%.1f 秒，状态 %s" % (time.time() - t0, dbg.StateAsCString(process.GetState())))
    signals = process.GetUnixSignals()
    # QEMU 自己用的信号（sigaltstack 协程靠 SIGUSR2 切栈，等不到就永远停在 sigsuspend 里）要照常递给进程。
    # 不能设成「不停下、LLDB 内部处理」：那样下面这个循环的 Continue 会插进 LLDB 的内部恢复，恢复时发的是不带
    # 信号的 c，SIGUSR2 被吞掉，QEMU 走不到 brk，接着就是一串 Resume timed out（第二阶段大半挂载这样失败，
    # 包日志里看得很清楚）。所以让它们停下、不提示，由循环逐个继续，LLDB 继续时会把信号带上（vCont;C1f）。
    for name in PASS:
        n = signals.GetSignalNumberFromName(name)
        signals.SetShouldStop(n, True)
        signals.SetShouldNotify(n, True)  # 不提示的话，同步模式下停止原因会被藏起来，看上去像「没原因的停止」
        signals.SetShouldSuppress(n, False)
    # 系统暂停后台 App 用的 SIGSTOP：停下，但继续时不递给进程
    n = signals.GetSignalNumberFromName("SIGSTOP")
    signals.SetShouldStop(n, True)
    signals.SetShouldNotify(n, True)
    signals.SetShouldSuppress(n, True)

    def stop(*_):
        log("结束：detach")
        process.Detach()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    blessed = 0
    unhandled = 0
    timeouts = 0
    while True:
        err = process.Continue()  # 同步模式：进程再停下或退出才返回
        if not err.Success():
            # Resume timed out 时进程常常其实已经在跑：先等它真的停下或退出，别马上再发继续
            log("继续失败：%s，等进程状态" % err)
            timeouts += 1
            if timeouts >= 3:
                # device-boot.sh 会结束 App 重来；先让包日志落盘再自己退出，免得被 SIGKILL 丢掉日志
                run("log disable gdb-remote packets process")
                log("连续 %d 次 Resume timed out，退出" % timeouts)
                os._exit(3)
            deadline = time.time() + 30
            while time.time() < deadline and process.GetState() in (lldb.eStateRunning, lldb.eStateStepping):
                time.sleep(0.5)
            log("现在状态 %s" % dbg.StateAsCString(process.GetState()))
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateInvalid):
            log("进程结束：%s，退出码 %d" % (dbg.StateAsCString(state), process.GetExitStatus()))
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
            log("线程 %d 停下：%s，PC %#x，指令 %s" % (
                thread.GetThreadID(), thread.GetStopDescription(256), frame.GetPC(),
                ("%#010x" % word) if err.Success() else "读不了（%s）" % err))
            imm = brk_immediate(word) if err.Success() else None
            if reason == lldb.eStopReasonException and imm == 0xF00D:
                command = frame.FindRegister("x16").GetValueAsUnsigned()
                if command == 1:
                    blessed += 1
                    if blessed > 2:
                        # QEMU 只映射一次代码区；同一个请求反复来，说明 pc 没跳过 brk，再做只会反复分配、手机一直冻着
                        log("准备请求第 %d 次出现，pc 没跳过 brk，结束进程" % blessed)
                        process.Kill()
                        sys.exit(4)
                    handled = prepare_region(process, frame)
                elif command == 0:
                    write_regs(thread, {"pc": frame.GetPC() + 4})
                    log("App 请求脱离：detach，调试器退出")
                    process.Detach()
                    return
                else:
                    log("不认识的命令 x16=%d，跳过" % command)
                    write_regs(thread, {"pc": frame.GetPC() + 4})
                    handled = True
            elif reason == lldb.eStopReasonException and lldb_jit._is_jit_brk(process, frame.GetPC()):
                t = time.time()
                if lldb_jit._bless(frame, Stream()):
                    blessed += 1
                    log("代码区准备好（旧协议），用了 %.1f 秒（第 %d 次）" % (time.time() - t, blessed))
                    handled = True
            elif reason == lldb.eStopReasonSignal:
                handled = True  # 信号停下：继续（PASS 里的信号 LLDB 会带上，SIGSTOP 不递）
            else:
                for f in thread.frames[:12]:
                    log("   ", f)
        if reasons == 0:
            # LLDB 内部的停止（dyld 加载通知之类）露到了外面；马上再发继续容易和它内部的恢复撞上，等一下
            t = process.GetSelectedThread()
            log("停下了但没有线程带停止原因（选中线程 %d：原因 %d，%s），等 0.5 秒再继续" % (
                t.GetThreadID(), t.GetStopReason(), t.GetStopDescription(200)))
            time.sleep(0.5)
            continue
        if handled:
            unhandled = 0
            continue
        # 比如 TXM 不认代码页时第一次跳进生成代码的 EXC_BAD_ACCESS：继续只会原地再停，连着几次就结束
        unhandled += 1
        if unhandled >= 3:
            log("连续 %d 次无法处理的停止，结束进程" % unhandled)
            process.Kill()
            sys.exit(2)


if __name__ == "__main__":
    main()
