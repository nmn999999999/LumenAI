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

    /// 灵动岛按钮按下的"待决决定"，**落盘**保存。
    ///
    /// 为什么必须落盘，而不是只放在内存里：用户按灵动岛按钮时，系统可能把 App
    /// **重新拉起**（App 之前已被挂起或回收）。那一刻内存里根本没有正在等待的请求 ——
    /// 于是"允许"会静默丢掉，用户切回 App 后看到的却是"被拒绝"。
    /// 落盘之后，这个决定会保留到下一轮真正来问的时候被消费掉。
    ///
    /// 带过期时间：一个几分钟前的"允许"不该在用户早已忘记它的时候生效 ——
    /// 授权是"就这一次、在此刻的上下文里"的同意，不是一张无限期的通行证。
    private static let decisionKey = "agent.pendingApprovalDecision"
    private static let decisionToolKey = "agent.pendingApprovalTool"
    private static let decisionExpiryKey = "agent.pendingApprovalExpiry"
    private static let decisionTTL: TimeInterval = 120

    /// 记录一个来自灵动岛的决定（可能没有对应的等待者）
    func recordExternalDecision(_ decision: ApprovalDecision, toolName: String?) {
        let d = UserDefaults.standard
        d.set(decision == .deny ? "deny" : "allow", forKey: Self.decisionKey)
        d.set(toolName ?? "", forKey: Self.decisionToolKey)
        d.set(Date().timeIntervalSince1970 + Self.decisionTTL, forKey: Self.decisionExpiryKey)
    }

    /// 取出并清掉待决决定。只在还没过期、且工具名对得上时返回。
    ///
    /// 工具名要对得上：用户批准的是**那一次具体的调用**。若期间任务已经推进到
    /// 另一个工具（比如从 note 变成了 rm），把旧的允许套上去是危险的。
    private func consumeExternalDecision(forTool toolName: String) -> ApprovalDecision? {
        let d = UserDefaults.standard
        let exp = d.double(forKey: Self.decisionExpiryKey)
        defer {
            d.removeObject(forKey: Self.decisionKey)
            d.removeObject(forKey: Self.decisionToolKey)
            d.removeObject(forKey: Self.decisionExpiryKey)
        }
        guard exp > Date().timeIntervalSince1970 else { return nil }
        let savedTool = d.string(forKey: Self.decisionToolKey) ?? ""
        guard savedTool == toolName else { return nil }
        return d.string(forKey: Self.decisionKey) == "deny" ? .deny : .once
    }

    /// 挂起等待。返回前不会恢复 —— 直到有人调 `resolve`。
    func park(callName: String, _ c: CheckedContinuation<ApprovalDecision, Never>) {
        // 灵动岛的按钮可能**先于**这次提问被按下（App 被拉起、任务从断点续跑，
        // 才走到这一步）。所以先看有没有留着的决定，有就直接答复，不让用户白等。
        if let decided = consumeExternalDecision(forTool: callName) {
            c.resume(returning: decided)
            return
        }
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

    /// 来自灵动岛的决定：**先落盘**，再尝试恢复当前等待者。
    ///
    /// 为什么要分两步：如果没有等待者（App 刚被系统拉起、或任务已推进到下一轮），
    /// 直接丢弃会让用户的点击静默失效 —— 而他切回 App 后看到的是"被拒绝"（弹窗
    /// 关闭被当成拒绝），体验上完全是反的。
    func resolveFromLiveActivity(approve: Bool) {
        recordExternalDecision(approve ? .once : .deny, toolName: pendingToolName)
        resolve(approve ? .once : .deny)
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
