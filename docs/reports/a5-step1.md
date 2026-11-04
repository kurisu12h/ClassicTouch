# iOS 8 到 10 第 1 步：iPod touch 5（n78）机型骨架

- 日期：2026-11-03
- 做的事：在 Mac 上给 qemu-ios 加 A5 机型 `iPod-Touch-5G` 和 AIC 中断控制器模型，用 KBoot 包直接进内核，目标是内核在 uart1 打印、停在 Waiting for root device。没碰真机，没 commit、没 push。
- 产物：`patches/a5-n78-skeleton.patch`（对 qemu-ios b225694505，到 3.16 节为止 9 个文件 +2547/-61 行，含对上游 `s5l8930_cdma.c`、`s5l8930_display.c` 的改动），`tools/a5/` 下的脚本和 `README.md`（复现步骤）。大文件都在 `work/a5/`，不进仓库。
- 标注：【已核实】在这次的运行日志或二进制里直接看到；【推测】我的推断。

---

## 0. 结论摘要

> **最新（3.17 节，交接）：** 9.3.5 的 NAND 层在同一个 IOP 模型上原样可用，格式化和 FTL 打开都成功；两分区盘、dyld 覆盖、launchd 清单、GL 前端还没做。
>
> **3.16 节：** 接上触摸（spi1 上的 Zephyr2 传感器）和 GPIO 按键，用脚本经 QMP 注入输入，7.1.2 从锁屏滑动解锁进了主屏，点开了「设置」，按 Home 回到主屏。
>
> **3.15 节：** 7.1.2 开机直接进了锁屏。做了四件事：给 lockdownd 打本地激活补丁；补上 iPod touch 5 设置助理比 iPhone 4 多出的步骤标记（Siri 等）；把常让 backboardd 崩溃的两个罗盘 HID 插件移走；n78 接上 guest 包服务，GL 协议告警随之消失。
>
> **3.14 节：** 接上 GL 桥后，7.1.2 画出了界面：第 120 秒是 UI 画的苹果标志，第 180 秒到设置助理的「Hello / slide to set up」。原先反复崩溃的是 backboardd（第一次是 GL 陷入没接住的 SIGILL，其余在 CompassPlugIn 里，后者接上 GL 后仍间歇出现）。
>
> **3.13 节：** 做出了 NAND 这一层（IOP 高层模拟加 PPN 页存储），一次格式化开机后，正常开机时可擦除存储和 NVRAM 都起来了，越过了钥匙包。
>
> **3.12 节：** 7.1.2 的完整系统从 USB 盘（系统加数据两个分区）开起来了，launchd 拉起五十多个守护进程，然后 keybagd 报 `FATAL KEYBAG ERROR: kb_load` 要求进恢复模式。卡点是钥匙包要的可擦除存储（A5 上在 NAND 里）。USB 见 3.11 节，显示见 3.10 节，launchd 见 3.9 节。下面 1 到 4 条是第 1 轮的情况。

1. **两个内核都在模拟器里开口说话了。** 7.1.2（xnu-2423.10.71）和 9.3.5（xnu-3248.61.1，RELEASE_ARM_S5L8942X）都在 uart1 打出完整的开机日志：corecrypto 自检通过，AMFI 认了放宽签名的启动参数，`AppleS5L8940XIO`、背光、AppleKeyStore、GPIO 中断控制器、性能控制器依次启动。【已核实】
2. **内核认出了我们写的 AIC。** 日志里 `AppleInterruptController::start: _aicVersion = 0 ... _aicNumExtInts = 0x000000c0 _aicNumIPIs = 0x00000002`。【已核实】
3. **现在两个版本停在同一个地方：** 性能控制器启动后 panic `handleSwapCleanup - can't free 1 channels of dimension 0`（7.1.2 caller 0x8041648f，9.3.5 caller 0x80376575）。原因是 A5 的 PMGR 位置上暂时放的是 A4 的 PMGR 模型。**下一步就是写 s5l8940x 的 PMGR 模型。**【停止点已核实；原因是推测，但两个版本都紧跟在 `AppleS5L8940XPerformanceController::start` 之后】
4. **还没到的：** Waiting for root device、USB 盘挂根。第 1 步完成了大约一半。

## 1. 新增的东西

### 1.1 QEMU 机型 `iPod-Touch-5G`（`hw/arm/ipod_touch_5g.c`）

- 单核 Cortex-A9，512 MiB 内存在 0x80000000，PA 0 别名到内存第一页（照 A4，未验证 A5 是否需要）。
- arm-io 窗口 0x30000000 到 0x40000000 整个兜底成未实现设备，访问会记进 `-d unimp`。
- uart1 在 0x32600000（A4 的 uart 偏移加 A5 窗口基址），接 serial0；它的 AIC 中断线还没接，控制台走轮询。
- AIC 在 0x3F200000，PMGR 位置 0x3F100000 暂时放 A4 的 `s5l8930.pmgr`。
- 开机包格式和 A4 一样（K48KBOOT 尾部），装载代码照抄 `ipad1_cpu_reset`。

### 1.2 AIC（`hw/arm/s5l8940_aic.c`）

寄存器表取自 xnu-4570.1.46 `pexpert/pexpert/arm/AIC.h`（第一个带 32 位 ARM 的开源 xnu）。定时器的用法照同一版本 T8002 的代码：往 `kAICTmrCnt` 写倒计时，倒数到 0 走 **FIQ**，FIQ 处理里写 `kAICTmrIntStat` 清掉。外设中断走 IRQ，读 `kAICIack` 应答，并把这条线自动屏蔽，等驱动写 `kAICIntMaskClr`。

- 192 条外部中断：9.3.5 的 AppleInterruptController 按 AicCap0 报告的数量核对设备树 `ipid-mask` 的长度（24 字节，正好 6 个 32 位字），报 256 时 panic `ipid-mask property length is 24 but should be 32`。设备树里 CPU 节点用的 0xc0 到 0xc3 正好在 192 之后，就是核间中断号。【已核实】
- 自动屏蔽和核间中断的置位、清除编码是推测，还没对照 9.3.5 的 AppleInterruptController 核实。定时器有没有真正走起来，这次也没专门验证。

## 2. 开机包要比 A4 多做的三件事（`tools/a5/n78_kboot.py`）

1. **内存基址 0x80000000，V=P**：7.x 和 9.x 内核都链接在 0x80001000。【已核实】
2. **清掉属性长度的最高位**：苹果设备树用长度字段的第 31 位标记「等 iBoot 从 syscfg 填写」，iBoot 填完会清掉。解析器读的时候屏蔽了这一位，内核没有。9.3.5 的 `/chosen` 里有两个（`marketing-hardware-behavior`、`marketing-software-behavior`），内核遍历属性时把这一位算进长度，一下跳到设备树外 2 GiB，第一条指令就数据中止（PC 0x8038783c，DFAR 0x0124dbbc）。7.1.2 没有这样的属性。【已核实】
3. **`/chosen/random-seed` 填 64 字节**：iBoot 会填随机数，IPSW 里是全 0。9.3.5 见到全 0 就 panic `EntropyData needed 64 bytes, but got 0`。现在由机器的 ECID 算出来，方便复现。【已核实】

其余照 A4：`platform-name` 改 `s5l8942x`、`chip-id` 改 0x8942；cpu1、IOP、闪存控制器、AE2、SGX、ISP、VXD 的 `compatible` 改成 `none`；AIC 的 `#main-cpus` 改 1，启动参数加 `cpus=1`。

## 3. 下一步

1. **s5l8940x PMGR 模型。** 先把 A4 的 PMGR 模型撤掉，让 `-d unimp` 显示性能控制器到底读写了哪些寄存器，再对照内核里 `AppleS5L8940XPerformanceController` 的代码补模型。设备树里 pmgr 的 `reg` 有 7 段（0xF100000 长 0x7000，另外 6 段在 0x8C00000 到 0xA600000）。
2. **GPIO：** 7.1.2 在 0xFA00000 一带有未实现访问，A5 的 GPIO 仍由 `AppleS5L8930XGPIOIC` 认领，A4 的 GPIO 模型换基址应该能用。
3. **接上 uart1 的中断（设备树 `interrupts` 0x16），** 然后继续往 Waiting for root device 走，再试 USB 大容量存储挂根。

## 3.5 第 2 轮（同日）：越过性能控制器，停在 i2c0 上的 PMU

**结论：** 两个版本都越过了 `handleSwapCleanup` panic，SPI、I2C、PWM、MIPI-DSI、I2S、PL310、串口、看门狗、DWI 等驱动都起来了。现在停在 i2c0 读 PMU（地址 0xE8，D1881）：7.1.2 panic `i2c0::_checkBusStatus SDA is stuck low ... for device pmu`，9.3.5 panic `i2c0::_checkBusStatus Bus is still in a bad state ... for device pmu`。【已核实】

原来的停止点有两个原因，都不在 PMGR 寄存器上：

1. **CPU 性能状态表是空的。** 撤掉 A4 的 PMGR 模型后 panic 照旧，说明不是寄存器的问题。panic 出自 xnu 开源的 `IOReporter::handleSwapCleanup`：给「维度」为 0 的 IOStateReporter 分配数组。性能控制器从设备树 `arm-io/pmgr` 的 `voltage-states1`（24 字节）和 `cpu-clk-cfgs`（12 字节）数性能状态，这两个属性 IPSW 里是 0，由 iBoot 的 `pmgr_update_device_tree` 填（n78 iBoot-1940，0x9ff1f82c）。反汇编出来的规则：3 个状态，每个状态的时钟源和分频取自 iBoot 的两张表（0x9ff41b0c `[1,2,1]`、0x9ff41b18 `[2,1,1]`）；`voltage-states1[i]` = {CPU 时钟周期（ns，16.16 定点）= 分频 × 1e9 × 65536 ÷ 时钟源 Hz, 0}；`cpu-clk-cfgs[i]` = PMGR+0x38 的值，第 28、29 位放时钟源，低 5 位放分频。拿 iPad 2（1 GHz A5）的 ioreg 导出核对：周期 2.0、1.25、1.0 ns，吻合。N78 的 `nominal-performance1` 是 1.25 ns（800 MHz），所以时钟源 1 取 800 MHz；时钟源 2 取 600 MHz 是推测。填上之后，7.1.2 把三个状态读成 `*0.800`、`*0.600`、`*0.400`。`/cpus/cpu0` 的频率也改成 A5 的值（CPU 800 MHz，总线 250 MHz，内存 400 MHz，外设 102.6 MHz，计时 24 MHz）。【规则已核实；时钟源 2 的频率为推测】
2. **AIC 的核间中断要靠读 Iack 应答。** 性能控制器启动后内核给自己发了一个核间中断（写 0x2008 = 0x80000000），然后在 IRQ 处理里反复读 Iack，中间只读 WhoAmI，不写 IPIClr。模型原来让核间中断一直挂着，内核就在中断处理里死循环。改成读 Iack 读到核间中断时顺手清掉。用 `AIC_TRACE=1` 环境变量可以打开 AIC 的逐次访问日志。【已核实】

另外：到这一步为止，内核对 PMGR 只读不写（0x38 到 0x104、0x1010 到 0x115c、0x220 到 0x254），读到 0 也能往下走。真正的 PMGR 模型等内核开始切换性能状态、往 PMGR 写的时候再做。

**下一步：** A5 的 I2C 控制器（`i2c,s5l8940x`，AppleS5L8940XI2CController）和挂在 i2c0 上的 PMU（Dialog D1881）。A4 的 `s5l8930_i2c.c` 和 PMU 模型可以参考，但 A5 换了控制器型号，寄存器要对照内核重新核实。

## 3.6 第 3 轮（同日）：I2C、PMU、PMGR 门控，9.3.5 进到 bsd_init

**结论：** I2C 和 PMU 通了，PMGR 的时钟门控也补上了。9.3.5 走到了 BSD 网络初始化（`L2TP domain init`、`PPTP domain init`），7.1.2 走到 LCD 面板驱动。两个版本现在都不再 panic，而是停在某个没有模型的设备在 `start()` 里等中断。【已核实】

新增（补丁现在 6 个文件、+1253 行）：

1. **`hw/arm/s5l8940_i2c.c`：A5 的 I2C 控制器。** 不是 A4 那种三星式控制器，而是 Linux `i2c-pasemi` 驱动的那种 PA Semi SMBus 块。编码从 7.1.2 驱动反汇编得出（init 0x80976c40、传输 0x80976e80、收数据 0x809776f8、`_checkBusStatus` 0x80977034），状态位名取自 Linux `i2c-pasemi-core.c`：0x00 发送 FIFO（0x100 起始、0x200 停止、0x400 读，读时低 8 位是字节数）、0x04 接收 FIFO（0x100 为空）、0x14 SMSTA（第 28 位 XIP、第 27 位 XEN、第 21 位 MTN，写 1 清）、0x18 中断屏蔽、0x1c 控制（低 8 位分频）。A5 驱动的中断模式会先写 0x2c = 0x100，再把屏蔽设成 0x00b00040（MTO、MTN、第 20 位、TOM），不包含 XEN。所以第 20 位被当作苹果加的「传输完成」中断，和 XEN 一起置位（推测）。`I2C_TRACE=1` 打开逐次访问日志。【编码已核实；第 20 位的含义为推测】
2. **GPIO：** 「SDA is stuck low」并不是控制器报的。驱动在每次传输前，通过 `function-iic_sda/scl` 从 GPIO 读引脚电平，GPIO 没有模型，读到 0，就判定总线卡死。A5 内核仍由 `AppleS5L8930XGPIOIC` 认领 GPIO，所以直接复用 A4 的模型（28 个端口、8 个中断组、AIC 0x77），并把 i2c0、i2c2 的四个脚（0x0604、0x0605、0x1800、0x1801）的静止电平设为高。【已核实】
3. **D1881 PMU：** 先做成 256 字节的寄存器文件，挂在 i2c0 的 0x74。`AppleD1881PMU` 已经读写了一百多次：屏蔽中断 0x0e 到 0x14，读事件 0x08 到 0x0d，以及 0x55、0x61、0x8a、0xa0 一带。9.3.5 还打出了 `AppleD1881PMUPowerSource: Setting battery threshold ... 4000 mV`。全读 0 暂时能过，以后电池、按键、RTC 要再补。【已核实】
4. **`hw/arm/s5l8940_pmgr.c`：** 加上 I2C 之后，第一次真正卡在 PMGR：`_enableDevicePowerGated: Power gate 0x6c enabled before clock was enabled`。时钟门控在 0x1010 + 4n（这块芯片一直排到 0x117c），约定和 A4 一样：第 0 到 3 位申请，第 4 到 7 位报告实际状态。模型让实际状态立即跟上申请；时钟配置的第 30 位（正在切换）写入后立即清掉；其余寄存器按原样存取。【已核实】
5. ~~设备树里又隐藏了 jpeg、scaler、vxe~~：后来证实不需要，已撤回，见 3.7 节。

**更正（3.7 节）：** 这一轮结束时我以为两个版本都卡在 DART、USB、CLCD、RGBOUT 上等中断，其实不对。它们当时已经在等根设备了，只是我用来判断的正则（`[Ww]aiting (for|on) root`）没匹配上内核的原话 `Waiting on <dict ...>`。那几次外设访问只是内核等根设备时，其他驱动的后台活动。

## 3.7 第 1 步目标达成：两个版本都在等根设备

**结论：** 7.1.2 和 9.3.5 都打出了 `Waiting on <dict ID="0"><key>IOProviderClass</key><string ID="1">IOMedia</string><key>IOPropertyMatch</key><dict ID="2"><key>Partition ID</key><integer size="64" ID="3">0x1</integer></dict></dict>`，即 kboot 的 `root-matching` 要的第 1 分区。等的同时还有驱动在加载（`AppleFSCompressionTypeZlib`、`IOSurfaceRoot`）。9.3.5 等根设备前的最后几行是 `AppleD1881PMU::start: pmu ...`、`using DWI for BUCK changes`。【已核实，两个版本各开机 60 到 75 秒】

- 撤掉 jpeg、scaler、vxe 的隐藏之后再开，两个版本照样走到这一步，所以隐藏列表回到 3.6 节之前的样子：cpu1、iop、flash-controller0、ae2、sgx、isp、vxd。【已核实】
- `tools/a5/auto_hide.py` 是一个启动调试的循环：开机，内核停住时就把最后访问的设备藏掉，再开，直到出现等根设备或 panic。`n78_kboot.py` 新增了 `N78_HIDE` 环境变量，用来临时多藏几个节点。

**第 1 步剩下的部分：** 给内核一个根设备。有两条路：
1. **USB 大容量存储**（第 0 步的方案）：要先做 EHCI 主机控制器（`usb-complex` 下面），再挂 QEMU 的 `usb-storage`。9.3.5 的 USB 主机栈换成了新的 IOUSBHostFamily，A4 的 EHCI 模型只在老栈上验证过。
2. **内存盘先试一下（更快）：** `ipad1_kboot.build()` 本来就支持 `ramdisk=`（加 `rd=md0`，把盘放在内核后面）。拿固件里的恢复内存盘（RestoreRamdisk，ipsw.me 有密钥）当根，能最快看到 launchd 等用户态程序在 A5 上跑起来。512 MiB 内存放得下。

## 3.8 内存盘当根：根挂上了，launchd 还没起来

**结论：** 用恢复内存盘（RestoreRamDisk，HFS+，9.3.5 约 20 MB、7.1.2 约 9 MB）当 md0，两个版本都打出了 `BSD root: md0`，根文件系统挂上了。之后内核继续加载驱动（`AppleFSCompressionTypeZlib`、L2TP/PPTP、显示管线、缩放器、JPEG、LCD），然后安静下来：没有 panic，60 秒内也没有一次来自 EL0 的异常（`-d int` 统计），也就是 `/sbin/launchd` 还没开始执行。【已核实】

- `tools/a5/n78_unpack.py` 现在也解出 `RestoreRamDisk.dmg`；`n78_kboot.py` 新增 `N78_RAMDISK=路径` 环境变量，交给 `ipad1_kboot.build(ramdisk=...)`，会加上 `rd=md0` 并清空 root-matching。
- **9.3.5 的定时器只响一次：** 内核设了 `TmrCnt = 0x394f8`（约 9.8 ms），第一次 FIQ 按时到来，FIQ 处理程序清了 `TmrIntStat`，但之后再没写过 `TmrCnt`，定时器就停了。之后内核反复按「高位、低位、高位」读主计时器（0x28、0x20、0x28）。7.1.2 没有这个问题（60 秒 117 次 FIQ）。原因未查明。【现象已核实】
- **7.1.2 定时器正常，也没起 launchd：** 所以卡点不只是 9.3.5 的定时器，而是 bsd_init 在 load_init_program 之前等着某样东西。PC 采样只落在调度器函数里（`thread_block_parameter`、`current_thread`），看不出是谁在等什么。

**下一步：** 拿到各线程的调用栈。打算用 QEMU 的 gdb 调试口（`-s -S`）接 lldb，加载带符号的 kernelcache，从 xnu 的线程列表取出每个线程保存的寄存器，逐个回溯；或者想办法触发一次 panic，让内核自己打印「Dumping thread state and stacks」。另外要回头查 9.3.5 的 FIQ 处理为什么不重新设定定时器。

## 3.9 launchd 起来了：两个版本都跑到 restored_external

**结论：** 7.1.2 和 9.3.5 都执行了 `/sbin/launchd`，并由它拉起恢复环境的 `restored_external`，这是模拟的 A5 上第一次跑起用户态程序。两个卡点：

1. **（两版共同）bsd_init 在等 AES 引擎。** 需要 CDMA（加密 DMA）和它的 AES 过滤器。复用上游 A4 的 `s5l8930_cdma.c`，接到 n78 上就通了。
2. **（9.3.5）定时器只响一次。** 原因在 AIC 的核间中断语义，不在定时器本身：读 Iack 取走 IPI 时应该只把它屏蔽、不清掉。改了 AIC 模型后，9.3.5 在 60 秒里收到 1388 次定时器 FIQ（原来只有 1 次）。

【以上都已核实】

| | 改之前（60 秒） | 只加 CDMA | 再改 AIC |
|---|---|---|---|
| 7.1.2 EL0 异常 / FIQ | 0 / 117 | 7262 / 未统计 | 7681 / 2740 |
| 9.3.5 EL0 异常 / FIQ | 0 / 1 | 10025 / 1 | 17454 / 1388 |

现在两个版本走到的地方一样：`restored_external` 报 `unable to find a usable display`、`unable to get framebuffer`、`enable_usb_connections failed`，然后 `restored exited normally with status 1 - rebooting`。重启途中 panic：7.1.2 `IOUSBController::HandleHardwareException: Type: 0x00000004 could not halt controller in 100 ms`，9.3.5 `AppleUSBHostController::hardwareException: ...` 同样的话。也就是说，下一批要补的是显示、USB 主机和设备控制器、NVRAM。9.3.5 打出了 `Darwin Bootstrapper Version 3.4.0`、`Restore environment starting`；7.1.2 打出了 `*** launchd[1] has started up. ***`，restored 退出前还在等 `IONVRAM`。【已核实】

### 3.9.1 怎么找到的：在 thread_block 上下断点

QEMU 的 gdb 调试口不认识 xnu 的线程，遍历线程表又要先知道结构体偏移。所以换了个办法：从开机起在 `thread_block_reason` 下断点（7.1.2 0x800bf190，9.3.5 0x8002d5c4，都是从导出函数 `thread_block` 的尾跳找到的），每次命中时沿 r7 帧链回溯，按内核栈分组，只留每个栈最后一次睡下时的调用链。一个线程永远睡下了，它最后那条调用链就是卡点。工具是 `tools/a5/gdbtrace.py`（自己实现的 gdb 远程协议，不依赖 gdb/lldb）。

- 开机到卡住只要约 2 秒；之后 198 秒里没有任何线程再调用 `thread_block`，CPU 一直在空闲循环。共 77 个内核栈。【已核实】
- 开机线程（bsd_init）的调用链是 `bsd_init` 0x802494d4 → `AppleARMPlatform`+0x66d8 → `thread_block`。0x802494d2 处是 `pe->callPlatformFunction("SecureRootName", false, rootdevice, …)`，也就是内联的 `IOSecureBSDRoot`。【已核实】
- 反汇编 AppleARMPE 的 `callPlatformFunction`，得到一个双方握手：
  - `SecureRootName`（bsd_init 来调）：比较根设备名，把结果记在对象 +0x98，把 +0x96 置 1 并唤醒，然后一直等 +0x97 被置位。
  - `SecureRoot`（AES 驱动来调，带上自己）：先等 +0x96，再回调这个驱动的 `SecureRootCallBack`，回调返回后才把 +0x97 置 1 并唤醒 bsd_init。
- 调 `SecureRoot` 的是 IOCryptoAcceleratorFamily（kext 里同时有 `SecureRoot` 和 `SecureRootCallBack` 两个字符串）。另一个栈正好卡在这条路上：`AppleCDMA`+0x215c（start）→ IOCryptoAcceleratorFamily+0x1868 → `callPlatformFunction("SecureRoot")` → AppleARMPlatform+0x675e → `SecureRootCallBack` → IOCryptoAcceleratorFamily+0x221a 在 `IOCommandGate::commandSleep` 里等一次 AES 运算完成。`-d unimp` 显示它写了 AES 上下文 1 的设置和 IV（arm-io +0x7801000 到 +0x780101c），配了 CDMA 通道 1、2 并按下 go，和 A4 上 7.x 的做法一模一样（通道 1 把数据喂进 AES，通道 2 取出结果）。没有 CDMA 模型，完成中断永远不来。【已核实】
- 同一时刻还有一批驱动在 `IODMAController::getController` 里等 DMA 控制器注册：AppleSamsungSPI、AppleSamsungSerial、AppleSamsungI2S、AppleAE2Audio。AppleCDMA 卡在自己的 start() 里，没走到 registerService。加上 CDMA 后这些也一起放行了。【已核实】

### 3.9.2 CDMA：复用 A4 模型

A5 设备树的 `arm-io/cdma`：`cdma-version` 3，通道区在 +0x7000000（长 0x2d000），AES 上下文区在 +0x7800000（长 0x9000，9 个上下文，和 A4 一样），`interrupts` 是 0x33 到 0x5c 共 42 条，对应通道 1 到 0x2a。上游 `s5l8930_cdma.c` 有三处写死了 A4，补丁里改成属性，A4、3GS 不传就保持原值：

- `dram-base`：判断描述符地址是内存还是设备 FIFO，原来固定 0x40000000，A5 是 0x80000000。
- `channels`：通道槽数（含 0 号全局块），原来固定 0x26，A5 用 0x2b。通道区内存区改在 realize 里按它定大小；数组开到 0x30。迁移状态仍只存前 0x26 个通道（改用 `VMSTATE_*_SUB_ARRAY`），`-dump-vmstate` 比对新旧二进制里 `s5l8930.cdma` 的描述完全一致，A4 的快照格式没变。A4 机型（`iPhone-4`、`ipad1`）实例化后 `info mtree` 里 CDMA 仍是 0x87000000 到 0x87025fff。【已核实；A4 实际开机没测，本机已没有 A4 的设备和固件】
- n78 上 `paced-ports` 设 0：A4 的 I2S FIFO 窗口不是 A5 的，音频 DMA 暂时不按播放速率走。

### 3.9.3 9.3.5 的定时器：丢掉的那个核间中断

两个内核的 FIQ 快路径一样，9.3.5 注册的是 T8002 式的定时器函数（AIC +0x2014 倒计时、+0x2018 清中断，表在 0x803f5790：FIQ 处理 0x800c8bcc、取时基 0x800c8be0、读倒计时 0x800c8c0c、设倒计时 0x800c8c20）。FIQ 处理清掉中断后总是进 `fleh_dec`（0x800c6c4c）。问题出在 `fleh_dec` 的一个分支：

1. 如果 FIQ 来时 IRQ 正被屏蔽（spsr 第 7 位），`fleh_dec` 不当场处理，而是调 `cpu_signal(cpu0, SIGPdec=1)`（0x800bd7b4），留到 IRQ 打开后再处理。断点记录：0.041 秒时正是这样。【已核实】
2. `cpu_signal` 给自己发信号时，先把信号位记进 cpu_data+0x30；如果这个字的第 31 位（相当于 xnu 的 `SIGPdisabled`）还在，就不发核间中断，直接返回。开机初期它就是置位的。这一位只有收到核间中断、进 `cpu_signal_handler`（0x800bd86c）时才清，清的同时处理积压的 SIGPdec，调 `rtclock_intr`（0x800cb74c）重设倒计时。【已核实】
3. 1.72 秒时 AppleARMCPU 启动 CPU（经内核 `processor_start`），调 AppleInterruptController 的 causeVector 给 cpu0 发自发 IPI（向量 0xc0，写 IPISet = 0x80000000）。但这时向量 0xc0 还没注册，驱动的中断处理读到 IPI 后直接跳过：不写 IPIClr，也不调处理函数。【已核实】
4. 旧模型在读 Iack 时就把 IPI 清了（3.5 节为 7.1.2 做的权宜之计），这个 IPI 就此丢失。SIGPdisabled 永远清不掉，SIGPdec 永远没人处理，定时器再也没人重设。7.1.2 不受影响，大概是它的第一次定时器 FIQ 没赶上 IRQ 屏蔽的时候。【推测】

驱动里的 disableVectorHard / enableVector 对 IPI 向量写的是每核寄存器 +0x24 和 +0x28（别名区 0x5024 / 0x5028 + 0x80 × 核号），值 0x80000000 表示自发 IPI，1 表示普通 IPI。开机时两个内核都会写 `0x2024 = 0x80000001`，之前日志里当成未实现寄存器。据此推断：+0x24 置 IPI 屏蔽、+0x28 清屏蔽；读 Iack 取走 IPI 时只把它屏蔽，IPI 仍挂着，直到写 IPIClr。这样那个早到的 IPI 会在向量注册、enableVector 解除屏蔽时重新送达。模型按此改了，7.1.2 原来那个「读 Iack 死循环」也照样不会出现（第二次读时 IPI 已屏蔽）。【寄存器用法已核实；Iack 自动屏蔽 IPI 是推测，但两版行为都对上了】

### 3.9.4 新工具（`tools/a5/`）

- `gdbtrace.py`：接 QEMU 的 `-gdb tcp::PORT`。三种用法：在地址上下断点并保留每个内核栈最后的调用链；`--log` 按顺序打印每次命中的 r0 到 r3 和短回溯；`--sample` 定时打断采样。符号取自 kernelcache 的导出符号。
- `kexts.py`：读 `__PRELINK_INFO`，列出各 kext 的装载地址和大小，或者告诉你某个地址在哪个 kext 里。
- `mkelf.py`：把 kernelcache 的 `__TEXT` 和 `__PRELINK_TEXT` 包成 ELF，这样 `llvm-objdump --start-address/--stop-address` 能反汇编任意范围，kext 也行（直接对 Mach-O 用 `--macho` 时这两个参数不生效）。
- `kexts.py`、`mkelf.py` 和 `xref.py` 一样，要和 `imgtools/` 放在同一目录（复现时放 `work/a5/`）。

### 3.9.5 下一步

1. **显示：** restored_external 找不到 framebuffer（7.1.2 走 CLCD/RGBOUT/AppleDisplayPipe，9.3.5 走 IOMFB）。要显示出苹果标志和进度条，需要显示管线的最小模型。
2. **USB：** 重启时 USB 主机控制器 panic（`could not halt controller in 100 ms`），`enable_usb_connections failed` 是设备端。EHCI 模型本来就是 USB 盘挂根要做的，可以一起做。
3. **NVRAM：** 7.1.2 的 restored 在等 `IONVRAM`，还报 `No IOFlashController instance found`。
4. **根文件系统：** 内存盘只能跑恢复环境；完整系统仍按原计划挂 USB 大容量存储。
5. **小尾巴：** A5 上 CDMA 的 I2S 按速率送数没接（`paced-ports` 0）；CDMA 模型里防 UART 接收链空转的判断用的是 A4 的 UART 地址，A5 上不生效，以后出现 BlueTool 那种空转时再补。

## 3.10 显示：苹果标志和恢复界面

**结论：** 两个版本的 restored_external 都拿到了 640×1136 的显示器，不再报 `unable to find a usable display`、`unable to get framebuffer`。QEMU 的 `screendump` 截到了画面：开机先是 iBoot 式的白色苹果标志；9.3.5 随后换成 restored 自己画的恢复界面（苹果标志加进度条底槽），7.1.2 换成屏幕中央一个转动的菊花图案。restored 退出、重启途中 panic 在 USB（3.9 节）之后，屏幕变黑。【已核实】

![A5 显示截图](img/a5-display.png)

（从左到右：7.1.2 第 1.5 秒、第 3 秒，9.3.5 第 2 秒、第 6 秒。截图由 `tools/a5/qmon.py` 经 QMP 拍，原图在 `work/a5/runs/s39/7n`、`9n`。）

| | 显示驱动 | restored_external |
|---|---|---|
| 7.1.2 | AppleH4PDisplayPipe、AppleH4PCLCD（日志里叫 AppleMobileCLCD） | `found display: primary`、`display: 640 x 1136`，然后 USB 失败退出 |
| 9.3.5 | IOMFB：`IOMFBSoCH4PProfile`、`AppleH4DisplayPipe`，`AppleMobileCLCD DisplayPipe ... physical = 0x3a100000` | 同上，再加 `powering on display`，画出标志和进度条 |

### 3.10.1 复用 A4 的显示模型，按 A5 的地址接上

上游 `s5l8930_display.c`（管线、CLCD、RGBOUT、TV-out）和 `ipod_touch_mipi_dsi.c` 原样实例化，地址取自 A5 设备树：

- 管线 0：clcd `reg[0]` = arm-io +0xa100000（A4 是 +0x9000000，挪了位置）；CLCD：+0x9200000；RGBOUT 自己的管线：rgbout `reg[0]` = +0xa200000；RGBOUT 控制块：rgbout `reg[1]` = +0x9600000；TV-out：+0x9400000；MIPI-DSIM：+0x9500000。clcd `reg[2]`（+0x9300000）和 displayport 没有接，仍记未实现。
- 中断：clcd 的 `interrupts` 是 {0x2b, 0x2a}，即管线 0 0x2b、CLCD 0x2a；rgbout 的第一条 0x2c 是它的管线；DSIM 0x29。
- A5 的 clcd 节点没有 DART mapper，模型的 dart2 不映射，层地址按物理地址或下面的页表走。
- 模型复位时照 iBoot 留下的样子预置：CLCD +0x60 为面板尺寸、ENVID 置 1、UI0 指向 vram（0x9f700000，即开机包和 boot_args 里的 vram）。

**「CLCD not initied by iBoot」：** 两个版本在这之前对显示块只读过一次 CLCD +0x60（面板尺寸，`(宽-1)<<16 | (高-1)`），读到 0 就打这句、不加载驱动。模型预置了这个值，这句就没了。【已核实】

### 3.10.2 H4P 管线的层寄存器和 A4 不一样（模型加了 `h4p` 开关）

A5 即使在 7.1.2 上也用 H4P 那一代显示驱动（kext：AppleH4PDisplayPipe、AppleH4PCLCD、AppleH4PRGBOUT）。第一次接上时内核报 `input width(-640) or height(-1136)`，restored 拿到的尺寸是 `4294966784 x 4294966272`，建不了显示缓冲。反汇编 AppleH4PDisplayPipe（11D257）得出：

1. **源矩形：** 接管 iBoot 画面时（0x80a2fc4a），宽 = 0x4070 的高 13 位 − 0x4060 的高 13 位，高 = 两者低 13 位之差，即 0x60 是源起点、0x70 是源终点。A4 模型在 0x60 放的是 A4 的「源终点」、0x70 是 0，于是得出 −640。交换时目标位置写 0x54、目标尺寸写 0x58（11 位，0x80a337ee、0x80a3381a）。【已核实】
2. **每层自带页表：** 交换后层的地址寄存器 0x44 变成 0，0x98 里是一个物理地址（0x80a32ace 建表）。读出来是每 4 KiB 一项、物理地址或上 1（有效位）的页表；0x44 是层在这张表里的虚拟地址。7.1.2 的层 0 表映射的正是 vram（0x9f700001、0x9f701001 …），层 1 是 restored 分配的零散页。【已核实】
3. **0x4c 不是 A4 的 UNSCALED 位：** H4P 往里写别的值，按 A4 解释会把目标矩形清零。【已核实】

`s5l8930_display.c` 加了属性 `h4p`（默认关，A4 不变）：复位时把 iBoot 的层预置为源 0x60→0x70；扫描输出按 0x60/0x70 取源矩形、0x54/0x58 取目标，0x98 非零时经页表取像素（`layer_read`）。只在 n78 上打开。改完后两版的 restored 都拿到 `display: 640 x 1136`。`-dump-vmstate` 比对：`s5l8930.display`、`s5l8930.cdma`、`ipodtouch.mipidsi` 的迁移格式和原版完全一致；iPhone 4 机型的管线 0、CLCD 仍在 0x89000000、0x89200000。【已核实；A4 实际开机仍未测，本机没有 A4 设备】

### 3.10.3 开机包画苹果标志

`n78_unpack.py` 现在也从本地 IPSW 解出 `applelogo@2x~iphone.s5l8942x.img3`（密钥在之前取的 ipsw.me 密钥表里，没有新下载），存成 `AppleLogo.bin`（iBootIm、grey、130×158）。`n78_kboot.py` 用 ipad1_kboot 的 `logo_segments` 把它居中画进 vram，作为 K48SEG 段跟在开机包后面，机型每次复位时拷进内存。

### 3.10.4 还没弄清的

- **7.1.2 的菊花图案是谁画的：** 它在层 0（页表映射 vram）里，7.1.2 只开着层 0（0x1038 = 0x100），restored 的层 1 行跨度还是 0。可能是 restored_external 在等 USB 主机时画的等待图案，也可能是内核的进度图。【推测】
- **9.3.5 两层都开（0x1038 = 0x300），** 模型把两层叠在一起显示，叠放次序沿用 A4 的（UI1 在上），从画面看没问题。
- H4P 的其余层寄存器（0x50、0x5c、0x88、0x8c、0x90）意义未查：0x88/0x8c 交换后是 0x100000，像 1.0 的缩放系数；0x90 写 1。画面需要缩放或偏移时再看。

### 3.10.5 新工具

- `tools/a5/qmon.py`：经 QMP（`-qmp unix:SOCK,server,nowait`）在指定时刻截图（存 PNG）并读出管线 0 的全局块、两层寄存器和 H4P 页表。
- `tools/a5/pcrefs.py`：在 llvm-objdump 的 Thumb 反汇编里找某个字符串的引用（ldr 或 movw/movt 再 add pc），kext 里的报错字符串靠它定位。

### 3.10.6 下一步

1. **USB：** 两版都是 `enable_usb_connections failed` 后退出，重启时 USB 主机控制器 panic。EHCI 也是 USB 盘挂根要的。
2. **NVRAM：** 7.1.2 的 restored 等 `IONVRAM`。
3. 显示方面暂时够用；以后进系统要看动画时，再核实 H4P 的缩放、旋转和层叠次序。

## 3.11 USB：主机能枚举 USB 盘，两版都从 USB 盘挂根

**结论：** 三件事都做到了：
1. **重启途中不再因 USB panic。** 原来没有 EHCI 模型，重启时 `StopUSBBus` 等不到 HCHalted 位。
2. **EHCI 能枚举 QEMU 的 `usb-storage`，两版都能从 USB 盘挂根。** 盘里装的是 IPSW 的系统分区，内核打出 `BSD root: disk0s1`，launchd 起来、fsck 根分区，然后因为找不到数据分区 `/dev/disk0s2` 走关机流程。
3. **恢复内存盘里 `enable_usb_connections failed` 消掉了。** restored_external 不再退出，停在恢复模式等主机来连（9.3.5 屏幕上一直是恢复界面）。

【以上都已核实】

![A5 USB 截图](img/a5-usb.png)

（从左到右：7.1.2 从 USB 盘挂根后第 30 秒，9.3.5 恢复内存盘第 40 秒（restored 一直在），9.3.5 从 USB 盘挂根后第 60 秒。）

| | 7.1.2 | 9.3.5 |
|---|---|---|
| 重启途中 USB panic | 没了 | 没了 |
| `usb-storage` 枚举 | 一开始就成功：设地址，读描述符，SCSI 依次 INQUIRY、MODE SENSE、READ CAPACITY、READ(10) | 先失败（`persistent enumeration failures`），修了 PA 0 后成功 |
| USB 盘挂根 | `Got boot device = .../usb-ehci-port1`，`BSD root: disk0s1`，launchd、`fsck_hfs` | 同左，完整路径到 `IOGUIDPartitionScheme/System@1`，`Darwin Bootstrapper` |
| 挂根后停在 | `Can't stat /dev/disk0s2`、`BAD DISK NAME /dev/disk0s2`，然后 `Userspace shutdown begun` | 同左 |
| 恢复内存盘里的 restored | 注册 PTP、AppleUSBMux、USB 以太网，启动 USB 栈，不退出 | 同左，恢复界面一直显示 |

### 3.11.1 接上的模型（都复用 A4 的）

A5 的 USB 布局和 A4 一样，只是换了基址。两版设备树相同：
- otgphyctrl 在 arm-io +0x6000000。
- usb-complex 的 `ranges` 把子节点映射到 +0x6100000 起：usb-device（Synopsys OTG）+0、usb-ehci +0x300000、usb-ohci0 +0x400000、usb-ohci1 +0x500000。
- 中断依次是 0x0b、0x0c、0x0d、0x0e。

n78 上照 `ipad1.c` 的做法接了四样：
- iPod 的 USB PHY 模型和 Synopsys OTG 模型。没接 usbmux 桥（`IT_USB_TCP`）时，由 OTG 内建的主机来配置设备。
- QEMU 的 `exynos4210-ehci-usb`（能力寄存器在 +0）和一个单口的 sysbus OHCI。
- 给两者设了 id，总线名固定为 `ehci.0`、`ohci.0`。挂盘的写法：`-drive if=none,id=root,file=...,format=raw -device usb-storage,bus=ehci.0,drive=root`。
- usb-ohci1 没接（publish-criteria 0x10，不发布）。

### 3.11.2 9.3.5 枚举失败：PA 0 上的「异常向量」被当成了传输

9.3.5 的新 USB 栈（IOUSBHostFamily）复位端口、使能端口之后，从来不发 SETUP 包。打开 QEMU 的 EHCI trace 后看清了过程：

1. **占位 QH 指向 PA 0。** 驱动在周期调度里放了一批占位 QH（设备 0、端点 15），它们的 next qTD 指针是 0，T 位没置。按 EHCI 规范，控制器会去物理地址 0 取一个 qTD。
2. **n78 的 PA 0 映射的是内存。** 原来照 A4 的 kboot 做法，PA 0 是 DRAM 第 0 页的别名，内核开机时把异常向量（`b .` 等）拷了进去。读出来的 token 正好带 Active 位，QEMU 就开始执行一个「传输」，报 `guest requested more bytes than allowed`。
3. **QEMU 出错后复位整个 EHCI。** 刚使能的端口跟着掉线，内核再复位端口，周而复始，最后报 `persistent enumeration failures`。

真机上 PA 0 是 SecureROM 的窗口：A4 机型用 `bootrom=` 启动时也是把 ROM 映射在 0，内核往那里拷向量也写不进去。所以 n78 的 PA 0 改成一块 64 KiB 的只读占位 ROM，开头是 8 条 `ldr pc, [pc, #0x18]`，其余为 0。改完以后：9.3.5 枚举成功，整个过程没有 guest_bug，EHCI 只在初始化时正常复位 3 次；两版照常开机，7.1.2 的枚举也没变。【已核实】

### 3.11.3 开机包里改的两处设备树（`tools/a5/n78_kboot.py`）

1. **`usb-ehci-port1` 的 `port-type` 改为 0。** 和 A4 机型对 6.x/7.x 设备树的改法相同（`ipad1.c`）：原来的 2 表示底座口，只有接上主机侧线缆才供电。
2. **usb-complex 加 `no-pmu`。** USB 仲裁器见到这个属性，就按「接在电脑上」（cable type USBHost，设备模式）处理，开机即发布 OTG 设备节点。否则它要等 PMU 报线缆，而 D1881 模型报的是 `Detached`（`AppleUSBCableDetect 0`），于是：
   - restored_external 先报 `unable to find valid configuration for this device`，再报 `enable_usb_connections failed`，然后退出；
   - OTG 设备端要到重启途中才起来。
   
   加上后，restored 打出 `found PTP interface`，注册了 PTP、iPod USB Interface、AppleUSBMux、USB 以太网四套配置，`AppleUSBDeviceMux::start`、`startUSBStack` 都起来了，QEMU 的内建主机报 `device configured`。
   
   这和 A4 机型的效果一样（「像接在 Mac 上的 iPad」）。代价是 PMU 自己的线缆检测仍报 Detached，充电状态之类以后要补 D1881 的充电器和 ADC 寄存器（日志里有 `_readADCGated ... ADC read bad state`）。【已核实】

### 3.11.4 USB 根盘（`tools/a5/n78_usbroot.py`）

1. **解密 rootfs。** 从本地 IPSW 取出 rootfs（7.1.2 `058-4385-009.dmg` 1.26 GB，9.3.5 `058-49388-036.dmg` 1.55 GB），用 ipsw.me 密钥表里的 RootFS 密钥（之前已取，没有新下载）经 `imgtools/vfdecrypt.py` 解密，得到 UDZO 压缩的 UDIF 镜像。
2. **切出 HFS 卷。** `hdiutil convert -format UDTO` 转成裸盘，按 APM 切出 Apple_HFS 分区：7.1.2 是 1620 MiB 的 HFSX，9.3.5 是 2012 MiB。
3. **包成 GPT 盘。** 第 1 分区放这个卷，类型为 Apple HFS 的 GUID，从 1 MiB 处开始。内核的 IOGUIDPartitionScheme 把它发布成 `Partition ID` 1（9.3.5 路径里叫 `System@1`），正好对上 kboot 默认的 root-matching。
4. **用法。** 不带内存盘的开机包（`n78-<build>.bin`）加上这块盘就能挂根。镜像在 `work/a5/disks/`，解密后的 dmg 在 `work/a5/rootfs/`，都不进仓库。开机时用 `snapshot=on` 挂，镜像不会被写。

这个 iPod 内核里也有 LightweightVolumeManager，它试过这块盘后放弃了（`LwVM: media block size too small`），不影响 GPT。

### 3.11.5 下一步

1. **数据分区（disk0s2，挂到 /private/var）：** 两版的 `/etc/fstab` 都要它。要按恢复的做法往里放 rootfs 的 /private/var 内容，并保留属主；imgtools 的 `ipad1_rootfs.py` 有 A4 上的做法（`build_nand`、`var_owners`）可以改用。做好后有望往 SpringBoard 走。
2. **PMU 的充电器和 ADC：** 现在靠 `no-pmu` 绕过线缆检测。
3. **HSIC 上的 Wi-Fi：** 内核在 EHCI 的 HSIC 口（端口 3）等 BCM Wi-Fi（`Bus enumeration failure`）。暂时无害，以后要么藏掉 DT 的 wlan 节点，要么接一个设备。
4. **NVRAM：** 7.1.2 和 9.3.5 的 restored 退出后都在等 `IONVRAM`。现在 restored 不退出，这条暂时碰不到，正式开系统时可能还会遇到。

## 3.12 冲主屏（7.1.2）：完整系统起到钥匙包，卡在可擦除存储

**结论：** 还没到锁屏或主屏。进展是 7.1.2 的完整系统从两分区的 USB 盘开了起来：
1. 系统分区挂成只读根，数据分区挂到 /private/var。
2. launchd 依次拉起 syslogd、sandboxd、powerd、keybagd、wifid、ptpd、timed、sharingd、passd 等五十多个任务（pid 排到 60 以上）。
3. 钥匙包守护进程 keybagd（pid 25）调 AppleKeyStore 全部失败（`AppleKeyStore: operation failed (pid: 25 sel: 24 ret: e00002f0)`），然后报 `FATAL KEYBAG ERROR: kb_load`、`REBOOTING INTO RECOVERY MODE.`。
4. launchd 走关机流程（`Userspace shutdown begun`），最后内核在重启路径上 panic。我们的机型还没有复位支持。

SpringBoard 没来得及起来，屏幕从苹果标志变黑。【已核实】

**卡点：** AppleKeyStore 在 start 里调 `IOService::waitForService` 等 `AppleEffaceableStorage`（可擦除存储，钥匙包的密钥放在这里），不设超时，一直等不到。A5 内核里的可擦除存储驱动只有 `AppleEffaceableNANDNOR`，它挂在 IOFlashStorage（NAND）上，NVRAM（`IOFlashNVRAM`）也是。A4 那种给 SPI NOR 嫁接可擦除分区的办法在这里用不上：A5 内核没有 NOR 版的驱动，`ipad1_kboot.graft_nor` 也因为 n78 没有 spi0 而跳过了。【已核实】

### 3.12.1 两个分区的 USB 盘：借 FirmwareKit 只做卷

FirmwareKit 的 `SystemEdits.buildK48` 正好做我们要的事：
- 系统卷：IPSW 的 rootfs 扩到分区大小，fstab 改成两分区，SpringBoard 任务加 GL 环境变量并把 stdout/stderr 接到 /dev/console，装 GL 前端（OpenGLES）、AppSync、guest 工具，lockdownd 激活，`--skip-setup` 写好「设置已完成」。
- 数据卷：新建一个日志式 HFSX，放进 /private/var 骨架，属主离线写进目录记录。

做法如下：

1. **重建 guest 工具。** 照 M0 报告第 4 节，`tools/m0/make-substitute-sdk.py` 加上游的 `contrib/export-guest-artifacts.sh`，得到 `work/guest-artifacts/ipad-guest-tools/`，29 个文件。
2. **FirmwareKit 改两处（补丁 `patches/a5-firmwarekit-n78-volumes.patch`，对 LightTouchMac b06012fa4c）。** 它的配方只认 A4 的几块板子：一处让 `n78ap` 走 n90 的 iOS 7 配方（`Preparer.swift`），一处让 n78ap 借 n90ap 的硬件描述（`K48Recipe.swift`），只用于 `--stop-after volumes`。改的是 `work/a5/LightTouchMac` 副本，编到 `work/a5/fk/build`，依赖取自本机 SwiftPM 缓存，没有联网。
3. **`tools/a5/n78_fkprep.py`。** 照 n90ap-11D257 的条目拼出 n78 的条目（iPod5,1 的密钥取自之前的 ipsw.me 密钥表），再放一份 M0 的 helper 替身（`tools/m0/helper-shim`），路径改成现在的项目目录，机型表加一行 n78ap。FirmwareKit 开工前会检查这两样东西，虽然 `--stop-after volumes` 走不到开机那一步。
4. **`firmwarekit create ... --stop-after volumes --skip-setup` 只要 10 秒，** 产出 `system.img`（1792 MiB）和 `data.img`（14 GB 稀疏）。
5. **`tools/a5/n78_usbroot.py` 打包。** 现在也接受「system.img + data.img」，打成 GPT 两分区，稀疏拷贝，得到 `work/a5/disks/11D257-full.img`（15 GB，实占约 2 GB）。

### 3.12.2 两次开机

1. **数据卷带内容保护（FirmwareKit 对 5.0 以后总是打开）：** 挂完 /private/var（`journaled, noatime, protect`）后，用户态再没有任何输出。从开机起在 thread_block 下断点，看到两条调用链：
   - AppleKeyStore +0x2856 在 `waitForService` 里等可擦除存储；
   - 内核文件系统代码（0x80238f4a）经 AppleKeyStore +0x1bb0 卡在它的锁上，即建受保护文件时要找钥匙包。
   
   整个系统就此停住，屏幕停在苹果标志。
2. **把数据卷卷头的内容保护位清掉**（HFS+ attributes 第 30 位，0x40000000；在盘镜像的 APFS 克隆 `11D257-full-noprot.img` 上改）：文件系统不再找钥匙包，用户态跑到上面的 keybagd 致命错误。
   - 第一次误清了第 13 位（那是「日志式」），已更正。

另外为了看用户态日志，在系统卷里改了 `/etc/asl.conf`（加 `? [<= Level info] file /dev/console`），并新建 `/etc/syslog.conf`（`*.* /dev/console`）。这是用 hdiutil 加 diskutil 挂上盘镜像手工改的，没写成脚本。串口上看到的 launchd 和 keybagd 消息可能本来就会打到控制台，这个改动起没起作用没有核实。

### 3.12.3 交接要点（给接手的会话）

- **复现：** `python3 -I tools/a5/n78_fkprep.py 11D257 work/a5/fk`，打 FirmwareKit 补丁、编好后照脚本开头的说明跑 `firmwarekit create` 和 `n78_usbroot.py`；清内容保护位的 Python 片段见本节。开机用不带内存盘的 `n78-11D257.bin`，加 `-drive ...,snapshot=on -device usb-storage,bus=ehci.0,drive=root`。
- **关键现场：** `work/a5/runs/s39/7h/block.txt`（带内容保护时的阻塞调用链），`work/a5/runs/s39/7i3/serial.log`（去掉内容保护后的完整串口，含 keybag 错误和关机）。
- **下一步首选：做 A5 的 NAND（PPN）和 IOFlashStorage。** 第 0 步报告第 1 节有 PPN 的分析。这一步同时给出 `AppleEffaceableNANDNOR`（钥匙包）和 `IOFlashNVRAM`（NVRAM，7.1.2 的 restored 和以后的系统都在等 `IONVRAM`）。做好之后：
  - 第一次开机由 keybagd 或 FirmwareKit 的 it_keybag 格式化可擦除区、建系统钥匙包。A4 上 FirmwareKit 用「keybag 开机」做这件事，见 `Preparer.keybagDone`。
  - 数据卷的内容保护可以恢复。
- **备选（快但更脏）：** 给 AppleKeyStore 打内核补丁，让它不等可擦除存储、用内存里的钥匙包；或者在用户态让 keybagd 跳过 kb_load 失败。都没试，可行性未知。
- **SpringBoard 之前还会遇到的：**
  1. GL 桥：系统卷里已经装了 GL 前端，但 n78 机型还没有 `QEMU_CALL`/`gles-host`，iOS 7 的 SpringBoard 没有宿主 GL 会崩（M1 第 4 步）。要照 `ipad1.c` 接上。
  2. 复位：keybagd 之类要求重启时，内核走到 panic。要给 n78 接上看门狗复位或 `PE_halt_restart` 的路径。
  3. 触摸（multi-touch 在 spi1）、按键、电池和实时时钟（D1881 的 ADC 现在报 `ADC read bad state`）。
- **9.3.5：** 还没动。第 0 步报告的两个新问题（dyld-390 不许覆盖共享缓存、launchd 从 `xpcd_cache.dylib` 读守护进程清单）在 7.1.2 走通以后再看。

## 3.13 NAND：IOP 高层模拟，可擦除存储和 NVRAM 起来了，越过钥匙包

**结论：** 7.1.2 越过了钥匙包。NAND 这一层由新写的 IOP 高层模型提供：一次「格式化开机」（恢复内存盘加帮手程序）把空白 NAND 分好区、做好 FTL、格式化可擦除存储、建好系统钥匙包；之后正常从 USB 盘开机，AppleEffaceableNAND 找到当前代（`found current generation, 2, in group 1`），`IOFlashNVRAM::start: nand nvram started successfully`，keybagd 不再报 FATAL。屏幕停在转圈图案，显示客户端大约每 10 秒断开重连一次。【已核实】

> **更正（3.14 节）：** 原先这里写「launchd 拉起了 SpringBoard（pid 76）」「SpringBoard 每 10 秒崩溃重启」，证据不够。pid 76 那行只出现在第一次正常开机（boot1），是 it_seal 停机时 launchd 打出的 `Stopping job`；第二次开机（boot2）的串口里没有 SpringBoard 字样。崩溃重启是从显示客户端重连 18 次推出来的。3.14 节读了数据卷里的崩溃日志：反复崩溃的是 **backboardd**，不是 SpringBoard。

![A5 NAND 之后：转圈](img/a5-nand-spinner.png)

（正常开机第 180 秒。）

**做法：** 选了「高层模拟 IOP」：IOP 固件不跑，QEMU 里一个新设备 `s5l8940.iop`（`hw/arm/s5l8940_iop.c`）直接回答内核通过 IOP 发来的 FMI 命令，背后是一个按 PPN 几何组织的页存储。理由：AP 和 IOP 之间的协议（控制块、门铃、EmbeddedIOP 消息环、AppleIOPFMI 的 512 字节命令）都能从内核和 IOP 固件里读出来，内核的断言字符串很多，回答错了会直接说；而跑真固件要再模拟 ARMv7 的 IOP 核、它的内存映射和中断、H2FMI 加 PPN 的寄存器级协议，都没有资料。【判断】

### 3.13.1 读出来的协议（7.1.2，都已核实）

反编译用的是 REA（Ghidra 后端）：把 kernelcache 里相关 kext 连同内核导出符号包成 ELF（`tools/a5/kextelf.py`），IOP 固件和 iBoot 按裸镜像包成 ELF（`rawelf.py`），再把伪代码里的字符串引用解开（`pcfix.py`、`fwfix.py`）。

1. **AppleA5IOP-14（IOP 控制块，arm-io +0xf300000）。** startCPU（0x80e2d93c）：+0x0 写 0，+0x4 写固件的物理地址，+0x34 写 0x3ff01ff（iop-version 1），+0x0 写 1；stopCPU 写 +0x0 = 0。门铃和 NMI 是设备树 `function-doorbell`/`function-nmi`，即 AIC 的 IPID 平台函数：把 IPID 向量（设备树 `ipid-mask` = 0xf，向量 0 到 3）的软件中断位置 1，门铃是向量 3。IOP 回 AP 用向量 2（设备树 iop `interrupts`），AIC 驱动分发这类向量前自己写 SW_CLR（0x80ba1a32）。
2. **IOP 看到的内存：** DRAM 在 0xc0000000，等于 AP 物理地址加 0x40000000（和 A4 的固件内存表一样）。
3. **EmbeddedIOP-50 的消息环。** 固件里的 `cnfg` 块（7.1.2 固件 +0x13000）由 AP 填：+0x4 标志、+0x8 消息缓冲、+0xc 调试标志，端点 h（< 10）的环地址在 +0x10 + 8h、槽数在 +0x14 + 8h（registerEndpoint 0x80cce9f8）。每槽 64 字节，第 0 字是「条目 | 归属位」（sendMessage 0x80ccf470、receiveMessage 0x80ccf39c）。命令型端点由 AP 放 `条目|0`，IOP 做完写回 `条目|1`。端点 0 是控制（`nop ` 等，缓冲 +4 写 0 表示完成），1 是 IOP 发给 AP 的消息，AppleIOPFMI 的总线 0 用端点 5（3 槽）。
4. **FMI 命令（AppleIOPFMI-93，512 字节）：** +0 操作码，+8 状态（1 成功，2 空白，0x8xxxxxxx 错误；`_fmiTranslateResult` 0x80b1af84），+0x10 总线，+0x18 CE。IOP 固件 `fmi_message_process`（0x1088）在 PPN 设备上的分派：

| 操作码 | 含义（固件函数） | 字段 |
|---|---|---|
| 0x01 | set_config | +0x88 是否 PPN，+0x8c PPN 规范版本 |
| 0x16 | 取控制器信息（0x861c） | +0x1c 固件版本、+0x5c 厂商 ID、+0x70 起是参数页（CAU 数、块数、页数、页大小、时序、队列深度） |
| 0x17 | 取晶粒信息（0x8798） | +0x20 晶粒唯一 ID，+0x30 晶粒芯片 ID |
| 0x19 | 取温度 | +0x18 有符号 16 位 |
| 0x0a / 0x0b | 写 / 读引导页（0x8468 / 0x83b4） | +0x1c 页，+0x20 缓冲，每页 0x600 字节 |
| 0x03 | 擦单块（0x7de0） | +0x1c 块 |
| 0x10 / 0x12 / 0x11 | 读 / 写 / 擦多页（0x7fbc / 0x822c / 0x7d5c） | +0x1c 数据段表 {地址, 长度}、+0x20 段表字节数、+0x24 元数据段表、+0x28、+0x2c ppnCommand、+0x30 其长度、+0x34 AES IV 表 |
| 0x0d | 读 CAU 出厂坏块表（0x84d8） | +0x1c 段表，结果是每块一位 |

5. **ppnCommand（IOFlashStorage 和 IOP 共用的结构）：** +0 操作（1 读、2 写、3 擦），+8 页数（u16），+0xe + 6k 是 CE 序号 k 的物理 CE；从 +0x1c 起每页一个 12 字节条目 {长度, 行地址, CE 序号, ?, 状态, ?}（`h2fmi_ppn_process_error_list` 0x6524）。状态是 PPN 的操作状态：0x40 就绪，0x08 空白，0x10 通用错误，0x01 失败（读引导页 0x6220，SwissPPN 的 `_ppnvflProgramMultiple` 0x80d12674）。SwissPPN 的行地址是 {页, 块 << 页位数, CAU << (页位数 + 块位数)}，再往上一位表示 SLC 模式（PPNMISC 0x80d110ac）。
6. **iBoot 写进设备树的 NAND 属性**（n78 iBoot-1940 `nandid.c`，0x9ff22338）：`#ce`、`ce-bitmap`、`device-readid`、`#databus`、`#ce-blocks`、`#block-pages`、`#page-bytes`、`#spare-bytes` 等，PPN 设备再加 `ppn-device`、`ppn-spec-version`、`blocks-cau`、`caus-ce`、`slc-pages`、`mlc-pages`、`cau-bits`、`page-bits`、`block-bits`、`ppn-features`。IPSW 里的设备树这些都是空的。

### 3.13.2 我们给的 PPN 设备

没有真机可读，几何是自己定的，取值都在 IOP 固件 `_validate_device_parameters`（0x7374）检查的范围内：1 条总线 1 个 CE，2 个 CAU，每 CAU 0x420 块，每块 128 页（SLC 64 页），页 8 KiB 加 32 字节元数据，共约 2.2 GB。设备树由 `tools/a5/n78_kboot.py` 的 `fill_nand` 填，控制器信息由 IOP 模型回答，两边一致。页存储放在 `-global driver=s5l8940.iop,property=nand,value=目录` 指定的目录里（`ce0.pages`、`ce0.boot` 两个稀疏文件，按位取反存放，空洞读出来就是擦除态；擦除在 macOS 上用 `F_PUNCHHOLE` 打洞）。不给目录时存在内存里。

### 3.13.3 空白 NAND 要像恢复那样先格式化

空白 NAND 上分区方案报 `no partition table found`，只发布一个 `Unformatted` 分区，可擦除存储和 NVRAM 都没有。格式化入口是 IOFlashPartitionScheme 的 user client，选择子 `copy`（0x636f7079，`kIOFlashPartitionSchemeFormatCmd`，0x806f730c），不带参数；内核要求 `/chosen/system-trusted` 非零且调用者是 root（0x806f71e0），格式化本身总是允许（0x806f6540）。可擦除存储的格式化（AppleEffaceableStorage 选择子 4）又只允许在受信任的根下做，即恢复内存盘当 md0（和 A4 的 `it_keybag` 一样）。

所以照 FirmwareKit 的「钥匙包开机」做了一个 A5 版：`tools/a5/it_nandfmt.c`（armv7，dlsym 调 IOKit，用 qemu-ios 的 armv6-toolchain 编、ldid 签名），放进恢复内存盘副本当 `/usr/local/bin/restored_external`（imgtools `ipad1_keybag.ramdisk_with_helper` 的做法：扩 1 MiB、删掉原文件再放入、离线把属主改成 root）。它依次：格式化 NAND 分区，格式化可擦除存储，在 USB 盘的数据卷上 `MKBKeyBagCreateSystem`，然后停机。开机包加 `nand-enable-reformat=1`，让 SwissPPN FTL 在空白的文件系统分区上自己格式化。

### 3.13.4 格式化开机里修掉的五个坑（按出现顺序）

1. **`-global s5l8940.iop.nand=...` 不生效：** 驱动名里有点号，要写 `-global driver=s5l8940.iop,property=nand,value=目录`。
2. **SLC 模式的行地址：** SwissPPN 测特殊块时在 SLC 模式下读写，行地址多一位 SLC 标志（cau、block、page 位之上），模型原来把它当越界拒绝，读回的是旧缓冲，2109 个特殊块全部「failed verifying」。现在去掉这一位再寻址（同一块的前 64 页）。
3. **擦除写零太慢：** 模型擦块时往稀疏文件写 1 MB 零，FTL 格式化擦遍全部 2112 块，等于写 2 GB。改用 `F_PUNCHHOLE`。
4. **`max-transaction-size` 不能是 0：** 我在设备树里填了 0，SwissPPN 往 PPN 命令里加页时要求「每个 CE 的页数 < 这个上限」（0x80d11640），一页都加不进去，`_ppnvflProgramMultiple`（0x80d12674）原地死循环，CPU 全忙但 IOP 收不到命令。改成 32。
5. **读状态的编码：** ppnCommand +0xc 是整体状态（所有页状态的按位或），等于 0x40 时内核不再逐页看；逐页时只认 0x40、0x42 到 0x45、0x49、0x51、0xc1（`_analyzeSpansReadStatuses` 0x80d14e7c），空白页要报 0x49，不是 0x48，否则 panic「Read operation contained an unidentified status」。另外读可以只读半页：每页条目带 {长度, 列偏移}，一个 8 KiB 物理页是两个「4 KiB 数据 + 16 字节元数据」的逻辑页，页存储按这个列布局存放。

修完以后格式化开机的日志（`work/a5/runs/s313/fmt14/serial.log`）：VFL、FPart、FTL 依次格式化，`Writing final signature`，`VFL_Open [OK]`，`FTL_Open [OK]`，`AppleNANDFactoryBBT::start: ready`，分区方案发布 8 个分区，`it_nandfmt: NAND partition format -> 0`，`[effaceable:INIT] format succeeded`，`MKBKeyBagCreateSystem -> 0, /mnt2/keybags/systembag.kb 1495 bytes`，然后停机。整个过程 IOP 收到约 1.7 万个命令。停机最后内核 panic 是因为机型还没有复位支持，不影响结果（NAND 存储已落盘）。

### 3.13.5 正常开机

- **USB 盘编号变了：** NAND 上的 FTL 也出一块盘，成了 disk0，USB 盘变成 disk1。所以系统卷的 `/etc/fstab` 要改成 `/dev/disk1s1`、`/dev/disk1s2`（手工改在盘克隆上；LwVM 认不了 NAND 盘，`media block size too small`，所以 root-matching 照样落在 USB 盘的第 1 分区）。
- **FirmwareKit 的 `it_seal`：** 系统卷里装着 A4 流程的 `it_seal`，首次开机 40 秒后主动停机「封存 NAND 存储」。第一次正常开机就是被它关掉的。在数据卷上放 `/private/var/.it_sealed` 标记它就直接退出。
- 之后的开机：可擦除存储、NVRAM、钥匙包都正常，显示客户端 200 秒里重连 18 次，屏幕是转圈（反复崩溃的是 backboardd，见 3.14 节）。

### 3.13.6 还没弄清或没做的

1. **`unable to efface group 0/1 after 3 attempts`：** 可擦除存储在「抹掉」旧组时失败，但仍找到了当前代、钥匙包能用。大概是它擦除用的命令或行地址我还没对上（擦单块 0x03 或擦多块的 SLC 地址），没查。【推测】
2. **引导页存储浪费空间：** 分区表写在引导页上，页号带了 SLC 位，`ce0.boot` 稀疏文件有 1.3 GB 实际占用。应该把引导页的 SLC 位也去掉，要重新格式化，没做。
3. **CAU 出厂坏块表**全报好块（每块一位都置 1），位的含义没核实，只是格式化和 FBBT 都接受了。
4. **9.3.5** 没试（AppleIOPFMI、IOP 固件版本不同，协议要再核对）。
5. **格式化开机要手工步骤：** 内存盘副本、改 fstab、放 `.it_sealed` 标记都是手工做的，还没写成脚本；复现见 `tools/a5/README.md`。

### 3.13.7 下一步

1. **GL 桥：** 照 `ipad1.c` 给 n78 接 `QEMU_CALL` 和 `gles-host`，系统卷里已经装了 GL 前端（已做，见 3.14 节）。
2. **复位：** 停机和重启都会 panic，格式化开机和以后的重启都需要。
3. 触摸、电池、实时时钟。
4. 把格式化开机写成脚本（相当于 A5 版的 FirmwareKit keybag 步骤），顺带修 3.13.6 的 1、2。

## 3.14 GL 桥：backboardd 画出来了，到设置助理的「Hello」

**结论：** 给 n78 接上 GL 桥（`QEMU_CALL` 陷入加 `gles-host`）后，7.1.2 从 USB 盘加格式化好的 NAND 开机，第 120 秒屏幕上是 UI 栈画的苹果标志，第 180 秒是设置助理的「Hello / slide to set up」，状态栏有「iPod」和电池图标。这是模拟的 A5 第一次画出 iOS 的界面。【已核实：截图 `work/a5/runs/s314/gl1/shot-120.png`、`shot-180.png`，即下面两张】

![A5 第 120 秒：UI 画的苹果标志](img/a5-gl-logo.png) ![A5 第 180 秒：Hello](img/a5-gl-hello.png)

### 3.14.1 先查清是谁在崩

上一轮（3.13 节）的正常开机都用 `snapshot=on`，崩溃日志随快照丢了。这次用盘的 APFS 克隆可写开机（`work/a5/nandfmt/disk-c1.img`，NAND 用格式化好的存储的克隆），150 秒后在 Mac 上挂数据卷读 `/private/var/mobile/Library/Logs/CrashReporter`：

1. **崩的是 backboardd，不是 SpringBoard。** 150 秒里 11 份 `backboardd_*.ips`，大约每 10 秒一份，没有 SpringBoard 的。【已核实】
2. **第一份（开机后约 17 秒）是 GL：** `EXC_BAD_INSTRUCTION (SIGILL)`，异常码 `0xee6f6f1f`，崩在 OpenGLES（QuartzCore 经 IOMobileFramebuffer 调进来）。0xee6f6f1f 就是 `mcr p15,3,r6,c15,c15,0`，GL 前端发给宿主的 `QEMU_CALL` 陷入，n78 没有这个协处理器寄存器，于是未定义指令。【已核实：`work/a5/nandfmt/disk-c1.img` 数据卷里的 `backboardd_1969-12-31-160017_localhost.ips`】
3. **其余十份在 CompassPlugIn：** `EXC_BAD_ACCESS`，地址 0xc，主线程，调用链 backboardd → IOKit → `/System/Library/HIDPlugins/CompassPlugIn.plugin`（HID 事件系统的会话过滤插件，没有匹配字典，所有服务都过它）。【已核实】见 3.14.3。

### 3.14.2 接上的东西（`hw/arm/ipod_touch_5g.c`）

照 `hw/arm/ipad1.c`：CPU 实例化后 `define_arm_cp_regs` 注册 `QEMU_CALL`（cp15，opc1 3，c15，c15，0，用户态可用），写入时调 `qc_handle_gles`（`QC_GLES`）和回 ping（`QC_GLES_PING`）；复位时 `gles_host_reset()`；机型类上 `gles_host_class_init()`（加 `gl-renderer` 属性）。剪贴板、guest 包、guest agent 这些 guest 服务没接，它们的调用不回答。设备树里的 SGX 仍然隐藏（compatible 为 none），和 A4 机型一样：GL 前端不经过内核的 SGX 驱动。

开机时 QEMU 打出（`work/a5/runs/s314/gl1/qemu.out`）：`host GL up: 2.1 Metal ... Apple M4 Max, present by readback`、`OpenGLES front end (contrib/gles-public): 508 gl exports`、`dispatch layout ...: 1035 slots`、`CoreAnimation composites through the host`。【已核实】

### 3.14.3 还没弄清或没做的

1. **CompassPlugIn 里的崩溃仍在，但是间歇性的：** 接上 GL 桥后，开机头 75 秒左右 backboardd 仍在 CompassPlugIn 里崩了 7 次（`work/a5/nandfmt/disk-c2.img` 的数据卷），之后不再崩，界面出来。崩溃报告给的 PC（插件 +0x1408、+0x1f88）在文件里分别是一条 `mov.w` 和 `__stub_helper` 与 `__symbolstub1` 之间的位置，都不访问内存；寄存器 r0 = 0xc，lr 指向系统库。所以报告里的 PC 不可信，或者运行时这段代码页的内容和文件不同。原因没查清，可能和加速度计、陀螺仪探测失败（`AppleEmbeddedI2CNewAccelerometer::free`、`AppleAP3GDL::probe ... ID=0x0`）、懒绑定，或者模拟器本身有关。【推测】它拖慢了开机（launchd 每次重启 backboardd 要等约 10 秒）。
2. **GL 线协议告警：** QEMU 打出 `the host speaks another wire protocol: GL calls may go astray` 和 `REFUSED shim:hello:protocol`。界面画得出来，但要核对系统卷里 GL 前端（FirmwareKit 装的 guest 工具）和这份 QEMU 的协议版本是否一致。【推测：前端和宿主不是同一次构建】
3. **为什么是「Hello」而不是锁屏：** 数据卷里 `com.apple.purplebuddy.plist` 的 `SetupDone`、`SetupFinishedAllSteps` 都是 true，lockdown 的 `data_ark.plist` 是 `FactoryActivated`，设置助理还是出来了。可能和设备身份（kboot 的序列号、ECID 与 FirmwareKit 做激活记录时用的不一致）有关。【推测】没有触摸也滑不过去。
4. 9.3.5 没试。

### 3.14.4 下一步

1. 查 CompassPlugIn 的间歇崩溃（gdb 在 backboardd 崩溃时看真实的 PC 和指令字节）。
2. 让设置助理不再出现，进锁屏：核对设备身份和激活记录。
3. 触摸（spi1 上的 multi-touch）、复位、电池和时钟。

## 3.15 锁屏：越过设置助理

**结论：** 7.1.2 在模拟的 iPod touch 5 上开机直接进了锁屏，不需要触摸：第 100 秒左右出现「slide to unlock」、时间、日期和相机图标，约 20 秒后自动熄屏。用 `tools/a5/n78_diskfix.sh` 从格式化后的盘一步改出两块克隆，同时开机，两次都进了锁屏，数据卷里都没有崩溃报告。【已核实：`work/a5/runs/s315/fix3a/shot-100.png`、`fix3b/shot-120.png`；崩溃日志目录在 `work/a5/nandfmt/disk-fix-a.img`、`disk-fix-b.img` 的数据卷】

![A5 锁屏](img/a5-lockscreen.png)

屏幕上那条「Cannot Use Device: QEMU USB HARDDRIVE」是 MobileStorageMounter 对我们挂根用的 USB 盘发的通知（FirmwareKit 的 `it_msmquiet` 在这个固件上不适用，fit.json 里已注明），不影响开机。时间是 1969-12-31 那个时间，因为还没有实时时钟。

一共做了四件事，前三件改的是盘，第四件改的是 QEMU。

### 3.15.1 激活：lockdownd 的本地激活补丁

- **FirmwareKit 对 n78 没打激活补丁。** 系统卷里的 lockdownd 和 IPSW 原版的哈希一样（`261017f5…`）。FirmwareKit 的 CActivation 在这份 lockdownd 上报 `no supported activation path`，于是退回到「只在 data_ark 里写 FactoryActivated」（这本来是 iOS 6 的路线）。【已核实：用 FirmwareKit 自带的 `activation.c` 编出命令行，对原版 lockdownd 跑 `--probe`】
- **补丁位置：** lockdownd 的 `dealwith_activation`（VA 0xfecc）里，`bl 0x22180; cmp r0,#1; bne 0xfffc` 决定要不要把激活状态短路成 Activated（日志 `Short circuiting activation state to Activated.`）。0x22180 返回的是「是否 hactivate」，由 MobileGestalt 的 ShouldHactivate 或 `hw.model` 以 DEV 结尾决定，iPod touch 5 上为假。把 0xff1a 的 `bne`（文件偏移 0xef1a）改成 `nop`，这条分支就总会走。A4 机型上 FirmwareKit 做的是同一件事，只是它的匹配器认不出这份代码的形状。【已核实：反编译 `work/a5/dis/pc-lockdownd-n78/functions/0xfecc.c`、`0x221b4.c`】
- **工具：** `tools/a5/n78_activate.py` 先核对原版哈希和 0xef18 处的 4 个字节，再原地改，属主不变。代码签名没有重签，靠开机参数 `amfi_allow_any_signature=1`、`cs_enforcement_disable=1` 放行。全程不连苹果服务器。
- **结果：** 开机后 data_ark 里的 `com.apple.mobile.lockdown_cache-ActivationState` 从 FactoryActivated 变成 Activated。但只改这一项，设置助理照样出来（`work/a5/runs/s315/act3/shot-110.png`，日文的「こんにちは」）。所以激活不是决定因素。【已核实】

### 3.15.2 设置助理：补上 iPhone 4 没有的步骤

FirmwareKit 的 `FinishedSetup` 是在 iPhone 4（n90）11D257 上对比「走完设置助理前后的数据卷」得出的键。iPod touch 5 的设置助理比 iPhone 4 多几步：Setup.app 里的完成标记有 `AssistantPresented`（Siri）、`ActivationLockPresented`、`KeychainSyncPresented`、`PBEmailUpdatesPresented`，前一个就是 iPhone 4 不支持的 Siri。把这四项置为 true，写进 `mobile/Library/Preferences/com.apple.purplebuddy.plist`，开机就直接进锁屏（`work/a5/runs/s315/act4/shot-100.png`）。【已核实：设置助理出现与否只差这四个键。至于真正起作用的是 Siri 这一项还是其中几项，没有逐个试】

### 3.15.3 backboardd 在罗盘插件里间歇崩溃：先移走插件

- **现象：** backboardd 在 CompassPlugIn 里崩，偶尔也在 CompassBacklightCompensation 里崩：`EXC_BAD_ACCESS` 访问地址 0xc，r0 = 0xc。两个都是 `/System/Library/HIDPlugins` 下罗盘相关的 HID 会话过滤插件。大约一半的开机会一直崩下去，屏幕停在转圈：act1 崩 20 次，fix2 跑 300 秒崩 11 次。另一半在几次崩溃后活下来，或者根本不崩。【已核实】
- **排除了 HFS 压缩：** 两个崩溃点都落在插件 __TEXT 的第二页，又都不是访存指令，我先猜是客体解压 HFS 压缩文件出了错。把插件改成不压缩存放后，act2、act4、act6 三次都没崩，但 fix1、fix2 两次照崩，崩溃点不变（+0x1408）。所以和压缩无关，前面那几次只是碰巧。【已核实】
- **现在的做法：** iPod touch 5 没有罗盘，就把这两个插件移到 `/System/Library/HIDPlugins.disabled/`（`n78_diskfix.sh`）。之后两次验证开机都没有崩溃。【已核实】
- **根因没查到。** 大概是插件读到我们模拟得不完整的传感器服务，加速度计和陀螺仪探测都失败了，然后解引用空指针；崩溃报告给的 PC 也不可信。要查得用 gdb 在崩溃那一刻看真实的 PC 和指令字节。【推测】

### 3.15.4 GL 协议告警：n78 没接 guest 包服务

3.14 节里的 `the host speaks another wire protocol` / `REFUSED shim:hello:protocol`，原因不是前端和 QEMU 的构建版本不同：GL 前端的 hello 走的是 guest 包服务（`contrib/it-gles/gles_dispatch.c` 的 `GLES_HELLO_PROTO`），而 n78 的 QEMU_CALL 只接了 GL 调用本身。照 `ipad1.c` 接上 `guest_pkg_init`、`guest_pkg_reset`、`guest_pkg_call` 以后，QEMU 打出 `shim hello: protocol 1, name table ad3b3412 (host: 1, ad3b3412)`，告警消失。系统卷里的 it_boot 也开始有回答（`it_boot: package 38 (read-only root)`）。【已核实：`work/a5/runs/s315/act6/qemu.out`、`act6/serial.log`】

### 3.15.5 复现

格式化开机按 3.13 节做；然后对格式化后的盘克隆跑 `tools/a5/n78_diskfix.sh`。它会改 fstab 为 disk1、放 `.it_sealed`、打 lockdownd 补丁、移走罗盘插件、补设置助理的四个键。最后正常开机（`tools/a5/README.md`）。

### 3.15.6 下一步

1. 罗盘插件崩溃的根因（gdb）。加速度计和陀螺仪也该有模型（i2c2 上的 ap3dsh、ap3gdl）。
2. 触摸（spi1 的 multi-touch），才能解锁进主屏。
3. 复位、电池、实时时钟。屏幕熄了以后要靠按键唤醒，也就是要有按键。
4. 9.3.5。

## 3.16 触摸和按键：解锁进了主屏，点开了「设置」

**结论：** 给 n78 接上 spi1 上的触摸传感器和 GPIO 按键后，用脚本经 QMP 注入输入，7.1.2 从锁屏滑动解锁进了主屏，点按打开了「设置」，按 Home 又回到主屏。全程不用人点。【已核实：`work/a5/runs/s316/t3/in-156.png`（主屏）、`t5/in-190.png`（设置）、`t5/in-205.png`（按 Home 回主屏），即下面几张】

![A5 主屏](img/a5-homescreen.png) ![A5 设置](img/a5-settings.png)

### 3.16.1 触摸链路（7.1.2 n78）

- **设备树：** `arm-io/spi1/multi-touch`，compatible `multi-touch,n78`，中断接 GPIO 控制器的 0x15（和 A4 的 Zephyr2 ATN 一样，是引脚 0x205）。电源走 PMU 的 LDO，复位、片选走 GPIO，时钟走 PWM。spi1 在 arm-io +0x2100000，AIC 中断 0x1d。【已核实：`work/a5/dec/11D257/DeviceTree.txt`】
- **驱动：** AppleMultitouchN1SPI，personality「C1,N78」，`mt-merge-personality` 是 `C1F58,1`，和 A4 的 n81、n90 是同一个驱动类。固件不在内核里：由用户态的 mtmergeprops 从系统卷的 `/usr/share/firmware/multitouch/N78.mtprops` 读出 `C1F58,1` 条目（`Constructed Firmware` 61520 字节、版本 0x0264、Z2 引导包），合并进驱动后一次下发。【已核实】
- **按键：** 设备树 `buttons` 节点，Home（menu）、电源（hold）、音量加、音量减分别是 GPIO 引脚 0、1、2、3，低电平有效；唤醒另走 PMU（`function-wake_button_*`）。【已核实】

### 3.16.2 接上的东西（`hw/arm/ipod_touch_5g.c`）

全部复用 A4 机型现成的模型（`hw/arm/ipad1.c` 的接法）：

- spi1 用 iPod 的 SPI 模型，外设是 multitouch。发送 FIFO 设为 0x10000，一次装得下 61520 字节的固件；固件经 CDMA 写进来。
- 触摸是 iPod 的 Zephyr2 协议模型。ATN 接 GPIO 引脚 0x205。n78 用新的 profile：族号 0x58，版本 0x264，行列数照 A4 iPod；面积按 4 英寸屏算（5000 × 8860），坐标框按 n81 的值放大到 1136 行。
- QEMU 的绝对坐标指针（QMP `input-send-event` 的 abs 加左键）转成一根手指。
- 键盘 H、L、=、- 分别对应 Home、电源、音量加、音量减，四个引脚静止时拉高。

PMU 唤醒没有做：D1881 还只是一组寄存器。不过熄屏后按 Home 能把屏幕点亮回到锁屏，因为 AP 没有真正睡下去。【已核实：`work/a5/runs/s316/t2/in-128.png`】

### 3.16.3 脚本化输入（`tools/a5/qinput.py`）

按时间表经 QMP 执行动作：`T:shot` 截图，`T:key:h` 按键，`T:tap:X,Y[,MS]` 点按（默认按住 300 毫秒，期间每 50 毫秒补一次同位置移动），`T:swipe:X0,Y0,X1,Y1[,MS]` 滑动。坐标是屏幕像素（640×1136）。复现：开机后约 148 秒按 Home 唤醒，152 秒从 (140,975) 滑到 (620,975) 解锁，160 秒点 (92,920) 打开「设置」，见 `tools/a5/README.md`。

### 3.16.4 还没弄清或没做的

1. **纵向校准不准：** 点 (92,800)（「设置」图标）打开的是上一行的「报刊杂志」（`work/a5/runs/s316/t4/in-172.png`）；点 (92,920) 才打开「设置」。也就是 y 在 800 到 900 一带，实际落点比瞄准点偏上约 100 像素。原因是坐标框和面积参数是按比例推的，没实测。要像 A4 那样用网页记点位，按轴拟合。【推测】
2. **点按要按住一会：** 120 毫秒的点按没打开应用（`t3`），按住 300 毫秒才行。可能是传感器帧的节奏，没细查。【已核实现象，原因为推测】
3. **开机时间不稳：** 同一块盘，锁屏有时 100 秒出现，有时要等按 Home 才看到（`t2`）。脚本里先按 Home 再解锁，就不受影响。
4. 自动锁定没有改；锁屏约 20 秒后熄屏，按 Home 能唤醒。
5. 多指、旋转、音量键没有测；PMU 唤醒、复位、实时时钟、罗盘插件崩溃的根因、9.3.5 仍待做。

## 3.17 9.3.5（13G36）：锁屏、主屏、打开「设置」

**结论：** 9.3.5 在模拟的 iPod touch 5 上开机进了锁屏，滑动解锁到主屏，点开了「设置」。从已经过首次数据迁移的盘开机，约 80 秒到锁屏（第一次开机多一段约 100 秒的迁移进度条）。【已核实：`work/a5/runs/s317/b4/in-83.png`、`in-90.png`、`in-25.png`】7.1.2 用同一套新脚本和新开机包回归，90 到 110 秒照旧锁屏。【已核实：`work/a5/runs/s317/r712/in-100.png`】

| 锁屏 | 主屏 | 「设置」 |
|---|---|---|
| ![9.3.5 锁屏](img/a5-935-lockscreen.png) | ![9.3.5 主屏](img/a5-935-homescreen.png) | ![9.3.5 设置](img/a5-935-settings.png) |

主屏上那个「Trust This Computer?」是 lockdownd 的配对提示（USB 设备模式起来了，以为连着电脑），点「Don't Trust」就关了。比 7.1.2 多做的事，按卡住的先后：

1. 两分区盘自己做（FirmwareKit 没有 iOS 9 配方）：`tools/a5/n78_volumes.py`。
2. 格式化帮手要带 `com.apple.private.security.disk-device-access` 等授权，9.x 的平台沙盒不让它读裸盘。
3. 共享缓存改成开发版（头 +0x68 置 0，同时重算签名第 0 页的哈希），dyld-390 才用磁盘上的 GL 前端：`tools/a5/n78_devcache.py`。
4. GL 前端补 iOS 9 的 4 个颜色格式导出（GLKit 强绑定）和 EAGLContext 的 `debugLabel`、`multiThreaded`（CoreImage 发 `setDebugLabel:`，SpringBoard 原来崩在这里）。
5. 设备树隐藏两个 M2 缩放器（9.3.5 的 SpringBoard 一用就让内核 panic），隐藏时连 `device_type` 一起改。
6. 激活补丁从 lockdownd 移到 mobileactivationd；设置助理靠 `ForceNoBuddy`。

前半部分（3.17.1 到 3.17.3）是上一段的交接记录，3.17.4 是这一段按步骤的过程记录。

### 3.17.1 已核实

1. **IOP 模型对 9.3.5 原样可用。** 9.3.5 的恢复内存盘当根、放出 IOP 和闪存控制器（`work/a5/kboot/n78-13G36-fmi-rd.bin`）开机：AppleA5IOP 起来，固件是 iBoot-2817.60.2；IOP 依次收到 set_config、0x16（控制器信息）、0x17、0xb（读引导页）；分区方案读引导页，报 `no partition table found`。和 7.1.2 一样，cnfg 块和消息环都不用改。【已核实：`work/a5/runs/s317/p1/serial.log`、`q.log`】
2. **格式化在 9.3.5 上也通。** 9.3.5 的恢复内存盘副本（`work/a5/nandfmt/rd-13G36.dmg`，做法同 3.13.3）加 `it_nandfmt`、`nand-enable-reformat=1`，挂 `13G36-usbroot.img`：VFL、FPart、FTL 依次格式化，`Writing final signature`、`VFL_Open [OK]`、`FTL_Open [OK]`，`AppleNANDFactoryBBT::start: ready`，可擦除存储 `started`，`it_nandfmt: NAND partition format -> 0`。IOP 约 1.6 万个命令，各种页状态都认。7.1.2 上调好的 PPN 设置（`max-transaction-size` 32、空白页 0x49、按列读半页）在 9.3.5 的 SwissPPN 上同样成立。【已核实：`work/a5/runs/s317/f1/serial.log`】
3. **帮手的误报：** 那次帮手最后报 `FAILED: no AppleEffaceableStorage`，其实可擦除存储已经起来了。帮手在同一个循环里同时等数据卷和服务，`13G36-usbroot.img` 只有一个分区，短路求值导致服务没被取到。要修：分开等两样东西，并给出准确的报错。用两分区的盘就不会碰到。【已核实：`tools/a5/it_nandfmt.c`】**更正（3.17.4）：** 两分区盘照样报这个错，根因是 9.x 的平台沙盒不让没授权的帮手读 `/dev/disk0s2`，循环已拆开。

### 3.17.2 交接时列的下一步（都已在 3.17.4 做完）

1. **做 9.3.5 的两分区盘。** FirmwareKit 没有 iOS 9 的配方：A4 机型最高到 7.1.2，`patches/a5-firmwarekit-n78-volumes.patch` 是让 n78 借 n90 的 iOS 7 配方，对 13G36 不适用。所以要么给 FirmwareKit 加 iOS 9 配方，要么不用它：系统卷用 `n78_usbroot.py` 从解密的 rootfs 扩容，数据卷照 FirmwareKit 的做法新建日志式 HFSX、放 `/private/var` 骨架并写属主。【推测：工作量主要在后一种】
2. **9.3.5 用户态的两个已知问题**（第 0 步报告 4.3、第 5 节，3.12.3）：
   - dyld-390 要求共享缓存是开发版，才允许用磁盘上的库覆盖缓存里的库；GL 前端、AppSync、guest 工具都靠这种覆盖。
   - 新的 launchd 从 `xpcd_cache.dylib` 读守护进程清单，往 `/System/Library/LaunchDaemons` 放的 plist 可能不生效，`it_boot`、`it_seal` 等装法会受影响。
   a5-launchd 会话查过一部分，先读它的记录。
3. **盘上修改要按版本分开**（`n78_diskfix.sh`）：
   - `n78_activate.py` 只认 11D257 的 lockdownd（哈希加偏移写死），9.3.5 要另找 `dealwith_activation` 里同样的判断；
   - 设置助理的完成标记要看 9.3.5 Setup.app 的键（iOS 8、9 新加了步骤）；
   - fstab 仍是 disk1（NAND 的 FTL 盘占 disk0）；
   - 罗盘插件是否同样要移走；
   - `.it_sealed` 只有装了 it_seal 才需要。
4. **GL 前端：** 系统卷里的前端（contrib/gles-public）要在 9.3.5 上验证。第 0 步核对过，GL 派发表三代逐字节相同，但跳板形状没核对；加上上面第 2 条的覆盖问题。
5. 然后依次是：正常开机、锁屏、解锁、「设置」。n78 机型这边（触摸、按键、GL 桥、guest 包服务）不用为 9.3.5 改。【推测】

### 3.17.3 现场

- 内核、设备树、恢复内存盘：`work/a5/dec/13G36/`。
- 9.3.5 格式化用的内存盘：`work/a5/nandfmt/rd-13G36.dmg`。
- 这次格式化出的 NAND 存储：`work/a5/nandfmt/nand-935/`。它没有建系统钥匙包，可擦除存储也没格式化，给正式的两分区盘做格式化开机时要重来。

### 3.17.4 第二段（同一会话续做，按 3.17.2 的顺序）

**第 1 步：两分区盘（完成）。**

- 新脚本 `tools/a5/n78_volumes.py ROOTFS.dmg OUTDIR [系统卷加大 MiB] [数据卷 MiB]`：系统卷用 imgtools 的 `extract_rootfs` 从解密的 rootfs 切出，再用 `grow_to_partition` 加大 512 MiB（留给 GL 前端和帮手）；数据卷照 FirmwareKit `SystemEdits` 的做法：14 GiB 稀疏、日志式、区分大小写的 HFSX，经 noowners 挂载拷入系统卷的 `/private/var` 骨架，再按系统卷目录里的属主离线改回（没有记录的按规则：`mobile`、`ea` 归 501，其余归 root），最后打开内容保护位（卷头属性 0x40000000，5.0 起恢复都这样格式化）。不做其他修改，fstab、激活、设置助理都留给 `n78_diskfix.sh`。【已核实：`work/a5/vol-13G36/build.log`】
- 结果：`system.img` 2524 MiB，HFSX，4 KiB 块，空闲 131835 块（约 515 MiB）；`data.img` 属主 0:0×27、0:1×1、0:3×1、24:24×1、25:25×2、33:33×1、64:0×1、501:501×29，共改 63 条目录记录。整个过程 8 秒。【已核实：同上】
- 拼盘：`python3 -I -B tools/a5/n78_usbroot.py work/a5/vol-13G36/system.img work/a5/disks/13G36-full.img work/a5/vol-13G36/data.img`，分区 1 System 在 LBA 2048，分区 2 Data 在 LBA 5173248，整盘 16863 MiB（稀疏，实占约 2 GB）。【已核实】
- 9.3.5 原版 fstab 是 `/dev/disk0s1 / hfs ro` 加 `/dev/disk0s2 /private/var`，和 7.1.2 一样要改成 disk1。系统卷里有 `dyld_shared_cache_armv7`，没有 `System/Library/Caches/com.apple.xpcd/`。【已核实：只读挂载 `vol-13G36/system.img` 查看】

**第 2 步：dyld 覆盖和 launchd 清单（静态结论，开机验证见后）。** 文件从 `vol-13G36/system.img` 拷到 `work/a5/vol-13G36/x/`（dyld、launchd、共享缓存），反编译用 REA（Ghidra），launchd 的大函数存在 `work/a5/dis/launchd-935-17d84.c`。

- **dyld-390 开哪个缓存**（`dyld::openSharedCacheFile`，0x1fe03226）：`enable-dylibs-to-override-cache` 存在且小于 1 KiB、并且 `dyld_shared_cache_armv7.development` 存在时开 `.development`；否则生产版缓存不存在时也开 `.development`；其余开生产版。【已核实】
- **何时允许磁盘库覆盖缓存**（`dyld::loadPhase5`，0x1fe077c4）：comm page 0xFFFF4084 第 0 位为 1，并且缓存头 +0x68 的 64 位 `cacheType` 为 0，才先 stat 磁盘上的库（`loadPhase5stat`），找到就用磁盘版；否则直接用缓存。`dyld::mapSharedCache`（0x1fe06390）在同样条件下还会不建 `ImageLoaderMegaDylib`（开发版缓存不走加速表）。【已核实】
- **缓存签名：** 13G36 的缓存在 0x1f58c000 有签名块，是 ad hoc（CodeDirectory flags 0x2，CMS 槽只有 8 字节），SHA-1、4 KiB 一页，共 128396 页，第 0 页哈希与文件吻合。dyld 映射前用 `fcntl(0x61)` 登记签名，失败就抛异常；之后把头 0x2000 字节 mmap 成可执行再和 read 到的比较。所以只改 +0x68 而不改第 0 页的哈希，页校验会失败。做法：+0x68 改 0，同时把 CodeDirectory 第 0 槽换成新页的 SHA-1。CDHash 随之改变，不在内核信任缓存里，能不能过要看 `amfi_allow_any_signature=1 cs_enforcement_disable=1`（我们自己的 ad hoc 帮手在这组参数下能跑）。【前半已核实，能否放行待开机】
- **开发位：** kboot 强制设备树 `debug-enabled` = 1（`imgtools/ipad1_kboot.py` 395 行），`PE_i_can_has_debugger` 为真，comm page 开发位应为 1。【推测，开机时读 0xffff4084 确认】
- **launchd 765.50.8 读清单的规则：** 开机时只在 `xpcd_cache.dylib` 在磁盘上**不存在**时才 dlopen 缓存里的那份（`FUN_0000513c`：`lstat` 成功就不读），所以往磁盘放一份改过的 `xpcd_cache.dylib` 会让 launchd 拿不到清单，「No service cache」后退出。`/System/Library/LaunchDaemons` 下的 plist 逐个去缓存里查，查不到就当错误丢掉（`FUN_000055cc`，类型改 4、错误 0x94），只有不在 `/System/Library` 下的路径才从磁盘读。决定这一切的开关是 `kern.bootargs` 里有没有子串 `rd=md0`（`FUN_0002675c`，结果写 0x3684d）：恢复内存盘开机时为真，「disk will be searched for uncached services」；正常开机为假，「system services must be in cache」。【已核实】
- **对本轮的影响：** 到锁屏和「设置」不需要新增守护进程（7.1.2 走到主屏也只改了 fstab、lockdownd、设置助理标记、罗盘插件和 GL 前端），所以 xpcd_cache 先不处理。以后要加守护进程，可试两条路：启动参数里放一个含 `rd=md0` 子串、但内核不认的参数（如 `it_rd=md0`；内核按参数名整词匹配 `rd`）【推测，副作用没查：开关还控制 ASL 日志等几处】；或者包一个缓存里已有、不关键的守护进程。【推测】

**格式化开机第一次失败（`work/a5/runs/s317/fmt2`）：** NAND 分区、VFL、FTL 都格式化好了（`it_nandfmt: NAND partition format -> 0`），之后帮手每秒被拒一次：`Sandbox: restored_externa(5) System Policy: deny(1) file-read-data /dev/disk0s2`，最后报 `FAILED: no AppleEffaceableStorage`。9.x 的平台沙盒不让没有授权的进程读裸盘；原版 restored_external 带 `com.apple.private.security.disk-device-access` 等 9 个授权。3.17.1 第 3 条说的「两分区盘就不会碰到」不对，单分区那次大概也是同一个原因。【已核实】修法：帮手按 `tools/a5/it_nandfmt.ent`（原版的 4 个相关授权）用 `ldid -Stools/a5/it_nandfmt.ent` 签名；帮手里等服务和等数据卷拆成两个循环，各报各的错。重做了 `nandfmt/rd-13G36.dmg` 和 `kboot/n78-13G36-nandfmt.bin`。

**第 3 步：9.3.5 格式化开机（完成，`work/a5/runs/s317/fmt3`）。** 带授权的帮手这次一路走完：`effaceable open 0 isFormatted 0 -> 0`、`format 0`、数据卷 `/dev/disk1s2`、`MKBKeyBagCreateSystem -> 0, /mnt2/keybags/systembag.kb 1495 bytes`、`system keybag created; halting`。中间内核报了两行 `[effaceable:ERR ] unable to efface group 0/1 after 3 attempts`，没有影响建钥匙包，正常开机时再看可擦除存储是否认得。【已核实：`work/a5/runs/s317/fmt3/serial.log` 218 到 240 行】成品：盘 `work/a5/nandfmt/disk-935-formatted.img`，NAND 目录 `work/a5/nandfmt/nand-935-formatted/`（实占 2.3 GB）。以后开机都用 `cp -c` 克隆。命令：

```bash
cp -c work/a5/disks/13G36-full.img work/a5/nandfmt/disk-935.img && mkdir -p work/a5/nandfmt/nand-935f
IOP_TRACE=1 DISK=work/a5/nandfmt/disk-935.img SNAP=off tools/a5/n78_run.sh work/a5/runs/s317/fmt3 work/a5/kboot/n78-13G36-nandfmt.bin 420 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-935f -D work/a5/runs/s317/fmt3/q.log
# 帮手打出 "system keybag created; halting" 后约 15 秒按 PID 结束 QEMU
```

**第 4 步：盘上修改按版本拆开（完成），GL 前端补了 9.x 的导出。**

- **激活搬家了。** 9.3.5 的 lockdownd 已经没有「Short circuiting」那段，它向 mobileactivationd 要激活状态（`MAEGate_GetActivationState`）。同一段逻辑在 `/usr/libexec/mobileactivationd` 的 `dealwith_activation`（0xb428，MobileActivation-96.60.1）：`bl 0x1a6bc; cmp r0,#1; bne` 后接 `bl 0x1a670; cmp r0,#0; beq 短路`，日志 `Hactivation is enabled, short circuiting activation state to Activated.`。把 0xb448 的 `bne`（文件偏移 0x7448，`03 d1` 改 `00 bf`）去掉，和 7.1.2 是同一个补丁。`tools/a5/n78_activate.py` 改成按 SHA-1 认两份原版（11D257 lockdownd `261017f5…`、13G36 mobileactivationd `b2f628f3…`），可重复执行。【已核实：反编译和字节；运行效果待开机】
- **设置助理：** 9.3.5 的盘没有 FirmwareKit 的种子，新脚本 `tools/a5/n78_setupdone.py` 写一个超集：13G36 Setup.app 和共享缓存里出现的所有 `…Presented` 键（`AppleIDPB9Presented`、`Passcode4Presented`、`LocationServices5Presented`、`Payment2Presented`、`TrueTonePresented` 等 34 个键），加 `SetupDone`、`SetupFinishedAllSteps` 和 7.x 的云配置记录。`SetupVersion` 填 7 是猜的（6.x 是 3，7.x 是 5）。【推测，待开机】
- **GL 前端缺 4 个导出。** 用缓存的导出字典树把 9.3.5 原版 OpenGLES 的 489 个导出解出来（`work/a5/vol-13G36/x/opengles-13G36.exports`），和前端比，只缺 `kEAGLColorFormatRGBA_XR10_64BPP`、`kEAGLColorFormatSRGBA_XR10_64BPP`、`kEAGLColorFormatSRGB_XR10`、`kEAGLColorFormatSRGB_XR10_A8_2P`。再扫全缓存 971 个镜像的绑定表，只有 GLKit 强绑定这 4 个，缺了它们，凡加载 GLKit 的进程在覆盖后都会绑不上。前端 `contrib/gles-public/opengles.c` 按原版字符串值补了这 4 个常量，`opengles.exports` 加了 4 行，重编到 `work/a5/guest/OpenGLES`（`build.sh`，替代 SDK），之后 9.3.5 的导出全覆盖。改动在 `work/a5/qemu-ios` 里，随补丁导出。【已核实：nm 对比为 0 缺】
- **缓存改开发版：** `tools/a5/n78_devcache.py` 把 +0x68 改 0 并重算签名第 0 槽（只动 20 个字节，可重复执行）。
- **`tools/a5/n78_diskfix.sh` 现在按 `SystemVersion.plist` 的 `ProductBuildVersion` 分支：** 两版都改 fstab、打激活补丁、移走罗盘插件（9.3.5 也有这两个插件，先照做）；11D257 照旧放 `.it_sealed`、补 4 个设置键；13G36 改缓存为开发版、装前端（`GLES=` 可换，默认 `work/a5/guest/OpenGLES`，装完离线把属主改回 root）、写设置助理种子。在 `disk-935-formatted.img` 的克隆上一次跑通。【已核实】

**第 5 步：GL 前端在 9.3.5 上加载了（`work/a5/runs/s317/b1`）。** 正常开机包 `kboot/n78-13G36-fmi.bin`（`N78_SHOW=arm-io/iop,arm-io/flash-controller0`，不带内存盘），盘 `nandfmt/disk-935-a.img`（格式化后的克隆跑过 diskfix），NAND `nandfmt/nand-935a`（格式化后的克隆），330 秒。

- comm page 0xffff4084 每次读都是 1，开发位成立。【已核实：`b1/mem.txt`】
- 改过的缓存映射成功，没有 dyld 报错；改过的程序 AMFI 照常放行（`AMFI: Invalid signature but permitting execution`）。【已核实：`b1/serial.log`】
- 可擦除存储认出第 3 代，`MKB_INIT: System Keybag loaded`，数据保护起来了。【已核实】
- **dyld 用上了磁盘上的前端：** QEMU 打出 `shim hello: protocol 1`、`OpenGLES front end (contrib/gles-public): 508 gl exports … ES 1.1 + 2.0 (GLEngine.bundle); IOSurface`、`dispatch layout from the @encode's count … 1035 slots`、`CoreAnimation composites through the host`。所以「缓存头改 0 加第 0 页重算哈希」这条路在 9.3.5 上走通了。【已核实：`b1/qemu.out`】
- 画面：120 秒是苹果标志加一条空进度条（iOS 9 首次开机的数据迁移界面，backboardd 用 GL 画的），210 秒起只剩苹果标志，到 300 秒没变。【已核实：`b1/shot-120.png`、`shot-210.png`、`shot-300.png`】
- **卡点：SpringBoard 每隔几秒崩一次**（数据卷里 10 份 `SpringBoard-*.ips`）：主线程 SIGABRT，栈是 SpringBoardFoundation → UIKit → CoreImage → CoreFoundation 的 `___forwarding___` → `doesNotRecognizeSelector:` → 抛异常。把 9.3.5 原版 EAGLContext、EAGLSharegroup 的方法表从缓存的 ObjC 元数据里解出来（`work/a5/vol-13G36/x/eagl-13G36.methods`），和前端比，缺 `debugLabel`、`setDebugLabel:`、`isMultiThreaded`、`setMultiThreaded:`、`setBlockFence:onQueue:` 等；再扫全缓存的 `__objc_selrefs`，发 `setDebugLabel:` 的正是 CoreImage 和 GLKit，`isMultiThreaded` 是 CoreMotion，`setBlockFence:onQueue:` 是 MediaToolbox。【已核实】前端补了前四个（EAGLContext 存在私有结构里，EAGLSharegroup 加一个实例变量），`setBlockFence:onQueue:` 只有视频用到，没补。
- 另有 mediaserverd 前几分钟崩了 11 次：相机的 `HDR.videoprocessor` 初始化时抛 C++ 异常（没有模拟相机），和到锁屏无关。【已核实】

**第二次开机（`work/a5/runs/s317/b2`，前端补了 EAGL 方法，盘 `disk-935-b.img` 是 a 盘开过一次后的克隆，已过数据迁移）：** 90 秒起画面变成状态栏（「iPod」、电池）加灰色苹果标志，说明 SpringBoard 起来并开始画了；之后一直不变。串口里内核 panic：`AppleM2ScalerCSCHalSamsung::resetScaler(): cannot reset the scaler 0`，panic 的任务是 SpringBoard（pid 48），前面是一串 `Scaler waiting for device reset step 2 to complete.`。缩放器驱动开机时就读到 `SOC 0x0, Scaler HW Version 0x0`（我们没模拟这个块，寄存器全零）；9.3.5 的 SpringBoard 一用硬件缩放器，复位等不到完成就 panic。7.1.2 没走到这条路。【已核实：`b2/serial.log` 440 行、`b2/shot-150.png`】下一步先试在开机包里隐藏 `arm-io/scaler0`（`N78_HIDE`），看 SpringBoard 会不会退回软件路径。

**第三次开机（`work/a5/runs/s317/b3`，开机包隐藏 `arm-io/scaler0`、`arm-io/scaler1`）：** 第一次只改 `compatible` 没用，缩放器驱动照样加载、照样 panic：IOKit 的 IONameMatch 也匹配 `device_type`（"scaler"）。`n78_kboot.py` 的隐藏改成 arm-io 下的节点同时把 `device_type` 改成 `-`（cpus/cpu1 不动，内核按它数 CPU；`-` 是为了放得进 ae2 只有 4 字节的 `device_type`）。之后缩放器不再加载，没有 panic，SpringBoard 没有退回失败，画面正常。90 秒前屏幕已熄，按 Home 唤醒后是设置助理的欢迎页「Hola / Deslizar para configurar」（多语言轮播）。【已核实：`b3/in-6.png`，存为 `img/a5-935-hello.png`】两个缩放器随后加进了 `HIDDEN` 的默认列表。

**设置助理的开关：** SpringBoard 导入的是 SetupAssistant.framework 的 `BYSetupAssistantNeedsToRun`。用新工具 `tools/a5/cache2elf.py` 把这个镜像从缓存切成 ELF 反编译（0x2a5e3b10）：com.apple.purplebuddy 的 `ForceNoBuddy` 为真就答「不用跑」；否则只看 `/tmp/com.apple.purplebuddy.sentinel` 在不在（设置助理那边做完才写）。之前写的那些 `…Presented`、`SetupVersion` 键在 9.x 上都不起决定作用。`n78_setupdone.py` 加上 `ForceNoBuddy = YES`。【已核实：反编译和缓存里的 CFString】

**第四次开机（`work/a5/runs/s317/b4`，盘 `disk-935-d.img` 是 c 盘的克隆再跑一次 diskfix，NAND `nand-935d`，开机包同第三次）：** qinput 在 QEMU 约 108 秒按 Home，屏上是锁屏（时间、日期、「slide to unlock」、相机）；`swipe:140,975,620,975,500` 解锁进主屏（FaceTime、日历、照片、相机等四排加 Dock，第二页小点）；点「Don't Trust」(455,785) 关掉配对提示，点「设置」(244,930) 打开设置，列表到「Wallpaper」。纵向仍要补约 100 像素（3.16 的老问题）。【已核实：`b4/in-83.png`、`in-90.png`、`in-25.png`、`qinput.log`】

**7.1.2 回归（`work/a5/runs/s317/r712`）：** 新的 `n78_kboot.py`（缩放器默认隐藏、`device_type` 一起改）重做 `kboot/n78-11D257-fmi.bin`，新的 `n78_diskfix.sh` 改 `nandfmt/disk-formatted.img` 的克隆（`disk-712-r.img`，打的仍是 lockdownd 补丁），90、100、110 秒是锁屏，120 秒熄屏，和 3.15 一致；没有缩放器日志，没有 panic。【已核实：`r712/in-100.png`、`serial.log`】

### 3.17.5 复现（9.3.5，全部在 `tools/a5/README.md`「9.3.5」一节）

```bash
# 1. 卷和盘（解密的 rootfs 见 3.11 节）
cd work/a5 && python3 -B ../../tools/a5/n78_volumes.py rootfs/13G36-rootfs.dmg vol-13G36 && cd ../..
python3 -I -B tools/a5/n78_usbroot.py work/a5/vol-13G36/system.img work/a5/disks/13G36-full.img work/a5/vol-13G36/data.img
# 2. 格式化开机（帮手要用 it_nandfmt.ent 签名，内存盘副本做法同 3.13）
cp -c work/a5/disks/13G36-full.img work/a5/nandfmt/disk-935-formatted.img && mkdir -p work/a5/nandfmt/nand-935-formatted
IOP_TRACE=1 DISK=work/a5/nandfmt/disk-935-formatted.img SNAP=off tools/a5/n78_run.sh work/a5/runs/fmt935 \
  work/a5/kboot/n78-13G36-nandfmt.bin 420 -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-935-formatted
# 3. GL 前端（work/a5/qemu-ios 打过补丁）和盘上修改
ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk bash work/a5/qemu-ios/contrib/gles-public/build.sh $PWD/work/a5/guest/OpenGLES
cp -c work/a5/nandfmt/disk-935-formatted.img work/a5/nandfmt/disk-935.img && tools/a5/n78_diskfix.sh work/a5/nandfmt/disk-935.img
# 4. 正常开机（首次多约 100 秒数据迁移），锁屏后按 Home、滑动、点设置
N78_SHOW=arm-io/iop,arm-io/flash-controller0 python3 -I -B tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36-fmi.bin
mkdir -p work/a5/nandfmt/nand-935 && cp -c work/a5/nandfmt/nand-935-formatted/* work/a5/nandfmt/nand-935/
(DISK=work/a5/nandfmt/disk-935.img SNAP=off tools/a5/n78_run.sh work/a5/runs/ui935 work/a5/kboot/n78-13G36-fmi.bin 330 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-935 &)
```

### 3.17.6 没做的和下一步

1. **缩放器只是藏起来了。** 9.3.5 的 SpringBoard 没了它也能跑，但照片缩略图、视频等用 IOSurfaceAccelerator 的地方以后可能出问题；真要用得模拟 M2 Scaler。【推测】
2. **前端没补 `setBlockFence:onQueue:`**（MediaToolbox 用，视频播放时才会碰到）。`setDebugLabel:` 等的补法、4 个导出都在补丁里，要不要提给上游由用户定。
3. **mediaserverd 在相机 HDR 插件里反复崩**（没模拟相机），没影响界面。
4. **launchd 只认缓存里的守护进程**（3.17.4 第 2 步），以后装 it_boot 一类的帮手要另想办法；`it_rd=md0` 那条路没试。
5. **设置助理是用 `ForceNoBuddy` 跳过的，**没有真正走完；`…Presented` 那些键在 9.x 上不起决定作用，留着无害。
6. 纵向触摸偏 100 像素、罗盘插件、实时时钟、复位，都是 7.1.2 留下的老问题，9.3.5 同样存在（罗盘插件在 9.3.5 上没验证是否也会崩，照样移走了）。

## 4. 测试机

用户 2026-11-03 把测试机改成 iPhone 14 Pro（iOS 27.0.1）。`xcrun devicectl list devices` 已能看到它（available, paired）。第 1 步只在 Mac 上做，这次没有用它。
