# A5（iPod touch 5，n78）开机脚本

iOS 8 到 10 轨道第 1 步用的两个脚本。报告见 `docs/reports/a5-step1.md`。

## 准备（在项目根目录）

```bash
# 1. 上游和 A5 工作树（qemu-ios 打 patches/a5-n78-skeleton.patch）
git clone https://github.com/samhenrigold/qemu-ios upstream/qemu-ios && git -C upstream/qemu-ios checkout b225694505
git -C upstream/qemu-ios worktree add -b a5-n78 ../../work/a5/qemu-ios b225694505
git -C work/a5/qemu-ios apply ../../../patches/a5-n78-skeleton.patch

# 2. 两个脚本依赖的 imgtools（上游 22f4f72746 删掉之前的版本，GPL-2）
git -C upstream/qemu-ios archive 22f4f72746^ imgtools | tar -x -C work/a5/

# 3. 编 QEMU（configure 参数同 M0 报告第 3 节）
mkdir -p work/a5/build && cd work/a5/build && ../qemu-ios/configure --target-list=arm-softmmu \
  --disable-sdl --disable-sdl-image --disable-capstone --disable-pie --disable-fuse \
  --extra-cflags="-I/opt/homebrew/opt/openssl@3/include -mmacosx-version-min=12.0" \
  --extra-ldflags="-L/opt/homebrew/opt/openssl@3/lib -lcrypto -mmacosx-version-min=12.0" \
  --python=/opt/homebrew/opt/python@3.12/libexec/bin/python3 && ninja qemu-system-arm && cd ../../..
```

固件（苹果服务器，要用户批准下载）：`iPod5,1_9.3.5_13G36_Restore.ipsw`、`iPod5,1_7.1.2_11D257_Restore.ipsw`，放 `work/firmware/`，sha1 取自 ipsw.me。

## 解固件、做开机包、开机

```bash
curl -fsS https://api.ipsw.me/v4/keys/ipsw/iPod5,1/13G36 -o work/a5/keys/13G36.json
python3 -I tools/a5/n78_unpack.py work/firmware/iPod5,1_9.3.5_13G36_Restore.ipsw work/a5/keys/13G36.json work/a5/dec/13G36
python3 -I tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36.bin
work/a5/build/qemu-system-arm -M iPod-Touch-5G,kboot=work/a5/kboot/n78-13G36.bin -display none \
  -serial file:work/a5/runs/13G36-serial.log -monitor none -d unimp,guest_errors -D work/a5/runs/13G36-q.log
```

`n78_unpack.py` 只解内核、设备树和 iBoot（根文件系统和内存盘以后再说）。`n78_kboot.py` 复用 `ipad1_kboot.py`，只换 A5 不同的部分，改了什么见它开头的说明和报告第 2 节。

QEMU 会拦住 `SIGALRM`，限时运行要用 `kill -9`（报告里用的是一行 perl：fork、等 N 秒、`kill 9`）。

## 内存盘当根（报告 3.8、3.9 节）

```bash
N78_RAMDISK=work/a5/dec/13G36/RestoreRamDisk.dmg python3 -I tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36-rd.bin
work/a5/build/qemu-system-arm -M iPod-Touch-5G,kboot=work/a5/kboot/n78-13G36-rd.bin -display none \
  -serial file:work/a5/runs/13G36-rd-serial.log -monitor none -d unimp,guest_errors,int -D work/a5/runs/13G36-rd-q.log
```

`-d int` 日志里 `from EL0` 的行数就是用户态异常次数，`Taking exception 6` 是定时器 FIQ。

## 调试工具

`kexts.py`、`mkelf.py`、`xref.py` 要和 `imgtools/` 在同一目录，先复制到 `work/a5/` 再用。

```bash
# 某地址在哪个 kext（不带地址则列出全部 kext）
python3 -I work/a5/kexts.py work/a5/dec/11D257/kernelcache.mach 804236d8
# 包成 ELF 后按地址范围反汇编（kext 也行；ARM 模式代码把 thumbv7 换成 armv7）
python3 -I work/a5/mkelf.py work/a5/dec/11D257/kernelcache.mach work/a5/dis/11D257.elf
/opt/homebrew/opt/llvm/bin/llvm-objdump -d --triple=thumbv7 --start-address=0x804235ac --stop-address=0x804237a8 work/a5/dis/11D257.elf
```

`gdbtrace.py` 接 QEMU 的 gdb 调试口（启动时加 `-gdb tcp::1234 -S`，它连上后才开跑）：

```bash
# 在 thread_block_reason 下断点 200 秒，列出每个内核栈最后一次睡下时的调用链（7.1.2）
python3 -I tools/a5/gdbtrace.py work/a5/dec/11D257/kernelcache.mach 1234 200 800bf190
# 按顺序记录每次命中（这里是 9.3.5 的 cpu_signal、信号处理、rtclock_intr、设倒计时）
python3 -I tools/a5/gdbtrace.py work/a5/dec/13G36/kernelcache.mach 1234 50 --log 800bd7b4 800bd874 800cb74c 800c8c20
# 打断采样 20 次当前调用链
python3 -I tools/a5/gdbtrace.py work/a5/dec/11D257/kernelcache.mach 1234 20 --sample
```

## 截图和显示寄存器（报告 3.10 节）

开机包要带苹果标志，先用新版 `n78_unpack.py` 解出 `AppleLogo.bin`，再重做开机包。开机时加 `-qmp unix:SOCK,server,nowait`，然后：

```bash
# 第 2、6 秒截图（存 shot-2.png、shot-6.png），并把管线 0 和 H4P 页表记进 pipe.txt
python3 -I tools/a5/qmon.py work/a5/runs/x/qmp.sock work/a5/runs/x 2 6
# 在 kext 的反汇编里找报错字符串的引用（pcrefs.py 也要和 imgtools/ 在同一目录）
python3 -I work/a5/pcrefs.py work/a5/dec/11D257/kernelcache.mach work/a5/dis/11D257-h4p.txt "input width(%d) or height(%d)"
```

## USB 和 USB 盘挂根（报告 3.11 节）

```bash
# rootfs 解密（密钥在 ipsw.me 的密钥表里，RootFS 那项），再做成 GPT 盘：第 1 分区是系统卷
KEY=$(python3 -I -c "import json;print(next(k['key'] for k in json.load(open('work/a5/keys/11D257.json'))['keys'] if k['image']=='RootFS'))")
unzip -o -q work/firmware/iPod5,1_7.1.2_11D257_Restore.ipsw 058-4385-009.dmg -d work/a5/rootfs
python3 -I work/a5/imgtools/vfdecrypt.py work/a5/rootfs/058-4385-009.dmg work/a5/rootfs/11D257-rootfs.dmg $KEY
python3 -I tools/a5/n78_usbroot.py work/a5/rootfs/11D257-rootfs.dmg work/a5/disks/11D257-usbroot.img
# 不带内存盘的开机包 + USB 盘（snapshot=on 不写镜像）
python3 -I tools/a5/n78_kboot.py work/a5/dec/11D257 work/a5/kboot/n78-11D257.bin
work/a5/build/qemu-system-arm -M iPod-Touch-5G,kboot=work/a5/kboot/n78-11D257.bin -display none \
  -serial file:work/a5/runs/usbroot-serial.log -monitor none \
  -drive if=none,id=root,file=work/a5/disks/11D257-usbroot.img,format=raw,snapshot=on -device usb-storage,bus=ehci.0,drive=root
```

看 USB 枚举：加 `-trace usb_set_addr -trace scsi_req_parsed -D trace.log`。
