# 把 App 装进 iPhone 14 Pro

**最新结论（第 7 节）：** App 装上了、能打开，两个包传进去并导入了。连线 lldb 给 JIT：默认开包日志之后，5 次挂载都是第一下成功；不开时 9 次全部失败，根因没查清。5 次都到了锁屏（9.3.5 128 到 133 秒，7.1.2 78 到 80 秒），但只有 1 次进了主屏，卡在 App 自己的滑动解锁上。7.1.2 锁屏上的「Cannot Use Device」查清是 DeviceOMatic 发的，已经禁掉。App 在包没传完时就去解的问题也修了。第 0 到 6 节是之前的记录。

- 日期：2026-11-04
- 执行会话：a5-nand。用户原话（决策会话转述）：「现在把app装进iPhone 14 pro」。
- 手机：iPhone 14 Pro（iPhone15,2，iOS 27.0.1，24A446），数据线连着，devicectl 显示已配对。签名用 Mac 上唯一的 Apple Development 证书（用户自己的付费团队）；把这台手机登记进团队是用户这句话要求的。
- 不做的：不提交、不推送；不碰 iPhone 18 Pro；不改手机设置；UDID、团队 ID、配对文件不进仓库。

## 0. 结论

1. **能先做的都编好了**，都用现在这套补丁（四个 iOS 补丁、`a5-n78-skeleton.patch` 18 个文件、`a5-n78-ios-ui.patch`）：
   - 真机依赖 sysroot（`work/ios/sysroot-iphoneos-arm64`，7 个静态库）；
   - 真机版 QEMU 和 dylib，JIT、解释器各一份：`libqemu-arm-jit.dylib`（35.9 MB）、`libqemu-arm-interp.dylib`（35.9 MB），各导出 58 个 `qemu_ios_*`，平台 iOS、最低 16.0；
   - Debug-iphoneos 的 App（`work/ios/DerivedData-tl/Build/Products/Debug-iphoneos/ClassicTouch.app`，就是 `device-install.sh` 默认找的路径），两份 dylib 都嵌进去了，签名校验通过；
   - 模拟器版 QEMU、dylib、App 也按新补丁重编了。
2. **模拟器里两个包都正常，黄金状态不用重做**：9.3.5 103 秒锁屏、113 秒主屏；7.1.2 41 秒锁屏、49 秒主屏（上一轮 66 到 104 秒、37 秒）。新 QEMU 和包里盘上的旧前端握手正常（协议 1，名表 ad3b3412，认出 329 槽）。【已核实：两次 `sim-boot.sh` 的摘要和 QEMU 日志】
3. **卡在签名上，要用户在 Mac 上做一件事（开发者模式打开后重试仍如此，见第 5 节）**：Xcode 里**没有登录任何 Apple 账号**（`xcodebuild` 报 `No Accounts`），所以不能自动把 14 Pro 登记进团队、也不能生成新的描述文件。本机缓存的「iOS Team Provisioning Profile: *」（到 2027-10-18）里登记了 4 台设备，**没有 14 Pro**，用它签的 App 装不进这台手机。需要用户在 Xcode → 设置 → 帐户里登录这个付费团队的 Apple ID，之后我重跑一次带 `-allowProvisioningDeviceRegistration` 的构建，Xcode 会登记手机、重做描述文件。【已核实：`work/ios/xcodebuild-os-14pro.log`；描述文件逐项核对】
4. **装好之后还要先问的**：这台 Mac 的 `work/ios/` 下**没有 StikDebug 的源码和构建、没有 `idevice-tools`、没有配对文件**（M1 当时放在 `work/ios/stikdebug/`、`work/ios/tools/idevice-tools-0.1.68/`、`work/ios/secrets/`，现在都不在）。`device-install.sh` 和 `device-boot.sh` 的传包、取日志都走 `idevice-tools` 的 AFC。手机上有没有 StikDebug，要等开发者模式打开才看得到。
5. 开发者模式：决策会话已让用户去开，我没有碰手机设置。

## 1. iOS 工作树换补丁

- `work/ios/qemu-ios` 还是上一轮（a5-app）的旧补丁。`build-qemu.sh` 只认「上游原样」或「打完现在这套补丁」两种状态，所以先把它改过的 21 个文件打包备份到 `work/ios/qemu-ios-oldpatches.tar`，再还原成上游原样（`git checkout` 加删掉补丁新建的 7 个文件），交给 `build-qemu.sh`。
- 第一次构建（模拟器 JIT）按顺序打上了 `ios-eagl-es2`、`ios-gles-perf`、`ios-host-gles-option`、`ios-txm-jit-protocol`、`a5-n78-skeleton`、`a5-n78-ios-ui` 六个补丁，之后的构建都判定「已打好」。【已核实：`work/ios/build-qemu-sim-jit-a6.log`】

## 2. 编了什么

| 东西 | 命令 | 结果 | 日志 |
|---|---|---|---|
| 模拟器版 QEMU（JIT） | `TCG=jit scripts/ios/build-qemu.sh iphonesimulator` | 编好 | `work/ios/build-qemu-sim-jit-a6.log` |
| 模拟器版 dylib | `TCG=jit scripts/ios/make-dylib.sh iphonesimulator` | 36 MB，58 个导出 | `make-dylib-sim-jit-a6.log` |
| 模拟器版 App | `xcodebuild … -sdk iphonesimulator -derivedDataPath work/ios/DerivedData-a5` | BUILD SUCCEEDED，嵌入 1 个 dylib | `xcodebuild-sim-a6.log` |
| 真机依赖 | `scripts/ios/build-deps.sh iphoneos` | 7 个库 | `build-deps-os.log` |
| 真机版 QEMU（JIT、解释器） | `TCG=jit` 和 `TCG=interp` 各跑 `build-qemu.sh iphoneos` | 都编好 | `build-qemu-os-jit.log`、`build-qemu-os-interp.log` |
| 真机版 dylib | `TCG=jit` 和 `TCG=interp` 各跑 `make-dylib.sh iphoneos` | 各 35.9 MB，58 个导出 | `make-dylib-os-*.log` |
| 真机版 App（目标 14 Pro） | `xcodebuild … -destination id=<14 Pro> -allowProvisioningUpdates -allowProvisioningDeviceRegistration` | **失败**：`No Accounts`；描述文件不含这台手机 | `xcodebuild-os-14pro.log` |
| 真机版 App（通用） | `xcodebuild … -destination generic/platform=iOS` | BUILD SUCCEEDED，嵌入 2 个 dylib，用本机现有的通配描述文件签名 | `xcodebuild-os-generic.log` |

- 编译源码包是上一轮下好的，这一轮没有下载任何东西。
- 构建日志里有团队 ID 和手机 UDID，都在 `work/`，不进仓库。14 Pro 的 UDID 存在 `work/ios/phone14-udid`（600，git 忽略）；这台 Mac 上本来没有 `work/ios/phone-udid`，没有动它。

## 3. 模拟器验证

模拟器「ClassicTouch iPhone 18 Pro」（iOS 27.2），装新 App，用容器里上一轮从包导入的两台设备，`sim-boot.sh` 每次从设备本体（也就是包里的盘和 NAND）冷启动。9.3.5 那次真机版 QEMU 同时在编，CPU 被占了一部分。

| 运行 | 系统 | 锁屏 | 主屏 | 主屏静止 CPU | 最大占用 |
|---|---|---:|---:|---:|---:|
| `20261104-205533-n78ap-13G36-jit` | 9.3.5 | 103 秒 | 113 秒 | 107% | 1143 MB |
| `20261104-205806-n78ap-11D257-jit` | 7.1.2 | 41 秒 | 49 秒 | 47% | 1029 MB |

- 两次都正常退出（`qemu_exit status=0`），运行目录拷回了 `work/ios/runs/`。
- 包里盘上的 GL 前端是上一轮编的（没有这一轮的 TLS 槽和宏上下文前多留的 4 个字）。新 QEMU 和它握手正常：`protocol 1, name table ad3b3412 (host: 1, ad3b3412)`、`1035 slots, 329 named`。所以包不用重做。这两处前端改动只在 iOS 10（Darwin 16）上起作用，对 9.3.5 和 7.1.2 本来就影响很小。【已核实：9.3.5 运行目录里的 QEMU 日志】
- 模拟器已关机。

## 4. 等用户之后的步骤

1. **用户在 Xcode 登录团队的 Apple ID**（Xcode → 设置 → 帐户），手机打开开发者模式（打开后手机会重启，要在手机上确认）。
2. 我重跑真机版构建（目标 14 Pro，`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`），核对新描述文件里有这台手机。
3. 装 App：`PHONE=$(cat work/ios/phone14-udid) SKIP_UPLOAD=1 SKIP_BOOT=1 scripts/ios/device-install.sh`，或直接 `xcrun devicectl device install app`。第一次打开开发版 App，手机上可能要在「设置 → 通用 → VPN 与设备管理」里信任开发者。
4. 查 StikDebug：手机上有没有装、版本多少。没有就要重新下源码（GitHub 上 StikDebug 3.2.0，外加 SPM 拉的 CodeEditorView、Rearrange）重编重签。
5. 传包要先有 `idevice-tools`（M1 用的是 idevice 官方发布页的 `idevice-tools-macos-arm-v0.1.68.zip`，约 5 MB）。也可以不下载，改用 `devicectl device copy to` 传进 App 容器（两个包合计 5.5 GB），但 M1 记过开着 LocalDevVPN 时 devicectl 的文件服务会卡死，脚本也要改。
6. 生成 StikDebug 要的 RemotePairing 配对文件（经 USB，`idevice-tools remotepairing_lockdown pair`），放 `work/ios/secrets/`。
7. 查手机剩余空间（两个包 5.5 GB，加 2 GB 解包余量），传 9.3.5 和 7.1.2 两个包，`STIK=1 device-boot.sh` 各开一次计时。

第 1 步要用户做；第 4 到 6 步涉及下载和配对文件，按决策会话的要求先问。

## 5. 开发者模式打开之后（同一天，第二次）

决策会话转告：用户已打开 14 Pro 的开发者模式（devicectl 显示 `Developer Mode Status: Enabled`）；手机上没有 StikDebug、没有 ClassicTouch，有 App Store 版 LocalDevVPN 1.3.0。用户定的是「先连线测，以后再说」：只走 Mac 上 lldb 给 JIT，不装 StikDebug、不碰配对文件。

- **还是装不上。** 指向 14 Pro 的构建重跑一次，仍报 `No Accounts` 和「描述文件不含这台手机」（`work/ios/xcodebuild-os-14pro-2.log`）。用通用版（本机现有的通配描述文件签名）试装，手机拒绝：`Failed to install embedded profile … 0xe8008012 (This provisioning profile cannot be installed on this device.)`，`ApplicationVerificationFailed`（`work/ios/devicectl-install-14pro.log`）。试装失败对手机没有改动。【已核实】
- 所以包没传、没导入，连线 JIT 也没开。**唯一的卡点是 Xcode 里没有团队的 Apple 账号**：用户在 Xcode → 设置 → 帐户登录后，我重跑构建，Xcode 会登记这台手机、生成含它的描述文件，就能装。
- 装上之后还有两件要先问的：
  - `device-boot.sh` 两种模式（连线 lldb、StikDebug）传文件、取日志都走 `work/ios/tools/idevice-tools-0.1.68` 的 AFC，这台 Mac 上没有。要么下载这个工具（idevice 官方发布页的 `idevice-tools-macos-arm-v0.1.68.zip`，约 5 MB），要么不下载、把脚本里的文件操作改成 `devicectl device copy`，两个包合计 5.5 GB 也走它。
  - lldb 附加 iOS 27.0.1 的进程时，Xcode 可能要准备这个版本的调试支持（本机只有 iPhone19,2 27.2 的）。要下载就停下来报。

## 6. 用户登录 Xcode 之后：装上、导入、连线 JIT 开机（同一天，第三次）

用户在 Xcode 登录了团队的 Apple ID。

**签名和安装**
- 指向 14 Pro 重跑构建（`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`）成功，Xcode 把手机登记进团队，新的「iOS Team Provisioning Profile: *」到 2027-11-04，里面有 14 Pro。【已核实：逐项核对嵌入的描述文件】
- 第一次增量构建换了描述文件、资源和 dylib，却没有重新签 App 本体（日志里没有一条 `CodeSign`），`codesign --verify` 报封存资源被改。删掉产物里的 `ClassicTouch.app` 重编，签名校验通过。
- `devicectl device install app` 装上，`devicectl device process launch` 打开，首页起来了；手机上没要求另外信任开发者。【已核实：`work/ios/devicectl-install-14pro-2.log`、`devicectl-launch-14pro.log`】

**传包和导入**（没有下载 `idevice-tools`，改用 `devicectl device copy to` 传进 App 的 `Documents/import/`）
- 9.3.5（2.6 GB）86 秒，7.1.2（2.9 GB）97 秒，约 30 MB/s。devicectl 只报得出总容量（1 TB），读不到剩余空间，所以传之前没有核对空间。
- 导入：9.3.5 解包 5.5 秒，7.1.2 6.1 秒。`import.log` 第一行是「n78ap-13G36.ctpack 失败：ctpack 提前结束」：传包时 App 已经开着，它在包没传完时就去解；重新打开 App 后解成功。App 应该跳过还在写的文件，或者传的时候先用临时名、传完再改名；这一处没改。【已核实：取回的 `import.log`】

**连线 JIT 开机**（Mac 上 `lldb_jit_runner.py` 经 USB 附加，应答 QEMU 准备代码区的 `brk #0xf00d`，256 MB 逐页写，然后脱离；App 用 `-autodrive YES -idle 20` 自己认锁屏、解锁、待机后退出）
- `device-boot.sh` 两种模式的文件操作都走 `idevice-tools`，所以写了一个会话临时目录里的变体 `devboot14.sh`：挂载部分照抄，文件操作改成 `devicectl device info files` 和 `device copy from`，不进仓库。
- **9.3.5 第一次调用（`boot-13G36-1.log`）三次挂载都失败**：附加上了，但停下时没有线程带停止原因，每次「继续」都报 `Resume timed out`，连续 3 次后放弃，QEMU 一直没走到 `brk`。紧接着第二次调用（带 `LLDB_PACKET_LOG`）第一次挂载就成功；7.1.2 也是第一次就成功。失败的原因没查清。`device-boot.sh` 注释里记过大约每 4 到 5 次挂载有一次这样，这次是 5 次里 3 次。包日志在会话临时目录。
- 每次脚本里 `device select <CoreDevice 标识>` 都报失败、但附加照样成功。单独跑 lldb 时 `device select` 是成功的，lldb 的设备表里只有 14 Pro 是连着的（18 Pro 显示断开），所以附加的是 14 Pro。【已核实：`xcrun lldb` 的 `device list`】
- Xcode 和 lldb 都没有要求下载 27.0.1 的设备符号，没弹个性化开发者磁盘映像的提示；lldb 只读模块的段信息（脚本里的 `memory-module-load-level minimal`）。

| 运行（`work/ios/runs/device14/`） | 系统 | 准备代码区 | 第一帧 | 锁屏 | 主屏 | 解锁次数 | 主屏静止 CPU | 最大占用 | 最低可用内存 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `20261104-211018-n78ap-13G36-jit` | 9.3.5 | 44.7 秒 | 45.5 秒 | 123 秒 | 141 秒 | 2 | 104% | 1204 MB | 1868 MB |
| `20261104-211336-n78ap-11D257-jit` | 7.1.2 | 40.3 秒 | 41.0 秒 | 82 秒 | 142 秒 | 5 | 43% | 1096 MB | 1976 MB |

- 时间从 App 调 `qemu_ios_main` 起算，前 40 多秒是 lldb 隔着 USB 逐页写 256 MB 代码区（StikDebug 在 18 Pro 上本机做同样的事是 0.7 到 0.85 秒，M1 第三阶段）。扣掉这一段，9.3.5 约 78 秒到锁屏，7.1.2 约 41 秒。两次都正常退出（`auto_quit`、`qemu_exit status=0`）。
- 7.1.2 锁屏上挂着一条「Cannot Use Device：QEMU USB HARDDRIVE: The connected device is not supported.」（DeviceOMatic 把 USB 根盘当外接设备，10.3.4 在改盘时禁掉了，7.1.2 的包没禁），而且和大时钟叠在一起，解锁试了 5 次才进主屏；模拟器里那次一次就进了。原因没细查。
- 截图（都是客体画面，没有个人信息）：
  - 9.3.5：`docs/reports/img/ios14pro-935-lock.png`（第 123 秒）、`ios14pro-935-home.png`（第 145 秒）、`ios14pro-935-window.png`（第 155 秒，App 窗口）；
  - 7.1.2：`ios14pro-712-lock.png`（第 110 秒，带那条通知）、`ios14pro-712-home.png`（第 149 秒）。
- 收尾时手机上还有一个 ClassicTouch 进程（PID 729，比脚本结束的那个新，来历没查），已结束。Mac 上没有残留的调试器或 devicectl。

**还没做的**：没测解释器；没装 StikDebug（用户定的「先连线测，以后再说」）；手机剩余空间没核对；传包和开机的临时脚本没进仓库。

## 7. 第四次：脚本不靠 idevice-tools、导入修复、挂载统计、7.1.2 的通知

用户说「继续做」。这一轮收拾第 6 节暴露的问题，没有下载东西，也没有碰 18 Pro。

### 7.1 脚本没有 idevice-tools 时改走 devicectl

- 新文件 `scripts/ios/devfiles.sh`：App 容器（Documents）里的文件操作，提供列目录、取文件、放文件三个函数，有两种后端。
  - 有 `work/ios/tools/idevice-tools-0.1.68` 时照旧走 AFC；
  - 没有时（或设 `FILES=devicectl`）走 `devicectl device info files`、`copy from`、`copy to`。`copy to` 会自动建目录。
- `device-boot.sh`、`device-install.sh` 改用这三个函数。AFC 那条路只是换成共用函数，逻辑没变，但这台 Mac 上没有工具，没法实测。`devicectl` 读不到剩余空间（`device info details` 只有总容量），走它时 `device-install.sh` 只提示一句、不检查空间。
- `device-app-flow.sh` 没改，还是只能走 AFC。
- 实测：`device-install.sh`（走 `devicectl`）传新的 7.1.2 包 82 秒，App 解包 6.3 秒，整个 96 秒。【已核实：`work/ios/runs/device/install-20261104-221242`】
- `devicectl` 没有删除命令。试验时在 App 的 `Documents/probe-dir/` 留下两个小文件（17 字节和 6 字节；后一个本来是 2.5 GB 的试验文件，用小文件覆盖掉了），不影响 App。

### 7.2 App 在包没传完时就去解（已修）

- 用 `devicectl` 传一个 2.5 GB 的文件，传的过程中轮询它在手机上的大小（`work/ios/runs/device14/copy-size-probe.txt`），过程分三段：
  - 先建一个 0 字节的文件，停约 5 秒才开始写；
  - 之后每秒涨 40 MB 左右，修改时间跟着变；
  - 写完再把修改时间改回 Mac 上原文件的时间。
- App 原来的判断是「修改时间 3 秒没变就算拷完」，开头那 5 秒正好满足，就拿空文件去解，报「ctpack 提前结束」。解失败后，要等文件的大小或修改时间变了才会重试，可文件长大不触发目录事件，也就没人再去扫，只好等下次打开 App。
- 修法（`app/ClassicTouch/ImportManager.swift`）：
  - 0 字节的包不解；
  - 每个包记下大小从什么时候起没再变，大小和修改时间都 3 秒没变才解；
  - 目录里还有解失败的包时，每 3 秒再扫一次。
- 验证：先把 `import/` 清空，App 开着时传 7.1.2 的包（82 秒），一次就解成功（5.9 秒），没有失败那一行。【已核实：取回的 `import-4.log`】第一次验证没测到这条路：上一轮失败留下的完整包还在 `import/`，`devicectl` 看到同样的文件 1 秒就跳过了。

### 7.3 连线 lldb 的挂载：开着包日志才稳定

- **现象**：附加成功，但停下时没有线程带停止原因，接着每次「继续」都是 `Resume timed out`，QEMU 走不到准备 JIT 的 `brk`。
- **按次数统计**：
  - 不开包日志：3 次调用、9 次挂载全部这样失败（第 6 节一次、仓库脚本两次）；
  - 开着包日志（`LLDB_PACKET_LOG`）：8 次调用都是第一下就挂上。
  - 【推测】记日志拖慢了 LLDB，躲开了一处时序问题；根因没查清。
  - 成功那次的包日志：附加后进程连收几次 SIGSTOP（`T11`），LLDB 自己发 `c` 继续，之后才是 QEMU 的 SIGUSR2 和 `brk`。中间有一行 `failed to get mutex, not sending packet 'jThreadsInfo'`。
- **处理**：`device-boot.sh` 连线 JIT 时默认开包日志，写在 lldb 日志旁边（`lldb-*-packets.log`，一次约 9000 行）；`LLDB_PACKET_LOG=none` 可以关掉。中途试过把「没有停止原因」之后的等待从 0.5 秒改成 3 秒，没测到就撤回了（那三次被下面的锁屏检查挡住，没有附加）。
- **锁屏**：
  - 中途手机自动锁屏时，`device select` 报「Device needs to be unlocked.」。
  - runner 原来的日志看不到这句，而且选设备失败后照样附加。现在 18 Pro 也连着，附加到别的手机上是有风险的。
  - 改法（`scripts/ios/lldb_jit_runner.py`）：把报错原文打出来；遇到「需要解锁」每 2 秒重试，最多 2 分钟；其他错误就不附加；报错没有文字的当作选上了（14 Pro 上一直是这样，附加正常）。
  - `device-boot.sh` 开机前也先用 `devicectl device info lockState` 查一次，锁着就提示并等最多 2 分钟。
  - 不过前面 9 次失败时手机并没有锁（报错是空的），所以锁屏不是那 9 次失败的原因。
- `device-boot.sh` 原来三次都挂不上时不退出，还会空等到时限（600 秒），现在直接退出。
- **认锁屏的方式**：`device-boot.sh` 原来在 Mac 上每秒取一张客体截图做 OCR，走 `devicectl` 时一个文件要一秒左右，400 秒只取回 37 个文件，锁屏一直没认出来。
  - 现在 StikDebug 模式和文件走 `devicectl` 时默认 `AUTODRIVE=1`：App 自己认锁屏、解锁、待机后退出，截图 5 秒一张，Mac 只轮询 `events.log`。

### 7.4 统计（14 Pro，仓库脚本，连线 JIT，默认开包日志）

| 运行（`work/ios/runs/device/`） | 系统 | 挂载 | 准备代码区 | 锁屏 | 主屏 | 自动解锁次数 |
|---|---|---|---:|---:|---:|---:|
| `20261104-215054-n78ap-13G36-jit` | 9.3.5 | 第 1 下 | 42.7 秒 | 128 秒 | 187 秒 | 5 |
| `20261104-215443-n78ap-13G36-jit` | 9.3.5 | 第 1 下 | 41.1 秒 | 133 秒 | 没到 | 12（全失败） |
| `20261104-220158-n78ap-13G36-jit` | 9.3.5 | 第 1 下 | 40.8 秒 | 131 秒 | 没到 | 12（全失败） |
| `20261104-221426-n78ap-11D257-jit` | 7.1.2（新包） | 第 1 下 | 40.6 秒 | 80 秒 | 没到 | 12（全失败） |
| `20261104-222137-n78ap-11D257-jit` | 7.1.2（新包） | 第 1 下 | 40.6 秒 | 78 秒 | 没到 | 12（全失败） |

- **挂载 5 次里 5 次第一下成功，锁屏 5 次里 5 次**；**主屏 5 次里只有 1 次**。
- 卡在 App 自己的解锁：按 Home，5 秒后从屏幕宽度的 18% 处滑到 92%（纵向 90% 处，600 毫秒分 20 步）。失败的几次，客体画面一直停在锁屏，时钟照走，滑动像是没被收到。
  - 第 6 节那两次分别用 2 次和 5 次解开，模拟器里 1 到 3 次。
  - QEMU 和串口日志里没有触摸相关的报错。
  - 原因没查。【推测】手机上客体跑得慢（主屏静止就占满一个核），合成的滑动太快没被认成滑动；也可能和 A5 触摸纵向偏约 100 像素有关（a5-app.md 2.1）。这是下一步。

### 7.5 7.1.2 锁屏上的「Cannot Use Device」（已修）

- 文字出自 DeviceOMatic（`DeviceOMatic.app` 的 `UNSUPPORTED_FAILURE_TITLE`/`BODY`），不是 a5-step1.md 3.15 节写的 MobileStorageMounter（已在原处补了更正）。它的 launchd 配置在可移动的 `IOUSBDevice` 接上时拉起它，正好是我们挂根用的 USB 盘。9.3.5 的锁屏上没有这条。
- `tools/a5/n78_diskfix.sh` 的 11D257 分支：在数据卷 `db/launchd.db/com.apple.launchd/overrides.plist` 里写入 `com.apple.device-o-matic` 的 `Disabled = true`。FirmwareKit 的种子里这个文件已经存在（0 字节，属 root），写进已有文件，属主不变。`build_nand.set_owner` 核对过，不用改。
- 7.1.2 包用的黄金盘（`work/ios/devices/n78ap-11D257/disk.img`）只做了这一步（原盘克隆留在 `work/ios/devices/n78ap-11D257-disk-before-dom.img`），重新打包成 `work/ios/packs/n78ap-11D257.ctpack`（旧包留作 `n78ap-11D257-before-dom.ctpack.old`）。
- 验证：
  - Mac 上用改过的黄金盘开机（`work/a5/runs/dom712g`），38 到 54 秒都是锁屏，没有这条通知，没有 panic；
  - 手机上新包两次开机共 105 张截图，OCR 一次都没认出这条通知。【已核实】
- 有一处没查：7.1.2 的锁屏有时没画出时钟和日期（这次 Mac 上那张、上一轮模拟器那张都是），和这次的改动无关。

### 7.6 文档、收尾

- 改了：
  - `scripts/ios/devfiles.sh`（新文件）、`device-boot.sh`、`device-install.sh`、`lldb_jit_runner.py`；
  - `app/ClassicTouch/ImportManager.swift`；
  - `tools/a5/n78_diskfix.sh`、`tools/a5/README.md`；
  - `docs/reports/a5-step1.md` 补了一句更正。
- 结束时手机上 App 已结束，Mac 上没有残留的调试器、脚本。没有提交。
