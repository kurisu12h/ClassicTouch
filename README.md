# Classic Touch（暂名）

在 iPhone 上运行原版的 iPhone OS 1 到 iOS 10，给老玩家一个回味经典 iOS 的入口。

> 开发中，尚未发布。

## 现状（2026-11）

在 iPhone 18 Pro（iOS 27.2）上已经开到主屏、能点能用：

| 模拟的机型 | 系统 | 到主屏 |
|---|---|---|
| iPod touch（第 2 代） | iPhone OS 3.1.3 | 约 18 秒 |
| iPhone 3GS | iOS 6.1.6 | 约 23 秒 |
| iPhone 4 | iOS 7.1.2 | 约 37 秒 |

- JIT 由手机上的 [StikDebug](https://github.com/StikDebug/StikDebug) 提供，不需要连电脑。
- 图形走手机自己的 GPU（OpenGL ES）。
- App 打开是系统列表，点一个就开机；换系统时 App 会重新启动。

**iOS 9：** 我们给 qemu-ios 加了 A5 芯片的 iPod touch（第 5 代）机型，iOS 9.3.5 和 7.1.2 已在 Mac 和 iOS 模拟器的 App 里开到主屏、打开「设置」（模拟器里 9.3.5 约 66 到 73 秒锁屏，7.1.2 约 37 秒），还没上真机。见 `docs/reports/a5-step1.md`、`docs/reports/a5-app.md`。

**iOS 10：** 新加 A6 芯片的 iPhone 5 机型，iOS 10.3.4 在 Mac 上每次开机都进锁屏、主屏，有默认壁纸，能点开「设置」（约 100 秒锁屏），熄屏后按 Home 能叫醒，图形走 GL 前端。见 `docs/reports/a6-step1.md`。

还没做的：iPhone OS 1、2 和 iOS 4、5 还没在手机上试过；iPod touch（第 5 代）还没在手机上试过，触摸纵向有约 100 像素的偏差；声音；多点触控；在手机上直接下载固件、制作设备。iOS 8 还没做；iOS 10 的电池显示不对。

## 怎么做到的

引擎是 [samhenrigold/qemu-ios](https://github.com/samhenrigold/qemu-ios)（QEMU 的分支，GPL-2.0），它在 Mac 上已经能跑 iPhone OS 1 到 iOS 7.1.2（Mac 应用是 [Light Touch](https://github.com/samhenrigold/LightTouchMac)）。本仓库做的是 iPhone 这一端：

- `app/`：iOS App（XcodeGen 工程）
- `patches/`：对 qemu-ios 的补丁（iOS 构建开关、iOS 26 以后的 JIT 协议、EAGL 的 OpenGL ES 2.0 支持）
- `scripts/ios/`：交叉编译依赖和 QEMU、打包设备、真机和模拟器测试脚本
- `docs/`：路线（`plan.md`）、调研和各阶段报告

## 苹果固件

本仓库和 App 都不包含任何苹果固件。固件由用户自己从苹果的服务器下载。

## 许可证

GPL-2.0-or-later，见 `LICENSE`。

本项目与 Apple Inc. 无关。iPhone、iPod touch、iOS 是 Apple Inc. 的商标。

---

**English:** Classic Touch (working title) aims to run stock iPhone OS 1 through iOS 10 on an iPhone. It builds on [qemu-ios](https://github.com/samhenrigold/qemu-ios). iPhone OS 3.1.3, iOS 6.1.6 and iOS 7.1.2 already boot to the home screen on an iPhone 18 Pro, with JIT from StikDebug and GPU-accelerated graphics. iOS 9.3.5 boots to the home screen on an emulated iPod touch (5th generation, a new A5 machine) on a Mac and in the iOS Simulator, not yet on a phone. iOS 10.3.4 on an emulated iPhone 5 (A6) reaches the lock screen, home screen (with its default wallpaper) and Settings on a Mac. Work in progress; no Apple firmware is included. Licensed GPL-2.0-or-later. Not affiliated with Apple.
