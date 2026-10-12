import Foundation

/// iSH「Linux 模式」在 LumenAI 里的**引擎状态**（纯读，不含生命周期，驱动在 `LinuxBoot`）。
///
/// 现状与边界（重要，别误读）：
/// · 现在链的是**真 Linux 内核**（`liblinux.a`，ish-app/linux 分支）+ iSH 的 Linux 模式接口层
///   （`libiSHLinux.a`）+ 模拟器（`libish_emu.a`）。上一版链的是 NotLinux 那套自写系统调用
///   模拟器（`libish.a`）—— 两套内核**不能共存**（实测 201 个重复符号），所以是替换不是追加。
/// · `isLinked` 的判据 = 内核入口 `run_kernel` 的地址非 0（`ish_link.c` 取址）。
///   链接期保证 → 运行期恒真；它存在的意义是**可断言**（CI 用 nm 复核同一事实）。
/// · 启动/会话是不是通，看 `isBooted` / `isSessionActive`，别拿 `isLinked` 当"能跑"。
/// · iSH 的终端渲染是 UIKit + Core Graphics，**不是 Metal**；LumenAI 里用 Metal 的是本地模型推理。
enum LinuxMode {

    /// 内核（`run_kernel`）是否真的链接进本二进制。
    static var isLinked: Bool { lumen_linux_kernel_entry() != 0 }

    /// 模拟器（asbestos）依赖是否也被解析进来 —— 只链了内核却落掉它的话这里会是 0。
    ///
    /// 注意用词：asbestos 是**线程化解释器**（gadget 是预编译函数指针链），
    /// 没有运行期代码生成、不依赖 JIT 权限 —— 这点对 iOS 很关键（App Store 版 iSH 就是这么跑的）。
    /// 之前文档里写的 "JIT" 是沿用上游旧说法，不准确。
    static var isEmuAvailable: Bool { lumen_linux_emu_marker() != 0 }

    /// 内核是否已经启动过（`actuate_kernel` 走到了 startup）。
    static var isBooted: Bool { lumen_linux_booted() }

    /// 是否有一个可交互的 Linux 会话（pty 已建、tty 已拿到）。
    static var isSessionActive: Bool { lumen_linux_session_active() }

    /// 是否已经「关闭」过。关闭 = 客户机用户进程全收掉（`lumen_linux_shutdown`）。
    /// 注意这不是"可以再启动"：iSH 的内核**只能启动一次**，关掉之后要重新启动
    /// 得重启 App（内核卸载接口上游根本没有）。
    static var isStopped: Bool { lumen_linux_stopped() }

    /// 内核起来过（含已停止）。内存 / 网卡这些诊断数都在内核里，只有这种时候取得到。
    static var isBootedOrStopped: Bool { isBooted || isStopped }

    /// 一句话状态，给设置页 / 终端页顶部显示（如实，不吹）。
    static var statusLine: String {
        guard isLinked else { return "Linux 内核未链接" }
        guard isEmuAvailable else { return "Linux 内核已链接（缺模拟器）" }
        if isStopped { return "Linux 已停止（再启动需重启 App）" }
        if isSessionActive { return "Linux 会话进行中" }
        if isBooted { return "Linux 内核已启动" }
        return "Linux 内核已链接（未启动）"
    }
}
