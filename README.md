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

还没做的：iPhone OS 1、2 和 iOS 4、5 还没在手机上试过；声音；多点触控；在手机上直接下载固件、制作设备。iOS 8 到 10 要模拟 A5/A6 芯片的机型，目前还没有任何模拟器支持，是长期目标。

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

**English:** Classic Touch (working title) aims to run stock iPhone OS 1 through iOS 10 on an iPhone. It builds on [qemu-ios](https://github.com/samhenrigold/qemu-ios). iPhone OS 3.1.3, iOS 6.1.6 and iOS 7.1.2 already boot to the home screen on an iPhone 18 Pro, with JIT from StikDebug and GPU-accelerated graphics. Work in progress; no Apple firmware is included. Licensed GPL-2.0-or-later. Not affiliated with Apple.
