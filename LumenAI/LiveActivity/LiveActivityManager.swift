import Foundation
import ActivityKit

/// 主 App 侧的实时活动管理：开始 / 更新 / 结束灵动岛上的那张卡片。
///
/// 定位说明（很重要，不然会被当成"没做完"）：灵动岛**不是**用来跑任务的，
/// 它是一块"任务还在进行"的可见凭据。真正让任务在后台活下去的是
/// `BackgroundTaskKeeper` 与后台 URLSession；灵动岛解决的是另一半问题 ——
/// 用户切出去之后**完全不知道 App 还在不在干活**，只能反复切回来看。
///
/// 三条 ActivityKit 的硬约束（都踩过或必然踩到）：
/// 1. `Activity.request` 会抛异常，**必须**处理：用户在设置里关掉了实时活动、
///    或者同时存在的活动数超限时都会失败。
/// 2. 同一时刻只保留**一个**活动。这里在 start 之前先把旧的 end 掉 ——
///    否则会出现两张卡片叠在岛上（用户看到的是一团糊在一起的内容）。
/// 3. `ContentState` 更新要**节流**。每次 update 都有成本，而 agent 循环里
///    工具进度变化很密；高频更新会被系统限流甚至丢弃，反而不更新了。
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// 当前活动的种类。
    ///
    /// 为什么需要它：同一时刻系统只允许一张卡片，而**下载和 agent 任务是两件独立的事**。
    /// 没有这个标记的话，用户一边跑 agent 一边下模型，后启动的那个会把前一个的卡片顶掉 ——
    /// 表现是灵动岛的内容突然变成另一个任务的，用户以为串了。
    /// 现在下载只在"没有 agent 任务在跑"时才起卡片。
    enum Kind { case agent, download }

    private var currentKind: Kind?
    private var activity: Activity<LumenAIActivityAttributes>?
    /// 上次真正推送更新的时刻（节流用）
    private var lastPush = Date.distantPast
    /// 最短更新间隔。1 秒是经验值：比它更密对观感没有帮助，却会消耗系统给的更新预算。
    private let minInterval: TimeInterval = 1.0

    private init() {}

    /// 实时活动是否可用。不可用时所有调用都安全地变成空操作 ——
    /// 调用点不需要到处写 if（写了也容易漏，漏掉的那处就是崩溃）。
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool { activity != nil }

    /// 开始一场活动。重复调用是安全的（会把上一场结束掉）。
    func start(conversationTitle: String,
               state: LumenAIActivityAttributes.ContentState,
               kind: Kind = .agent) {
        guard isAvailable else { return }
        // 下载不抢 agent 的卡片：agent 任务是用户主动发起的、正在等的，
        // 而下载是背景活，谁在等谁优先。
        if kind == .download, currentKind == .agent { return }
        Task {
            // 先结束旧的：同屏两张卡片会把内容糊在一起
            await endAllStale()
            do {
                let attributes = LumenAIActivityAttributes(conversationTitle: conversationTitle)
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil)
                )
                currentKind = kind
                lastPush = Date()
            } catch {
                // 不弹错给用户：灵动岛只是"锦上添花"，申请不到不该打断任何正在做的事。
                print("[LiveActivity] 申请失败（不影响主流程）: \(error.localizedDescription)")
            }
        }
    }

    /// 更新状态。默认受 `minInterval` 节流；`force: true` 用于阶段切换这类
    /// 必须立刻可见的时刻（例如"完成 / 失败"）。
    func update(_ state: LumenAIActivityAttributes.ContentState, force: Bool = false) {
        guard isAvailable, let activity else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastPush) < minInterval { return }
        lastPush = now
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// 结束（带一个"结果状态"再收：直接消失会让用户来不及看到结论）
    func end(state: LumenAIActivityAttributes.ContentState? = nil,
             dismissAfter: TimeInterval = 4,
             kind: Kind? = nil) {
        // 指定 kind 时只有"当前卡片就是这一类"才收 —— 否则下载结束会把
        // 正在跑的 agent 卡片一起收掉，而 agent 那边还在等用户看进度。
        if let kind, currentKind != kind { return }
        guard let activity else { return }
        self.activity = nil
        currentKind = nil
        Task {
            let content = state.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(dismissAfter)))
        }
    }

    /// 清掉所有残留的活动。
    /// 为什么需要：App 被强杀时活动不会自动消失（它是系统的，不是我们的），
    /// 用户之后会在岛上一直看到一张永远不动的旧卡片。所以启动时清一次。
    func endAllStale() async {
        for a in Activity<LumenAIActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        currentKind = nil
    }
}
