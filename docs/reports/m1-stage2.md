# M1 第二阶段：JIT 改走通用协议

- 日期：2026-11-01
- 执行会话：M1 执行会话（接第一阶段）。范围是决策会话派的第二阶段：新 JIT 协议补丁、调试器支持、模拟器回归、真机 256 MB 重测、iPod touch 2 代长待机。中途决策会话三次收窄：取消长待机测试；真机每台只测一轮 256 MB；不做 512 MB 和「不开镜像」的对照。
- 没做的：没碰 iPhone 14 Pro，没装 StikDebug，没拷 6 到 7 GB 的设备符号，没 commit。

## 0. 结论

1. **新协议能用，但没达到「256 MB 几秒准备好」的目标。** 补丁 `patches/ios-txm-jit-protocol.patch` 让 QEMU 发 `brk #0xf00d`（StikDebug universal.js 的约定）。Mac 上的调试器用 debugserver 的 `_M` 分配可执行内存，**256 MB 只要 0.02 秒**；QEMU 映射好后发「脱离」，之后 App 不再带着调试器跑。iPhone 18 Pro 上 32 MB 端到端成功 4 次，都开到了主屏。
2. **分配之后仍要调试器把每一页写一遍，这一步受连接速度限制。** 实测只分配不写的话，生成的代码执行不了：App 单核满载、画面不动。Wi-Fi 下有两种写法：整块写约 2.0 到 2.2 MB/s，32 MB 用 15 到 17 秒；逐页写 1 字节（StikDebug 的做法）每页约 29 毫秒，32 MB 用 60 秒。照此推算，256 MB 整块写约 2 分钟、逐页写约 8 分钟。旧协议读出再写回 256 MB 是 322 秒。StikDebug 在手机本机上跑，往返几乎为零，逐页写才快。从 Mac 隔着网络调试，这一步快不起来。
3. **256 MB 的真机正式测量没完成，两台的 JIT 锁屏时间和待机 CPU 都没有新数。** 原因是我的调试器脚本（`lldb_jit_runner.py`）在 Xcode 27.2 的 LLDB 下不稳，后面三段的细节见第 4 节：
   - 先是两个测量脚本同时在跑、互相把 App 杀掉，造成连续挂载失败。现在加了单实例锁。
   - 把 QEMU 用到的信号设成「LLDB 内部处理」时，挂载有时卡死（Resume timed out）。
   - 改成「停下再逐个放行」以后挂载稳了，但又改不动寄存器：PC 跳不过 `brk`，同一个请求反复触发。

   按决策会话的约定，在这里停下。手机上的 App 已结束，没有残留进程。
4. 32 MB 下新旧协议的开机表现一致，区别只在准备耗时：
   - QEMU 亮屏：新协议 12.0 到 15.9 秒，旧协议 12.8 秒。
   - 扣掉停顿到锁屏：新协议约 16 到 18 秒，旧协议约 18 秒。
   - 主屏待机 CPU：新协议 23% 到 28%，旧协议 21%。
5. 模拟器回归和第一阶段一致，改动只影响真机 JIT。iPod touch 2 代长待机测试按指示取消，SecureROM 占位文件列为「已知风险，未测」（第 5 节）。

## 1. 补丁：`patches/ios-txm-jit-protocol.patch`

改 `tcg/region.c`，只在 iOS 真机、iOS 26 以上、JIT 构建、有调试器时生效：

- `jit26_prepare_region(0, size)`：`mov x16, #1; brk #0xf00d; ret`，x0 为 0 表示请调试器分配，x1 是长度，调试器把地址写回 x0。返回值不是页对齐、或低于 4 GiB 的 `__PAGEZERO`，就当调试器没处理，报错退出。
- 拿到 RX 地址后，用 `mach_vm_remap` 做一个别名再 `mprotect` 成 RW，作为 TCG 写代码的那一侧（split-wx）。
- `jit26_detach()`：`mov x16, #0; brk #0xf00d`，请调试器脱离。QEMU 只映射一次代码区，之后不再需要调试器。
- 环境变量 `QEMU_IOS_JIT_PROTOCOL=legacy` 保留旧的 `brk #0x69` 读写回，方便对照。App 的启动参数 `-jitprotocol legacy` 会设这个变量。
- 写法参考 vytska69/Ios-emul 的 0016 补丁，协议以 StikDebug 的 universal.js 为准（`_M<长度>,rx` 分配，`prepare_memory_region` 每 16 KiB 页写 1 字节，见 StikDebug 的 `JSDebugSupport.swift`）。
- 补丁开头写了原因和基于的上游提交（b225694505，叠在 `ios-host-gles-option.patch` 之后）。四份 dylib 都已重编，真机 JIT 版里能看到 3 处 `brk #0xf00d`。

这个补丁同时也是将来用 StikDebug 脱离电脑拿 JIT 的前提：universal.js 对 `brk #0x69` 只回一个错误码。

## 2. 调试器端：`scripts/ios/lldb_jit_runner.py`

- 认 `brk #0xf00d`：x16=1 时用 `SBProcess.AllocateMemory(size, 可读可执行)` 分配，再按 `JIT_TOUCH` 写：
  - `bulk`（默认）：整块写零。
  - `page`：逐页写 1 字节。
  - `none`：只分配不写。

  写完把地址写回 x0、PC 加 4。x16=0 时 detach 后退出。旧的 `brk #0x69` 照常支持。
- 绕开的 LLDB 问题（第一阶段已有）：
  - 不用命令行驱动的停止钩子，改用 SB API 同步模式；
  - 关闭并行加载模块；
  - `target.memory-module-load-level minimal`：本机没有手机 24B119 的符号缓存；
  - gdb-remote 包超时调到 60 秒。
- 第二阶段新加：
  - 写寄存器后读回核对，不对就用 `register write` 再写；
  - 同一个准备请求出现第三次就结束进程，不让手机一直冻着；
  - 连续 3 次 Resume timed out 就先让包日志落盘再退出；
  - 可选的 gdb-remote 包日志（`LLDB_PACKET_LOG`）。
- `device-boot.sh` 新增：
  - `TBSIZE`、`JITPROTO`、`JIT_TOUCH` 参数；
  - 挂载卡住自动重试（最多 3 次）；
  - 单实例锁；
  - 摘要里记录当时 iPhone 镜像 App 是否在运行、Mac 负载、调试器准备耗时。
- App 新增：
  - `-jitprotocol` 参数；
  - JIT 准备期间状态栏写明「画面会停住一会儿」，并先画出来再起 QEMU；
  - 等调试器之前先把 JIT 版的库加载好；
  - `-qemuargs` 改成直接读原始参数（UserDefaults 会把以「-」开头的值当成新的键）。

## 3. 测量结果

### 3.1 模拟器回归（新补丁不影响模拟器）

| 设备 | 后端 | QEMU 亮屏 | 锁屏 | 主屏 | 主屏待机 CPU | 最大占用 |
|---|---|---|---|---|---|---|
| iPod touch 2 代 3.1.3 | JIT 256 MB | 8.8 秒 | 11 秒 | 19 秒 | 20% | 703 MB |
| iPod touch 2 代 3.1.3 | 解释器 | 36.3 秒 | 54 秒 | 64 秒 | 77% | 399 MB |
| iPhone 3GS 6.1.6 | JIT 256 MB | 18.6 秒 | 19 秒 | 48 秒 | 12% | 799 MB |

和第一阶段（10 秒、54 秒、19 秒到锁屏）一致。待机段核对过，没有事件，帧编号没变。

### 3.2 iPhone 18 Pro，iPod touch 2 代 3.1.3，JIT，代码区 32 MB

| 运行 | 协议、写法 | 准备耗时 | QEMU 亮屏 | 锁屏（扣停顿） | 锁屏时 CPU 秒 | 主屏待机 CPU | 占用 | 可用内存 |
|---|---|---|---|---|---|---|---|---|
| 第一阶段 195249 | 旧协议，读出写回 | 46.4 秒 | 12.8 秒 | 约 18 秒 | 17.8 | 21% | 277 MB | 3099 MB |
| 203400 | 新协议，逐页写 | 分配 0.10 秒 + 写 60.1 秒 | 12.3 秒 | 17 秒 | 16.6 | 23% | 242 MB | 3134 MB |
| 203806 | 新协议，整块写 | 0.02 + 16.7 秒 | 12.0 秒 | 16 秒 | 15.8 | 25% | 247 MB | 3129 MB |
| 204358 | 新协议，整块写 | 0.03 + 16.8 秒 | 12.8 秒 | 18 秒 | 17.9 | 25% | 248 MB | 3128 MB |
| 204542 | 新协议，整块写 | 0.10 + 17.0 秒 | 15.9 秒 | 18 秒 | 17.4 | 28% | 250 MB | 3126 MB |

- 全部走 Wi-Fi，Mac 1 分钟负载 3.3 到 3.7。各轮待机段（主屏后到退出前约 20 秒）都用 `check-idle.py` 核对过：没有脚本以外的事件，帧编号变化 0 到 1（状态栏时钟），可以用。
- 「镜像」一栏只能记到 Mac 上的 iPhone 镜像 App 有没有在运行（这几轮都在），记不到镜像会话是不是正连着。
- 只分配不写（`JIT_TOUCH=none`，256 MB，203629）：分配 0.02 秒、随即脱离，但 App 之后单核 100% 空转、帧编号停在 1、占用只有 25 到 38 MB，没开机。说明 TXM 确实只认调试器写过的页。

截图：`docs/reports/img/m1s2-device-n72ap-3.1.3-jit32-universal-home.png`（203806 那轮 App 自己存的窗口快照，主屏，状态栏显示 JIT）。

### 3.3 256 MB 真机正式测量：没有完成

两台都没有拿到 256 MB 的新数。能给的只有推算：Wi-Fi 下整块写约 2.1 MB/s，256 MB 约 2 分钟；第一阶段同样在 Wi-Fi 下，旧协议读出写回用了 322 秒。插线（有线）的速度也没量到：用户插线那段时间，挂载正被下一节的问题卡住，一次也没成功。

### 3.4 顺带更正第一阶段的待机 CPU

第一阶段 `summarize-run.py` 把 QEMU 退出后那几秒也算进了待机段，所以待机 CPU 偏低。按「主屏后 3 秒到退出前」重算：

| 第一阶段运行 | 原来报的 | 重算 |
|---|---|---|
| 真机 iPod 解释器 | 50% | 61% |
| 真机 3GS 解释器 | 91% | 108%（超过一个核） |
| 真机 iPod JIT 32 MB | 18% | 21% |
| 真机 3GS JIT 32 MB | 79% | 作废：决策会话已核对，那段时间有人点了设置 |

脚本已改，第二阶段的数都按新口径算。

## 4. 卡在哪里：调试器端在 Xcode LLDB 下不稳

按时间顺序，每一段都有日志（`work/ios/runs/device/lldb-*.log`、`packets-*.log`）：

1. **20:25 到 20:46，旧的信号设置**（SIGUSR1/2 等「不停下、LLDB 内部处理并递给进程」）：成功 6 次（含 4 次正式的 32 MB），失败 4 次。失败都是挂上后先来两次「没原因的停止」，接着每次继续都 `Resume timed out`。
2. **20:40 到 21:10，误判阶段**：我先后以为是 Wi-Fi 延迟、手机锁屏、dyld 加载通知，各改了一轮，插上线也照样失败。最后发现 21:04 那次正式测量的脚本重试失败后一直没退出，后面的验证脚本和它同时在跑，两边都用 `--terminate-existing` 启动 App，互相把对方的 App 杀掉。20:41 以后的连续失败，至少有一部分是这个原因。已加单实例锁。
3. **包日志里的另一个问题**（21:05，`packets-fail.log`）：QEMU 线程收到 SIGUSR2 停下（sigaltstack 协程靠它切栈），LLDB 恢复时发的是不带信号的 `c`，而不是 `vCont;…;C1f`，信号被吞，QEMU 线程永远停在 `sigsuspend`。这一次采样时旧脚本可能也在跑，不能完全排除干扰。
4. **改成「停下、提示、逐个放行」以后**（21:13、21:58）：挂载稳了，0.5 秒挂上、2 秒后就停在 `brk #0xf00d`，整块写 32 MB 用 15 到 18 秒。但写回 x0 和 PC 都不生效，SBValue 和 `register write` 读回来都还是旧值，同一个 `brk` 反复触发，调试器每次都重新分配、重写 32 MB。第二次是我加的保护在第 3 次触发时结束了进程。同一段代码在第 1 步的设置下改寄存器是正常的，所以怀疑和「信号停下」的设置有关（线程还有待递的信号时 LLDB 不接受改寄存器？），没来得及验证。

另外确认了一条和代码无关的限制：**手机锁着时，Mac 上的 devicectl 启动 App 会被系统拒绝**（「Unable to launch org.classictouch.app because the device was not, or could not be, unlocked」）。用 iPhone 镜像时手机本体是锁的，所以真机测量期间不能开镜像，要用户解锁、直接看手机。`lockState` 里 passcodeRequired 为 false 时也被拒过，要以实际启动结果为准。

### 可选路线

1. **把信号处理和改寄存器分开（推荐，先在不占手机的情况下准备好）**：恢复第 1 步的信号设置（第 1 步时改寄存器是正常的），单实例锁已经排除了第 2 步那种互相打架。只在「没原因的停止」时不急着继续，等 LLDB 内部的恢复走完再发。之后在用户方便时，32 MB 验证一次，再跑两轮 256 MB。每轮在 Wi-Fi 下手机会停约 2 分钟。
2. **用 USB**：插线后整块写应该快很多，但这次没量到，前提还是第 1 条先修好。
3. **长远看，JIT 本来就不该靠 Mac 上的 LLDB**：发布形态是 StikDebug（或内嵌 StikJIT）在手机本机上应答 `brk #0xf00d`，本机往返几乎为零，逐页写也能流水线批量发，256 MB 也就几秒。补丁已经按这个协议写好，E3 装 StikDebug 时可以直接验证。StikDebug 要用户批准才装。

## 5. iPod touch 2 代 SecureROM 占位文件：长待机测试已取消，列为已知风险

在第二台模拟器（ClassicTouch Standby）里跑了约 11 分钟后，按决策会话的指示停掉，模拟器已关。观察到的：

- 锁屏后约 1 分钟背光变 0，CPU 2% 到 4%，帧编号不再变。
- 每分钟经 QMP 读一次 CPU 的 PC，11 次都在客体内核同一处（0xc0567e3c，像是空闲等中断），没看到 AP 断电或唤醒走 bootrom 的迹象。
- 没到「按 Home 唤醒」那一步。

结论：**已知风险，未测**。iPod touch 2 代正式支持时再处理：要么让用户自己提供 SecureROM，要么让唤醒也走 direct-iboot（只调研改哪里，还没做）。

## 6. 文件

- 新增或修改：
  - `patches/ios-txm-jit-protocol.patch`
  - `scripts/ios/lldb_jit_runner.py`、`device-boot.sh`、`sim-boot.sh`、`summarize-run.py`
  - 新增脚本 `check-idle.py`、`sim-standby.sh`、`qmp.py`
  - `app/ClassicTouch/Engine.swift`、`EmulatorViewController.swift`
  - 本报告和 `docs/reports/img/m1s2-*.png`
- 原始记录：
  - `work/ios/runs/device/`：各轮的运行目录、摘要、调试器日志、包日志
  - `work/ios/runs/standby-cancelled.log`
  - `work/ios/logs/`
- 研究材料：`work/ios/research/`（Ios-emul 的 0016 补丁、StikDebug 的 universal.js 和 JSDebugSupport.swift，只读参考）。
