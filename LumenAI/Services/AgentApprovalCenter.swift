import Foundation

/// 待授权的工具调用由**一个地方**统一持有。
///
/// 为什么不能继续把它放在 `ChatView` 的 `@State` 里：授权这个动作现在有**两个入口** ——
/// App 内的弹窗，以及灵动岛/锁屏上的按钮。而灵动岛的按钮是由**另一个进程**渲染、
/// 由系统拉起的 App 进程执行的，它拿不到某个视图的 `@State`。
/// 所以那份"正在等的请求"必须搬到一个谁都能找到的地方。
///
/// ⚠️ 这里最要命的一条约束：`CheckedContinuation` **只能被恢复一次**，
/// 恢复第二次会直接崩（不是报错，是 fatalError）。而"两个入口"意味着重复恢复是
/// **很容易发生**的：用户在 App 里点了「允许」的同时，灵动岛上的按钮也可能被按到；
/// 或者弹窗被系统关掉时走的是"视为拒绝"的分支，而按钮那边又给了「允许」。
/// 所以所有恢复都必须经过 `resolve`，并且由它保证只生效一次。
@MainActor
final class AgentApprovalCenter: ObservableObject {
    static let shared = AgentApprovalCenter()

    /// 正在等待的工具名（给灵动岛卡片显示"要执行什么"）
    @Published private(set) var pendingToolName: String?
    /// 是否有请求在等。UI 观察它来关闭弹窗。
    @Published private(set) var isWaiting = false

    private var continuation: CheckedContinuation<ApprovalDecision, Never>?

    private init() {}

    /// 挂起等待。返回前不会恢复 —— 直到有人调 `resolve`。
    func park(callName: String, _ c: CheckedContinuation<ApprovalDecision, Never>) {
        // 理论上同一时刻只会有一个（AgentService 是**逐个**弹窗的：并行调用也严禁并行弹），
        // 但真出现重入时，把**旧的**按拒绝收掉，绝不让它永远挂着 ——
        // 挂着的后果是整个 agent 任务永久阻塞，而且界面上没有任何迹象。
        if let old = continuation {
            continuation = nil
            old.resume(returning: .deny)
        }
        continuation = c
        pendingToolName = callName
        isWaiting = true
    }

    /// 恢复等待中的请求。返回是否**真的**恢复了（第二次调用返回 false，是安全的空操作）。
    @discardableResult
    func resolve(_ decision: ApprovalDecision) -> Bool {
        guard let c = continuation else { return false }
        continuation = nil
        pendingToolName = nil
        isWaiting = false
        c.resume(returning: decision)
        return true
    }

    /// 任务被取消/结束时兜底：别把一个永远等不到答案的请求留在那里。
    func cancelIfWaiting() {
        resolve(.deny)
    }
}
