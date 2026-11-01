# M1 第三阶段（E3）：用 StikDebug 在手机本机给 JIT

- 日期：2026-11-01
- 执行会话：M1 执行会话（接第一、二阶段）。范围：在 iPhone 18 Pro（iOS 27.2）上用 StikDebug 在手机本机应答新 JIT 协议，测 256 MB 准备耗时，两台各正式测一轮。
- 没做的：没碰 iPhone 14 Pro，没拷设备符号，没给 StikDebug 或其他上游提 issue、PR，没 commit。StikDebug（AGPL-3.0）的代码只在 `work/`，没有进仓库，也没编进我们的 App。

## 0. 结论

1. **StikDebug 3.2.0 在 iOS 27.2 上能给 JIT，新协议在发布形态下走通了。** 它在手机本机应答 `brk #0xf00d`：
   - 准备 **256 MB 代码区 0.68 到 0.85 秒**（4 次），32 MB 0.10 秒；
   - 平均每页（16 KiB）约 41 到 52 微秒，含分配；
   - 同样的 256 MB，第二阶段 Mac 上的 LLDB 经 Wi-Fi 要 2 到 8 分钟。
   
   准备完 QEMU 让它脱离，App 之后不带调试器跑。
2. **代码区回到 256 MB 后，JIT 快了一大截：**

   | 设备 | QEMU 亮屏 | 锁屏 | 到锁屏的 CPU | 主屏 | 主屏待机 CPU |
   |---|---|---|---|---|---|
   | iPod touch 2 代 3.1.3 | 7.7 秒 | 10 秒 | 6.9 秒 | 18 秒 | 19% |
   | 3GS 6.1.6 | 12.2 秒 | 14 秒 | 14.0 秒 | 22 秒 | 16% |

   对比真机解释器：iPod 43 秒、3GS 115 秒到锁屏，待机 CPU 61% 和 108%。两轮的待机段都核对过，没人碰。
3. **用户要做的事很少。** 这一阶段用户实际做了三件：
   - 装好并打开 LocalDevVPN；
   - 插一次数据线生成配对文件；
   - 中途拔插一次线，让卡住的文件服务恢复。

   每轮测量用户在手机上一下都不用点：Mac 用 `stikjit://` URL 拉起 StikDebug，由它启动我们的 App；App 读配置自己开机、解锁、待机、退出。
4. **新发现的风险已坐实：iPod touch 2 代用占位 SecureROM 时，一旦进了深睡就唤不醒。** 锁屏熄屏约 18 秒后客体进深睡，按 Home 唤醒会跳进占位 bootrom，CPU 100% 原地空转（第 4 节）。所以开机后要尽快解锁；正式支持 iPod touch 2 代之前，这个问题必须解决。
5. 阻塞点（都已绕过）：
   - 开着 LocalDevVPN 时，CoreDevice 的文件服务（`devicectl copy`）先在 Wi-Fi 下变慢，后来整个卡死，插拔线也不恢复。改用 AFC（idevice 工具、经 USB）后正常。
   - Mac 端认锁屏太慢，正是它让 iPod 进了深睡。改成 App 用 Vision 自己认。

## 1. StikDebug 的构建和安装

- 源码：官方仓库 StikDebug/StikDebug，发布标签 **3.2.0**（提交 97530a9，2026-10-30，不低于要求的 3.1.11），浅克隆到 `work/ios/stikdebug/`。
- 依赖：
  - Rust 写的 idevice 库以预编译静态库的形式放在仓库里（`StikDebug/idevice/libidevice_ffi.a`，57 MB），直接用了，没有从 Rust 源码重编（那要下载 Rust 工具链）。
  - Xcode 的 SPM 从 GitHub 拉了两个源码包：CodeEditorView 和 Rearrange。
- 只在 `work/` 里的副本上做了两处改动：
  - Bundle ID 改成 `org.classictouch.dev.stikdebug`：原来的 `com.stik.stikdebug` 属于别人的团队。
  - 用一份空的本地 entitlements 去掉了 App Group：原来的组名是别人团队的。代码里用 App Group 的只有图标磁盘缓存，拿不到容器时有退路；它代码里用的组名本来也和 entitlements 不一致。
- 签名：Release 构建，用 Xcode 里已有的付费个人团队、自动签名。用的是团队现成的通配描述文件「iOS Team Provisioning Profile: *」，**没有注册任何 App ID 或能力，没改账号设置**。
- 用 devicectl 装到 iPhone 18 Pro，再预先写好它的偏好设置（`Library/Preferences/org.classictouch.dev.stikdebug.plist`）：
  - `confirmExternalJITRequests = false`：外部 URL 请求开 JIT 时不弹确认；
  - `keepAliveLocation = false`：后台保活只用音频，不弹定位权限。

## 2. 配对文件

- StikDebug 3.2.0 要的是 **RemotePairing 配对文件**（RPPairing：Ed25519 公私钥、标识、可选 `alt_irk`），不是传统的 lockdown 配对记录。代码里用的是 `rp_pairing_file_read`。
- 工具：idevice 官方发布页的 `idevice-tools-macos-arm-v0.1.68.zip`（MIT，5 MB，sha256 和 GitHub 给的一致），放在 `work/ios/tools/idevice-tools-0.1.68/`。
- 生成：`idevice-tools remotepairing_lockdown pair <主机名> <文件>`，经 USB、借用 Mac 已有的信任关系，手机上没有弹窗。随后用 `verify` 校验，手机回答「recognizes this pairing record」。这一步只能走 USB，所以用户插了一次线。
- 存放：文件在 `work/ios/secrets/`（目录 700、文件 600），没进仓库，也不写进报告。用 devicectl 拷到 StikDebug 的 `Documents/pairingFile.plist`，它启动时会自己收进受保护的目录。
- 官方指南推荐的是 iloader（GUI，从 GitHub 下 DMG），这次没用。

## 3. 我们这边的改动

- **补丁**：`patches/ios-txm-jit-protocol.patch` 在新协议路径里加了一行耗时日志：`[jit] universal: N MiB at … prepared in X s`，写进 `qemu.log`。四份 dylib 里只有真机 JIT 版受影响，已重编。
- **App**：
  - `LaunchOptions.swift`：启动参数优先，没有参数就读 `Documents/autostart.json`。StikDebug 拉起我们时不带参数，靠这个文件决定开哪台设备、用哪种后端、代码区多大。
  - `GuestText.swift`：Vision 文字识别。
  - `EmulatorViewController.autodrive()`：每秒认一次客体画面。看到「slide to unlock」就记 `lock_seen` 并立刻解锁，每 12 秒重试；认出主屏就记 `home_seen`，停止识别，待机 `idle` 秒（默认 40）后自己让 QEMU 退出。整轮测量不需要 Mac 插手。
- **脚本** `scripts/ios/device-boot.sh` 加了 `STIK=1` 模式：
  1. 写好 `autostart.json`（JIT、代码区、autodrive、待机 40 秒、截图每 5 秒一张）；
  2. 结束还在跑的 App；
  3. `devicectl device process launch --payload-url "stikjit://enable-jit?bundle-id=org.classictouch.app&script-name=universal.js" org.classictouch.dev.stikdebug`；
  4. 之后每 3 秒取一次 `events.log`，等 QEMU 退出再取统计、日志和窗口截图。

  文件操作全部改走 AFC（`idevice-tools afc --documents`）。其他修补：
  - 控制命令每次写不同的内容：devicectl 会跳过它认为没变过的文件；
  - AFC 偶尔崩溃时不退出，先下载到临时文件再改名；
  - `summarize-run.py` 和 `check-idle.py` 也认 App 自己发的 `auto_quit`。

## 4. 测量结果

全部在 iPhone 18 Pro（iOS 27.2 24B119）上，经 USB 连 Mac，手机解锁，LocalDevVPN 开着。Mac 上的 iPhone 镜像 App 在运行（脚本只能记到 App 在不在跑，记不到镜像会话是否连着）。Mac 1 分钟负载 3.7 到 8.1（开头几秒有我自己的构建在收尾）。

### 4.1 两台各一轮（StikDebug，256 MB）

| 设备 | 后端 | 准备代码区 | QEMU 亮屏 | 锁屏 | 到锁屏的 CPU | 主屏 | 主屏待机 CPU | 占用 | 可用内存（最低） |
|---|---|---|---|---|---|---|---|---|---|
| iPod touch 2 代 3.1.3 | **StikDebug JIT 256 MB** | **0.68 秒** | **7.7 秒** | **10 秒** | **6.9 秒** | **18 秒** | **19%** | 751 到 775 MB | 2601 MB |
| | 第二阶段 新协议 32 MB（Mac LLDB，Wi-Fi） | 16.7 秒 | 12.0 秒 | 扣停顿 16 秒 | 15.8 秒 | | 25% | 247 MB | 3129 MB |
| | 第一阶段 旧协议 32 MB（Mac LLDB，Wi-Fi） | 46.4 秒 | 12.8 秒 | 扣停顿约 18 秒 | 17.8 秒 | | 21% | 277 MB | 3099 MB |
| | 第一阶段 解释器 | 无 | 27.4 秒 | 43 秒 | 42.5 秒 | 54 秒 | 61% | 411 MB | 2965 MB |
| iPhone 3GS 6.1.6 | **StikDebug JIT 256 MB** | **0.76 秒** | **12.2 秒** | **14 秒** | **14.0 秒** | **22 秒** | **16%** | 791 到 892 MB | 2484 MB |
| | 第一阶段 旧协议 32 MB（Mac LLDB，Wi-Fi） | 37.7 秒 | 26.1 秒 | 扣停顿约 26 秒 | 27.0 秒 | | 作废（有人点过） | 365 MB | 3011 MB |
| | 第一阶段 解释器 | 无 | 114.6 秒 | 115 秒 | 122.7 秒 | 137 秒 | 108% | 559 MB | 2817 MB |

- 这一阶段的锁屏、主屏时间是 App 自己用 Vision 认出来的（`lock_seen`、`home_seen`），和前两个阶段 Mac 上 OCR 每秒截图的口径一致；从 App 调 `qemu_ios_main` 起算。两轮都是第一次自动解锁就成功（锁屏后 1 秒）。
- 待机 CPU 按第二阶段的新口径：主屏后 3 秒到 `auto_quit` 之前。`check-idle.py` 核对：
  - iPod：21 到 58 秒，帧编号只变 2（状态栏时钟），没有任何事件；
  - 3GS：25 到 63 秒，同样只变 2，没有事件。
- 占用比 32 MB 时多了约 500 MB，主要是 256 MB 代码区（可读可执行和可写各映射一份，按实际用到的页计）。可用内存在 iPhone 18 Pro 上仍有 2.4 GB 以上。没加 `increased-memory-limit`。
- 相比第一阶段的 32 MB，iPod 到锁屏的 CPU 从 17.8 秒降到 6.9 秒，3GS 从 27.0 秒降到 14.0 秒；和解释器比，分别是 6.2 倍和 8.8 倍。第二阶段推测「32 MB 太小、频繁清空重翻译」，这次的数据证实了。
- 不需要补测：两轮都没被干扰、没出错，数字也在预期范围内。

截图（App 自己存的窗口快照，主屏，状态栏显示 JIT，确认过画面）：
- `docs/reports/img/m1s3-device-n72ap-3.1.3-stikdebug-jit256-home.png`
- `docs/reports/img/m1s3-device-n88ap-6.1.6-stikdebug-jit256-home.png`

### 4.2 准备耗时的全部记录

| 运行 | 代码区 | StikDebug 准备耗时 | QEMU 亮屏 |
|---|---|---|---|
| 221610 | 32 MB | 0.10 秒 | 12.6 秒 |
| 221950 | 256 MB | 0.85 秒 | 8.1 秒 |
| 223815 | 256 MB | 0.81 秒 | 7.8 秒 |
| 224227（iPod 正式） | 256 MB | 0.68 秒 | 7.7 秒 |
| 224356（3GS 正式） | 256 MB | 0.76 秒 | 12.2 秒 |

每页的「往返时间」没法单独量：StikDebug 每批流水线发 128 个 `M` 包（每页写 1 字节），往返被摊掉了。按总耗时除以页数，256 MB 是每页约 41 到 52 微秒（含 `_M` 分配和脚本开销），32 MB 是约 49 微秒，所以准备时间基本和代码区大小成正比，但量级是秒以内。

### 4.3 iPod touch 2 代：占位 SecureROM 下深睡唤不醒（223815 那一轮）

这一轮还用 Mac 端经 AFC 逐张取截图来认锁屏，延迟很大：锁屏在第 10 秒，解锁命令到第 39 秒才发出。`stats.csv` 里看得很清楚：

| 时间 | CPU | 背光 | 帧编号 | 说明 |
|---|---|---|---|---|
| 15 秒 | 33% | 245 | 76 | 锁屏亮着 |
| 18 秒 | 25% | 0 | 103 | 锁屏自己熄屏 |
| 21 到 33 秒 | 17% 到 22% | 0 | 103 | 熄屏空闲 |
| 36 到 39 秒 | 2% | 0 | 103 | 进了深睡（处理器断电） |
| 39 秒 | | | | 按 Home 唤醒 |
| 42 秒以后 | 100% | 0 | 103 | 一直满载、画面不再更新 |

和 `hw/arm/ipod_touch_2g.c` 的逻辑对得上：处理器重新上电时会复位并执行 bootrom，而 bootrom 是我们的占位文件（地址 0 上一条 `b .`），于是原地空转。第二阶段在模拟器里观察的 11 分钟里没触发，是因为锁屏后一直没有按 Home 唤醒；那次 CPU 同样降到了 2% 到 4%。

**处理**：
- 测量这边，改成 App 自己认锁屏、1 秒内解锁，之后再没出现。
- 正式支持 iPod touch 2 代之前必须解决，可选：
  - 让用户自己提供 SecureROM；
  - 改 qemu-ios，让唤醒也走 direct-iboot 那条路（只调研、没做）；
  - 在客体里关掉深睡。

## 5. 用户要做几步

### 这次实际做的

1. 从 App Store 装 LocalDevVPN，打开它、允许添加 VPN 配置、打开 VPN（决策会话转告时已做完）。手机上另装有别的 VPN App，同一时间只能开一个，要保证开的是 LocalDevVPN。
2. 插一次数据线，让 Mac 生成配对文件（手机没有弹窗）。
3. 中途拔插一次线，想让卡住的文件服务恢复；没起作用，后来改走 AFC 解决。
4. 测量期间手机保持解锁、插着线、不开 iPhone 镜像，测待机时不碰屏幕。

每轮测量本身用户 0 次点击。StikDebug 第一次运行时会不会弹「本地网络」权限，我没观察到，用户也没提，测量一直正常。

### 将来真实用户（不用 Mac）的流程，供设计启动流程参考

**一次性：**
- 装 StikDebug、LocalDevVPN 和我们的 App；
- 在电脑上插线生成一次配对文件，导入 StikDebug（iOS 更新或重置后要重做）。

**每次打开：**
1. 确认 LocalDevVPN 开着（打开后可以一直开着）；
2. 在我们的 App 里点「开启 JIT」：App 自己打开 `stikjit://enable-jit?bundle-id=…&script-name=universal.js`，StikDebug 默认会弹一次确认，点确认后它会重新拉起我们的 App；
3. 选要开的系统。

大约 2 到 3 次点击。另一种做法是先打开 StikDebug、点 Enable JIT、选我们的 App。但我们的 App 不在它按名字自动分配脚本的名单里，要先长按给它指定一次 universal.js。

## 6. 遇到的问题

| 问题 | 处理 |
|---|---|
| StikDebug 原有的 Bundle ID 和 App Group 属于别人的团队 | 本地副本改 Bundle ID、去掉 App Group，用通配描述文件签名，账号里什么都不用注册 |
| 配对文件只能经 USB 生成 | 请用户插一次线 |
| 开着 LocalDevVPN 时，devicectl 经 Wi-Fi 列文件要 13 秒、拷贝 40 秒超时 | 请用户插回线。截屏、进程、锁定状态这几个服务一直正常 |
| CoreDevice 的文件服务卡死：被中断几次后，所有 App 的容器都列不出来，重启 Mac 上用户级的 CoreDeviceService、插拔线都不恢复 | 改用 idevice 工具的 AFC（传统 lockdown 的 house_arrest，经 usbmuxd），一秒内返回 |
| 第二次控制命令送不到 App | devicectl 会跳过没变过的文件；每次写不同内容（改 AFC 后也保留） |
| `idevice-tools afc` 偶尔 Abort trap | 失败不退出，下载先写临时文件 |
| Mac 端认锁屏慢，iPod 进深睡唤不醒 | App 用 Vision 自己认锁屏和主屏、立刻解锁 |

## 7. 下一步建议

1. **JIT 路线定为 StikDebug（或以后内嵌 StikJIT）加通用协议。** Mac 上 LLDB 那条路只留作开发调试，脚本修复按决策会话的安排先放着。
2. App 里加「开启 JIT」按钮（打开 `stikjit://` URL），并把 universal.js 的指定放进 URL 参数，省掉用户在 StikDebug 里手动指定脚本。
3. **iPod touch 2 代的 SecureROM 问题要在正式支持前解决**（第 4.3 节）。
4. `increased-memory-limit`：iPhone 18 Pro 上 256 MB 代码区之后仍有 2.4 GB 余量，不急；iPhone 14 Pro（6 GB）要等实测。
5. 解释器下的待机耗电（3GS 108%）在 JIT 下降到 16%，JIT 对续航也很关键。

## 8. 文件

- 仓库里（未 commit）：
  - `patches/ios-txm-jit-protocol.patch`（加了耗时日志）
  - `app/ClassicTouch/LaunchOptions.swift`、`GuestText.swift`、`EmulatorViewController.swift`
  - `scripts/ios/device-boot.sh`、`summarize-run.py`、`check-idle.py`
  - 本报告和 `docs/reports/img/m1s3-*.png`
- `work/` 里（不提交）：
  - `work/ios/stikdebug/`（StikDebug 源码，AGPL）
  - `work/ios/DerivedData-stikdebug/`
  - `work/ios/stikdebug-local.entitlements`、`work/ios/stikdebug-prefs/`
  - `work/ios/tools/idevice-tools-0.1.68/`
  - `work/ios/secrets/`（配对文件）
  - `work/ios/runs/device/2026110122*`（各轮记录）
- 手机上：装着 StikDebug（`org.classictouch.dev.stikdebug`）和我们的 App，测完已结束 App。LocalDevVPN 由用户自己管理。
