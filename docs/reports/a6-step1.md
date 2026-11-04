# A6（iPhone 5）第 1 步：iOS 10.3.4（14G61）往锁屏和主屏推

- 日期：2026-11-04 起
- 执行会话：a5-nand（接着 `docs/reports/a5-step1.md`、`a5-app.md` 做）。用户原话：「先继续解决iOS10」。
- 范围：iPhone 5（A6，S5L8950X）新机型，iOS 10.3.4 开到最远的一步，查清卡点。装真机先放一放。
- 下载：用户批准一个文件（「批准」）：iPhone 5 的 iOS 10.3.4（14G61）Restore IPSW，iPhone5,1 和 iPhone5,2 共用。
- 不做的：不提交、不推送、不碰真机；苹果固件不进仓库。

## 0. 结论

**最远到哪（第六轮，2026-11-04）：** iPhone 5（A6，n41）的 iOS 10.3.4 在 Mac 上**每次开机都进锁屏、主屏，有默认海浪壁纸，能点开「设置」，熄屏后按 Home 能叫醒**：壁纸是全新克隆盘单开 3 次里 3 次都有（锁屏、主屏、叫醒后），同一块盘第二次开机也有（17.7，截图 `docs/reports/img/a6-1034-wallpaper-lock.png`、`a6-1034-wallpaper-home.png`）；黑屏第五轮是 5 次里 0 次，这一轮 4 次里 0 次，叫醒 4 次里 4 次；mediaserverd 不再崩，没有 panic（16.7，叫醒截图 `docs/reports/img/a6-1034-wake.png`）。9.3.5 回归照常（17.8）。**仍有缺陷：** 电池显示快没电（15.4）；电话角标没有数字。

**六轮下来解决的关键问题：**

1. Swift CPU：Cortex-A15 加苹果 MIDR；L2 组数要是 2 的幂（第 3 节）。
2. iOS 10 的 AMFI 不放行 ad hoc 签名：把我们的 CDHash 换进内核的静态信任缓存，认第 0 槽的 SHA-1 代码目录（第 5、9 节）。
3. **A6 的递减器**：CPU 自己的通用虚拟定时器，以 IRQ 级别从 0x1C 入口进来；没接时 USB 不枚举（第 7 节）。
4. **迁移后的内存改写**：GL 宿主写回 surface 用的是绑定时缓存的物理页，surface 释放后照写；改成写回前按所属进程的页表核对（13.1）。
5. **D1972 PMU 的 ADC 完成中断**（13.2）；**CommCenter** 没基带就崩、SpringBoard 主线程等它，用 launchd 的 disabled.plist 禁掉（13.3）。
6. **iOS 10 的文字层格式 `LA08`** 和半精度 `RGhA`：文字、时钟日期回来，花屏线消失（14.1）。
7. **触摸**：开机包的时钟频率表只填到第 55 槽，spi1 的时钟读到 0，SPI 驱动不打日志就退出（15.1）；触摸模型对 n41 要自报家族 0x57（15.2）。
8. 锁屏的「存储介质读不了」是 storage_mounter 把 USB 根盘当外接盘，已禁（15.4）。
9. **缓存里的镜像直接调苹果原版的 gl 函数**（存根被优化成直接跳转，dyld 改绑不到），原版从线程 TLS 第 30 槽取上下文，前端从没放过，所以全是空操作：mediaserverd 的 HDR 因此每几秒崩一次、SpringBoard 等它。前端设当前上下文时把宏上下文也放进这个槽（16.1、16.4）。先试过在缓存里放跳板，盖掉了前端认槽要读的指令，backboardd 反复崩溃，已撤回（16.2）。
10. **A6 显示的 gamma 装载位**：驱动等 0x40 清零、没有超时，模型不清就忙等到 IOP 超时 panic（16.2、16.3）。
11. **壁纸**：盘上 SpringBoard 的壁纸缓存（`MappedImageCache/Wallpaper/…-untinted.cpbitmap`）是 GL 画了再读回的，第一轮用旧前端直接写 disk-n3 时读回被丢，存下的整幅图全是不透明黑，之后每次开机都直接读它，修好 GL 也看不出来。`n78_diskfix.sh` 改盘时删掉它，SpringBoard 开机重画（17.1 到 17.5）。被隐藏的缩放器在这条路上，但缺了它 SBF 会退回 CPU（17.3）。

**卡点和下一步：** 电池：电量计模型接上了，驱动没来问（15.4）。TLS 方案之后宿主日志多了几类拒绝（VAO 没实现、一个着色器在宿主上编译失败），和壁纸无关（有壁纸和没壁纸的两次一条不差），是哪个进程没查（17.6）。查壁纸用的 gdbstub 断点脚本（能自己算共享缓存的滑动量）还在会话临时目录，要不要收进 `tools/a5/` 由决策会话定（17.2）。

## 1. 固件

- IPSW：`iPhone_4.0_32bit_10.3.4_14G61_Restore.ipsw`，2000796302 字节，地址取自 ipsw.me API（`updates.cdn-apple.com/2019/ios/091-25277-…`），sha1 `2f88a216491667ce33e768ab54752d9d0f53dc20` 和批准的一致，放在 `work/firmware/`。【已核实】
- 一个包给四种板子：n41ap（iPhone5,1，BoardID 0x00）、n42ap（iPhone5,2，0x02）、n48ap、n49ap（iPhone 5c，0x0A、0x0E），芯片号都是 0x8950。iPhone 5 两种板子共用内核 `kernelcache.release.iphone5`、iBoot、LLB，只有设备树不同。选 **n41ap**（没有 CDMA，板号 0x00 和 n78 一样）。【已核实：BuildManifest】
- **所有镜像都没有 KBAG**（AppleLogo、电池图、设备树、内核、LLB、iBoot、iBEC、iBSS、恢复界面图），和可行性调研说的一样，不用密钥。【已核实】
- 解包：`tools/a5/n78_unpack.py` 加了两样：板号参数（按 DeviceClass 选清单里的 Erase 身份）；没有 KBAG 的镜像直接取 DATA 段，密钥文件可以写 `-`。`python3 -I -B tools/a5/n78_unpack.py work/firmware/iPhone_4.0_32bit_10.3.4_14G61_Restore.ipsw - work/a6/dec/14G61-n41 n41ap` 得到 `kernelcache.mach`（20566016 字节，Mach-O ARM V7S）、`DeviceTree.bin`（88056）、`iBoot.bin`（iBoot.iphone5，303104）、`RestoreRamDisk.dmg`（24.7 MB，HFSX）、`AppleLogo.bin`。【已核实：`work/a6/dec/14G61-n41/`】

## 2. 清点：A6（n41）和 A5（n78）差在哪

工具：新写 `tools/a5/dtcmp.py A.bin B.bin [前缀]`，逐个节点比兼容串、第一个 reg、中断和 device_type。对比结果存在 `work/a6/dtcmp-armio.txt`（arm-io 一层）和 `dtcmp-all.txt`（更深的节点）。

**arm-io 地图几乎一样。** AIC（0xF200000）、CDMA（0x7000000）、显示管线（0xA100000）、两个 DART、FMI（0x1200000）、GPIO（0xFA00000）、i2c0 和 i2c2、IOP（0xF300000）、PMGR（0xF100000）、PWM、SGX（0x5100000）、SPI1、UART1 到 4、USB（0xF108000 和 0x6000000）、看门狗，基址和中断号全部相同，只是兼容串从 `s5l8940x` 换成 `s5l8950x`（QEMU 的模型按地址挂，不看兼容串）。【已核实：`work/a6/dtcmp-armio.txt`】

| | n78（A5，9.3.5） | n41（A6，10.3.4） |
|---|---|---|
| CPU | 两个 `ARM,cortex-a9` | 两个 `apple,swift` |
| L2 | `pl310`（0xE000000） | 没有这个节点（集成了） |
| PMU（i2c0 0x74） | `pmu,d1881`，中断 0xd | `pmu,d1972`，中断 0x6，下面多了振动马达 |
| i2c1（0x3300000） | 没有 | 新总线：加速度计 ap3dsh、光感 tsl2581、罗盘 akm8963 |
| i2c0 其他 | tristar | tristar（中断 0x1f）、陀螺仪 ap3gdl、背光 lm3534 |
| 触摸 | spi1 `multi-touch,n78`，中断 0x15 | spi1 `multi-touch,n41`，中断 0xc9 |
| 音频编解码器 | cs42l81，控制在 spi2 | cs42l65，控制在 spi3（新） |
| UART | 1 到 4 | 多了 uart5（电量计 bq27540，HDQ）、uart6（调试口） |
| 基带 | 没有 | `baseband`（n41）、EHCI 下的 `hsic-baseband` |
| 其他 | displayport、tv-out、trace、spi2 | i2c1、i2s1、jpeg1、spi3、温度传感器、sacm、cpu-debug-interface |
| 底座 | 30 针 | Lightning（`dock,9pin`） |

**内核 kext：** 9.3.5 有 165 个，10.3.4 有 178 个（`tools/a5/kexts.py`，清单在 `work/a6/kexts-*.txt`）。【已核实】

- 10.3.4 才有：`AppleS5L8950X`（平台）、`AppleD1972PMU`、`AppleH5PCLCD`（显示，A5 是 H4P）、`IOP_s5l8950xiop_firmware`（IOP 固件换了一版）、`IOP_s5l8950xae2_firmware`、`IMGSGX543RC2`、`AppleLMBacklight`、`AppleHDQGasGaugeControl`、`AppleTemperatureSensor`、`AppleCS42L65Audio`、`AppleSongbirdDSP`、`AppleBasebandN41`、`usb.hsic.cellular`、`AppleBCMWLANCoreLegacy`、`AppleEmbeddedGPS`、`AppleEmbeddedPressure`、`hfs.kext` 和 `apfs`（HFS 成了单独的 kext）等。
- 9.3.5 才有：`AppleS5L8920X`、`AppleD1881PMU`、`AppleH4PCLCD`、`AppleH4PRGBOUT`、`AppleTVOut`、`AppleCS42L81Audio`、`IMGSGX543`、`BasebandSPI` 等。

**要新做或要核对的（按开机顺序）：** Swift CPU 型号和双核（先单核）；内存 1 GB；D1972 PMU（先看和 D1881 的寄存器差多少）；i2c1 总线；H5P 显示管线（和 H4P 的差别）；IOP 固件换版后 `cnfg`、FMI 消息是否照旧；触摸的中断脚；基带、音频、电量计先在设备树里隐藏。

## 3. CPU 和机型：内核到等根设备（完成）

**Swift CPU（`target/arm/tcg/cpu32.c`，型号名 `apple-swift`）：** 就是 QEMU 的 Cortex-A15（ARMv7 加 VFPv4、两套指令集的硬件除法、多核扩展，正好是 ARMv7s），换上苹果的 MIDR 0x610F0000（xnu `cpuid.h` 的厂商 0x61、部件号 0 即 Swift）。还改了一处：L2 的 CCSIDR。A15 的 L2 是 2304 组 × 16 路，xnu 的 `vm_page_set_colors` 用「组数 × 行长 ÷ 页大小」算页着色数，得 36，不是 2 的幂，内核在 VM 初始化时 panic `vm_page_set_colors`（`work/a6/runs/r1`）。按 A6 的 1 MiB、8 路、64 字节行设成 0x70FFE03A（2048 组，着色数 32）后过去了。【已核实：`r1/serial.log`、`r2/serial.log`】

**机型：iPhone 5 是 iPod touch 5 机型的子类**（`hw/arm/ipod_touch_5g.c`，`-M iPhone-5`）。两台板子的差别收进 `N78Board`，类里带一个指向它的指针：

| | n78 | n41 |
|---|---|---|
| 默认 CPU | cortex-a9 | apple-swift |
| 内存 | 512 MiB | 1 GiB（vram、CDMA 的内存窗口、开机包的范围检查都跟着走） |
| I2C | i2c0、i2c2，脚 0x604/0x605、0x1800/0x1801 | i2c0、i2c1、i2c2，脚 0x702 到 0x705、0xb00/0xb01 |
| 触摸 ATN | GPIO 0x205 | GPIO 0x1901（设备树中断 0xc9） |
| 按键 | 脚 0 到 3 | 脚 0 到 4（多一个静音拨片） |
| 控制台 | uart1 | uart6（设备树的 `debug-console`；第一次开机串口没字，QEMU 记下内核在轮询 0x2B00010） |

因为是子类，`object_dynamic_cast(…, TYPE_N78_MACHINE)` 对两台都成立，按键函数 `ipod_touch_5g_press_button`、App 桥的熄屏判断不用改。踩到一个坑：子类的 class_init 里对父类加的 `kboot` 属性调 `object_class_property_set_description`，在子类自己的属性表里找不到，`-M help`、`-cpu help` 启动就段错误，去掉了。【已核实】

**开机包（`tools/a5/n78_kboot.py`）：** 按设备树的兼容串认板（`ipad1_kboot.dt_board`），n41 用 `iPhone-5`、1 GiB、型号号码 MD297、平台名 `s5l8950x`、芯片号 0x8950，CPU 主频 1.3 GHz；A6 的 pmgr 没有 `cpu-clk-cfgs`（多了 `boost-performance0/1`），这一项跳过；额外隐藏 `baseband`（高通基带没有模型）和两个 JPEG 块（复位轮询一万次后放弃，下一次起生效）。n78 的开机包用新脚本重做，逐字节不变。`tools/a5/n78_run.sh` 加了 `MACHINE`（默认 iPod-Touch-5G）。【已核实】

**结果（`work/a6/runs/r2`，挂 64 MB 空盘，90 秒）：** 串口从 `iBoot version: iBoot-3406.60.10` 开始（这次没打内核版本行；版本 `Darwin Kernel Version 16.7.0 … xnu-3789.70.16~21/RELEASE_ARM_S5L8950X` 见后来 panic 日志里的 `Kernel version:`，如 `fmt4/serial.log` 第 263 行、`n2/serial.log` 第 768 行），`AppleS5L8950XIO: chip-revision: B1`，AIC（0xc0 个外部中断）、GPIO、显示帧缓冲、I2S、性能控制器（两个性能域，CPU 1300/800/650 MHz 三档）、三条 I2C、PWM、DSI、看门狗、串口都起来了；`AppleD1972PMU::start` 在 D1881 的寄存器替身上也没报错；APFS 和 HFS 的 kext 加载；最后 `Waiting on … IOMedia … Partition ID 1`，等根设备。【已核实：`r2/serial.log`；内核版本见上】

没管的报错：显示管线 `minimum-frequency property not found`、`getClockFrequency(0) (0) < videoClock`；背光 lm3534 `could not communicate`；罗盘 AKM8963 探测不到；tristar 读不到 REV。【已核实】

## 4. 根文件系统和 USB 根盘

- 14G61 的根文件系统 DMG（`058-74968-065.dmg`，UDZO）里是 **GUID 分区表**（一个 EFI 分区、一个 Apple_HFSX），不再是 9.x 的 Apple 分区图；卷是 HFS+（日志式、大小写敏感），不是 APFS。`tools/a5/n78_volumes.py` 加了 `extract_hfs`：先转成 UDTO，看到 `EFI PART` 就按 GPT 找 HFS 类型（48465300-…）的分区原样拷出，否则照旧走 imgtools。【已核实：`work/a6/vol-14G61/system.img`，2966 MiB】
- 盘：`n78_volumes.py work/a6/rootfs/14G61-rootfs.dmg work/a6/vol-14G61`，再 `n78_usbroot.py` 拼成 `work/a6/disks/14G61-full.img`（17305 MiB，GPT，System + Data，第二分区从 LBA 6078464 起）。【已核实】
- 用户态先看到的东西（还没用上）：共享缓存 `dyld_shared_cache_armv7s`（cacheType 1，即发布版缓存；代码签名 ad hoc，CD flags 0x2，CDHash 5c8dad28…）；launchd 是「Darwin Bootstrapper Version 4.0.0」（libxpc_executables-972.70.1）。这两项留到正常开机那一步再查。【已核实：`work/a6/vol-14G61/x/`】

## 5. AMFI：iOS 10 不再放行 ad hoc 签名，改内核的静态信任缓存

**现象（`work/a6/runs/fmt1`）：** 格式化用的 RAM 盘里，我们自己的助手 `it_nandfmt`（ad hoc 签名）一启动就被杀：`_validateCodeDirectoryHashInDaemon … no registered daemon port`、`AMFI: code signature validation failed.`。9.3.5 那条「Invalid signature but permitting execution」在 10.3.4 里没有了，启动参数 `amfi_allow_any_signature=1`、`cs_enforcement_disable=1` 也不管用：签名不在信任缓存里就去问 amfid，而 RAM 盘和开机早期都没有 amfid。【已核实：`fmt1/serial.log`】

**做法：** AMFI 是预链接进内核的，里面有一份静态信任缓存（REA 反编译 `work/a6/amfi-14G61.elf`；查表 0x807e934c，`vnode_check_signature` 0x807eb810）。布局：0x807EDFD4 起 256 项索引（按 CDHash 首字节，每项 `u16 个数, u16 起点`），0x807EE3D4 起按序排好的条目，每条存其余 19 字节，共 5635 条，后面紧跟一张苹果根证书，没有空位。【已核实】

- 用新写的 `tools/a5/cdhash.py` 算出 14G61 根文件系统全部 Mach-O 切片（1413 个）和恢复 RAM 盘全部切片（135 个）的 CDHash：RAM 盘的全在表里，根文件系统的 1411 个在表里；表里 **4112 条两边都对不上**（大概是别的机型或别的包的），可以拿来换。【已核实：`work/a6/cdhash-rootfs.txt`、`cdhash-ramdisk.txt`、`trustcache-14G61.txt`】
- `tools/a5/n41_trustcache.py KERNEL OUT 哈希文件… [--keep …]`：从「两边都对不上」的条目里按顺序从尾部去掉和新哈希一样多的条数，加入新哈希，重新排序，重建索引。条数不变，证书不动。按 VA 换文件偏移要走 LC_SEGMENT（AMFI 在 `__PRELINK_TEXT` 里，第一次按「VA − 0x80001000」算错了位置）。【已核实】
- `n78_kboot.py` 加了 `N78_TRUST=哈希文件,…`：给内核副本打这个补丁再装进开机包。【已核实】

**结果（`work/a6/runs/fmt2`、`fmt3`）：** `it_nandfmt`（CDHash 84126ec4…，`work/a6/trust-ramdisk.txt`）正常运行。【已核实】

## 6. NAND 格式化开机

RAM 盘：14G61 的恢复 RAM 盘没有空位（0 字节可用），`hdiutil resize` 加 1 MiB，再照 A5 的做法把 `it_nandfmt` 放成 `restored_external`（属主 root）。开机包 `work/a6/kboot/n41-14G61-nandfmt.bin`：信任缓存补丁、RAM 盘、`nand-enable-reformat=1`，用 `N78_SHOW` 放出 IOP 和闪存控制器。【已核实】

结果（`fmt3/serial.log`）：

- A6 的 IOP 固件（`IOP_s5l8950xiop`，设备树 `iop-version` 2）在现有的 IOP 高层模拟上照样能用：分区表格式化 8 个分区、VFL 和 FTL 格式化、写签名、`VFL_Open`/`FTL_Open` 都 OK，NVRAM 从空白起来，可擦除存储（effaceable）启动。`it_nandfmt: NAND partition format -> 0`。【已核实】
- 一处不同：`AppleNANDFTL::_publishServices: Creating block device of 0 sectors`（FTL 块设备 0 个扇区）。我们不从 NAND 挂根，暂不影响；记下待查。【已核实：现象；影响是推测】
- **然后客机就停了**：助手下一步要等 `/dev/disk<n>s2`（USB 盘上的数据卷），最多等 60 秒，超时会打印 `FAILED: no data volume`，但这句一直没出来，串口停在客机时间 11 秒左右。说明不只是没找到盘，客机里的 `sleep(1)` 也没返回过（见第 7 节）。【已核实：现象】

## 7. 卡点：10.3.4 不枚举 USB 盘（已解决：A6 的递减器中断）

正常开机（`work/a6/runs/r3`，挂 `14G61-full.img`）停在 `Waiting on … IOMedia … Partition ID 1`，整份日志没有一行 USB 的输出；9.3.5 同一位置有 `AppleSynopsysOTGDevice::start`、`AppleUSBHostResources`，接着 `Got boot device = …usb-ehci…QEMU USB HARDDRIVE…`。两个内核里 USB 相关的 kext 和匹配条件一样（`usb-complex,s5l8930x`、`usb-synopsys_ehci,s5l8930x` 等），n41 设备树的兼容串也都带着 s5l8930x 那一项。【已核实：`work/a6/kpers-all.txt`、`DeviceTree.txt`】

打开仲裁器调试日志（启动参数 `AppleEmbeddedUSBArbitrator-debug=0xffffffff AppleS5L8930XUSBArbitrator-debug=0xffffffff AppleEmbeddedUSBNub-debug=0xffffffff AppleUSBPhy-debug=0xffffffff`，`work/a6/runs/u1`）：`AppleS5L8930XUSBArbitrator` 匹配并启动了，读到 `hsic-enabled: true`，按 `no-pmu` 定为 `USBHost`，PHY 起来（`_phyVersion 4`），上电走到 `enableDevicePower: enable index 4` 后再没有下文，EHCI 的 nub 没发布。【已核实：`u1/serial.log` 第 70 到 122 行】

**对照（`work/a6/runs/u0-n78`，n78 9.3.5 同样的调试参数）：** 9.3.5 在 `enableDevicePower: enable index 4` 之后紧接着 `clearPortReset`、给其余各门上电、`publishing nub … for usb-device`、`… for usb-ehci`。两边差在「上电之后的那一步」：10.3.4 的线程从这里再没醒过。【已核实】

**为什么不醒：客机里所有「睡到某个时刻」的线程都醒不了。** r3、fmt3 的串口都停在客机时间 11 秒前后，连 9.x 每隔一阵会打的等根设备提示都没有；格式化助手 `sleep(1)` 等数据卷，60 秒后该打 `FAILED`，也没打。QMP 抓寄存器（`work/a6/runs/u2/regs.txt`），CPU 在空闲循环（0x800d48de）里转，IRQ、FIQ 都屏蔽着，不是死循环。【已核实】

**根因：A6 的内核用 CPU 自己的通用定时器做时钟，我们没把它的中断送进去。**【已核实】

- 内核的 `mach_absolute_time`（0x80007ff8）、取递减器（0x8000803c）、设递减器（0x80008058）先看 cpu_data 里平台登记的函数（+0x80、+0x74、+0x78），没有就直接读 CNTVCT、读写 CNTV_TVAL。A5 上这三项是 AIC 的定时器；A6 跑起来读出来都是 0（`work/a6/runs/u9`，QMP `x /16wx 0x803ea060`），所以时间和递减器全走 Swift 核的通用虚拟定时器。0x80007fc8 把 CNTV_CTL 置 1 打开它。
- QEMU 的 Cortex-A15 有这个定时器（计数照走，所以内核时间戳是对的），但机型没接它的中断输出，到点了没人知道。

**中断从哪进：** 先照 A5 的样子接到 FIQ，两次都崩：

1. 复位时 CNTV_CVAL 是 0，内核一打开定时器就到点，0x80007fc8 同时打开 FIQ，FIQ 帧压到引导线程栈外面：`panic … Unexpected abort exception`（`u4`）。
2. 把 CVAL 复位成最大值后，第一个 FIQ 进去就返回到用户态 PC 0（`u6`，`-d int`）。

查向量（QMP 读运行中的 0xffff0000 和 cpu_data+0xa8 指的表 0x80005000）：0x1C 槽跳到 0x80005b60，即 xnu 的 `fleh_decirq`；0x18 槽是 `fleh_irq`（0x80005904）。`fleh_decirq` 从内核态进来时，会切到 IRQ 模式取 lr 和 spsr 当被打断的现场，然后才 `cpsie af` 打开 FIQ。这只有在 IRQ 模式下进入才成立。AIC 驱动的 `handleInterrupt`（REA 反编译，`work/a6/aic-14G61.elf` 0x80fa71b4）遇到定时器类型的 IACK（7）直接 panic，所以定时器也不走普通 IRQ。对照 A5（`-d int`）：它的 FIQ 走 `fleh_fiq_generic`，切回 FIQ 模式取现场，和 A6 这条不同。【已核实：以上各项】

结论：**Swift 的递减器是 IRQ 一级的中断（受 CPSR.I 屏蔽、在 IRQ 模式下进入），但有自己的入口 0x1C**，类似 PowerPC 的递减器异常。真机怎么接的没有资料，这是按内核代码反推的。【推测】

**做法（`hw/arm/ipod_touch_5g.c`，只对有通用定时器的 CPU 生效，n78 的 Cortex-A9 不变）：**

- Swift 的 `cntfrq` 设成 24 MHz（设备树的 timebase-frequency）。
- 虚拟定时器的输出和 AIC 的 IRQ 取或，接到 CPU 的 IRQ；CPU 接 IRQ 时如果定时器正在请求，用异常后钩子（`arm_register_el_change_hook`，不要大锁）把入口从 0x18 改到 0x1C。`rtclock_intr` 写下一个截止时间（CNTV_TVAL）后电平自然落下。AIC 的 FIQ（A5 的定时器）照旧接 FIQ，A6 内核不会启动它。
- 复位时 CNTV_CVAL 设成最大值（架构上复位值未定义），第一次中断等内核自己设截止时间。

**结果（`work/a6/runs/u10`）：** 仲裁器发布 `usb-device`、`usb-ehci`，`Got boot device = …usb-ehci…QEMU USB HARDDRIVE…`，`BSD root: disk0s1`，根卷 HFS 挂上（APFS 先试、失败后改用 HFS，正常），launchd「Darwin Bootstrapper 4.0.0」起来，fsck 两个卷、挂上 `/private/var`（带内容保护）。下一个卡点是 `MKB_INIT: Could not open /private/var/keybags/systembag.kb` → `REBOOTING INTO RECOVERY MODE`：没有系统钥匙包，要靠 NAND 格式化开机建（第 8 节）。【已核实：`u10/serial.log` 第 524 到 560 行】

## 8. NAND 格式化开机（完成）

修好递减器后，同一个格式化开机包重跑（`work/a6/runs/fmt4`，全新盘副本、空 NAND 目录）。助手一路走完：`NAND partition format -> 0`、`effaceable open 0 isFormatted 0 -> 0`、`[effaceable:INIT] format succeeded`、数据卷 `/dev/disk0s2`、`MKBKeyBagCreateSystem -> 0, /mnt2/keybags/systembag.kb 1495 bytes`、`system keybag created; halting`。【已核实：`fmt4/serial.log` 第 200 到 227 行】

- 和 A5 一样有两行 `[effaceable:ERR ] unable to efface group 0/1 after 3 attempts`，A5 上不影响钥匙包（a5-step1.md 3.17）。【已核实：现象】
- 停机时 `panic … "Halt/Restart Timed Out"`，之后反复 double panic，串口日志 30 秒涨到几十 MB（已截到前 2 MB）。数据卷在停机前已卸载，钥匙包已落盘。A5 是打出 halting 后约 15 秒按 PID 结束 QEMU，这里照做，以后看到 halting 就结束。【已核实】
- USB 盘这次是 disk0（NAND 的 FTL 仍是 0 扇区，没有发布成盘），A5 上 USB 盘是 disk1。【已核实：现象】

成品：盘 `work/a6/nandfmt/disk-1034-formatted.img`，NAND 目录 `work/a6/nandfmt/nand-1034-formatted/`。以后开机都 `cp -c` 克隆。命令：

```bash
cp -c work/a6/disks/14G61-full.img work/a6/nandfmt/disk-1034-formatted.img && mkdir -p work/a6/nandfmt/nand-1034-formatted
IOP_TRACE=1 MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-1034-formatted.img SNAP=off tools/a5/n78_run.sh work/a6/runs/fmt4 \
  work/a6/kboot/n41-14G61-nandfmt.bin 420 -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-1034-formatted \
  -D work/a6/runs/fmt4/q.log
```

## 9. 改盘：fstab、激活、开发版缓存、GL 前端、信任缓存

**第一次正常开机（`work/a6/runs/n1`，盘没改）：** 接上 NAND 后 FTL 占了 disk0（0 扇区），USB 盘变成 disk1，和 A5 一样；14G61 自带的 fstab 写的是 disk0，`fsck timed out. Can't stat /dev/disk0s1`。所以 `n78_diskfix.sh` 的 fstab（disk1）照用。【已核实：`n1/serial.log` 第 162、196 行】

**激活：** 10.3.4 的 mobileactivationd 改成了 ObjC，9.3.5 那处 `cmp r0,#1; bne` 没了。短路判断看 `-[DeviceType should_hactivate]`（0x245e6，文件偏移 0x205e6），它就是一个读成员的属性方法，改成 `movs r0,#1; bx lr`。`n78_activate.py` 按 SHA-1（8f3a3b82…）认文件，每一项带自己的补丁字节。【已核实：REA，`work/a6/x14/mobileactivationd`；效果待开机验证】

**签名：** 改过的文件页哈希对不上，10.x 的 AMFI 会杀。改完用 `ldid -e` 取出原来的授权、`ldid -S授权` 重新做 ad hoc 签名，写回原文件（属主不变）。ldid 签出来有两个代码目录：第 0 槽 SHA-1，0x1000 槽 SHA-256。**10.3.4 认的是第 0 槽那个**：第一次按 xnu 源码的「SHA-256 优先」只加了 SHA-256 截断的哈希，开机后 launchd 直接 panic `initproc exited … unexpected exec of non-platform binary: /usr/libexec/mobileactivationd`（内核没在信任缓存里找到它，不算平台二进制）；而格式化助手 it_nandfmt 当初加的是第 0 槽哈希，能跑。`cdhash.py` 保持取第 0 槽。【已核实：`work/a6/runs/n2/serial.log` 的 panic；it_nandfmt 见第 5 节】

**开发版缓存：** dyld-433.8 的 `loadPhase5` 和 dyld-390 一样：通信页 0xffff4084 第 0 位置位且缓存头 +0x68 的 cacheType 为 0，才先找磁盘上的文件（REA 反编译 `work/a6/vol-14G61/x/dyld` 0x7f28）。`n78_devcache.py` 加认 `dyld_v1  armv7s` 的头，最后打印改后的 CDHash。【已核实】

**GL 前端：** 10.3.4 缓存里 OpenGLES 导出的 489 个符号，现有的 9.x 前端（`work/a5/guest/OpenGLES`，armv6 和 armv7）全有（`work/a6/gles-missing-14G61.txt` 为空）。ObjC 方法没比成（`cacheinfo.py methods` 解析 armv7s 缓存出错），留到开机看。【已核实：导出】

**信任缓存：** `n78_diskfix.sh` 的 14G61 分支把三样东西的 CDHash 写到盘镜像旁边的 `DISK.img.trust`：重签后的 mobileactivationd、改后的缓存、GL 前端（两个切片）；做开机包时 `N78_TRUST=DISK.img.trust`。`n41_trustcache.py` 换掉 4 条两边都对不上的条目。【已核实：`work/a6/nandfmt/disk-n2.img.trust`、`trust cache: 4 hashes added`】

Setup 完成状态照用 9.x 的 `n78_setupdone.py`（35 个键，ForceNoBuddy），10.x 是否还认待开机看。

```bash
cp -c work/a6/nandfmt/disk-1034-formatted.img work/a6/nandfmt/disk-n2.img && tools/a5/n78_diskfix.sh work/a6/nandfmt/disk-n2.img
N78_TRUST=work/a6/nandfmt/disk-n2.img.trust N78_SHOW=arm-io/iop,arm-io/flash-controller0 \
  python3 -I -B tools/a5/n78_kboot.py work/a6/dec/14G61-n41 work/a6/kboot/n41-14G61-n2.bin
mkdir -p work/a6/nandfmt/nand-n2 && cp -c work/a6/nandfmt/nand-1034-formatted/* work/a6/nandfmt/nand-n2/
MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-n2.img SNAP=off tools/a5/n78_run.sh work/a6/runs/n2 work/a6/kboot/n41-14G61-n2.bin 360 \
  -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-n2
```

**第二次正常开机（`work/a6/runs/n2`，改过的盘，信任缓存错加了 SHA-256 哈希）：** 系统钥匙包载入（`MKB_INIT: System Keybag loaded`），屏幕上是苹果标志加进度条（第一次开机的数据迁移，A5 上也有），SpringBoard、backboardd、lockdownd、mediaserverd 等都起来了；约 270 秒时 launchd 因上面的 mobileactivationd 不是平台二进制而 panic。期间串口有 60 多行 `AMFI: code signature validation failed.`，不带文件名。【已核实：`n2/shot-100.png`、`n2/serial.log`】

**第三次（`work/a6/runs/n3`，信任缓存改用第 0 槽哈希）：** 串口上一条 `AMFI: code signature validation failed` 都没有了（n2 的 60 多条看来都是这几个文件）。数据迁移从头做到满格（约 260 秒）。**GL 前端在 iOS 10 上原样能用**：QEMU 输出 `[gles] host GL up: 2.1 Metal … Apple M4 Max`、`OpenGLES front end (contrib/gles-public): 508 gl exports`、`CoreAnimation composites through the host`，随后贴了几十张纹理、画了 ES2 的 `glDrawElements`；SpringBoard 打出 `creating global IOSurfaces`。【已核实：`n3/qemu.out`、`n3/serial.log`】

迁移满格后约 90 秒，第二个 SpringBoard（pid 201，迁移结束后重启的那个）里内核 panic：`pmap_page_protect: bad pve entry pte_p=0x8ecef000 … pte=0xff6ac1b0, va=0x3000000 ppnum: 0x8e6a1`。这个「页表项」低两位是 00，不是有效项，说明该页表所在的物理页被写坏了。嫌疑：宿主侧 GL 桥（或别的直接写客机内存的模型）在第一个 SpringBoard 退出后还往它用过的物理地址写，那些页被回收成了页表。【已核实：panic 内容；原因是推测】A5 的 9.3.5 第一次开机也是做完迁移后「从这块盘再开」。

## 10. 卡点：迁移之后内核内存被改写（已解决，见 13.1）

迁移完成后从同一块盘再开（`n4`、`n5`），每次都在锁屏出来之前 panic，panic 的种类每次不同，共同点是内核的内存被别人改了：【已核实：各 `serial.log`】

| 运行 | panic |
|---|---|
| n3 | `pmap_page_protect: bad pve entry … pte=0xff6ac1b0`（页表项被写成 0xff6ac1b0，低两位 00，不是有效项；在第二个 SpringBoard 里） |
| n4 | `kernel abort type 4 … fault_addr=0xc2dd3000`，在 IRQ 处理里（AIC → IOCPUInterruptController → 驱动） |
| n5 | `a freed zone element has been modified in zone kalloc.192: expected 0x38618738 but found 0x70007` |

排查到现在：

- **开机包的内存布局没问题。** 1 GiB 时 memSize 0x3F700000，vram 0xBF700000（和 QEMU 帧缓冲的地址一致），pram 在最顶上。【已核实：`ipad1_kboot.layout`、`N78_VRAM_BASE`】
- **设备模型里没有写死 512 MiB 的地址掩码。**（CDMA 的 dram-size 跟着板子走，IOP 模拟把 IOP 侧 0xC0000000 起的地址换回 0x80000000，1 GiB 正好覆盖。）格式化开机的 IOP 跟踪里，FMI 命令带的缓冲区地址都是合理的物理地址。【已核实：`fmt4/q.log`】
- **GL 写回的几何没问题。** 临时加了日志（`IT_GLES_PAGELOG`），记 GL 宿主把 surface 写回客机内存时落在哪些页：两张 640×1136 的落在 vram 里，一张 744×1392（行距 3008 字节）落在 0x9C/0x9D 一带的零散页上，页数和尺寸对得上。但写回用的是缓存的页表（按 surface 的内核 ID 记住、只在同一调用进程里核对），进程退出、页被回收后再写就会写坏别人的页，这一点还没排除。【已核实：几何；陈旧页是推测】
- 对照实验 `n6`：`IT_GLES_NULL=1`（所有 GL 调用不做事，宿主完全不写客机内存），同一块盘开 300 秒，看内存损坏还在不在。

对照 `n6` 的结果：300 秒里没有出现内存被改写，但约 150 秒时换成 IOP 控制消息超时（`IOP::_sendControlMessageGated: timed out with partially completed command - granting grace period 1` 到 5），随后 panic `IOP: timed out waiting for workloop to process completed command`。别的运行里都没有这条。所以这次对照不够干净：不能说明 GL 写回就是元凶，也不能排除。【已核实：`n6/serial.log` 第 236 到 255 行】

## 11. 回归 n78 的 9.3.5

改过的公共代码：`ipod_touch_5g.c`（N78Board 重构、iPhone 5 子类、Swift 的定时器接线，后两样只对带通用定时器的 CPU 生效）、`n78_kboot.py`、`n78_unpack.py`、`n78_activate.py`、`n78_devcache.py`、`n78_diskfix.sh`、`cdhash.py`。

- 9.3.5 格式化后的盘新克隆一份，用新的 `n78_diskfix.sh` 改盘：13G36 分支照常（激活补丁、开发版缓存、GL 前端、属主、Setup 35 个键），不生成 trust 文件。【已核实】
- 第一次开机（`work/a6/runs/reg935`）：数据迁移，迁移后在 ReportCrash 里 panic `kernel abort type 4 … fault_addr=0xffffffff`。A5 阶段的做法本来就是迁移后从这块盘再开。【已核实】
- 第二次开机（`work/a6/runs/reg935b`）：**88 秒锁屏**，OCR 认出「iPod」「Wednesday, December 31」「slide to unlock」（截图 `docs/reports/img/a6-regress-935-lock.png`）。【已核实】
- 锁屏之后约一两分钟，SpringBoard 里内核 panic `kernel abort type 4 … far 0xf`。A5 阶段 9.3.5 到「设置」的那几次在各自的时长里没有 panic，这次对 n78 实际生效的 QEMU 改动只有 N78Board 重构（值和原来一样），所以更像原来就有、偶发的问题，和 A6 的几次内存改写可能同源。【已核实：现象；同源是推测】

## 12. 补丁、文档

- **补丁并进 `patches/a5-n78-skeleton.patch`**（现在 13 个文件）：iPhone 5 是同一个 `ipod_touch_5g.c` 里 n78 机型的子类，用的是重构后的 `N78Board`，单独出补丁也只能叠在它上面、不能单打；`cpu32.c` 的 `apple-swift` 只有二十来行。文件名不改，`build-qemu.sh` 和工作树的流程不用动。在上游原样的临时克隆里按 `build-qemu.sh` 的顺序打四个 iOS 补丁、这个补丁、`a5-n78-ios-ui.patch`，都打得上。【已核实】
- 注意：`work/ios/qemu-ios`（App 用的 iOS 工作树）打的还是旧的 skeleton 补丁，下次编 App 前要从上游重建这个工作树再打全套补丁。
- `docs/plan.md` 加了一行，`README.md`、`tools/a5/README.md`（A6 一节）同步。临时诊断代码（`IT_GLES_PAGELOG`）已删。

## 13. 锁屏和主屏（第二轮）

决策会话核对后要求继续查迁移后的内存改写，目标锁屏和主屏。这一轮依次解决了三件事，`work/a6/runs/n15` 开到了锁屏和主屏。

### 13.1 内存改写：GL 写回往已释放的 surface 页里写

- n3 那个坏页表项 0xff6ac1b0，按内存字节序是 B=0xb0、G=0xc1、R=0x6a、A=0xff，一个不透明的青蓝色像素；n5 的 0x00070007 不像像素，n4 是读到坏指针。【已核实：数值】
- 嫌疑对象：GL 宿主的 surface 写回（`gles_surface_writeback`）。绑定时按调用进程的页表把 surface 的物理页记下来，之后任何进程 glFlush/glFinish 都会把所有「脏」surface 按这张缓存的页表写回客机内存，从不再核对。surface 被释放或所属进程退出后，这些页回到内核，再写就写进了别人的页。
- 修法（`hw/arm/gles-host.c`）：绑定时记下所属进程的 TTBR0；写回前用这张页表（短描述符，按当时的 TTBCR.N）重走 surface 的首、中、尾三页，任一页已不映射或换了物理页就丢掉这次写回、作废缓存。没有缓存页的 surface（按虚拟地址写）只许所属进程自己写。这个核对由机型打开（`gles_host_set_owner_check`，n78/n41 打开），因为 4.x 内核只给进程留最后碰过的那页映射，老机型照旧。【已核实：代码】
- 验证：n7 起每次都有一条 `[gles] surface tex 1 (744x1392 at 0x02e66000) no longer its process's: frame not written back`。临时诊断（已删）显示当时所属进程就是调用者本身（TTBR0 相同、ASID 0x29），第一页在它自己的页表里已没有映射，QEMU 自己的地址翻译也给出同样结论（`qemu 0 0`）。744×1392 正是 iPhone 5 带视差边距的壁纸尺寸，和青蓝色像素对得上。之后 n7 到 n15 都没再出现内存改写型 panic。【已核实：`n7/qemu.out`、`n10/qemu.out`、各 `serial.log`】

### 13.2 PMU 的 ADC 不完成：backboardd 的 HID 服务被拖住

- 改写消失后，画面停在苹果标志、随后熄屏，后来还出 IOP 控制消息超时 panic。数据卷上的崩溃报告（`stacks+backboardd`，看门狗抓的全体线程栈）用新写的符号化脚本（按共享缓存的镜像和导出符号）看：backboardd 的 HID 事件服务线程卡在 `IOHIDServiceCopyEvent` → 内核里 `AppleEmbeddedTempSensor` → `AppleDialogPMU` → `AppleD1972PMU::_readADCGated`。【已核实：`n12/crash/`】
- D1972 读 ADC（REA 反编译 0x810e6440）：往 0x48 写「通道 | 0x20」启动，最多等 1 秒等中断处理把状态改成 2，再读 0x49、0x4A 拼成 12 位结果。我们的 PMU 替身只是寄存器表，没有中断，每次读都干等满 1 秒（串口里的 `ADC read bad state: 1`），温度传感器一次取数要读好几个通道，HID 服务是串行的，后面的请求全被堵住。A5 的 9.3.5 也有同样的报错，只是没堵到这个程度。【已核实】
- I2C 跟踪（`I2C_TRACE=1`）看到 D1972 用一字节寄存器地址；0x12 到 0x1A 是 9 个中断屏蔽字节（开机全写 0xFF，之后只在 0x13 打开 bit7 和 bit5）；中断处理读 0x01 起 9 个事件字节，从不往里写。PMU 中断按设备树是 GPIO 6 号脚。【已核实：`work/a6/runs/i2c1/q.log`、`DeviceTree.txt`】
- 修法（`hw/arm/s5l8940_i2c.c`，只对 n41 打开，n78 的 PMU 不变）：0x48 写入带 0x20 时填结果（半量程 0x800）、置事件 0x02 的 bit5；事件寄存器读即清；有未屏蔽事件就拉 GPIO 6（低电平有效）。先试的「写 1 清」不对：驱动读了 26 万次事件、从不清，成了中断风暴；改成读即清后每次转换正好一次中断。ADC 报错从 12 条变成 0 条。【已核实：`i2c2`、`i2c3` 的 `q.log` 和 `serial.log`】
- 同时把递减器转发改成 AIC 的中断先走（两者同时挂起时不转到 0x1C）。这一条是为 IOP 超时加的，单独看没有解决它（n11 仍超时），保留是因为更合理；IOP 超时在 13.2 修好之后再没出现过。【已核实：n11 仍超时；n13 到 n15 没有】

### 13.3 CommCenter：SpringBoard 主线程等基带

- PMU 修好后 backboardd 的看门狗报告里，等的是 SpringBoard：`BKWatchdogService isAlive` → `BKSystemAppSentinel ping` → `pingSystemApp:timeout:`。SpringBoard 主线程卡在 UIApplicationMain 的运行循环里，经 PersistentConnection 定时器向 CommCenter 发同步 XPC（CoreTelephony 查数据连接状态）。iPhone 5 的基带我们藏掉了，CommCenter 一启动就段错误，崩溃报告每次运行十几二十份。【已核实：`n14/crash/stacks+backboardd-…160244.543.ips`，backboardd 的方法名来自 REA 解析 `/usr/libexec/backboardd`】
- 修法：iOS 10 的 launchd 从 `/private/var/db/com.apple.xpc.launchd/disabled.plist` 读禁用的任务（launchd 里的字符串，文件已由 launchd 自己建好），加上 `com.apple.CommCenter: true`。服务名不再注册，CoreTelephony 的请求立刻失败。先手工改了 disk-n2 的数据卷验证。【已核实】
- 已并进 `n78_diskfix.sh` 的 14G61 分支：全新的数据卷上只有这个目录（属 root、755），没有文件，所以这一步用 `noowners` 重挂后写入（已有就合并），卸载后用 `build_nand.set_owner` 把属主改回 root。【已核实：`disk-n3.img` 上 `launchd disabled: ['com.apple.CommCenter']`、`owner root: 1 record`】
- `n78_run.sh` 加了 `QEMU=` 变量，指定用哪个 qemu-system-arm（做新旧版对照用）。

### 13.4 结果（`work/a6/runs/n15`）

- **82 秒锁屏**：状态栏「Searching…」、电量图标，中间一条通知「CONTENTS NOT AVAILABLE / Cannot read the connected storage media.」（iOS 把我们的 USB 根盘当成了外接存储设备），底部翻页点和相机图标（`docs/reports/img/a6-1034-lockscreen.png`）。【已核实：OCR 和截图】
- **按 Home 进主屏**（175 秒按下，178 秒截图）：iOS 10 主屏，时间 4:03 PM，Mail、Calendar（Wednesday 31）、Photos、Camera、Maps、Clock、Weather、Stocks、Wallet、Notes、Reminders、News、iTunes Store、App Store、iBooks、TV、Home、Health、Settings，Dock 上 Phone、Safari、Messages、Music（`docs/reports/img/a6-1034-home.png`）。【已核实】
- 瑕疵：壁纸没出来（黑底加几道彩色横纹，大概就是 13.1 被丢掉的那张壁纸 surface），图标下没有文字，Dock 的文字位置是黑块。没有 panic，也没有 IOP 超时。【已核实：截图】

### 13.5 9.3.5 锁屏后的 `far 0xf`：新旧两版对照

- 旧版：334612f 时的 `a5-n78-skeleton.patch` 打在同一个上游版本上，另建工作树 `work/a6/qemu-old`、另编 `work/a6/build-old`（子项目从现有工作树本地复制，没有下载）。新版：现在的工作树（含 N78Board 重构、GL 所属进程核对）。
- 两版用同一块 9.3.5 盘（`work/a6/regress/disk-935.img`，迁移后的状态，快照模式，起点完全相同）、各自一份 NAND 副本，同时开 300 秒，85、150、250 秒按 Home 截图。【已核实：`work/a6/runs/c935-old`、`c935-new`】

| | 锁屏（OCR） | panic |
|---|---|---|
| 旧版 334612f | 153、253 秒 | 无 |
| 新版 | 88、153、253 秒 | 无 |

- 两版都没复现 `far 0xf`，新版里 GL 所属进程核对一次都没触发。reg935b 那次 panic 用的是加核对之前的版本，盘是迁移后第一次重开。所以这次不能说它是这轮改动引入的，也没能归因，记为偶发。【已核实：上表；归因未定】


## 14. 画面缺陷和解锁（第三轮）

决策会话看了 13.4 的截图：系统确实起来了，但壁纸全黑、中间有横向花屏线、文字没画出来、锁屏没有时间日期，要求如实记下、修完再算「进锁屏、进主屏」，然后照 A5 的路解锁、进「设置」。这一轮的结果：文字、时钟日期、花屏线修好了；**壁纸仍是黑的，触摸驱动链在 n41 上没起来，所以没能解锁进「设置」**。

### 14.1 文字、时钟、花屏线：iOS 10 的 `LA08` 表面格式（已修）

- n15 的宿主日志里有两条格式拒绝：`REFUSED surface:LA08`、`REFUSED surface:RGhA`。iOS 10 的文字层（CoreText 画好的字形）用的 IOSurface 像素格式四字码是 `LA08`（亮度加透明度各 8 位），宿主只认 iOS 7 的 `LA88` 和更早的 `2C08` 两种写法，这种 surface 绑不上，文字层就是空的：图标名、Dock 文字（黑块）、锁屏的大时钟和日期都在这一类里。【已核实：`n15/qemu.out`】
- 修法（`hw/arm/gles-host.c`、`gles.h`）：`LA08` 按 `LA88` 同样处理（每像素 2 字节，以 GL_LUMINANCE_ALPHA 上传）。`RGhA` 是半精度浮点的 RGBA（每像素 8 字节），见到的是一张 256×1 的查找表，上传时转成 8 位 RGBA；绑定和刷新两处的像素缓冲按 `MAX(4, 每像素字节数)` 分配。【已核实：代码】
- 修后锁屏有「4:02」和「Wednesday, December 31」，主屏图标名、Dock 文字都在，中间的横向花屏线也没了（花屏线是哪一层没画出来留下的，没单独核对，按修后消失推断与此同源）。之后 p3、p6、p10、s1、f2 的截图都是这样，日志里不再有这两条拒绝。【已核实：截图和 OCR；花屏线的来源是推测】

### 14.2 壁纸：合成器用的 surface 从来没被写过（未解决）

- 渲染进程这一侧是对的：p15 用 `-trace gles_surface_log` 看，处理壁纸的进程把 744×1392 的 surface（客体地址 0x02e66000）画好后写回，采样和 6279561，不是空的。【已核实：`p15/qemu.out` 第 66、67 行】
- 同一进程后来又往这张纹理画了一次，这次写回被所属进程核对挡下：它自己的页表里第一页已经没有映射（`probe 0/4089 r 0`，当前 TTBR0 就是绑定时那个），前面刚有 `glDeleteTextures(1)`。也就是这块 surface 已被它自己的进程释放，挡下是对的；放开核对就会出 13.1 那种内存改写（见 14.4 的 p7）。【已核实：`p14/qemu.out` 第 53 到 80 行，诊断代码已删】
- 合成器（backboardd 的上下文）绑的是另一块 744×1392：IOSurface 号 5 被重用了，但物理页完全不同（第一页 0x3cdb3000，渲染进程那块是 0x18b1e000），采样和 2722635，屏上就是黑底。整个运行里没有任何 GL 调用往这块内存里画过，所以从渲染进程的结果到合成器的 surface 之间少了一步复制，而这一步不经过我们桥接的 GL。【已核实：`p13/qemu.out` 的 `[surf]` 诊断行】
- 少的这步是什么还没查实。【推测】嫌疑一：M2 缩放器（IOSurfaceAccelerator 的 transfer），开机包把两个缩放器藏了（A5 时 9.3.5 碰它就 panic）；GL 前端为 4.x 接过有条件的 transfer，但 10.3.4 的日志里一条 transfer 记录都没有。嫌疑二：CPU 侧拷贝（锁住 IOSurface 再 memcpy）发生在我们把帧写回之前。试过让前端的 `clientWaitSync` 先把上下文刷一遍，让帧在 CPU 读之前写回（p13），壁纸照样黑，已撤回，前端恢复原样（`work/a6/OpenGLES.before-sync`，CDHash 不变）。9.3.5 在同样隐藏缩放器的情况下壁纸正常，说明 iOS 10 换了壁纸的出图路径。
- 下一步建议：在 backboardd 绑那块 surface 之前，按 IOSurface 号追谁写过它的物理页（QEMU 里给这几页设写监视），看是内核驱动（缩放器）还是用户态拷贝。

### 14.3 触摸：n41 的 SPI 控制器没起来（未解决，所以没进「设置」）

- s1：120 秒锁屏，135 秒按 Home 进主屏；150 秒、190 秒两次点「设置」图标（(396,918)、(396,818)，按 640×1136 的屏幕坐标），之后的截图一直是主屏，串口里没有一行多点触控的日志。【已核实：`s1/in-160.png` 到 `in-215.png`、`s1/serial.log`】
- 往上查：n78 的串口里有 `AppleSamsungSPIController::start: spi1 …`、`spi2 …`，随后 `multi-touch@0:AppleARMSPIDevice::initWithRegistryEntry`；n41 上一行 SPI 日志都没有，控制器本身就没起来，触摸驱动（`AppleMultitouchN1SPI`，「C1,N41」那份人格是有的）自然轮不到。【已核实：`work/a5/runs/s317/b4/serial.log` 第 63 到 171 行对照 `s1/serial.log`】
- 两版的驱动和匹配条件一样（`com.apple.driver.AppleSamsungSPI`，IONameMatch `spi-1,samsung`，n41 的 spi1 节点也是这个 compatible），开机包没有藏 spi 节点。两边 spi1 节点的差别：n41 的 `clock-gates` 是 0x1b（n78 是 0x44），`dma-channels` 用 0x11、0x12（n78 是 0x0b、0x0c），`dma-parent` 指向另一个节点。【已核实：两份 `DeviceTree.txt`】
- 【推测】控制器卡在它依赖的东西上：A6 的时钟门 0x1b 或 DMA 控制器在我们的模型里没就绪，驱动在 start 之前就放弃了，所以连 `start` 那行都没打。还没查实。
- 所以决策会话说的触摸中断脚 0x1901 这一轮验不了，「设置」也没能点开（A5 的路是滑动解锁、点「设置」，都靠触摸）。

### 14.4 其他问题

- **开机后整段黑屏（偶发）**：这一轮 14 次带截图的开机里（不算关掉核对的 p7）有 4 次（p5、p12、f1、g1）从头黑到尾、按 Home 也不亮，没有 panic，同一块盘、同一个开机包再开就正常。原因没查。【已核实：现象】
- **关掉所属进程核对的对照（p7）**：用当时的诊断开关关掉核对，开机后 panic `kernel abort type 4: fault_type=0x1, fault_addr=0xff006764`，说明 13.1 的核对仍然必要。【已核实：`p7/serial.log` 第 335 行；开关已随诊断代码删掉】
- **电话图标的红色角标里没有数字**：角标本身画出来了，数字没有；可能还是某种没认出的文字层，但日志里已没有格式拒绝，没查。【已核实：现象】
- **锁屏通知「CONTENTS NOT AVAILABLE / Cannot read the connected storage media.」**：iOS 把我们挂根用的 USB 盘当成了外接存储配件。这一轮没去设备树或配件服务那边压它，不影响开机和进主屏。【已核实：现象；没查】
- 电池图标是红色（快没电）：PMU 的 ADC 现在一律回半量程，电量读数大概由此而来，没查。【推测】

### 14.5 最终验证（快照模式，同一块迁移过的盘 `disk-n3.img`）

| 运行 | QEMU | 锁屏（OCR） | 按 Home 后 | panic |
|---|---|---|---|---|
| f2 | 删完诊断代码的版本 | 100、120 秒：「4:02」「Wednesday, December 31」 | 140、170 秒主屏，图标名齐 | 无 |
| f1 | 同上 | 整段黑屏（14.4） | 黑 | 无 |
| g1 | 补丁改写法之后（14.6） | 整段黑屏 | 黑 | 无 |
| g2 | 同上 | 100、120 秒 | 140、170 秒主屏 | 无 |

- 锁屏和主屏的截图换成 f2 的（`docs/reports/img/a6-1034-lockscreen.png`、`a6-1034-home.png`）：有大时钟、日期、图标名和 Dock 文字，没有花屏线；壁纸黑、电话角标没有数字、锁屏那条存储通知还在。【已核实】
- 黑屏的几次里有的带一条「GL 调用访问客体页四次缺页后被丢弃」（slot 237），但 n15、p2、p11、p13 也有这条却正常，p12 黑屏却没有，所以和黑屏对不上。【已核实：各次 `qemu.out`】
- 9.3.5 回归（n78，`work/a6/regress/disk-935.img`）：f935 和 g935 都是 88、153 秒锁屏，没有 panic，所属进程核对一次没触发。【已核实：`f935`、`g935`】
- 结束时没有 QEMU 进程。

### 14.6 补丁

- 这三轮的 QEMU 改动仍并在 `patches/a5-n78-skeleton.patch`（16 个文件）：iPhone 5 是 `ipod_touch_5g.c` 里 n78 的子类，PMU 和 GL 宿主的改动都由机型打开（所属进程核对 n78/n41 都开；PMU 的 ADC 只给 n41），拆成单独补丁也只能叠在它上面。
- 这一轮 GL 宿主的改动一开始和 `ios-gles-perf.patch` 碰到同几行（`GLESSurface` 里 `detached` 后面、绑定时找可复用纹理的循环），按 `build-qemu.sh` 的顺序打不上。改了写法：新字段 `ttbr`、`unwritten` 放到 `gen` 前面（在快照保存的 36 字节之外，恢复时清零，即「不知道」）；「渲染了但没写回」的 surface 在原循环之前单独过一遍，同一块物理内存被另一个进程绑定时把它改记成按这个进程地址的「已脱离」副本，原循环一行不动。【已核实：代码】
- 在上游原样的两个临时工作树里核对：按 `build-qemu.sh` 的顺序打四个 iOS 补丁、`a5-n78-skeleton.patch`、`a5-n78-ios-ui.patch` 全部打得上；只打 skeleton 得到的 `gles-host.c` 和 Mac 工作树逐字节相同。Mac 版重编通过。临时工作树已删。【已核实】
- `work/ios/qemu-ios`（App 用的 iOS 工作树）还是旧补丁，下次编 App 前要重建（同第 12 节）。iOS 版这一轮没有编。
- 新工具 `tools/a5/stacksym.py`：把看门狗的全体线程栈报告按共享缓存命名（13.2、13.3 就是用它看出谁在等谁），`tools/a5/README.md` 的 A6 一节已加，并补了 CommCenter、`QEMU=` 和从迁移过的盘开到主屏的命令。
- 旧版对照用的 `work/a6/qemu-old`（上游的 git 工作树，334612f 时的补丁）和 `work/a6/build-old` 留着，以后再做新旧对照不用重建；不要了用 `git -C upstream/qemu-ios worktree remove work/a6/qemu-old` 删。

## 15. 触摸、「设置」、壁纸（第四轮）

决策会话核对第 14 节后定的顺序：先修触摸（挡着进「设置」），再查壁纸，再查偶发黑屏；顺手看存储通知和电池；补查 g2 里另外三条 REFUSED。

### 15.1 触摸：时钟频率表只填到第 55 槽（已修）

- 先排除了 PMGR 和 DMA：t1 带 `-d unimp` 开机，未建模设备里访问最多的是 `0xf800438`、`0xf80020c`（各五千多次），在 n41 设备树里是 `perfcounter`（和 pmgr 的第二段同址），写入值在一组固定配置和 0 之间来回切，像空闲进出时开关性能计数器，与 SPI 无关；spi1 的 `dma-parent` 两边都指向 `cdma`，CDMA 驱动在 n41 上照常起来（`CDMA::_mapKeyID` 那行两边都有）。t1 里 spi1 一次片选都没有。【已核实：`work/a6/runs/t1/qemu.out`、两份设备树】
- 反编译 10.3.4 的 `AppleSamsungSPIController::start`（kext 包成 ELF，`work/a6/dis/spi-14G61.elf`，REA，0x807df4e0）：读完 `spi-version` 后向父设备要名为 `nclk` 的时钟频率（vtable +0x34c，64 位返回），**为 0 就直接返回，什么都不打**，打 `_spiBaseAddress` 那行在这之后。【已核实：反编译】
- 时钟频率来自 `arm-io/clock-frequencies`，按 clock-id 的低字节取槽。开机包用的是 imgtools 里 A4 的 55 项表 `CLOCKS`；n41 的设备树有 96 个槽，后 41 个留成 0。n41 的 spi1 时钟是 0x12b、0x13b，spi3 是 0x13d，0x3b、0x3d 都在第 55 槽之后；n78 的 spi1 是 0x130、0x133，在表内，所以 A5 没事。【已核实：设备树】
- 修法（`tools/a5/n78_kboot.py`，只对 n41）：把表按设备树的槽数补满，多出的槽给外设时钟（和表的默认值一样，100 MHz）。n78 的开机包不变。【已核实：代码】
- 修后（t2 起）：串口出现 `AppleSamsungSPIController::start: spi1: _spiBaseAddress = 0x32100000…` 和 spi3 的同一行，`AppleMultitouchN1SPI: successfully started`，下发 32 字节接近感应校准、32 字节触摸校准和固件 `0x0266.bin`（114 ms），和 A5 的 9.3.5 一样；QEMU 侧 spi1 有 250 次片选、触摸模型 1221 条日志，150 秒那次点按被收成一次按下和抬起。【已核实：`t2/serial.log` 第 62 到 225 行、`t2/qemu.out`】

### 15.2 触摸的家族号，进「设置」（已修）

- t2 到 t5：驱动链起来了，点按也被收到（t5 的 145 秒、205 秒两次按下抬起），但主屏毫无反应。【已核实：`t5/qemu.out` 的 `FINGER` 行、截图】
- 原因在传感器自报的家族号。触摸模型对 n41 用的还是 n78 那份参数，自报家族 0x58（iPod touch 5 的 C1F58）。14G61 系统卷上的 `N41.mtprops` 只有一项 `C1F57,1`（固件 `0x0266.bin`，64340 字节），内核里 N41 的人格也在 `AppleMultitouchSPIC1F57` 下，所以 iPhone 5 是家族 0x57。固件照样下发（mtmergeprops 只认文件名），但 iOS 10 已不支持 iPod touch 5，按 0x58 报上来的帧没被变成触摸事件。这是推断：没有去拆 MultitouchSupport 核对，依据是改了家族号就好了。【已核实：mtprops 内容（只读挂载 `work/a6/vol-14G61/system.img`）；「0x58 被丢掉」是推测】
- 修法（`hw/arm/ipod_touch_5g.c`）：给 n41 单独一份 `mt_profile_n41`，家族 0x57、固件版本 0x266，几何参数沿用 n78 的（同是 4 英寸屏）。【已核实：代码】
- t6：100 秒锁屏，120 秒按 Home 进主屏；135 秒左滑翻到第二页（FaceTime、Calculator、Podcasts、Watch、Extras），150 秒右滑回来；**170 秒点「设置」图标（396,860），「设置」打开**，显示「Sign in to your iPhone」、飞行模式、蓝牙、通知、控制中心、勿扰、通用。【已核实：`t6/in-145.png`、`in-180.png`，存为 `docs/reports/img/a6-1034-home-page2.png`、`a6-1034-settings.png`】
- 触摸中断脚 0x1901（设备树 interrupts 0xc9 = 0x19 × 8 + 1）由此验过：中断不对的话驱动收不到帧。点按的位置见 15.3。

### 15.3 整段黑屏：一熄就叫不醒（定性：不是 GL 宿主或显示管线，在用户态；未修）

- **黑屏和 LCD 关闭一一对应**：到 t3 为止 15 次带截图的开机里，5 次黑屏（p5、p12、f1、g1、t2）的串口都有 `ApplePinotLCD::_lcdEnable: enable: 0`，10 次正常的都没有；之后的 t3、t9 也一样。注册顺序（USB 盘先于背光）对不上。【已核实：各次 `serial.log`】
- **10.3.4 熄屏后按 Home 叫不醒**：t8 在锁屏出来后 125 秒按电源键，LCD 关；140、155 秒两次按 Home，截图一直是黑的，DSI 上除了 125 秒那串关屏命令再没有任何写入，内核根本没收到开屏请求。9.3.5 同样的操作是 `_lcdEnable: 0` 后跟 `_lcdEnable: 1`（`g935`、`c935-new`）。【已核实：`t8/qemu.out` 的 DSI 跟踪（带时间戳）、`t8/serial.log`】
- t4 是正常的一次：40 到 70 秒苹果标志，80 秒起锁屏一直亮到 150 秒，160 秒按 Home 进主屏。所以黑屏那几次不是锁屏超时熄掉的，而是锁屏还没画出来，屏就关了。【已核实：`t4/in-*.png`】
- 不是系统睡眠：熄屏后内核日志照常（温度传感器每隔几秒一行），「prevent idle sleep」计数没到 0（背光那个断言还在）。【已核实：`t8/serial.log`】
- **卡在 SpringBoard**：t9 用可写克隆盘开机（正好黑屏），数据卷上留下 backboardd 看门狗的三份全进程栈（bug_type 288，原因「Watchdog: taking a stackshot」）。用 `tools/a5/stacksym.py` 看，SpringBoard 主线程两次都卡在同步等待：一次在 FrontBoard 经 LaunchServices 发的同步 XPC 里，一次在 Widgets 里等信号量。Widgets 那个函数（0x320c85b2，选择子按 iOS 10 缓存的 v2 滑动信息还原）是取小组件图标：`[[widget extension] objectForInfoDictionaryKey:]`、`[LSPlugInKitProxy pluginKitProxyForIdentifier:]`、`bundleURL`、`[NSBundle bundleWithURL:]`、`[UIImage imageNamed:inBundle:…]`，返回地址落在 `objectForInfoDictionaryKey:` 之后。同一时刻 pkd、lsd 都闲着，所以不是哪个服务卡死，是 SpringBoard 在等一个不会来的回复或信号。backboardd 主线程正常待在 run loop 里。【已核实：`work/a6/runs/t9/crash-sym/stk-160031.406.txt`、`stk-160118.805.txt`（符号化后的全文；原始 .ips 在克隆盘上，克隆盘做 t10 时已删）；选择子名的还原方法见 15.6】
- 所以按决策会话要的三分法，黑屏属于「SpringBoard 没起来」，不是 GL 宿主没出帧、也不是显示管线没刷新。为什么只是偶发（同一块盘、同一个开机包）、等的到底是什么，还没查到。【推测】和启动时各服务的先后有关：先起来的服务没准备好时，同步请求就一直等。
- 同一次 t9 里 mediaserverd 崩了 10 次（`HDR.videoprocessor` 插件里抛出未捕获的 C++ 异常后 abort，相机和视频处理那一路），disk-n3 上之前的崩溃报告里也有，和黑屏不一定有关，先记下。【已核实：崩溃报告】
- **熄屏后叫不醒也是 SpringBoard 主线程卡住，等的是 mediaserverd**：t10 用可写克隆盘开机，120 秒正常锁屏，125 秒按电源键熄屏，140 秒按 Home 没亮。这次留下四份看门狗全进程栈，SpringBoard 主线程四次都卡在同步等 mediaserverd：`Celestial` → `FigSharedPlayerCreate` → `FigPlayerRemoteCreate` → `FigSandboxReacquireServer`（CoreMedia 重连媒体服务的那一步）或 `CMSessionMgr…`，调用方是 SpringBoard 自己（按电源键锁屏时要建播放器，大概是播锁屏音）。同一次开机 mediaserverd 崩了 13 次，SpringBoard 一直在等一个不停重启的服务，主线程处理不了 Home。【已核实：`work/a6/runs/t10/crash/`（原始 .ips 和符号化文本）】
- **mediaserverd 为什么崩**：每次都是 `HDR.videoprocessor`（相机 HDR 合成，只在共享缓存里，系统卷上 `/System/Library/VideoProcessors/` 只有 BarcodeScanner）初始化时 `bad_alloc` 后 abort。反编译（`work/a6/dis/HDR-14G61.elf`）：0x30f78704 用 `[[EAGLContext alloc] initWithAPI:2]` 建 ES2 上下文，成功后最后一步 `glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &this[4])`；建不成只打一句「couldn't create the eagl context」，`this[4]` 不写。构造函数 0x30f78ac4 随后按 `this[4] × 4` 字节 `new[]`，未初始化的值一乘溢出成 0xffffffff，`new[]` 抛 `bad_alloc`。宿主日志里「OpenGLES front end」只有 4 行（每个用上前端的进程一行），mediaserverd 重启 13 次一行没有，说明它在建上下文之前就被前端拒了。【已核实：反编译、`t10/qemu.out`；「在哪一步被拒」是推测】
- 前端（`contrib/gles-public/opengles.c`）里 ES2 上下文要过 `fe_es2()`：用 `access()` 看 `OpenGLES.framework/GLEngine.bundle` 在不在。【推测】mediaserverd 的沙盒不许它看这个路径，`access()` 失败，前端就当没有 ES2，`initWithAPI:2` 直接返回 nil。改法：只有 `ENOENT` 才算没有。前端重编（`work/a5/guest/OpenGLES`，旧的留在 `work/a6/OpenGLES.before-es2`），`n78_diskfix.sh` 装回 disk-n3、信任缓存换上新 CDHash，开机包重做。

- **mediaserverd 为什么崩（续）**：上面「前端拒了 ES2」的推测不对。前端握手行带上进程名后（t15、t16）看到：三个进程里失败的都是 `initWithAPI:3`（ES 3.0，A6 本来就不支持，真机也返回 nil、调用方退回 ES2，属正常）；mediaserverd 的 ES2 上下文建成了三次。再看 HDR 的初始化：单例已经在别的线程建过时，构造函数走「拷贝单例的上下文」那条分支，紧接着 `glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &this[4])`，却没有把那个上下文设成本线程的当前上下文。我们的前端对「没有当前上下文」的 GL 调用一律什么都不做，`this[4]` 就是堆里的旧数据，`new[]` 溢出抛 `bad_alloc`。【已核实：反编译 0x30f78704 的两条分支、`t15/qemu.out`、`t16/qemu.out`】
- 试过的修法（前端加 `fe_no_context`：没有当前上下文时，`glGetIntegerv` 查实现限值就按设备回答）**没用**：t21 里 mediaserverd 照样崩了 5 次，位置一模一样。已撤回（真机的 GL 在没有当前上下文时也什么都不做，留着只会和真机不一致）。`fe_es2()` 的改动也证明无关，已撤回。留下的只有两行日志：握手行带进程名；建上下文因 API 之外的原因失败时记一行。【已核实：`t21/crash/` 5 份 mediaserverd 报告】
- 【推测】HDR 的 `glGetIntegerv` 根本没走我们的前端：它在共享缓存里，调的是存根，存根指针原本指向缓存里苹果自己的 OpenGLES（0x1d0a33e8）。开发版缓存下 dyld 应当把它改绑到磁盘上的前端，若这个镜像没被改绑，调用就进了苹果原版、没有它认的上下文，什么都不写。下一步：在 mediaserverd 里看 HDR 镜像的懒绑定指针实际指向哪里。
- **熄屏后叫不醒（续）**：t17（mediaserverd 这次没崩）里 SpringBoard 主线程只在开机早期卡过几次同步调用（lockdown、偏好设置 XPC、CoreTelephony），**熄屏之后一直闲在 run loop 里**，backboardd 各线程也都闲着，屏照样叫不醒。所以熄屏后的问题不是谁卡住。【已核实：`t17/crash/` 九份栈】
- 不是系统空闲睡眠：熄屏后内核日志照常；加启动参数 `noidle=1`（内核里有这个字符串，IOPMrootDomain 的）也叫不醒（t19）。t18 的 PMU 跟踪里熄屏时有一串背光相关的写（0x6d、0x22、0x23），之后温度 ADC 不再轮询，是传感器随屏关了，不是睡眠。【已核实：`t18/qemu.out`（`I2C_TRACE=1`）、`t19/serial.log`】
- **熄屏后按 Home，内核收到了**：t20 给 GPIO 模型加了临时记录（已删），亮屏时两次按 Home、熄屏后两次按 Home，每次都看到中断处理程序清 0 号脚的挂起位、重写配置字（`0x880 <- 1`、`0x000 <- 0x20d`），熄屏前后一模一样。所以中断没丢，设备树里的 `function-wake_button_menu`（指向 PMU，`'STAT'` 0x180）这条 PMU 唤醒路也不是必经的。按键进了内核，用户态却没有去点亮屏幕，下一步要沿 HID 事件追：backboardd 有没有收到 Home 的事件、收到后为什么不点亮。【已核实：`t20/qemu.out`】
- 9.3.5 同样的操作能叫醒（15.3 开头），所以是 10.3.4 用户态这条路上缺了什么。开机就黑屏（锁屏没出来屏先关）和熄屏叫不醒是同一个现象的两种时机：开机早期 SpringBoard 主线程卡在同步调用里，backboardd 先把屏关了，之后就再也叫不醒。【推测】

### 15.4 锁屏的存储通知（已压掉）、电池（没修好）

- **存储通知**：文字「Contents not Available / Cannot read the connected storage media.」在系统卷上有两处：`MobileStorage.framework`（键 `MOUNT_FAILURE_*`、`VERIFICATION_FAILURE_*`）和 `DeviceOMatic.app`。发它的是 `com.apple.mobile.storage_mounter`：它的 launchd 配置在「可移动 USB 设备下出现块设备」时被拉起（`IOBlockStorageDevice`，父设备 `IOUSBHostDevice` 且 `removable`），正是我们挂根用的 USB 盘，挂不上就报 MOUNT_FAILURE。先只禁 `com.apple.device-o-matic` 不管用（t8 仍有通知），再禁 storage_mounter 后（t10 起）锁屏只剩「Press home to open」。两个都留着禁用：storage_mounter 只管外接盘和开发者镜像，DeviceOMatic 管外接配件，模拟器都用不上，后者在 A5 上报过「Cannot Use Device」。改在 `n78_diskfix.sh` 的 14G61 分支（数据卷 launchd `disabled.plist`）。【已核实：`t8/in-120.png` 有通知，`t10/in-120.png`、`t11`、`t13` 没有】
- 这条通知不只是难看：t7 那次开机慢，锁屏还没出来就按了 Home，通知变成主屏上的模态弹窗，挡住了点「设置」。【已核实：`t7/in-160.png`】
- **电池**：iPhone 5 的电量来自 uart5 上的电量计 `bq27540`（HDQ 协议，设备树 `uart5/gas-gauge`，驱动 `AppleHDQGasGaugeControl`，匹配 `gas-gauge,hdq`）。t1 里 uart5（0x2a00000）在未建模设备的访问清单里。给 n41 接上了 A4 机型现成的 HDQ 电量计模型（`s5l8930_hdq.c`，容量 1440 mAh，满电、不在充电），串口驱动认出了 `uart5`，但整次开机 HDQ 一个字节都没收到（`-trace s5l8930_hdq_log` 为 0），电池仍是红色快没电。驱动在等什么没查，按决策会话「能简单改就改」到此为止；模型留着（比未建模的 uart5 更接近真机，没有副作用）。【已核实：`t10/serial.log` 第 80 行、`t11/qemu.out`】

### 15.5 壁纸：排除了缩放器，修了一处只读页写回，仍是黑的（未解决）

- **不是缩放器缺了才黑**：10.3.4 里用到缩放器的是 QuartzCore（`CA::WindowServer::AppleDisplay` 有 `__IOSurfaceAccelerator` 成员，绑定 `IOSurfaceAcceleratorCreate`、`IOSurfaceAcceleratorTransformSurface`），但 9.3.5 的 QuartzCore 绑定的是同样两个函数，两个缩放器在 9.3.5 上同样藏着，它的壁纸正常。显示也不经过 DART（两边的 clcd 都只有 `dma-parent`），显示模型本来就会合两个 RGB 平面。【已核实：`cacheinfo.py binds`、两份设备树】
- 临时诊断（surface 绑定时打出进程的 CONTEXTIDR、第一页物理地址；`glReadPixels` 打出目标页和像素校验和；都标了 DIAG，收尾时删）看到三个进程：合成器每帧都绑一块 744×1392（IOSurface 号 5，物理页与渲染进程的不同）；渲染壁纸的进程只绑过自己那两块；**渲染进程画完后用 `glReadPixels` 把画面读回一块缓冲，而这次读回一直被丢掉**：目标页在页表里是只读的（短描述符 AP2=1、AP=11，各级都只读），我们注入的写权限错误（DFSR 0x80f，WnR=1）内核处理了四次，既不改成可写也不杀进程，第五次宿主放弃，这次调用作废。`surface:no-texture` 那条是另一个进程（CONTEXTIDR 8，绑的是 `420f`、`b64a` 这类 CoreVideo 格式的小块），和壁纸无关；`slot:877` 是 `glLabelObjectEXT`（调试标签，回 0 无害）。【已核实：`t11/qemu.out`、`t12/qemu.out` 的 `[surfdiag]` 行】
- 修法（`hw/arm/guest-gles.c`）：只对写、只在内核已经处理过四次之后、只对在页表里存在且可读的页，再重发一次调用，把这些页越过保护写进去（真机上 `glReadPixels` 的目标由 GPU 和驱动从内核一侧写，碰不到用户映射的权限）。写时复制的页在第一次写错误时就被内核复制了，到不了这一步。第一次发生时记一行 `REFUSED guest-write:read-only-page`。【已核实：t13 起日志里是这一行，不再有 `fault-dropped`】
- 修完之后壁纸**还是黑的**（t13、t15 的主屏截图）。所以这次读回不是壁纸本身（大概是取壁纸平均色之类），合成器那块 surface 的内容另有来路，还没找到。【已核实：截图；「读回的用途」是推测】

### 15.6 补丁、工具

- `patches/a5-n78-skeleton.patch` 重新导出（17 个文件）。这一轮的 QEMU 侧：`ipod_touch_5g.c`（n41 的触摸参数家族 0x57；uart5 接 HDQ 电量计）、`s5l8940.h`（`S5L8940_IRQ_UART`）、`guest-gles.c`（只读页写回）、`contrib/gles-public/opengles.c`（只加日志：握手带进程名、建上下文失败记一行）。在上游原样的临时工作树里核对：按 `build-qemu.sh` 的顺序打四个 iOS 补丁、skeleton、`a5-n78-ios-ui.patch` 全部打得上；只打 skeleton 得到的四个改动文件和 Mac 工作树逐字节相同。临时工作树已删。所有临时诊断（`[surfdiag]`、页表项、GPIO 记录、前端的 DIAG 行）都已删掉。【已核实】
- 改盘和开机包：`n78_kboot.py`（n41 的时钟频率表补满 96 槽）、`n78_diskfix.sh`（14G61 另禁 `com.apple.mobile.storage_mounter`、`com.apple.device-o-matic`）。
- `tools/a5/qinput.py` 加了 `T:chord:K1+K2..[:MS]`（几个键同时按下、同时松开），为 sysdiagnose 组合键加的；10.3.4 上按了没有产出 sysdiagnose，看门狗的全体线程栈够用了。
- iOS 10 的共享缓存（armv7s）里 `__DATA` 的指针带 v2 滑动信息：头部 0x38 处是 slideInfoOffset，`delta_mask` 0xe0000000、`value_add` 0x1a000000，读选择子、类名要先 `(v & ~delta_mask) + value_add`。`cacheinfo.py` 现有的方法不处理这一步（9.x 的缓存是 v1），这一轮是在脚本外手算的，没有改 `cacheinfo.py`。
- 这一轮新做的反编译输入在 `work/a6/dis/`（`spi-14G61.elf`、`QuartzCore-14G61.elf`、`Widgets-14G61.elf`、`HDR-14G61.elf`），可写盘留下的崩溃报告和符号化栈在 `work/a6/runs/t9/crash-sym/`、`t10/crash/`、`t14/crash/`、`t17/crash/`。

### 15.7 最终验证（删完诊断、撤回无效改动之后的版本）

| 运行 | 盘 | 100 秒 | 120 秒按 Home | 135/150 秒左右滑 | 170 秒点「设置」 | 200 秒按 Home | panic |
|---|---|---|---|---|---|---|---|
| t21 | disk-n3 可写克隆 | 锁屏 | 主屏 | 第二页、回第一页 | 「设置」打开 | 回主屏 | 无 |
| t22 | disk-n3 快照 | 锁屏 | 主屏 | 第二页、回第一页 | 「设置」打开 | 回主屏 | 无 |

- 两次都没熄屏，锁屏上没有存储通知。「设置」截图存为 `docs/reports/img/a6-1034-settings.png`（t6，和 t21、t22 的 182 秒截图一样），第二页存为 `a6-1034-home-page2.png`。【已核实：`t21`、`t22` 的截图和 OCR】
- t21 的数据卷上 mediaserverd 仍崩了 5 次（同一处 HDR），backboardd 看门狗留了 7 份全进程栈，界面没受影响。【已核实：`t21/crash/`】
- 9.3.5 回归（`r935`，n78，`work/a6/regress/disk-935.img`）：153 秒锁屏，没有 panic；熄屏 3 次、点亮 2 次，和旧版 QEMU（`c935-old`）及前两轮（`f935`、`g935`）完全一样（88 秒那张是在熄屏和按 Home 唤醒之间截到的黑屏，`c935-old` 也有一次）。【已核实】
- 结束时没有 QEMU 进程，没有挂着的镜像，临时工作树和克隆盘已删。

## 16. 稳定开机、熄屏唤醒、壁纸（第五轮）

决策会话核对第 15 节后，用户说「继续修」。目标：每次开机都稳定进主屏，熄屏后按 Home 能叫醒，壁纸能显示。顺序：先修 mediaserverd，再查叫不醒（含 lm3534 背光），再查壁纸。每项修完用全新克隆盘开 3 次以上，统计黑屏次数。

### 16.1 缓存里的 gl* 调用绕开了前端（定性）

- **怎么绕开的**：HDR 调 `glGetIntegerv` 的地方是 `blx 0x30f7a5a8`，那是 HDR 自己的存根，只有两条指令：`ldr r12, [字面量]`、`add pc, pc, r12`，是按 pc 相对的固定跳转，直接落到缓存里苹果 OpenGLES 的 `glGetIntegerv`（0x1d0a33e8）。它不读懒绑定指针：做缓存时 `update_dyld_shared_cache` 把存根优化成了直接跳转，dyld 再怎么改绑都管不到。【已核实：REA 反汇编 `work/a6/dis/HDR-14G61.elf` 0x30f78744、0x30f7a5a8】
- **苹果原版 gl* 做什么**：原版 `glGetIntegerv` 是 `mrc p15, 0, r0, c13, c0, 3; bic r0, #3; ldr r3, [r0, #0x78]; cbz r3, 返回; ldr r0, [r3, #0x10]; ldr.w r3, [r3, #0x1b4]; bx r3`：从线程 TLS 的第 30 槽（`__PTK_FRAMEWORK_OPENGL_KEY`）取上下文，空就什么都不做；不空就取 +0x10 的 GC、+0x1b4 的函数指针跳过去。扫了原版缓存里全部 457 个 gl* 入口，个个都从 TLS 偏移 0x78 取上下文，低于 +0x14 的只读 +0x10（GC）。我们的前端接管了 EAGL，用的是自己的 pthread 键，**从来没往第 30 槽里放东西**，所以缓存里的镜像直接调 gl* 永远是空操作。这就是 HDR 的 `this[4]` 没被写的原因（15.3）。【已核实：原版缓存字节，llvm-mc 反汇编；扫描脚本在会话临时目录】
- **影响面**：缓存里绑定 OpenGLES `gl*` 导出的镜像有 30 个，按绑定个数：WebCore 147、SceneKit 108、VectorKit（地图）100、Jet 94、GLKit 70、DrawingKit 59、GyroVideoStabilization 57、NanoUniverse 57、HealthKitUI 50、MediaToolbox 47、HDR.videoprocessor 45、DigitalTouchShared 45、Celestial 42……还有 UIKit 13、ProceduralWallpapers 14、CoreImage 2。QuartzCore 和 CoreImage 的主路径走前端给的分派表（`GetMacroContextPrivate`），所以锁屏、主屏能画出来。【已核实：`cacheinfo.py binds`】

### 16.2 第一种修法：在缓存里放跳板（已撤回）

- **做法**：在缓存里苹果 OpenGLES 每个 gl* 导出的开头写一段 18 字节的 Thumb-2 跳板（`movw/movt r12`、`add r12, pc`、`ldr.w r12, [r12]`、`ldr.w pc, [r12, #4×i]`），经苹果 OpenGLES 第一个 `__bss` 里的一个字跳进前端的同序函数表；前端加载时用 `shared_region_check_np` 找到这个字填上表地址。457 个入口、改 5 页、重算页哈希，CDHash 变 `dee36e7f…`。【已核实：代码，llvm-mc 反汇编跳板】
- **结果**：第一次可写开机（t23）在锁屏前 panic：`IOP: timed out waiting for workloop to process completed command`，之前五次 `granting grace period 1` 到 `5`，和第二轮的 n6、n11 一样（日志里「panic」34 次是展开的 panic 日志，超时本身每次一条）。随后三台并行（ta1 到 ta3）、单开完整拷贝 NAND（tb1）、快照单开（tc1、tc5）全部同样 panic；缓存还原成原版、只留前端（tc4）就没有。【已核实：各次 `serial.log`】
- **按决策会话要求核对的并行和宿主因素**：按运行目录的建立时间和 `serial.log` 最后修改时间，n6、n11、t23 运行时都没有别的 QEMU 在跑（t23 时宿主上 Ghidra 在分析背光 kext）。A5/A6 的 IOP 模型（`hw/arm/s5l8940_iop.c`）完全同步：AP 敲门铃时，模型在 vCPU 线程上一口气处理完环里的命令（NAND 读写是对宿主文件的同步 `pread`/`pwrite`），然后置 AP 的软件中断，**不靠宿主定时器或线程**。所以并行、克隆盘都不是原因，单开和快照照样出。【已核实：时间戳、代码、tb1/tc1】
- **谁占着 CPU**：tc5 每 0.25 秒从 QMP 取一次寄存器（不停客机），488 次采样 468 次在内核态，PC 多在 `_clock_delay_until` 的忙等里（QEMU 把 `wfe` 当空操作）。tc6 顺帧指针取调用链，45 次都是 `delay_for_interval` ← `AppleH5PCLCD` ← `IOMobileGraphicsFamily` ← 系统调用。反编译 `AppleH5PCLCD` 0x81317fac：`while (寄存器块 && (*(块 + 0x2c) & 0x40)) IODelay(10);`，**没有超时**，等清零后写 gamma 表、再置 0x40 开始装载。+0x2c 是我们显示模型的 `CLCD_GAMMA_CTRL`，模型只存值、从不清 0x40，**第二次装 gamma 表就永远转下去**；调用它的线程优先级高，IOP 工作循环排不上，成了 IOP 超时。【已核实：`tc5/samples.txt`、`tc6/samples.txt`、反编译 `work/a6/dis/h5p-14G61.elf`】
- **为什么会第二次装 gamma，以及修了 gamma 之后界面还是起不来（tc7、tc9）**：当时判断成「跳板一次放开 30 个框架，引出的新路径太多」，改成按进程放行（只给 mediaserverd 真表，其余进程每项返回 0），td1 照样黑屏。**这个判断不对。** td1 的数据卷上 backboardd 崩了 20 次，每次同一处：QuartzCore 0x1dbe874c（CoreAnimation 的 GL 能力探测）里 `strncmp("Apple", glGetString(GL_RENDERER), 5)`，取到空指针。这个 `glGetString` 走的是前端的分派表，不是缓存存根。原因：前端在 6.x 以后是**读苹果原版每个 gl* 开头的指令来认分派表的槽位**（`gles_dispatch.c` 的 `gles_trampoline_slot`），跳板把这 18 字节盖掉了，认出的槽从 329 个掉到 126 个，`GetString` 那格成了返回 0 的占位。backboardd 一起来就崩、launchd 再拉、再崩。【已核实：`td1/crash/` 20 份报告同一栈；`qemu.out` 里 `dispatch layout … 329 named`（t21、tc4）对 `126 named`（tc5、tc7、td1）】
- 【推测】第二次装 gamma 就是重启的 backboardd 初始化显示时装的；没修 gamma 时卡成 IOP 超时，修了之后 backboardd 一直在崩溃重启，界面当然起不来。跳板和按进程放行都已撤回（前端、`build.sh`、`n78_devcache.py --gl-thunks`、`n78_diskfix.sh` 的 `GL_THUNKS` 都删了），disk-n3 上的缓存还原成原版再标开发版，CDHash 回到 `b2485177…`。

### 16.3 留下的两处 QEMU 修复：gamma 忙位、lm3534

- **gamma 忙位**（`hw/arm/s5l8930_display.c` 加属性 `gamma-busy`，`ipod_touch_5g.c` 只给 n41 设 0x40）：写 CLCD +0x2c 时把这些位当作装载立刻完成、读回为 0。真机上 backboardd 崩溃重启也会再装一次 gamma，模型必须把装载做完，所以跳板撤了也留着。A4、A5 的驱动不看这一位，属性默认 0，行为不变。【已核实：代码；9.3.5 回归见 16.8】
- **lm3534 背光**（i2c0 地址 0x63）：`AppleLMBacklight::start` 从 0x10 起读寄存器，没人应答就打 `could not communicate with controller - tearing down driver`。它只要读得到应答，之后写回几项设置，所以借 D1881 PMU 的寄存器文件（不带 ADC）当最小应答模型，挂在 i2c0 的 0x63。之后每次开机都没有这一行（te1、tw1、tf1 到 tf3）；屏幕亮度仍由显示模型负责。它对叫醒有没有单独的作用没有分开测（叫醒是 16.4 之后才好的）。【已核实：各次 `serial.log`】

### 16.4 修法：前端把苹果 gl* 读的 TLS 槽也填上

- **思路**：不动缓存。苹果原版 gl* 从 TLS 第 30 槽取的那个结构，正好是 CoreAnimation 用的「宏上下文」整体往前挪 0x10 字节：宏上下文第 0 个字是 GC、第 1+k 个字是第 k 个函数，原版要的是 +0x10 的 GC、+0x14+4k 的函数（`glGetIntegerv` 的 +0x1b4 = 宏上下文的第 0x69+1 个字，和 CoreAnimation 调 `GetIntegerv` 用的槽一致）。所以 `+[EAGLContext setCurrentContext:]` 设当前上下文时，把这个上下文的宏上下文减 0x10 写进第 30 槽，换成别的上下文或置空时清掉。这和原版 `setCurrentContext:` 把自己的上下文放进这个槽是同一回事：有当前上下文时，缓存里所有直接调用都带着该有的 GC 进前端；没有当前上下文时照样什么都不做，和真机一样。
- **代码**（`contrib/gles-public/opengles.c`）：`fe_stock_current` 用 `mrc p15, 0, r, c13, c0, 3` 取线程指针写第 30 槽；宏上下文前面多分配 4 个字（`FE_STOCK_PAD`），往前 0x10 字节仍在自己的内存里；释放时减回去。只在 Darwin 16（iOS 10）起、而且认槽时看到原版把 GC 放在 +0x10（`gles_dispatch.c` 新记的 `gles_trampoline_gc`）时才写，更早的固件行为不变。`GetMacroContextPrivate` 的「CoreAnimation 走宿主」那行日志从 `fe_macro` 挪到方法里，因为现在设当前上下文时也会建宏上下文。【已核实：代码；扫描见 16.1】
- **结果**（te1，全新克隆盘单开）：100 秒锁屏，128 秒按 Home 进主屏，150 秒点开「设置」，175 秒按电源键熄屏（`_lcdEnable: enable: 0`），200 秒按 Home **亮回锁屏**（`_lcdEnable: enable: 1`）。分派表认出 329 槽；mediaserverd 只握手一次、**数据卷上没有 mediaserverd 的崩溃报告**（之前 t9 崩 10 次、t10 崩 13 次、t21 崩 5 次）；只有 7 份 backboardd 看门狗的全进程栈（t21 也有 7 份，界面不受影响）。【已核实：`te1` 的截图、`serial.log`、`crash/`】

### 16.5 熄屏后叫醒

- 16.4 之后每次都能叫醒（te1、tw1、tf1 到 tf3，见 16.7）。之前一次都没叫醒过（t8、t10、t17、t19、t20）。t10 那次 SpringBoard 主线程在等不停重启的 mediaserverd；t17 那次 mediaserverd 没崩、SpringBoard 也闲着，照样叫不醒。所以叫醒靠的不只是 mediaserverd 不崩。【推测】点亮锁屏的那条路上有缓存里的镜像直接调 gl*（UIKit 13 个、CoreImage 2 个绑定），以前全是空操作，比如等一个永远不来的结果；具体是哪一处没有查，决策会话要的 HID 追踪也因此没做。lm3534 是同一批加进来的，没有分开测。【已核实：各次截图和 `_lcdEnable` 日志；原因是推测】

### 16.6 壁纸：JPEG 嫌疑排除，合成器那块 surface 在第一次绑定前就是不透明黑（未解决）

- **写监视**（临时诊断，已删）：合成器或渲染进程每次绑定 744×1392 及以上的 surface 时，把它的物理页登记下来，之后记下每页每类写入方的第一次写：CPU 的写（TCG 的 `notdirty_write`，布防时清掉这些页的 CODE 脏位逼写走慢路径）、设备模型经 `address_space_write` 的写（`invalidate_and_set_dirty`）、GL 宿主写回 surface（`gles-host.c` 里经 `qemu_map_ram_ptr` 的 `memcpy`）、GL 宿主替客机写内存（`guest-gles.c` 的 `guest_rw_ram`，`glReadPixels` 这类）。按决策会话的提醒 grep 了经宿主指针直接写客机内存的地方：A5/A6 用到的模型里只有 GL 宿主这两处，`ipod_touch_5g.c` 的那处是开机时填 boot ROM，显示模型只读，其余是别的机型（ipad1、s5l8920、ipod_touch_2g）。【已核实：grep `address_space_map|dma_memory_map|memory_region_get_ram_ptr|qemu_map_ram_ptr|cpu_physical_memory_map`】
- **结果**（tw1）：整次开机只布防了三块 744×1392。两块是渲染进程（CONTEXTIDR 0x40，客体地址 0x02e66000、0x02a67000，和 14.2 那个处理壁纸的进程同一地址）的：布防时不是黑的，之后是它自己的 GL 写回，再往后是内核（CONTEXTIDR 0、svc 态）和设备模型的写，也就是 surface 释放后页被重用。第三块是合成器的（CONTEXTIDR 0x16，客体地址 0x02af3000）：**第一次绑定时 2048 个采样里 2024 个已经是不透明黑（0xff000000）**，之后整次运行**任何一方都没再写过它**（CPU、内核、设备、GL 宿主都没有）。所以不是「内容本该由硬件产生」：这块内存在合成器第一次用它之前，已经被某个写入方填成了不透明黑（不是清零，清零是 0x00000000），写监视在绑定时才布防，没抓到这个写入方。【已核实：`tw1/qemu.out` 的 `[watch]` 行】
- **JPEG 块被隐藏的嫌疑：排除。** iPhone 5 的默认壁纸确实是 JPEG：`/Library/Wallpaper/iPhone/default-568h@2x.jpg` 链到 `050.WWDC2016@2x~iphone.jpg`，744×1392，正好是合成器那块 surface 的尺寸；而 iPod touch 5 的默认壁纸在 `DefaultWallpapers.plist` 里是 PNG（这个表只有 `iPod5,1`、`iPod7,1`），9.3.5 在 n78 上根本不走 JPEG。但数据卷上 SpringBoard 第一次开机时存下的 `mobile/Library/SpringBoard/LockBackground.cpbitmap`（4187271 字节，744×1392，每行 3008 字节）转成图片看，是正确的 iOS 10 默认海浪壁纸，所以 JPEG 在第一次开机时解码成功了（软件解码），之后的开机直接读这份原始像素，和 JPEG 无关。缓存里引用 `AppleJPEGDriver` 的是 libMobileGestalt、MediaToolbox 和 JPEGH1 视频编解码插件，ImageIO 不直接开它。【已核实：系统卷文件、`sips`、cpbitmap 转图、缓存字符串】
- 所以壁纸的像素在盘上是好的，从 `LockBackground.cpbitmap` 到合成器那块 surface 之间，内容变成了不透明黑。下一步建议：在 surface 第一次被任何进程绑定之前就抓写入方，比如按「整页写入 0xff000000」或按 IOSurface 的创建（内核 `IOSurfaceRoot` 的用户客户端调用）布防，再看是 SpringBoard 里哪一步（CoreAnimation 提交图像、或 CoreImage 处理壁纸后读回）填的黑。缩放器（`IOSurfaceAccelerator`）仍被隐藏，这一步如果本该由它把 cpbitmap 的像素搬进新 surface，填黑后不搬就正是这个现象；15.5 用「9.3.5 绑定同样两个函数、壁纸正常」排除过它，但 9.3.5 在 n78 上壁纸是 PNG、路径不一定相同，需要重新核对。【推测】

### 16.7 统计：全新克隆盘单开，几次里几次

每次都是 disk-n3 的全新可写克隆（NAND 目录完整拷贝），一次只开一台，宿主上没有别的 QEMU；操作一样：100 秒截图，120 秒按 Home，140 秒点「设置」，160 秒按 Home，175 秒按电源键，200 秒按 Home，207 秒截图。

| 运行 | QEMU | 锁屏 | 主屏 | 「设置」 | 熄屏 | 按 Home 叫醒 | panic | 数据卷上新增的崩溃报告 |
|---|---|---|---|---|---|---|---|---|
| te1 | 带写监视诊断 | 是 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 7 |
| tw1 | 带写监视诊断 | 是 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 9 |
| tf1 | 最终版（诊断已删） | 是 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 8 |
| tf2 | 最终版 | 是 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 8 |
| tf3 | 最终版 | 是 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 9 |

- **黑屏：最终版 3 次里 0 次，连同诊断版共 5 次里 0 次**（第四轮到 t3 为止 15 次里 5 次，15.3）。**叫醒：5 次里 5 次**（之前 0 次）。mediaserverd 5 次里 0 次崩溃（之前每次开机崩 5 到 13 次）。并行开机这一轮没有再做（决策会话要求单开和并行分开记，这里全是单开）。【已核实：各次截图 OCR、`serial.log` 的 `_lcdEnable`、数据卷 `CrashReporter` 的新文件】
- 叫醒后的锁屏截图存为 `docs/reports/img/a6-1034-wake.png`（tf1，207 秒）。
- backboardd 看门狗的全进程栈（bug_type 288）每次 7 到 9 份，第四轮正常开机时也有（t21 7 份），界面不受影响，没细查。
- TLS 方案之后，宿主日志里多了几类以前没有的拒绝：某个进程用了 VAO（`glGenVertexArraysOES`、`glBindVertexArrayOES` 前端没实现，回 0），一个用 `GL_EXT_separate_shader_objects` 的着色器在宿主（macOS 的 GL 2.1）上编译失败、程序链接失败，另有 `GL_INVALID_ENUM/VALUE`、帧缓冲不完整。这些是缓存里的直接调用现在真的进了前端才暴露的，界面看不出影响，是哪个进程、画的是什么没查。【已核实：`te1/qemu.out`】

### 16.8 回归 n78 的 9.3.5

- 新前端装进回归盘（`n78_diskfix.sh work/a6/regress/disk-935.img`，13G36 分支；前端的 TLS 写入在 Darwin 15 上不生效，但宏上下文多留的 4 个字和 `getMacroContextPrivate` 的改动会走到），最终版 QEMU 快照模式开机（`r935f`）：88 秒、153 秒都是锁屏，190 秒按时熄屏；熄屏 3 次、点亮 2 次，没有 panic，和上一轮的 `r935` 一样。分派表照旧认出 329 槽。【已核实：`r935f` 截图 OCR、`serial.log`】
- 这一轮对 n78 生效的 QEMU 改动只有前端；gamma 忙位、lm3534、电量计都只给 n41 设，属性默认关。

### 16.9 补丁、工具、文档

- `patches/a5-n78-skeleton.patch` 重新导出（18 个文件，比上一轮多 `contrib/it-gles/gles_dispatch.c`）。这一轮的 QEMU 侧：`contrib/gles-public/opengles.c`（TLS 第 30 槽、宏上下文前留 4 个字）、`contrib/it-gles/gles_dispatch.c`（记下认槽时 GC 的偏移）、`hw/arm/s5l8930_display.c`（`gamma-busy`）、`hw/arm/ipod_touch_5g.c`（n41 的 lm3534 应答和 `gamma-busy`）。在上游原样的临时工作树里核对：按 `build-qemu.sh` 的顺序打四个 iOS 补丁、skeleton、`a5-n78-ios-ui.patch` 全部打得上；只打 skeleton 得到的 18 个文件和 Mac 工作树逐字节相同。临时工作树已删。【已核实】
- 跳板相关的全部撤掉：前端的 `fe_cache_thunks` 和表、`build.sh` 生成的 `gles_cache_gl.h`、`n78_devcache.py --gl-thunks`、`n78_diskfix.sh` 的 `GL_THUNKS`/`GLES_EXPORTS`。所有临时诊断（写监视、慢调用计时）都已删掉，最终版 QEMU 里没有。
- `tools/a5/README.md` 的 A6 部分补了 lm3534、`gamma-busy`、TLS 槽，改了第 6 步的说明。统计和采样用的脚本（`batch.sh`、`qsample.py`）、扫原版 gl* 的脚本在会话临时目录，没进仓库。
- 这一轮新做的反编译输入在 `work/a6/dis/`（`h5p-14G61.elf`、`lmbl-14G61.elf`、`ImageIO-14G61.elf`），运行目录 `work/a6/runs/` 的 t23、ta1 到 ta3、tb1、tc1 到 tc9、td1、te1、tw1、tf1 到 tf3、r935f；td1 的 20 份 backboardd 崩溃报告在 `td1/crash/`。

### 16.10 收尾

- 结束时没有 QEMU 进程、没有挂着的镜像，克隆盘和 NAND 拷贝已删，REA 会话已关。

## 17. 壁纸（第六轮）

决策会话核对第 16 节后，用户说「接着修壁纸」。目标：锁屏和主屏显示默认海浪壁纸，全新克隆盘单开至少 3 次都显示；叫醒、「设置」、9.3.5 回归不退步。**结果：修好了，全新克隆盘单开 3 次里 3 次有壁纸**（锁屏、主屏、叫醒后都有），同一块盘第二次开机也有；叫醒、「设置」照旧。**这一轮没有改 QEMU 和 GL 前端**，改的是盘：盘上留着一份以前生成的全黑壁纸缓存。

### 17.1 根因：盘上的壁纸缓存是全黑的

- iOS 10 的 SpringBoard 把壁纸处理后的图存进 BaseBoardUI 的映射图像缓存，目录 `mobile/Library/Caches/MappedImageCache/Wallpaper/`：一张整幅的 `shared-wallpaperController-(-2:0:0:0.0:0:0.0:0.0)-untinted.cpbitmap`（744×1392，每行 3008 字节，4187210 字节），三张 186×348 的加色模糊图（`…-tinted.cpbitmap`），一张 24×44 的采样图。**disk-n3 上那张整幅图的 1035648 个像素全是 0xff000000**（其余 11136 个字是每行末尾的填充 0），三张加色图是均匀的灰（0xff4d4d4d、0xff737373、0xff4d4d4d，也就是黑色加了色调），只有采样图是海浪的青绿色。【已核实：逐字统计 g3 克隆盘上的文件】
- **合成器那块 surface 就是这张缓存**：开机时 SpringBoard 用 AppSupport 的 `CPBitmapCreateMappedDataFromPath` 把它 `mmap` 进来（g3：大小 0x3fe44a，正是这个文件的长度），交给 CoreAnimation；backboardd 的渲染服务收到图像内存后用 `IOSurfaceWrapClientImage` 把它包成 IOSurface 当纹理（744×1392、BGRA、每行 0xbc0 字节；QuartzCore 0x1dbb2884，`CA::Render` 图像取 IOSurface 的那个方法）。16.6 看到的「第一次绑定前已经是不透明黑、之后谁都没写」就是这样来的：像素是从文件里映射进来的，本来就没有谁再画它。16.6 把它和 `LockBackground.cpbitmap` 连起来，是因为两个文件每行都是 3008 字节，那个推断不对。【已核实：g2、g3 的断点记录，反编译 `work/a6/dis/QuartzCore-14G61.elf`】
- 缓存一旦存在，SpringBoard 就直接读它，不再重画；从 disk-n3 克隆出来的每一块盘都带着这份黑图。

### 17.2 怎么查的：在共享缓存里下断点

- 用 QEMU 自带的 gdbstub（`-gdb tcp:127.0.0.1:1234`）加一个 Python 写的 GDB 远程协议小客户端：在缓存函数入口下断点，记 CONTEXTIDR（区分进程）、参数、返回值、按帧指针取的调用链，必要时下写监视点；每次命中读完就继续，客机照常开机。
- **iOS 10 的共享缓存开机时会随机滑动**：第一次（g1）按文件里的地址下断点，一次都没命中。之后客户端先在用户态打断，读 PC 处 48 字节代码，到缓存文件里找同样字节、同页内偏移的位置，算出滑动量（g2、g3、g4 分别是 0x129c000、0x1330000、0xd24000），再下断点。
- 这些脚本只在会话临时目录，没进仓库；运行目录 `work/a6/runs/g1` 到 `g5` 里有 `trace.txt`。

| 运行 | 盘 | 看什么 | 结论 |
|---|---|---|---|
| g1 | disk-n3 克隆 | 缩放器、VideoToolbox、SBF 的缩图 | 没算滑动量，一次没命中 |
| g2 | 同上 | 同上，加滑动量 | SBF 缩图时缩放器建不起来、VideoToolbox 退回软件（17.3）；backboardd 包 744×1392 |
| g3 | 同上 | 4 MB 左右的 `mmap`/`vm_allocate` 及其写入 | SpringBoard 映射了 `…-untinted.cpbitmap`（17.1） |
| g4 | 克隆盘删掉 `Wallpaper/` 下的缓存 | 同 g2 | **锁屏有壁纸**；SpringBoard 重新生成了缓存 |
| g5 | 同 g4 | `CPBitmapWriter*`、`CARenderServerRender*`/`Capture*` 的调用链 | 缓存由 BaseBoardUI 在 dispatch 队列里写；生成时没用渲染服务截图 |

### 17.3 被隐藏的缩放器：在这条路上，但壁纸不靠它

- 决策会话要求重新核对缩放器（15.5 拿 9.3.5 排除它，而 n78 的壁纸是 PNG，路径不一定一样）。查下来缩放器**确实在 iOS 10 的壁纸路径上**：SpringBoardFoundation 有个裁剪缩小壁纸的方法（0x24e401b0，把 744×1392 里 (26, 64, 320, 568) 点的一块缩成 206×366 像素），先用 `SBFCreateIOSurfaceForImage` 把 `LockBackground.cpbitmap` 的映射包成 IOSurface，再用 `VTPixelTransferSessionTransferImage` 搬到 `FigCreateIOSurfaceBackedCVPixelBufferWithAttributes` 建的新 surface 里。每次开机这一步里 `IOSurfaceAcceleratorCreate` 都返回 0xe00002c0（kIOReturnNoDevice，缩放器被开机包藏了），VideoToolbox 返回 -12905（kVTPixelTransferNotSupportedErr），SBF 随即走 CPU 的裁剪绘制，返回一张图。【已核实：g2、g4 的断点记录，反编译 `work/a6/dis/SBF-14G61.elf`】
- 所以缺缩放器的情况 SBF 自己处理了；缩放器一直藏着，wf1 到 wf3 照样有壁纸。AppleJPEG 也绑定了缩放器函数，但默认壁纸的 JPEG 只在第一次设置壁纸时解码一次（之后读 `LockBackground.cpbitmap`），这一轮的开机里没走到。【已核实：`cacheinfo.py binds`；AppleJPEG 那句是推测】

### 17.4 当初为什么是黑的

- 删掉缓存后（g4、g5、wf1 到 wf3）SpringBoard 会重新生成：宿主日志里 SpringBoard 先上传一张 744×1392 的 RGBA 纹理（均值 147，不是黑的），画一次（混合 1、0x303），再用 `glReadPixels`（分派槽 237）读回到一页在它页表里只读的内存，也就是 15.5 修过的那条读回路径（日志 `stays read-only to stores (slot 237): written past its protection`）。缓存在的时候（tf1、wf3b1）没有这张纹理的上传。g5 的调用链显示缓存文件由 BaseBoardUI 在 dispatch 队列里用 `CPBitmapWriterAddImage` 写下，整个过程没调用 `CARenderServerRender*`、`CARenderServerCapture*`。所以整幅壁纸是 **GL 画出来再读回的**。【已核实：g4、g5、wf1 到 wf3 的 `qemu.out`，g5 的 `trace.txt`】
- disk-n3 是第一轮 n3 那次数据迁移开机直接写出来的盘，之后 n4、n5 也直接在它上面开过；那时这次读回会被丢掉（15.5 是第四轮才修的），缓存里镜像直接调的 gl* 也全是空操作（16.4 是第五轮修的）。生成出来的图没被写进像素，就成了不透明黑，存进了缓存。之后几轮要么是快照模式、要么是克隆盘，缓存一直在，SpringBoard 再没重画过，所以 15.5 和 16.4 修好之后壁纸看起来照样是黑的。【推测：缓存文件的时间戳都是 1970 年，看不出是哪次开机写的；也没有用旧版前端重现；为什么是 0xff000000 而不是全零也没查】

### 17.5 修法

- `tools/a5/n78_diskfix.sh` 的 14G61 分支在数据卷上删掉 `mobile/Library/Caches/MappedImageCache/Wallpaper/` 下的文件（目录留着），SpringBoard 下次开机重画。这份缓存是 GL 画的，换过前端或修过 GL 之后旧缓存就可能不对，改盘时清掉最省事。13G36 的盘上没有这个目录（9.3.5 的回归盘查过），所以只对 14G61 做。【已核实：脚本；回归盘】
- disk-n3 上只做了这一步删除（没有整个重跑 `n78_diskfix.sh`），盘的信任缓存文件不受影响。从它克隆的每块盘第一次开机都会重新生成缓存，锁屏的时间没有明显变化（wf1 到 wf3 都在 110 秒截图时已是锁屏）。用现在的 QEMU 和前端从头做的盘，第一次开机生成的就是对的，这一步只对用旧前端开过的盘有用。
- QEMU、GL 前端都没改，`patches/a5-n78-skeleton.patch` 重导出来和上一轮逐字节相同。

### 17.6 TLS 方案之后新出现的拒绝：和壁纸无关

- 16.7 记下的几类拒绝（`glGenVertexArraysOES`、`glBindVertexArrayOES` 没实现；一个带 `GL_EXT_separate_shader_objects` 的着色器在宿主上编译失败、程序链接失败；槽 632 的 `GL_INVALID_ENUM/VALUE`；帧缓冲不完整）在 tf1（黑壁纸）和 g4（有壁纸）里一条不差，所以不是壁纸的原因。它们出现在 SpringBoard 载入前端之后，是哪个进程、画的是什么，这一轮没有查。【已核实：两次的 `qemu.out`；进程没查】

### 17.7 统计：全新克隆盘单开，几次里几次

每次都是 disk-n3（已删缓存）的全新可写克隆（NAND 目录完整拷贝），一次只开一台，宿主上没有别的 QEMU。操作：110 秒截图，130 秒按 Home，138 秒截图，150 秒点「设置」，160 秒截图，170 秒按 Home，178 秒截图，185 秒按电源键，192 秒截图，210 秒按 Home，217 秒截图（比第五轮晚 10 秒左右，留出重新生成缓存的时间）。壁纸用截图第 380 到 1000 行（日期以下、「Press home」以上）里有一个通道亮于 24 的像素占比来判断：tf1 的黑壁纸锁屏是 0.000，主屏只有图标是 0.491，有壁纸是 1.000。

| 运行 | 盘 | 锁屏 | 壁纸（锁屏/主屏/叫醒后） | 主屏 | 「设置」 | 熄屏 | 叫醒 | panic | 新增崩溃报告 |
|---|---|---|---|---|---|---|---|---|---|
| wf1 | 全新克隆 | 是 | 1.000 / 1.000 / 1.000 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 5 |
| wf2 | 全新克隆 | 是 | 1.000 / 1.000 / 1.000 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 5 |
| wf3 | 全新克隆 | 是 | 1.000 / 1.000 / 1.000 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 6 |
| wf3b1 | wf3 那块盘第二次开机 | 是 | 1.000 / 1.000 / 1.000 | 是 | 是 | 是 | 是 | 无 | backboardd 看门狗栈 5 |

- **壁纸：全新克隆盘 3 次里 3 次有**，同一块盘第二次开机直接读重新生成的缓存，也有。四次存下的整幅缓存逐项相同：约 23.9 万种颜色，0 个不透明黑像素。【已核实：截图、`wpcheck` 数值、各次拷出的 `untinted.cpbitmap`】
- 叫醒、「设置」：4 次里 4 次，和第五轮一样。mediaserverd 没有崩溃报告。backboardd 看门狗的全进程栈（bug_type 288）每次 5 到 6 份，第五轮是 7 到 9 份，界面不受影响。
- 截图：`docs/reports/img/a6-1034-wallpaper-lock.png`（wf1，110 秒锁屏）、`a6-1034-wallpaper-home.png`（wf1，138 秒主屏）。主屏的 Dock 模糊底色也对了（那是加色缓存图）。

### 17.8 回归 n78 的 9.3.5

- 和上一轮同样的盘和参数（`work/a6/regress/disk-935.img` 快照模式，`qemu-final`，这一轮二进制没变）开了一次（`r935g`）：88 秒、153 秒都是锁屏，壁纸检测都是 1.000（和 r935f 一样），190 秒已按时熄屏；没有 panic，分派表照旧认出 329 槽。`_lcdEnable` 熄屏 2 次、点亮 1 次，r935f 是 3 次、2 次，多的是开机早期一次自动熄屏再点亮，截图那几个时间点的状态一样。【已核实：截图 OCR、`wpcheck`、`serial.log`】
- 改盘脚本这一轮的改动只在 14G61 分支，9.3.5 的盘上也没有这个缓存目录，回归盘没有重跑 `n78_diskfix.sh`。

### 17.9 补丁、工具、文档

- QEMU、GL 前端都没改。`patches/a5-n78-skeleton.patch` 用 `git diff --cached` 重导，和上一轮逐字节相同；在临时目录里按 `build-qemu.sh` 的顺序打四个 iOS 补丁、skeleton、`a5-n78-ios-ui.patch` 全部打得上，只打 skeleton 得到的 18 个文件和 Mac 工作树逐字节相同。【已核实】
- `tools/a5/n78_diskfix.sh`：14G61 分支删掉壁纸缓存，文件头的说明补了一句。`tools/a5/README.md`、`README.md`、`docs/plan.md` 相应更新。
- 这一轮没有往 QEMU 里加诊断代码，用的是 QEMU 自带的 gdbstub。会话临时目录里的脚本没进仓库：GDB 远程协议的断点记录器（自己算共享缓存滑动量，记参数、返回值、调用链，能下写监视点）、存根到导出名的映射、壁纸检测、单次和批量开机脚本。
- 新做的反编译输入：`work/a6/dis/SBF-14G61.elf`（SpringBoardFoundation）、`VT-14G61.elf`（VideoToolbox）。运行目录 `work/a6/runs/` 的 g1 到 g5（断点追踪）、wf1 到 wf3、wf3b1（统计）、r935g（回归）；各次统计拷出的整幅缓存在 `wf*/untinted.cpbitmap`。

### 17.10 收尾

- 结束时没有 QEMU 进程、没有挂着的镜像，克隆盘和 NAND 拷贝已删，REA 会话已关。disk-n3 上删掉了旧的壁纸缓存（目录留着，空的），其余不变。
