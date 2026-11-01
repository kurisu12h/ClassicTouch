# M2 第一项：手机上的宿主 GL（EAGL 补 OpenGL ES 2.0）

- 日期：2026-11-01
- 执行会话：m2-gl-eagl。范围：给 iOS 宿主的 EAGL 后端补上 ES 2.0，让 iPhone 4 的 iOS 7.1.2 在 iPhone 18 Pro 上带图形加速开到主屏，iOS 3.1.3、6.1.6 不退步。
- 没做的：没改 `upstream/`，没 commit、没 push，没给任何上游提 issue 或 PR，没下载 ANGLE 或其他依赖，没碰 iPhone 14 Pro。真机上没做后台测试（简报只要求模拟器，见第 5 节）。

## 0. 结论

1. **iOS 7.1.2 在 iPhone 18 Pro 上带宿主 GL 开到了主屏。** StikDebug JIT、代码区 256 MB，一轮：锁屏 29 秒，主屏 37 秒；主屏待机 CPU 44%（一个核，37 秒没人碰）；App 占用 1027 到 1109 MB，可用内存最低 2267 MB。自动点开「设置」2.1 秒认出设置页，按 Home 1.1 秒回到主屏，触摸和按键都正常。GL 跑在手机的 A20 Pro GPU 上（「OpenGL ES 3.0 Metal - 105」），CoreAnimation 全程走宿主合成，零拒绝。M1 第四步关着宿主 GL 时，同一台设备卡在苹果标志、SpringBoard 179 秒崩了 29 次。
2. **iOS 3.1.3 和 6.1.6 没有退步**，开机时间和待机 CPU 都和 M1 第三阶段（stub、走软件合成）持平或更好：

   | 设备 | 锁屏 | 主屏 | 主屏待机 CPU | 对照 M1 第三阶段（stub） |
   |---|---|---|---|---|
   | iPhone 3GS 6.1.6 | 15 秒 | 23 秒 | 12% | 14 秒、22 秒、16% |
   | iPod touch 2 代 3.1.3 | 10 秒 | 18 秒 | 19% | 10 秒、18 秒、19% |

   iPod 第一轮的待机段被打断（「天气」在第 27 秒被打开，事件记录里没有任何操作，像是手机屏幕被碰到），按规矩补测一轮，上表是补测的数字（第 4.3 节）。
3. **做法**：没有另写一套，而是让 iOS 的 EAGL 构建走上游 ANGLE 那条「每个客体上下文一个宿主 ES 上下文」的路，只把上下文的建立、切换、释放换成 EAGL，ES 适配（帧缓冲名字、矩形纹理、ES 1.1 的行长度、GLSL 原样提交）直接复用 ANGLE 那层。补丁 `patches/ios-eagl-es2.patch`，`build-qemu.sh` 默认开宿主 GL，`HOST_GLES=disabled` 编 stub 对照。
4. **后台**：`qemu_ios_set_foreground(false)` 现在会等正在执行的那次 GL 调用做完才返回，之后的调用一律拒绝并计数。模拟器里验证：主屏时切到系统「设置」15 秒，后台期间拒绝 4716 次 GL 调用（约 6 秒后 App 被系统挂起），切回来后客体照常出画面，SpringBoard 没重启。模拟器不会因为后台用 GL 杀进程，所以「真机上不被杀」只能靠代码保证，没在手机上实测。
5. **阻塞点：没有。** 没碰到系统 OpenGLES 缺能力的墙。值得跟进的两件事（第 6 节）：iOS 7 主屏待机 44% 比 Mac 上的 25% 高，读回的开销还没分析；切到后台时虚拟机仍在跑（只是 GL 被拒），应该顺便暂停虚拟机。

## 1. 动手前的计划（先写下，再做）

### 1.1 现状：EAGL 后端缺什么

读 `hw/arm/gles-host.c`（8258 行）、`gles-host-eagl.c`（296 行）、`gles-host-angle.c.inc`、`gles-host-stub.c` 后的判断：

1. **整个进程只有一个 ES 1.1 上下文。** `gles-host-eagl.c` 用一个静态 `gles_ctx`，`initWithAPI:1`，不认客体的上下文和共享组。`gles-host.c` 里凡是「每个客体上下文一个宿主上下文」的代码（`gles_context_operation`、`gles_contexts`、`GLESGroup.root`、`GLESHost.cgl`）都写在 `#if !defined(GLES_HOST_EAGL) || defined(GLES_HOST_ANGLE)` 里，只给 CGL 和 ANGLE 编；纯 EAGL 构建收到 `GLES_OP_NEW_CONTEXT` 直接回 0（「legacy EAGL backend, no native-context handles」）。iOS 4 以后的 CoreAnimation（iOS 6、7 在 backboardd 里）建的是 API 2 的上下文，跑着色器，ES 1.1 上下文执行不了。
2. **纯 EAGL 构建在现在的主干上已经编不过。** 实测把 `-Dhost_gles` 打开编模拟器版：`gles-host.c` 20 个错误，用到了 ES 1.1 头文件里没有的 `GL_UNPACK_ROW_LENGTH`、`GL_TEXTURE_CUBE_MAP_*` 等。上游 8 月转做 Mac 后，iOS 这条路只剩 ANGLE 那一支在维护（ANGLE 构建也定义 `GLES_HOST_EAGL`）。
3. **ANGLE 后端已经做完了 iOS 7 需要的事**（上游 `docs/research/angle-evaluation.md` 10-21 节，n90ap 11D257 在 Mac 上全程走 ANGLE 合成、零拒绝）：
   - 客体 API 2 的上下文建宿主 ES 2.0（ANGLE 实际给 ES 3.0），API 0、1 建 ES 1.1；
   - 帧缓冲对象的名字按当前上下文选 OES 版或核心版；
   - 客体 GLSL 原样交给宿主编译（不走桌面 1.20 改写）；
   - ES 要求内部格式和数据格式一致，`glTexImage2D` 改内部格式；
   - ES 1.1 没有 `GL_UNPACK_ROW_LENGTH`，上下文自己记、上传前把行压紧；
   - 3.x 的 CoreAnimation 用 `GL_TEXTURE_RECTANGLE`，ES 没有，当成 2D 纹理（每个纹理单元自己记绑定和开关，画的时候把纹理矩阵乘 1/宽、1/高）；
   - APPLE_fence 用 NV_fence 代替。
4. **合成结果怎么到 App 的画面**：iOS 6、7 的 CoreAnimation 把图层画进客体内存里的 IOSurface（宿主这边是挂在 FBO 上的纹理），`gles_surface_writeback` 用 `glReadPixels` 读回、写进客体内存的页，客体的显示控制器从那里扫描输出，QEMU 的显示设备再画进控制台，App 每次屏幕刷新用 `qemu_ios_ui_frame` 取 BGRA 帧。宿主 GL 只负责「画进客体内存」，不直接碰 App 的画面。旧 EAGL 后端那个 IOSurface 颜色附件只用于整屏帧缓冲（`gles_present_to_panel`），而且是全进程一个；ANGLE 后端干脆不用（全走读回）。

### 1.2 改法

不另写一套，而是**让 iOS 的 EAGL 构建走 ANGLE 那条「每个客体上下文一个宿主 ES 上下文」的路**，只把上下文的建立、切换、释放换成 EAGL：

1. `gles-host.c`：新增宏 `GLES_HOST_ES_CONTEXTS`（ANGLE 和 iOS EAGL 都定义），把现在写成 `!defined(GLES_HOST_EAGL) || defined(GLES_HOST_ANGLE)` 和 `defined(GLES_HOST_ANGLE)` 的「ES 宿主」分支改成认这个宏；iOS 上同时包含 `OpenGLES/ES1` 和 `ES3` 的头文件。
2. 新文件 `gles-host-eagl.c.inc`：EAGL 上下文的结构（`EAGLContext`、API 版本、ANGLE 适配要的那几项状态）和建立、切换、释放；然后包含 `gles-host-angle.c.inc` 里和 EGL 无关的那部分 ES 适配。`gles-host-angle.c.inc` 只加条件编译：EGL 的部分只给 ANGLE；APPLE_fence 在 iOS 上没有 NV_fence 可借，改成「每个栅栏都已完成」（客体的数据每次调用都已拷进宿主，和 ANGLE 的语义一样）；BGRA 纹理在 iOS 上照 `APPLE_texture_format_BGRA8888` 用 RGBA 内部格式。
3. `gles-host-eagl.c` 改写成纯 C 的 Objective-C 运行时调用（原文件说明了为什么不能是 .m），提供：按 API 建 `EAGLContext`（客体 API 2 建 ES 3.0，失败退 ES 2.0；API 0、1 建 ES 1.1；同组的上下文用根上下文的 `sharegroup`）、设为当前、释放。当前上下文自己记在线程变量里，不每次问系统；建上下文时包一层自动释放池。
4. 苹果规定同一 sharegroup 的上下文 API 版本要一致（ANGLE 不管）。客体在真 iOS 上也受同样的规则，应该不会混用；万一宿主拒绝，打日志并让这个客体上下文失败，不悄悄退成不共享。
5. 整屏帧缓冲先和 ANGLE 一样全走读回；需要时再按上下文补 IOSurface。
6. 后台：iOS 会杀掉在后台提交 GPU 命令的进程。现有的 `qemu_ios_set_foreground(false)` 让之后的 GL 调用回 -1（客体前端对普通调用的 -1 只是忽略）。要核对 App 在什么时机调它、正在执行的那次调用会不会跨过去，能在模拟器里验证就验证。
7. 构建：`build-qemu.sh` 默认 `HOST_GLES=enabled`；`HOST_GLES=disabled` 编 stub 放到 `build-qemu-<平台>-<后端>-stub`，留作对照。

验证顺序：模拟器里 n90ap 11D257 开到主屏，n88ap 10B500、n72ap 7E18 不退步；再上 iPhone 18 Pro。

## 2. 实现

### 2.1 补丁 `patches/ios-eagl-es2.patch`（939 行，基于 b225694505）

| 文件 | 改动 |
|---|---|
| `hw/arm/gles-host.c` | 新宏 `GLES_HOST_ES_CONTEXTS`（ANGLE 和 iOS EAGL 都定义）。原来写成 `!defined(GLES_HOST_EAGL) \|\| defined(GLES_HOST_ANGLE)` 的 15 处（每上下文状态、`gles_context_operation`、矩形纹理、NV12、APPLE_fence、裁剪平面查询）和 `defined(GLES_HOST_ANGLE)` 的 3 处（PVRTC 用 RGBA 存储、GLSL 原样提交、不注册快照）都改认它；iOS 上同时包含 OpenGLES 的 ES1 和 ES3 头文件，包含新的 `gles-host-eagl.c.inc`；建上下文那段 ANGLE、EAGL 共用，日志打 `[gles-eagl] context api=… renderer=…`；删掉旧的单上下文分支。后台：见第 5 节 |
| `hw/arm/gles-host-eagl.c.inc`（新） | EAGL 上下文结构（EAGLContext、API、ANGLE 适配要的行长度和矩形纹理状态、栅栏表），建立、设为当前、引用计数和释放；客体 API 2 建 ES 3.0，API 0、1 建 ES 1.1，同组用根上下文的 EAGLSharegroup；APPLE_fence 自己记（iOS 没有 NV_fence）；最后包含 `gles-host-angle.c.inc` |
| `hw/arm/gles-host-angle.c.inc` | EGL 生命周期和 NV_fence 两段只给 ANGLE 编；BGRA 纹理在 iOS 上用 RGBA 内部格式。ANGLE 构建的行为不变 |
| `hw/arm/gles-host-eagl.c` | 改成三个纯 C 函数（按 API 建上下文、设为当前、释放），仍走 Objective-C 运行时（原文件解释了为什么不能是 .m），每次包一层自动释放池（vCPU 线程没有自己的池）；去掉只能给一个上下文用的 IOSurface 颜色附件 |

为什么客体 ES 2.0 建宿主 ES 3.0：ANGLE 也是这样（请求 2 给 3.0），上游在 Mac 上验证过的就是这个组合；ES 3.0 原样编译客体的 `#version 100` 着色器，而且有 ES 2.0 没有的 `GL_UNPACK_ROW_LENGTH`，`gles-host.c` 上传纹理时要用。计划第 3 条写的「ES 3.0 建不成就退 ES 2.0」最后没做：退到 ES 2.0 还得给它补行长度的适配，而模拟器和 iPhone 18 Pro 都建得出 ES 3.0；建不成时客体这个上下文失败，日志会写明。

整屏帧缓冲和 ANGLE 一样走 `glReadPixels` 读回。iOS 4 以后屏幕上的东西是 CoreAnimation 自己的 IOSurface，本来就由 `gles_surface_writeback` 读回，旧的 IOSurface 附件只管整屏帧缓冲，三台设备都用不上。

补丁打得上原样的上游：`git -C upstream/qemu-ios apply --check patches/ios-eagl-es2.patch` 通过（只检查，没改 `upstream/`）。工作树里改了之后重新导出补丁：

```bash
cd work/ios/qemu-ios
{ awk '/^diff --git/{exit} {print}' ../../../patches/ios-eagl-es2.patch
  git diff -- hw/arm/gles-host.c hw/arm/gles-host-angle.c.inc hw/arm/gles-host-eagl.c
  git diff --no-index -- /dev/null hw/arm/gles-host-eagl.c.inc; } > ../eagl-es2.patch.new \
  && mv ../eagl-es2.patch.new ../../../patches/ios-eagl-es2.patch
```

### 2.2 构建开关

- `scripts/ios/build-qemu.sh`、`make-dylib.sh`：`HOST_GLES=enabled`（默认）编宿主 GL 版，放在原来的 `work/ios/build-qemu-<平台>-<后端>/`；`HOST_GLES=disabled` 编 stub，放 `build-qemu-<平台>-<后端>-stub/`。`build-qemu.sh` 原来就会自动打 `patches/ios-*.patch`（已打过的跳过）。
- 四份 dylib（真机、模拟器各有 JIT 和解释器）都重编成了 GL 版，都链着 OpenGLES 和 libobjc，每份约 34 MB，导出 58 个函数没变。解释器版只编了，没测。
- M1 的四份 stub dylib 留了一份在 `work/ios/stub-dylibs/`，要对照时也可以 `HOST_GLES=disabled` 重编。
- App 重编并重装到模拟器和手机；App 的 Swift 代码这次没改。

### 2.3 编译时遇到的

上游的纯 EAGL 构建在主干上编不过（第 1.1 节第 2 条），改成走 ES 上下文这条路后一次编过，GL 相关文件只剩三个上游原有的警告（`gles_es2_glsl` 未使用等，ANGLE 构建也有）。

## 3. 模拟器验证（M4 Max 上的 iPhone 18 Pro 模拟器，iOS 27.2，JIT 256 MB）

注意：模拟器里的 OpenGLES 是「Apple Software Renderer」，GL 在 CPU 上算，而且算在我们的进程里，所以模拟器的待机 CPU 会比 stub 高，速度也不代表手机。

| 设备 | QEMU 亮屏 | 锁屏 | 到锁屏的 CPU | 主屏 | 主屏待机 CPU（16 秒） | 最大占用 | 对照 M1 第一阶段模拟器（stub） |
|---|---|---|---|---|---|---|---|
| iPhone 4 7.1.2 | 1.4 秒 | 32 秒 | 37.3 秒 | 41 秒 | 46% | 996 MB | 开不到锁屏（M1 第四步：150 秒里 SpringBoard 启动 25 次） |
| iPhone 3GS 6.1.6 | 16.2 秒 | 17 秒 | 18.3 秒 | 45 秒 | 17% | 790 MB | 亮屏 18.2、锁屏 19、主屏 49 秒，10%，789 MB |
| iPod touch 2 代 3.1.3 | 8.7 秒 | 9 秒 | 8.6 秒 | 18 秒 | 23% | 713 MB | 亮屏 7.0、锁屏 10、主屏 19 秒，17%，704 MB |

- 三台的 `qemu.log` 都有「CoreAnimation composites through the host」，拒绝数都是 0。宿主上下文：iOS 7、6 是一个 ES 1.1（API 0：客体里不报 API 版本的旧式建法，`[mbxshim] GLESCreateGC`）加一到两个 ES 3.0（CoreAnimation 的 API 2）；iOS 3.1.3 是两个 ES 1.1（API 0、1），走的是矩形纹理那层适配。
- 这三轮用的是加第 5 节后台改动之前的构建（只差 `gles_host_set_allowed` 那一段，不碰 GL 路径）；第 5 节的模拟器后台测试和第 4 节的真机各轮都是最终构建。
- 三台的锁屏、主屏截图都核对过，画面完整（iOS 7 的毛玻璃 Dock、iOS 6 的玻璃 Dock、iOS 3 的 Dock 倒影都在）。

![模拟器里 iOS 7.1.2 的主屏](img/m2gl-sim-n90ap-7.1.2-jit-home.png)

其余截图：`img/m2gl-sim-n90ap-7.1.2-jit-lock.png`、`img/m2gl-sim-n88ap-6.1.6-jit-home.png`、`img/m2gl-sim-n72ap-3.1.3-jit-home.png`。

## 4. iPhone 18 Pro 真机（iOS 27.2 24B119，StikDebug JIT，256 MB，USB）

命令（每台一轮，手机解锁、插线、不开镜像；Mac 1 分钟负载 4 到 5）：

```bash
STIK=1 IDLE=40 TBSIZE=256 OPENSETTINGS=1 scripts/ios/device-boot.sh n90ap-11D257 jit 600
STIK=1 IDLE=40 TBSIZE=256 scripts/ios/device-boot.sh n88ap-10B500 jit 600
STIK=1 IDLE=40 TBSIZE=256 scripts/ios/device-boot.sh n72ap-7E18 jit 600
```

设备文件都是手机上原有的（没有重传），每轮 `-resetstate` 从黄金状态冷启动。每轮测完脚本都结束了 App，手机上没有残留进程。

### 4.1 结果

| 设备 | 准备代码区 | QEMU 亮屏 | 锁屏 | 到锁屏的 CPU | 主屏 | 主屏待机 CPU | 占用 | 可用内存（最低） |
|---|---|---|---|---|---|---|---|---|
| **iPhone 4 7.1.2** | 0.48 秒 | 1.1 秒 | **29 秒** | 33.2 秒 | **37 秒** | **44%** | 1027 到 1109 MB | 2267 MB |
| 　对照 M1 第四步（stub） | 0.77 秒 | 1.1 秒 | 未到达 | | | | 最高 1015 MB | 2361 MB |
| 　对照 M0 Mac（CGL，JIT） | | | 40.2 秒 | | | 25% | | |
| **iPhone 3GS 6.1.6** | 0.79 秒 | 13.4 秒 | **15 秒** | 14.5 秒 | **23 秒** | **12%** | 822 到 914 MB | 2462 MB |
| 　对照 M1 第三阶段（stub） | 0.76 秒 | 12.2 秒 | 14 秒 | 14.0 秒 | 22 秒 | 16% | 791 到 892 MB | 2484 MB |
| **iPod touch 2 代 3.1.3**（补测） | 0.78 秒 | 8.0 秒 | **10 秒** | 7.0 秒 | **18 秒** | **19%** | 741 到 801 MB | 2575 MB |
| 　第一轮（待机段被打断，作废） | 0.78 秒 | 7.9 秒 | 10 秒 | 7.9 秒 | 18 秒 | ~~38%~~ | 744 到 797 MB | 2579 MB |
| 　对照 M1 第三阶段（stub） | 0.68 秒 | 7.7 秒 | 10 秒 | 6.9 秒 | 18 秒 | 19% | 751 到 775 MB | 2601 MB |

- 口径同 M1 第三阶段：锁屏、主屏是 App 自己用 Vision 认出来的时间，从 App 调 `qemu_ios_main` 起算；CPU 是本进程所有线程，按一个核算；待机段是主屏后 3 秒到 `idle_end`/`auto_quit`。
- 三台的 GL 都跑在「Apple A20 Pro GPU」上：ES 1.1 是「OpenGL ES-CM 1.1 Metal - 105」，ES 3.0 是「OpenGL ES 3.0 Metal - 105」。拒绝数都是 0，没有出现「EAGL 拒绝建上下文」（第 6 节的共享组风险这次没碰到）。
- 待机段核对（`check-idle.py`）：iPhone 4 41 到 78 秒，没有事件，帧编号 +371（约每秒 10 帧。iOS 7 主屏「时钟」图标的秒针一直在走，待机本来就不是静止的；M0 在 Mac 上量到 iOS 7 主屏静置时每秒换帧约 30 次，手机上只有三分之一，原因没查）；3GS 27 到 63 秒，+2；iPod 补测 22 到 58 秒，+1。
- 占用比 stub 时多几十 MB（宿主 GL 上下文和纹理）。

### 4.2 iPhone 4：点开设置再按 Home

`OPENSETTINGS=1`：待机结束后 App 认出主屏上的「Settings」字样，点它上方的图标；第 79.0 秒点下，第 81.1 秒认出设置页（2.1 秒，含每秒一次识别的延迟），第 84.0 秒按 Home，第 85.1 秒认回主屏（1.1 秒）。M0 在 Mac 上点开设置到前台是 1.85 秒。

![手机上 iOS 7.1.2 的主屏（App 窗口截图，顶上是 App 的状态行）](img/m2gl-device-n90ap-7.1.2-stikdebug-jit256-home.png)

![手机上自动点开的 iOS 7「设置」](img/m2gl-device-n90ap-7.1.2-stikdebug-jit256-settings.png)

另两台：`img/m2gl-device-n88ap-6.1.6-stikdebug-jit256-home.png`、`img/m2gl-device-n72ap-3.1.3-stikdebug-jit256-home.png`。

### 4.3 iPod 第一轮为什么作废

第一轮（`20261101-234131`）开机和锁屏、主屏时间都正常，但待机段 CPU 38%、帧编号以每秒 16 帧一直在涨。看客体截图，第 26 到 27 秒之间「天气」被打开了，之后一直显示「Updating...」转圈（`img/m2gl-device-n72ap-3.1.3-disturbed-weather.png`）。`events.log` 里这段没有任何脚本操作；App 不记录手指触摸，所以和 M1 第一阶段 3GS 那次一样，判断是手机屏幕被碰到了。按规矩补测一轮（`20261101-234337`），待机 19%、帧编号只变 1，和 stub 时一样。

## 5. 后台：App 不在前台时不再调 GL

### 5.1 机制

- App 在 `sceneWillResignActive` 调 `qemu_ios_set_foreground(false)`，`sceneDidBecomeActive` 调 `(true)`（M1 就有，上游头文件要求在 willResignActive 时关，不是 didEnterBackground）。
- 原来 `gles_host_set_allowed(false)` 只改一个标志：vCPU 线程上正在执行的那次 GL 调用（读标志在改之前）会照样跑完，可能跨过 App 进后台的时刻。
- 补丁里改成：每次 GL 调用先标记「在调用中」再读标志；关的一方先改标志再等标记清掉（最多 1 秒，超时打日志），两边各有一道内存屏障，所以 `set_foreground(false)` 返回后不会再有 GL 调用进到系统 GL。被拒的调用计数，回到前台时打 `[gles] foreground again: N GL calls refused while away`。客体前端对普通调用的 -1 只是忽略。

### 5.2 模拟器验证

新脚本 `scripts/ios/sim-background.sh`：iPhone 4 7.1.2 开到主屏，等 10 秒，用 `simctl launch com.apple.Preferences` 把系统「设置」切到前台，15 秒后再 `simctl launch` 我们的 App（还在跑，不会重启），10 秒后退出。

```
进后台前：第 55.0 秒，帧编号 942
后台 15 秒后：第 61.0 秒，帧编号 1002      ← App 进后台约 6 秒后被系统挂起，统计停在第 61 秒
回前台 10 秒后：第 81.0 秒，帧编号 1102
[gles] foreground again: 4716 GL calls refused while away
SpringBoard 只有 PID 64（没重启）；运行目录只有一个（App 没重启）
```

回前台后截图里状态栏时间、时钟图标的指针都在走，画面完整（`img/m2gl-sim-n90ap-7.1.2-jit-after-background.png`）。

### 5.3 没验证到的

- **真机上「后台用 GL 会被杀」没实测。** 模拟器不执行这条规则，所以模拟器只能证明后台期间 GL 调用确实被拦下（4716 次），不能证明手机不会杀。真机上可以用 `devicectl` 拉起系统「设置」把 App 送到后台再切回来测一次，约 1 分钟，没做（简报只要求模拟器）。
- 拉下控制中心、通知中心时 App 也会 willResignActive，这时 App 还看得见，但客体的 GL 被拒，画面会停住，回来后恢复。这是上游的取舍。
- 客体重启（`gles_host_reset`）时会在主循环线程上释放 GL 对象，如果恰好发生在后台，会碰 GL。很少见，没处理。
- 进后台到被系统挂起的约 6 秒里，虚拟机还在跑，iOS 7 的 CoreAnimation 不停地发 GL 调用、全被拒。见第 6 节。

## 6. 风险和下一步

1. **iOS 7 主屏待机 44%**，比 Mac 上 CGL 的 25% 高，比 iOS 6 的 12% 高很多；换帧也只有 Mac 的三分之一。没分析原因。一个推测：iOS 7 主屏一直在重画（时钟图标），每次合成完都要 `glReadPixels` 读回客体内存，在手机这种分块渲染的 GPU 上读回要等管线排空。值得用 `IT_GLES_PROF=1` 看一次 GL 桥的时间花在哪：如果主要是读回，可以按上下文给 CoreAnimation 的表面补 IOSurface（旧代码只给整屏帧缓冲用，还是全进程一个）。
2. **App 进后台时暂停虚拟机。** `qemu_ios_ui_pause`/`resume`（QMP stop/cont）现成；后台不跑客体既省电，也避免恢复时虚拟时钟一下跳很多。属于 M2「版本列表冷启动」那部分 App 生命周期的设计。
3. **共享组 API 混用**：苹果规定同一 sharegroup 的上下文 API 要一致，ANGLE 不管。客体在真 iOS 上受同样的限制，这次三台都没碰到；万一某个 App 混用，宿主会拒绝建上下文并打「[gles-eagl] EAGL refused an ES n context in its share group」，那个 App 的 GL 会失败。
4. **只测了主屏、锁屏、设置**，没测 3D 游戏和第三方 App。
5. OpenGLES 从 iOS 12 起弃用，在 iOS 27.2 上仍然可用（这次实测）。将来被删时的后备仍是 ANGLE（上游 ANGLE 构建不受这个补丁影响）。
6. 快照仍然被 GL 挡住（`gles_begin_context` 挂迁移阻断器），按已定决策不做。

## 7. 文件

- 仓库里（未 commit）：
  - `patches/ios-eagl-es2.patch`（新）
  - `scripts/ios/build-qemu.sh`、`scripts/ios/make-dylib.sh`（`HOST_GLES` 开关，默认开）
  - `scripts/ios/sim-background.sh`（新）
  - 本报告和 `docs/reports/img/m2gl-*.png`（10 张，都核对过画面）
- `work/` 里（不提交）：
  - `work/ios/qemu-ios`（工作树，已打上新补丁）；四份 `build-qemu-*` 重编为 GL 版
  - `work/ios/stub-dylibs/`（M1 的四份 stub dylib）
  - `work/ios/runs/device/20261101-233707-n90ap-11D257-jit`、`-233957-n88ap-10B500-jit`、`-234131-n72ap-7E18-jit`（作废）、`-234337-n72ap-7E18-jit`，各有 `.summary`
  - `work/ios/runs/sim/`（模拟器四轮的运行目录拷贝）
  - `work/logs/m2gl-*.log`（构建和各轮的输出）
- 手机上：App 换成了 GL 版（数据容器没动，三台设备都还在）；StikDebug 没动。
