# M1 第一阶段：交叉编译、最简 App 壳、模拟器和 iPhone 18 Pro 上开机

- 日期：2026-11-01
- 执行会话：M1 第一阶段。原定范围是 B1、C1 到 C3、D1、E0（iOS 模拟器），中途决策会话追加了 iPhone 18 Pro 上的 E1（解释器）和 E2（Xcode/LLDB 拿 JIT）。
- 没做的：没碰 iPhone 14 Pro，没装 StikDebug，没 commit，没对外发任何东西，没动 M0 的目录（`work/devices/`、`work/states/` 只读克隆）。

## 0. 结论

1. **qemu-ios（QEMU 11.0.5，b225694505）几乎原样就能编成 iOS dylib。** 整个 QEMU 源码只加了一个构建开关补丁（`patches/ios-host-gles-option.patch`，8 行，给 meson 加 `-Dhost_gles=disabled`），一行 C 代码都没改。依赖 sysroot 每个平台约 1 分钟，QEMU 每份约 36 秒，四份 dylib（iphoneos、iphonesimulator 各有解释器版和 JIT 版）每份约 34 MB，只依赖 CoreFoundation、CoreMedia、CoreVideo、VideoToolbox 和 libz、libSystem、libresolv、libiconv，iOS 上都有。协程用 sigaltstack 就行，不需要 libucontext。
2. **iOS 模拟器里两台设备、两种后端都开到了主屏**：iPod touch 2 代 3.1.3（n72ap 7E18）和 iPhone 3GS 6.1.6（n88ap 10B500），解释器版和 JIT 版都行。JIT 在模拟器里不用挂调试器。
3. **iPhone 18 Pro（iOS 27.2，24B119）上也开到了主屏**，解释器版和 JIT 版（Mac 上的 LLDB 经 Wi-Fi 挂着）各两台。这就是 M1「第一」里程碑的技术部分：qemu-ios 在 iPhone 上跑 iPhone OS 3 和 iOS 6。
4. **最大的瓶颈是 JIT 代码区的「准备」**：照上游 `lldb_jit.py` 的做法，调试器要把整块代码区读出再写回。手机走 Wi-Fi 连 Mac，实测约 0.8 MB/s：256 MB 要 322 秒，所以真机测量时代码区缩到 32 MB（准备 38 到 46 秒）；缩小后 JIT 要频繁清空重翻译，提速只剩 2 到 4 倍（模拟器里 256 MB 时是 4 到 9 倍）。解决办法见第 7 节（插线、改新协议让调试器直接分配可执行内存）。
5. 真机解释器版：iPod touch 2 代 43 秒到锁屏，3GS 115 秒；主屏待机 CPU 分别约 50% 和 91%（一个核），占用 380 到 560 MB；App 可用内存约 3.0 GB，宽裕。

## 1. 能复现的构建命令

前提：Xcode 27.2、Homebrew 的 meson 1.11、ninja、pkg-config、jq，`/opt/homebrew/opt/python@3.12`（和 M0 同一个），XcodeGen。全部在仓库根目录跑。

```bash
# B1：下载依赖源码（8 个包 66 MB，逐个核对 sha256），再为两个平台各编一套静态库 sysroot
scripts/ios/fetch-sources.sh
scripts/ios/build-deps.sh iphonesimulator     # 约 1 分钟 → work/ios/sysroot-iphonesimulator-arm64
scripts/ios/build-deps.sh iphoneos            # 约 1 分钟 → work/ios/sysroot-iphoneos-arm64

# C1：qemu-ios 的独立工作树（同一个提交），meson 子项目从上游克隆本地复制，不联网拉源码
git -C upstream/qemu-ios worktree add --detach "$PWD/work/ios/qemu-ios" b225694505
for d in dtc keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3; do cp -R upstream/qemu-ios/subprojects/$d work/ios/qemu-ios/subprojects/; done

# C2/C3：四份 QEMU 和 dylib（build-qemu.sh 会自动打 patches/ios-*.patch），每份约 36 秒
for p in iphonesimulator iphoneos; do for t in interp jit; do
  TCG=$t scripts/ios/build-qemu.sh $p && TCG=$t scripts/ios/make-dylib.sh $p
done; done
# 产物：work/ios/build-qemu-<平台>-<后端>/libqemu-arm-<后端>.dylib

# D1：App 壳（嵌入阶段会把上面的 dylib 拷进 Frameworks 并签名）
(cd app && xcodegen generate)
xcodebuild -project app/ClassicTouch.xcodeproj -scheme ClassicTouch -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath work/ios/DerivedData build
xcodebuild -project app/ClassicTouch.xcodeproj -scheme ClassicTouch -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath work/ios/DerivedData \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<签名团队 ID> build
```

开机测量（设备先放进 App 的 Documents，见第 3 节）：

```bash
scripts/ios/sim-boot.sh n72ap-7E18 interp          # E0，模拟器
TBSIZE=32 scripts/ios/device-boot.sh n88ap-10B500 jit   # E1/E2，真机；jit 会自动挂 LLDB
```

`scripts/ios/` 一览：

| 文件 | 作用 |
|---|---|
| `sources.tsv`、`fetch-sources.sh` | 依赖源码的官方地址和 sha256（glib 到 nettle 取自 LightTouchMac 的 `dependencies.json`），下载并核对 |
| `common.sh` | 平台设置：`-target arm64-apple-ios16.0[-simulator]`、SDK、并行度（上限 8） |
| `build-deps.sh` | libffi 3.8.0、pcre2 10.48、glib 2.88.3（带 proxy-libintl 0.5 和 LightTouchMac 的 pipe2 补丁）、pixman 0.46.4、libslirp 4.9.4（加 qemu-ios 的两个补丁）、OpenSSL 3.6.3（只要 libcrypto）、Nettle 3.10.2，全静态；许可证原文放 `sysroot/share/licenses/` |
| `build-qemu.sh` | 改自上游已删的 `contrib/ios-app/build-ios.sh`：去掉 TCTI 和 PGO，`--without-default-features` 再打开 pixman、slirp、nettle，`--with-coroutine=sigaltstack`，`-Dhost_gles=disabled` |
| `make-dylib.sh` | 改自上游已删的 `make-dylib.sh` 和现行 `make-dylib-macos.sh`：取 ninja 的链接命令，把 `system/main.c` 换成 `qemu-ios-entry.c`，链进 `qemu-ios-ui.c` 和 `qemu-macos-extras.c`，导出和 Mac 版相同的 ABI 再加两个 iOS 专用函数，共 58 个；不用 `-undefined dynamic_lookup` |
| `embed-qemu.sh` | Xcode 构建阶段：拷 dylib 进 Frameworks 并签名 |
| `pack-device.py` | 把设备目录打成 `.ctpack`（只装有数据的区段），见第 5 节 |
| `sim-boot.sh`、`device-boot.sh`、`summarize-run.py` | 冷启动计时：重置状态、启动、每秒一张客体截图、OCR 判锁屏和主屏、自动解锁、汇总 |
| `lldb_jit.py` | 上游已删的 LLDB 停止钩子，原样找回（只加了来源说明） |
| `lldb_jit_runner.py` | E2 用的调试器：LLDB SB API、同步模式，应答 `brk #0x69` |

依赖比简报多了两个，都是官方源码包：**libffi**（iOS SDK 里没有 ffi 头文件，模拟器 SDK 连库都没有，glib 的 gobject 要它）和 **Nettle**（QEMU 11 去掉了内置 AES，iPod touch 1 代和 A4 机型的 CDMA 解密靠它；LightTouchMac 也编它）。另外 QEMU 的 configure 会用 pip 从 PyPI 装 `qemu.qmp` 和 `setuptools` 两个构建工具（和 M0 的 Mac 构建一样，几百 KB）。没下载任何预编译二进制。

## 2. 补丁和对上游的改动

| 补丁 | 改了什么 | 原因 |
|---|---|---|
| `patches/ios-host-gles-option.patch` | `meson_options.txt` 加 `host_gles` 特性开关（默认 auto，行为和上游一样），`meson.build` 里 `host_gles` 依赖改用它，`scripts/meson-buildoptions.sh` 加对应的 `--enable/--disable-host-gles` | iOS SDK 带 OpenGLES.framework，上游只要找到就自动编 EAGL 版 GL 桥，没法关。首次开机要先不用宿主 GL（调研报告 4.5）：换成 `gles-host-stub.c`，客体探测 GLES HLE 失败后退回软件合成 |

除此之外 QEMU 源码一行没改。原来预计要改的几处都不用改：`tcg/region.c` 的 TXM 路径、`osdep.h` 的 JIT 写保护空桩、configure 的 `needs_exe_wrapper` 都在主干里，直接能用；`file-posix.c` 的 IOKit、`system()` 在 iOS 上不可用这些，QEMU 自己早已处理。

运行时用到的两个机器选项（在 App 里拼参数时加，不是补丁）：

- iPod touch 2 代加 `amc-mode=handshake`：默认的 `decode` 要 libavcodec（FFmpeg），没有就直接报错退出；`handshake` 只做音频握手，正好对应 M1 不出声。
- JIT 版加 `-accel tcg,split-wx=on`：默认 split-wx 是关的，会去申请 MAP_JIT，iOS 不给；双映射才走 `region.c` 的 TXM 路径。代码缓冲用 `tb-size`（App 默认 256 MB，真机 JIT 测量用 32 MB）。

## 3. App 壳（`app/`）

- XcodeGen 工程（`app/project.yml`），Bundle ID `org.classictouch.app`，显示名「Classic Touch」，都是占位名。最低 iOS 16，场景生命周期（iOS 27 SDK 要求），只竖屏。签名团队不写进仓库，构建时命令行传。
- `Engine.swift`：按后端 `dlopen` Frameworks 里的 `libqemu-arm-interp.dylib` 或 `-jit.dylib`，`dlsym` 出 ABI，在 8 MB 栈的后台线程上调 `qemu_ios_main`。一个进程只起一次 QEMU。
- `EmulatorViewController.swift`：CADisplayLink 每次屏幕刷新取 `qemu_ios_ui_frame` 的 BGRA 帧，做成 CGImage 放进 CALayer；单指触摸按客体屏幕归一化后给 `qemu_ios_ui_touch`；Home 键、电源键给 `qemu_ios_ui_button`；`sceneWillResignActive`、`sceneDidBecomeActive` 接 `qemu_ios_set_foreground`。顶上一行显示运行时间、CPU、占用、可用内存、帧数。QEMU 的 stderr、串口、每秒统计、客体截图都写到 `Documents/logs/<时间>-<设备>-<后端>/`。
- `DeviceProfile.swift`：读 FirmwareKit 的 `device.lock.json`，照 LightTouchMac 的 `BootRecipe.swift`（iPod 和 iPad 两种）和 M0 的 `bench.py` 拼 argv。M1 支持 `boot_strategy` 为 iboot（iPod touch 2 代）和 kboot（3GS、iPhone 4、iPod touch 3/4 代、初代 iPad）的设备。
- `DevicePack.swift`：启动时把 `Documents/import/*.ctpack` 解到 Documents。
- 启动参数（供脚本用）：`-device`、`-tcg`、`-tbsize`、`-resetstate`、`-waitdebugger`、`-guestpng`、`-autounlock`、`-qemuargs`；宿主可以往 `Documents/control/` 放 `unlock`、`home`、`quit` 文件来操作。
- 宿主 GL 关着，没有 entitlement 文件（`get-task-allow` 由开发签名自带），没加 `increased-memory-limit`。

设备放进 App：模拟器直接 `cp -c`（APFS 克隆）进容器的 `Documents/devices/`；真机用 `pack-device.py` 打包后 `xcrun devicectl device copy to` 拷进 `Documents/import/`，App 启动时解开。3GS 的包里带了 M0 走完设置向导的状态（`work/states/n88ap-10B500` 的克隆，放在 `golden-state/`），`-resetstate` 每次从它重来，开机直接到锁屏。

## 4. 开机结果

计时口径：App 调 `qemu_ios_main` 起算的墙钟秒；「锁屏」「主屏」是每秒一张客体截图里 OCR 第一次认出「slide to unlock」和主屏图标名的时间；CPU 是本进程所有线程 user+sys，百分比按一个核算（同 M0）；「QEMU 亮屏」是 QEMU 自己打的 `[boot] first lit frame`，不含等调试器和准备代码区的停顿，最适合横向比较。主屏时间受自动解锁的时机影响（屏还没亮时滑动无效，要重试），参考价值比锁屏低。

### 4.1 iOS 模拟器（E0，M4 Max 上的 iPhone 18 Pro 模拟器，iOS 27.2）

| 设备 | 后端 | QEMU 亮屏 | 锁屏 | 到锁屏的 CPU | 主屏 | 主屏待机 CPU | 最大占用 |
|---|---|---|---|---|---|---|---|
| iPod touch 2 代 3.1.3 | 解释器 | 36.3 秒 | 54 秒 | 54.5 秒 | 64 秒 | 58% | 394 MB |
| iPod touch 2 代 3.1.3 | JIT（256 MB） | 7.0 秒 | 10 秒 | 9.2 秒 | 19 秒 | 17% | 704 MB |
| iPod touch 2 代 3.1.3 | JIT（32 MB，对照） | 19.5 秒 | 27 秒 | 26.9 秒 | 35 秒 | 19% | 228 MB |
| iPhone 3GS 6.1.6 | 解释器 | 159.9 秒 | 160 秒 | 169.0 秒 | 179 秒 | 93% | 545 MB |
| iPhone 3GS 6.1.6 | JIT（256 MB） | 18.2 秒 | 19 秒 | 20.7 秒 | 49 秒 | 10% | 789 MB |

- 模拟器里 `os_proc_available_memory()` 恒为 0，可用内存没有意义。
- JIT 在模拟器里不用调试器：模拟器进程按 macOS 规则，`split-wx` 的双映射可以直接用。
- 32 MB 对照说明：代码缓冲缩小对 JIT 伤害很大（亮屏从 7 秒变 19.5 秒），所以第 4.2 节真机 JIT 的提速偏小主要是缓冲太小，不是手机慢。
- 第一次开机时的实际观察（`m1-sim-n72ap-3.1.3-interp-*.png`）：触摸、Home 键都能用；3.x 锁屏几秒不碰就熄屏，熄屏后按 Home 能叫醒；熄屏时解释器 CPU 降到 20% 到 30%，没有空转。

截图：`docs/reports/img/m1-sim-n72ap-3.1.3-interp-home.png`、`m1-sim-n72ap-3.1.3-interp-lock.png`、`m1-sim-n72ap-3.1.3-jit-home.png`、`m1-sim-n88ap-6.1.6-interp-home.png`、`m1-sim-n88ap-6.1.6-jit-home.png`。

### 4.2 iPhone 18 Pro 真机（E1、E2，iOS 27.2 24B119，A20 Pro，Wi-Fi 连 Mac）

| 设备 | 后端 | QEMU 亮屏 | 锁屏 | 到锁屏的 CPU | 主屏 | 主屏待机 CPU | 占用 | 可用内存（最低） |
|---|---|---|---|---|---|---|---|---|
| iPod touch 2 代 3.1.3 | 解释器 | 27.4 秒 | 43 秒 | 42.5 秒 | 54 秒 | 50% | 378 到 411 MB | 2965 MB |
| iPod touch 2 代 3.1.3 | JIT（32 MB） | 12.8 秒 | 88 秒，扣掉停顿约 18 秒 | 17.8 秒 | 101 秒 | 18% | 227 到 277 MB | 3099 MB |
| iPhone 3GS 6.1.6 | 解释器 | 114.6 秒 | 115 秒 | 122.7 秒 | 137 秒 | 91% | 534 到 559 MB | 2817 MB |
| iPhone 3GS 6.1.6 | JIT（32 MB） | 26.1 秒 | 84 秒，扣掉停顿约 26 秒 | 27.0 秒 | 112 秒 | 79% | 319 到 365 MB | 3011 MB |

- JIT 两行的「停顿」是：App 等 LLDB 挂上，QEMU 分配代码区时 `brk #0x69` 请调试器准备，调试器读写 32 MB 用了 46.4 秒（iPod）和 37.7 秒（3GS）。这期间整个 App 被调试器停住，手机画面不动（第 6 节）。停顿后 QEMU 才真正开始跑，所以 JIT 行看「QEMU 亮屏」和「到锁屏的 CPU」更准。
- 真机比 M4 Max 上的模拟器还快：解释器亮屏 27.4 秒对 36.3 秒（iPod）、114.6 秒对 159.9 秒（3GS）。
- 真机上 JIT 对解释器：亮屏快 2.1 倍（iPod）和 4.4 倍（3GS）；这是 32 MB 缓冲下的数字，照模拟器的对照推算，换成 256 MB 还能快 2 到 3 倍。
- 没加 `increased-memory-limit` 时 App 的内存上限约 3.3 GB，测量中可用内存一直在 2.8 GB 以上，iPhone 18 Pro 上内存不是问题。
- iOS 6 在解释器下主屏待机还占 91% 的核，耗电会是问题；iPod 3.1.3 是 50%。
- **决策会话核对补注**：3GS JIT 那次第 112 秒到主屏属实（`work/ios/runs/device/20261101-195908-n88ap-10B500-jit/guest-0112.png`）。但第 116 到 146 秒，客体里依次打开了设置、通用、语言，又退回主屏。脚本没有发这些点按（`events.log` 里只有两次 unlock 和一次 quit），是有人在手机上点的，正好说明真机 JIT 下触摸能用。因此这一行的「主屏待机 CPU 79%」不是待机数，要重测；`m1-device-n88ap-6.1.6-jit-home.png` 截到的也是设置刚打开的画面，不是主屏。

截图：`docs/reports/img/m1-device-n72ap-3.1.3-interp-booting.png`（devicectl 截的真机全屏，开机中）、`m1-device-n72ap-3.1.3-interp-home.png`、`m1-device-n72ap-3.1.3-jit-home.png`、`m1-device-n88ap-6.1.6-interp-home.png`、`m1-device-n88ap-6.1.6-jit-home.png`，以及两张锁屏的客体截图。原始记录在 `work/ios/runs/`（摘要 `*.summary`、每秒统计 `stats.csv`、`qemu.log`、串口、LLDB 日志）。

## 5. 遇到的问题和解决办法

| 问题 | 解决 |
|---|---|
| configure 加 `--disable-download` 后失败：它无条件要装 Python 的 tooling 组（qemu.qmp、setuptools），离线找不到 | 不加这个开关；meson 子项目事先从上游克隆本地复制，所以只会从 PyPI 装那两个构建工具，和 M0 一样 |
| meson 报 hexagon 目标「No build machine compiler」 | `--host-cc` 不能用工具链里的 clang 原身（找不到 macOS SDK），改用 `/usr/bin/clang`（xcrun 包装） |
| 依赖脚本末尾 `otool \| grep -m1` 触发 pipefail 退出 | 加 `\|\| true` |
| App 报「dylib 里没有 qemu_ios_set_foreground」 | Mac 版导出表没有它和 `qemu_ios_ui_frame_size`（Mac 不需要），iOS 导出表补上这两个 |
| iPod touch 2 代报「AMC decoding requires a build with libavcodec support」 | 机器选项 `amc-mode=handshake`，见第 2 节 |
| iPod touch 2 代报「is a NAND image store, written in place: it takes no nandrw overlay」 | 这台的 NAND 是就地写的镜像库，照 LightTouchMac 的 `liveNAND`：第一次启动把 NAND 克隆到 `state/nand` 再就地写，不传 nandrw。3GS 的 NAND 控制器支持页覆盖层，照 M0 用 `nand-overlay` |
| **iPod touch 2 代要苹果的 SecureROM（`bootrom_240_4`），本机没有** | 用 4 字节占位文件（一条 ARM `b .`）。看过 `hw/arm/ipod_touch_2g.c`：direct-iboot 冷启动时 bootrom 只被放进地址 0、从不执行，所以能开机；但**深睡（AP 断电）唤醒会从 bootrom 走真正的启动链，用占位文件时会停住**。测试中锁屏熄屏、按 Home 唤醒都正常，那是屏幕休眠不是 AP 断电；长时间待机会不会触发还没测。这件事要决策，见第 7 节 |
| devicectl 拷文件不保留稀疏空洞：设备的 NAND 是稀疏文件（iPod 实际 465 MB、表观 8.1 GB；3GS 加黄金状态表观 34 GB），实测把 4 GB 空洞当零照传要 71 秒 | 自己打包：`pack-device.py` 只收有数据的区段（SEEK_DATA/SEEK_HOLE，再跳过全零的 64 KiB 块），iPod 451 MB、3GS 1911 MB；拷进手机 9 秒和 32 秒，App 解包 0.4 秒和 1.8 秒，解出来还是稀疏文件 |
| 自动解锁失败：3.x、6.x 的锁屏几秒就熄屏，熄屏时滑动无效 | 先按 Home 叫醒，5 秒后再滑；脚本没看到主屏就每 20 到 25 秒再试一次 |
| JIT：`devicectl --start-stopped` 加 LLDB 挂载后手机白屏 | 本机只有手机旧系统（24B5110a）的符号缓存，手机已是 24B119，LLDB 卡在 dyld 的加载通知上隔着网络读模块。改成 App 正常启动、带 `-waitdebugger` 在界面上等调试器，LLDB 设 `target.memory-module-load-level minimal` 只读段信息，挂载从超时变成 0.5 秒 |
| JIT：Xcode 27.2 的 LLDB 崩溃两次 | 一次是并行加载模块时在 `PlatformDarwinDevice::GetDeviceSupportDirectoryForOSVersion` 里崩（关 `target.parallel-module-load`）；一次是命令行驱动的事件线程在 `ProcessGDBRemote::WillPublicStop` 里崩。最后改成独立脚本 `lldb_jit_runner.py`：SB API、同步模式、自己处理每次停止，不用停止钩子 |
| JIT：偶发「Resume timed out」后一直卡住 | Wi-Fi 下默认的 gdb-remote 包超时不够，`plugin.process.gdb-remote.packet-timeout` 设成 60 |
| JIT：准备 256 MB 代码区要 322 秒 | 真机测量改用 `-tbsize 32`（38 到 46 秒）；根治见第 7 节 |

## 6. 装真机：现状、用了什么、还需要用户做什么

已经做了（决策会话追加 E1/E2 后，按「只用 Xcode 里已有的签名团队」的边界）：

- **签名团队**：Xcode 里有一个付费个人团队（团队 ID 略，`isFreeProvisioningTeam = 0`），钥匙串里有它的 Apple Development 证书。自动签名直接用了团队现成的通配描述文件「iOS Team Provisioning Profile: *」，没有新建 App ID，没改任何账号设置。团队 ID 没写进仓库。
- **手机**：iPhone 18 Pro，iOS 27.2 正式版（24B119，不是调研时缓存里那个 24B5110a），已配对，开发者模式已开，经 Wi-Fi 连着。装 App、拷设备、启动、挂调试器都是 `xcrun devicectl` 和 LLDB 在 Mac 上做的，不用用户在手机上点任何东西。
- 手机上现在装着 `org.classictouch.app`，Documents 里有两台设备（约 2.4 GB）和运行记录。测完已结束 App。不需要时可以直接在手机上删掉 App。

需要用户知道或决定的：

1. **测试时手机会白屏或冻住**：JIT 测试中 App 先显示「等待调试器」，挂上后在准备代码区时整个画面不动（32 MB 约 40 秒）。之前有一次用 `--start-stopped` 的做法白屏了 5 分钟，已经改掉。
2. **插线会快很多**（推测）：现在手机走 Wi-Fi，调试器读写内存约 0.8 MB/s。用数据线连 Mac 再测一次就知道能不能把代码区放大到 256 MB。要用户插线。
3. **要不要让 Xcode 拷一份 24B119 的设备符号**（约 6 到 7 GB，从手机拷到 Mac 的 `~/Library/Developer/Xcode/iOS DeviceSupport`）：在 Xcode 里直接「运行」到这台手机时会自动拷。现在靠 minimal 模块加载绕过去了，不拷也能用；拷了之后挂调试器、看崩溃栈更顺。我没触发。
4. **iPhone 14 Pro 没碰**：第一次连 Xcode 也要拷约 6 到 7 GB 符号，按简报等批准。
5. **离开电脑用 JIT（E3）**要装 StikDebug 和 LocalDevVPN、导配对文件，没做。

推荐手机：继续用 iPhone 18 Pro 做开发机（已经跑通，CPU 最快，内存宽裕）；14 Pro 在 E3 之后作为低配和 27.0.1 的对照。

## 7. 下一步建议

1. **JIT 改新协议（E3 之前最值得做的事）**：让调试器直接分配已准备好的可执行内存（StikDebug 的 universal.js 那套，`brk #0xf00d`、x0 传 0 时由 debugserver 代为分配 RX，参考 Ios-emul 的 0016 补丁），不再搬运整块数据。这样代码区可以回到 256 MB 以上，准备时间和区大小无关，真机 JIT 才能拿到模拟器里那种 4 到 9 倍的提速，也是脱离电脑用 StikDebug 的前提。这要改 `tcg/region.c`，做成 `patches/ios-txm-jit-protocol.patch`。
2. **先插线复测一次 E2**（256 MB），量化 USB 下的准备速度，判断旧协议在开发阶段还能不能凑合。
3. **iPod touch 2 代的 SecureROM 怎么办（要决策）**：上游 Light Touch 把 `bootrom_240_4` 打包在 App 里，我们的规矩是苹果固件不进仓库、不进 App。选项：让用户自己提供；或者研究能不能让唤醒也走 direct-iboot 的路子（改 qemu-ios）、或在客体里关掉深睡。在这之前，iPod touch 2 代长时间待机可能会卡住，要先实测一次长待机。
4. **省电**：解释器下 iOS 6 主屏待机占 91% 的核。值得看上游 blake-lucas 分支的空闲优化，以及前后台切换时暂停虚拟机。
5. **F 阶段的事照原计划**：EAGL 补 ES 2.0、快照（无 GL 时存、退出、新进程恢复、看能不能点）、`tb-size` 和内存对比、`glGetTexImage` 探测。

## 8. 产物和目录

- 仓库里（未 commit）：`scripts/ios/`、`patches/ios-host-gles-option.patch`、`app/`（`project.yml`、生成的 `ClassicTouch.xcodeproj`、`ClassicTouch/*.swift`、`Info.plist`）、本报告和 `docs/reports/img/m1-*.png`。
- `work/ios/`（约 7.5 GB，不提交）：`src/`（源码包）、`sysroot-*`、`deps-build/`、`qemu-ios/`（工作树，带补丁）、`build-qemu-*`（四份构建和 dylib）、`DerivedData/`、`devices/`（M0 设备的 APFS 克隆和 3GS 黄金状态）、`packs/`（`.ctpack`）、`runs/`（测量记录）、`logs/`。
- 专用模拟器「ClassicTouch iPhone 18 Pro」（7C0870F5-C435-4A26-AC3C-D17ADB816486），App 容器里有两台设备的克隆。
- `upstream/qemu-ios` 本身没改，只多了一条 worktree 登记。
- 自动化记忆里加了一条：真机测试会白屏或冻住时先跟用户说明。
