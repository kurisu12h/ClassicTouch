# 路线和决策

## 已定决策

| 日期 | 决策 |
|---|---|
| 2026-11-01 | 开源，GPL-2.0-or-later（用户：算是给开源社区的贡献） |
| 2026-11-01 | 按侧载发布规划（GitHub + AltStore 源），不指望 App Store |
| 2026-11-01 | 不打包苹果固件，App 内从苹果服务器下载、在手机上制作设备 |
| 2026-11-01 | 版本范围先做 iPhone OS 1 到 iOS 7.1.2；iOS 8 以后（A5/A6 芯片）留作以后 |
| 2026-11-01 | 工作方式：决策会话派执行会话，执行会话回报决策会话，决策会话再告诉用户 |
| 2026-11-01 | M0 加测 iPhone 4 iOS 7.1.2（苹果服务器）和 iPod touch 2 代 iOS 3.1.3（archive.org），用户已批准下载 |
| 2026-11-01 | M1 第二阶段开工：新 JIT 协议加真机重测，用户批准 |
| 2026-11-01 | 不做快照秒切。App 里用列表选系统，选了就冷启动（用户：「做成可以在列表选择系统就行了」）。快照不排期 |
| 2026-11-01 | M1 第三阶段试 StikDebug：从源码编译、用付费个人团队签名装到 iPhone 18 Pro（需要时可注册 App ID），在 Mac 上生成配对文件，用户自己装 LocalDevVPN |
| 2026-11-01 | JIT 路线定为 StikDebug（以后可考虑内嵌 StikJIT）加通用协议（`brk #0xf00d`）。Mac 上 LLDB 只留作开发调试 |
| 2026-11-02 | 目标扩到 iPhone OS 1 到 iOS 10（用户定）。iOS 8 到 10 要模拟 A5/A6 机型（iPhone 4S/5、iPad 2 等），上游和 Light Touch 都不做，没有现成模拟器，是长期目标 |
| 2026-11-02 | GitHub 仓库 kurisu12h/ClassicTouch，先私人，做完公开（用户定）。初次推送连现有代码和文档；commit、push 仍只在用户要求时做 |
| 2026-11-02 | 和界面会话并行开两件（用户选）：会话 timeline-fill 补齐年表，下载并制作 iPod touch 2 代 2.2.1、iPhone 4 4.3.5 和 5.1.1、初代 iPhone 1.0（约 1.9 GB，用户已批准），先在 Mac 和 iOS 模拟器开机，并给初代 iPhone 加 App 端开机支持（报告 `docs/reports/m2-timeline.md`）；会话 ios8-10-research 做 iOS 8 到 10 可行性调研（报告 `docs/research/ios8-10-feasibility.md`）。「手机上制作设备」这次没选 |
| 2026-11-02 | iOS 8 到 10 开始第 0 步（用户批准，含下载 iPod touch 5 的 9.3.5 和 7.1.2，约 2.9 GB）：会话 ios8-10-research 解包固件、清点硬件和内核，回答闪存、AMFI、GL 装载等 6 个问题，不写模拟器代码（报告 `docs/research/ios8-10-step0.md`）。做不做整条 iOS 8 到 10 轨道，看第 0 步结果再定 |
| 2026-11-02 | 年表补齐完成（`docs/reports/m2-timeline.md`）：初代 iPhone 1.0、iPod touch 2 代 2.2.1、iPhone 4 4.3.5 和 5.1.1 在 Mac 和 iOS 模拟器里都开到主屏，年表 2007 到 2013 连成一列。初代 iPhone 用占位 ROM 就能开（App 加了 `s5l8900` 开机方式）；2.2.1 要打 `patches/firmwarekit-n72-2x-direct-iboot.patch`（以后 M3 在手机上做设备也要带）。测试设备用 en-AU 英文做（脚本 OCR 认英文）。4 个包在 `work/ios/packs/`（约 5.2 GB），还没装手机；`Theme.swift` 的 `Era.runnable` 要改成 `1...7` |
| 2026-11-02 | iOS 8 到 10 第 0 步完成（`docs/research/ios8-10-step0.md`）：A5 内核没有老闪存驱动，A4 的闪存生成器用不上，但可以把系统盘挂在 USB 大容量存储上绕开（驱动已核实，要开机验证）；AMFI 仍认放宽签名的启动参数；GL 派发表三代逐字节相同；新问题是 9.3.5 的 dyld 已要求开发版共享缓存（GL 前端装法要改，建议改缓存头 cacheType 试）、launchd 改从缓存读守护进程。没有硬性阻断。第 1 步（机型骨架）待用户定 |
| 2026-11-02 | 用户：先做不要真机的部分。iOS 8 到 10 第 1 步开工（会话 ios8-10-research，Mac 上做 iPod touch 5 机型骨架，目标内核打印到 Waiting for root device，再试 USB 盘，报告 `docs/reports/a5-step1.md`）；timeline-fill 做装手机前的准备（`Era.runnable` 改 `1...7`、编真机版、写好一键装机命令），装手机等用户方便时再安排 |
| 2026-11-02 | 装机前准备完成：`Era.runnable` 已改 `1...7`，autodrive 能认「不经锁屏直接到主屏」，真机版 App 编译通过（没装），一键装机 `scripts/ios/device-install.sh`（约 10 到 15 分钟，要插线、解锁、开 LocalDevVPN、关镜像）。iOS 8 到 10 第 1 步的会话开工约 10 分钟后被 Opus 5.5 的安全机制以「[cyber]」拦下停了，只留下 `work/a5/`（qemu-ios 工作树、FirmwareKit 副本、初步构建），没有补丁和报告。怎么继续待用户定 |
| 2026-11-02 | **项目暂停（用户定）**：全部改动推到 GitHub 后，本机项目文件夹整个删掉（含 `upstream/`、`work/`：固件、做好的设备和 `.ctpack`、编译产物、StikDebug 副本、配对文件）。推送前核对过：`work/ios/qemu-ios` 的改动和 `patches/` 4 个 qemu 补丁叠加的结果一致，FirmwareKit 的改动就是 `patches/firmwarekit-n72-2x-direct-iboot.patch`；A5 第 1 步会话留下的半截 kboot 改动（约 50 行，没编完）不保留。手机上的 App、StikDebug 和三台设备数据没动，4 个新系统没装。以后恢复：克隆仓库，`scripts/ios/fetch-sources.sh` 取上游并打补丁，重新下载固件、制作设备；StikDebug 照 `docs/reports/m1-stage3-stikdebug.md` 第 1、2 节重编并重新生成配对文件 |

## 测试设备

| 设备 | 系统 | 用途 |
|---|---|---|
| iPhone 18 Pro | iOS 27.2（24B119） | 主开发机，用户已同意（2026-11-01），开发者模式已开；M1 已在上面开机，Wi-Fi 连 Mac |
| iPhone 14 Pro（A16） | iOS 27.0.1 | 第二台，首次连 Xcode 要下约 6 到 7 GB 符号，未获批 |

## 路线

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | Mac 上编译引擎，跑代表版本，测有 JIT 和纯解释器的 CPU 占用、快照大小和耗时 | 完成（2026-11-01，见 `docs/reports/m0-mac-benchmark.md`） |
| M1 | 交叉编译到 iPhone，最简 App 壳，把 Mac 上做好的设备拷进手机开机（「第一」的里程碑） | 第一阶段完成（2026-11-01，见 `docs/reports/m1-stage1.md`）：iPod touch 2 代 3.1.3 和 3GS 6.1.6 在模拟器和 iPhone 18 Pro 上，解释器、JIT 都开到主屏。瓶颈：旧 JIT 协议要调试器搬整块代码区，Wi-Fi 下只能用 32 MB。第二阶段（2026-11-01，见 `docs/reports/m1-stage2.md`）：新 JIT 协议补丁 `patches/ios-txm-jit-protocol.patch` 能用，真机 32 MB 四次开到主屏，调试器分配 256 MB 只要 0.02 秒；但分配后仍要调试器把每页写一遍，Mac 隔着 Wi-Fi 约 2 MB/s，256 MB 约 2 分钟。Mac 上的 LLDB 脚本在信号处理和改寄存器上不稳，256 MB 真机测量没完成。第三阶段（E3）完成（2026-11-01，见 `docs/reports/m1-stage3-stikdebug.md`）：StikDebug 3.2.0 在 iOS 27.2 上手机本机给 JIT，256 MB 准备 0.68 到 0.85 秒；JIT 256 MB 下 iPod 3.1.3 10 秒、3GS 6.1.6 14 秒到锁屏，待机 CPU 19% 和 16%（解释器 43 秒、115 秒，61%、108%）。每轮测量用户 0 次点击。第四步（2026-11-01，见 `docs/reports/m1-stage4-ios7.md`）：iPhone 4 iOS 7.1.2 在手机上卡在苹果标志。关着宿主 GL 时 iOS 7 的 SpringBoard 一建 GL 上下文就崩，179 秒重启 29 次；模拟器复现，和手机、JIT、USB 键盘无关。iOS 3、6 能退回软件合成，iOS 7 不能。要开 iOS 7 得先有宿主 GL。还没做：真正拔线、只在手机上操作的流程 |
| M2 | 能玩：多点触控、3D、声音、Home/电源键；版本列表选系统后冷启动 | 第一项「手机图形加速」完成（2026-11-01，见 `docs/reports/m2-gl-eagl.md`，补丁 `patches/ios-eagl-es2.patch`）：EAGL 按客体 API 分别建 ES 1.1 / ES 3.0 上下文，复用上游 ANGLE 的 ES 适配；iPhone 18 Pro 上 iOS 7.1.2 29 秒到锁屏、37 秒到主屏，待机 44%，设置和 Home 能用；iOS 3、6 不退步。待跟进：iOS 7 待机 44% 偏高（疑似 glReadPixels 读回）；没测 3D 游戏。第二项「App 雏形」完成（2026-11-02，见 `docs/reports/m2-app-prototype.md`）：系统列表、点系统跳 StikDebug 开 JIT 后自动回来开机（换系统同样走 `stikjit://` 起新进程）、返回列表、后台和列表页暂停虚拟机、Finder/「文件」导入 `.ctpack`、String Catalog（中文）。用户已拔线亲手试通。用户反馈：iOS 7 锁屏和主屏很卡（每秒 6 到 10 帧，占满一个核），「设置」不卡，iOS 3 顺。第三项「iOS 7 卡顿」完成（2026-11-02，见 `docs/reports/m2-ios7-perf.md`，补丁 `patches/ios-gles-perf.patch`）：主因是每帧中途把没画完的整屏读回客体内存十几到二十几次，改成每帧只在画完时读一次；真机锁屏拖动 26→60 帧，主屏按住拖 5→49 帧，翻页动画约 36 帧；静止 CPU 仍 41%（剩下那次读回慢在苹果 GL 内部，再降要 IOSurface 渲染目标或显示直通）。第四项「界面」（会话 app-ios-7，报告 `docs/reports/m2-ui.md`）：用户选了「年表」方案，首页、设置（外观、删除系统、存储）、关于（许可证全文、致谢）、App 图标已做；运行画面新外观已接进 `EmulatorViewController` 并装到 iPhone 18 Pro（2026-11-02，三台设备数据保留；真机 iOS 7 锁屏拖 60 帧、主屏拖 55 帧，没变慢），等用户亲手试；「请我喝杯咖啡」按钮的链接等用户给。待办：`.ctpack` 文档类型；客体锁屏熄屏后黑屏的提示。已知：iOS 7 会弹「Cannot Use Device / QEMU USB Keyboard」挡住触摸，App 现在默认不挂 usb-kbd。一个进程只能起一次 QEMU，从列表换另一个系统要重启 App 进程（iOS 上 App 不能自己重开，用 StikDebug 时每次启动还要重新开 JIT），这个流程要设计。快照不做（EAGL 后端本来也存不了，`gles-host.c:672`） |
| M3 | 版本库：手机上选版本、下载固件、就地制作设备 | |
| M4 | 打磨界面（版本列表、机身外观、导入老 App），发布 | |

## 待用户决定

- **iOS 8 到 10 做不做**（调研报告 `docs/research/ios8-10-feasibility.md`，2026-11-02）：做得成、没有硬性阻断，但是全新 SoC 移植（A5 的中断控制器、双核、PPN 闪存），中位估计 2.5 到 4 个月到 iOS 9 主屏、iOS 10 再加 1 到 3 个月。第一台推荐 iPod touch 5（A5，6.0 到 9.3.5）；iOS 10 要第二台 iPhone 5（A6，固件没加密，已抽查 fwkeydb）。第 0 步要下载 iPod touch 5 的 9.3.5 和 7.1.2（约 2.9 GB）。是否买二手参照机（iPod touch 5 或 iPad mini 1 加树莓派 Pico，或 iPhone 5）待定
- 「请我喝杯咖啡」用哪个平台、链接

- App 名字（不能带 iOS、iPhone 等苹果商标）；现在用占位名 Classic Touch（`org.classictouch.app`）
- 是否让 Xcode 从 iPhone 18 Pro 拷一份 24B119 的设备符号（约 6 到 7 GB，进 Mac 的 `~/Library/Developer/Xcode/iOS DeviceSupport`）；现在不拷也能用

## 已知事实和待验证

- 手机上的 StikDebug 是我们自己编的副本（`org.classictouch.dev.stikdebug`，源码在 `work/ios/stikdebug/`，3.2.0）。为了测试时不用点，M1 把它的「外部请求开 JIT 时弹确认」关了（`confirmExternalJITRequests = false`）；配对文件在 `work/ios/secrets/`（600 权限），等于手机的访问凭证，永不进仓库。
- 开发签名：Xcode 里已有付费个人团队，M1 用它现成的通配描述文件装机，没建新 App ID。团队 ID 不进仓库。发布后用户各自用自己的 Apple ID 经 AltStore/SideStore 签，不涉及我们的账号。
- iPod touch 2 代要苹果的 SecureROM（`bootrom_240_4`），按规矩不能进 App。现在用 4 字节占位文件，冷启动没问题。用户 2026-11-01 决定先不做长待机测试；M0 在看到这条决定前已顺手做了一次两分钟的睡眠测试：锁屏约 30 秒后进深睡，按 Home 后 CPU 复位到地址 0，卡死。根治路线已明确：照 3GS 机型的 `s5l8920_resume` 给 iPod 2 代补一段唤醒的高层模拟，做成补丁，之后完全不需要苹果的 SecureROM。等做 iPod touch 2 代正式支持时再做；在那之前避免让它进深睡（自动锁定设为永不）。
