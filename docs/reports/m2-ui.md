# M2 界面：把 App 做好看

- 执行会话：m2-ui。分两步：先出设计方案给用户挑（第一步），用户选定后实现（第二步）。
- 2026-11-02 用户选了重做后的方案 A「年表」，第二步已完成。
- 没做的：没改 `EmulatorViewController.swift`、`Engine.swift`、`GuestText.swift`（iOS 7 优化会话在改），没改 `RootViewController.swift`（不需要），没碰 `upstream/`、`scripts/ios/`，没 commit、没 push，没下载任何东西（字体全用系统自带），没往 iPhone 上装或运行任何东西。

## 0. 结论（第二步）

1. **首页按「年表」实现了**，iOS 模拟器里浅色、深色、大号字体都核对过：大版本 1 到 10 排成年表，每台一行（大号年份、机型、系统版本、构建号、占用、线描机身），连着没导入的年份合成一行灰字，iOS 8 到 10 一行标「以后」。正在运行的那台年份变红、左边一道红条、带「继续」，点了回到模拟器画面。
2. **运行画面的新外观写成了独立文件** `EmulatorChromeView.swift`，按简报还没接进 `EmulatorViewController`；调试版用启动参数 `-uipreview <设备 id>` 能看样子。等 iOS 7 优化会话做完，接进去大约十行（第 3 节）。
3. **App 图标**换成年表风格（白底、「2007」、一道红条），颜色放进 `Assets.xcassets`，浅色、深色各一套。
4. **测试入口没坏**：`-device` 开机、`control/back` 回列表、点「继续」回画面都在模拟器里走过一遍；`-fakejit`、`-select`、`autostart.json`、`control/` 的代码一行没动。Debug、Release 都编译通过，新代码 0 个警告。
5. 没装真机，由决策会话安排。
6. **又加了设置、关于和「请我喝杯咖啡」**（用户 2026-11-02 提的，见第三步）。捐赠链接还空着，等用户给。
7. **运行画面的新外观已接进 `EmulatorViewController`，装到了 iPhone 18 Pro 上**（见第四步）：真机 iOS 7 滑动测试锁屏拖 60.3、主屏拖 54.5 帧/秒，和 iOS 7 优化后的数字（59.7、49.0）相当；手机上三台设备的数据都保留。

## 第二步：实现（2026-11-02）

### 1. 改了什么

| 文件 | 内容 |
|---|---|
| `app/ClassicTouch/LibraryViewController.swift` | 重写。普通表格、不要系统导航栏；行有表头、导入、系统、灰行、脚注、JIT 框几种。按大版本 1 到 10 排，连着没导入的合成一行，大于 `Era.supported`（现在是 7）的标「以后」。对外接口（`current`、`jitState`、`onSelect`、`onResume`、`onJITHelp`、`reload()`）没变，所以 `RootViewController` 不用改。点灰行看导入说明，点「以后」看为什么还不能开。调试版加了 `-uipreview` 入口 |
| `app/ClassicTouch/LibraryCells.swift`（新） | 上面几种行的样子 |
| `app/ClassicTouch/Theme.swift`（新） | 颜色、字体（年份用系统自带的 DIN Condensed，其余文字跟系统字号）、年份对照 `Era`、线描机身 `LineDeviceView`（4 种外形管 8 个机型，都是自己画的轮廓） |
| `app/ClassicTouch/EmulatorChromeView.swift`（新） | 运行画面外观：黑底，顶上大号年份、机型和系统、「⋯」；细线；运行状态（「⋯」收起或展开，记在 UserDefaults）；中间留给客体屏幕（402 宽的屏上是 360 × 540）；底部「年表」「Home」「电源」三个方正大按键。附调试版预览 `EmulatorChromePreviewController` |
| `app/ClassicTouch/Assets.xcassets`（新） | `AppIcon`（1024，由 `docs/design/mockups/app-icon.html` 截出）；颜色 Paper、Ink、Mid、Faint、Rule、Accent |
| `app/ClassicTouch/Localizable.xcstrings` | 加 19 条、删 8 条已经没人用的，共 78 条 |
| `app/ClassicTouch.xcodeproj` | `xcodegen generate` 重新生成，只多了上面 3 个 Swift 文件和资源目录，`project.yml` 没改 |

为了不让共用工程在中途编不过（另一个会话也在编），新首页先在 `work/ios/ui-build/` 的暂存工程里改到编译通过，再一次性拷回、重新生成共用工程；暂存工程已删掉。

### 2. 验证（iOS 模拟器）

自己的模拟器设备「ClassicTouch UI」（iPhone 18 Pro，iOS 27.2，UDID 在 `work/ios/ui-sim-udid`），自己的构建目录 `work/ios/DerivedData-ui`。三台设备用 APFS 克隆放进模拟器的文稿目录，不额外占空间。

| 检查 | 结果 | 图 |
|---|---|---|
| 冷启动，`-fakejit off`（装了 StikDebug、还没 JIT） | 年表、两行灰色「还没导入」、「2014–16 iOS 8、9、10 以后」、JIT 框「还没开」 | `img/ui-impl-home.png` |
| `-device n88ap-10B500 -tcg jit -fakejit on` 开机，20 秒后写 `control/back` | `vm_pause reason=list`；3GS 那行变红、带「继续」，JIT 框「当前系统在用 JIT」 | `img/ui-impl-running.png` |
| 点 3GS 那行 | `vm_resume`，回到模拟器画面（还是旧外观，见第 3 节） | |
| 深色模式 | 黑底白字，红色换成深色版 | `img/ui-impl-home-dark.png` |
| 辅助功能大字号（accessibility-large） | 文字正常换行，年份不放大、不和别的字重叠 | （没放图） |
| `-uipreview n88ap-10B500` | 运行画面新外观；点「⋯」收起状态行后客体屏幕跟着重新居中；点「年表」关掉预览 | `img/ui-impl-emulator.png` |
| 主屏 | 新图标 | `img/ui-impl-icon.png` |
| Debug、Release 编译（模拟器） | 都通过，新代码没有警告 | |

核对中发现并改掉的：

1. 大字号下系统行的年份被截成「…」，灰行的年份压到右边的字。年份那一栏宽度固定，年份本来就是 46 pt，改成不跟系统字号放大，放不下时自动缩小。
2. 冷启动时 iPod 那行的「实验性」提示被压扁，重新排版后又正常。原因是 UIStackView 切换排列子视图的隐藏状态时加的高度约束，会残留到第一次量行高；改成不切换隐藏，没有提示时那块自然是 0 高。

### 3. 运行画面怎么接（已在第四步接好，这里留作记录）

`EmulatorChromeView.swift` 开头也写了。大约十行：

1. `viewDidLoad`：先 `view.addSubview(chrome)` 再加 `screen`（屏幕盖在上面；chrome 自己的空白处不接触摸，触摸照旧落到 `EmulatorViewController`）；`chrome.configure(profile, backend: "JIT" 或「解释器」)`。
2. 原来的 `status`、`backButton`、`homeButton`、`powerButton` 换成 `chrome.status`、`chrome.back`、`chrome.home`、`chrome.power`。返回、按下、松开的动作照原样挂上去，删掉原来设字体、边框、圆角的那几行。
3. `viewDidLayoutSubviews`：`chrome.frame = view.bounds; chrome.layoutIfNeeded(); screen.frame = chrome.screenFrame(for: guestSize)`。
4. 开机前 Home、电源照旧先隐藏（`chrome.home.isHidden = true`），开机后再显示。

接完要在模拟器里过一遍测试入口（autodrive、滑动测试的触摸坐标是按客体屏幕归一化的，屏幕位置变了不影响）。

### 4. 没做的、要留意的

- 换系统、没有 JIT、导入说明这些弹窗还是系统的 `UIAlertController`，样式没改。
- 没加英文（String Catalog 已就位）。
- 以后支持新机型或新版本时，改 `Theme.swift` 里的 `Era.runnable`（现在是 2...7），「以后」那几行会自动变成「还没导入」。
- 模拟器里重装 App 后，数据容器的路径会变（内容还在），脚本要每次重新取 `simctl get_app_container`。
- 调试预览读 `Documents/ui-preview.png` 当屏幕画面，只在模拟器里放过，App 不带任何苹果系统的截图。
- 模拟器设备「ClassicTouch UI」留着（已关机），以后接运行画面时还能用。

## 第三步：设置、关于、请我喝杯咖啡（2026-11-02）

用户要求：「还要加上设置，关于，然后最好再有个捐赠按钮，可以请我喝杯咖啡」。样式沿用年表：白纸黑字、细线、粗黑线大标题。

### 1. 做了什么

- **入口**：首页右上角导入按钮左边加了齿轮（`LibraryCells.swift`、`LibraryViewController.swift`）。设置、关于、许可证三页都推进同一个导航栈，系统返回键写「年表」，可以右滑返回。
- **设置**（`SettingsViewController.swift`，新）：
  - 显示：外观（跟随系统、浅色、深色），弹出菜单，选了马上生效，存在 UserDefaults，下次打开 App 第一帧就套上。模拟器画面一直是黑底，不受影响。
  - 系统和存储：每台一行，写占用；正在运行的那台写「运行中」。点一台弹确认后删除（标题写机型和系统，正文写会删掉多少数据、不能恢复）。正在运行的不让删，会说明怎么办。下面写手机还剩多少空间，另有「怎么导入系统」。
  - JIT：「JIT 和 StikDebug」说明（用 Root 原来那个弹窗）。
  - 关于：「关于 Classic Touch」加版本号，然后是「请我喝杯咖啡」。
- **关于**：小图标（照 App 图标画的）、名字、版本；一段简介；开源（源代码链 GitHub 仓库，许可证 GPL-2.0-or-later，看全文）；致谢（qemu-ios、QEMU、Light Touch、StikDebug，各自写许可证，点了用 App 内的 Safari 打开项目主页）、依赖库的许可证；声明（和 Apple 无关，商标归 Apple，App 不带苹果的系统文件）；最后也有「请我喝杯咖啡」。
- **许可证全文**：新加资源 `app/ClassicTouch/ThirdPartyLicenses.txt`（约 200 KB）。按 `scripts/ios/build-deps.sh` 的注释「GPL 分发时要随 App 带上」，把本 App 的 LICENSE、qemu-ios 的 LICENSE 和 COPYING.LIB、Light Touch 的 LICENSE，以及 QEMU 静态链接的 8 个库（GLib、PCRE2、proxy-libintl、pixman、libslirp、OpenSSL、Nettle、libffi）的许可证原文合成一份。显示时把段落里的硬换行接起来，手机上好读。
- **请我喝杯咖啡**：黑底白字的大按钮，设置页和关于页底部各一个。链接放在 `Links.coffee`，**现在是空的**，点了会弹「捐赠页还没设置好」。等用户定了平台、给了链接，改这一行就行。
- **年表顺带改准**：iPhone OS 1 只跑在初代 iPhone 和 iPod touch（第 1 代）上，这两种 App 还不支持（要 pflash），原来写「还没导入」不对，现在和 iOS 8 到 10 一样标「以后」，点了说明原因（`Era.runnable = 2...7`）。
- String Catalog 又加 38 条、删 1 条，共 115 条。共用工程用 `xcodegen generate` 重新生成，只多了 `SettingsViewController.swift` 和 `ThirdPartyLicenses.txt`。

### 2. 验证（iOS 模拟器）

| 检查 | 结果 | 图 |
|---|---|---|
| 首页 | 齿轮在导入按钮左边；2007 那行变成「iPhone OS 1 以后」 | `img/ui-impl-home.png` |
| 点齿轮 | 进设置，返回键「年表」 | `img/ui-impl-settings.png`、`img/ui-impl-settings-2.png`（下半截） |
| 外观选「深色」再选回「跟随系统」 | 马上变，菜单打勾对 | |
| 点「请我喝杯咖啡」 | 链接空着，弹「捐赠页还没设置好」 | |
| 关于、许可证 | 内容对，许可证按段落重排 | `img/ui-impl-about.png` |
| 删除 iPod（克隆的，删完再克隆回来） | 确认框写机型和 487.1 MB；删完目录没了，设置和首页都刷新 | `img/ui-impl-delete.png` |
| `-device` 开 iOS 6 后回列表，再进设置点它 | 显示「运行中」，点了说明不能删 | |
| 正在运行（带齿轮）、深色首页 | 正常 | `img/ui-impl-running.png`、`img/ui-impl-home-dark.png` |
| Debug、Release 编译 | 都通过，新代码没有警告 | |

核对中发现并改掉的：

1. **删除会删到一半**：FirmwareKit 做的设备里 `nand/` 是只读目录（r-x），直接删会先删掉 `device.lock.json` 等文件、再在 `nand/` 报没权限，结果这台从列表消失、几百 MB 还留着。现在先把整棵目录树的目录改成可写再删，模拟器里复测整个目录都删干净了。
2. 占用还没算完就点删除，确认框里大小写成「?」：没算完就不写大小。
3. 设置页导航栏中间的「设置」和大标题重复：去掉导航栏上的。

### 3. 要用户定的

- **捐赠链接**：用哪个平台（Buy Me a Coffee、Ko-fi、GitHub Sponsors、爱发电等），给一个页面地址。可以给两个（比如一个国际、一个国内），按钮可以改成先弹选择。

## 第四步：运行画面接入和真机验证（2026-11-02）

决策会话转达用户批准：iOS 7 优化会话做完（`docs/reports/m2-ios7-perf.md`）后，把新外观接进模拟器画面，再装到手机上。

### 1. 接线

- `EmulatorViewController.swift` 改了 51 行（不算 iOS 7 会话的改动）：原来的 `status`、`backButton`、`homeButton`、`powerButton` 改成指向 `EmulatorChromeView` 里同名控件的属性，其余代码（状态文字、按键的按下和松开、返回、隐藏和显示）一行没动；删掉原来设字体、边框、圆角和手算位置的代码；`viewDidLayoutSubviews` 改成三行；开机读到设备后 `chrome.configure`（年份、机型、系统、JIT 或解释器）。iOS 7 会话加的滑动测试、`-perf`、`-qemuenv`、`threads.csv`、认锁屏的兜底都没碰。
- `EmulatorChromeView.swift`：没有刘海的机型（iPhone SE）安全区上下都是 0，年份贴着屏幕上沿、按键离下沿只有 8 pt，加了最小边距（上 14、下 16）。开头的说明改成「已接入」。
- String Catalog：加「解释器」，删掉没人用的「‹ 返回列表」，共 115 条。

### 2. 模拟器（自己的「ClassicTouch UI」）

| 检查 | 结果 |
|---|---|
| 从列表开机（`-fakejit off` 点 iPhone 4，App 记下待开机后退出；`-fakejit on` 再打开，相当于 StikDebug 拉起） | `boot config=list`，新外观：顶上「2013 iPhone 4 · iOS 7.1.2 · JIT」，状态行，客体屏幕居中（`img/ui-impl-emulator-sim.png`） |
| 电源键 | 客体熄屏 |
| Home 键 | 熄屏时叫醒 |
| 在客体屏幕上滑「Deslizar para configurar」 | 进到语言选择，触摸落点对 |
| 「⋯」收起、展开 | 状态行收起后客体屏幕重新居中，再点恢复 |
| 「年表」 | `back_to_list`、`vm_pause reason=list`，首页 iPhone 4 那行变红、带「继续」 |
| iPhone SE（第 3 代）临时模拟器，`-uipreview` | 屏幕最矮的机型也放得下，居中，上下有边距（`img/ui-impl-emulator-se.png`）；看完删掉了这台模拟器 |
| `SIM_UDID=… scripts/ios/sim-boot.sh n88ap-10B500 jit` | 锁屏 18 秒、主屏 46 秒、待机 14%（以前 16 秒、45 秒、13%），正常退出 |
| `SIM_UDID=… scripts/ios/sim-swipe.sh n90ap-11D257` | 认出锁屏、解锁、认出主屏，各段都跑完。帧/秒：锁屏拖 60.0、锁屏静止 59.5、主屏静止 10.0、翻页 19.9、按住拖 44.5、静止 10.0；iOS 7 会话两轮是 60、59 到 59.3、10、20.4 到 22.0、49.3 到 53.9、10.1。按住拖略低，模拟器是 CPU 软件渲染、波动大，以真机为准 |
| Debug、Release 编译 | 都通过 |

App 只支持竖屏，所以没有旋转要测。

### 3. 真机（iPhone 18 Pro，iOS 27.2）

- 编 iphoneos 版（Debug，构建目录 `work/ios/DerivedData-ui`）：签名团队 ID 在命令里从本机开发证书读出来直接传给 `xcodebuild`，没写进任何仓库文件。嵌了两个 dylib。
- `devicectl device install app` 覆盖安装，**App 数据保留**：首页三台都在（972.2 MB、2.16 GB、2.74 GB，共 5.88 GB），没有重传。
- 正常打开 App（没有 JIT）：新年表首页（`img/ui-device-home.png`；手机开着粗体字，所以字比模拟器粗）。
- `STIK=1 SWIPETEST=1 IDLE=20 scripts/ios/device-boot.sh n90ap-11D257 jit`，一轮，没有被打断（iPhone 镜像没开），记录在 `work/ios/runs/device/20261102-015446-n90ap-11D257-jit/`：锁屏 27 秒、主屏 42 秒，正常退出，测完 App 没在运行。运行画面截图 `img/ui-device-emulator.png`（App 自己在第 67 秒存的窗口截图）。

| 画面 | 这一轮（新外观） | m2-ios7-perf 改后 |
|---|---|---|
| 锁屏来回拖 | **60.3** 帧/秒，CPU 101% | 59.7，99% |
| 锁屏静止 | 60.0，76% | 60.0，96% |
| 主屏翻页（整段） | 23.9，49%；翻页动画本身 44.5（5 次：52、46、45、44、36） | 22.7，49%；动画本身 36 |
| 主屏按住拖 | **54.5**，78% | 49.0，74% |
| 主屏静止 | 10.0，41% | 10，41% 到 42% |

新外观没有拖慢 iOS 7：几项都在 iOS 7 优化后的数字附近，翻页和按住拖还略高（客体屏幕从铺满全宽 402 × 603 变成 360 × 540，App 这边合成的像素少了一点，但主要还是正常波动）。

### 4. 请用户亲手试（由决策会话转告）

1. 拔掉数据线，确认 LocalDevVPN 开着。
2. 打开 Classic Touch：首页是白底黑字的年表，右上角有齿轮和导入按钮。
3. 点「2013 iPhone 4」：会跳到 StikDebug（可能要点一次确认），再自动回来开机，约 30 秒到锁屏。
4. 运行画面：顶上大号「2013」和机型，底部「年表」「Home」「电源」三个键。锁屏几秒后会变暗熄屏，点「Home」叫醒，然后在模拟的屏幕上滑动解锁。
5. 试「电源」（熄屏，再按「Home」亮回来），点右上「⋯」收起或展开那行小字。
6. 点「年表」回首页：iPhone 4 那行变红，写「运行中，已暂停」，点「继续」回到画面。
7. 回首页点齿轮：看设置（外观可以换深色）和「关于 Classic Touch」。「请我喝杯咖啡」现在只会提示还没设置。设置里点一台系统会问要不要删除，不想删就点取消。
8. 试完从多任务里划掉 App。

## 第一步：设计方案（2026-11-02）

三套方向明显不同的方案，每套画了首页（选择系统）和运行中的模拟器画面，详细说明在 `docs/design/README.md`。

| 方案 | 风格 | 客体屏幕 | 实现量 | 图 |
|---|---|---|---|---|
| A 年表（重做） | 白底黑字的年鉴：大号窄体年份、细线、线描机身，红色只标运行中和实验性；iOS 8 到 10 留「以后」一行；运行画面黑底、三个方正大按键 | 360 × 540 pt | 中等偏小，约 600 行 | `img/ui-a-home.png`、`img/ui-a-run.png` |
| B 怀旧拟物 | 致敬 iOS 6 以前：蓝灰导航栏、竖条纹、分组表格、玻璃按钮；运行画面是自己画的机身，点机身上的键操作 | 320 × 480 pt（原机 1:1） | 最大，1000 行以上 | `img/ui-b-home.png`、`img/ui-b-run.png` |
| C 现代卡片 | 大标题、横滑大号机型卡片、底部「正在运行」迷你条；运行画面全黑、屏幕铺满 | 402 × 603 pt（和现在一样） | 最小，约 500 行 | `img/ui-c-home.png`、`img/ui-c-run.png` |

三套并排的总览：`img/ui-overview.png`。

第一版 A（深夜蓝、琥珀发光、毛玻璃卡片、年份刻度条）用户说「不好看，太 AI 了」，同一天整个重做成上面的「年表」：去掉渐变、发光和胶囊标签，时间感改靠排版。旧图已被新图覆盖。

2026-11-02 目标扩到 iOS 10（`CLAUDE.md`）：A 按年份列出了没导入的年份，所以加了「2014–16 · iOS 8、9、10 [以后]」一行，样式比「还没导入」更浅，不像已经支持；B、C 只列已导入的系统，不用改。App 名候选（拾光、Pinstripe、Throwback）和「可以混着用」的建议见 `docs/design/README.md`。

做法：每屏用 HTML 按 402 × 874 pt 画（`docs/design/mockups/`），机身是自己写的矢量图（`common.js` 的 `device()`），用本机 Chrome 无头模式按 3 倍截成 1206 × 2622 的 PNG（`docs/design/render.sh`）。屏幕里的客体画面取自我们自己的运行记录（`work/ios/runs/`），拷了三张到 `docs/design/mockups/assets/`，只在文档里用。

需要用户定的：

1. 选哪套（或怎么混）。
2. App 名先不改，候选只供参考。

第二步的边界（简报写明，记在这里备查）：只改 `LibraryViewController.swift`、`RootViewController.swift` 里和外观有关的部分、新加的界面文件、`Assets.xcassets`、`Localizable.xcstrings`；模拟器画面的新外观先写成独立的新视图文件，接进 `EmulatorViewController.swift` 那几行等 iOS 7 优化会话做完；用自己的构建目录（`work/ios/DerivedData-ui`）和单独的 iOS 模拟器设备；测试入口不能坏。
