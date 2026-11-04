# A5（iPod touch 5，n78）和 A6（iPhone 5，n41）开机脚本

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

## 完整系统盘（报告 3.12 节）

```bash
# guest 工具（M0 报告第 4 节）
python3 tools/m0/make-substitute-sdk.py work/sdk-substitute/iPhoneOS-substitute.sdk
ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk IPAD_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk \
  LDID=$(command -v ldid) upstream/qemu-ios/contrib/export-guest-artifacts.sh work/guest-artifacts
# FirmwareKit 副本打补丁并编译（依赖取自 SwiftPM 本机缓存）
cp -R upstream/LightTouchMac work/a5/LightTouchMac   # 或 git worktree
git -C work/a5/LightTouchMac apply ../../../patches/a5-firmwarekit-n78-volumes.patch
swift build -c release --package-path work/a5/LightTouchMac/Packages/FirmwareKit --scratch-path work/a5/fk/build --product firmwarekit
# 条目和 helper 替身，只做卷，打成两分区 USB 盘
python3 -I tools/a5/n78_fkprep.py 11D257 work/a5/fk
work/a5/fk/build/release/firmwarekit create --entry work/a5/fk/n78ap-11D257.json \
  --ipsw work/firmware/iPod5,1_7.1.2_11D257_Restore.ipsw --out work/a5/fk/out/n78ap-11D257 --cache work/a5/fk/cache \
  --guest-tools work/guest-artifacts/ipad-guest-tools --helper work/a5/fk/helper/LightTouchDevice \
  --stop-after volumes --skip-setup --language en-US
python3 -I tools/a5/n78_usbroot.py work/a5/fk/out/n78ap-11D257/volumes/system.img work/a5/disks/11D257-full.img \
  work/a5/fk/out/n78ap-11D257/volumes/data.img
```

## NAND、可擦除存储、钥匙包（报告 3.13 节）

IOP 高层模型（`hw/arm/s5l8940_iop.c`）在补丁里。开机包要放出 IOP 和闪存控制器（`N78_SHOW`），`n78_kboot.py` 的 `fill_nand` 会按模型的 PPN 几何填设备树。NAND 页存储放在一个目录里（`ce0.pages`、`ce0.boot`），用 `-global driver=s5l8940.iop,property=nand,value=目录` 指定；`IOP_TRACE=1` 把 IOP 的命令和统计写进 `-D` 日志。

```bash
# 1. 帮手程序（armv7，替代 SDK，ldid 签名）
mkdir -p work/a5/guest && bash -c 'export GUEST_ARCH=armv7 ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk
  . upstream/qemu-ios/contrib/armv6-toolchain/armv6.sh
  cc6 tools/a5/it_nandfmt.c work/a5/guest/it_nandfmt.o -isystem "$(xcrun clang -print-resource-dir)/include"
  link6 -execute work/a5/guest/it_nandfmt work/a5/guest/it_nandfmt.o && ldid -S work/a5/guest/it_nandfmt'
# 2. 恢复内存盘副本：扩 1 MiB，删掉原 restored_external 再放入帮手，离线把属主改成 root
mkdir -p work/a5/nandfmt/mnt && cd work/a5/nandfmt && cp ../dec/11D257/RestoreRamDisk.dmg rd-11D257.dmg
hdiutil resize -sectors $((9940992/512)) -imagekey diskimage-class=CRawDiskImage rd-11D257.dmg
hdiutil attach -imagekey diskimage-class=CRawDiskImage -mountpoint mnt -nobrowse rd-11D257.dmg
rm mnt/usr/local/bin/restored_external && cp ../guest/it_nandfmt mnt/usr/local/bin/restored_external
chmod 755 mnt/usr/local/bin/restored_external && hdiutil detach mnt && cd ..
python3 -I -c "import sys,types; sys.path.insert(0,'imgtools'); sys.modules['mkpkg']=types.ModuleType('mkpkg')
import build_nand as bn; bn.set_owner('nandfmt/rd-11D257.dmg', ['usr/local/bin/restored_external'], 0, 0)"
cd ../..
# 3. 两个开机包：格式化用（内存盘当根、FTL 自格式化）和正常开机用
N78_SHOW=arm-io/iop,arm-io/flash-controller0 N78_RAMDISK=work/a5/nandfmt/rd-11D257.dmg \
  python3 -I tools/a5/n78_kboot.py work/a5/dec/11D257 work/a5/kboot/n78-11D257-nandfmt.bin "nand-enable-reformat=1"
N78_SHOW=arm-io/iop,arm-io/flash-controller0 python3 -I tools/a5/n78_kboot.py work/a5/dec/11D257 work/a5/kboot/n78-11D257-fmi.bin
# 4. 格式化开机（约 3 分钟，帮手打出 "system keybag created; halting" 后内核 panic 属正常）：写盘克隆、写 NAND 目录
cp -c work/a5/disks/11D257-full-noprot.img work/a5/nandfmt/disk.img
IOP_TRACE=1 DISK=work/a5/nandfmt/disk.img SNAP=off tools/a5/n78_run.sh work/a5/runs/fmt work/a5/kboot/n78-11D257-nandfmt.bin 300 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand -D work/a5/runs/fmt/q.log
```

5. 盘克隆上手工改两处（`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount`，`mount -t hfs -o noowners`）：第 1 分区 `/etc/fstab` 改成 `/dev/disk1s1`、`/dev/disk1s2`（NAND 的 FTL 盘占了 disk0）；第 2 分区放空文件 `.it_sealed`（否则 FirmwareKit 的 `it_seal` 首次开机 40 秒后停机）。
6. 正常开机：`DISK=改好的盘 tools/a5/n78_run.sh DIR work/a5/kboot/n78-11D257-fmi.bin 200 -global driver=s5l8940.iop,property=nand,value=格式化好的 NAND 目录的克隆`。

反编译辅助（都要和 `imgtools/` 放在同一目录，复现时复制到 `work/a5/`）：`kextelf.py` 把指定 kext 连同内核导出符号包成 ELF 给 Ghidra（REA），`rawelf.py` 把裸镜像（IOP 固件、iBoot）包成 ELF，`pcfix.py`、`fwfix.py` 把伪代码里的字符串引用解开，`kstr.py` 列地址范围里的字符串，`kpers.py` 列 kext 的匹配条件。

## GL 桥和截图（报告 3.14 节）

补丁里 n78 已注册 `QEMU_CALL`，系统卷里 FirmwareKit 装的 GL 前端会直接用上，不用额外参数（`-M iPod-Touch-5G,gl-renderer=angle` 可换渲染器）。看崩溃日志要可写开机：`cp -c` 一份盘克隆，`SNAP=off` 开机，结束后挂克隆的第 2 分区（`mount -t hfs -o noowners`，卷没干净卸载时只读挂不上），日志在 `mobile/Library/Logs/CrashReporter/`。截图：

```bash
cp -c work/a5/nandfmt/disk-n1.img work/a5/nandfmt/disk-c2.img; mkdir -p work/a5/nandfmt/nand-c2 && cp -c work/a5/nandfmt/nand-formatted/* work/a5/nandfmt/nand-c2/
(DISK=work/a5/nandfmt/disk-c2.img SNAP=off tools/a5/n78_run.sh work/a5/runs/gl work/a5/kboot/n78-11D257-fmi.bin 200 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-c2 &)
sleep 3; python3 -I tools/a5/qmon.py work/a5/runs/gl/qmp.sock work/a5/runs/gl 60 120 180
```

## 到锁屏（报告 3.15 节）

格式化开机做完后，对格式化后的盘克隆跑一次 `tools/a5/n78_diskfix.sh`（按系统卷的版本号分支，9.3.5 见最后一节）。对 7.1.2 它会改 fstab 为 disk1、在数据卷放 `.it_sealed`、给 lockdownd 打本地激活补丁（`n78_activate.py`，按哈希认 11D257 lockdownd 和 13G36 mobileactivationd）、把两个罗盘 HID 插件移到 `HIDPlugins.disabled`、补上设置助理的 Siri 等四个完成标记，并在 launchd 的 `overrides.plist` 里禁掉 DeviceOMatic（它把挂根用的 USB 盘当外接设备，在锁屏上挂一条「Cannot Use Device」，手机上因此要多试几次才能解锁，`docs/reports/ios-device-14pro.md` 第 7 节）。之后照「GL 桥和截图」一节开机，约 100 秒到锁屏，再过 20 秒左右熄屏，所以截图要在 95 到 120 秒之间多截几张：

```bash
cp -c work/a5/nandfmt/disk-formatted.img work/a5/nandfmt/disk-ls.img && tools/a5/n78_diskfix.sh work/a5/nandfmt/disk-ls.img
mkdir -p work/a5/nandfmt/nand-ls && cp -c work/a5/nandfmt/nand-formatted/* work/a5/nandfmt/nand-ls/
(DISK=work/a5/nandfmt/disk-ls.img SNAP=off tools/a5/n78_run.sh work/a5/runs/ls work/a5/kboot/n78-11D257-fmi.bin 150 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-ls &)
sleep 3; python3 -I tools/a5/qmon.py work/a5/runs/ls/qmp.sock work/a5/runs/ls 95 100 105 110 115 120
```

## 触摸、按键、解锁进主屏（报告 3.16 节）

补丁里 n78 已有 spi1 触摸和 GPIO 按键。`tools/a5/qinput.py SOCK OUTDIR 动作...` 经 QMP 注入输入，动作有：`T:shot`、`T:key:h`（Home；l 是电源键）、`T:tap:X,Y[,MS]`、`T:swipe:X0,Y0,X1,Y1[,MS]`，坐标是 640×1136 屏幕像素。用 3.15 节修过的盘（这里用开过一次的 `disk-fix-a.img` 的克隆）：

```bash
cp -c work/a5/nandfmt/disk-fix-a.img work/a5/nandfmt/disk-ui.img
mkdir -p work/a5/nandfmt/nand-ui work/a5/runs/ui && cp -c work/a5/nandfmt/nand-formatted/* work/a5/nandfmt/nand-ui/
(DISK=work/a5/nandfmt/disk-ui.img SNAP=off tools/a5/n78_run.sh work/a5/runs/ui work/a5/kboot/n78-11D257-fmi.bin 220 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-ui &)
sleep 3; python3 -I tools/a5/qinput.py work/a5/runs/ui/qmp.sock work/a5/runs/ui \
  148:key:h 151:shot 152:swipe:140,975,620,975,500 157:shot 160:tap:92,920,300 190:shot 200:key:h 205:shot
```

纵向坐标没校准，实际落点比瞄准点偏上约 100 像素，所以点「设置」用的是 y=920。

## 9.3.5（13G36）：锁屏、主屏、「设置」（报告 3.17 节）

`n78_kboot.py` 现在默认隐藏两个 M2 缩放器（`arm-io/scaler0`、`scaler1`），隐藏时 arm-io 下的节点连 `device_type` 一起改成 `-`（IONameMatch 也认它）。9.3.5 比 7.1.2 多出来的工具：

| 文件 | 作用 |
|---|---|
| `n78_volumes.py ROOTFS.dmg OUTDIR [加大MiB] [数据卷MiB]` | 系统卷（rootfs 切出并加大）和数据卷（稀疏日志式 HFSX、`/private/var` 骨架、属主、内容保护），代替 FirmwareKit |
| `it_nandfmt.ent` | 格式化帮手的授权（9.x 平台沙盒不让无授权进程读裸盘）：`ldid -Stools/a5/it_nandfmt.ent` |
| `n78_devcache.py CACHE` | 共享缓存改开发版：头 +0x68 置 0，重算签名第 0 槽，dyld-390 才让磁盘上的库覆盖缓存 |
| `n78_setupdone.py VAR` | 9.x 设置助理完成状态，起决定作用的是 `ForceNoBuddy` |
| `cacheinfo.py CACHE exports/binds/methods/selrefs` | 不解开缓存，查导出、谁绑定某符号、ObjC 类的方法、谁发某选择子 |
| `cache2elf.py CACHE IMAGE OUT.elf` | 把缓存里一个镜像切成 ELF 给 Ghidra（REA） |

```bash
# 1. 卷和两分区盘（rootfs 是 3.11 节解密的那份）
cd work/a5 && python3 -B ../../tools/a5/n78_volumes.py rootfs/13G36-rootfs.dmg vol-13G36 && cd ../..
python3 -I -B tools/a5/n78_usbroot.py work/a5/vol-13G36/system.img work/a5/disks/13G36-full.img work/a5/vol-13G36/data.img
# 2. 帮手带授权签名，换进 9.3.5 内存盘副本（副本做法同「NAND」一节，把 11D257 换成 13G36），做格式化开机包
bash -c 'export GUEST_ARCH=armv7 ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk
  . upstream/qemu-ios/contrib/armv6-toolchain/armv6.sh
  cc6 tools/a5/it_nandfmt.c work/a5/guest/it_nandfmt.o -isystem "$(xcrun clang -print-resource-dir)/include"
  link6 -execute work/a5/guest/it_nandfmt work/a5/guest/it_nandfmt.o && ldid -Stools/a5/it_nandfmt.ent work/a5/guest/it_nandfmt'
N78_SHOW=arm-io/iop,arm-io/flash-controller0 N78_RAMDISK=work/a5/nandfmt/rd-13G36.dmg \
  python3 -I -B tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36-nandfmt.bin "nand-enable-reformat=1"
# 3. 格式化开机（帮手打出 "system keybag created; halting" 后约 15 秒按 PID 结束 QEMU）
cp -c work/a5/disks/13G36-full.img work/a5/nandfmt/disk-935-formatted.img && mkdir -p work/a5/nandfmt/nand-935-formatted
IOP_TRACE=1 DISK=work/a5/nandfmt/disk-935-formatted.img SNAP=off tools/a5/n78_run.sh work/a5/runs/fmt935 \
  work/a5/kboot/n78-13G36-nandfmt.bin 420 -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-935-formatted \
  -D work/a5/runs/fmt935/q.log
# 4. GL 前端（打过补丁的 work/a5/qemu-ios：9.x 的 4 个导出、EAGLContext debugLabel 等）和盘上修改
ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk bash work/a5/qemu-ios/contrib/gles-public/build.sh $PWD/work/a5/guest/OpenGLES
cp -c work/a5/nandfmt/disk-935-formatted.img work/a5/nandfmt/disk-935.img && tools/a5/n78_diskfix.sh work/a5/nandfmt/disk-935.img
# 5. 正常开机。第一次多约 100 秒数据迁移（苹果标志加进度条）；之后从这块盘再开，约 80 秒锁屏，随即熄屏
N78_SHOW=arm-io/iop,arm-io/flash-controller0 python3 -I -B tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36-fmi.bin
mkdir -p work/a5/nandfmt/nand-935 work/a5/runs/ui935 && cp -c work/a5/nandfmt/nand-935-formatted/* work/a5/nandfmt/nand-935/
(DISK=work/a5/nandfmt/disk-935.img SNAP=off tools/a5/n78_run.sh work/a5/runs/ui935 work/a5/kboot/n78-13G36-fmi.bin 330 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-935 &)
# 锁屏出来后（第二次开机约 100 秒）：Home 唤醒、滑动解锁、关掉「Trust This Computer?」、点「设置」
sleep 3; python3 -I -B tools/a5/qinput.py work/a5/runs/ui935/qmp.sock work/a5/runs/ui935 \
  105:key:h 108:shot 110:swipe:140,975,620,975,500 115:shot 120:tap:455,785 125:tap:244,930 140:shot
```

时间要按实际开机进度调：锁屏出现后约 20 秒熄屏，按 Home 唤醒即可。主屏的「Trust This Computer?」是 lockdownd 的配对提示，点「Don't Trust」。

## 接进 iPhone App（报告 `docs/reports/a5-app.md`）

n78 在 App 里的开机方式是 `n78`（`app/ClassicTouch/DeviceProfile.swift`）。设备目录：`device.lock.json`（`board n78ap`、`boot_strategy n78`）、`kboot.bin`（`n78_kboot.py` 的正常开机包）、`disk.img`（两分区盘）、`nand/`（`ce0.pages`、`ce0.boot`）。最好用开过一次的盘和 NAND（9.3.5 省掉首次数据迁移）。

```bash
# 设备目录和包（9.3.5 为例；7.1.2 同样，kboot 换 11D257）
D=work/ios/devices/n78ap-13G36 && mkdir -p $D/nand && cp work/a5/kboot/n78-13G36-fmi.bin $D/kboot.bin
cp -c 开过一次的盘.img $D/disk.img && cp -c 对应的NAND目录/* $D/nand/
echo '{"board":"n78ap","boot_strategy":"n78","product_version":"9.3.5","build":"13G36","machine":{}}' > $D/device.lock.json
python3 -I -B scripts/ios/pack-device.py work/ios/packs/n78ap-13G36.ctpack $D=devices/n78ap-13G36
# iOS 模拟器版（依赖源码要先 fetch-sources.sh 下好）
scripts/ios/build-deps.sh iphonesimulator
TCG=jit scripts/ios/build-qemu.sh iphonesimulator && TCG=jit scripts/ios/make-dylib.sh iphonesimulator
# 包放进模拟器里 App 的 Documents/import/，打开 App 自己导入；然后计时、进「设置」
SIM_UDID=$(cat work/ios/sim-udid) scripts/ios/sim-boot.sh n78ap-13G36 jit 420
scripts/ios/sim-settings.sh n78ap-13G36 0.381,0.819     # 7.1.2 用 0.144,0.810
```

`build-qemu.sh` 会在 iOS 工作树上依次打 `patches/ios-*.patch`、`a5-n78-skeleton.patch`、`a5-n78-ios-ui.patch`；iOS 工作树要先从 `upstream/qemu-ios` 本地克隆，并把 meson 子项目（berkeley-softfloat-3、berkeley-testfloat-3、dtc、keycodemapdb）复制进去。触摸纵向偏上约 100 像素，脚本里点按的坐标已经往下补了。

## A6：iPhone 5（n41）的 10.3.4（14G61）（报告 `docs/reports/a6-step1.md`）

机型 `iPhone-5`（`n78_run.sh` 用 `MACHINE=iPhone-5`），CPU `apple-swift`，都在 `a5-n78-skeleton.patch` 里。A6 新加的工具：

| 文件 | 作用 |
|---|---|
| `dtcmp.py A.bin B.bin [前缀]` | 两份设备树逐节点比兼容串、第一个 reg、中断 |
| `cdhash.py 文件或目录…` | Mach-O 各切片的 CDHash（第 0 槽代码目录，10.3.4 的 AMFI 认这个） |
| `n41_trustcache.py 内核 输出 哈希文件… [--keep …]` | 把 CDHash 换进 14G61 内核的静态信任缓存；`n78_kboot.py` 的 `N78_TRUST=` 调它 |
| `stacksym.py 缓存 stacks+X.ips 进程名…` | 看门狗抓的全体线程栈（bug_type 288）按共享缓存的镜像和导出符号命名，查谁卡住了谁（报告 13.2、13.3） |

`n78_unpack.py` 加了板号参数（一个包给几种板子）、不加密的镜像不用密钥；`n78_volumes.py` 认 GPT 的根文件系统；`n78_activate.py`、`n78_devcache.py`、`n78_diskfix.sh` 加了 14G61 分支（14G61 还在数据卷的 launchd `disabled.plist` 里禁掉 CommCenter、storage_mounter、DeviceOMatic：没有基带 CommCenter 一起来就崩，SpringBoard 主线程会一直等它；后两个把 USB 根盘当外接存储，锁屏上挂一条「Cannot read the connected storage media」；还删掉 SpringBoard 的壁纸缓存 `MappedImageCache/Wallpaper/`，那是 GL 画了再读回的，用旧前端开过的盘里存的是全黑，报告 17）。`n78_kboot.py` 对 n41 把时钟频率表补满设备树的 96 槽（否则 spi1 的时钟读到 0，触摸起不来）。QEMU 侧 n41 另有 lm3534 背光的最小应答（i2c0 的 0x63）和显示模型的 `gamma-busy`（A6 的显示驱动装 gamma 表时等 0x40 清零、没有超时，报告 16.3）；GL 前端在 10.x 上把当前上下文也放进苹果原版 gl* 读的 TLS 第 30 槽，缓存里各镜像直接调的 gl* 才进得了前端（16.4）。这些都在 `a5-n78-skeleton.patch` 里。`n78_run.sh` 用 `QEMU=` 指定别的 qemu-system-arm（做新旧版对照）。`qinput.py` 的 `T:chord:equal+minus+l` 同时按几个键。

```bash
# 固件（用户批准）：iPhone_4.0_32bit_10.3.4_14G61_Restore.ipsw，sha1 2f88a216491667ce33e768ab54752d9d0f53dc20
python3 -I -B tools/a5/n78_unpack.py work/firmware/iPhone_4.0_32bit_10.3.4_14G61_Restore.ipsw - work/a6/dec/14G61-n41 n41ap
# 1. 卷和两分区盘（根文件系统是包里最大的 058-74968-065.dmg）
cd work/a5 && python3 -B ../../tools/a5/n78_volumes.py ../a6/rootfs/14G61-rootfs.dmg ../a6/vol-14G61 && cd ../..
python3 -I -B tools/a5/n78_usbroot.py work/a6/vol-14G61/system.img work/a6/disks/14G61-full.img work/a6/vol-14G61/data.img
# 2. 信任缓存要保留的哈希：根文件系统和恢复内存盘里全部 Mach-O
python3 -I -B tools/a5/cdhash.py 挂载的系统卷 > work/a6/cdhash-rootfs.txt; python3 -I -B tools/a5/cdhash.py 挂载的内存盘 > work/a6/cdhash-ramdisk.txt
# 3. 格式化开机：内存盘加 1 MiB、换进 it_nandfmt（同 A5），助手的哈希进信任缓存
N78_TRUST=work/a6/trust-ramdisk.txt N78_SHOW=arm-io/iop,arm-io/flash-controller0 N78_RAMDISK=work/a6/nandfmt/rd-14G61.dmg \
  python3 -I -B tools/a5/n78_kboot.py work/a6/dec/14G61-n41 work/a6/kboot/n41-14G61-nandfmt.bin "nand-enable-reformat=1"
cp -c work/a6/disks/14G61-full.img work/a6/nandfmt/disk-1034-formatted.img && mkdir -p work/a6/nandfmt/nand-1034-formatted
MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-1034-formatted.img SNAP=off tools/a5/n78_run.sh work/a6/runs/fmt4 \
  work/a6/kboot/n41-14G61-nandfmt.bin 420 -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-1034-formatted
# 看到 "system keybag created; halting" 就按 PID 结束 QEMU（之后关机超时会反复 panic，日志暴涨）
# 4. 改盘（生成 DISK.img.trust），带这些哈希做正常开机包
cp -c work/a6/nandfmt/disk-1034-formatted.img work/a6/nandfmt/disk-n2.img && tools/a5/n78_diskfix.sh work/a6/nandfmt/disk-n2.img
N78_TRUST=work/a6/nandfmt/disk-n2.img.trust N78_SHOW=arm-io/iop,arm-io/flash-controller0 \
  python3 -I -B tools/a5/n78_kboot.py work/a6/dec/14G61-n41 work/a6/kboot/n41-14G61-n2.bin
# 5. 正常开机：第一次约 260 秒数据迁移（苹果标志加进度条），迁移后熄屏，按 PID 结束
mkdir -p work/a6/nandfmt/nand-n2 && cp -c work/a6/nandfmt/nand-1034-formatted/* work/a6/nandfmt/nand-n2/
MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-n2.img SNAP=off tools/a5/n78_run.sh work/a6/runs/n3 work/a6/kboot/n41-14G61-n2.bin 360 \
  -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-n2
# 6. 从迁移过的盘再开（快照模式，盘不变）：约 100 秒锁屏，按 Home 进主屏，点「设置」（报告 15.2）。
#    熄屏后按 Home 能叫醒（报告 16.4、16.5）；锁屏和主屏有壁纸（17）
MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-n2.img tools/a5/n78_run.sh work/a6/runs/f2 work/a6/kboot/n41-14G61-n2.bin 230 \
  -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-n2 &
python3 -I -B tools/a5/qinput.py work/a6/runs/f2/qmp.sock work/a6/runs/f2 100:shot 120:key:h 128:shot \
  135:swipe:560,600,80,600 145:shot 150:swipe:80,600,560,600 170:tap:396,860 182:shot
```

