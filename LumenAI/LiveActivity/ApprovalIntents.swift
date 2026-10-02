import Foundation
import ActivityKit
import AppIntents

/// 灵动岛授权按钮 → App 主进程之间的**唯一通道**。
///
/// 为什么需要这样一层：授权请求此刻卡在 App 进程里的一个 `CheckedContinuation` 上，
/// 而灵动岛的按钮是在 **Widget 扩展进程**里渲染的。用户点按钮时，系统会把
/// **App 进程**（可能已在后台、甚至已被挂起）拉起来执行这个意图 ——
/// 扩展只负责把按钮画出来、把意图编码进去，它自己不会去执行。
///
/// 所以：App 启动时把 `resolver` 注册上；扩展那边它是 `nil`，而扩展也不会用到它。
/// 两个 target 都编译这个文件，但只有 App 会真的调用 resolver。
enum ApprovalBridge {
    /// 参数：true = 允许这一次，false = 拒绝。
    ///
    /// `nonisolated(unsafe)`：意图的 `perform()` 不保证在主 actor 上执行，
    /// 而这里只是转手调用一个闭包；真正的状态收拢在 `AgentApprovalCenter`（@MainActor）里。
    /// 标记 unsafe 是如实承认"这个静态可变状态由调用方自己保证安全"。
    nonisolated(unsafe) static var resolver: ((Bool) -> Void)?
}

/// 灵动岛 / 锁屏上的「允许」按钮。
///
/// 为什么用 `LiveActivityIntent` 而不是普通的 `AppIntent`：
/// 普通意图倾向于把 App 切到前台；而用户点这个按钮恰恰是**不想**离开当前界面，
/// 只想让那个卡住的任务继续跑。`LiveActivityIntent` 明确表达了"在后台执行即可"。
struct ApproveToolIntent: LiveActivityIntent {
    // 用**计算属性**而不是存储属性：AppIntents 协议要求 `{ get }`，
    // 而 `static var x = ...` 在 Swift 6 严格并发下会被判为
    // "nonisolated global shared mutable state"（可变静态状态）—— 编译不过。
    // 计算属性没有存储，天然满足并发安全。
    static var title: LocalizedStringResource { "允许执行" }
    static var description: IntentDescription { IntentDescription("允许这一次工具调用并继续任务") }

    func perform() async throws -> some IntentResult {
        ApprovalBridge.resolver?(true)
        return .result()
    }
}

/// 「拒绝」按钮。
struct DenyToolIntent: LiveActivityIntent {
    // 用**计算属性**而不是存储属性：AppIntents 协议要求 `{ get }`，
    // 而 `static var x = ...` 在 Swift 6 严格并发下会被判为
    // "nonisolated global shared mutable state"（可变静态状态）—— 编译不过。
    // 计算属性没有存储，天然满足并发安全。
    static var title: LocalizedStringResource { "拒绝" }
    static var description: IntentDescription { IntentDescription("拒绝这次工具调用") }

    func perform() async throws -> some IntentResult {
        ApprovalBridge.resolver?(false)
        return .result()
    }
}
