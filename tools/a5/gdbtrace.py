#!/usr/bin/env python3
"""Talk to QEMU's gdb stub (-gdb tcp::PORT) without a gdb: break on a kernel
function, take a frame-pointer backtrace at every hit, and keep the last one per
kernel stack. A thread that blocks for good shows its final call chain.

    gdbtrace.py KERNEL.mach PORT SECONDS ADDR [ADDR...]   # breakpoints
    gdbtrace.py KERNEL.mach PORT SAMPLES --sample          # interrupt and backtrace N times
    gdbtrace.py KERNEL.mach PORT SECONDS --log ADDR [ADDR...]  # every hit in order: r0-r3, lr, short backtrace

Addresses are hex (thread_block_reason, say); Thumb bit is ignored. The iOS ABI
keeps the frame pointer in r7: [r7] is the caller's r7, [r7 + 4] its lr.
Symbols come from `nm` on the kernelcache (exported ones only).
"""
import bisect, os, socket, struct, subprocess, sys, time

STACK_BITS = 14                      # group hits by sp >> 14 (xnu arm kernel stacks are 16 KiB)


class Stub:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.buf = b""
        self.cmd("QStartNoAckMode")
        self.ack = False

    def _send(self, body):
        pkt = b"$" + body.encode() + b"#%02x" % (sum(body.encode()) & 0xff)
        self.s.sendall(pkt)

    def _recv(self):
        while True:
            i = self.buf.find(b"$")
            if i >= 0:
                j = self.buf.find(b"#", i)
                if j >= 0 and len(self.buf) >= j + 3:
                    body = self.buf[i + 1:j]
                    self.buf = self.buf[j + 3:]
                    if getattr(self, "ack", True):
                        self.s.sendall(b"+")
                    return body.decode(errors="replace")
            d = self.s.recv(65536)
            if not d:
                raise EOFError
            self.buf += d

    def cmd(self, body):
        self._send(body)
        return self._recv()

    def regs(self):
        g = bytes.fromhex(self.cmd("g"))
        return list(struct.unpack_from("<16I", g))

    def mem(self, addr, n):
        r = self.cmd("m%x,%x" % (addr, n))
        if r.startswith("E") or not r:
            return None
        return bytes.fromhex(r)

    def u32(self, addr):
        b = self.mem(addr, 4)
        return None if b is None else struct.unpack("<I", b)[0]

    def interrupt(self):
        self.s.sendall(b"\x03")
        return self._recv()

    def cont(self):
        self._send("c")

    def wait_stop(self, timeout=None):
        self.s.settimeout(timeout)
        try:
            return self._recv()
        except socket.timeout:
            return None
        finally:
            self.s.settimeout(None)


class Syms:
    def __init__(self, path):
        out = subprocess.run(["nm", "-n", path], capture_output=True, text=True).stdout
        self.a, self.n = [], []
        for line in out.splitlines():
            p = line.split()
            if len(p) == 3 and p[1] in "tT":
                self.a.append(int(p[0], 16))
                self.n.append(p[2])

    def __call__(self, addr):
        i = bisect.bisect_right(self.a, addr) - 1
        if i < 0 or addr - self.a[i] > 0x4000:
            return "%#x" % addr
        return "%#x %s+%#x" % (addr, self.n[i], addr - self.a[i])


def backtrace(st, r, depth=24):
    pcs = [r[15], r[14]]
    fp = r[7]
    for _ in range(depth):
        if fp < 0x80000000 or fp & 3:
            break
        nxt, lr = st.u32(fp), st.u32(fp + 4)
        if nxt is None or lr is None or lr < 0x80000000:
            break
        pcs.append(lr)
        if nxt <= fp:
            break
        fp = nxt
    return [p & ~1 for p in pcs]


def show(sym, bt):
    return "\n".join("    " + sym(p) for p in bt)


def run_breaks(st, sym, seconds, addrs):
    for a in addrs:
        assert st.cmd("Z0,%x,2" % a) == "OK", "breakpoint %#x refused" % a
    last, hits, order = {}, {}, []
    t_end = time.time() + seconds
    st.cont()
    while time.time() < t_end:
        stop = st.wait_stop(max(0.1, t_end - time.time()))
        if stop is None:
            break
        r = st.regs()
        pc = r[15] & ~1
        key = (r[13] >> STACK_BITS, pc)
        bt = backtrace(st, r)
        hits[key] = hits.get(key, 0) + 1
        last[key] = (time.time(), bt)
        if key not in order:
            order.append(key)
        # step over the breakpoint, then put it back
        st.cmd("z0,%x,2" % pc)
        st.cmd("s")
        st.cmd("Z0,%x,2" % pc)
        st.cont()
    st.interrupt()
    t0 = time.time()
    for key in order:
        ts, bt = last[key]
        print("stack %#x  bp %s  hits %d  last %.1fs ago" %
              (key[0] << STACK_BITS, sym(key[1]), hits[key], t0 - ts))
        print(show(sym, bt))
    r = st.regs()
    print("now: pc %s sp %#x" % (sym(r[15]), r[13]))
    print(show(sym, backtrace(st, r)))


def run_log(st, sym, seconds, addrs, limit=400):
    for a in addrs:
        assert st.cmd("Z0,%x,2" % a) == "OK", "breakpoint %#x refused" % a
    t0 = time.time()
    n = 0
    st.cont()
    while time.time() < t0 + seconds and n < limit:
        stop = st.wait_stop(max(0.1, t0 + seconds - time.time()))
        if stop is None:
            break
        r = st.regs()
        pc = r[15] & ~1
        n += 1
        bt = backtrace(st, r, 6)[1:]
        print("%7.3fs %s  r0 %#x r1 %#x r2 %#x r3 %#x  <- %s" %
              (time.time() - t0, sym(pc), r[0], r[1], r[2], r[3],
               " <- ".join("%#x" % p for p in bt)))
        sys.stdout.flush()
        st.cmd("z0,%x,2" % pc)
        st.cmd("s")
        st.cmd("Z0,%x,2" % pc)
        st.cont()
    st.interrupt()


def run_samples(st, sym, n):
    seen = {}
    st.cont()
    for _ in range(n):
        time.sleep(0.2)
        st.interrupt()
        r = st.regs()
        bt = tuple(backtrace(st, r, 12))
        seen[bt] = seen.get(bt, 0) + 1
        st.cont()
    if not os.environ.get("GDBTRACE_CONTINUE"):    # GDBTRACE_CONTINUE=1: leave the guest running
        st.interrupt()
    for bt, c in sorted(seen.items(), key=lambda kv: -kv[1]):
        print("%d samples" % c)
        print(show(sym, bt))


def main():
    path, port = sys.argv[1], int(sys.argv[2])
    sym = Syms(path)
    st = Stub(port)
    if "--sample" in sys.argv:
        run_samples(st, sym, int(sys.argv[3]))
    elif sys.argv[4] == "--log":
        run_log(st, sym, float(sys.argv[3]), [int(a, 16) & ~1 for a in sys.argv[5:]])
    else:
        run_breaks(st, sym, float(sys.argv[3]), [int(a, 16) & ~1 for a in sys.argv[4:]])
    st.cmd("D")


if __name__ == "__main__":
    main()
