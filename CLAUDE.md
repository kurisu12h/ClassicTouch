# 经典 iOS 时光机（暂名）

做一个 iPhone App：在 iPhone 上运行 iPhone OS 1 到 iOS 10 的原版系统，给老玩家一个回味经典 iOS 的入口。目标从 7.1.2 扩到 iOS 10 是用户 2026-11-02 定的；目前能模拟的上限是 iOS 7.1.2，iOS 8 到 10 要 A5/A6 机型，还没有任何模拟器支持。用户把它当作对开源社区的贡献：开源（GPL-2.0-or-later），侧载发布。

仓库：[kurisu12h/ClassicTouch](https://github.com/kurisu12h/ClassicTouch)，先设为私人，做完再公开。

## 分工

- **决策会话**：拆任务、派会话、汇总结果向用户汇报。执行会话不直接找用户要决定。
- **执行会话**：只做简报里写明的范围。做完把详细报告写到 `docs/reports/`，本轮最后一条消息用 3 到 5 句话写清结论、关键数字和阻塞点（决策会话只能看到开头约 400 字）。
- 遇到简报之外需要用户拍板的事（额外下载、花钱、对外发帖或给上游提 issue/PR、改系统设置、签名用的 Apple ID），停下来，把问题写进汇报，不要自己决定。

## 基础事实（2026-11-01 核实）

- 引擎：[samhenrigold/qemu-ios](https://github.com/samhenrigold/qemu-ios)（QEMU 11 分支，GPL-2）。Mac 应用和固件制作工具 FirmwareKit 在 [samhenrigold/LightTouchMac](https://github.com/samhenrigold/LightTouchMac)（GPL-2+）。
- Mac 上已能跑：iPhone OS 1.0 到 iOS 7.1.2，共 8 种机型（初代 iPhone、3GS、iPhone 4、iPod touch 1 到 4 代、初代 iPad）。图形靠把 OpenGL ES 调用转给宿主 GPU（CGL，或实验性的 ANGLE）。
- Light Touch 的 README 明确：不做 iOS/安卓/网页版，不做更新的机型和版本。iPhone 版是空白。
- 上游 2026-08-04 已在 A19 iPhone 真机上跑起来过（dylib 嵌进 App），08-05 标「dead end」转做 Mac 版。原因是性能：作者认定发布版拿不到 JIT，纯解释器在手机上约十分之一实速、一两帧。10-13 删了 iOS 构建脚本，但 `tcg/region.c` 的 TXM JIT 路径、`hw/arm/gles-host-eagl.c`、`contrib/ios-app/qemu-ios-ui.c` 的 App ABI 都还在主干。详见 `docs/research/m1-iphone-feasibility.md`。
- **结论：iOS 4 以后要「能玩」，JIT 是必需的**（StikDebug 等调试器方案，iOS 27 上要走 TXM 协议）。
- 同类项目：S5LBox（从零写的模拟器，在 iPhone 上跑 iPhone OS 3.1.3，MIT）；pocketTouch（闭源 IPA，自称 Light Touch 的 iOS 移植，跑 1 到 3，未核实）；Inferno-iOS（iPhone 上跑 iOS 14）；c12n/nexttouch（空仓库，宣称要做 iOS 8 到 10）。安卓移植：KD3533/qemu-ios-android。

## 目录

- `upstream/`：上游仓库的克隆。不直接改；需要的改动另存为 `patches/` 里的补丁并写明原因。
- `work/`：构建产物、固件、设备镜像、快照。体积大，永不提交。
- `docs/plan.md`：路线和已定决策。`docs/reports/`：各会话报告（截图放 `docs/reports/img/`）。`docs/research/`：调研。

## 规矩

- 全程中文，少用破折号。
- 苹果固件永不进仓库、永不打包进 App。用户自己下载，App 只负责从苹果服务器（或上游固件表里的镜像）取。
- 不 commit、不 push、不开 PR、不在上游提 issue，除非用户要求。
- 这些永不进仓库：手机 UDID（脚本从 `work/ios/phone-udid` 读）、StikDebug 配对文件（`work/ios/secrets/`）、签名团队 ID、用户手机上其他 App 和账号的信息、带个人信息的截图。
- 任何东西都不要放进 `~/Desktop` 或 `~/Documents`（iCloud 同步，会拖慢构建）。
- 编译、制作设备这类长命令放后台跑。
- 本机：M4 Max（36 GB），macOS 27，Xcode 27.2，剩余磁盘约 319 GB。
