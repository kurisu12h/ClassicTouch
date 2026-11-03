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
| 2026-11-03 | **恢复，先攻 iOS 8 到 10（用户定）**。项目根目录改为 `~/Developer/ClassicTouch`（原 `~/Developer/classic-ios` 已删）。已重新克隆 qemu-ios b225694505、LightTouchMac b06012fa4c（上游都没有新提交），Mac 版 `work/build-jit/qemu-system-arm` 照 M0 第 3 节编好（没带 FFmpeg，A5 串口开机用不到）。另注：`scripts/ios/fetch-sources.sh` 取的是 iOS 交叉编译的依赖源码包，不是上游仓库，上面的恢复说明要补这一句。第 1 步（n78 机型骨架）重新开工，固件下载待用户批准 |
| 2026-11-03 | 用户批准并已下载 iPod5,1 的 9.3.5 和 7.1.2（sha1 核对通过，`work/firmware/`），解出内核、设备树、iBoot 到 `work/a5/dec/`（密钥取自 ipsw.me，`work/a5/n78_unpack.py`）。**测试机改为 iPhone 14 Pro（用户定）**；当时 Mac 上只看得到 iPhone 18 Pro，14 Pro 没出现。第 1 步只在 Mac 上做，暂时用不到手机。14 Pro 上要注意：iOS 27.0.1 上 StikDebug 给 JIT 还没有成功报告（M1 调研第 0 节第 2 条）；第一次连 Xcode 要下约 6 到 7 GB 设备符号（要用户批准）；StikDebug 和 App 都要重新装、重新生成配对文件 |
| 2026-11-03 | **iOS 8 到 10 第 1 步过半**（`docs/reports/a5-step1.md`，补丁 `patches/a5-n78-skeleton.patch`，脚本 `tools/a5/`）：新机型 `iPod-Touch-5G` 加 AIC 模型，7.1.2 和 9.3.5 的内核都在 uart1 打出开机日志，AppleInterruptController 认出 AIC（192 条外部中断、2 个核间中断），GPIO、性能控制器都起来了；两个版本都停在性能控制器之后的 panic「handleSwapCleanup - can't free 1 channels of dimension 0」（PMGR 位置上暂放的是 A4 模型）。下一步写 s5l8940x 的 PMGR 模型。iPhone 14 Pro 后来已能被 devicectl 看到 |
| 2026-11-03 | **越过性能控制器**（报告 3.5 节）：原停止点不是 PMGR 寄存器，而是设备树里 iBoot 该填的 CPU 性能状态表（`voltage-states1`、`cpu-clk-cfgs`，规则从 n78 iBoot 反汇编得出）和 AIC 核间中断要靠读 Iack 应答。现在 SPI、I2C、PWM、DSI、I2S、PL310、串口、看门狗、DWI 都起来了，两个版本都停在 i2c0 读 PMU（0xE8）失败的 panic。PMGR 寄存器模型推迟到内核开始写 PMGR 时再做。下一步：A5 的 I2C 控制器加 D1881 PMU |
| 2026-11-03 | **I2C、PMU、PMGR 门控完成**（报告 3.6 节）：A5 的 I2C 是 PA Semi 式控制器（Linux i2c-pasemi 那种），新写了模型；GPIO 复用 A4 模型，I2C 引脚设为高电平；D1881 先做成寄存器文件，PMU 驱动已经读写一百多次；PMGR 时钟门控也补上了。9.3.5 走到 BSD 网络初始化，7.1.2 走到 LCD 驱动。两个版本都不再 panic，停在没有模型的设备（DART、USB、CLCD、RGBOUT）在 start() 里等中断。jpeg、scaler、vxe 已在设备树里隐藏 |
| 2026-11-03 | **iOS 8 到 10 第 1 步目标达成**（报告 3.7 节）：7.1.2 和 9.3.5 的内核都走到 `Waiting on <dict>…IOMedia…Partition ID 1…`，即在等根设备。上一条说「停在 DART、USB 等设备上等中断」是误判：等根设备那行早就打出来了，判断用的正则没匹配上。jpeg、scaler、vxe 的隐藏已撤回，不需要。第 1 步剩下的是给内核一个根设备：USB 大容量存储（要做 EHCI），或者先用恢复内存盘当 md0 试一下（更快）。待用户定 |
| 2026-11-03 | **内存盘当根（用户定先试）**（报告 3.8 节）：两个版本都 `BSD root: md0`，根挂上了，但 launchd 还没执行（60 秒内没有用户态异常）。9.3.5 另有定时器只响一次的问题。下一步：用 gdb 调试口拿各线程调用栈，找 bsd_init 在等什么 |
| 2026-11-03 | **launchd 起来了**（报告 3.9 节）：7.1.2 和 9.3.5 用恢复内存盘当根，都执行了 launchd 并拉起 restored_external，这是模拟的 A5 上第一次跑用户态。卡点有两个：bsd_init 的 IOSecureBSDRoot 要等 AES 驱动在 start 里跑完一次 AES 运算，没有 CDMA 模型就永远等着（复用上游 A4 的 `s5l8930_cdma.c`，加了 `dram-base`、`channels` 属性，A4 的默认值和快照格式不变）；9.3.5 定时器只响一次，是因为 AIC 模型读 Iack 时把一个早到的自发 IPI 清掉了，内核的 SIGPdisabled 因此永远清不掉（改成读 Iack 只屏蔽 IPI，加上 +0x24/+0x28 两个 IPI 屏蔽寄存器）。60 秒 FIQ：7.1.2 2740 次，9.3.5 1388 次（原 1 次）。现在两版都是 restored_external 找不到显示器、USB 连接失败后退出，重启时 panic 在 USB 主机控制器 `could not halt controller in 100 ms`。下一步候选：显示管线、EHCI（也是 USB 盘挂根要的）、NVRAM。A4 的 CDMA 改动只做了实例化和 vmstate 比对，没实际开机（本机已无 A4 设备） |
| 2026-11-03 | **显示出来了**（报告 3.10 节，用户：「先做显示」）：上游 A4 的显示模型和 MIPI-DSI 模型按 A5 地址接到 n78 上（管线 0 挪到 arm-io +0xa100000），开机包从本地 IPSW 解出苹果标志画进 vram。A5 用的是 H4P 一代管线（7.1.2 也是），层寄存器和 A4 不同：源矩形是 0x60 到 0x70，每层自带页表（0x98）。显示模型加了 `h4p` 开关（默认关，A4 迁移格式不变）。现在两版 restored_external 都拿到 640×1136 的显示器，不再报找不到显示器和帧缓冲；截图：开机是苹果标志，9.3.5 进到恢复界面（标志加进度条），7.1.2 显示一个转圈图案（谁画的待查）。restored 仍因 USB 失败退出。下一步候选：EHCI、NVRAM |
| 2026-11-03 | **USB 通了，两版都能从 USB 盘挂根**（报告 3.11 节，用户：「接着做 USB」）：A4 的 USB PHY、OTG、EHCI、OHCI 模型按 A5 地址接到 n78（arm-io +0x6000000 起），重启途中的 USB panic 没了。9.3.5 新 USB 栈原来枚举失败，原因是 n78 的 PA 0 是内存别名，驱动的占位 QH 指向 PA 0，读到内核拷进去的异常向量被当成传输，QEMU 的 EHCI 因此反复自我复位；PA 0 改成只读占位 ROM（真机上是 SecureROM）后两版都能枚举 `usb-storage`。用本地 IPSW 解密的 rootfs 做成 GPT 盘（`tools/a5/n78_usbroot.py`，没有新下载），两版都 `BSD root: disk0s1`、起 launchd、fsck，然后因缺数据分区 /dev/disk0s2 关机。开机包给 usb-complex 加 `no-pmu`（按接在电脑上处理），恢复内存盘里 restored 不再报 `enable_usb_connections failed`，停在恢复模式。下一步：做数据分区（/private/var），往 SpringBoard 走 |
| 2026-11-03 | **冲主屏（7.1.2）阶段报告**（报告 3.12 节，用户：「接着冲主屏」）：本日改动已由用户批准提交在 `a5-n78` 分支（01730e0），之后照旧不提交。借 FirmwareKit 只做卷（副本打两行补丁 `patches/a5-firmwarekit-n78-volumes.patch` 让 n78ap 走 n90 的 iOS 7 配方，`--stop-after volumes --skip-setup`；guest 工具按 M0 第 4 节重建），USB 盘做成系统加数据两分区。7.1.2 完整系统开起来：数据卷挂到 /private/var，launchd 拉起五十多个守护进程，然后 keybagd `FATAL KEYBAG ERROR: kb_load`、要求进恢复模式而关机。卡点是 AppleKeyStore 等的可擦除存储（A5 上只有 NAND 版驱动 AppleEffaceableNANDNOR，NVRAM 也在 NAND 上）；数据卷开着内容保护时连文件创建都卡住，清掉后才走到这一步。下一步首选做 A5 的 NAND（PPN）和 IOFlashStorage，一次解决钥匙包和 NVRAM；之后还要接 GL 桥和复位。还没到锁屏 |
| 2026-11-03 | **NAND 做好了，越过钥匙包**（报告 3.13 节，用户选「做 NAND，正路」）：新写 IOP 高层模型 `hw/arm/s5l8940_iop.c`（AppleA5IOP 控制块、AIC 门铃、EmbeddedIOP 消息环、AppleIOPFMI 的 PPN 命令：控制器信息、读写擦多页、引导页、坏块表），背后是自定的 PPN 设备（1 CE、2 CAU×0x420 块×128 页×8 KiB，约 2.2 GB，页存储落在稀疏文件）。IOP 固件不跑。照 FirmwareKit 的钥匙包开机做了 A5 版帮手 `tools/a5/it_nandfmt.c`：恢复内存盘当根，经分区方案 user client 格式化 NAND 分区（FTL 用 `nand-enable-reformat=1` 自格式化），再格式化可擦除存储、在 USB 数据卷上建系统钥匙包。之后正常开机：可擦除存储、NVRAM 起来，keybagd 不再报错，屏幕是转圈（反复崩溃的是 backboardd，3.14 节更正）。手工步骤（盘上改 fstab 为 disk1、放 `.it_sealed`）还没写成脚本；9.3.5 未试 |
| 2026-11-03 | **A5 画出了 iOS 界面**（报告 3.14 节，用户：「接着做 GL 桥」）：先在可写的盘克隆上取崩溃日志，反复崩溃的是 backboardd：第一次是 GL 前端的 `QEMU_CALL` 陷入（0xee6f6f1f）没人接的 SIGILL，其余在 CompassPlugIn 里。照 `ipad1.c` 给 n78 接上 `QEMU_CALL` 和 gles-host 后，第 120 秒 UI 画出苹果标志，第 180 秒到设置助理「Hello / slide to set up」（截图 `docs/reports/img/a5-gl-hello.png`）。待查：CompassPlugIn 间歇崩溃（开机头 75 秒 7 次）、GL 线协议告警、SetupDone 已置位仍出设置助理；没有触摸。9.3.5 未试 |
| 2026-11-04 | **A5 进了锁屏**（报告 3.15 节，用户：「直接冲锁屏」）：7.1.2 开机约 100 秒直接到锁屏，不需要触摸，两次验证都过（截图 `docs/reports/img/a5-lockscreen.png`）。原因和做法：FirmwareKit 的激活匹配器认不出 n78 的 lockdownd，退回了 data_ark 路线，改用 `tools/a5/n78_activate.py` 原地打同样的本地短路补丁（不连苹果服务器）；设置助理是因为 iPod touch 5 比 iPhone 4 多了 Siri 等步骤，补上四个完成标记；backboardd 约一半的开机会在罗盘 HID 插件里崩溃（NULL+0xc，根因未查，和 HFS 压缩无关），先把两个插件移走；n78 接上 guest 包服务，GL 协议告警消失。这些盘上的改动都写进了 `tools/a5/n78_diskfix.sh`。下一步：触摸、按键、复位、实时时钟，罗盘插件的根因，9.3.5 |
| 2026-11-04 | **A5 进了主屏**（报告 3.16 节，用户：「继续做」）：照 `ipad1.c` 给 n78 接上 spi1 上的触摸（iPod 的 SPI 和 Zephyr2 模型，固件由 mtmergeprops 从 N78.mtprops 的 C1F58 条目下发，61520 字节）和 GPIO 按键（Home、电源、音量，引脚 0 到 3）。新工具 `tools/a5/qinput.py` 经 QMP 按时间表截图、按键、点按、滑动：按 Home 唤醒、滑动解锁进主屏，点开「设置」，按 Home 返回，全程无人操作（截图 `docs/reports/img/a5-homescreen.png`、`a5-settings.png`）。待做：触摸纵向校准（偏上约 100 像素）、PMU 唤醒、复位、实时时钟、罗盘插件根因、9.3.5 |

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
