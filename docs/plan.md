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
| M2 | 能玩：多点触控、3D、声音、Home/电源键；版本列表选系统后冷启动 | 第一项「手机图形加速」完成（2026-11-01，见 `docs/reports/m2-gl-eagl.md`，补丁 `patches/ios-eagl-es2.patch`）：EAGL 按客体 API 分别建 ES 1.1 / ES 3.0 上下文，复用上游 ANGLE 的 ES 适配；iPhone 18 Pro 上 iOS 7.1.2 29 秒到锁屏、37 秒到主屏，待机 44%，设置和 Home 能用；iOS 3、6 不退步。待跟进：iOS 7 待机 44% 偏高（疑似 glReadPixels 读回）；没测 3D 游戏。第二项「App 雏形」完成（2026-11-02，见 `docs/reports/m2-app-prototype.md`）：系统列表、点系统跳 StikDebug 开 JIT 后自动回来开机（换系统同样走 `stikjit://` 起新进程）、返回列表、后台和列表页暂停虚拟机、Finder/「文件」导入 `.ctpack`、String Catalog（中文）。用户已拔线亲手试通。用户反馈：iOS 7 锁屏和主屏很卡（每秒 6 到 10 帧，占满一个核），「设置」不卡，iOS 3 顺。第三项「iOS 7 卡顿」进行中（2026-11-02 用户批准，交给 m2-gl-eagl 会话，报告 `docs/reports/m2-ios7-perf.md`）：先做自动滑动测试，用 `IT_GLES_PROF` 找时间花在哪，再对症改。待办：列表里删除系统；`.ctpack` 文档类型；客体锁屏熄屏后黑屏的提示。已知：iOS 7 会弹「Cannot Use Device / QEMU USB Keyboard」挡住触摸，App 现在默认不挂 usb-kbd。一个进程只能起一次 QEMU，从列表换另一个系统要重启 App 进程（iOS 上 App 不能自己重开，用 StikDebug 时每次启动还要重新开 JIT），这个流程要设计。快照不做（EAGL 后端本来也存不了，`gles-host.c:672`） |
| M3 | 版本库：手机上选版本、下载固件、就地制作设备 | |
| M4 | 打磨界面（版本列表、机身外观、导入老 App），发布 | |

## 待用户决定

- App 名字（不能带 iOS、iPhone 等苹果商标）；现在用占位名 Classic Touch（`org.classictouch.app`）
- 是否让 Xcode 从 iPhone 18 Pro 拷一份 24B119 的设备符号（约 6 到 7 GB，进 Mac 的 `~/Library/Developer/Xcode/iOS DeviceSupport`）；现在不拷也能用

## 已知事实和待验证

- 手机上的 StikDebug 是我们自己编的副本（`org.classictouch.dev.stikdebug`，源码在 `work/ios/stikdebug/`，3.2.0）。为了测试时不用点，M1 把它的「外部请求开 JIT 时弹确认」关了（`confirmExternalJITRequests = false`）；配对文件在 `work/ios/secrets/`（600 权限），等于手机的访问凭证，永不进仓库。
- 开发签名：Xcode 里已有付费个人团队，M1 用它现成的通配描述文件装机，没建新 App ID。团队 ID 不进仓库。发布后用户各自用自己的 Apple ID 经 AltStore/SideStore 签，不涉及我们的账号。
- iPod touch 2 代要苹果的 SecureROM（`bootrom_240_4`），按规矩不能进 App。现在用 4 字节占位文件，冷启动没问题。用户 2026-11-01 决定先不做长待机测试；M0 在看到这条决定前已顺手做了一次两分钟的睡眠测试：锁屏约 30 秒后进深睡，按 Home 后 CPU 复位到地址 0，卡死。根治路线已明确：照 3GS 机型的 `s5l8920_resume` 给 iPod 2 代补一段唤醒的高层模拟，做成补丁，之后完全不需要苹果的 SecureROM。等做 iPod touch 2 代正式支持时再做；在那之前避免让它进深睡（自动锁定设为永不）。
