# M1 调研：把 qemu-ios 搬上 iPhone 的可行性

- 日期：2026-11-01
- 作者：M1 调研执行会话（只读调研，没有克隆、下载或修改任何仓库文件，本文件除外）
- 方法：`gh api` 读 samhenrigold/qemu-ios、samhenrigold/LightTouchMac、utmapp/UTM、utmapp/qemu、StikDebug 等仓库的提交和历史文件；WebSearch / WebFetch；本机 Xcode 27.2 的 iPhoneOS27.2 SDK 和本机已有的 iPhone 18 Pro 设备符号缓存。
- 标注：**【已核实】** 表示我直接读到了源码、提交说明、SDK 文件或项目自己的文档；**【推测】** 表示我的推断，或只有第三方说法、没能独立核实。
- 测试机（决策会话补充）：iPhone 18 Pro（A20 Pro，iOS 27.2），iPhone 14 Pro（A16，iOS 27.0.1）。

---

## 0. 结论摘要

1. **上游真的在 iPhone 真机上跑起来过，放弃的原因是性能，不是构建或图形。** 2026-08-04 作者把 qemu-ios 编成 iOS dylib、塞进 App、拷进 NAND 镜像在手机上开机，JIT 只能在 Xcode 调试器挂着时用。8-05 的「TCG experiments, dead end.」是一整套给纯解释器提速的实验（UTM 的 TCTI、PGO、按地址 HLE 掉 memcpy 之类、拉长定时器、降 vsync），结论是：发布版「永远不会有 JIT」，解释器约慢 30 倍，UI 只有 1 到 2 帧，TCTI 和普通解释器只差 1%。同一天作者转去做 Mac 版（LightTouchMac 首个提交也在 8-05）。【已核实】
2. **JIT 在 iOS 26/27 上可以拿到，但必须靠外部调试器，而且要按 TXM 的新协议走。** 两台测试机在 iOS 27 上都属于 TXM 设备，机制相同：App 先把代码区映射成 RX，再用 `brk` 陷入让调试器（Xcode LLDB 或 StikDebug 的脚本）「准备」这块内存。qemu-ios 的 `tcg/region.c` 里已经有这段代码（从 UTM 移植，用旧的 `brk #0x69` 协议）。有一份公开报告确认 QEMU 类 App 在 **iOS 27.2** 上用 StikDebug 拿到了 JIT（iPhone 16e，新的 `brk #0xf00d` 协议）；**27.0.1 上没找到成功报告**，只有失败报告。【已核实 / 27.0.1 部分为推测】
3. **交叉编译建议直接在 qemu-ios（QEMU 11.0.5）上加 iOS 构建，不要 rebase 到 utmapp/qemu（10.0.12）。** 上游研究文档写「rebase 到 utmapp/qemu」时 qemu-ios 还是 QEMU 8.2；现在它反而比 UTM 新三个大版本。iOS 需要的几样东西（TXM 版 JIT 缓冲区、iOS 下 `pthread_jit_write_protect_np` 空桩、交叉编译的 configure 修正、EAGL 上下文）都还留在 qemu-ios 主干里；删掉的只是构建脚本，可以从 `af4d255637` 找回来改。【已核实】
4. **图形走 EAGL（系统 OpenGLES.framework）最省事：iOS 27.2 SDK 和 iPhone 18 Pro 真机上它都还在，导出 457 个 gl 函数。** 但**「带 GL 的快照」在任何 ES 宿主上都还没人做出来**（EAGL、ANGLE、安卓的 EGL 都挂着迁移阻塞），上游 Mac 版 10-22 还发现「快照恢复后点不动」。这两件事直接关系到「随时切换版本」，是 M2 最大的风险，M1 应该先摸清楚。【已核实】
5. **有人在做，但没有人做成我们要的东西。** S5LBox（从零写的解释器，只有 iPhone 3G 的 3.1.3，0 到 4 帧）已发布；pocketTouch 发了一个闭源 IPA，自称跑 1.x 到 3.x，未核实；Inferno-iOS、Ios-emul 在 iPhone 上跑的是 iOS 14（iPhone 11 模拟）。**公开可见的、基于 qemu-ios、覆盖 1 到 7、带 JIT 的 iPhone 版目前没有。**【已核实（截至 2026-11-01 的 GitHub 与网络搜索）】
6. **M1 建议先在 iPhone 18 Pro 上试**，理由见第 8 节；iPhone 14 Pro 作为低配基线第二个跑。

---

## 1. 上游 8 月的 iPhone 宿主尝试走到了哪一步

### 1.1 时间线【已核实】

| 日期 | 提交 | 内容 |
|---|---|---|
| 07-30 | 仓库创建 | 从 devos50/qemu-ios（QEMU 8.2）起步 |
| 08-03 | [20577fdbbb](https://github.com/samhenrigold/qemu-ios/commit/20577fdbbbd9) | 写可行性研究 `docs/research/ipod-touch-2g-on-iphone.md`：在 Mac 上测 TCI 比 JIT 慢 3.3 到 5.2 倍，结论「可行」，真正的阻碍是 JIT 要靠第三方工具每次启动重新打开 |
| 08-04 | [74e9ca7934](https://github.com/samhenrigold/qemu-ios/commit/74e9ca793442) | 整体 rebase 到 QEMU v10.0.2（和当时 UTM 同版本） |
| 08-04 | [49f0804cb7](https://github.com/samhenrigold/qemu-ios/commit/49f0804cb70a) | 「Shimmying things around for an iOS port????」：加 `build-ios-sim.sh`、`gles-host-stub.c` |
| 08-04 | [d14b8cc839](https://github.com/samhenrigold/qemu-ios/commit/d14b8cc839a8) | 「iOS not-really-JIT JIT helpers」：加 `contrib/ios-app/` 全套（`build-ios.sh`、`make-dylib.sh`、`embed-qemu.sh`、`install-images.sh`、`lldb_jit.py`、`qemu-ios-entry.c`、`qemu-ios-ui.c/h`），`tcg/region.c` 加 iOS 26 TXM 路径，configure 加交叉编译的 `needs_exe_wrapper` |
| 08-05 15:27 | [01ae922092](https://github.com/samhenrigold/qemu-ios/commit/01ae922092d37d029f42427f7aa50025fc6d2a9b) | 「TCG experiments, dead end.」：+8491 行，见 1.3 |
| 08-05 | [LightTouchMac 70534953](https://github.com/samhenrigold/LightTouchMac/commit/70534953) | 「Native AppKit front-end embedding qemu-ios as an in-process dylib」：Mac 版诞生 |
| 08-05 20:51 | [7615017fe7](https://github.com/samhenrigold/qemu-ios/commit/7615017fe7fe) | `contrib/macos-app/make-dylib-macos.sh`：「contrib/ios-app is reused unchanged」 |
| 08-06 | [dd93107e64](https://github.com/samhenrigold/qemu-ios/commit/dd93107e6446) | ios-app 的快照 ABI（save2/status/resume），之后 Mac 版沿用 |
| 10-07 | [b18cd1606c](https://github.com/samhenrigold/qemu-ios/commit/b18cd1606c9c) | 移植到 QEMU 11：保留「the iOS JIT buffer path in region.c」，TCTI 因 QEMU 11 换了后端接口没移植 |
| 10-08 | [74759924a1](https://github.com/samhenrigold/qemu-ios/commit/74759924a121) | 删除 TCTI（「It never built on QEMU 11」） |
| 10-13 | [6a9aacff4b](https://github.com/samhenrigold/qemu-ios/commit/6a9aacff4b89) | 删除「Dead contrib tools」：iOS 宿主脚本 5 个；`qemu-ios-entry.c`、`qemu-ios-ui.c/h` 因为 Mac dylib 还在用而保留 |

### 1.2 真机跑起来过吗：跑起来过【已核实，证据来自代码注释】

- `embed-qemu.sh`（删除前版本，见 [af4d255637 的 contrib/ios-app](https://github.com/samhenrigold/qemu-ios/tree/af4d25563788929799725b626c3c2f644bbeb58b/contrib/ios-app)）：「a rebuilt emulator was never re-copied, so the phone quietly went on running the previous build」，说明在手机上反复跑过。
- `install-images.sh`：用 `xcrun devicectl device copy to` 把约 520 MB 的打包 NAND、bootrom、NOR、iBoot 拷进 App（Bundle ID `gold.samhenri.LightTouch`）的 Documents。
- dead-end 提交里 `embed-qemu.sh` 的注释：TCTI「measured on device it was within 1% of the plain interpreter on this workload (104.0 vs 104.9 CPU-seconds …) while costing 322 MB of gadget tables」。
- `tcg/region.c`（至今仍在主干）：「measured on an A19: rx and rwx both map fine with CS_DEBUGGED unset」，即作者的测试机是 A19（iPhone 17 系列），iOS 26。
- `lldb_jit.py`：LLDB 停止钩子，接到 `brk #0x69` 后把代码区读出再写回，「That write is what makes the kernel record the mapping as a legitimate debug region」，说明 JIT 版在 Xcode 调试器下跑过。
- `gles-host-eagl.c`：EAGL 上下文 + IOSurface 颜色附件已写好，注释里有在真机上量过的读回格式（「Measured against a red triangle」）。
- `qemu-ios-ui.c`：加了前后台切换时停 GL 调用、切后台存快照、回前台恢复等逻辑，都是 iOS App 生命周期才需要的。

研究文档开头写「nothing was built from it」，和上面的提交记录矛盾；文档是 08-03 写的，代码是 08-04/05 写的，文档后来只做过整理，没更新这段。

### 1.3 为什么叫「dead end」：性能，而且作者认定发布版没有 JIT【已核实】

dead-end 提交加的东西几乎全是「让纯解释器快一点」的实验：

| 实验 | 文件 | 注释里的结论 |
|---|---|---|
| UTM 的 TCTI 后端 | `tcg/aarch64-tcti/`（含从 UTM 搬来的 1026 行 README） | 真机上和 TCI 只差 1%，还要 322 MB 小工具表，默认不打包 |
| PGO 等编译优化 | `build-ios.sh` | `-O3`、LTO、`-mcpu` 都在噪声内，只有 PGO 快 13.7% |
| 关掉 goto_ptr 的对比开关 | `tcg-accel-ops.c` | TCTI 不支持 goto_ptr，ARM 的 `bx lr` 每次都要回 C 查表 |
| 按虚拟地址 HLE 客体函数 | `target/arm/tcg/it-hle.c` | 「there will never be a native JIT in the shipping app and the TCG interpreter is roughly 30x slower than one」 |
| 拉长客体定时器 | `ipod_touch_timer.c` | 「Under an interpreter that is roughly a tenth of real speed」，客体被定时器中断淹没 |
| 降低面板 vsync | `ipod_touch_lcd.c` | 「under an interpreter the guest may only manage one or two frames a second」 |
| 客体/vCPU 采样分析器 | `cpu-exec.c` 等 | 用来找该 HLE 什么 |

所以失败点是**性能**：作者的前提是「发布版 App 只能用解释器」（JIT 只在调试器挂着时可用，`build-ios.sh` 写明「development-only」），而解释器下 iPod touch 2G 的 3.1.3 只有约十分之一实速、UI 一两帧，各种提速手段都没救回来。不是构建失败（dylib、嵌入、拷镜像都跑通了），不是图形失败（EAGL 路径写好了），也不是「JIT 做不到」（调试器下做到了）。

两个数字要注意区分：Mac 上测开机 CPU 秒，TCI 比 JIT 慢 3.3 到 5.2 倍（研究文档）；dead-end 代码注释说解释器约慢 30 倍、约十分之一实速（交互场景）。M0 正在 Mac 上实测 JIT 和纯解释器，等它的数据再定。【两个数字都已核实为上游原话，哪个更接近真实交互体验属推测】

另外，上游 README 的「Scope」明确写了不做 iOS 版，请求会被关闭（[LightTouchMac README](https://github.com/samhenrigold/LightTouchMac#scope)）。所以这既是「性能走不通」，也是作者转向 Mac 后的方向选择；他后来没有再碰 iPhone 宿主，10 月把脚本当「Dead contrib tools」删掉。

### 1.4 删除后主干里还剩什么可以直接用【已核实】

- `tcg/region.c` 的 iOS 26 TXM 路径：先映射 RX、调试器在场时 `brk #0x69` 请调试器准备、再把写别名改成 RW；没有调试器时直接报错「jit needs an attached debugger on this OS」，好让上层退回解释器。代码和 [UTM 的 region.c](https://github.com/utmapp/qemu/blob/utm-edition/tcg/region.c) 一致。
- `include/qemu/osdep.h`：iOS 上 `qemu_thread_jit_write/execute` 是空操作（iOS SDK 不导出 `pthread_jit_write_protect_np`）。
- `configure`：交叉编译时探测能否运行目标程序，不能就写 `needs_exe_wrapper = true`。
- `hw/arm/gles-host-eagl.c`（296 行）和 `meson.build` 里的 `host_gles` 依赖（OpenGLES、Foundation、IOSurface、CoreFoundation），`hw/arm/meson.build` 在没有 OpenGL 而有 OpenGLES 时自动编 EAGL 版。
- `contrib/ios-app/qemu-ios-entry.c`、`qemu-ios-ui.c/h`：给宿主 App 的 C ABI（`qemu_ios_main`、帧回调、触摸、按键、输入序列、前后台、快照 save2/status/resume），Mac 版一直在用、一直在维护。
- 被删的 `build-ios.sh`、`make-dylib.sh`、`embed-qemu.sh`、`install-images.sh`、`lldb_jit.py` 可以从 `af4d255637` 读回来改。

---

## 2. 交叉编译

### 2.1 UTM 怎么编【已核实】

[`scripts/build_dependencies.sh`](https://github.com/utmapp/UTM/blob/main/scripts/build_dependencies.sh)：

- 平台 `-p ios|ios-tci|ios_simulator…`，`-a arm64`，最低 iOS 15，用 `xcrun --sdk iphoneos` 加 `-target arm64-apple-ios15.0` 交叉编译每个依赖，装进 `sysroot-iOS-arm64`。
- 依赖（[patches/sources](https://github.com/utmapp/UTM/blob/main/patches/sources)）：pkg-config、libffi、libiconv、gettext、libpng、libjpeg-turbo、glib 2.83、libgpg-error、libgcrypt、pixman 0.38、OpenSSL 1.1.1b、libtpms/swtpm、opus、zstd、spice、libusb、usbredir、libslirp 4.9.1、libucontext，加上 GPU 相关的 ANGLE（从 WebKit 抽）、virglrenderer、MoltenVK 等。
- QEMU 用 utmapp/qemu 的 `v10.0.12-utm`，iOS 上的参数：`--enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext --enable-hvf-private`；`ios-tci` 平台在 arm64 上加 `--enable-tcg-threaded-interpreter`（TCTI，给 App Store 上的 UTM SE 用）。
- `--enable-shared-lib`、`libucontext` 协程、TCTI 都是 utmapp/qemu 自己加的，上游 QEMU 没有。

### 2.2 上游 8 月怎么编（`build-ios.sh`，删除前版本）【已核实】

- 依赖直接用 UTM CI 产出的 sysroot（「the dependency sysroot is UTM's prebuilt CI artifact」）。
- `configure --cross-prefix= --cpu=aarch64 --cc="clang -isysroot $SDK -target arm64-apple-ios16.0" … --target-list=arm-softmmu --with-coroutine=sigaltstack --enable-slirp --audio-drv-list= --disable-coreaudio --disable-hvf --disable-cocoa --disable-sdl … --disable-tools --disable-plugins --disable-opengl`，`TCG=interp` 时加 `--enable-tcg-interpreter`。
- 不用 `--enable-shared-lib`，而是 `make-dylib.sh` 抓 ninja 链接 `qemu-system-arm` 的那条命令，把 `system/main.c` 换成 `qemu-ios-entry.c`，重新链成 `libqemu-arm-{jit,interp}.dylib`，只导出 `qemu_ios_*`。这个思路现在 Mac 版的 `make-dylib-macos.sh` 还在用。
- App 同时带 JIT 版和解释器版两个 dylib，启动时按是否有调试器选一个。

### 2.3 qemu-ios 比 UTM 多要什么【已核实，iOS 可用性一栏部分为推测】

依据：[qemu-ios meson.build](https://github.com/samhenrigold/qemu-ios/blob/main/meson.build)、[hw/arm/meson.build](https://github.com/samhenrigold/qemu-ios/blob/main/hw/arm/meson.build)、LightTouchMac 的 [dependencies.json](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/dependencies.json) 和 [build-package-native.sh](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/recipes/build-package-native.sh)。

| 依赖 | qemu-ios 用在哪 | iOS 上怎么办 |
|---|---|---|
| libslirp 4.9.4 + 两个补丁（`libslirp-set-restricted.patch`、`libslirp-guestfwd-connector.patch`） | 客体联网、`lan=off`、guestfwd | 找不到打过补丁的版本时 meson 会自动用 subproject 静态编，交叉编译应能复用【推测】；UTM 的 4.9.1 没有这两个补丁 |
| OpenSSL libcrypto（静态） | `ipod_touch_aes.c` 用 `<openssl/aes.h>`，`ipod_touch_pke.c` 用 `<openssl/bn.h>` | UTM sysroot 有 1.1.1b；LTM 用 3.6.3。iOS 上交叉编 OpenSSL 是成熟流程 |
| QEMU 自己的 cipher（LTM 用 nettle） | `s5l8930_cdma.c` 走 `crypto/cipher.h` | UTM 有 gcrypt；或用 QEMU 内置 AES【推测，需编译验证】 |
| FFmpeg 9.0.1 + qemu-ios 的两个 H.264 补丁，只开 aac/mp3/alac/h264 解码 | iPod touch 2G 的 H.264 视频和原始 AAC | 可选，没有时只是警告；LGPL，可以 iOS 交叉编；M1 可以先不要 |
| VideoToolbox、CoreMedia、CoreVideo、IOSurface | 视频解码、GL 表面 | iOS 都有 |
| glib、pixman、zlib | QEMU 基础 | UTM sysroot 有；zlib 系统自带 |
| libimobiledevice、libplist、usbmuxd 分支、libtatsu、libusb | LTM 侧：给模拟设备装 App、AFC、恢复固件 | 不链进 QEMU；iOS 上不能起 usbmuxd 守护进程，见 2.4 |
| ANGLE | 实验性渲染器 | 可选，见第 4 节 |

### 2.4 macOS 专用的代码，在 iOS 上怎么换【已核实现状，处理方式为建议】

| 组件 | Mac 上的现状 | iOS 上的处理 |
|---|---|---|
| Cocoa UI（`ui/cocoa.m`） | LTM 编译时 `--enable-cocoa` | `--disable-cocoa`。显示走 `qemu_ios_ui_attach` 的帧回调，App 自己画到 CALayer / Metal |
| CGL（`gles-host.c` 的 CGL 部分） | 默认渲染器 | iOS SDK 没有 OpenGL.framework，`TARGET_OS_IPHONE` 下自动走 EAGL；M1 也可以先完全不要宿主 GL（见第 4 节） |
| CoreAudio（`audio/coreaudio.m`，用 macOS 的 AudioObject HAL 设备 API） | `--enable-coreaudio` | iOS 没有这套设备 API，`--disable-coreaudio --audio-drv-list=`。M1 不出声；M2 用 noaudio 的 `IT_AUD_RT` 实时 PCM 抽头或音频捕获接口，交给 AVAudioEngine / RemoteIO |
| usbmuxd 分支 + `tcp_usb`（`-M …,usb-tcp-addr=`） | LTM 起 usbmuxd 进程连到 QEMU 的 tcp_usb，再用 libimobiledevice 装 App、传文件、恢复 | iOS 不能起子进程或守护进程。M1 不设 `usb-tcp-addr`；M2/M3 要么在进程内实现一个 usbmux，要么改走客体代理 + slirp guestfwd（S5LBox 就是用「虚拟 USB」装 App） |
| helper 进程、XPC、sandbox extension（LTM 的 HostRuntime） | Mac 上一台设备一个 helper 进程 | iOS 上 dylib 进程内运行。`qemu-ios-entry.c` 注释：「QEMU is not designed to be started twice in one process … One VM per app launch, as in UTM」。切版本要么重启 App，要么用 iOS 26 的 ExtensionKit 扩展进程（UTM 已用它跑 qemu-img，[PR #7908](https://github.com/utmapp/UTM/pull/7908)） |
| `pthread_jit_write_protect_np` | macOS 才有 | `osdep.h` 已为 iOS 做空桩 |
| Darwin kqueue poll、`file-posix` 打洞 | Darwin 通用 | iOS 也有 kqueue 和 fcntl，预计能编【推测】 |
| vmnet、libusb 直通、HVF | Mac | 全关 |
| FirmwareKit（Swift，做设备用） | macOS 声明，但已有 Linux/Windows/Android 条件分支；会起 iBoot32Patcher 子进程 | M3 的事：子进程要改成链接库 |

### 2.5 版本差多少，选哪条路【已核实版本号，建议为推测】

- qemu-ios 主干 `VERSION` 是 **11.0.5**；utmapp/qemu 的 `utm-edition` 是 **10.0.12**（UTM 主干用 `v10.0.12-utm`，2026-07-27 发布）。中间隔着 10.1、10.2、11.0 三个大版本。qemu-ios 10-07 才从 10.0.2 线迁到 11.0.3，旧线已不维护。
- 上游研究文档建议「rebase 到 utmapp/qemu」是 8 月初 qemu-ios 还是 8.2 时的判断，现在已经过时。
- 从 UTM 真正需要借的只有：(1) TXM 版 JIT 缓冲区，qemu-ios 已经有；(2) 可能需要的 libucontext 协程（见下）；(3) 依赖的交叉编译脚本。`--enable-shared-lib` 可以用重链接替代，TCTI 不值得要（见 3.2）。
- **建议：在 qemu-ios 的 QEMU 11 上直接加 iOS 构建**，改动放 `patches/`。往回 rebase 到 10.0.12 等于扔掉 qemu-ios 10 月以来的全部移植和修复，代价远大于自己补几个 iOS 条件编译。

协程后端有一个需要 M1 实测的分歧：上游 8 月的 iOS 构建用 `--with-coroutine=sigaltstack` 并在真机跑过；而 [Inferno-iOS](https://github.com/MakrSas/Inferno-iOS) 的 README 说「iOS has no usable `sigaltstack`」所以改用 ucontext（它的依赖里有 libucontext），UTM 也用 libucontext。QEMU 11 的 `coroutine_backend` 选项只有 ucontext / sigaltstack / windows / wasm。先试 sigaltstack，不行就把 UTM 的 libucontext 补丁搬过来（小改动）。【分歧本身已核实，结论待实测】

### 2.6 可参考的「QEMU 编成 iOS 库」先例【已核实】

- [Inferno-iOS](https://github.com/MakrSas/Inferno-iOS)（GPL-3.0，155 星）：用 Xcode 27.0 和 iOS 27 SDK，把 ChefKiss 的 QEMU 分支用 `meson … -Dshared_lib=true -Dcoroutine_backend=ucontext` 编成 `libqemu-aarch64-softmmu.dylib`，依赖 glib、pixman、libslirp、libucontext、lzfse、libpng、gmp、nettle、libtasn1；README 写明默认 TB 缓冲 128 MB，64 MB 时 8 到 11 帧、256 MB 时 21 到 25 帧。
- [Ios-emul](https://github.com/vytska69/Ios-emul)（立陶宛语，基于 QEMUAppleSilicon）：有完整的 iOS 补丁集，其中 [`0016-ios-txm-jit-via-stikdebug.patch`](https://github.com/vytska69/Ios-emul/blob/claude/ipsw-emulator-app/qemu/patches/inferno/0016-ios-txm-jit-via-stikdebug.patch) 就是我们需要的 TXM 新协议实现。

---

## 3. 执行方式

### 3.1 QEMU 11 的 TCI 在 aarch64 上还能用【已核实】

- qemu-ios 主干 `tcg/tci/` 完整，`meson_options.txt` 有 `tcg_interpreter`；在有原生后端的主机上打开只会打印「not recommended」警告。
- QEMU 11 的 `docs/about/deprecated.rst` 和 `removed-features.rst` 没有弃用 TCI；11.0 删的是 32 位宿主。QEMU 11 新增的 wasm64 宿主必须用 TCI，说明 TCI 还在被维护。
- 性能见 1.3：Mac 开机 CPU 秒慢 3.3 到 5.2 倍；上游真机交互场景约十分之一实速、一两帧。

### 3.2 UTM 的 TCTI 现状：不值得为它花力气【已核实】

- utmapp/qemu 里 TCTI 最后两次改动是 2025-07「update to support QEMU v10.0」和「implement vector immediate shifts」（[提交列表](https://github.com/utmapp/qemu/commits/utm-edition/tcg/aarch64-tcti)），只支持 10.0 的后端接口。
- qemu-ios 10-07 移植 QEMU 11 时明确没移植（「targets the 10.0 backend interface, which v11 replaced」），10-08 删除。
- 上游真机实测：对这个负载 TCTI 和 TCI 差 1%，还多 322 MB。原因之一是 TCTI 不支持 goto_ptr，ARM 客体每次函数返回都要回 C 查表。
- 结论：不移植 TCTI。没有 JIT 时的提速应该花在别处（PGO 有 13.7%，blake-lucas 分支的各类 TB 布局优化在 JIT 下也有效）。

### 3.3 iOS 26/27 上开 JIT 的机制【已核实】

**背景**：第三方 App 拿不到 `dynamic-codesigning`，所以 `MAP_JIT` 这条路走不通。以前的办法是带 `get-task-allow` 签名，让调试器挂上去，进程得到 `CS_DEBUGGED` 后就能自己 `mprotect` 出可执行页。iOS 26 起，有 TXM（Trusted Execution Monitor）的设备上这招失效：进程不能再把自己的页标成可执行，必须由调试器来「准备」每块可执行区域。

**TXM 设备的判定**（StikDebug 的 [`ProcessInfo+TXM.swift`](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/ProcessInfo%2BTXM.swift)）：

- iOS 26：iPhone 型号号 ≥ 14.2（A15 起）算 TXM。
- iOS 27：除 iPad8,11/8,12 外**全部**按 TXM 处理（DolphiniOS 在 iOS 27 beta 上专门修了 A13/A14/M1 的 JIT，见 [builds.io 指南](https://builds.io/blog/technologies/ios-technologies/how-to-enable-jit-on-iphone/)）。

**两种协议**（[StikJIT INTEGRATION.md](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md)、[universal.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/universal.js)、[legacy.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/legacy.js)）：

| | 旧协议（legacy.js） | 新协议（universal.js，官方推荐） |
|---|---|---|
| App 侧陷入 | `brk #0x69`，x0 = 地址，x1 = 长度 | `brk #0xf00d`，x16 = 命令（1 = 准备区域，0 = 脱离，2 = 下发脚本），x0/x1 = 地址/长度 |
| 调试器侧 | 处理**一次** `brk #0x69` 后自动脱离 | 循环处理，直到 App 主动发「脱离」；地址传 0 时由 debugserver 代为分配 RX |
| 谁在用 | UTM、DolphiniOS、Flycast、Inferno-iOS；**qemu-ios 现在的 region.c 也是这个** | MeloNX、touchHLE、Husk 等；Ios-emul |
| 备注 | universal.js 收到 `0x69` 会直接返回错误码 `0xE0000069` | 要求：先等 `CS_DEBUGGED` 出现再陷入，否则进程会崩；所有 RX 区域在脱离前一次准备好 |

QEMU 只在初始化时分配一块代码缓冲区，两种协议都够用。

**UTM 用的是哪种**：UTM 用 legacy.js（StikDebug 按 App 名自动分配，见 [AutoScriptAssignments.swift](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/AutoScriptAssignments.swift)）。UTM 的 [iOS.entitlements](https://github.com/utmapp/UTM/blob/main/Platform/iOS/iOS.entitlements) 只有 `extended-virtual-addressing`、`increased-memory-limit` 和 App Group；JIT 靠开发签名自带的 `get-task-allow` 加外部调试器，用 `csops` 查 `CS_DEBUGGED`（[UTMJailbreak.m](https://github.com/utmapp/UTM/blob/main/Services/UTMJailbreak.m)）。

**我们的 App 需要什么**：

- Entitlement：`get-task-allow`（开发签名自带，免费和付费账号都有）；建议加 `increased-memory-limit`；`extended-virtual-addressing` 对 32 位客体不需要。
- 代码：`region.c` 已有 TXM 路径。建议改成新协议（参考 Ios-emul 的 0016 补丁），App 启动时在调试器还挂着的窗口里把代码区准备好再脱离；没调试器时自动用解释器版 dylib。
- 运行时：设备开**开发者模式**；StikDebug 需要配对文件、App Store 上的 LocalDevVPN、挂载开发者磁盘映像（DDI）；我们的 App 名不在 StikDebug 的自动分配表里，用户要在 StikDebug 里长按 App 手动「Assign Script」（Inferno-iOS 就是这样让用户选 legacy.js），并且**要从 StikDebug 里启动 App**，先自己打开再附加会失败（维护者在 [#476](https://github.com/StikDebug/StikDebug/issues/476) 的回复）。

**拿 JIT 的四种方式**：

| 方式 | 适合 | 说明 |
|---|---|---|
| Xcode 直接运行 + LLDB 停止钩子 | M1 开发 | 上游 `lldb_jit.py` 的做法，连着电脑；不需要 StikDebug |
| StikDebug（AGPL-3.0）+ LocalDevVPN | 脱离电脑使用 | 用户多装一个 App；每次启动都要从 StikDebug 拉起 |
| 内嵌 StikJIT（MPL-2.0 的 XCFramework） | 以后改善体验 | 要放在一个 App 扩展里（进程不能自己调试自己），需要用户导入配对文件；免费账号下扩展也占 App ID |
| TrollStore / AltJIT | 不考虑 | TrollStore 在 17.0.1 后就没了；AltStore Classic 的 Enable JIT 需要电脑上的 AltServer |

### 3.4 两台测试机：都是 TXM，方案相同

| | iPhone 18 Pro | iPhone 14 Pro |
|---|---|---|
| 芯片 / 内存 | A20 Pro / 12 GB（[Wikipedia](https://en.wikipedia.org/wiki/IPhone_18_Pro)） | A16 / 6 GB |
| 型号号 | iPhone19,2（本机 Xcode 设备符号缓存目录名） | iPhone15,2 |
| 系统 | iOS 27.2（本机缓存里记的构建号是 24B5110a，像是 beta 构建号，需要确认现在是否已是正式版） | iOS 27.0.1 |
| 是否 TXM | 是（iOS 27 一律按 TXM） | 是（iOS 26 起就是：15.2 ≥ 14.2） |
| JIT 机制 | 调试器准备区域，同一套代码 | 同左 |
| StikDebug 已知问题 | iPhone 18 Pro 系列 DDI 挂载失败，3.1.11（09-23）改用 cryptex 挂载后修好；27.2 上有隧道建不起来的报告，最后归因于旧配对文件 | 27.0.x 上有「附加失败 E96」「Husk 卡在附加」等报告，维护者多归为操作问题，没找到成功报告 |
| 和本项目相关的硬件差异 | A19 起有 MIE（内存标记），第三方 App 默认不启用，不影响 JIT【推测，依据 [8ksec](https://8ksec.io/mie-deep-dive-enabling-apps/)】；CPU 明显更快 | 内存小一半，单核慢不少【推测】 |

### 3.5 iOS 27 正式版上 JIT 的公开报告

| 来源 | 系统 / 设备 | 结果 | 判断 |
|---|---|---|---|
| [Ios-emul docs/status.md](https://github.com/vytska69/Ios-emul/blob/claude/ipsw-emulator-app/docs/status.md) | **iOS 27.2**，iPhone 16e（A18），StikDebug，新协议 | QEMU 模拟的 iPhone 11 跑到主屏并能开设置 | **成功**【已核实为作者自述】 |
| [StikDebug 3.1.11 发布说明](https://github.com/StikDebug/StikDebug/releases) | iPhone 18 Pro 系列 | 修好 DDI 挂载 | 工具层面已适配 |
| [StikDebug #471](https://github.com/StikDebug/StikDebug/issues/471) | iOS 27.2 / 27.0 | 隧道失败，删 App 换配对文件后解决 | 配置问题 |
| [StikDebug #476](https://github.com/StikDebug/StikDebug/issues/476)、[#491](https://github.com/StikDebug/StikDebug/issues/491) | iOS 27.0 / 27.0.1 | 附加失败、App 报未开 JIT | 被维护者以「不计划修复 / 用户错误」关闭 |
| [Husk #183](https://github.com/Leviidev/Husk/issues/183) | iOS 27.0.1，iPhone 15 | 卡在附加，多人附和，仍开着 | 失败（原因不明） |
| [Inferno-iOS #8](https://github.com/MakrSas/Inferno-iOS/issues/8) | iOS 27 RC，iPhone 17 | 不再崩，但在苹果标之前卡住 | 不确定 |

结论：**27.2 有一份 QEMU 类 App 成功的公开记录；27.0.1 没有。** JIT 在 iOS 27 上「工具链支持、偶尔能跑通」，但每一环（配对文件、VPN、DDI、脚本分配、启动顺序）都可能出错，而且每次 iOS 更新都可能坏一次。M1 必须两台都实测。【推测】

---

## 4. 图形

### 4.1 本机 SDK 和真机里的 OpenGLES.framework【已核实】

- `iPhoneOS27.2.sdk/System/Library/Frameworks/OpenGLES.framework` 还在：`Headers/` 下有 `EAGL.h`、`EAGLDrawable.h`、`EAGLIOSurface.h`、`ES1/`、`ES2/`、`ES3/`；`OpenGLES.tbd` 导出 486 个符号，其中 **457 个 `gl*`**，ObjC 类 `EAGLContext`、`EAGLSharegroup`。ES1 固定管线全在（`glMatrixMode`、`glOrthof`、`glLightfv`、`glTexEnvf`、`glDrawTexfOES`、`glGenFramebuffersOES` 等）。
- 头文件里所有 API 标着 `OPENGLES_DEPRECATED(ios(2.0, 12.0))`，即 iOS 12 起弃用，但没有标成不可用；`texImageIOSurface:`（iOS 11 起）也还在。
- 本机 `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone19,2 27.2 (24B5110a)/` 里 iPhone 18 Pro 真机的 `OpenGLES` 二进制同样导出 **457 个 `gl*`**，还带 `GLEngine.bundle`（现在的 iOS GL 实际跑在 Metal 之上）。
- 有个意外：`glGetTexImage` 在 tbd 和真机二进制里都**导出了，但头文件里没有**。CGL 快照代码正依赖这个函数读回纹理。它在 iOS 上能不能用、行为对不对完全未知【推测，值得 M1 顺手探一下】。
- 上游研究文档当时核对的是 iPhone 17 + iOS 26.5 SDK，也是 457 个，与今天一致。

### 4.2 EAGL 路线

优点：
- 客体的 API 就是宿主的 API（ES 1.1 / 2.0），不需要固定管线模拟或着色器翻译；`gles-host.c` 里「ES 宿主」那套条件分支（`GLES_HOST_EAGL`）因为 ANGLE 工作在 10 月一直被维护着（ANGLE 版也定义 `GLES_HOST_EAGL`）。
- 不用打包任何库，App 体积小；有 IOSurface 颜色附件，避开逐帧 `glReadPixels`。
- UTM 的 iOS 版也有「EAGL backend」（[v5.0.3 发布说明](https://github.com/utmapp/UTM/releases)修过它开机黑屏），说明系统 OpenGLES 在 iOS 上还在被别的项目使用。它是不是经由 ANGLE 的 GL 后端，我没核实【推测】。

缺点：
- 苹果 iOS 12 起弃用，随时可能删（已经拖了 7 年）。
- `gles-host-eagl.c` 自 08-05 后没实质更新：**只建 ES 1.1 上下文**；iOS 4 以后 CoreAnimation 合成器要 ES 2.0 上下文，得照 ANGLE 的做法按 API 版本分别建上下文。
- 苹果规定「同一 sharegroup 里的所有上下文必须和第一个上下文同一 API 版本」（[OpenGL ES 编程指南](https://developer.apple.com/library/ios/documentation/3DDrawing/Conceptual/OpenGLES_ProgrammingGuide/WorkingwithOpenGLESContexts/WorkingwithOpenGLESContexts.html)）。ANGLE 接受混用，EAGL 不接受。客体当年跑在同样规则的真 iOS 上，大概率不会混用【推测】。
- 3.1.3 的 CoreAnimation 用 `GL_TEXTURE_RECTANGLE`，ES 里没有这个目标；ANGLE 版已经有一层「矩形纹理当 2D 纹理」的适配（`gles-host-angle.c.inc`），EAGL 要复用或重写。

### 4.3 ANGLE（Metal）路线

优点：
- 基于 Metal，不受 OpenGLES 弃用影响；上游 10-21 起已经能让 CoreAnimation 在 k48ap 7B500、n81ap 10B500、n90ap 11D257 上全程走 ANGLE 合成，零拒绝（[angle-evaluation.md](https://github.com/samhenrigold/qemu-ios/blob/main/docs/research/angle-evaluation.md)）。
- UTM 的 iOS 版就是用 ANGLE，有先例。

缺点：
- 要打包 ANGLE（6 个 dylib，约 11.6 MB；完整构建树约 8.7 GB），iOS 版要另外编；上游现在只在 Mac 上编过，而且是「CGL 旁边的实验性渲染器」，iOS 上没有 CGL 可以退回。
- n72ap 7E18（3.1.3）在 ANGLE 上还开不了机（矩形纹理问题，文档 10-21 节说已加适配，但没写复测结果）。

### 4.4 对「快照里保存 GL 状态」的影响：两条路一样难【已核实】

- 现状：只有 **CGL** 能存带 GL 的快照（[1c974f183c](https://github.com/samhenrigold/qemu-ios/commit/1c974f183c23)，`gles-host-snapshot.c.inc`）。它依赖「一个同时带固定管线和可编程管线的旧式桌面上下文」、`glGetTexImage`、`glGetTexLevelParameteriv`。
- EAGL：`gles_begin_context()` 在 `GLES_HOST_EAGL` 下一有活着的 GL 上下文就挂迁移阻塞：「Live OpenGL ES state cannot be saved (including accelerated system UI)」。ANGLE 同样挂着。blake-lucas 分支里安卓的 EGL 宿主也一样（[gles-host.c 第 612 行附近](https://github.com/blake-lucas/qemu-ios/blob/main/hw/arm/gles-host.c)）。**也就是说，目前没有任何人在 ES 宿主上做出带 GL 的快照。**
- ANGLE 文档列出的待办对 EAGL 同样适用：ES1 和 ES2 上下文要分别抓取和回放状态；ES 没有 `glGetTexImage`，彩色纹理可以绑 FBO 读回，alpha / luminance 纹理不能当颜色附件，要么保留上传时的副本，要么画进 RGBA 再读；ES 不接受把 RGBA 数据传进未定尺寸的 alpha/luminance 存储，回放也要改。EAGL 唯一可能的捷径是 4.1 说的私有 `glGetTexImage`，未验证。
- 退路：GL 桥拒绝时客体会退回软件 CoreAnimation 合成（stub 注释：「a guest probing the HLE simply falls back to its software renderer」；iPod touch 2G 一类还有 MBX2D 模型可以合成，上游在关掉 GL shim 时实测快照 107 MB、恢复 0.11 秒，见 [MBX 提交 103d076b09](https://github.com/samhenrigold/qemu-ios/commit/103d076b09c3)）。软件合成慢，但没有 GL 上下文就没有迁移阻塞。各版本是否都能顺利走软件合成，需要实测【推测】。
- 另外两个和快照相关、与图形无关的问题：
  - **一个进程只能起一次 QEMU**，所以「换版本」在 iOS 上等于「存快照 → 退出 → 新进程用 `-incoming` 恢复」。
  - 上游 Mac 版 10-22 实测：用 `-incoming` 在新进程里恢复后，画面在动、代理在响应，**但点按全部无效**（[LightTouchMac 3f39d80d](https://github.com/samhenrigold/LightTouchMac/commit/3f39d80d)，n72ap 3.1.3，「until it is fixed, checks keep cold boots」）。截至上游 10-23 的最后提交还没修。而同一进程内「存完继续跑」是好的。

### 4.5 建议

- M1 第一次开机**先不要宿主 GL**（用 stub 或让 GL 桥拒绝），走软件合成，把「能不能开机」和「GL 对不对」分开验证，也让快照可用。
- 接着上 EAGL，补 ES 2.0 上下文，复用 ANGLE 版的矩形纹理和按 API 选 OES 名字的适配。EAGL 比 ANGLE 少一个要在 iOS 上编、打包、维护的大依赖。
- 快照带 GL 是 M2 的独立工作包，EAGL 和 ANGLE 的工作量差不多，不应该因为快照选 ANGLE。
- ANGLE 作为 OpenGLES 被删时的后备，`gles-host.c` 已经能同时编两套，保持兼容即可。

---

## 5. 签名和资源

### 5.1 免费 Apple ID 和付费开发者账号

| | 免费 Apple ID（Personal Team） | 付费（99 美元/年） |
|---|---|---|
| 签名有效期 | 7 天，要重签（SideStore 可在手机上续签） | 1 年 |
| 同时装的 App 数 | 3 个（第三方资料广泛这么说，未在苹果文档核实）：SideStore + StikDebug + 我们的 App 正好占满 | 不受此限 |
| App ID | 同时最多 10 个，每个一周到期；App 扩展各占一个（[AltStore FAQ](https://faq.altstore.io/altstore-classic/app-ids)） | 不受此限 |
| `get-task-allow` | 有（开发签名） | 有（开发签名） |
| `increased-memory-limit` | Xcode 直接装和 AltStore Classic 2.2 起可以；**SideStore 用免费账号签会丢**（[SideStore #1616](https://github.com/SideStore/SideStore/issues/1616)，2026-09 起未修） | 可以 |
| `extended-virtual-addressing` | 不确定【推测】 | 可以；我们用不到 |
| JIT | 一样，都靠外部调试器 | 一样 |

对 M1 开发：用户用自己的账号在 Xcode 里直接装到手机就行，免费账号够用（每 7 天在 Xcode 里重跑一次）。对以后发布：每个用户用自己的账号签，账号类型由用户决定，App 要在免费账号、SideStore 丢 entitlement 的情况下也能跑。

### 5.2 单个 App 的内存上限够不够

- 已知数据点：iPhone 15 Pro Max（8 GB，iOS 27.0）默认约 3.3 GB，有 `increased-memory-limit` 约 6 GB（SideStore #1616 的实测）；12 GB 的 iPhone 16/17 Pro Max 有该 entitlement 时约 6144 MB（[苹果开发者论坛](https://developer.apple.com/forums/thread/834805)）；Inferno-iOS 自述「到 3 GiB 就被杀」【第三方说法】。iPhone 14 Pro（6 GB）没找到数字，估计默认 2.5 到 3 GB【推测】。
- iPhone 4 客体估算【推测】：客体内存 512 MB；TCG 代码缓冲默认 **1 GiB**（`DEFAULT_CODE_GEN_BUFFER_SIZE`，按用到的页计入）；GL 桥给客体 GL 对象的上限 512 MiB（`GLES_MAX_GPU_BYTES`，iOS 上是统一内存）；帧缓冲、快照缓冲、glib 等几百 MB。最坏情况接近 2 到 2.5 GB。
- 结论：iPhone 18 Pro 宽裕；iPhone 14 Pro 不加 entitlement 可能贴边。建议 iOS 上把 `tb-size` 设到 256 到 512 MB（Inferno 的数据说明 TB 太小会掉帧，blake-lucas 测到开机后代码缓存约 400 MB），加上 `increased-memory-limit`，M1 在两台机上用 `os_proc_available_memory()` 实测。TXM 下调试器要「准备」整块代码区，区越大准备越慢，这也是缩小 `tb-size` 的理由【推测】。

---

## 6. 有没有别人已经在做 iPhone 端

| 项目 | 是什么 | 和我们的关系 |
|---|---|---|
| [S5LBox](https://github.com/j0shua-SYSON/S5LBox)（MIT，60 星，v1.0 于 10-14 发布，v1.1 于 10-19） | **从零写的** S5L8900/ARMv6 全系统模拟器，在普通 iPhone 上跑 iPhone 3G 的 iPhone OS 3.1.3；纯解释器，不要任何特殊 entitlement；有 Legacy Store、Cydia、存档恢复 | 最接近的竞品，但只有一个机型一个版本；自述「not 30 fps」，前台交互常在 0 到 4 帧（[README-DETAILED](https://github.com/j0shua-SYSON/S5LBox/blob/main/docs/README-DETAILED.md)） |
| [pocketTouch](https://github.com/landonjsmith/pocketTouch) | 10-20 发了一个 441 MB 的闭源 IPA 和 AltStore 源，自称「Run iPhone OS 1 to iOS 3 on your iPhone」，是 Light Touch 的非官方移植，用 AltStore 的 Enable JIT；仓库里没有源代码 | 声称做了，但未核实能否运行（发布页显示下载 1 次）；作为 GPL 衍生品却不给源码 |
| [Inferno-iOS](https://github.com/MakrSas/Inferno-iOS)（GPL-3.0，155 星） | QEMU（ChefKiss Inferno）模拟 iPhone 11，在 iPhone 上跑 iOS 14，StikDebug legacy.js | 不同的版本段，但技术路线最像我们，可借鉴构建和 JIT 处理 |
| [Ios-emul](https://github.com/vytska69/Ios-emul) | QEMUAppleSilicon，iPhone 上跑 iOS 14；状态表里 iPod touch 1G/2G「qemu-ios 还不能编进 IPA，仅 macOS」 | 有 iOS 27.2 JIT 成功记录；作者考虑过 qemu-ios 但没做 |
| [blake-lucas/LightTouch](https://github.com/blake-lucas/LightTouch)（GPL-2.0，87 星） | qemu-ios 的安卓/Linux/Windows/macOS 版 | 没有 iOS；但它的性能文档和 EGL 宿主代码对我们很有价值 |
| [KD3533/qemu-ios-android](https://github.com/KD3533/qemu-ios-android) | Termux 下的安卓版 | 无关 |
| [heirofIsildur1/LightTouchMac](https://github.com/heirofIsildur1/LightTouchMac) | 简介写「LightTouchMac for iOS. I haven't done any work on this yet」，和上游完全一样 | 只是占位 |
| [c12n/nexttouch](https://github.com/c12n/nexttouch) | 11-01 新建的空仓库，简介说要做 iOS 8 到 10、含 iOS 平台 | 空 |
| Reddit / 社交媒体 | r/LegacyJailbreak、r/emulation 没搜到相关帖子（搜索引擎没收录到，可能有漏） | 未发现公开宣布 |

结论：**截至 2026-11-01，没有找到开源的、基于 qemu-ios、覆盖 iPhone OS 1 到 iOS 7、能在 iPhone 上跑的项目。** 「第一」的位置还空着，但 S5LBox 已经占了「在 iPhone 上跑 3.1.3」的叙事，pocketTouch 声称做过 1 到 3。上游作者明确不做 iOS 版。

---

## 7. 风险清单（按风险从高到低）

| # | 风险 | 可能性 | 影响 | 缓解 |
|---|---|---|---|---|
| 1 | **JIT 工具链在 iOS 27 上不稳定**：配对文件、LocalDevVPN、DDI、手动分配脚本、必须从 StikDebug 启动，任何一环出错就退回解释器；每次 iOS 更新可能再坏。27.0.1 上没有成功报告 | 中高 | 高：没有 JIT 只有一两帧，「能玩」做不到 | M1 开发先用 Xcode + LLDB；改用新协议；两台机都测；以后考虑内嵌 StikJIT；解释器版做 PGO 并始终能开机 |
| 2 | **快照秒切做不成**：ES 宿主带 GL 的快照无人实现；上游 `-incoming` 恢复后点按失效未修；一个进程只能起一次 QEMU，切版本要重启 App，在 StikDebug 下还要重新拿 JIT | 高 | 高（威胁核心卖点，M2） | M1 先在不开 GL 的情况下验证「存 → 退出 → 新进程恢复 → 能点」；把恢复后点不动的 bug 作为 M2 首个工作项；评估 ExtensionKit 扩展进程 |
| 3 | **QEMU 11 树在 iOS 上编不过或跑不稳**：8 月以后新增的大量代码从没为 iOS 编过；协程后端（sigaltstack 还是 libucontext）有分歧 | 中 | 中（耗时） | 先编 iOS 模拟器的解释器版快速迭代；改动集中成补丁 |
| 4 | **EAGL 被苹果删或行为异常**；`gles-host-eagl.c` 只支持 ES1，需要补 ES2 和矩形纹理 | 中低（短期） | 中 | 先无 GL 开机；保持 ANGLE 可编作后备 |
| 5 | **内存**：iPhone 14 Pro 默认上限未知，1 GiB 默认代码缓冲 + 512 MB 客体 + GL | 低中 | 中 | `tb-size` 256 到 512 MB；`increased-memory-limit`；实测 |
| 6 | **签名与分发体验**：免费账号 3 个 App 正好占满；SideStore 免费账号丢 `increased-memory-limit`；7 天重签 | 中 | 低（不挡技术验证） | 文档写清；以后内嵌 StikJIT 少占一个位置 |
| 7 | **许可证**：QEMU 整体是 GPL-2.0，带进来后整个 App 实际按 GPL-2.0 分发；StikDebug 是 AGPL-3.0，不能把它的代码编进来；StikJIT 是 MPL-2.0，按 MPL 的「次要许可」条款可与 GPL-2.0+ 组合 | 低 | 中 | 只通过 URL 调起 StikDebug，不链接它的代码；内嵌 StikJIT 前再核实【推测】 |
| 8 | **竞品抢先**：pocketTouch 若真能跑、或 S5LBox 扩展机型 | 低中 | 低（开源贡献不怕重叠） | 尽早发一个能开机的版本 |

---

## 8. M1 执行计划

### 8.1 先在哪台机上试：iPhone 18 Pro（iOS 27.2）

1. **iOS 27 上唯一公开的 QEMU 类 JIT 成功记录就在 27.2**（Ios-emul，iPhone 16e）；27.0.x 只有失败报告。先在成功概率高的系统上建立「能跑」的基线，再去 27.0.1 上排查，问题更好定位。
2. **它已经和这台 Mac 的 Xcode 配对过**：本机已有 `iPhone19,2 27.2` 的设备符号缓存（10-18 生成，6.7 GB），Xcode 直接运行和 LLDB 调试马上可用；本机没有 iPhone 14 Pro 的符号缓存，推测它还没连过这台 Mac 的 Xcode，第一次连要等 Xcode 拷约 6 到 7 GB 符号。
3. **12 GB 内存**，把内存上限从第一次开机的变量里排除。
4. **CPU 最快**，解释器版在它上面的表现就是「没有 JIT 时的最好情况」，如果连它都太慢，早点知道。
5. StikDebug 对 iPhone 18 Pro 的 DDI 问题已在 3.1.11 修好。

然后在 **iPhone 14 Pro（iOS 27.0.1）** 上复现同样步骤，作为低配基线（A16、6 GB）和第二个 iOS 小版本的 JIT 数据点。两台机的 JIT 机制完全相同，代码不需要分支。

例外：如果 iPhone 18 Pro 是用户的主力机，不想在上面开开发者模式、装 StikDebug 和 LocalDevVPN，就反过来先用 14 Pro，机制一样，只是要先接受 27.0.1 上 JIT 更可能出问题。

### 8.2 步骤

| 阶段 | 步骤 | 验收 | 估计 |
|---|---|---|---|
| A 准备 | A1 读 M0 报告：Mac 上 3GS 6.1.6 的 JIT / TCI 数据、快照大小；拿到 LTM 做好的设备目录和实际 QEMU 参数（参考 LTM 的 `BootRecipe.swift`） | 有一台在 Mac 上能开机的设备，和它的完整 argv | 0.5 天 |
| | A2 用户回答第 9 节问题（手机、账号、下载） | 有答复 | |
| B 依赖 | B1 以 LTM 的 `build-package-native.sh` 为模板、参考 UTM 的交叉编译参数，写 iOS arm64 依赖脚本，在 `work/` 下编：glib、pcre2、proxy-libintl、pixman、libslirp 4.9.4（两个补丁）、OpenSSL 静态库；FFmpeg 暂缓 | sysroot 和 pkg-config 文件齐全 | 1 到 2 天 |
| C 交叉编译 | C1 从 `af4d255637` 找回 `build-ios.sh` / `make-dylib.sh`，去掉 TCTI，适配 QEMU 11（`--disable-cocoa --disable-coreaudio --audio-drv-list= --disable-opengl --target-list=arm-softmmu` 等）；协程先试 sigaltstack | 编出 `libqemu-arm-interp.dylib` | 2 到 4 天 |
| | C2 编 iOS 模拟器的解释器版，在模拟器里跑通开机（快速迭代） | 模拟器里能看到客体画面 | 含在上面 |
| | C3 编 JIT 版 `libqemu-arm-jit.dylib` | 两个 dylib 都只依赖 iOS 有的框架（`otool -L` 检查） | 0.5 天 |
| D App 壳 | D1 最简 Xcode 工程：dlopen dylib，后台线程调 `qemu_ios_main`，帧画到 CALayer/Metal，触摸、Home、电源键、前后台接到现成 ABI | 能编、能装 | 2 到 3 天 |
| | D2 用 `xcrun devicectl device copy to` 把 Mac 上做好的设备拷进 App 的 Documents（照上游 `install-images.sh`），按 LTM 的规则拼 argv | 文件在手机上，参数正确 | 0.5 天 |
| | D3 第一次开机关掉宿主 GL，走软件合成 | | |
| E 首次开机（「第一」） | E1 iPhone 18 Pro 上用解释器版冷启动到锁屏：记录耗时、CPU、内存占用 | 看到锁屏 | 1 天 |
| | E2 JIT：Xcode 运行 + LLDB 停止钩子（把上游 `lldb_jit.py` 改成新协议，或保留 `0x69`） | 开机到主屏，记录与 E1 的对比 | 1 到 2 天 |
| | E3 JIT：`region.c` 改用新协议（参考 Ios-emul 0016 补丁），在 StikDebug 里手动指定 universal.js，脱离电脑启动 | 不连电脑开机到主屏 | 1 到 2 天 |
| | E4 在 iPhone 14 Pro 上重复 E1 到 E3 | 两台机的对比表 | 1 天 |
| F 摸底（M1 尾巴 / M2 开头） | F1 EAGL：给 `gles-host-eagl.c` 补 ES 2.0 上下文，验证 CoreAnimation 走 GL | 主屏用 GL 合成、无拒绝 | 3 到 5 天 |
| | F2 快照：无 GL 时「存 → 退出 → 新进程 `-incoming` 恢复」，看能不能点（复现上游 bug）；有 GL 时确认阻塞 | 记录结果 | 1 天 |
| | F3 内存和 `tb-size`：128 / 256 / 512 MB 对比，两台机 `os_proc_available_memory()` 实测 | 推荐默认值 | 1 天 |
| | F4 顺手探一下 iOS 私有 `glGetTexImage` 能不能读回纹理 | 能 / 不能 | 0.5 天 |

### 8.3 粗估工作量

- A 到 E（「第一」里程碑，两台机都开机到主屏）：约 **1.5 到 2.5 周**。
- 加上 F（GL 和快照摸底）：再加约 **1 周**。
- 上游 8 月的经验是：从写研究文档到在真机上跑出数据只用了约两天，所以构建这块风险可控；真正吃时间的是 iOS 27 上 JIT 工具链的调通和 GL/快照。【推测】

---

## 9. 需要用户回答的问题

1. **iPhone 18 Pro 是不是主力机？** 能不能在上面开开发者模式、导配对文件、装 StikDebug 和 LocalDevVPN？它现在是 27.2 正式版，还是 Xcode 缓存里那个 24B5110a（看起来像 beta）？
2. **签名账号**：M1 开发阶段用免费 Apple ID 在 Xcode 里直接装够用（7 天一签）。要不要现在就买付费开发者账号（99 美元/年）？不买也不挡 M1。
3. **下载许可**：
   - 编 iOS 依赖要下载 glib、pcre2、pixman、libslirp、OpenSSL（以后还有 FFmpeg）的源码包，合计约 100 到 200 MB，放 `work/`；
   - iPhone 14 Pro 第一次连 Xcode 会自动拷约 6 到 7 GB 设备符号；
   - 两台手机上装 StikDebug（GitHub 发布的 IPA）和 LocalDevVPN（App Store）。
4. **M1 第一次开机可以先不要 GL 加速吗？**（画面靠软件合成，会慢，但能把「能开机」和「GL 对不对」分开验证。）
5. **以后要不要把 StikJIT（MPL-2.0）内嵌进 App**，省掉用户单独装 StikDebug？这会多一个 App 扩展，免费账号下多占一个 App ID。现在不用决定，M2 前再定。
6. 对外沟通（以后）：要不要请 StikDebug 把我们的 App 名加进自动脚本分配表（需要给对方提 PR）？现在不用决定。

---

## 附：主要来源

上游（qemu-ios / LightTouchMac）
- dead-end 提交 [01ae922092](https://github.com/samhenrigold/qemu-ios/commit/01ae922092d37d029f42427f7aa50025fc6d2a9b)；iOS 移植提交 [49f0804cb7](https://github.com/samhenrigold/qemu-ios/commit/49f0804cb70a)、[d14b8cc839](https://github.com/samhenrigold/qemu-ios/commit/d14b8cc839a8)；研究文档提交 [20577fdbbb](https://github.com/samhenrigold/qemu-ios/commit/20577fdbbbd9)；v10.0.2 rebase [74e9ca7934](https://github.com/samhenrigold/qemu-ios/commit/74e9ca793442)；Mac dylib [7615017fe7](https://github.com/samhenrigold/qemu-ios/commit/7615017fe7fe)；QEMU 11 移植 [b18cd1606c](https://github.com/samhenrigold/qemu-ios/commit/b18cd1606c9c)；删 TCTI [74759924a1](https://github.com/samhenrigold/qemu-ios/commit/74759924a121)；删 iOS 脚本 [6a9aacff4b](https://github.com/samhenrigold/qemu-ios/commit/6a9aacff4b89)
- 删除前的 [contrib/ios-app](https://github.com/samhenrigold/qemu-ios/tree/af4d25563788929799725b626c3c2f644bbeb58b/contrib/ios-app)；删除前的 [TCTI README](https://github.com/samhenrigold/qemu-ios/blob/f1c24fbbca8faba53cba367a70ede87556a4b119/tcg/aarch64-tcti/README.md)
- [docs/research/ipod-touch-2g-on-iphone.md](https://github.com/samhenrigold/qemu-ios/blob/main/docs/research/ipod-touch-2g-on-iphone.md)、[docs/research/angle-evaluation.md](https://github.com/samhenrigold/qemu-ios/blob/main/docs/research/angle-evaluation.md)
- [tcg/region.c](https://github.com/samhenrigold/qemu-ios/blob/main/tcg/region.c)、[hw/arm/gles-host-eagl.c](https://github.com/samhenrigold/qemu-ios/blob/main/hw/arm/gles-host-eagl.c)、[hw/arm/gles-host.c](https://github.com/samhenrigold/qemu-ios/blob/main/hw/arm/gles-host.c)、[contrib/ios-app/qemu-ios-entry.c](https://github.com/samhenrigold/qemu-ios/blob/main/contrib/ios-app/qemu-ios-entry.c)、[meson.build](https://github.com/samhenrigold/qemu-ios/blob/main/meson.build)
- CGL 快照 [1c974f183c](https://github.com/samhenrigold/qemu-ios/commit/1c974f183c23)；恢复后点不动 [LightTouchMac 3f39d80d](https://github.com/samhenrigold/LightTouchMac/commit/3f39d80d)
- [LightTouchMac README](https://github.com/samhenrigold/LightTouchMac)、[dependencies.json](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/dependencies.json)、[build-package-native.sh](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/recipes/build-package-native.sh)、[BootRecipe.swift](https://github.com/samhenrigold/LightTouchMac/blob/main/Packages/HostRuntime/Sources/HostRuntime/BootRecipe.swift)

UTM
- [build_dependencies.sh](https://github.com/utmapp/UTM/blob/main/scripts/build_dependencies.sh)、[patches/sources](https://github.com/utmapp/UTM/blob/main/patches/sources)、[iOS.entitlements](https://github.com/utmapp/UTM/blob/main/Platform/iOS/iOS.entitlements)、[UTMJailbreak.m](https://github.com/utmapp/UTM/blob/main/Services/UTMJailbreak.m)、[PR #7908](https://github.com/utmapp/UTM/pull/7908)、[发布说明](https://github.com/utmapp/UTM/releases)、[iOS 安装文档](https://docs.getutm.app/installation/ios/)
- utmapp/qemu [region.c](https://github.com/utmapp/qemu/blob/utm-edition/tcg/region.c)、[TCTI 提交](https://github.com/utmapp/qemu/commits/utm-edition/tcg/aarch64-tcti)

JIT 工具
- StikDebug [发布说明](https://github.com/StikDebug/StikDebug/releases)、[README](https://github.com/StikDebug/StikDebug)、[ProcessInfo+TXM.swift](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/ProcessInfo%2BTXM.swift)、[AutoScriptAssignments.swift](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/AutoScriptAssignments.swift)、[universal.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/universal.js)、[legacy.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/legacy.js)
- StikDebug issues [#465](https://github.com/StikDebug/StikDebug/issues/465)、[#469](https://github.com/StikDebug/StikDebug/issues/469)、[#471](https://github.com/StikDebug/StikDebug/issues/471)、[#476](https://github.com/StikDebug/StikDebug/issues/476)、[#491](https://github.com/StikDebug/StikDebug/issues/491)
- [StikJIT INTEGRATION.md](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md)；[Husk #183](https://github.com/Leviidev/Husk/issues/183)
- [builds.io JIT 指南](https://builds.io/blog/technologies/ios-technologies/how-to-enable-jit-on-iphone/)

同类项目
- [S5LBox](https://github.com/j0shua-SYSON/S5LBox)、[pocketTouch](https://github.com/landonjsmith/pocketTouch)、[Inferno-iOS](https://github.com/MakrSas/Inferno-iOS)（[#5](https://github.com/MakrSas/Inferno-iOS/issues/5)、[#8](https://github.com/MakrSas/Inferno-iOS/issues/8)）、[Ios-emul](https://github.com/vytska69/Ios-emul)、[blake-lucas/LightTouch](https://github.com/blake-lucas/LightTouch)（[PERFORMANCE.md](https://github.com/blake-lucas/LightTouch/blob/main/docs/PERFORMANCE.md)）、[blake-lucas/qemu-ios](https://github.com/blake-lucas/qemu-ios)、[KD3533/qemu-ios-android](https://github.com/KD3533/qemu-ios-android)

签名、内存、图形、硬件
- [SideStore #1616](https://github.com/SideStore/SideStore/issues/1616)、[AltStore FAQ: App IDs](https://faq.altstore.io/altstore-classic/app-ids)、[AltStore Classic 发布说明](https://faq.altstore.io/release-notes/altstore)、[苹果开发者论坛 834805](https://developer.apple.com/forums/thread/834805)
- [苹果 OpenGL ES 编程指南：上下文与 sharegroup](https://developer.apple.com/library/ios/documentation/3DDrawing/Conceptual/OpenGLES_ProgrammingGuide/WorkingwithOpenGLESContexts/WorkingwithOpenGLESContexts.html)
- [iPhone 18 Pro（Wikipedia）](https://en.wikipedia.org/wiki/IPhone_18_Pro)、[MIE 第三方 App 启用方式（8ksec）](https://8ksec.io/mie-deep-dive-enabling-apps/)

本机
- `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk/System/Library/Frameworks/OpenGLES.framework/`
- `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone19,2 27.2 (24B5110a)/arm64e.x1/Symbols/System/Library/Frameworks/OpenGLES.framework/OpenGLES`
