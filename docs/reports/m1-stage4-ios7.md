# M1 第四步：iPhone 18 Pro 上用 StikDebug JIT 开 iPhone 4 的 iOS 7.1.2

- 日期：2026-11-01
- 执行会话：M1 执行会话（接第一到第三阶段）。范围：用 M0 做好的 iPhone 4（n90ap-11D257）和它的黄金状态，在 iPhone 18 Pro（iOS 27.2）上用 StikDebug 给 JIT、代码区 256 MB、宿主 GL 关着（stub），冷启动一轮，到主屏后点开「设置」再按 Home。
- 没做的：没开 EAGL 宿主 GL（M2 的事），没测解释器版，没碰 iPhone 14 Pro，没 commit、没 push，没给任何上游提 issue 或 PR。手机上的 iPhone 4 设备文件按要求留着没删。

## 0. 结论

1. **iOS 7.1.2 开不到锁屏，停在黑底白苹果。** 原因是 iOS 7 的 SpringBoard 一初始化 OpenGL ES 就崩，崩了被 launchd 重启，179 秒里启动了 29 次（约每 5.5 秒一次）。这一步按约定关着宿主 GL，所有 GL 调用都被拒绝。按约定开不到主屏就停，没有硬绕。
2. **和手机、JIT、USB 键盘都无关。** 在 Mac 的 iOS 模拟器里用同一套 stub 构建复现：不挂 USB 键盘、挂 USB 键盘各 150 秒，SpringBoard 都启动了 25 次，都停在苹果标志。M0 在 Mac 上（宿主 GL 开着）同一台设备、同一份黄金状态 40 秒到锁屏。
3. **开到 SpringBoard 之前的部分都正常：**

   | 项目 | 数字 |
   |---|---|
   | 设备包上传（AFC，USB） | 2.4 GB，65 秒（约 37 MB/s） |
   | App 解包 | 2.3 秒 |
   | StikDebug 准备 256 MB 代码区 | 0.77 秒 |
   | QEMU 亮屏（第一帧有背光的画面） | 1.1 秒（CPU 3.2 秒） |
   | 锁屏、主屏 | 未到达 |
   | CPU（占一个核） | 前 15 秒 124%，15 到 60 秒 54%，60 到 178 秒 36%（SpringBoard 反复崩溃重启的开销） |
   | App 占用 | 最高 1015 MB |
   | 可用内存 | 最低 2361 MB |

   对照 M0 Mac 上的 iPhone 4 JIT：锁屏 40.2 秒、主屏静置 25%、点开设置到前台 1.85 秒。这些手机上都还没法比。
4. **iOS 6 为什么没事：** 第三阶段 3GS 的 iOS 6.1.6 装的是同一个 GL 前端，也和宿主握了手、也被 stub 拒绝，但它的合成能退回软件，照样到了主屏。iOS 7 退不回去。
5. **触摸和 Home 键在 iOS 7 上没验证成**（到不了主屏）。新写的「点开设置再按 Home」自动操作在模拟器的 3GS iOS 6 上走通了：点图标后 2.5 秒认出设置页，按 Home 后 1.6 秒认回主屏。iOS 7 一旦开到主屏，这段可以直接用。
6. **阻塞点：iOS 7 离不开宿主 GL。** 要在手机上开到 iOS 7，得先做下面第 5 节的某条路线，都需要决策会话拍板。

## 1. 准备

- **设备文件**：从 M0 的 `work/devices/n90ap-11D257`（2.2 GB）和 `work/states/n90ap-11D257/state`（119 MB，走完首次设置）APFS 克隆到 `work/ios/devices/n90ap-11D257` 和 `n90ap-11D257-golden`，M0 的目录只读。打包 `work/ios/packs/n90ap-11D257.ctpack`（数据 2291 MB，打包 2.4 秒），经 AFC 传到 App 的 `Documents/import/`，大小核对一致。App 启动时解开，包随即删除。
- **USB 键盘：不挂。** iOS 7 解锁后会弹「Cannot Use Device / QEMU USB Keyboard」挡住触摸（M0 报告第 7 节）。`DeviceProfile.boot` 新加 `usbKeyboard` 参数，App 的 `-usbkbd YES`（或 autostart.json 的 `"usbkbd": true`）才挂，默认不挂；App 现在本来也不往客体送按键。手机这轮 `usbkbd=false`。按简报，「去掉后开不了机」时要改成挂上并自动点 OK；这次开不了机和键盘无关（模拟器挂上也一样，第 3 节），所以没在手机上再跑挂键盘的一轮。
- **宿主 GL**：仍是 stub（`-Dhost_gles=disabled`），没动。
- **App 构建**：真机和模拟器版都重编、重装。dylib 没变（第三阶段的四份）。

## 2. 真机这一轮

命令：`STIK=1 IDLE=40 TBSIZE=256 OPENSETTINGS=1 scripts/ios/device-boot.sh n90ap-11D257 jit 900`。运行目录 `work/ios/runs/device/20261101-225949-n90ap-11D257-jit/`。Mac 负载 2.9 左右；iPhone 镜像应用的进程开着，但手机全程解锁，没有在镜像（第三阶段 9 轮也是这样）。

events.log：

```
0.0 boot ... backend=jit ... debugger=true bootrom=placeholder-b-self.bin usbkbd=false
1.4 first_frame 640x960
3.0 backlight_on level=1601
179.0 control quit
179.0 qemu_exit status=0
```

- 用户在第 2 分钟左右报「还在白色苹果界面」。查串口后确认是崩溃循环，第 179 秒发 `quit`，QEMU 正常退出，脚本随后结束 App，手机上没有残留进程。
- 客体画面第 14 秒以后再没变过（帧编号停在 3），只存了 3 张客体截图。

![手机上卡在苹果标志（第 174 秒）](img/m1s4-device-n90ap-7.1.2-stikdebug-jit256-stuck-apple.png)

串口（`serial-0.log`，505 行）里开机一路正常：内核、IOKit、NAND、Wi-Fi 入网，launchd 起来。之后 SpringBoard 每次都走到这几行就没了下文，换一个 PID 重来：

```
SpringBoard[64:1b07] Loaded logger: SBWorkspaceLogging
SpringBoard[64:1b07] *** error reading settings archive file: <SBRootSettings: .../RootSettings.plist>
[gles] OpenGLES front end (contrib/gles-public): 508 gl exports, ... host protocol 1; ES 1.1 + 2.0 (GLEngine.bundle); IOSurface
SpringBoard[99:1b07] Loaded logger: SBAppInstallationLog
...
```

最后一次是 SpringBoard[154]，客体时间 04:00:04 到 04:02:42，共 29 次。`qemu.log` 只有 JIT 准备、亮屏和 `[gles] shim hello: protocol 1 ... (host: 1, ...)`，没有 QEMU 侧的报错。「error reading settings archive」在 M0 Mac 上那次正常开机里也有，不是原因。

## 3. 模拟器复现（不占用手机）

同一份设备和黄金状态，模拟器版 JIT dylib（也是 stub），`scripts/ios/sim-boot.sh n90ap-11D257 jit 150`：

| 轮次 | USB 键盘 | 150 秒里 SpringBoard 启动次数 | 锁屏 |
|---|---|---|---|
| 20261101-230439 | 不挂 | 25 | 未到达 |
| 20261101-230714 | 挂（`USBKBD=1`） | 25 | 未到达 |

结论：手机、TXM、StikDebug、USB 键盘都可以排除。

## 4. 原因

- 设备是 FirmwareKit 照 Light Touch 的配方做的，`ca_ogl` 开着：客体里的 OpenGLES.framework 被整个换成上游的 GL 前端 `contrib/gles-public`，iOS 6、7 的 CoreAnimation 经它把 GL 调用转给宿主（上游 `docs/n90/README.md` 的 7.1.2 结果就是这样跑通的）。
- 我们关掉宿主 GL 时，QEMU 用的是 `hw/arm/gles-host-stub.c`，对每个调用都回 -1。前端建上下文（`fe_new_gc`）失败，`-[EAGLContext initWithAPI:...]` 返回 nil。
- 上游 stub 的注释说「客体探测失败后退回自己的软件渲染」。iOS 6 做到了：3GS 那轮同样握手、同样被拒，照样到主屏。iOS 7.1.2 的 SpringBoard 拿到 nil 上下文就崩（推断：崩溃报告在客体 `/var/mobile/Library/Logs/CrashReporter`，这次没取出来）。
- 第一阶段关宿主 GL，是为了把「能不能开机」和「GL 对不对」分开验证。这个分法对 iOS 3、6 成立，对 iOS 7 不成立。

## 5. 可选路线（都需要决策会话拍板）

1. **把 EAGL 宿主 GL 提前到现在做（原本是 M2）。** 上游 `hw/arm/gles-host-eagl.c` 还在主干，2026-08-04 在 A19 真机上跑起来过；我们的构建只要不传 `-Dhost_gles=disabled` 就会编进去。最直接，也是 iOS 7「能玩」迟早要走的路。代价：M0 报告第 3 节说 EAGL 后端有活着的 GL 上下文时会挡住快照，「快照秒切」得另做；App 进后台前必须停 GL（`qemu_ios_set_foreground` 已有）。
2. **重做一台关掉 `ca_ogl` 的 iPhone 4（软件 CoreAnimation）。** 上游给 iOS 6.0 beta 和 7.0 beta 这样做过（`docs/n81/README.md` 第 12 条、`docs/n90/README.md`），开机正常但没有 GL 应用。要用 M0 的 FirmwareKit 重新制作设备、重走首次设置（Mac 上约几分钟）；7.1.2 在软件合成下能不能开、会不会更慢（iOS 7 的模糊和动画都靠合成）都没验证过。好处是不碰宿主 GL，快照也不受影响。
3. **让 stub 不回 -1，而是在宿主里用软件实现 GLES。** 工作量最大，不建议。

建议先在 Mac 的模拟器里试第 1 条（模拟器 SDK 也有 OpenGLES，不占用手机），通了再上真机测一轮；第 2 条可以作为不想动 GL 时的对照。

## 6. 手机上留下的东西

- App 的 `Documents/devices/n90ap-11D257/`：设备本体（2.2 GB）、`golden-state/`（119 MB）、这次的 `state/`（克隆，只多出写过的页）。手机剩余空间从上传前的 252.64 GB 降到 250.08 GB，共约 **2.56 GB**（含这一轮的日志）。按要求没删。
- `Documents/autostart.json` 现在指向 n90ap-11D257。下次由 StikDebug 拉起 App 之前，脚本会重写它。

## 7. 改动

- `app/ClassicTouch/DeviceProfile.swift`：`boot(...)` 加 `usbKeyboard`，有 USB 主机口的机型默认不再挂 USB 键盘。
- `app/ClassicTouch/EmulatorViewController.swift`：新启动参数 `-usbkbd`、`-opensettings`；`settingsTrip()`（待机结束记 `idle_end`，认出主屏上的「Settings」字样后点它上方 0.06 处的图标，认出设置页存 `settings-*.png`，2 秒后按 Home，认回主屏存 `home-back-*.png`，5 秒后退出；每步 20 秒没反应重试，最多 3 次，整段 150 秒超时）；`boot` 事件记 `usbkbd=`。
- `app/ClassicTouch/GuestText.swift`：识别结果带上指定词的位置（`GuestReading.places`）；新增 `isSettingsScreen`；`isHomeScreen` 排除设置页（它的标题也是「Settings」）。
- `scripts/ios/device-boot.sh`：`OPENSETTINGS=1`、`USBKBD=1`；取回 `argv.json`、`guest-*`、`settings-*`、`home-back-*`、`import.log`；摘要写点开设置和回主屏的秒数；到时限没退出就发 `quit`；测完结束 App 进程。
- `scripts/ios/sim-boot.sh`：`USBKBD=1`。
- `scripts/ios/summarize-run.py`、`scripts/ios/check-idle.py`：待机段也截到 `idle_end`。

模拟器验证（3GS iOS 6.1.6，JIT，`-autodrive YES -opensettings YES -idle 10`）：

```
19.6 lock_seen 19.6
39.6 home_seen 39.6
50.0 idle_end
50.6 settings_label 0.855,0.762
51.0 tap_settings 1 at 0.855,0.702
53.5 settings_seen 53.5
56.0 home_press 1
57.6 home_back 57.6
63.0 auto_quit
```

![模拟器里自动点开的 iOS 6「设置」](img/m1s4-sim-n88ap-6.1.6-jit-autodrive-settings.png)

## 8. 复现

```bash
cp -c -R work/devices/n90ap-11D257 work/ios/devices/
cp -c -R work/states/n90ap-11D257 work/ios/devices/n90ap-11D257-golden
python3 scripts/ios/pack-device.py work/ios/packs/n90ap-11D257.ctpack \
  work/ios/devices/n90ap-11D257=devices/n90ap-11D257 \
  work/ios/devices/n90ap-11D257-golden/state=devices/n90ap-11D257/golden-state
work/ios/tools/idevice-tools-0.1.68/bin/idevice-tools --udid <手机> afc --documents org.classictouch.app \
  upload work/ios/packs/n90ap-11D257.ctpack /Documents/import/n90ap-11D257.ctpack
# 手机解锁、插线、开 LocalDevVPN、不开镜像
STIK=1 IDLE=40 TBSIZE=256 OPENSETTINGS=1 scripts/ios/device-boot.sh n90ap-11D257 jit 900
# 模拟器复现（设备先克隆进模拟器 App 容器的 Documents/devices/）
scripts/ios/sim-boot.sh n90ap-11D257 jit 150
USBKBD=1 scripts/ios/sim-boot.sh n90ap-11D257 jit 150
```

日志：`work/ios/runs/device/20261101-225949-n90ap-11D257-jit/`（events、stats、qemu.log、serial-0.log、截图、import.log、summary），`work/logs/stage4-*.log`，模拟器各轮在模拟器 App 容器的 `Documents/logs/` 下。
