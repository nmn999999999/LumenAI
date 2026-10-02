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
               state: LumenAIActivityAttributes.ContentState) {
        guard isAvailable else { return }
        Task {
            // 先结束旧的：同屏两张卡片会把内容糊在一起
            await endAllStale()
            do {
                let attributes = LumenAIActivityAttributes(conversationTitle: conversationTitle)
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil)
                )
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
             dismissAfter: TimeInterval = 4) {
        guard let activity else { return }
        self.activity = nil
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
    }
}
