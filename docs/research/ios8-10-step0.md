# iOS 8 到 10 第 0 步：iPod touch 5 固件清点

- 日期：2026-11-02
- 作者：ios8-10-research 执行会话（接着 `docs/research/ios8-10-feasibility.md` 做）。只读分析，没写模拟器代码，没改 `upstream/`、`app/`、`scripts/`、`patches/`，没 commit、没 push，没对外联系任何人。
- 下载（用户已批准）：从苹果服务器下载 iPod5,1 的 9.3.5（13G36，1,609,091,774 字节，sha1 `8ee90db3…e05a`）和 7.1.2（11D257，1,285,647,825 字节，sha1 `f935397e…a66a`），放在 `work/firmware/`，两个 sha1 都核对通过（地址和 sha1 取自 ipsw.me 公开接口）。
- 解出来的东西：全在 `work/research/ipod5/`（内核缓存、设备树、iBoot、两个恢复内存盘、解密后的根文件系统、设备树对照表），约 2.7 GB，永不进仓库。对照用的 iPhone 4 7.1.2 解密件直接只读取自 FirmwareKit 的缓存 `work/cache/decrypted-v2/81da17b3…/`。
- 工具：没装任何第三方程序。我自己写的 Python 脚本放在 `work/research/tools/`（`fw.py` 解 IMG3、LZSS、设备树、vfdecrypt、预链接扩展表；`kc.py` 找内核扩展里的字符串和代码引用；`dsc.py` 读共享缓存；`dtdiff.py` 设备树对照；`genpass.py` 是照 xerub/genpass（GPL-2）算法的 Python 重写；`unpack.py` 一键解 IPSW），都用 `python3 -I` 跑；本机已有的 Python `cryptography` 50.0.0 做 AES/3DES；Xcode 自带的 `llvm-objdump`、`otool`；`hdiutil` 只读挂载。genpass 的两份 C 源码（posixninja/genpass、xerub/genpass）只读到 `work/research/genpass-src/` 参考，没编译。密钥取自 ipsw.me 和 tihmstar/fwkeydb。
- 标注：【已核实】直接在这次解出的二进制、设备树或源码里读到；【推测】我的推断，或要开机才能确认。

---

## 0. 结论摘要

1. **设备树（第 1 问）：** iPod 5 9.3.5 对 iPhone 4 7.1.2，arm-io 下一级节点里 33 个照旧、28 个改名、32 个新增、45 个没了（没了的大多是板级外设：基带、指南针、气量计等）。A5 的地址布局是「A4 的 arm-io 偏移不变，窗口从 0x80000000 挪到 0x30000000」：CDMA、AES、FMI、EHCI、SGX、PMGR、GPIO、看门狗在窗口内的低 28 位都和 A4 一样。不少节点在 A5 上仍由 A4（S5L8930X）那一代驱动认领（GPIO、DART、USB、看门狗、CDMA），或由三星通用驱动认领（UART、SPI、I2S、PKE、MIPI-DSI）。真正要新写的是 AIC（`aic,1`）、PMGR（`pmgr,s5l8940x`）、I2C（`i2c,s5l8940x`）、DWI、PL310、PMU（D1881）、显示（CLCD 换了地址，管线改名 H4P），以及 AE2 音频协处理器、IOP（`AppleA5IOP`）。【已核实】
2. **NAND（第 2 问，最大风险）：不能把模拟闪存当原始 NAND，A4 的生成器用不上；但可以整个绕开闪存，把系统盘挂在 USB 大容量存储上。**
   - A4 用的 YAFTL/VSVFL 原始 NAND 代码只在 `AppleNANDLegacyFTL` 里（按 `ppn-device = false` 匹配），iPod 5 的 7.1.2 和 9.3.5 内核里都没有这个扩展，只剩 `AppleSwissPPNFTL`（要求 `ppn-device = true`、`ppn-ftl-ver = 2`）。【已核实】
   - IOP 固件同样从 iBoot 源码树编出：7.1.2 和 A4 一样是 iBoot-1940.10.58，9.3.5 是 iBoot-2817.60.2。但 A5 的 IOP 是 **ARMv7 核**（A4 是 ARMv5，上游用 arm946 模拟），所以「跑真 IOP 固件」那条路要换核。【已核实】
   - **绕法：** 9.3.5 内核带完整的 USB 主机栈和 `IOUSBMassStorageDriver`，按 USB 接口类 8、子类 6（SCSI）通用匹配，QEMU 自带的 `usb-storage` 正好是这个类型；EHCI 的驱动、兼容串和寄存器偏移都和 A4 一样（`usb-synopsys_ehci,s5l8930x`，usb-complex 内 0x300000），上游已为 A4 的 USB 键盘做过 EHCI 主机模型。7.1.2 内核也有 `IOUSBMassStorageClass`。effaceable 存储可以放 NOR（内核有 `AppleEffaceableNOR`，A4 的 kboot 已经会给没有 NOR 的板子嫁接 NOR 节点）。驱动层面已核实；内核肯不肯从 USB 盘挂根、数据保护是否顺利要开机才知道【推测】。
   - PPN 正路（模拟 PPN 加写 Swiss PPN FTL 生成器，或让内核用 `nand-enable-reformat` 自格式化）以后再做，不挡开机。
3. **AMFI（第 3 问）：** 7.1.2 和 9.3.5 的 AMFI 都还读 `amfi_allow_any_signature`、`cs_enforcement_disable`、`amfi_get_out_of_my_way`、`amfi_unrestrict_task_for_pid`，每个都有代码引用和「disabled by boot-arg」的日志；读取前先调 `PE_i_can_has_debugger(NULL)`（9.3.5 内核自带符号表，函数名直接可见），而它读的就是 kboot 设成 1 的 `chosen/debug-enabled`。现成的 kboot 做法在 9.3.5 上照样成立。【已核实】
4. **GL 和显示（第 4 问）：**
   - `__GLIFunctionDispatchRec` 的 @encode 还在，而且在 iPhone 4 7.1.2、iPod 5 7.1.2、iPod 5 9.3.5 三份共享缓存里**逐字节相同**（1035 槽）。gles-public 按 @encode 推派发表的办法直接适用。【已核实】
   - QuartzCore：7.1.2 用 `H3CLCDDisplay` / `H4CLCDDisplay`；9.3.5 改成 `AppleCLCDDisplay`，类名匹配挪进了 IOMobileFramebuffer 框架，但认的仍是 `AppleCLCD`（内核里两代的类都叫 `AppleMobileCLCD`）。【已核实】
   - **新问题：** 9.3.5 的 dyld 是 dyld-390.7，不是我上份报告按开源版推测的 dyld-360。它已经有 iOS 10 那种 `dylibsCanOverrideCache()` 检查：先读 comm page 0xFFFF4084 的开发固件位，再要求共享缓存头 +0x68 的 `cacheType` 为 0（开发版），而 9.3.5 自带的缓存是 1（生产版）。所以 **gles-public 现在用的覆盖开关在 9.3.5 上就失效了**；7.1.2 的 dyld-324.1 没有这个检查。【已核实】出路见 4.3 节，最简单的是在准备设备时把缓存头这个字段改成 0【推测，要实测签名校验放不放行】。
5. **launchd（第 5 问）：** 9.3.5 换成了 libxpc 的新 launchd（765.50.8）。开机时它从共享缓存里的 `xpcd_cache.dylib` 读守护进程清单，260 个 plist 全部预编在里面。它是否还会扫 `/System/Library/LaunchDaemons` 里后加的 plist，静态上看不出来【推测：大概率只认缓存】。7.1.2 的老 launchd 直接读目录，所以上游往目录里放 plist 的装法在 7.1.2 能用，在 9.3.5 要先实测。备选：包一个现有守护进程的可执行文件，或者在缓存头改法生效后连 `xpcd_cache.dylib` 一起覆盖。
6. **根文件系统密钥（第 6 问）：能。** 我用 Python 重写的 genpass 在 9.3.5 的两个恢复内存盘上，配平台名 `s5l8942x`，算出了和 ipsw.me 公开值逐位相同的根文件系统密钥；7.1.2 和 iPhone 4 7.1.2（`s5l8930x`）也一样。缺根文件系统密钥的 8.4.1、9.3.5 机型（fwkeydb 都有它们的内存盘密钥）都能这样算出来。【已核实（9.3.5、7.1.2）；推广到 8.4.1 为推测】
7. **第 1 步怎么做最省：** 在 A4 机型代码上派生 `n78` 机型，单核 Cortex-A9，设备树里先把 cpu1、IOP、闪存控制器、AE2、SGX、ISP、视频编解码藏掉（兼容串改 none，上游对基带就是这么做的），只新写 AIC（含定时器）和 PMGR，其余照 A4 的模型换基址；kboot 加一个 n78 板子。目标：9.3.5 和 7.1.2 的内核在 uart1 上打印，停在 Waiting for root device。紧接着挂一个 `usb-storage` 看内核能否认出 USB 盘。详见第 7 节。
8. **新冒出来的阻断：** 没有硬性阻断。新增三个要处理的问题：dyld-390 的缓存覆盖检查（影响 GL 前端和 launchd 绕法，9.3.x 起）；9.3.5 把 USB 主机栈整体换成了新的 IOUSBHostFamily（A4 的 EHCI 模型只在老栈上验证过）；A5 的 IOP 是 ARMv7 核。

---

## 1. 设备树对照（第 1 问）

对照表全文在 `work/research/ipod5/dtdiff-n90-712-vs-n78-935.md`（另有 n78 7.1.2 对 9.3.5、n90 7.1.2 对 n78 7.1.2 两份），每行有两边的 `compatible`、iPod 5 的 `reg` 和 `interrupts`，以及按 `IONameMatch` 算出由哪个内核类认领。

### 1.1 总体

| 对照 | 照旧 | 改名 | 新增 | 没了 |
|---|---|---|---|---|
| iPhone 4 7.1.2 → iPod 5 9.3.5（全部节点） | 33 | 28 | 32 | 45 |
| iPod 5 7.1.2 → iPod 5 9.3.5 | 90 | 1 | 2 | 2 |

iPod 5 自己的 7.1.2 和 9.3.5 设备树几乎一样（只是 `sgx` 改叫 `gpu,s5l8940x`，`scaler` 拆成 `scaler0/1`，`rgbout` 没了），所以机型做出来两个版本共用。【已核实】

### 1.2 地址布局【已核实】

| | iPhone 4（A4） | iPod 5（A5） |
|---|---|---|
| arm-io `ranges` | 0x0 → 0x80000000，长 0x40000000 | 0x0 → 0x30000000，长 0x10000000 |
| 内核链接基址 | 0x80001000 | 0x80001000 |
| 内核版本 | xnu-2423.10.71（7.1.2） | xnu-2423.10.71（7.1.2）、xnu-3248.61.1（9.3.5），RELEASE_ARM_S5L8942X |
| 板号 / 芯片号 | 0x00 / 0x8930 | 0x00 / 0x8942（BuildManifest） |
| 系统分区下限 | 1664 MiB（上游实测要这么大） | 2012 MB（9.3.5 的 BuildManifest） |

窗口内偏移不变的块：CDMA（0x7000000，版本 2 → 3）、AES（0x7800000）、FMI（0x1200000 起六段）、EHCI（usb-complex 内 0x300000）、SGX 基址（0x5100000，长度从 0x1000 变 0x18000）、PMGR（低 28 位 0xF100000）、看门狗（低 28 位 0xF103020）、GPIO。CLCD 从 0x9000000 挪到 0xA100000，IOP 从 0x6300000 挪到 0xF300000。

### 1.3 逐块归类【已核实】

| 类别 | 节点（iPod 5 9.3.5 上认领它的类） |
|---|---|
| 仍是 A4 那代驱动 | gpio（`AppleS5L8930XGPIOIC`）、dart-rt/nrt（`AppleS5L8930XDART`）、usb-complex（`AppleS5L8930XUSBArbitrator`）、otgphyctrl（`AppleS5L8930XUSBPhy`）、wdt（`AppleS5L8930XWatchDogTimer`）、cdma（`AppleCDMA`）、pwm（`AppleS5L8920XPWM`）、jpeg、scaler0/1（`AppleM2ScalerCSCDriver`）、flash-controller0（`AppleIOPFMI`） |
| 三星通用驱动（A4 上已有模型） | uart1 到 uart4（`AppleSamsungSerial`）、spi1/spi2（`AppleSamsungSPIController`）、i2s0/i2s2（`AppleSamsungI2SController`）、pke（`AppleSamsungPKE`）、mipi-dsim（`AppleSamsungMIPIDSIController`） |
| 新的 SoC 级块 | aic（`AppleInterruptController`，替代 PL192 VIC）、pmgr（`AppleS5L8940XPerformanceController`）、i2c0/i2c2（`AppleS5L8940XI2CController`）、dwi（`AppleS5L8940XDWI`，替代 swi）、pl310（`AppleS5L8940XPL310`）、iop（`AppleA5IOP`，替代 `AppleARM7M`）、sgx（`SGXDriver543`）、clcd（`AppleMobileCLCD`，扩展是 `AppleH4PCLCD`）、sha2（`sha,s5l8940x`，替代 sha1）、perfcounter、trace |
| 新的音频结构 | ae2（`AppleA5AE2`，音频协处理器）、mca0/mca1（`AppleAE2MCA`）、i2s-switch（`AppleAE2I2SSwitch2`），编解码器 cs42l81、功放 cs35l19 |
| 板级 | PMU 从 D1815 换成 D1881（9.3.5 新增 `AppleDialogPMU` 扩展）；加速度计 `ap3dsh`；陀螺仪 `ap3gdl` 同 iPhone 4；触摸 `multi-touch,n78` 仍在 spi1；屏 `lcd,pinot` 在 mipi-dsim 上；Wi-Fi 在 EHCI 的 HSIC 口（`AppleBCMWLANBusInterfaceHSIC`） |
| 没了 | vic、uart0、uart5/6、spi0、swi、sdio、ceata、amc、rgbout、sha1、基带相关、指南针、气量计、GPS |

AIC 节点属性：`reg 0xF200000 0x10000`、`#main-cpus 2`、`use-ldrex 1`、`ipid-mask`、`target-destinations`。两个 CPU 节点都是 `ARM,cortex-a9`。【已核实】

**串口：** 设备树里没有 uart0。XNU 的 `serial_init()` 依次找 `boot-console`、`uart0`、`uart1`（xnu-4570 `pexpert/arm/pe_serial.c`），9.3.5 内核里也有这几个字符串，所以控制台会落在 uart1（0x32600000）。【源码已核实；9.3.5 二进制走同一逻辑为推测】

---

## 2. NAND 栈（第 2 问）

### 2.1 内核扩展【已核实】

| | iPhone 4 7.1.2 | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|---|
| FMI | `AppleIOPFMI`（`fmi,s5l8920x`） | 同 | 同（AppleIOPFMI-95） |
| 原始 NAND FTL | `AppleNANDLegacyFTL`（`ppn-device = false`），里面是 Whimory 的 yaFTL、VFL | **没有** | **没有** |
| PPN FTL | 没有 | `AppleSwissPPNFTL`（`ppn-device = true`、`ppn-ftl-ver = 2`），WhimoryPPN 的 SFTL、PPNVFL | 同（IOFlashStorage-730） |
| `AppleNANDFTL` | 公共库，没有匹配条目 | 同 | 同 |
| IOP 固件 | `IOP_s5l8930x_firmware`，iBoot-1940.10.58，ARMv5 | `IOP_s5l8942xiop_firmware`，iBoot-1940.10.58 | 同名，iBoot-2817.60.2，0x23000 字节，ARMv7 |
| IOP 驱动 | `AppleARM7M` + `EmbeddedIOP` | `AppleA5IOP`（`iop,s5l8940x`）+ `EmbeddedIOP` | 同 |
| effaceable | NAND 或 NOR | `AppleEffaceableNAND` / `AppleEffaceableNOR` | 同 |

A5 IOP 固件里有 53 条 dsb/dmb/isb 和 v7 的 wfi，A4 的一条都没有（用 CP15 的老式 wfi），两者开头都是经典 ARM 异常向量表。所以 A5 的 IOP 是 ARMv7 核（具体型号没查，可能是 Cortex-A5 或 R 系列【推测】）。

### 2.2 判断

1. **不能把模拟闪存当原始 NAND 用，FirmwareKit 的 A4 生成器（YAFTL/VSVFL 格式）用不上。** 原始 NAND 的 FTL 只在 `AppleNANDLegacyFTL` 里，A5 内核没有这个扩展；`ppn-device` 报假时没有任何 FTL 会接手，也就不会出现 disk0。【已核实】
2. **PPN 正路的工作量：** 要么在 IOP 邮箱层做高层模拟，实现 `IOPPNCommand` 那套读、写、擦语义加一个页存储（A4 的 HLE 实现的是原始 NAND 的环形命令，协议要重做）；要么换一个 ARMv7 的 IOP 核去跑真固件，外加 H2FMI 和 PPN 的寄存器级模型（Cascadia 记录了 PPN 命令序列）。系统盘内容要么写 Swiss PPN FTL 的离线生成器（Cascadia 有只读实现可参考），要么用 `nand-enable-reformat`（9.3.5 的 SwissPPNFTL 认这个参数，【已核实】）让内核自格式化，再想办法把系统灌进去。估计几周。【推测】
3. **推荐绕法：系统盘挂在 USB 大容量存储上。**
   - 9.3.5 内核有 `IOUSBMassStorageDriver`，它的 `IOUSBMassStorageInterfaceNubSCSI` 按 `bInterfaceClass 8`、`bInterfaceSubClass 6` 通用匹配任何 IOUSBHostInterface，之后 `IOSCSIPeripheralDeviceType00` 出块设备。QEMU 的 `usb-storage` 就是 8/6/0x50。【已核实】
   - 7.1.2 内核有 `IOUSBMassStorageClass`。【已核实，匹配条件没细看】
   - EHCI：兼容串 `usb-synopsys_ehci,s5l8930x`、驱动 `AppleS5L8930XUSBEHCI`、寄存器偏移，和 A4 都一样。上游为 iPad 和 iPhone 4 的 USB 键盘做过 EHCI 主机，iOS 7 的 iPhone 4 能枚举出 QEMU 的 USB 键盘（我们 M0 实测会弹「Cannot Use Device」，说明主机栈在工作）。【已核实】
   - 内核认 LwVM（`LightweightVolumeManager` 按 `Whole` 的 IOMedia 匹配），也可以直接用普通分区表，再改 rootfs 里的 fstab。
   - effaceable 放 NOR：内核有 `AppleEffaceableNOR`（`effaceable,nor`，挂在 `nor-flash,spi` 下），A4 的 kboot 已经会给没有 NOR 的 N81/N90 嫁接 K48 的 NOR 节点。【已核实】
   - 没核实、要开机才知道：内核从 USB 盘挂根会不会被拒（比如要求根在内置存储），数据分区的内容保护在 USB 盘上能否建立 keybag，9.3.5 的新 USB 主机栈和 A4 的 EHCI 模型合不合得来。【推测】
   - 内存盘（kboot 已支持 `md0`）只适合开到 launchd：9.3.5 系统分区下限 2012 MB，放不进 512 MB 内存。

---

## 3. AMFI 启动参数（第 3 问）【已核实】

用 `kc.py refs` 在 AMFI 扩展里找字符串，再找 Thumb 代码里「ldr 文字池 + add pc」对它的引用（这几代内核取字符串都这么写）。

| 参数 | iPhone 4 7.1.2 | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|---|
| `amfi`（总开关） | 有引用 | 有引用 | 有引用 |
| `amfi_unrestrict_task_for_pid` | 有 | 有 | 有 |
| `amfi_allow_any_signature` | 有 | 有 | 有，日志「signature enforcement disabled by boot-arg」 |
| `amfi_get_out_of_my_way` | 有 | 有 | 有 |
| `cs_enforcement_disable` | 有 | 有 | 有，日志「cs_enforcement disabled by boot-arg」 |
| `cs_debug` | AMFI 里有 | AMFI 里有 | 移到了基础内核 |

9.3.5 AMFI 读参数前的代码：`movs r0, #0; bl <桩>; cmp r0, #0; beq 跳过`，桩经 `__nl_symbol_ptr` 跳到内核的 `_PE_i_can_has_debugger`（内核带符号，`llvm-objdump` 直接显示函数名）。也就是说和 3.2 到 5.1.1 一样，只在 `debug-enabled` 非零时才读这些参数，而 kboot 已经把它设成 1。9.3.5 的 AMFI 还新增了加载信任缓存的接口（`loadTrustCache`），这次用不上。

---

## 4. GL 派发表、显示类名、dyld 覆盖（第 4 问）

### 4.1 派发表【已核实】

三份共享缓存里各有一处 `{__GLIFunctionDispatchRec=…}`，长 4195 字节，iPhone 4 7.1.2、iPod 5 7.1.2、iPod 5 9.3.5 **逐字节相同**（1035 个函数指针槽，和 `docs/n90/README.md` 记的 7.1.2 槽数一致）。gles-public 按 @encode 数槽位的办法在 9.3.5 上照样成立；按 OpenGLES 导出跳板解码槽名那一步，9.3.5 的跳板指令形状有没有变还没看【推测：编译器换了代，可能要补解码形状】。

9.3.5 里 `GLEngine.bundle/GLEngine` 和 `IMGSGX543GLDriver` 都在共享缓存里；缓存里还有 `Metal.framework`（A5 上没有 Metal 设备，只是框架在）。

### 4.2 显示类名【已核实】

| | 匹配显示的地方 | 字符串 |
|---|---|---|
| iPhone 4 7.1.2、iPod 5 7.1.2 | QuartzCore（`CA::WindowServer::H3CLCDDisplay`、`H4CLCDDisplay` 的 `open()`） | `AppleCLCD`、`AppleRGBOUT` |
| iPod 5 9.3.5 | QuartzCore 只剩 `AppleCLCDDisplay` 类，`AppleCLCD`、`AppleRGBOUT` 字符串挪到了 IOMobileFramebuffer、VideoToolbox、UIKit | `AppleCLCD` |

内核这边两代的 CLCD 类都叫 `AppleMobileCLCD`（A4 的扩展叫 AppleCLCD，A5 叫 AppleH4PCLCD）。所以用户态始终按 `AppleCLCD` 找屏，上游 A4 的显示通路在概念上不用改，要改的是 A5 显示管线的寄存器模型（CLCD 换了地址，DisplayPipe 改名）。

### 4.3 dyld 覆盖开关：9.3.5 上已失效【已核实】

| | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|
| dyld 版本 | dyld-324.1 | dyld-390.7 |
| 共享缓存头 | `mappingOffset 0x68`，没有 `cacheType` 字段 | `mappingOffset 0x98`，`cacheType`（+0x68）= 1（生产版） |
| 读 comm page 开发固件位（0xFFFF4084） | 没有 | 两处：`mapSharedCache()` 和 `loadPhase5()` |

9.3.5 dyld `loadPhase5()` 里的判断（反汇编，地址 0x1fe07824 起）：读 0xFFFF4084 第 0 位，为 0 就不允许覆盖；再取 `sSharedCache`，读它 +0x68 的 64 位 `cacheType`，非 0 也不允许。这就是 dyld-421（iOS 10）开源代码里 `dylibsCanOverrideCache()` 的内联版本。第一个条件 kboot 能满足（内核把 `PE_i_can_has_debugger()` 写进这个位），第二个不满足。

**结论：** gles-public 现在靠的「放一个 `enable-dylibs-to-override-cache` 文件让 dyld 用磁盘上的 OpenGLES」在 9.3.5 上不生效，7.1.2 照旧。我上份报告说「iOS 8、9 照旧可以，iOS 10 才失效」是按开源的 dyld-360 推的，9.3.x 实际用的是 dyld-390，这里更正。8.4.1 的 dyld 版本没下载核实【推测：dyld-353，覆盖仍可用】。

出路（都没试过）：

1. **准备设备时把共享缓存头 +0x68 改成 0**（或另存一份 `dyld_shared_cache_armv7.development` 再改，9.3.5 的 dyld 认这个文件名）。改的是有文档的头字段，不是手找的代码偏移。风险在缓存文件的代码签名：头所在页的哈希会对不上，开着 `cs_enforcement_disable` 时内核放不放行要实测。【推测】
2. 改 `/usr/lib/dyld`，按特征码把 `cacheType` 检查跳过（ad hoc 重签）。可行但违背上游「不手改字节」的原则。【推测】
3. 用 `DYLD_INSERT_LIBRARIES` 插桩接管 GL 入口。要先能改 backboardd 和 App 的环境变量，而 9.3.5 的 launchd 作业定义在缓存里（第 5 节），绕回到同一个问题。【推测】

第 1 条最省，建议第 1 步顺手做个小实验：只改这个字节开机，看 dyld 会不会加载磁盘上的替身库。

---

## 5. launchd（第 5 问）

| | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|
| launchd | 老 launchd（154,736 字节），字符串里只有 `overrides.plist`，没有 xpcd 缓存 | libxpc 的新 launchd，libxpc_executables-765.50.8，「Darwin Bootstrapper Version 3.4.0」，240,896 字节 |
| 守护进程清单缓存 | 共享缓存里有 `xpcd_cache.dylib`（193 个 LaunchDaemons），给 xpcd 用 | 共享缓存里有 `xpcd_cache.dylib`，`__TEXT,__xpcd_cache` 节里是 plist：260 个 LaunchDaemons 的完整内容、91 个 AppExtensions、`SystemLibraryTreeState` |
| `/System/Library/LaunchDaemons` | 194 个文件 | 260 个文件 |
| `/Library/LaunchDaemons` | 不存在 | 不存在 |

9.3.5 launchd 的字符串里依次是：xpcd 缓存的路径和节名、`No daemons in cache`、`No tree state entry in cache`、然后才是 `/System/Library/LaunchDaemons`、`/System/Library/NanoLaunchDaemons`；还支持 `EnvironmentVariables`、`disabled.plist`、`overrides.plist`（在 `/private/var/db/com.apple.xpc.launchd`）。【已核实】

判断：9.3.5 开机先用缓存，是否还会扫目录拿后加的 plist，静态看不出【推测：大概率只认缓存，那么上游往目录放 plist 的装法在 9.3.5 不生效；7.1.2 照旧生效】。第 1 步开机后放一个最小的测试作业就能确认。备选：

1. 包一个缓存里已有、又不关键的守护进程：把它的可执行文件换成我们的启动器，先拉起客体工具再 exec 原程序（AMFI 已放开，ad hoc 签名能跑）。
2. 缓存头改法（4.3 第 1 条）生效后，dyld 也会从磁盘加载改过的 `xpcd_cache.dylib`，可以在它的 plist 里加作业、给 SpringBoard 和 backboardd 加环境变量。【推测】

---

## 6. 根文件系统密钥（第 6 问）【已核实】

genpass 的原理：用平台名的 SHA-1 加四个常数算出内存盘里四处「盐」的位置，对整个内存盘加这几段做 SHA-256 得到 asr 口令，再用口令（前 24 字节当 3DES 密钥、后 8 字节当 IV）解开加密 DMG 头里包着的 vfdecrypt 密钥。我照 xerub/genpass（asr4.c、pass2key.c）用 Python 重写为 `work/research/tools/genpass.py`，只需加密根文件系统 DMG 的头 64 KB。

| 固件 | 内存盘 | 平台名 | 结果 |
|---|---|---|---|
| iPod 5 9.3.5 | 058-49111-036（Erase）、058-49421-036（Update） | `s5l8942x` | 两个都等于 ipsw.me 公开值 `edf6e096…cb8d0` |
| iPod 5 9.3.5 | 同上 | `s5l8940x` | 解不开（平台名必须对） |
| iPod 5 7.1.2 | 058-4322-012 | `s5l8942x` | 等于公开值 `13f5a0a0…f0aa` |
| iPhone 4 7.1.2 | 058-4107-013、058-4266-010 | `s5l8930x` | 等于公开值 `38d0320d…3684` |

所以只要有恢复内存盘的密钥，就能算出根文件系统密钥。fwkeydb 对 iPhone 5 的 9.3.5、iPhone 4S 和 iPhone 5 的 8.4.1 都有内存盘密钥（上份报告已查），缺的根文件系统密钥都能这样补齐【推测，没在这些版本上实跑】。App 里可以照搬这个算法，不用存根文件系统密钥。

---

## 7. 第 1 步（机型骨架）怎么做最省

目标：iPod 5 的 9.3.5 和 7.1.2 内核在串口打印横幅，停在 Waiting for root device；顺手确认 USB 盘能被认出。只在 Mac 上做，不碰手机和 App。【以下都是建议，推测】

1. **机型：** 在上游 A4 机型（`hw/arm/ipad1.c` 那套）上派生 `n78`，做成 `patches/` 里的补丁。DRAM 0x80000000 起 512 MB，arm-io 窗口 0x30000000 起 256 MB。
2. **CPU：** 先单核 `cortex-a9`。设备树删掉 cpu1，AIC 的 `#main-cpus` 改 1（kboot 里做）。双核留到后面。
3. **要新写的模型（只做到内核不卡）：**
   - AIC（0x3F200000）：照 xnu-4570 `pexpert/pexpert/arm/AIC.h` 的寄存器，加每线屏蔽和目标核、IACK、定时器和时间戳（内核的计时就在这里，见上份报告引的 Cascadia 笔记）。
   - PMGR（0x3F100000）：先做成「写什么都成功、读回合理值」，看门狗块（0x3F103020）里的 24 MHz 计数器要能走。
   - I2C（`i2c,s5l8940x`）加一个 D1881 PMU 的桩，DWI 和 PL310 的桩。
4. **照搬 A4 模型、只换基址：** uart1（控制台）、GPIO、chipid（填 0x8942）、看门狗、CDMA 和 AES（版本号从 2 改 3，先不用）、SPI。
5. **设备树里先藏掉**（兼容串改 none）：iop、flash-controller0、ae2、mca0/1、i2s-switch、sgx、isp、vxd、vxe、jpeg、displayport、tv-out、Wi-Fi。显示和触摸放到第 3 步。
6. **kboot：** 给 FirmwareKit 的 KBoot 加 n78 板子：内存基址和大小、板号 0x00、芯片号 0x8942、A5 的时钟表（先照 A4 的填，内核读不对再改）、640×1136 屏幕参数、`debug-enabled` 等照旧、`nvram-proxy-data` 照 7.x 的办法填。启动参数照旧加 `serial=3 debug=0x8`。
7. **紧接着试 USB 盘：** 打开 A4 的 EHCI 模型，挂一个 QEMU `usb-storage`，内容用 FirmwareKit 现成的系统卷镜像。看 9.3.5 的新 USB 栈能否枚举并出 IOMedia，再把 `root-matching` 指过去。这一步通了，第 2 步（launchd 跑起来）就基本不用碰闪存。
8. **两个顺手的小实验：** 共享缓存头 `cacheType` 改 0 后 dyld 会不会加载磁盘上的替身库（4.3）；目录里后加的 plist 会不会被 launchd 加载（第 5 节）。

估计第 1 步 1 到 2 周（上份报告的估计不变）。第 2 步如果 USB 盘路线通，从「1 到 2 个月」可以缩到几周，因为最大的一块（PPN 存储）被推迟了。【推测】

---

## 8. 对上份报告的更正和补充

1. **dyld 覆盖开关：** 9.3.x 已经和 iOS 10 一样需要开发版共享缓存（dyld-390.7），不是 iOS 10 才开始。`docs/research/ios8-10-feasibility.md` 3.4 节已加一行指向本文。
2. **存储：** 「让 A5 内核把模拟闪存当原始 NAND、复用 A4 生成器」这条省力路被排除；换成「USB 大容量存储做系统盘」这条更省的路，PPN 推后。
3. **AMFI：** 上份报告标「8 到 10 没核实」，现在 9.3.5 已核实仍然认启动参数，门控方式不变。
4. **USB 主机栈：** 9.3.5 用的是新的 IOUSBHostFamily（`com.apple.driver.usb.AppleUSBEHCI` 等），7.1.2 和 A4 上是老的 IOUSBFamily。
5. **IOP：** A5 是 ARMv7 核，A4 是 ARMv5。

---

## 9. 文件清单（都在 `work/`，不进仓库）

| 路径 | 内容 |
|---|---|
| `work/firmware/iPod5,1_{7.1.2_11D257,9.3.5_13G36}_Restore.ipsw`（加 `.sha1`） | 两个固件 |
| `work/research/ipod5/{7.1.2,9.3.5}/` | 解密后的内核缓存（`.mach`）、设备树（`.bin`、`dt.txt`、`dt.json`）、iBoot、两个恢复内存盘、根文件系统（`rootfs.dmg`，UDIF，可用 `hdiutil attach -readonly` 挂载）、内核扩展表 `kexts.txt` |
| `work/research/ipod5/dtdiff-*.md` | 三份设备树对照表 |
| `work/research/ipod5/keys/` | ipsw.me 和 fwkeydb 的密钥 JSON |
| `work/research/n90-7.1.2/` | iPhone 4 7.1.2 的设备树文本和内核扩展表（解密件仍在 FirmwareKit 缓存里，只读用） |
| `work/research/tools/` | 本次的脚本 |
| `work/research/genpass-src/` | genpass 两份 C 源码，只读参考 |
