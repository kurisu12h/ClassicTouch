# A5（iPod touch 5，n78）接进 iPhone App

- 日期：2026-11-04
- 执行会话：a5-nand（接着 `docs/reports/a5-step1.md` 3.17 节做）。范围：把 a5-n78 补丁叠到 iOS 交叉编译用的 qemu-ios 上，编 iOS 模拟器版；App 里加 n78 的开机方式；做 n78 的 `.ctpack`；在 iOS 模拟器的 App 里把 9.3.5 和 7.1.2 开到锁屏（最好到主屏、「设置」）。
- 不做的：不碰真机，不下载设备符号，不签名，不用 Apple ID；不提交、不推送。

## 0. 结论

1. **iPod touch 5 代的 9.3.5 和 7.1.2 都在 iOS 模拟器的 App 里开到了锁屏、主屏，并打开了「设置」。** 模拟器是 iPhone 18 Pro（iOS 27.2），App 用 JIT、代码区 256 MB，设备从 `.ctpack` 导入；所有点按都由 App 自己完成（`control/unlock`、`control/tap`），没用模拟器的点屏工具。【已核实：第 6 节的运行目录和截图】

   | 系统 | 锁屏 | 主屏 | 「设置」 | 主屏静止 CPU | 最大占用 |
   |---|---:|---:|---:|---:|---:|
   | iOS 9.3.5（13G36） | 66 到 104 秒（四次） | 84 秒（`sim-boot.sh`） | 138 秒 | 96%（一个核） | 1132 MB |
   | iOS 7.1.2（11D257） | 37 秒（两次） | 45、46 秒 | 65 秒 | 43% | 1029 MB |

2. **接进 App 用到的东西：** a5-n78 补丁叠在四个 iOS 补丁之上没有冲突；新补丁 `a5-n78-ios-ui.patch` 让 App 的按键、熄屏判断认得 n78；`build-qemu.sh` 会一起打这两个补丁；App 新增 `n78` 开机方式（USB 根盘加 IOP 的 NAND 目录），年表里 2013 年和 2015 年都能选出 iPod touch 5 代。
3. **两个 `.ctpack`：** 9.3.5 2.6 GB、7.1.2 2.9 GB，App 导入各约 4 秒。NAND 真正有数据的只有 8 MB，包里也只占这么多，不用缩；体积几乎全是系统卷。
4. **下载：** 只下了批准的 8 个依赖源码包（67 MB，sha256 全部对上）；pip 只装了 qemu.qmp 和 setuptools，日志里没有从网上下载的记录。
5. **问题：**
   - **触摸纵向偏上约 100 像素**（3.16 节的老问题）在 App 里也有：App 自己的「打开设置」测试（`-opensettings`）就是因此点空的。试着改机型的 `frame_y0` 去修，结果触摸整个失效，原因没查清，已还原（2.1 节）。
   - **主屏偶尔弹「Trust This Computer?」**（模态，挡住点按）；用户点按钮中间会因为上面的偏差落在按钮上方，要点偏下的位置才行。
   - 9.3.5 主屏静止要占一个核，7.1.2 不到一半。
   - Mac 上做 9.3.5 本体时出过一次「compressed PTE … corrupted?」的内核 panic，重做就好了，原因没查（第 3 节）。
6. **装真机还差什么**见第 7 节，几件事要用户定：用哪台手机、用哪个 Apple ID 签名、要不要下设备符号。

## 1. 叠补丁

**这台 Mac 上没有 iOS 交叉编译的现场。** `work/ios/` 整个不在：依赖源码包、`sysroot-iphonesimulator-arm64`、iOS 用的 qemu-ios 工作树、App 的 DerivedData、M1/M2 的设备和包都没有，`work/` 下只剩 A5、Mac 版构建和固件。iOS 模拟器运行时（iOS 27.2）和三台 iPhone 18 Pro 模拟器还在，`meson`、`ninja`、`xcodegen` 在。【已核实：`ls work/`、`xcrun simctl list`】

**iOS 工作树：** 从本地的 `upstream/qemu-ios`（b225694505，和 A5 工作树同一个提交）`git clone --shared` 到 `work/ios/qemu-ios`，没有联网。

**冲突检查：**

- `ios-gles-perf.patch` 单独检查失败，是因为它依赖 `ios-eagl-es2.patch`（同改 `hw/arm/gles-host.c`）；按 `build-qemu.sh` 的顺序（文件名顺序）依次打，四个都打上了。【已核实】
- a5-n78 补丁（11 个文件，含 3.17 节 GL 前端的 9.x 补充）在四个 iOS 补丁之上能直接打上。两边都改的只有 `hw/arm/s5l8930_display.c`（iOS 的 gles-perf 改读回时机，A5 加 H4P 管线），改的地方不重叠。【已核实：`git apply` 无冲突】
- 语义上要补的一处：App 桥（`contrib/ios-app/qemu-ios-ui.c`）的按键不走 QEMU 键盘，而是挨个调各机型的 `*_press_button()`，n78 原来只接了键盘（H、L 等）。补了：
  - `hw/arm/ipod_touch_5g.c` 加 `ipod_touch_5g_press_button()`（Home、电源、音量加减 → GPIO 0 到 3，低有效），声明放进 `include/hw/arm/ipod_touch_buttons.h`。进了 a5-n78 补丁，Mac 版 A5 构建编过。【已核实】
  - 新补丁 `patches/a5-n78-ios-ui.patch`（只改 `qemu-ios-ui.c`）：`ios_press` 里调它；n78 的面板经 MIPI-DSI 供电，加进 `ios_dsi_panel` 的判断（`display_sleeping` 才认得熄屏）；机型表加一行 `iPod-Touch-5G n78ap 640×1136`。
  - 触摸不用改：App 桥走旧式绝对坐标指针（`qemu_input_queue_abs` 加左键），n78 的 `n78_mouse_event` 就是接这条路的（Mac 上 qinput 经 QMP 也走它）。
- `scripts/ios/build-qemu.sh` 的补丁清单从 `patches/ios-*.patch` 改成「`ios-*.patch` 加 `a5-n78-skeleton.patch` 加 `a5-n78-ios-ui.patch`」，按这个顺序打，判断「已打好、原样、都不是」的逻辑不变。照它的逻辑在临时目录里把全套补丁打到上游原样上，和工作树逐个比，21 个文件全部一致。【已核实】

## 2. App 里加 n78

- **`DeviceProfile.swift`：** 机型表加 `n78ap`（`iPod-Touch-5G`，640×1136，没有基带；USB 主机口上挂的是根盘，不挂 usb-kbd，所以 `hasUSBHost` 记 false），列表名「iPod touch（第 5 代）」。新开机方式 `n78`（lock 的 `boot_strategy`）：
  - 本体：`device.lock.json`、`kboot.bin`、`disk.img`（两分区 USB 盘）、`nand/`（`ce0.pages`、`ce0.boot`）；
  - 第一次启动把 `disk.img` 和 `nand/` 各克隆进 `state/`（先放暂存名再改名，APFS 上是克隆、稀疏文件不展开），之后 QEMU 就地写；
  - 参数照 `tools/a5/n78_run.sh`：`-M iPod-Touch-5G,kboot=<本体>/kboot.bin`，`-drive if=none,id=root,file=<state>/disk.img,format=raw -device usb-storage,bus=ehci.0,drive=root`，`-global driver=s5l8940.iop,property=nand,value=<state>/nand`；不加 `-netdev`（n78 没有网卡），内存用机型默认的 512 MB。
- **`Theme.swift`：** 年表能开的版本从 `1...7` 改成 `[1…7, 9]`（iOS 9 记 2015），n78 的机身线稿用 `.flat`（直边、有前摄像头）。7.1.2 的 n78 和 iPhone 4 的 7.1.2 同在 2013 一格里。
- **按键：** App 的 Home、电源、音量键经 `qemu_ios_ui_button` → `ios_press` → `ipod_touch_5g_press_button`（第 1 节）。

### 2.1 触摸纵向偏差：试了，没修成

3.16 节留下的问题是点按落点比瞄准点偏上约 100 像素，App 里用户点屏幕也会这样，所以试着在机型里修。

- 已知点：瞄 785 落在约 685（「Don't Trust」按钮，645 到 725），瞄 930 落在约 830（「设置」图标，770 到 880），t2 里瞄 810 关掉了同一个按钮、瞄 1080 点开了 Dock 的「邮件」（图标从约 975 起）。都和「整体偏上约 100 像素」一致，按现参数推出的比例（0.1304 像素一个传感器单位）也和 1136/8709 吻合，所以只改原点：`frame_y0` 从 -254 挪到 -1021。【推测】
- 结果：t1、t3 两次开机（`work/a5/runs/s317/t1`、`t3`），触摸整个不起作用，连屏幕中部的横滑都解不了锁；同一块盘的克隆用 -254（t2）照常能点。`frame_y0` 在多点触控模型里只用来算每个触点的坐标（`ipod_touch_multitouch.c` 905 行），中部那一下换算出来是正常的正数，为什么会整个失效没查清。【已核实：现象；原因不明】
- 处理：参数还原成 -254，App 先带着这个偏差；在模拟器里点按时照 Mac 的做法往下多瞄约 100 像素。根治要看客体的触摸换算（mtprops 里的传感器区域参数），留作后续。

## 3. n78 的 `.ctpack`

**设备目录**（`work/ios/devices/<id>/`，打包前用 `cp -c` 克隆）：`device.lock.json`（`board n78ap`、`boot_strategy n78`、版本和构建号，`machine` 为空）、`kboot.bin`（`work/a5/kboot/n78-<构建号>-fmi.bin`，带默认隐藏的缩放器）、`disk.img`、`nand/`。盘和 NAND 都是「格式化开机、跑过 `n78_diskfix.sh`、再开过一次到锁屏」的状态，这样用户第一次开机就不用再等 9.3.5 约 100 秒的数据迁移。

- 7.1.2：`n78ap-11D257`，盘和 NAND 取 a5-step1 3.17.4 的 7.1.2 回归那一份（`nandfmt/disk-712-r.img`、`nand-712-r`）。
- 9.3.5：`n78ap-13G36`，`nandfmt/disk-935-formatted.img` 的克隆跑 diskfix 后开一次（`work/a5/runs/app/gold935b`：150 秒迁移，263 秒按 Home 是锁屏，没有 panic），盘 `disk-935-gold2.img`、NAND `nand-935-gold2`。

**体积：NAND 不用缩。** 两个 NAND 文件名义 4.4 GB、实际占 2.3 GB，但非零数据只有 8 MB（`ce0.pages` 7 MB、`ce0.boot` 1 MB），其余都是写进去的全零块：页存储按位取反存，擦除态（0xff）写下去就是 0。`pack-device.py` 本来就跳过全零的 64 KiB 块，App 解包时也只写有数据的区段，所以包里和手机上的 NAND 都只有约 8 MB。3.13.6 第 2 条说的引导页白占 1.3 GB，只是 Mac 上这份文件分配了全零块，不影响包和手机。【已核实：用 `pack-device.py` 的 `extents()` 统计 `nand-935-formatted`】引导页号带 SLC 位、落在文件 0.8 GB 往后的问题仍在，要改得重新格式化，这次没动。

| 包 | 数据 | 包大小 | 打包用时 |
|---|---:|---:|---:|
| `work/ios/packs/n78ap-11D257.ctpack` | 2785 MB | 2.9 GB | 2.5 秒 |
| `work/ios/packs/n78ap-13G36.ctpack` | 2449 MB | 2.6 GB | 2.8 秒 |

盘占了几乎全部：系统卷是 IPSW 的 rootfs 原样（7.1.2 约 1.8 GB，9.3.5 约 2 GB），加数据卷。

**9.3.5 本体第一次没做成（`work/a5/runs/app/gold935`）：** 格式化好的盘跑 diskfix 后第一次开机，150 秒数据迁移进度条、200 秒灰色苹果标志，约 220 秒内核 panic：`compressed PTE 0xc0c53ecc 0xfff8f8f8 has extra bits 0xfff8f878: corrupted?`。内存压缩器发现一个页表项被写成 0xfff8f8f8，按字节看是一个近白的 BGRA 像素，像是宿主把画面数据写进了客体已经回收、又被拿去当页表的内存（GL 的读回或 IOSurface 写回用了过期的地址）。以前十几次开机没见过。【已核实：现象，`gold935/serial.log` 658 行；原因是推测】换一块新克隆重做。

## 4. 编 App（模拟器版）

- 没有 dylib 时先编过一次：64 个 Swift 编译步骤全部通过，没有错误和警告，只有最后的 `embed-qemu.sh` 报「没有编好的 qemu-ios dylib」。
- dylib 编好后：`xcodebuild -project app/ClassicTouch.xcodeproj -scheme ClassicTouch -sdk iphonesimulator -configuration Debug -derivedDataPath work/ios/DerivedData-a5 -destination id=<模拟器> build`，「嵌入了 1 个 qemu-ios dylib（iphonesimulator）」，BUILD SUCCEEDED。【已核实：`work/ios/xcodebuild-a5.log`】只编了 JIT 版 dylib；解释器版在模拟器里用不上，没编。
- 测试入口加了一个控制命令 `tap`（`EmulatorViewController.pollControl`）：往 `Documents/control/tap` 写「x,y」（客体屏幕的归一化坐标，左上为原点），App 在那里按 0.3 秒。新脚本 `scripts/ios/sim-settings.sh` 用它在模拟器里解锁、关掉配对提示、点开「设置」。

## 5. iOS 模拟器版：依赖和 QEMU

- **下载：** `scripts/ios/fetch-sources.sh` 从表里的官方地址下了 8 个包，逐个核对 sha256 全部通过，合计 67 MB（openssl 一个 52 MB，比我问的时候估的 30 MB 多）。【已核实：`work/ios/src/`】
- **依赖 sysroot：** `scripts/ios/build-deps.sh iphonesimulator` 59 秒编完 7 个静态库（libffi、pcre2、proxy-libintl、glib、pixman、slirp、openssl、nettle），装进 `work/ios/sysroot-iphonesimulator-arm64`，`minos 16.0`、`platform IOSSIMULATOR`。【已核实：`work/ios/build-deps-sim.log`】
- **meson 子项目：** iOS 工作树是 `git clone --shared` 出来的，没有子项目源码；照 `build-qemu.sh` 开头的说明，从本地 `upstream/qemu-ios/subprojects/` 用 `cp -c` 复制了 berkeley-softfloat-3、berkeley-testfloat-3、dtc、keycodemapdb，meson 不用再联网。
- **模拟器：** 新建「ClassicTouch iPhone 18 Pro」（iPhone 18 Pro，iOS 27.2，运行时本机已有），UDID 记在 `work/ios/sim-udid`。OCR 工具从 `tools/m0/ocr.swift` 本地重编到 `work/tools/ocr/ocr`（`sim-boot.sh` 要用）。9.3.5 锁屏的「slide to unlock」带流光，OCR 读成「crae to unlotk」，`sim-boot.sh` 的锁屏判断放宽为也认「to unl」。

- **iOS 版 QEMU：** `TCG=jit scripts/ios/build-qemu.sh iphonesimulator` 36 秒编完（工作树已打好全套补丁，脚本判定「已打好」）；configure 的 mkvenv 用 QEMU 自带的轮子装了 meson、pycotap，又装了 qemu.qmp 0.0.5、setuptools，日志里没有 Downloading。`TCG=jit scripts/ios/make-dylib.sh iphonesimulator` 得到 `libqemu-arm-jit.dylib`（36 MB，导出 58 个 `qemu_ios_*`），里面有 `iPod-Touch-5G` 机型。【已核实：`work/ios/build-qemu-sim-jit.log`、`make-dylib-sim-jit.log`】

## 6. iOS 模拟器里的 App

模拟器「ClassicTouch iPhone 18 Pro」，App 是第 4 节那份。两个包放进 App 的 `Documents/import/`，不带参数打开 App，首页导入：9.3.5 解包 4.1 秒、7.1.2 4.3 秒，年表里 2013 一格是「iPod touch（第 5 代）· iOS 7.1.2 · 11D257 · 2.98 GB」，2015 一格是「iPod touch（第 5 代）· iOS 9.3.5 · 13G36 · 2.61 GB」，2014（iOS 8）和 2016（iOS 10）标「以后」。【已核实：`logs/import.log`、`img/a5-app-library.png`】

![App 首页](img/a5-app-library.png)

GL：App 里走 EAGL 后端，前端握手协议 1，`host GL up: OpenGL ES 3.0 APPLE-24.0.2 / Apple Software Renderer`（模拟器的 GLES 是软件渲染，比真机的 GPU 慢）。

每次运行（运行目录都拷到了 `work/ios/runs/<名字>/`，含 `events.log`、`stats.csv`、客体和窗口截图；时间从 App 调 `qemu_ios_main` 起算）：

| 运行 | 系统 | 做法 | 锁屏 | 主屏 | 「设置」 | 备注 |
|---|---|---|---:|---:|---:|---|
| `20261104-032344-n78ap-13G36-jit` | 9.3.5 | `sim-boot.sh` | 73 | 84 | | 主屏静止 96%（16 秒），占用 1132 MB |
| `20261104-032558-n78ap-13G36-jit` | 9.3.5 | `-autodrive -opensettings` | 104.6 | 114.6 | 没成 | App 认出「Settings」标签，在它上方点三次，加上触摸偏差点在两排图标之间，5 分钟后超时 |
| `20261104-033342-n78ap-13G36-jit` | 9.3.5 | `sim-settings.sh` 第一版 | 85 | 94 | 没成 | 主屏弹着「Trust This Computer?」，点「设置」被挡 |
| `20261104-034101-n78ap-13G36-jit` | 9.3.5 | `sim-settings.sh` | 66 | 116 | 138 | 解锁试了三次（67、87、108 秒）；117 秒点掉配对提示，133 秒点「设置」 |
| `20261104-033121-n78ap-11D257-jit` | 7.1.2 | `sim-boot.sh` | 37 | 45 | | 主屏静止 43%（16 秒），最大占用 1029 MB |
| `20261104-034354-n78ap-11D257-jit` | 7.1.2 | `sim-settings.sh` | 37 | 46 | 65 | 点一次就进了 |

锁屏时间是 OCR 第一次认出「slide to unlock」的那张客体画面的秒数；9.3.5 锁屏出来约 20 秒后会熄屏，熄屏后的解锁要先按 Home，所以主屏时间和锁屏时间之间的差不全是开机本身。四次 9.3.5 的锁屏在 66 到 104 秒之间，差别大，没细查（第二次是 autodrive，认锁屏的方法不同）。【已核实：各运行的 `events.log`】

| 9.3.5 锁屏 | 9.3.5 主屏 | 9.3.5「设置」 |
|---|---|---|
| ![](img/a5-app-935-lockscreen.png) | ![](img/a5-app-935-home.png) | ![](img/a5-app-935-settings.png) |

| 7.1.2 锁屏 | 7.1.2 主屏 | 7.1.2「设置」 |
|---|---|---|
| ![](img/a5-app-712-lockscreen.png) | ![](img/a5-app-712-home.png) | ![](img/a5-app-712-settings.png) |

App 运行画面（「年表」外观，顶上「2015 · iPod touch（第 5 代）· iOS 9.3.5 · JIT」）：

![](img/a5-app-935-window.png)

最后：App 已终止，模拟器已关机，Mac 上没有 QEMU 进程。

## 7. 装真机还差什么

**要用户定的：**

1. **用哪台手机。**
   - iPhone 18 Pro（iOS 27.2）：M1、M2 已在上面用 StikDebug 的 JIT 开过 iOS 3、6、7，StikDebug、配对文件、App 签名都是现成的。【已核实：M1、M2 报告】
   - iPhone 14 Pro（iOS 27.0.1，用户指定的测试机）：StikDebug 在 iOS 27.0.1 上给 JIT 还没有成功的报告；第一次连 Xcode 要下约 6 到 7 GB 设备符号（要批准）；StikDebug 和 App 都要重装、重新生成配对文件。没有 JIT 只能用解释器，iOS 7 在解释器下已经基本不能用（M1 第四步），9.3.5 更重，所以 JIT 是前提。【推测】
2. **签名用的 Apple ID**（现在用的是付费个人团队，团队 ID 不进仓库）。

**我们这边要做的（大约半小时，不含等用户）：**

1. 真机版依赖和 QEMU：`scripts/ios/build-deps.sh iphoneos`，`TCG=jit` 和 `TCG=interp` 各跑一遍 `build-qemu.sh iphoneos`、`make-dylib.sh iphoneos`（源码包已经下好，不用再下载）。
2. 真机版 App：照 `device-install.sh` 的 `APP` 默认路径编 Debug-iphoneos，用上面定的团队签名。
3. 拷包：`scripts/ios/device-install.sh work/ios/packs/n78ap-13G36.ctpack work/ios/packs/n78ap-11D257.ctpack`（经 USB 的 AFC 传进 App 的 `Documents/import/`，App 自己导入，再每台用 StikDebug 开一次计时）。两个包 5.5 GB，按 M2 实测 AFC 约 34 MB/s，传完约 3 分钟；也可以用 Finder 的文件共享或「文件」拷。【推测：速度按 M2 的 473 MB 用 14 秒推算】
4. 手机空间：包 5.5 GB，解开后 2.4 GB 加 2.8 GB，包解完就删；`device-install.sh` 要求剩余空间至少是包的总大小加 2 GB。之后客体每写一块，`state/` 里的克隆就多占一块。
5. 内存：模拟器里 9.3.5 最大占用 1132 MB（客体 512 MB、代码区 256 MB、GL 等），iPhone 14 Pro 和 18 Pro 都是 6 GB 以上，App 的上限通常在 3 GB 左右，应当够。【推测】

**最好在给用户试之前修的：** 触摸纵向偏差（不然点按钮都要往下点）；主屏偶发的配对提示（考虑预置配对记录或用描述文件禁止配对）；9.3.5 主屏静止占一个核（真机上费电、发热）。

