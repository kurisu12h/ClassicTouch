# M2 App 雏形：不靠 Mac，拿起手机就能用

- 日期：2026-11-02
- 执行会话：m2-app-proto。范围：系统列表首页、一键开 JIT（`stikjit://`）、返回列表和换系统、后台暂停虚拟机、Finder/「文件」导入设备、保留测试入口。最后一步请用户拔线亲手试（第 7 节，等用户做）。
- 没做的：没改 `upstream/`，没 commit、没 push，没给上游提 issue 或 PR，没碰 iPhone 14 Pro，没下载任何新东西。界面只做功能，没做机身外观。

## 0. 结论

1. **App 现在是「打开就是系统列表，点一个就开机」**。没有 JIT 时，点系统后 App 记下选了哪台、打开 `stikjit://enable-jit?bundle-id=org.classictouch.app&script-name=universal.js`、自己退出；StikDebug 挂着调试器拉起一个新进程，新进程看到「有 JIT、有待开的那台」直接开机。换系统就是再走一遍，顺带解决了「一个进程只能起一次 QEMU」。
2. **真机（iPhone 18 Pro，iOS 27.2）上整条链用脚本走通了一遍**（`scripts/ios/device-app-flow.sh`，App 里不开任何测试开关）：
   - 列表进程 → StikDebug → 新进程用 JIT 开 iOS 6，运行目录在 App 打开后 10 秒出现，准备 256 MB 代码区 0.60 秒；
   - 后台 17.7 秒（系统「设置」在前台），进程号不变（31485）、运行目录没多出来，回来后主屏照常、帧编号继续涨；
   - 换系统：QEMU 先正常退出（status 0），再经 StikDebug 起新进程开 iOS 7（准备 0.83 秒），到主屏；
   - 全程 178 秒，手机上 0 次点击。
3. **后台**：`sceneWillResignActive` 时清前台标志并暂停虚拟机（QMP stop），回到前台再继续；回到列表时也暂停。模拟器里暂停时本进程 CPU 从 12% 到 19% 降到 1% 到 2%。
4. **导入不靠脚本**：Finder（文件共享）或「文件」把 `.ctpack` 放进 `Documents/import/`（放文稿根目录也认），首页显示「正在拷入」、进度和结果。真机上用 AFC 上传（Finder 走的就是它）473 MB 用 14 秒，拷完 3 秒后自动导入，0.5 秒解完。先解到暂存目录、完整解完才并进去，截断的包报「导入失败：ctpack 提前结束」，已有设备不受影响。
5. **测试入口都还在**：`device-boot.sh`（STIK 模式开 iOS 6：锁屏 15 秒、主屏 23 秒、待机 17%，和第三阶段的 14、22 秒、16% 一致）、`sim-boot.sh`（3GS JIT：锁屏 16 秒、主屏 45 秒）都回归通过。
6. **请用户亲手试**：步骤见第 7 节。我们那份 StikDebug 关掉了外部请求的确认弹窗，所以中间不用点确认；真实用户默认会多点一次「确认」。
7. 真机脚本测试里有两次 App 失去前台（第 6.2 节）：一次 7 秒、App 自己回来了，原因没弄清；一次像是手机被碰。暂停和恢复都按设计工作。用户手试里那次近 3 分钟的离开，用户确认是自己切出去的。
8. **用户手试**（第 7.1 节）：流程走通，但 iOS 7 拖动锁屏、翻主屏很卡（每秒 6 到 10 帧，进程占满一个核），「设置」不卡（33 到 57 帧）；iPod 3.1.3 顺（14 到 54 帧）。瓶颈在模拟 CPU 加 GL 转发和读回这一侧，建议单独派性能会话。

## 1. 做了什么

| 简报的项 | 实现 | 主要文件 |
|---|---|---|
| 1. 系统列表首页 | 扫 `Documents/devices/` 读 `device.lock.json`，按系统版本排序，显示「iPhone 3GS · iOS 6.1.6」（4.0 以前写 iPhone OS）、构建号和占用空间（按已分配块算，后台线程算）；iPod touch 2 代多一行橙色「实验性：熄屏后可能卡住」。上面是「正在运行」（从模拟器画面返回时），中间是导入，下面是 JIT 状态 | `LibraryViewController.swift`、`DeviceProfile.swift` |
| String Catalog | `Localizable.xcstrings`，源语言中文，67 条，界面文字全走 `String(localized:)`；以后加英文只改这个文件 | `Localizable.xcstrings`、`project.yml` |
| 2. 一键开 JIT | `csops` 查 `CS_DEBUGGED`，再看调试器是否还挂着（见 2.2）；`canOpenURL` 判断装没装 StikDebug（加了 `LSApplicationQueriesSchemes: [stikjit]`）；没装时说明并允许用解释器开机，iOS 7 提示基本不能用 | `JIT.swift`、`RootViewController.swift` |
| 3. 换系统 | 模拟器画面左上「‹ 返回列表」；列表里再点别的系统弹确认，有 StikDebug 走 `stikjit://`，没有就请用户关掉 App 再打开（重开后直接用解释器开那台） | `RootViewController.swift`、`EmulatorViewController.swift` |
| 4. 后台 | 失去前台和回到列表都暂停虚拟机，回来继续 | `Engine.setRunning`、`RootViewController.updateRun` |
| 5. 导入 | 盯 `Documents/import/` 和文稿根目录，等拷完再解，暂存后合并，进度和结果显示在首页 | `ImportManager.swift`、`DevicePack.swift` |
| 6. 测试入口 | 启动参数、`autostart.json`、`Documents/control/`、autodrive 照旧；新加 `-select`、`-fakejit`、control 的 `back`/`resume`/`select` | 见第 5 节 |

App 名仍是占位的「Classic Touch」（没有苹果商标），列表内容里写机型和系统名（iPhone、iOS）属于指称性使用。

## 2. 开 JIT 和换系统怎么走

### 2.1 流程

```
用户点一台
├─ 这个进程起过 QEMU？
│   ├─ 同一台、还在跑 → 回到画面继续
│   └─ 别的 → 弹「换成 X？」确认 → 下面的「换进程」
├─ 有 JIT（CS_DEBUGGED 且调试器还挂着）→ 直接用 JIT 开机
├─ 装了 StikDebug → 换进程（要 JIT）
└─ 都没有 → 「没有 JIT」：用解释器开机 / 怎么装 StikDebug / 取消

换进程：写 Library/Application Support/pending-boot.json（设备 id、要不要 JIT、时间）
       → QEMU 在跑就 qmp quit 正常退出（块设备落盘，最多等 2 秒）
       → 要 JIT：打开 stikjit://…，系统确认 URL 交出去后立刻 exit(0)
         不要 JIT：exit(0)，用户自己重新打开 App

新进程启动：启动参数 / autostart.json 指定设备 → 测试入口，照旧
          有 pending-boot.json（要 JIT 的 2 分钟内有效，解释器的 10 分钟）→ 等 JIT 最多 5 秒 → 开机
                                                                       等不到 → 「没拿到 JIT」：再试一次 / 用解释器 / 取消
          否则 → 列表
```

### 2.2 几个关键点

- **App 为什么要自己退出**：StikDebug 3.2.0 处理 `enable-jit` 时用 `process_control_launch_app(…, start_suspended: true, kill_existing: false)`（`JITEnableContext.debugApp`），不杀已有进程。我们的进程还活着的话，它要么启动失败，要么挂到旧进程上，而旧进程起过 QEMU 已经没用了。所以 URL 一交出去就 `exit(0)`。真机实测从 App 打开到新进程建好运行目录 10 秒，中间没有撞车。
- **判断有没有 JIT**：按简报用 `csops(getpid(), CS_OPS_STATUS)` 查 `CS_DEBUGGED`。但它是「被调试过」的粘性标志，而 iOS 26 起 TXM 只认调试器准备过的代码页：QEMU 分配代码区时调试器必须还挂着，否则 `brk #0xf00d` 没人接，进程直接崩。universal.js 一直挂到 QEMU 发脱离命令，所以真机上要 `CS_DEBUGGED` 和 `P_TRACED` 两样都有才算「有 JIT」。
- **StikDebug 拉起的进程一起来就有调试器**：它是挂起启动、挂上调试器再放行，新进程第一次检查就看到了 JIT，5 秒的等待没用上。
- **换系统时先让 QEMU 正常退出**：真机上换系统那次 `qemu_exit status=0` 和 `relaunch` 在同一个 0.1 秒里，客体本身相当于拔电池（确认框里写了），但宿主这边块设备都落了盘。
- **模拟器里模拟 JIT**：启动参数 `-fakejit on|off|nostik`（只在模拟器生效）。`off` 时点系统只写 pending、退出，宿主再带 `-fakejit on` 启动就相当于 StikDebug 拉起的新进程。

### 2.3 用户多点的那一下

真实用户的 StikDebug 默认开着「外部请求开 JIT 时确认」，所以每次开机或换系统都会在 StikDebug 里多点一次「确认」（我们手机上那份关掉了，见 M1 第三阶段报告）。App 里 JIT 的说明文字已经写了「StikDebug 可能会弹一次确认，点确认即可」。以后内嵌 StikJIT 可以省掉这一跳。

## 3. 后台和返回列表

- `RootViewController.updateRun`：虚拟机只在「App 在前台」且「正显示模拟器画面」时跑。`Engine.setRunning(false)` 先 `qemu_ios_set_foreground(false)`（GL 立刻停，iOS 会杀后台发 GL 的进程），再 `qemu_ios_ui_pause`（QMP stop，排到 QEMU 主循环上做）；`true` 时 `set_foreground(true)` 再 `qemu_ios_ui_resume`。
- 注意 `qemu_ios_set_foreground(true)` 本身就会把停着的虚拟机重新跑起来（`qemu-ios-ui.c` 的 `ios_resume_bh`），所以在列表页时 App 回到前台不调它，等用户点「继续」。
- 每次暂停、继续都记进 `events.log`：`vm_pause reason=background|list`、`vm_resume`。
- 拉下控制中心、通知中心时 App 也会失去前台，这时画面停住，回来继续。
- 好处：后台不跑客体，省电；客体的虚拟时钟停着，回来时不会一下跳很多。

## 4. 导入

- 盯着 `Documents/import/` 和 `Documents/` 两个目录（目录事件），App 回到前台时也扫一次。包的修改时间 3 秒没变才认为拷完；还在拷的显示「正在拷入」，每秒再看一次。
- 解到 `import/.staging-<包名>/`，完整解完再把文件逐个挪进 `Documents` 的同一位置（同名替换，设备原有的 `state/` 不动，重新导入同一台不丢用户数据），最后删包。上次被杀留下的暂存启动时清掉。
- 解包前看剩余空间，不够（包大小加 500 MB）就报错。包里的系统正在运行时先不并进来，等下次打开 App。失败的包大小和时间不变就不重试；拷到一半被读到而失败的，接着拷完大小一变会自动重试。
- 结果追加到 `logs/import.log`，格式和以前一样（`device-boot.sh` 会取回）。
- Info.plist 里 `UIFileSharingEnabled`、`LSSupportsOpeningDocumentsInPlace` 原来就开着。

## 5. 测试入口（都保留）

| 入口 | 变化 |
|---|---|
| 启动参数 `-device` 等 | 照旧，走 `RootViewController` 的测试入口分支，等导入完再开机 |
| `Documents/autostart.json` | **改成只用一次**：读过就改名为 `autostart.used.json`。不然用户以后自己打开 App 也会直接开那台、看不到列表。`device-boot.sh` 每次拉起前都重写它，不受影响 |
| `Documents/control/` | 原有 `unlock`、`home`、`quit`；新加 `back`（返回列表）、`resume`（回到画面）、`select`（文件内容写设备 id，像用户点了它，换系统时不弹确认） |
| autodrive、opensettings | 照旧，只有启动参数或 autostart.json 打开时才开。真实用户从列表开机时全关 |
| 新 `-select <id>` | 像用户在列表里点了这一台，走完整流程（包括去 StikDebug），`device-app-flow.sh` 用它 |
| 新 `-fakejit on\|off\|nostik` | 只在模拟器里，见 2.2 |
| 存图 | 测试入口照旧（客体画面默认每 5 秒、窗口每 15 秒）；从列表开机默认不存，免得用户手机上越攒越多 |
| 运行目录 | 只留最近 30 个 |
| 自动锁屏 | 原来整个 App 都不让手机自动锁屏，现在只在模拟器画面开着时 |

`scripts/ios/device-boot.sh`、`sim-boot.sh` 没改，回归都通过（第 6 节）。

## 6. 验证

### 6.1 iOS 模拟器（ClassicTouch iPhone 18 Pro，iOS 27.2）

用模拟器工具点屏幕，`-fakejit` 模拟 JIT 和 StikDebug。

| 步骤 | 结果 |
|---|---|
| `-fakejit off` 打开 | 列表三台、占用、iPod 的实验性提示、JIT「还没开」（`m2app-sim-1-list-nojit.png`） |
| 点 iPhone 3GS | 写下 `{"device":"n88ap-10B500","wantJIT":true}`，进程退出 |
| 带 `-fakejit on` 再启动（相当于 StikDebug 拉起） | 新进程 `boot config=list … backend=jit`，到锁屏（`m2app-sim-2-booted-after-fakejit.png`） |
| 返回列表 | `vm_pause reason=list`，CPU 降到 1% 到 2%；列表顶部「正在运行 · 已暂停」，3GS 标「运行中」，JIT「当前系统在用 JIT」（`m2app-sim-3-back-to-list-paused.png`） |
| 点「继续」 | `vm_resume`，CPU 回到 12% 左右 |
| 系统「设置」切到前台 8 秒再切回 | 同一进程（PID 14802），`vm_pause reason=background`、`vm_resume` |
| 点 iPhone 4 | 弹「换成 iPhone 4 · iOS 7.1.2？」（`m2app-sim-4-switch-confirm.png`），点「换系统」：`relaunch` 和 `qemu_exit status=0`，进程退出；再带 `-fakejit on` 启动，直接开 iOS 7 |
| `-fakejit nostik` 点 iPod | 弹「没有 JIT」三个按钮（`m2app-sim-5-nostik-alert.png`），选解释器开机正常 |
| 解释器运行中点 3GS | 弹「关闭 App」那种说明（`m2app-sim-6-switch-nostik.png`），关掉再打开，直接用解释器开 3GS |
| 慢慢拷入 iPod 的包（每秒 40 MB，模拟 Finder） | 「正在拷入」（`m2app-sim-7-import-copying.png`），拷完自动导入，列表多出 iPod（`m2app-sim-8-import-done.png`） |
| 文稿根目录放一个截断的包 | 「导入失败：ctpack 提前结束」，暂存清掉，已有设备没动 |
| `sim-boot.sh n88ap-10B500 jit` 回归 | 锁屏 16 秒、主屏 45 秒、待机 13%，正常退出 |

模拟器里发现并修好一个问题：从列表开机时，Root 在把模拟器画面登记为「当前显示」之前就收到「引擎已启动」，于是当成「不在显示」清了前台标志（iOS 6、7 的 GL 会被拒）。改成先登记再加视图，开机后再补一次判断。

另外，iOS 7 到锁屏几秒后客体会自己熄屏（背光从 1971 降到 456，之后全黑），按画面下方的 Home 才亮。这是客体自己的行为，真 iPhone 也一样，但第一次看到全黑会以为坏了，给用户的说明里写了。

### 6.2 iPhone 18 Pro 真机（iOS 27.2，USB，LocalDevVPN 开着）

**首页**：`m2app-device-1-list.png`。JIT 一行显示「还没开」，说明 `canOpenURL(stikjit://)` 认出了 StikDebug。

**整条用户流程**（`scripts/ios/device-app-flow.sh`，记录在 `work/ios/runs/device/flow-20261102-002055/`）：

| 时间（脚本起算） | 事件 |
|---|---|
| 0 秒 | 结束 App，带 `-select n88ap-10B500` 打开（列表进程 PID 31480） |
| 10 秒 | 新运行目录出现，开机进程 PID 31485，`backend=jit debugger=true`，准备 256 MB 0.60 秒 |
| 64 秒 | 认出 iOS 6 主屏（`m2app-device-2-ios6-home-via-stikdebug.png`）。脚本每 15 秒看一次，第 20、39 秒（App 内时间）各发了一次解锁 |
| 64 到 97 秒 | **后台测试**：系统「设置」切到前台，回来。App 内第 56.3 秒 `vm_pause reason=background`，第 57 秒后被系统挂起，第 73.5 秒恢复，74.0 秒 `vm_resume`（离开 17.7 秒）。进程号前后都是 31485，运行目录 1 个，帧编号 275 → 278，回来后主屏照常（`m2app-device-3-ios6-after-background.png`），CPU 回到 10% 到 13% |
| 103 秒 | 往 `control/select` 写 n90ap-11D257 |
| 115 秒 | 旧进程 `relaunch`、`qemu_exit status=0`；新进程 PID 31505，`backend=jit debugger=true`，准备 0.83 秒 |
| 165 秒 | 认出 iOS 7 主屏（`m2app-device-4-ios7-home-after-switch.png`） |
| 178 秒 | `control/quit`，结束 App |

后台那段没有出现 `foreground again: N GL calls refused`：虚拟机先停了，后台根本没有 GL 调用。

**`device-boot.sh` 回归**（`STIK=1 IDLE=40 … n88ap-10B500 jit`）：锁屏 15 秒、主屏 23 秒、待机 17%（25 秒）、准备 0.81 秒、正常退出。`autostart.json` 读完已改名为 `autostart.used.json`，之后正常打开 App 显示的是列表。

**导入**（AFC 上传，Finder 文件共享走的就是它）：App 开着列表时上传 iPod 的包，473 MB 用 14 秒，期间首页「正在拷入」（`m2app-device-5-import-copying.png`），拷完自动导入，0.5 秒，覆盖已有的同一台（`m2app-device-6-import-done.png`）。

**没弄清的两次失去前台**：
- 流程测试里 iOS 6 开机第 2.8 到 9.9 秒，App 失去前台 7 秒（第二次开机没有）。可能是装完第一次被 StikDebug 拉起时的系统提示，也可能是 StikDebug 那边短暂到前台。这段时间虚拟机按设计停着，所以 QEMU 亮屏记成 22.6 秒（第三阶段 12.2 秒，扣掉 7.1 秒基本对上）。
- `device-boot.sh` 回归第 50 秒 App 被切到后台，第 52 秒被挂起，第 94.8 秒才回来，回来时待机时间已到、按计划退出。脚本这段只在经 AFC 取文件，不会切 App，像是手机被人碰了。待机 CPU 只算了前 25 秒，锁屏、主屏数字不受影响，按约定不补测。

请用户手试时留意有没有弹窗（第 7 节）。

## 7. 请用户亲手试（这一步停下，等用户做）

前提：手机上装着最新的 App（已装好）和我们编的 StikDebug；三台设备都在。

1. 拔掉数据线。
2. 确认 LocalDevVPN 开着（不是别的 VPN）。
3. 打开 Classic Touch。首页是系统列表，有三台；最下面 JIT 一行写着「还没开」。
4. 点「iPhone 3GS · iOS 6.1.6」。App 会跳到 StikDebug，几秒后自动回到 Classic Touch 开始开机。我们这份 StikDebug 关了确认弹窗，中间不用点；真实用户这里会在 StikDebug 里多点一次「确认」。
5. 约 15 秒到锁屏。锁屏几秒不碰会熄屏变黑，点画面下方的「Home」叫醒，然后在模拟的屏幕上从左往右滑解锁，看到 iOS 6 主屏。
6. 点左上「‹ 返回列表」。列表最上面是「正在运行 · 已暂停」。点「iPhone 4 · iOS 7.1.2」，弹出「换成 iPhone 4 · iOS 7.1.2？」，点「换系统」。
7. App 再跳一次 StikDebug，自动回来开 iOS 7，约 30 秒到锁屏，同样 Home 叫醒、滑动解锁到主屏。
8. 试完从多任务里划掉 App。

如果卡在 StikDebug 里（多半是 LocalDevVPN 没连上）：打开 LocalDevVPN，2 分钟内回到 Classic Touch，它会提示「没拿到 JIT」，点「再试一次」。

请顺便告诉我们：中间有没有出现任何系统弹窗；从点系统到回到 Classic Touch 大概几秒；哪一步不顺手。

### 7.1 用户手试结果（2026-11-02 00:30 起）

用户反馈：**「iOS 7 滑动和解锁很卡，主界面滑动很卡，但是设置不卡」。** 列表、跳 StikDebug、开机、返回列表、换系统这条流程本身走通了（手机上的运行记录取回到 `work/ios/runs/device/handtest/`）。

两次运行：

| 运行 | 事件 |
|---|---|
| 00:30:39 iPod touch 2 代 3.1.3（列表第一行，不是简报里的 3GS） | JIT 开机，第 10.1 秒 App 失去前台，第 174.7 秒才回来；第 221.9 秒返回列表，第 228.0 秒换系统（`qemu_exit status=0`） |
| 00:34:30 iPhone 4 iOS 7.1.2 | JIT 开机（这次没有开头被切走）；第 78 到 198 秒离开过 2 分钟，之后两次各几秒 |

每秒出帧数（stats.csv 帧编号的差）和本进程 CPU：

| 画面（按时间和出帧推断） | 每秒帧数 | CPU（占一个核） |
|---|---|---|
| iOS 7 开机到锁屏前（0 到 25 秒） | 0 到 1 | 100% 到 140% |
| iOS 7 拖动锁屏解锁（29 到 44 秒） | **6 到 10** | 95% 到 103% |
| iOS 7 进主屏的动画（45 到 57 秒） | 28 到 57 | 50% 到 100% |
| iOS 7 翻主屏等（198 到 260 秒里的卡顿段） | **5 到 10** | 70% 到 96% |
| iOS 7 较顺的段（推测是「设置」） | 33 到 57 | 45% 到 98% |
| iOS 7 静止时（71 到 78、244 到 250 秒） | 稳定 10 | 约 40% |
| iPod 3.1.3 解锁和使用（175 到 222 秒） | 14 到 54 | 30% 到 60% |

初步判断：
- 卡的是锁屏和主屏，这两处 iOS 7 的合成层多（整屏壁纸、半透明的层、拖动时整屏移动），每帧都要在 vCPU 线程上转发大量 GL 调用，再把整屏 glReadPixels 读回客体内存。卡的时候进程基本占满一个核，出帧只有 6 到 10，说明瓶颈在模拟 CPU 这一侧（客体代码加同一线程上的 GL 转发和读回），不是 App 界面；「设置」是不透明的列表，层少，所以顺。
- 静止时稳定每秒 10 帧、CPU 约 40%，和 M2 宿主 GL 报告里「iOS 7 待机 44%、换帧只有 Mac 的三分之一」是同一件事。
- iOS 7 在真 iPhone 4 上锁屏和主屏本来也偏卡，有一部分是系统本身，但我们这里明显更慢。
- 这超出 App 雏形的范围，建议单独派一个性能会话：用 `IT_GLES_PROF=1` 看 GL 桥的时间花在哪（读回、纹理上传还是客体 CPU），再决定是给 CoreAnimation 的表面补 IOSurface 免读回、把 GL 挪到单独线程，还是先从 TCG 侧下手。可以先在 Mac 的模拟器里复现（同一套 EAGL 后端），不占手机。

iPod 那次开机第 10 秒起离开近 3 分钟，用户确认是自己切出去的，不是停在 StikDebug 里。所以「点系统、StikDebug 开好 JIT 后自动回到本 App 开机」在用户手上成立。脚本测试里第一次开机第 2.8 到 9.9 秒那次 7 秒的失去前台仍没弄清，App 自己回来了，不影响使用。

## 8. 已知问题和下一步

1. **两次无故失去前台**（6.2 节）：用户手试能帮着确认是不是系统提示。
2. **iPod touch 2 代熄屏卡住**没修（按用户决定），列表里标了「实验性」。
3. **客体锁屏几秒就熄屏**：用户可能以为黑屏是坏了。可以考虑开机后自动解锁一次，或在画面上提示「按 Home 叫醒」。
4. **删除系统**：列表里还不能删设备，只能用 Finder 或「文件」删 `devices/<id>`。
5. **「用其他 App 打开」.ctpack**：没声明文档类型，从「文件」或隔空投送不能直接「用 Classic Touch 打开」，只能拷进本 App 的文件夹。要做的话加 UTI 声明。
6. **英文**：String Catalog 已就位，加英文只需在 Xcode 里给 `Localizable.xcstrings` 加 English 并填译文。
7. 每次换系统都要过一遍 StikDebug（真实用户多点一次确认）。内嵌 StikJIT 可以省掉。

## 9. 文件

- 仓库里（未 commit）：
  - 新：`app/ClassicTouch/RootViewController.swift`、`LibraryViewController.swift`、`JIT.swift`、`ImportManager.swift`、`Localizable.xcstrings`
  - 改：`app/ClassicTouch/EmulatorViewController.swift`（去掉菜单和导入，加返回列表、暂停、新控制命令、存图规则）、`Engine.swift`（`setRunning`）、`DeviceProfile.swift`（显示名、占用、排序）、`DevicePack.swift`（暂存、进度、合并）、`LaunchOptions.swift`（autostart 只用一次）、`AppDelegate.swift`
  - `app/project.yml`（`LSApplicationQueriesSchemes`、String Catalog 设置），重新生成的 `ClassicTouch.xcodeproj`
  - 新：`scripts/ios/device-app-flow.sh`
  - 本报告和 `docs/reports/img/m2app-*.png`（14 张，都核对过画面；切到系统「设置」那张有用户的 Apple ID 和 Wi-Fi 名，没放进来）
- `work/` 里（不提交）：`work/ios/runs/device/flow-20261102-002055/`（流程测试全部截图和日志）、`work/ios/runs/device/20261102-002453-n88ap-10B500-jit*`（回归）、`work/logs/m2app-*.log`（构建和各轮输出）
- 手机上：新 App 已装好，没在运行；三台设备都在（iPod 那台被重新导入过一次，内容相同）；`Documents/autostart.used.json` 是回归留下的，无害。StikDebug 没动。
