# LumenAI 交付状态（已做 / 未做）

> 整理时间：2026-10-12（第二轮：接真 Linux 会话）｜ 版本 **0.3.86 (86)** ｜ 分支 `main`
> 本文只写**已经在本机跑过、有证据**的事；跑不了的会明确标注「未验证」，不拿推算当测量。

---

## 一、结论先说

| | 状态 |
|---|---|
| App 能不能编 | ✅ Release (iOS 真机 SDK) `BUILD SUCCEEDED`，arm64，二进制 61,408,328 B（0.3.87） |
| 自动化测试 | ✅ 4 套全绿（`agent_loop` / `agent_checkpoint` / `agent_parts` / `benchmark_verdict`） |
| Agent 死循环（P0） | ✅ 已修复 + 有回归测试 |
| Token / 延迟优化（P1） | ✅ 已落地（模拟对比，见下） |
| 终端页 / shell 界面 | ✅ 沙盒 shell + **真 Linux 会话面板** |
| Metal 加速 | ✅ 本来就是通的，这次变成**可见、可断言** |
| **内核换链接** | ✅ App 现在链的是**真 Linux 内核**（`liblinux` + `libiSHLinux` + emu + fakefs 合成库）；NotLinux 已移出（`nm` 断言，防两套内核共存） |
| **链接期两条 panic 隐患** | ✅ 都在**产物上断言**过：initcall 顺序（devpts 先于 ios_pty）+ `__percpu_first` 页对齐 |
| **Linux 内核真 boot** | ✅ **本机真启动过**：Alpine 3.19 用户空间起来了、6 个 tty 出登录提示（`tests/ish_boot/run.sh`） |
| **真会话能跑命令** | ✅ **本机真跑过**：起 `/bin/sh`（pid 27）→ 敲 `echo lumen-pty-ok` → 拿回显（`PTY_OK`） |
| **App 里的 Linux 会话** | ⚠️ 代码已接（boot 驱动 / rootfs 导入 / pty 收发 / 状态界面），**但本机没有 iOS 真机，未在设备上验证** |
| **客户机联网** | ✅ **本机真跑过**：`golp` 网卡（10.0.0.1）up ＋ 客户机里 `apk update` 真拉到索引（`NET_OK`）；缺的 DNS 由宿主读 `res_ninit` 注入客户机 `/etc/resolv.conf` |
| **关闭 Linux** | ✅ **本机真跑过**：杀掉客户机用户进程后 pty 被内核清理（`SHUTDOWN_OK`）。内核本身卸不掉这件事**如实写在 UI 和 README 里** |
| **内存占用可见** | ✅ 开发者诊断里分开报：客户机（内核视角，固定 256 MB）与宿主 `phys_footprint`/`resident`；取数逻辑在 harness 上核对过，**真机取值未取证** |
| **Metal 运行期证据** | ✅ 从 llama.cpp 自己的日志取 offload 结论（`load_tensors: offloaded N/M layers to GPU`），不拿开关冒充；**真机输出未取证** |
| VT100 终端渲染 | ⬜ **未做**——现在是原始字节 + ANSI 清洗，全屏程序（vim/top）显示会不对 |
| 真实模型的 token / TTFT / P95 | ⛔ 本机无 API Key，**不可观测**，不伪造 |
| 提交到 git | ✅ 已提交（特性 `c89c3e8` + 本索引提交）；**推送与 GitHub Release 待本机凭据**（`gh` token 失效 + 钥匙串里没有 github.com 凭据，见最后一节） |

---

## 二、已完成（含验证方式）

### 1. P0：Final Answer 已显示但 Agent 仍继续循环

**根因两条**（都在源码里定位过，不是猜的）：

1. 流式生成时一看到结束暗号就 `break` —— 而提示词要求「先暗号、后正文」，
   于是**正文被整体掐掉**，`extractFinalAnswer` 拿到「只有暗号」返回 nil，
   本轮被判成纯思考 → 继续请求模型 → 下一轮再掐一次 → 永远不出答案。
2. 「拿到最终答案就 `return`」的几条出口**没有清断点存档**，
   ChatView 回前台 / 冷启动时读存档**自动续跑**一个已完成的任务 →
   用户看到「答案都出来了它还在跑」。

**改法**（`LumenAI/Services/AgentPerf/AgentLoopPolicy.swift` 新增，纯逻辑；
`AgentService.swift` 所有出口收敛到同一个状态机）：

- 终止状态机 `AgentLoopTerminator`：暗号 / 纯正文 / 空回复 / 重复调用 / 软上限统一判定；
- **只有「任务真的结束」才清档**（取消、生成失败保留，那两种才需要续跑）；
- 暗号处**不再掐流**，只设「尾巴上限」防跑飞；
- 暗号 + 工具调用同时出现 → **工具调用优先**（协议上必须执行）；
- **未知工具名 + 暗号** → 走纠正分支，不再把工具 JSON 当最终答案吐给用户；
- 只有暗号没正文 → 允许补 1 次；连续空回复 → 2 轮收尾；
- 纯正文连续 3 轮（`plainTextHardLimit`）→ 收尾，短结论不再重发到软上限 150 轮；
- 软轮上限单一真源（`loopPolicy.softIterationLimit`）。

**回归测试**（`tests/agent_loop`、`tests/agent_checkpoint`，`swiftc` 单编即可跑，不依赖网络/模拟器）：

```
agent_loop        ✅ 全部通过（10 组场景 / 断言「模型请求了几次」而不只是「界面上有字」）
agent_checkpoint  ✅ 全部通过（清档规则 + 续跑次数上限）
agent_parts       ✅ 全部通过（气泡分段）
benchmark_verdict ✅ 全部通过（A/B 判定契约）
```

**模拟基线对比**（同一批 9 个场景，legacy = 修复前，fixed = 修复后）：

| 指标 | 旧 | 新 |
|---|---|---|
| 模型请求次数 | 210 | **18** |
| 估算输入 token | 1,017,120 | **14,720** |
| 产出可用回答的场景数 | 4/9 | **9/9** |

> ⚠️ 这是**模拟**对比（纯逻辑驱动），不是真实模型测量。真实 API 的 token / TTFT / P95
> 本机拿不到 Key，**没有数据**，不报。

### 2. P1：性能与 Token 消耗

已落地并可由开关复现（`AgentOptimizations`，benchmark 传 `.baseline` 即旧行为）：

- Reasoning 早停（`ReasoningControl`）：产出可执行内容后不再陪它继续生成；
- 工具结果有上限的结构化提取（`ToolResultReducer`）、历史轮压缩（`ToolHistoryCompactor`）；
- 提示词补上「每轮必须二选一：调工具，或输出暗号+正文」（云端 + 中文两处）；
- A/B benchmark 的 baseline/optimized 分别接 `.legacy` / `.fixed` 终止策略，
  这样两组差的是**真实修复收益**，不只是性能开关。

### 3. 终端（Shell）界面

- `LumenAI/Views/Shell/ShellView.swift`（新）：命令行 / 输出 / 退出码 / 当前 cwd /
  历史上下翻阅 / 快捷命令 / 清空 / 复制 / 重置会话；
- 与 agent 的 `shell` 工具**共用同一个沙盒会话**；agent 跑过的命令带 `agent` 标记显示在同一处
  （`LumenAI/Services/Linux/ShellTranscript.swift`，在 `AgentTool` 唯一执行点记录）；
- 入口两处：设置 → 「终端 / Linux 模式」卡；文件页右上角终端按钮；
- `ShellSandbox.runWithExitCodeAsync`（新增，对称于 `runAsync`，多带退出码）。

### 4. Metal 加速

- `LumenAI/Services/MetalCapability.swift`（新）：运行时探测 `MTLDevice` +
  按当前设置算出**实际生效**的 offload 层数（自动模式按内存/上下文换算）；
- 事实：Metal 早就是通的（`llama.xcframework/ios-arm64/libllama-ios.a` 里 `_ggml_metal*`
  有 **256 个唯一符号**（`nm` 519 行，含各目标文件里的重复），含 `_ggml_backend_metal_init`；
  `useMetalAuto` 默认开），本轮只是把它变成**可见可断言**，不是新加功能。
  （0.3.87 又加了一条**运行期**证据 —— 见「二、9」的 d。）

### 5. iSH 引擎（Linux 模式）——已完成的部分

- 子模块 `third_party/ish` 引入；`scripts/build-ish-libs.sh` 幂等构建所需 `.a`
  （默认编 NotLinux，`ISH_BUILD_LINUX=1` 编 Linux 模式）；
- **死链接修好了**：那几个 `.a` 原先只挂在 `OTHER_LDFLAGS` 上、无任何引用点，
  实测二进制里 iSH 符号数 = **0**。现在有 `ish_link.{h,c}` 取地址作锚点 +
  `-Wl,-u` 双保险，`nm` 断言进 CI。
  实测（本轮产物，换链接后）：`_run_kernel`=1、`_asbestos_new`=1、
  `_lumen_linux_kernel_entry`=1、`_lumen_linux_emu_marker`=1，
  而 NotLinux 的 `_become_first_process`=**0**（两套内核不能共存，见「二、8」）。
- **两套 vdso 补丁**（`scripts/patch-ish-vdso.sh`）：NotLinux 侧 meson 用 zig 替代
  Homebrew LLVM；Linux 模式内核侧 `deps/linux/arch/ish/x86/Makefile` 写死 `-fuse-ld=lld`
  （Xcode 只有 ld/ld-classic）→ 只换链接器，编译仍走 clang。幂等、路径失效自愈。
- **Linux 模式库编译成功**（`ISH_BUILD_LINUX=1 ./scripts/build-ish-libs.sh`）：
  `liblinux.a`（真 Linux 内核，774 个成员）+ `libiSHLinux.a` + `libiSHLinuxUser.a` 均
  `BUILD SUCCEEDED`，`nm` 核对 `_run_kernel` / `_actuate_kernel` / `_linux_start_session` /
  `_ios_pty_open` 都在。`deps/linux` 内核源码（359MB，`update=none` 的空子模块）已按官方脚本拉取。
- **CI**（`.github/workflows/build-ipa.yml`）：checkout 带 `submodules: recursive`
  （上一次 CI 挂在这里）、venv 装 meson/ninja/ziglang、显式校验 5 个 `.a` 存在与架构、
  4 套单元测试、产物 `nm` 断言防静默回退。

### 6. Linux 内核 boot：本机真跑通了（本轮最大进展）

**结论**：真 Linux 内核 + Alpine 3.19 用户空间在本机**真的启动起来了**，
有 console 输出、有 getty 登录提示，没有 panic。**不是模拟、不是推算，是一条真实启动日志。**

```
$ ./tests/ish_boot/run.sh
[lumen] importing rootfs: … -> /tmp/ish-rootfs/root
[lumen] actuate_kernel("maxcpus=0") …
[    0.123919] Run /sbin/init as init process
Welcome to Alpine Linux 3.19
Kernel 5.16.0-g8ec9bf17f89c-dirty on an i686 (/dev/tty1)
(none) login:                 ← tty1..tty6 各一个
[lumen] RESULT BOOTED (exit=0, 30.1s, console=4043 bytes, panic=0): 内核启动且有 console 输出
== 退出码 0 ==
PASS 内核起来了
```

**验证方式**（新增 `tests/ish_boot/`，全部在本机可复现，不碰 App 的链接）：

| 文件 | 作用 |
|---|---|
| `shims.c` | 15 个 app 层符号的自实现（照上游语义，避开 iSH 的 AppDelegate/AppGroup entitlement） |
| `lumen_init.c` | 内核侧 `pure_initcall`：先把 `/root` 建出来（见下 #3） |
| `percpu_align.S` | 把 `__percpu_first` 对齐到页边界（见下 #2） |
| `main.c` | 导入 rootfs → `actuate_kernel` → 跑 runloop → 按结果给退出码 |
| `build.sh` / `run.sh` | 编译 & 运行；**产物是 macOS 可执行文件，直接 exec** |

**boot 路上真正卡死我们的 6 个点**（每个都是读代码 + 打断点定位的，不是猜）：

1. **`__per_cpu_start` 不页对齐 → 内核 `panic("BUG!")`**
   上游用 `arch/ish/kernel/sections.S` 代替链接脚本（文件里写着
   “Darwin doesn't do linker scripts”），把 `__per_cpu_start` 定义成 ld64 的
   `section$start$__DATA$__percpu_first`；但那些 section 是**空的**，对齐只有 1
   （实测地址 `…c6b0`）。内核第一条断言
   `PCPU_SETUP_BUG_ON(offset_in_page(__per_cpu_start))` 直接炸。
   → `percpu_align.S` 给同一 section 贡献 4096 字节 + `.p2align 12`，ld64 取 max(对齐) 后落页边界。
2. **`/root` 不存在 → fakefs 挂不上**：`ish_rootfs()` 直接 `do_mount(path, "/root", "fakefs")`，
   而 `CONFIG_BLK_DEV_INITRD=n`（没有 initramfs 造目录），空 ramfs 里查不到 `/root` → `-ENOENT`，
   后面 `devtmpfs`/`proc` 全跳过。→ `lumen_init.c` 在 level 0 initcall 先 `init_mkdir("/root")`。
3. **initcall 顺序错 → `failed to mount devpts: -ENODEV`**：`ios_pty_init`（app 侧，
   device_initcall level6）要挂 devpts，而 `module_init(init_devpts_fs)` 也在 level6、
   在内核侧。**链接时 app 对象排在 liblinux 前面就会先跑**，devpts 还没注册。
   → `build.sh` 把 `-force_load liblinux.a` 放在最前（也符合 sections.S「这个对象要第一个链进去」）。
4. **第 2 个 CPU 一进 idle 就 SIGSEGV**：`arch/ish/kernel/smp.c` 的 `start_secondary`
   给每个 secondary CPU 起宿主线程，iSH 是单 CPU 模拟器，这条路径上游从没跑过。
   `arch/ish/Kconfig` 里 `NR_CPUS` 是 `range 2 32`，改 1 会被拒。
   → 命令行 `actuate_kernel("maxcpus=0")`（`smp.c:1063` 的内核早期参数，
   ish 的 `setup_arch` 会 `parse_early_param()`），**不用重编内核**。
5. **平台/架构的三个环境坑**（本机是 **Intel Mac i5-7200U**）：
   arm64 模拟器二进制直接 `bad CPU type in executable` → 整套按 **macOS 平台** 编；
   `link-vmlinux.sh` 调的是 `libtool -static`，PATH 里是 Homebrew GNU libtool 就报
   `unrecognised option: '-static'` → 手动 ninja 时要把 `/usr/bin` 放最前；
   `xcode-meson.sh` 只在 build 目录**没配置过**时才重写 `cross.txt`，换架构必须先删
   `…/ReleaseLinux-iphonesimulator/meson`（踩过：换 ARCHS 后 kernel 库其实是旧架构）。
6. **直调 clang 找不到 SDK**：`xcrun --find clang` 出来的二进制不带 sysroot 信息，
   必须显式 `-isysroot`，否则 `'sys/types.h' file not found`。

**rootfs**：iSH 官方 `appstore-apk.tar.gz`（`app/iSH.xcconfig` 的 `ROOTFS_URL`），
`fakefs_import()` 产出 `data/` + `meta.db`，只导一次后续复用。

### 7. 顺带修掉的复查风险

来自一次独立的只读复查（Boole），已全部落地：

- 短正文结论（<80 字、不带暗号）不收敛 → `plainTextHardLimit = 3`；
- 未知工具名 + 暗号被吞成最终答案 → 改走纠正分支；
- 软上限两个真源 → 合并成一个。

### 8. 本轮（0.3.86）：把**真 Linux 会话**接进 App

**链接换成真内核**（不是"再挂一个库"，是替换）
- `scripts/build-ish-libs.sh`（`ISH_BUILD_LINUX=1`）现在除了编 `liblinux` / `libiSHLinux`，
  还会**合成** `third_party/ish/build/ReleaseLinux-iphoneos/liblumen-linux.a`：
  成员顺序 = `liblinux` → `libiSHLinux` → `libiSHLinuxUser` → 我们的内核补丁 → rootfs 导入器。
- 为什么要合成（而不是在 `OTHER_LDFLAGS` 里分别列）：**initcall 的执行顺序 = 目标文件在链接
  命令行上的先后**。内核侧 `init_devpts_fs`(level 6) 必须排在 app 层 `ios_pty_init`(level 6) 之前，
  否则 `do_mount("devpts")` 返回 `-ENODEV`，而 `app/LinuxPTY.c` 那行是 **`panic()`**。
  Xcode 的链接行是「app 的所有 `.o` → 再 …OTHER_LDFLAGS」，`-force_load` 只会落在 app 对象之后
  ——分成多个库链时顺序必然是反的。合成库把这个顺序**焊死**在库内部。
- 产物取证（`build-ish-verify/.../LumenAI.app/LumenAI`，arm64，**61,292,080 B**；改前 53,083,480 B）：
  `_run_kernel 1｜_actuate_kernel 1｜_linux_start_session 1｜_ios_pty_open 1｜_init_devpts_fs 1
  ｜_fakefs_import 1｜_asbestos_new 1｜_become_first_process 0`（NotLinux 已移出，防两套内核共存）。
- **initcall 顺序**（`nm -n` 实测，地址小的先跑）：
  `lumen_mkroot0 → call_block_init4 → fakefs_init5 → ish_rootfs → **init_devpts_fs6** → pasteboard_init6
   → nslog_init6 → **ios_pty_init6**` —— devpts 确实在 ios_pty 前面。
- **`__percpu_first` 对齐**：`otool -l` 实测 `align 2^12 (4096)`、地址 `0x101c85000` 落页边界
  （不对齐的话内核第一条断言就 `panic("BUG!")`，harness 第一次跑就是这么炸的）。
- 这两条现在都进了 CI 断言（`Assert Linux kernel is linked and ordered`），因为它们正是
  "链接一改就 panic、但不改就看不出来"的那类回归。

**App 侧的 15 个内核接口符号**（`LumenAI/Services/Linux/LinuxAppGlue.m`）
- 链接探针实测（`clang -force_load liblumen-linux.a`）需要补的符号**恰好**是
  `ConsoleLog / ReportPanic / DefaultRootPath / FsInitialize / Terminal_*(4) / UIPasteboard_*(3)
  / NSData_*(2) / async_do_in_ios / objc_get / objc_put`，外加 `sync_do_in_workqueue`
  （上游它在 `IOSCalls.m`，而那个文件没进 `libiSHLinux.a`，所以必须我们自己给）。
- 全部按上游语义实现，只有两处刻意不同：① 不碰 iSH 的 Roots / AppGroup / AppDelegate
  （会牵出 entitlement 和 `T _main`）；② 终端先只做**原始字节**，不做 VT100 状态机。
- `FsInitialize` 是**空实现**：上游用来读 `/ish/version` 做文件系统迁移，我们导入的是官方
  appstore rootfs、一次导入后续复用，不做迁移（harness 用同样的空实现已真 boot 通过）。

**启动 / 会话 / 界面**
- 内核跑在**专用 pthread** 上（`run_kernel()` 会返回，模拟 CPU 是它自己起的宿主线程）；
  线程 park 住不退出——`setup_current` 把 `current` 挂在调用线程上。
- rootfs：App 里下载 iSH 官方 tarball（与 iSH 自己同一个 URL）或从「文件」导入
  → `fakefs_import` → `Application Support/ish/roots/default`，导入在后台线程。
- 会话：`linux_start_session` 走 `sync_do_in_workqueue`（内核态接口），tty 收发走我们的
  `Terminal_*`；界面在终端页的 `LinuxSessionPanel`（状态 / 导入 / 启动 / 敲命令 / 清屏）。
- `LinuxMode` 判据改成 `run_kernel` 的地址；`LinuxMode.isBooted / isSessionActive` 才是"能跑"。

**会话路上真踩到的两个坑**（都在 harness 上复现过，两条都改了 App 侧代码）
1. **`send_input` 必须在**内核上下文**里调**：`ios_pty_cb_send_input → kernel_write` 要用内核的
   `current`，而 App 主线程（或任意 GCD worker）没有 —— 直接调就是跳 0 崩（实测 backtrace：
   `kernel_write + 190` ← `ios_pty_cb_send_input`）。上游能直接调，是因为它 App 的主线程**就是**
   内核线程；我们把内核放在专用 pthread 上，所以统一走 `async_do_in_workqueue`。
2. **每个终端必须是不同句柄**：早先 harness 给所有终端返回同一个静态哨兵，于是
   `Terminal_setLinuxTTY` 分不清"控制台 tty / 会话 pty"，把控制台当会话用 →
   SIGSEGV 在 `tty_insert_flip_string`。App 侧用的是每个终端一个 ObjC 对象，本来就没这个问题。

**本机验证结果（有日志）**
- `./tests/ish_boot/run.sh` → `RESULT PTY_OK … 内核起来了，而且真会话能跑命令拿到回显`
  （起 `/bin/sh` → pid 27 → 敲 `echo lumen-pty-ok` → 回显 `lumen-pty-ok`）。
- 整包：`BUILD SUCCEEDED`（arm64，真机 SDK，版本 0.3.86）。
- 新增的 Swift 代码确实在包里：`nm` 里能找到 `_$s7LumenAI9LinuxBootC…`（`startShell`/`sessionPid`）、
  `_$s7LumenAI17LinuxSessionPanelV…`、`_$s7LumenAI17LinuxTerminalTextO8StripperV…`。
  （别用 `grep -a` 查中文串判断"有没有进包"：本机这么查连**旧**字符串都查不到，
  之前那条"grep -a 命中中文"的结论不可复现，别当证据用。）
- 4 套单测：`benchmark_verdict / agent_parts / agent_loop / agent_checkpoint` 全绿。
- CI：`ISH_BUILD_LINUX=1`（按需 clone 内核源码）+ 三条产物断言（符号 / initcall 顺序 / 页对齐）。

**这一轮明确没做**：真机验证（没有 iOS 真机）、VT100 屏幕语义（vim / top 这类全屏程序显示会不对）。

### 9. 本轮（0.3.87）：联网 / DNS / 关闭 / 内存与 Metal 的**运行期证据**

四件事：前三件是把已经能跑的东西接进 App 并如实显示，第四件是把"Metal 到底用没用"
从配置回显变成运行期证据。

**a) 联网：客户机出网是真的通的（本机实测，不是"网卡 up 了就宣称联网"）**
- `arch/ish/net/golp.c` 早就编进内核了（`CONFIG_GOLP=y` + `CONFIG_GOLP_AUTOCONFIG=y`，
  见 `arch/ish/Kconfig`；iphoneos / iphonesimulator 两个 objtree 都核过），
  `golp_autoconfig` 是 `late_initcall`，开机自己把网卡 up 起来并挂 10.0.0.1；
  TCP/UDP 经 `host_socket` / `host_connect` / `host_sendmsg`（`arch/ish/kernel/syscalls_user.c`）
  **直接桥到宿主 socket**。
- 本机证据（`LUMEN_NET_PROBE=1 ./tests/ish_boot/run.sh …`）：
  `[lumen] netinfo(第 1 个会话起来后): golp ifindex=2 up=1 running=0 ipv4=10.0.0.1`
  ＋ 客户机里 `apk update` 真拉到两个仓库：
  `fetch …/main/x86/APKINDEX.tar.gz` → `OK: 21917 distinct packages available` → `RESULT NET_OK`。
  DNS + TCP + TLS 三段全通。
- **补上的那块是 DNS**：官方 rootfs 里**没有** `/etc/resolv.conf`（实测 tarball 只有
  `/etc/hosts`、`/etc/nsswitch.conf`）。缺了它 musl 的解析器退回 127.0.0.1，而客户机的
  127.0.0.1 上什么都没有 —— 表现恰好是"网卡 up、地址也有、域名一个都解析不了"。
  上游 iSH 只在 **NotLinux** 模式做这件事（`app/AppDelegate.m` 的 `configureDns` 是
  `#if !ISH_LINUX`），Linux 模式这个洞是我们填的：
  · 内核侧 `lumen_write_guest_file()`（新增）：`filp_open(O_WRONLY|O_CREAT|O_TRUNC)`。
    没用上游现成的 `linux_write_file`，因为它是 `O_WRONLY` **不带 O_CREAT**，
    对着一个不存在的文件必然 -ENOENT。
  · App 侧 `lumen_linux_write_resolv_conf()`：宿主 `res_ninit` + `res_getservers` 取当前 DNS
    （与上游同一套 API），写进客户机；一条都读不到才退回 1.1.1.1。
    `boot()` 在开会话**之前**调它 —— 顺序错了第一条命令就会挂在 DNS 上。
  · 链接要加 `-lresolv`：iOS 上符号是 `res_9_ninit` 别名，少了它 ld 报
    `_res_9_ninit undefined`（看着像代码写错，其实是缺库）；上游 iSH 也链它。
  · 本机证据（探针改成**宿主注入**、客户机不再自己写）: 注入 `rc=0`，
    客户机 `cat /etc/resolv.conf` 打出我们注入的标记行，apk 照旧 `OK: 21917 …` → `RESULT NET_OK`。
- 面板显示的是**内核视角**的网卡：golp 只存在于内核里，App 侧看不到它。

**b) 关闭：能关，且如实说明关不掉什么**
- 内核那条路走不通：`arch/ish/kernel/reboot.c` 的 `machine_halt()` 就是 `exit(0)` ——
  客户机里敲 halt/poweroff 会把**整个 App** 一起结束。
- 所以关闭 = 内核侧 `lumen_kill_user_processes()`（SIGKILL 掉 `pid>1 && mm!=0` 的全部任务）
  ＋ 摘掉会话句柄 + `g_boot_state = 4`。两处刻意不碰：**不碰 pid 1**（SIGKILL 对内层 init
  本来就被忽略；而它若真被"终止"，busybox init 会走 shutdown 序列 → `machine_power_off`
  → App 一起没），**不碰 `mm==0` 的内核线程**（那是模拟器自己的线程，杀了内核就哑了）。
- 本机证据（`LUMEN_SHUTDOWN_PROBE=1 ./tests/ish_boot/run.sh …`）：
  `RESULT SHUTDOWN_OK … 杀掉 7 个客户机用户进程后 pty 被清理（会话确实结束了）`。
  判据是 `Terminal_setLinuxTTY(term, NULL)`（内核侧 `ios_pty_cleanup` 发的），
  不是"我们以为自己关了"。
- 如实登记的限制：**内核卸不掉**（内核只支持启动一次），关掉后要重新启动得重启 App。
  这句同时写在面板的 `stopped` 状态和 README 里。

**c) 内存：客户机与宿主的账分开报（进开发者诊断）**
- 客户机 RAM 固定 256 MB（`arch/ish/kernel/setup.c`：`ish_phys_size = 0x10000000`，
  `host_mmap` 到宿主 `0x200000000`）。那块映射只是**保留地址空间**，真吃物理内存的是
  **被触碰过的页** —— 所以两个数分开显示，不合成一个笼统的"占用"。
  · 客户机：内核侧 `lumen_meminfo()`（`si_meminfo`，新增）→ App `lumen_linux_guest_meminfo()`
  · 宿主：`task_info(TASK_VM_INFO)` → `phys_footprint` / `resident`
- 本机证据：`[lumen] meminfo(第 1 个会话起来后): total=251 MB free=243 MB shared=0 MB buffers=0 MB`。
- 取数都必须在**内核上下文**里跑（宿主看不到客户机页表），所以 C 侧统一包
  `sync_do_in_workqueue`，Swift 侧放后台队列调、不阻塞主线程。

**d) Metal：给的是运行期证据，不是配置回显**
- 可核的事实：`llama.xcframework/ios-arm64/libllama-ios.a` 里 `_ggml_metal*`
  **256 个唯一符号**（`nm` 519 行，含各目标文件里的重复；含 `_ggml_backend_metal_init` /
  `_ggml_metal_init`），主工程链 `-framework Metal`，
  `useMetalAuto` 默认开 —— 本地模型推理**是**走 Metal 的。
- 但"开关开着"≠"这次真跑了 GPU"（Metal 初始化失败会静默回落 CPU）。所以加了一条
  **运行期证据**：`llama_bridge_backend_note()` 从 llama.cpp 自己的日志里取最后一条
  offload/Metal 结论（典型 `load_tensors: offloaded 32/33 layers to GPU`），
  `MetalCapability.runtimeEvidence` 显示它；本次运行还没成功加载过模型时**如实显示
  "无运行期证据"**，不拿开关冒充。
- **Linux 终端不用 Metal**：iSH 的终端渲染是 UIKit + Core Graphics。这条写进代码注释和面板
  说明，免得被读成"整机都是 Metal"。
- ⚠️ 本机没有 iOS 真机、也没在本机加载过模型，所以这条只到"代码路径 + 构建证据"，
  **真机上的那一行实际输出没有取证**（如实登记）。

**本轮产物取证**（`build-ish-verify/Build/Products/Release-iphoneos/LumenAI.app/LumenAI`）
- 最终产物：v0.3.87、arm64、**61,408,328 B**（上一次 0.3.86 是 61,292,080 B）。
- 新符号各 1：内核侧 `_lumen_meminfo` / `_lumen_net_info` / `_lumen_write_guest_file` /
  `_lumen_kill_user_processes`；App 侧 `_lumen_linux_guest_meminfo` / `_lumen_linux_net_info` /
  `_lumen_linux_host_memory` / `_lumen_linux_write_resolv_conf` / `_lumen_linux_shutdown` /
  `_llama_bridge_backend_note`。
- 三条老断言照旧全过：内核符号在、NotLinux 不在、initcall 顺序（devpts `0x101c8fe50` <
  ios_pty `0x101c90000`）、`__percpu_first` align `2^12`。
- CI 的符号断言里补上那四个内核侧新符号 —— 合成库成员一改就可能整块掉出去，
  而那样只是链接失败或静默行为错，看不出来。
- 4 套单测全绿；`xcodegen generate` + 整包 `BUILD SUCCEEDED`（0.3.87）。

---

## 三、未完成（如实登记）

### 1. Linux 会话：已接进 App，但**没有真机验证** ⬜

**现在做到哪一步**：App 已经**换到真 Linux 内核**（链接 + 启动 + rootfs + pty 收发 + 状态界面
全在代码里），而且内核 boot 与"真会话能跑命令"都在**本机 harness** 上真跑过（`PTY_OK`）。
客户机**联网**（`NET_OK`）、**关闭**（`SHUTDOWN_OK`）、**内存/网卡取数**也都在 harness 上真跑过
（见「二、9」）。
**没做**：真机验证（本机没有 iOS 真机）；VT100 屏幕语义（终端现在是原始字节 + ANSI 清洗）。

**四个关键决定（都已落实，留档说明为什么）**：

1. **两套内核不能共存**：`libish.a`（NotLinux）与 `liblinux.a`（真内核）一起
   `-force_load` 实测 **201 个重复符号**（`sys_read`/`sys_brk`/`sys_socket`… 两边都实现了一遍）。
   所以「切到 Linux 模式」= **替换**链接，不是追加。已替换：`LinuxMode.isLinked` 判据改成
   `run_kernel` 的地址，CI 里那条断言也改成了「Linux 符号必须在 + NotLinux 符号必须不在」。
2. **链接契约已闭合**：Linux 模式链（`liblinux` + `libiSHLinux` + `libiSHLinuxUser`
   + emu + fakefs + libarchive + `-lsqlite3` + `-liconv`；后两个是 fakefs 元数据库和
   libarchive 转字符集要的），app 层那 15 个符号由 `LinuxAppGlue.m` 实现
   （`ConsoleLog` / `ReportPanic` / `DefaultRootPath` / `FsInitialize` /
   `Terminal_*` / `UIPasteboard_*` / `NSData_*` / `async_do_in_ios` / `objc_get` / `objc_put`
   + `sync_do_in_workqueue`）。
   ⚠️ 顺序要求：内核成员必须排在 app 层对象前面（initcall 顺序）——
   这在 Xcode 里做不到（`-force_load` 只会落在 app 对象之后），所以合成一个库，
   **成员顺序焊死**（见「二、8」）。
   ⚠️ 不能整个 `-force_load libiSHApp.a`：它里面有 `T _main` 和 iSH 自己的 App UI。
3. **rootfs 管线已通**：iSH 官方 `appstore-apk.tar.gz` → `fakefs_import()` → `data/` + `meta.db`，
   约 3 MB，一次导入后续复用。App 里支持"下载官方 tarball"或"从文件导入"。
4. **boot 要带两个补丁**：`/root` 目录（`lumen_kernel_addon.c`）、`maxcpus=0`（单 CPU），
   外加链接期的 `__percpu_first` 页对齐（`lumen_percpu_align.S`）。
   前两条是**上游 Linux 模式的已知缺口**，第三条是 ld64 没有链接脚本导致的；
   都不是我们引入的，但进 App 必须一并带上，否则就是「点一下会 panic 的按钮」。
   现在前三条都有断言/代码兜着，`maxcpus=0` 写在启动参数里。

**剩余工作（按依赖顺序）**：

| # | 步骤 | 可否在本机验证 | 状态 |
|---|---|---|---|
| 1 | rootfs 管线：官方 rootfs → `fakefs_import(tarball, dir)` → root 目录 | ✅ | ✅ 已跑通（App 里也接了：下载/导入 → 导入器） |
| 2 | 15 个 app 层符号自实现（照上游语义，避开 iSH 的 AppDelegate/AppGroup entitlement） | ✅ 编译 + 链接 | ✅ 已跑通（`LinuxAppGlue.m`，链接探针实测"缺的正好是这 15 个"） |
| 3 | 链接切换：`libish.a` → `liblinux.a` + `libiSHLinux.a`，同步改判据 / CI 断言 | ✅ 整包构建 + `nm` | ✅ **已做**：合成 `liblumen-linux.a`（成员顺序 = initcall 顺序），`LinuxMode` 判据改成 `run_kernel`，CI 三条断言 |
| 4 | boot：`actuate_kernel` → `run_kernel` → `start_kernel`，失败要能报 | ✅ **已在本机验证** | ✅ 已跑通（App 侧：专用 pthread 启动 + panic 回调 + 超时） |
| 5a | PTY 交互（敲命令拿到回显） | ✅ **已在本机验证**（`PTY_OK`） | ✅ 已跑通 |
| 5b | VT100 终端 UI（真正画屏幕、支持全屏程序） | ⚠️ 需真机看 | ⬜ 未做（现在是原始字节 + ANSI 清洗） |
| 6 | 设置页 / 终端页状态与错误可见、如实显示 | ✅ | ✅ 已做（状态行 + 动作按钮 + 失败原因） |
| 7 | 真机验证（本机只有 Intel Mac，**没有 iOS 真机**） | ⛔ 需真机 | ⬜ 未做 |
| 8 | 联网桥接：golp 网卡（内核已编进）+ 宿主 DNS 注入 `/etc/resolv.conf` | ✅ 本机实测 `NET_OK` | ✅ 已做（内核 addon + `-lresolv`） |
| 9 | 关闭 Linux：客户机用户进程全收掉 + 摘会话 | ✅ 本机实测 `SHUTDOWN_OK` | ✅ 已做（内核卸不掉，UI/README 已如实说明） |
| 10 | 开发者诊断取数：客户机内存 / 宿主内存 / 网卡 / Metal 运行期证据 | ⚠️ 取数逻辑可核，**真机取值未取证** | ✅ 已做（代码 + 构建证据） |

### 2. 真实模型的性能基线 ⛔ 不可观测

本机没有 API Key，所以 **TTFT / P95 / 真实 token 计数一个都测不到**。
能报的只有上面那组模拟对比。要真数据需要：配上 Key + 跑 `AgentBenchmark` A/B。

### 3. 测试覆盖面的已知局限

- `tests/agent_loop` 只驱动**纯逻辑**（`AgentLoopPolicy`），不覆盖 `AgentService.run()`
  的真实出口——接线写错（比如某个出口忘了调 `finish`）测试抓不到；
- `loopPolicy` 的 override 参数没有守卫，未来误传 `.legacy` 会整体回退到修复前行为；
- `softLimit`（轮次软上限）目前按「真结束」清档，但任务未必完成，用户会失去续跑——**取舍待定**；
- **Linux 会话这条路，自动化只覆盖"内核侧"**：`tests/ish_boot` 用的是它自己的 shim
  （stdout 版），而 App 里是 `LinuxAppGlue.m`（ObjC + 主队列回调）——
  两边的**内核接口语义一致**（同一份内核侧源码、同一套调用顺序），但 App 那份
  15 个符号的实现和 Swift 侧的 boot/rootfs/会话驱动**没有被单测覆盖**，
  只能等真机上点一次「启动 Linux」才算真验证。

### 4. 工程杂项

- **还没 commit**：P0/P1、终端页、真 Linux 链接与会话、CI、测试全在工作区
  （`tests/` 被 `.gitignore` 忽略，新测试要 `git add -f` 才进版本库）；
- 版本号本轮升到 **0.3.86**（`project.yml` + README 徽章）；
- **本机是 Intel Mac（i5-7200U）**：没有 iOS 真机，arm64 模拟器二进制也跑不了；
  Linux boot 是按 **macOS x86_64** 编才跑起来的（原因见「二、6」#5）。真机验证仍然缺。
- **iSH 是 GPLv2/v3**：现在二进制里**真的含 iSH 代码**，对外分发（含自签 IPA 给别人）
  要履行 GPL 义务（提供对应源码 / 许可文本）；`LICENSE.IOS` 只是不对 App Store 条款冲突追究，不豁免其它要求。

---

## 四、怎么复现验证

```bash
# 1) 四套单元测试（秒级，不依赖网络 / 模拟器）
swiftc -o /tmp/t1 LumenAI/Services/AgentPerf/BenchmarkVerdict.swift  tests/benchmark_verdict/main.swift && /tmp/t1
swiftc -o /tmp/t2 LumenAI/Data/ChatMessage.swift                      tests/agent_parts/main.swift        && /tmp/t2
swiftc -o /tmp/t3 LumenAI/Services/AgentPerf/AgentLoopPolicy.swift    tests/agent_loop/main.swift         && /tmp/t3
swiftc -o /tmp/t4 LumenAI/Data/ChatMessage.swift \
                  LumenAI/Services/AgentCheckpoint.swift \
                  LumenAI/Services/AgentPerf/AgentLoopPolicy.swift    tests/agent_checkpoint/main.swift  && /tmp/t4

# 2) 语法检查（CI 同款）
find LumenAI LumenAIWidget -name '*.swift' -print0 | xargs -0 xcrun swiftc -parse

# 3) 整包构建（CI 同款参数）
xcodegen generate
xcodebuild -scheme LumenAI -configuration Release -project LumenAI.xcodeproj \
  -destination 'generic/platform=iOS' -derivedDataPath build-ish-verify \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  COMPILER_INDEX_STORE_ENABLE=NO -skipMacroValidation -skipPackagePluginValidation

# 4) Linux 模式那套库 + 合成链接包（慢：要拉 359MB 内核源码 + 编十几分钟；幂等）
ISH_BUILD_LINUX=1 ISH_SKIP_NOTLINUX=1 ./scripts/build-ish-libs.sh
# 期望尾部：liblumen-linux.a / arm64 / 成员数 784 / _run_kernel 2 ｜ _init_devpts_fs 1 …

# 5) 内核真的进包了吗（防静默回退 / 防两套内核共存）
BIN=build-ish-verify/Build/Products/Release-iphoneos/LumenAI.app/LumenAI
for s in _run_kernel _actuate_kernel _linux_start_session _init_devpts_fs _fakefs_import _asbestos_new; do
  printf '%-24s %s\n' "$s" "$(nm -j "$BIN" | grep -cx "$s")"; done   # 期望全是 1
nm -j "$BIN" | grep -cx _become_first_process                          # 期望 0（NotLinux 已移出）

# 6) 链接期两条 panic 隐患（CI 同款断言）
nm -n "$BIN" | grep -E '_init_devpts_fs6$|_ios_pty_init6$'   # devpts 的地址必须更小
otool -l "$BIN" | grep -A6 'sectname __percpu_first' | grep align   # 期望 2^12 (4096)

# 7) 内核真的能 boot、真会话真的能跑命令吗（本机，几分钟；只需先编一次内核库）
./tests/ish_boot/build.sh      # 编 harness（产物是 macOS 可执行文件，内核侧源码与 App 共用同一份）
./tests/ish_boot/run.sh        # 导入 rootfs → 起内核 → 起 /bin/sh → 敲 echo lumen-pty-ok
# 期望退出码 0、日志里有 "Welcome to Alpine Linux"、"(none) login:" 和
#   "[lumen] RESULT PTY_OK … 内核起来了，而且真会话能跑命令拿到回显"

# 8) 联网真的通吗（需要网络；apk 慢，给足等待时间）
LUMEN_NET_PROBE=1 ./tests/ish_boot/run.sh /tmp/ish-rootfs/iSH-root.tar.gz /tmp/ish-rootfs/root 600
# 这条路是：宿主往客户机写 /etc/resolv.conf（官方 rootfs 里没有这个文件）→ 客户机 apk update
# 期望日志里有：resolv.conf 宿主注入: rc=0 ｜ netinfo: golp ifindex=2 up=1 ipv4=10.0.0.1
#   客户机里 cat /etc/resolv.conf 打出注入内容 ｜ apk 的 OK: <N> distinct packages available
#   → "[lumen] RESULT NET_OK … 客户机内的 apk update 成功（DNS+TCP+TLS 都通）"

# 9) 关闭真的把会话收掉了吗
LUMEN_SHUTDOWN_PROBE=1 ./tests/ish_boot/run.sh /tmp/ish-rootfs/iSH-root.tar.gz /tmp/ish-rootfs/root 90
# 期望："[lumen] RESULT SHUTDOWN_OK … 杀掉 N 个客户机用户进程后 pty 被清理（会话确实结束了）"
```

## 五、发布（v0.3.87）

本地产物已经做好，**只差推送和造 Release** —— 这两步需要 GitHub 凭据，而当前环境里：
`gh auth status` 报 token 失效（`~/.config/gh/hosts.yml` 里读不到可用 token）、
钥匙串里没有 `github.com` 的凭据（`git credential-osxkeychain get` 返回空）、
`~/.ssh/id_ed25519` 也没在 GitHub 上注册（`ssh -T git@github.com` → `Permission denied (publickey)`）。
所以推送/发 Release 没法由代理代做。

已备好：
- `LumenAI-v0.3.87.ipa`（28,499,045 B，未签名，`Payload` 结构与 CI 一致：主二进制 61,408,328 B、
  `SherpaOnnxC.framework`、`LumenAIWidget.appex`（版本同样 0.3.87/87）、`mlx-swift_Cmlx.bundle`）；
- `update/index.json` 已升到 0.3.87（单独一个提交，见下）；
- 发布说明：`/tmp/lumenai-v0.3.87-notes.md`。

**执行顺序不能反**（先造 Release 再推索引提交）：

```bash
gh auth login                                   # 一次性：重新登录，拿到有 repo 权限的 token

# 1) 先推特性提交（此时索引还是 0.3.85，用户不会被引到还不存在的下载链接）
git push origin c89c3e8:main

# 2) 造 v0.3.87 的 Release（tag 指向 c89c3e8）并上传 IPA
gh release create v0.3.87 --target c89c3e8 \
  --title "LumenAI v0.3.87 — 真 Linux 会话：联网 / DNS / 关闭 + 开发者诊断" \
  --notes-file /tmp/lumenai-v0.3.87-notes.md \
  LumenAI-v0.3.87.ipa

# 3) 再推索引提交（这时 …/download/v0.3.87/LumenAI-v0.3.87.ipa 已经有效）
git push origin main
```

为什么顺序只能这样：索引**超前**而资产不存在时，App 会把它当成新版本并把用户引到 404 的下载链接
（`checkGrayIndex` 只在"索引落后"时能靠 GitHub `releases/latest` 交叉取较大者自愈，反过来不能）。
