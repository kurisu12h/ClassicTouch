# iOS 8 到 10 可行性调研：在 iPhone 上模拟 A5/A6 机型

- 日期：2026-11-02
- 作者：ios8-10-research 执行会话。纯调研，没写模拟器代码；除本文件外没改仓库里的任何文件。
- 方法：读本仓库 `docs/`，`upstream/qemu-ios`（b225694505）和 `upstream/LightTouchMac`（b06012fa）的源码与文档；`gh api` 读 apple-oss-distributions/xnu（xnu-4570.1.46，第一个带 32 位 ARM 代码的开源版本）、apple-oss-distributions/dyld（239.4、353.2.1、360.22、421.2、433.5）、tihmstar/fwkeydb、rzxvx/Project-Cascadia、c12n/nexttouch、blake-lucas/LightTouch、axi0mX/ipwndfu 等仓库；ipsw.me 公开接口（只读密钥和固件包元数据）；网页搜索。没有往 `work/research/` 克隆任何仓库（用不着）；没下载任何苹果固件；临时目录里只放了 ipsw.me 的密钥 JSON 和 LLVM 的一个 `ARM.td`。
- 标注：**【已核实】** 我直接读到了源码、仓库内容、官方页面或公开数据；**【作者自述】** 项目作者自己说的，我没法独立验证；**【推测】** 我的推断，或只有间接、第三方证据。
- 机型代号：A5 = S5L8940X（45 nm）/ S5L8942X（32 nm），A5X = S5L8945X，A6 = S5L8950X，A6X = S5L8955X；A4 = S5L8930X（上游现有最新的一代）。

---

## 0. 结论摘要

1. **做得成，目前没找到硬性阻断。**
   - 固件都能解：iOS 5 到 9 的 A5/A6 固件密钥都公开（fwkeydb 一直列到 iPhone 4S 9.3.6、iPhone 5 9.3.5）；**iOS 10 在 A6 上的固件镜像根本没加密**（iPhone 5 和 iPad 4 的 10.0 到 10.3.4，每个版本 16 个镜像都没有 KBAG）。【已核实】
   - 32 位机型没有 SEP、没有 KPP，一直用 IMG3，内核可以照现在 A4 的办法由 FirmwareKit 的 KBoot 直接引导，不用模拟 iBoot。【KBoot 部分已核实；SEP、KPP 为第三方资料加推测】
   - QEMU 有 Cortex-A9，ARM 客体支持多线程 TCG；A6 的 Swift（ARMv7s）在指令集上只是 ARMv7 加 VFPv4 和硬件除法，可以照 Cortex-A15 定一个新型号。【已核实】
   - GPU 不用模拟：A5/A6 上 iOS 8 到 10 的界面仍是 OpenGL ES 2.0（Metal 要 A7），可以沿用现在「在客体里换掉 OpenGLES、把调用转给宿主」的做法。【推测；iOS 10 有一个装载上的坎，见 3.4】
2. **但这是一次全新 SoC 移植，不是改配置。** A5 换成了苹果自己的中断控制器 AIC（A4 是 4 个 PL192），系统定时器在 AIC 里，双核，闪存换成 PPN 而且仍由 IOP 协处理器驱动，内存从 0x40000000 挪到 0x80000000。**公开世界里没有任何人模拟过 A5/A6，也没有人在模拟器里跑起过 32 位 iOS 8 到 10。** nexttouch 目前只有选单和目录，作者自己写「no new emulation yet」。【已核实，截至 2026-11-02 的 GitHub 和网页检索】
3. **第一台建议 iPod touch 5（n78ap，A5 32 nm，S5L8942X）。** 同芯片的 iPad mini 1 有 Project Cascadia（GPL-2.0，在 A5 上跑主线 Linux）留下的大量实机硬件笔记；没有基带；屏幕 640×1136 是手机形状；系统 6.0 到 9.3.5，可以先用 6.1、7.1.2 这些在 A4 上已经调通用户态的版本验证新机型，再爬 8.4.1、9.3.5。iOS 10 只能等第二台 iPhone 5（A6）。备选是 iPhone 4S（屏幕和 iPhone 4 一样、能跑 iOS 5，但有高通基带、同芯片资料少）。
4. **工作量（一个人加 AI 会话）【推测】：** A5 开到 iOS 9 主屏，乐观 4 到 6 周，中位 2.5 到 4 个月；做到「能玩」再加半个月到 2 个月；在此基础上 iPhone 5 跑 iOS 10 再加 1 到 3 个月。对照：上游作者从零做 A4 到 iOS 7 只用了约 10 天，但他有 iPod/3GS 的现成代码、openiBoot 和 iEmu 留下的 A4 寄存器资料，还有一台随便折腾的真 iPad；A5 这三样我们都缺或只有一部分。
5. **性能【推测】：** 有 JIT 时，iPhone 18 Pro 上 iOS 9 约 45 到 90 秒到锁屏，主屏静止约半个到大半个核，拖动翻页和现在 iOS 7 同档（30 到 60 帧）；体验大致相当于当年真机跑 iOS 9/10，本来就偏卡。没有 JIT 不能用。
6. **最大的三个风险：**
   ① **存储**：PPN 闪存加 IOP 协处理器加苹果的 Swiss PPN FTL 格式，上游没有现成模型，FirmwareKit 的 NAND 生成器只会 A4 的 YAFTL 格式；
   ② **没有真机参照**：上游做 A4 靠真 iPad 读寄存器、拿 NAND 镜像和串口日志；
   ③ **iOS 9/10 的代码签名和 GL 装载**：iOS 10 的 dyld 只在「开发版共享缓存」上才允许文件覆盖缓存里的库，我们现在装 GL 前端的方式在 iOS 10 上失效，要换方案；AMFI 在 iOS 8 到 10 是否还认放宽签名的启动参数也没核实。
7. **建议的第一步：** 派一个会话做「第 0 步」：下载 iPod touch 5 的 9.3.5（1.61 GB）和 7.1.2（1.29 GB）固件（要用户批准），用公开密钥解出内核和设备树，清点全部设备节点、内核扩展和版本，回答 6.4 节的 6 个待查问题，不写模拟器代码。之后在 Mac 上做新机型骨架，目标是「内核在串口打印，停在 Waiting for root device」。
8. **要用户拍板的事：** 第 0 步的下载；要不要买一台二手 A5（iPod touch 5 或 iPad mini 1，外加一块树莓派 Pico 做 checkm8）或 A6（iPhone 5，Mac 直接 checkm8）当参照机；接受长期维护一套上游不会收的机型代码。

---

## 1. 哪台机型先做

### 1.1 候选

| 机型（板号） | 芯片 | CPU | GPU | 内存 | 屏幕 | 系统范围 | 基带 | 现成硬件资料 |
|---|---|---|---|---|---|---|---|---|
| iPhone 4S（n94ap） | A5 S5L8940X | 2×Cortex-A9 800 MHz | SGX543MP2 | 512 MB | 640×960 | 5.0 到 9.3.6 | 高通 MDM6610 | 无专门资料 |
| iPad 2（k93ap 等） | A5 S5L8940X（iPad2,4 是 8942） | 2×A9 1 GHz | SGX543MP2 | 512 MB | 1024×768 | 4.3 到 9.3.5 / 9.3.6 | Wi-Fi 款无 | 无专门资料 |
| **iPod touch 5（n78ap）** | **A5 S5L8942X** | 2×A9 800 MHz | SGX543MP2 | 512 MB | **640×1136** | **6.0 到 9.3.5** | **无** | Cascadia（同芯片） |
| iPad mini 1（p105ap 等） | A5 S5L8942X | 2×A9 1 GHz | SGX543MP2 | 512 MB | 1024×768 | 6.0 到 9.3.5 / 9.3.6 | Wi-Fi 款无 | Cascadia 就是这台 |
| iPad 3（j1/j2） | A5X S5L8945X | 2×A9 1 GHz | SGX543MP4 | 1 GB | 2048×1536 | 5.1 到 9.3.5 / 9.3.6 | 部分有 | 少 |
| iPhone 5（n41ap/n42ap） | A6 S5L8950X | 2×Swift 1.3 GHz | SGX543MP3 | 1 GB | 640×1136 | 6.0 到 10.3.4 | 高通 MDM9615 | 只有 A6X 的设备树地图 |
| iPhone 5c（n48/n49） | A6 S5L8950X | 同上 | 同上 | 1 GB | 640×1136 | 7.0 到 10.3.3 | 有 | 同上 |
| iPad 4（p101 到 p103） | A6X S5L8955X | 2×Swift | SGX554MP4 | 1 GB | 2048×1536 | 6.0 到 10.3.3 / 10.3.4 | 部分有 | Cascadia issue #6 的完整地图 |

- 芯片、GPU、内存、频率：维基百科 Apple A5 / Apple A6 条目【已核实】。
- 系统范围：fwkeydb 里 iPhone4,1（9A334 到 13G37）、iPad2,1（8F191 到 13G36）、iPod5,1（10A406 到 13G36）、iPhone5,2（10A405 到 14G61）、iPad3,4（10A407 到 14G61）的版本目录【已核实】；iPad mini 1、iPad 3、iPhone 5c 的范围按公开常识【推测】。
- A6X 的 CPU 是 Swift、触摸挂在 spi3、GPU 是 SGX554MP4、Wi-Fi 是 HSIC 上的 BCM4334：Cascadia issue #6，一位贡献者从越狱的 iPad 4（iOS 10.3.4）上读的【作者自述】。

### 1.2 推荐 iPod touch 5，理由

1. **资料最多。** Cascadia 在同芯片的 iPad mini 1 实机上摸清了：AIC1 中断控制器和它的定时器、第二个核怎么放出复位（PMGR `+0x1214`、`+0x1220`，核从物理地址 0 起跑）、PL310 L2、PMGR 门控（`0x3F101008 + id×4`）、PMGR 看门狗块里唯一的 24 MHz 自由计数器、H2FMI 加 PPN 闪存的整条读路径、Z2 触摸上电、I2C/SPI/GPIO、扬声器、PMU、电池电量计、SGX543 上电序列，还写了从苹果设备树（ADT）转 Linux DTS 的工具。【作者自述；仓库里对应的文档和驱动文件已核实存在】
2. **没有基带。** 上游的基带模型是英飞凌 SPI 协议（iPhone 3GS/4 用），iPhone 4S/5 的高通基带完全不同；iPod 不用处理基带激活，也不用藏 CommCenter。【推测】
3. **屏幕形状。** 640×1136 在现代 iPhone 上留黑边最少；平板（1024×768）在手机上会缩得很小。
4. **版本阶梯能把问题分开。** iPod touch 5 最早是 6.0，6.1.x 和 7.1.2 的用户态（GL 前端、激活、客体工具包、只读根分区）上游已在 A4 的 iPod touch 4 和 iPhone 4 上打通。先用这两个版本把「机器模型的问题」和「新系统的问题」分开，再爬 8.4.1、9.3.5。

缺点：最高 9.3.5（9.3.6 只是 GPS 修复，无所谓）；板级外设（屏幕面板、PMU、音频编解码器）和 iPad mini 不完全一样，要按 iPod 5 自己的设备树来。iPad mini 1 可以当「同芯双胞胎」，遇到 SoC 级问题直接查 Cascadia。

**备选 iPhone 4S。** 如果用户更想要「iPhone」和 iOS 5：屏幕和 iPhone 4 一样，App 现成；5.1.1 到 7.1.2 可以和现有 n90 逐版对照。代价是要关掉高通基带并处理 iPhone 的激活；S5L8940X 没有直接资料（它和 8942 是同一设计的 45 nm / 32 nm 版本，寄存器大概率一样【推测】）。nexttouch 选的就是 4S 加 iPad 2 Wi-Fi 当调试双胞胎【作者自述】。

**iOS 10 只有 A6/A6X 能跑。** iPhone 5 是第二台。从 A5 到 A6：CPU 要换 Swift 型号（好做）；外设有一批变化（L2 不再是外置 PL310、触摸从 spi1 挪到 spi3 等）；按「半个新 SoC」估。

---

## 2. 要补哪些硬件

### 2.1 地址布局：换了基址，偏移有不少没变

| 块 | A4（`include/hw/arm/s5l8930.h`）【已核实】 | A5 iPad mini 1（Cascadia `ADDRESSES.md`）【作者自述】 |
|---|---|---|
| DRAM | 0x40000000 | 0x80000000 |
| 中断控制器 | VIC0 0xBF200000（4 个 PL192） | AIC 0x3F200000 |
| PMGR | 0xBF100000 | 0x3F100000 |
| GPIO | 0xBFA00000 | 0x3FA00000 |
| UART0 | 0x82500000 | 0x32500000 |

PMGR、GPIO、UART0、中断控制器的低 28 位都一样，三星血统的块（UART、SPI、I2C、GPIO、PMGR 布局）看起来是跟着总线整体挪了，而不是重新设计【推测】。A6X 的 AIC 也在 0x3F200000【作者自述】。iPhone 4S 实机的 ioreg 里 AIC 在 arm-io 内 0xF200000，兼容串 `aic,1`【第三方实机数据（GitHub gist）】。

### 2.2 逐项

难度：低 = 几天以内，中 = 一到几周，高 = 几周以上而且有未知数。

| 部件 | A4 现在怎么做（qemu-ios） | A5/A6 要做什么 | 资料 | 难度 | 能先放空吗 |
|---|---|---|---|---|---|
| CPU | `cortex-a8` 单核 | A5：QEMU 现成 `cortex-a9`（xnu 认作 CPUFAMILY_ARM_14）。A6：新建 Swift 型号，指令特性照 A15（VFPv4、ARM/Thumb 硬件除法、多核扩展），MIDR 厂商 0x61、部件号 0x0 | xnu `osfmk/arm/cpuid.h`、`cpuid.c`；LLVM `ARM.td` 的 `swift` 定义【已核实】 | 低 | 否 |
| 双核 | 机型已有 AP 加 IOP 两个 CPU，`max_cpus = 2` | A5 有 SCU；第二核由 PMGR 放出复位，从物理 0 起跑；核间中断走 AIC。QEMU 的 ARM 客体 `mttcg_supported = true`，两个 vCPU 各占一个宿主线程 | Cascadia `p105-smp-bringup.md`；`target/arm/cpu.c`【已核实】 | 中 | 可以：设备树只留 cpu0，先单核开机【推测】 |
| 中断控制器 | 4 个 PL192 菊链 | 新写 AIC 模型：xnu 开源的 `AIC.h` 给了全部寄存器名和偏移（Rev、Cap0、GlbCfg、MainTim、WhoAmI、Iack 及向量类型、IPI 置位清除、Tmr 配置计数），每条线的屏蔽和目标核按 Cascadia 的 AIC1 驱动 | xnu `pexpert/pexpert/arm/AIC.h`【已核实】；Cascadia `irq-apple-aic1.c`【作者自述】 | 中 | 否 |
| 系统定时器 | PMGR 里的三星定时器 | iOS 在 A5 上不用 Cortex-A9 的全局定时器，用 AIC 的计时和「共享时间戳」（内核扩展 AppleInterruptController 处理 `kAICIackVecTypeTimer`）；PMGR 看门狗块里有 24 MHz 计数器 | Cascadia `p105-xnu-timer-re.md`【作者自述】 | 中 | 否 |
| PMGR、时钟、电源域、调频 | `s5l8930_pmgr.c` | 新 PMGR：门控寄存器、时钟表、性能状态；KBoot 的 clock-frequencies 表要按 A5 重填 | Cascadia `p105-pmgr-gates.md`、`p105-xnu-pmgr-extract.md`；设备树 | 中 | 多数可以「写了就当成功」 |
| 芯片 ID、安全信息 | chipid 模型 | chip-id 0x8942/0x8950、board-id、安全纪元；kboot 下只需内核读到的那些 | 设备树 | 低 | 否 |
| UART、SPI、I2C、GPIO、PWM | 三星血统，A4 都有 | 地址换了，寄存器大概率相近；iOS 5 起兼容串改成 `*-1,samsung`，上游在 A4 的 iOS 5 到 7 上已经适配过 | Cascadia 的 `i2c-s5l8940x.c`、`spi-s5l8940x.c`、`pinctrl-s5l8940x-gpio.c` | 低到中 | 否 |
| PMU（电源管理芯片，I2C） | D1815 等 | iPad mini 的 PMU 在 I2C0 的 0x3c；iPod 5 的具体型号待查 | Cascadia（背光、充电、关机都经它）；设备树 | 中 | 多数可以桩 |
| 显示 | `s5l8930_display.c`（DisplayPipe、CLCD、RGBOUT、DSIM、DART2） | 新一代显示管线，iPod 5 是 640×1136 的 MIPI 面板（A6X 是 eDP）；QuartzCore 按显示驱动的类名挑渲染服务器，类名变了 GL 前端的显示通路要跟 | Cascadia `p105-fb.md`；设备树 | 中到高 | 否，但可以先简化成固定帧缓冲 |
| GPU | 不模拟 SGX535：客体里换掉 OpenGLES，调用转宿主（`contrib/gles-public` 加 `hw/arm/gles-host*.c`） | 同样不模拟 SGX543/554。要做：设备树的 sgx 节点处理；GL 前端认 8.x 到 10.x 的 OpenGLES 和派发表（7.1.2 是 1035 槽，已能按 @encode 自动推导）；能力上限按 SGX543 报；iOS 10 换装载方式（3.4） | gles-public README【已核实】；dyld 源码【已核实】 | 中，iOS 10 高 | 否：iOS 7 起没有宿主 GL 时 SpringBoard 一建上下文就崩（我们 M1 第四步实测） |
| **存储** | H2FMI 原始 NAND 加 IOP（默认跑真 IOP 固件），FirmwareKit 离线生成 YAFTL/VSVFL 格式的闪存镜像 | A5 是 PPN 闪存（芯片内带控制器，自报「PPN」1.5.5）。iOS 的栈：`fmi,s5l8920x` → AppleIOPFMI（IOP 协处理器）→ AppleSwissPPNFTL → disk0 → LwVM → HFS+。要：IOP 侧的新协议或新 IOP 模型、PPN 命令集、Swiss PPN FTL 格式的离线生成器（或让内核自格式化后再灌系统） | Cascadia `p105-nand.md`（读路径全套、命令序列）【作者自述】；上游 `gap-nand-genesis-decision.md` 的生成器思路【已核实】 | **高（最大一项）** | 早期可以用内存盘开机（KBoot 已支持 md0），但 iOS 9 系统分区约 1.5 GB，放不进 512 MB 内存，只能用裁过的系统【推测】 |
| 加密引擎、数据保护 | CDMA 的 AES 过滤、SHA1、PKE；伪造 UID 派生键 | A5 的 AES/SHA 块位置和协议待查；iOS 8 起数据分区逐文件加密，keybag 一次性制作（`it_keybag`）要跟到 8 到 10 | 设备树、内核 | 中到高 | 否：/private/var 挂不上就到不了 SpringBoard |
| 触摸 | Zephyr2（`ipod_touch_multitouch.c`） | 仍是 Z2（iPad mini 在 spi1，A6X 在 spi3，`AppleMultitouchSPIZ2F13`）；固件从 IPSW 取 | Cascadia `p105-z2-boot.md` | 低到中 | 否 |
| 音频 | CS42L61、Mikey、I2S、CDMA | 换编解码器和 I2S/DMA 代际 | Cascadia `p105-audio.md` | 中 | 可以先没声音 |
| USB | DWC OTG（usbmux/AFC）、EHCI/OHCI | 同是 Synopsys dwc2；我们 App 不靠 usbmux | Cascadia | 低 | 可以 |
| Wi-Fi、蓝牙 | BCM4329，走 IOP 的 SDIO 环 | A5 是 BCM4334，iPad mini 上走 HSIC 挂在 EHCI 上，不是 SDIO | Cascadia | 高 | 可以（App 里先没网） |
| 基带 | 英飞凌 SPI 模型（n90） | iPhone 4S/5 是高通，模型不能用；iPod、iPad Wi-Fi 款没有 | | 高 | 可以：设备树里把节点兼容串改成 none，n90 现在就这么做 |
| 传感器 | 加速度计、指南针、光感 | iPad mini 的加速度计是 LIS3DSH；陀螺仪是新的 | Cascadia `p105-sensors.md` | 低到中 | 可以先固定朝向 |
| L2 缓存 | 无 | A5 有 PL310（QEMU 有 l2x0 模型）加苹果自己的 CIF 小块；A6 集成在内存子系统里 | Cascadia | 低 | 否（驱动会配它） |
| 相机、ISP、JPEG、视频解码 | 部分有 | 放空 | | | 可以 |

### 2.3 资料来源的分量

- **xnu 开源代码**（xnu-4570 起带 32 位 ARM）：给了 AIC 寄存器、CPU 识别、comm page 怎么填，但 S5L8940X/8950X 的板级配置被删掉了，只剩 Apple Watch 的 S7002/T8002。【已核实】
- **Project Cascadia**：A5 最有价值的公开资料，来自实机，GPL-2.0，可以直接参考它的驱动写模型。注意它的很多寄存器序列是从用户自己解密的 iBEC 二进制里反汇编读出来的，不是泄露源码；我们照它写模型属于参考公开项目的 GPL 代码和文档。泄露的 iBoot 源码按简报不碰。【已核实仓库内容，结论为作者自述】
- **设备树和内核扩展本身**：IPSW 里的 DeviceTree、kernelcache（密钥公开）是每台机器的「真相」，上游做 A4 的每一步也都是从这里读的。第 0 步就是把它们清点出来。
- **theiphonewiki / theapplewiki**：本次两个站点都没取到（403、504），用 fwkeydb 和 ipsw.me 代替。

---

## 3. 启动链和系统

### 3.1 qemu-ios 现在怎么开机【已核实】

两条路：

1. **真启动链**：SecureROM → LLB → iBoot → 内核。iPod touch 2 代要苹果的 bootrom（我们用 4 字节占位绕过了冷启动）；iPad 1 也能走真 iBoot-817（上游 M8）。
2. **kboot**：FirmwareKit 的 `KBoot.swift` 替 iBoot 做跳内核前的事：解密内核缓存；按 iBoot 的方式填设备树（内存图、chosen、时钟表、身份信息、MAC 地址、`nvram-proxy-data`）；造 boot_args（版本号从内核自己的检查里读出，iOS 4.3 起是 3）。机器把这个包放进内存，关着 MMU 跳到内核入口。iPhone 4、iPod touch 4 只走 kboot。iOS 6/7 上的几个坑（Epoch Mismatch、内核要映射物理地址 0、NVRAM 代理数据全零导致死循环）都已在 kboot 里解决（`docs/n90/README.md`）。

kboot 会把 chosen 里的 `debug-enabled`、`production-cert`、`secure-boot` 等设成 1（真机是 0），再配上启动参数 `amfi_allow_any_signature=1 cs_enforcement_disable=1`，这样内核才肯放宽代码签名，客体里的 GL 前端和 agent 才能跑（`KBoot.swift` 第 40、416 行）。

### 3.2 A5/A6 能不能照做：能，只走 kboot

iBoot 路线要模拟 DRAM 控制器、精确的 PMGR、签名和安全纪元检查。上游在 A4 上试 iBoot-1219（iOS 5）就卡在 `miu_init: Epoch Mismatch` 和 PMU 关机路径（`docs/ipad1/ios5.md`）【已核实】。kboot 按 A5 要改的：内存基址 0x80000000、内存大小（512 MB / 1 GB）、时钟表、板号和芯片号、显示参数、设备树的 NOR/NVRAM 处理。【推测】

### 3.3 32 位 iOS 8 到 10 有没有挡模拟器的东西

| 东西 | 情况 | 标注 |
|---|---|---|
| SEP（安全隔区） | A7 才有，A5/A6 没有 | 【推测（公认常识）】 |
| KPP（内核补丁保护） | iOS 9 引入，只在 arm64 设备上；32 位内核可以随便改，最差由模拟器在启动时改内核内存 | 【第三方资料：iOSRE wiki、Promon】 |
| 个性化签名（IMG4、APTicket 绑定） | 32 位一直是 IMG3；kboot 不经过 iBoot 验签 | 【已核实：fwkeydb 里 A6 的 10.3.4 镜像文件名仍是 `.img3`】 |
| 代码签名 | A4 的 3.2 到 5.1.1 内核里，AMFI 的四个放宽参数只在 debug-enabled 非零时生效，5.1.1 还在读（`docs/ipad1/ios5.md` 的表）；kboot 已设 debug-enabled | 3.2 到 5.1.1【已核实】；8 到 10 是否还读【推测：开发熔丝的真机要用，大概率还在】；不行就像越狱那样在内核里改 AMFI |
| 专门的模拟器检测 | 没找到。真正的风险是「驱动等不到硬件就 panic 或卡死」，这是模型保真度问题，A4 上一样遇到过 | 【推测】 |
| 文件系统 | 32 位设备升 10.3 不转 APFS，仍是 HFS+。nexttouch 路线图说 A6 要处理 APFS，我认为不对 | 【第三方报道（MacStories）加推测】 |
| 分区 | iOS 5 起用 LwVM，上游在 A4 的 5 到 7 已处理 | 【已核实】 |
| launchd | iOS 8 换了新 launchd，守护进程和环境变量的加载方式可能变；上游现在靠往 LaunchDaemons 放 plist、改 SpringBoard 的环境变量来装客体工具，8 到 10 上要重新确认 | 【推测，第 0 步查】 |
| 激活 | iPod 不需要基带；上游对 7.1.2 用预先烤好的激活状态（FactoryActivated），8 到 10 要重试 | 【推测】 |

### 3.4 GL 前端在 iOS 8 到 10 上怎么装进去【dyld 源码已核实，出路为推测】

现在的做法：把 gles-public 编出来的 OpenGLES 放到系统原来的位置，再放一个 `/System/Library/Caches/com.apple.dyld/enable-dylibs-to-override-cache` 文件，dyld 就用文件里的库代替共享缓存里的那份（gles-public README）。

dyld 源码里这个开关的条件：

| dyld 版本 | 对应系统 | 条件 |
|---|---|---|
| 239.4 | iOS 7 | 文件存在 |
| 353.2.1 | iOS 8 | 文件存在，且小于 `ENABLE_DYLIBS_TO_OVERRIDE_CACHE_SIZE` |
| 360.22 | iOS 9 | 同上 |
| 421.2、433.5 | iOS 10 | 改成 `dylibsCanOverrideCache()`：comm page 的 `_COMM_PAGE_DEV_FIRM` 第 0 位为 1，**并且**共享缓存类型是 development |

**更正（2026-11-02，第 0 步）：** iPod touch 5 的 9.3.5 实际带的是 dyld-390.7，已经有下面 iOS 10 这条检查，共享缓存头 `cacheType` = 1，所以覆盖开关在 9.3.x 上就已失效，不是 iOS 10 才开始。详见 `docs/research/ios8-10-step0.md` 4.3 节。

`_COMM_PAGE_DEV_FIRM` 由内核填成 `PE_i_can_has_debugger(NULL)`（xnu `osfmk/arm/commpage/commpage.c` 第 104 行），kboot 设了 debug-enabled，这一条能满足。但正式 IPSW 带的是生产版共享缓存，**所以 iOS 10 上覆盖不生效，iOS 8、9 照旧可以**。

iOS 10 的出路（都没试过）：

1. 用 `DYLD_INSERT_LIBRARIES` 插一个带 interpose 的库，把 GL 入口接过来。要确认 AMFI 不剥掉系统进程的 DYLD 环境变量，以及 App 进程也能注入。
2. 改共享缓存头里的类型字段。缓存带代码签名，要配合 AMFI 放宽，或者由模拟器在缓存映射后改客体内存。
3. 在更低一层接，例如换掉 SGX 的 gld 驱动包。iOS 5 起 GLEngine 和 SGX 驱动都已进了共享缓存（`docs/ipad1/ios5.md`：「bundle dirs empty on disk」），这条大概走不通。

估计 iOS 10 单独这块要 1 到 2 周【推测】。

### 3.5 固件密钥公开到什么程度

| 系统 | A5（4S、iPad 2、iPod 5、iPad mini） | A6（iPhone 5）、A6X（iPad 4） | 来源 |
|---|---|---|---|
| iOS 5 到 7 | 每个版本都有 | 6 到 7 每个版本都有 | fwkeydb 版本目录【已核实】 |
| iOS 8.4.1（12H321） | 内核、设备树、iBoot 有密钥；ipsw.me 没有根文件系统密钥 | 同左 | ipsw.me、fwkeydb【已核实】 |
| iOS 9.3.5（13G36） | 16 个镜像都有 KBAG 和密钥；根文件系统密钥 ipsw.me 对 4S、iPad 2、iPod 5、iPad mini 有 | 镜像密钥有；iPhone 5、iPad 3 没有根文件系统密钥 | 同上【已核实】 |
| iPhone 4S 9.3.6（13G37） | fwkeydb 有 | | 【已核实】 |
| iOS 10.0 到 10.3.4 | 不适用 | **16 个镜像全部没有 KBAG，即没加密**（14A403、14G61，iPad3,4 的 14G61 都查了）；ipsw.me 对 14G61 没有条目，对 14A403 到 14G60 列了条目但密钥是空的，原因同此 | fwkeydb、ipsw.me【已核实】 |

- 缺根文件系统密钥的几个：iOS 8/9 的根文件系统密钥历来能用公开工具（genpass）从解密后的恢复内存盘算出来【推测，第 0 步验证】；iOS 10 的根文件系统不加密【推测】。
- nexttouch 路线图把「A6 的 iOS 10 没有公开密钥」列为待定问题、说可能要用 checkm8 从真机提取【作者自述】。按 fwkeydb 的数据，这件事已经有答案：根本不用密钥。
- 和现在一样，App 只存密钥和苹果的下载地址，在手机上下载后自己解，我们不分发任何苹果的东西（Light Touch 的固件表就带 `keys` 字段）【已核实】。
- 真机 checkm8：A6/A6X 可以直接用 ipwndfu（支持 s5l8950x、s5l8955x）；A5/A5X 在 ipwndfu 的「未来支持」里，实际要用 checkm8-a5，配 Arduino 加 USB Host Shield 或树莓派 Pico（Cascadia 用的是 Pico）【已核实：ipwndfu README、Legacy-iOS-Kit wiki】。只在要从真机读寄存器、拿 NAND 镜像时才需要。

---

## 4. 前人做过多少

| 项目 | 做了什么 | 和 A5/A6、32 位 iOS 8 到 10 的关系 | 标注 |
|---|---|---|---|
| c12n/nexttouch | 2026-11-01 建仓，当天发 v0.1.0：Rust 写的目录、选单、设置，Windows/Android/iOS 三个壳；iOS 8/9/10 条目全部标「Not booting yet」 | 只有路线图（4S 9.3.5、iPhone 5 10.3.4、六个开机里程碑），仓库里没有任何引擎代码；作者明说「no new emulation yet」「qemu-ios engine implements no SoC newer than the A4」 | 仓库内容【已核实】；计划【作者自述】 |
| samhenrigold/qemu-ios、LightTouchMac | 8 种机型，最高 A4 和 iOS 7.1.2 | README 明说不做比列表更新的机型、不做 iOS 版；固件表 329 条全在这 8 个板号上，没有 A5/A6 的条目或「coming_soon」 | 【已核实】 |
| blake-lucas/LightTouch、blake-lucas/qemu-ios | Light Touch 的分支，跑在 Android、Linux、Windows、macOS；做了不少引擎提速（上游最近几次提交就是从这里移植的） | 只到 iOS 7，没有 iOS 版 App，没有 A5 | 【已核实（README）】 |
| mada-02/iOS-Emulator | 「An iOS 1-7 emulator」 | 无 | 【已核实（仓库描述）】 |
| devos50/qemu-ios | iPod touch 1、2 代，qemu-ios 的源头 | 无 | 【已核实（之前的调研）；没搜到 A5 相关】 |
| rzxvx/Project-Cascadia | 在 A5 的 iPad mini 1 上跑主线 Linux 6.12：双核、中断、定时器、触摸、Wi-Fi、蓝牙、音频、XFCE、NAND 只读、SGX543 的内核驱动加 Mesa；另有 A13；issue #6 有 A6X 的硬件地图 | 不是模拟器，但是 A5 硬件最好的公开资料 | 仓库内容【已核实】；功能【作者自述】 |
| winocm/xnu（2013 到 2017） | 把开源 Darwin 内核移植到 ARMv7/ARMv6/AArch64，能在 QEMU 的开发板上跑 | 只有开源内核，不是 iOS 的内核缓存和系统 | 【已核实（仓库描述）】 |
| Corellium（商业） | 虚拟 iPhone | 最老机型 iPhone 6，最低 iOS 10，没有 32 位 | 【已核实（官方支持页）】 |
| QEMUAppleSilicon、qemu-t8030、Inferno-iOS、alephsecurity xnu-qemu-arm64 | iPhone 6s/X/11 等 64 位机型 | 64 位，和我们无关；qemu-t8030 是直接在内核里补 AMFI，不靠启动参数 | 【已核实（之前的调研和 qemu-t8030 wiki）】 |
| iEmu、QEMU-s5l89xx-port（2012） | 早年模拟 S5L89xx 的尝试 | 失败，没到 A5 | 【第三方（Emulation General Wiki）】 |

检索范围：GitHub 代码搜索 `s5l8940`、`s5l8950`（只有越狱工具、bootrom 漏洞工具和资料）；GitHub 仓库搜索；网页搜索「QEMU A5 S5L8940 iPhone 4S」「32 位 iOS 9/10 模拟」等。**没找到任何公开的 A5/A6 模拟器，也没找到 32 位 iOS 8 到 10 在模拟器里开机的公开记录。**

---

## 5. 性能

### 5.1 已有数据（iPhone 4，A4 单核，iOS 7.1.2）【已核实】

| 项目 | 数值 | 来源 |
|---|---|---|
| Mac M4 Max，JIT，开机到锁屏 | 40 秒（客体主核 35.5 CPU 秒） | `docs/reports/m0-mac-benchmark.md` |
| Mac，纯解释器（TCI），开机到锁屏 | 407 秒（11.2 倍） | 同上 |
| iPhone 18 Pro，JIT，到锁屏 / 到主屏 | 29 秒 / 37 秒 | `docs/reports/m2-gl-eagl.md` |
| 18 Pro，主屏静止 | 41% 一个核（读回约 13%，客体约 20%，合成发帧约 7%） | `docs/reports/m2-ios7-perf.md` |
| 18 Pro，锁屏拖动 / 主屏按住拖 / 翻页动画 | 60 / 49 / 36 帧 | 同上 |
| App 内存占用 | 1.03 到 1.11 GB（客体 512 MB） | `docs/reports/m2-gl-eagl.md` |

### 5.2 估算【推测】

假设：

- JIT 下一个客体核大致跑到真机 A4 的速度（18 Pro 上 iOS 7 29 秒到锁屏，和当年真 iPhone 4 同一量级）。
- iOS 9 开机的总工作量约为 iOS 7 的 1.5 到 2 倍，其中一部分能分到第二个核。
- 双核时有两个 vCPU 线程，加上 QEMU 主线程、App 主线程；A20 Pro 大概是 2 个性能核加 4 个能效核，会有线程被挤到能效核上；GL 转发也跑在 vCPU 线程上。
- 读回成本按像素算：640×1136 比 640×960 多 18%。

| | iOS 9.3.5（iPod touch 5，A5 双核） | iOS 10.3.4（iPhone 5，A6 双核，1 GB） |
|---|---|---|
| 开机到锁屏 | 45 到 90 秒 | 50 到 100 秒 |
| 主屏静止 CPU（一个核 = 100%） | 50% 到 80% | 55% 到 90% |
| 拖动、翻页 | 30 到 60 帧，主要看 GL 读回 | 同左 |
| 开 App | 2 到 4 秒 | 2 到 5 秒 |
| App 内存 | 约 1.1 GB | 约 1.6 到 1.8 GB |
| 没有 JIT | 开机十分钟以上，不能用 | 同左 |

补充：

- 两个 vCPU 线程会分 JIT 代码区，可能要从 256 MB 加到 512 MB；StikDebug 准备时间约从 0.7 秒变 1.5 秒。
- 也可以只模拟一个核跑（设备树只留 cpu0），线程少、对手机可能更友好，要实测才知道哪个好。
- iPhone 14 Pro 上大约再慢一倍，iOS 10 的 1 GB 客体内存会比较紧。
- 真机上 iOS 9 跑在 4S、iOS 10 跑在 iPhone 5 本来就慢，「回味」的预期要和用户说清楚。

---

## 6. 结论和路线

### 6.1 做不做得成

能。没有哪一项是「原理上做不到」：固件能解，内核能直接引导，没有 SEP 和 KPP，CPU 现成，GPU 走转发。问题是值不值、要多久。这是一个完整的新 SoC 移植，加上存储这块大活，再加 iOS 10 的 GL 装载问题。

### 6.2 工作量【推测】

| 阶段 | 内容 | 产出 | 乐观 | 中位 |
|---|---|---|---|---|
| 0 | 解包、清点设备树和内核扩展，回答 6.4 节的问题 | 清单文档 | 1 个会话 | 1 到 2 天 |
| 1 | 机型骨架：单核 A9、AIC 和定时器、PMGR 桩、UART、chipid，kboot 改 A5 | 内核横幅，停在 Waiting for root device | 1 周 | 2 到 3 周 |
| 2 | 存储：IOP、FMI、PPN 或替代方案，FTL 生成或自格式化，AES 和 keybag，PMU | launchd 跑起来，/private/var 挂上 | 2 到 3 周 | 1 到 2 个月 |
| 3 | 显示管线，GL 前端从 7.1.2 爬到 8.4.1、9.3.5，触摸，激活，客体工具包 | SpringBoard 出画面，能点 | 1 到 2 周 | 3 到 6 周 |
| 4 | 双核、声音、按键、睡眠唤醒、稳定性 | 能玩 | 1 到 2 周 | 3 到 6 周 |
| 5 | 接进 iPhone App：多线程 TCG 加 JIT、内存 | 手机上开 iOS 9 | 几天 | 1 到 2 周 |
| 6 | A6：Swift 型号、A6 外设差异、iOS 10 的 GL 装载 | iPhone 5 跑 iOS 10 | 3 到 4 周 | 2 到 3 个月 |

合计：A5 到 iOS 9 主屏乐观 4 到 6 周、中位 2.5 到 4 个月；能玩再加半个月到 2 个月；A6 和 iOS 10 再加 1 到 3 个月。按我们现在「一个会话推进一个小里程碑」的节奏，A5 到能玩约 40 到 100 个执行会话。

估算的参照：

- **上游 A4**：2026-09-26 新建 `ipad1` 机型，09-27 iOS 3.2 到主屏（那天 329 个提交），10-05 iPhone 4 的 iOS 7.1.2 通过整套检查，约 10 天。前提是现成的 iPod/3GS 代码、openiBoot 和 iEmu 的 A4 寄存器资料，以及一台真 iPad（limera1n 读寄存器、导出 NAND 和系统分区）。【已核实：git log、`docs/archive/ipad1-PLAN.md`】
- **上游 3GS / iPod touch 3 代机型**：10-04 首次提交，当天内核到 launchd（同一代 SoC 已有资料）。【已核实】
- **Cascadia**：2026-08-11 建仓，在真机上靠 checkm8 一步步摸，十月初才把 GPU 画出东西。【建仓日期已核实，进度为作者自述】
- **我们自己**：M0 到 M2 两天走完移植、JIT、EAGL、调优，但那是在现成机型上。

### 6.3 最大的三个风险

1. **存储（最大）。** A4 的路是：H2FMI 原始 NAND，IOP 跑真固件，FirmwareKit 离线生成 YAFTL 格式镜像。A5 换成 PPN 加 Swiss PPN FTL，上游没有模型，Cascadia 只做了只读。要么写 Swiss PPN FTL 的生成器，要么让内核用 `nand-enable-reformat` 自格式化再想办法灌系统，要么找捷径（见 6.4 第 2 问：如果 A5 的内核还带 YAFTL 那套，能否让它把模拟闪存当原始 NAND，直接复用现成生成器）。
   缓解：早期先用内存盘开到 launchd，存储并行做。
2. **没有真机参照。** 上游每次卡住都能去真 iPad 上读寄存器值、对日志；我们只有设备树、内核反汇编和 Cascadia 的笔记。
   缓解：买一台二手 iPod touch 5 或 iPad mini 1（价格没查），加一块树莓派 Pico 做 checkm8-a5（Cascadia 的整套工具可以直接用）；或者买 iPhone 5（Mac 直接 checkm8，顺便为 A6 准备）。这要用户决定。
3. **代码签名和 GL 装载在 9、10 上变了。** iOS 10 的 dyld 不再让文件覆盖生产版共享缓存（3.4），GL 前端得换装法；AMFI 在 8 到 10 是否认启动参数没核实，不认就要在内核里打补丁（32 位没有 KPP，可以做，但每个版本要找位置，违背上游「不按偏移手改」的原则，得用特征码自动找）。

其他值得记一笔的：双核在手机上的线程争用（5.2）；我们要长期维护一套上游不收的机型代码（上游 README 的范围声明写得很死）；nexttouch 宣称在做同一件事，目前是空架子。

### 6.4 建议的第一步

**第 0 步（一个会话，要用户批准下载约 2.9 GB）：** 从苹果服务器下载 iPod touch 5 的 9.3.5（13G36，1.61 GB）和 7.1.2（11D257，1.29 GB），用公开密钥解出内核缓存、设备树、恢复内存盘，回答这 6 个问题：

1. 设备树里所有节点的 `compatible`、`reg`、`interrupts`，和 iPhone 4 7.1.2 逐项对照：哪些驱动换了名字、哪些块是新的。
2. 内核缓存里的 NAND 栈：除了 AppleSwissPPNFTL，是不是还带 AppleNANDFTL（YAFTL/VSVFL）？IOP 固件和邮箱协议是哪一版？如果能让 A5 的内核把模拟闪存当原始 NAND 用，就能直接复用 FirmwareKit 的 A4 生成器，省掉最大的一块。
3. AMFI 还读不读 `amfi_allow_any_signature`、`cs_enforcement_disable`、`amfi_get_out_of_my_way`（FirmwareKit 的 FitCheck 就是做这个字符串检查的）。
4. 共享缓存里 OpenGLES 的 `__GLIFunctionDispatchRec` @encode 还在不在；QuartzCore 认哪个显示驱动类名。
5. iOS 9 的 launchd 怎么加载守护进程和环境变量（决定客体工具怎么装）。
6. 8.4.1、9.3.5 缺的根文件系统密钥能不能用公开工具从内存盘算出来。

**第 1 步（Mac 上，1 到 3 周）：** 新建 A5 机型骨架（单核 Cortex-A9、AIC 加定时器、PMGR 桩、UART、chipid），kboot 支持 A5 的内存布局。目标：iPod touch 5 的 9.3.5 和 7.1.2 内核都在串口打印横幅，停在 Waiting for root device。这一步不碰手机、不碰 App。

### 6.5 需要用户定的事

1. 做不做：这是几个月级别的长期轨道，不挡 M2 到 M4。
2. 第 0 步的下载（约 2.9 GB，苹果服务器）。
3. 第一台用 iPod touch 5（推荐）还是 iPhone 4S。
4. 要不要买参照机：二手 iPod touch 5 / iPad mini 1 加树莓派 Pico，或者 iPhone 5。
5. 代码怎么放：照现在的规矩，A5 机型以补丁形式放在 `patches/`；上游不会收，GPL 下自己维护没有问题。

---

## 7. 来源

本地（只读）：

- `upstream/qemu-ios`：`README.md`、`docs/n90/README.md`、`docs/ipad1/README.md`、`docs/ipad1/ios5.md`、`docs/archive/ipad1-PLAN.md`、`docs/research/ref-a4-soc.md`、`docs/research/web-sgx.md`、`docs/research/gap-unsigned-guest-code-3.2.md`、`docs/research/gap-nand-genesis-decision.md`、`contrib/gles-public/README.md`、`include/hw/arm/s5l8930.h`、`hw/arm/ipad1.c`、`hw/arm/s5l8930_h2fmi.c`、`target/arm/tcg/cpu32.c`、`target/arm/cpu.c`、`accel/tcg/tcg-all.c`，以及 `git log`。
- `upstream/LightTouchMac`：`README.md`（Scope）、`LightTouchMac/Resources/firmware-catalog.json`、`Packages/FirmwareKit/Sources/FirmwareKit/KBoot/KBoot.swift`。
- 本仓库：`docs/plan.md`、`docs/research/m1-iphone-feasibility.md`、`docs/reports/m0-mac-benchmark.md`、`docs/reports/m2-gl-eagl.md`、`docs/reports/m2-ios7-perf.md`。

GitHub（`gh api`）：

- [apple-oss-distributions/xnu @ xnu-4570.1.46](https://github.com/apple-oss-distributions/xnu/tree/xnu-4570.1.46)：`pexpert/pexpert/arm/AIC.h`、`board_config.h`、`osfmk/arm/cpuid.h`、`cpuid.c`、`osfmk/arm/commpage/commpage.c`、`pexpert/arm/pe_identify_machine.c`
- [apple-oss-distributions/dyld](https://github.com/apple-oss-distributions/dyld)：`src/dyld.cpp` @ dyld-239.4、353.2.1、360.22、421.2、433.5
- [tihmstar/fwkeydb](https://github.com/tihmstar/fwkeydb)：`keys/firmware/iPhone5,2/0x8950/*`、`iPhone4,1/0x8940/*`、`iPad2,1/0x8940/*`、`iPod5,1/0x8942/*`、`iPad3,4/0x8955/*`
- [rzxvx/Project-Cascadia](https://github.com/rzxvx/Project-Cascadia)：README、`docs/research/ADDRESSES.md`、`p105-nand.md`、`p105-xnu-timer-re.md`、[issue #6（A6X 硬件地图）](https://github.com/rzxvx/Project-Cascadia/issues/6)
- [c12n/nexttouch](https://github.com/c12n/nexttouch)：README、`docs/ROADMAP.md`、文件树
- [blake-lucas/LightTouch](https://github.com/blake-lucas/LightTouch)、[mada-02/iOS-Emulator](https://github.com/mada-02/iOS-Emulator)、[devos50/qemu-ios](https://github.com/devos50/qemu-ios)、[winocm/xnu](https://github.com/winocm/xnu)
- [axi0mX/ipwndfu](https://github.com/axi0mX/ipwndfu)：README（checkm8 支持的 SoC）
- [llvm/llvm-project @ llvmorg-17.0.6 `ARM.td`](https://github.com/llvm/llvm-project/blob/llvmorg-17.0.6/llvm/lib/Target/ARM/ARM.td)：`swift` 处理器定义

网页：

- [ipsw.me API](https://api.ipsw.me/v4/keys/ipsw/iPhone5,2/14G61)（密钥和固件包元数据）
- [Apple A5 - Wikipedia](https://en.wikipedia.org/wiki/Apple_A5)、[Apple A6 - Wikipedia](https://en.wikipedia.org/wiki/Apple_A6)
- [ioreg from iPhone 4S（gist）](https://gist.github.com/fergy/3844426)
- [Corellium iOS 支持页](https://support.corellium.com/devices/ios)
- [qemu-t8030 wiki：Bringing up the emulator](https://github.com/TrungNguyen1909/qemu-t8030/wiki/Bringing-up-the-emulator)
- [Legacy-iOS-Kit wiki：checkm8-a5](https://github.com/LukeZGD/Legacy-iOS-Kit/wiki/checkm8-a5)
- [iOSRE wiki：Kernel Patch Protection](https://github.com/kpwn/iOSRE/blob/master/wiki/Kernel-Patch-Protection-(KPP).md)、[Promon 越狱概览](https://promon.co/?p=1338)
- [iOS 10.3 与 APFS（MacStories 摘录）](https://pxlnv.com/linklog/apple-releases-ios-10-3/)
- [Emulation General Wiki：iOS emulators](https://emulation.gametechwiki.com/index.php/IOS_emulators)
