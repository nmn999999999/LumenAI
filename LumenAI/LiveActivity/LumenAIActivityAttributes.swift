import Foundation
import ActivityKit

/// 灵动岛 / 锁屏实时活动的**共享数据契约**。
///
/// ⚠️ 这个文件会被**两个 target 各编译一次**（主 App 与 Widget 扩展），
/// 所以它不能依赖任何一个 target 里的其它类型 —— 一旦引用了 app 内的东西，
/// 扩展那边就编译不过，而报错会指向"找不到类型"，跟灵动岛本身毫无关系。
///
/// 为什么用 `ActivityAttributes` 而不是自定义推送结构：ActivityKit 要求
/// 「不变的属性（attributes）+ 会变的状态（ContentState）」分开，
/// 因为系统只对 ContentState 做增量更新，attributes 在整场活动里是恒定的。
struct LumenAIActivityAttributes: ActivityAttributes {

    /// 会变的状态。每一帧都必须是**小而完整**的：ActivityKit 会把整个 ContentState
    /// 序列化后交给扩展，塞大字符串（比如工具输出）会让更新变慢甚至被系统丢弃。
    struct ContentState: Codable, Hashable {
        /// 当前正在做什么（已拟人化，直接显示给用户）
        var title: String
        /// 阶段
        var phase: Phase
        /// 第几轮 / 共几轮（共几轮常常不知道，所以是可选）
        var step: Int
        var totalSteps: Int?
        /// 补充说明（例如"下载中断，3 秒后自动重试"）
        var detail: String?
        /// 进度（0...1）。仅下载/生成这类有明确进度的阶段才有
        var progress: Double?
        /// 本轮开始时间，用于在岛上显示"已经跑了多久"
        var startedAt: Date
    }

    enum Phase: String, Codable, Hashable {
        case thinking
        case tool
        case downloading
        case done
        case failed
        /// 被系统打断但**会自己续上**（切后台超时、进程被回收）。
        ///
        /// 为什么必须和 `failed` 分开：两者在用户眼里是完全不同的两件事 ——
        /// failed = "这件事没做成，你得重来"，paused = "我还在，回来自动接着干"。
        /// 用同一个红色失败态去表示"暂停"，用户会以为任务废了，然后手动重发，
        /// 而重发恰恰会和自动续跑撞在一起（同一段对话、同一条气泡）。
        case paused
    }

    /// 不变的属性：这场活动属于哪段对话。
    /// 放 attributes 而不是 ContentState，是因为它在整场活动里不会变，
    /// 放进会变的部分等于每次更新都白传一遍。
    var conversationTitle: String
}

extension LumenAIActivityAttributes.ContentState {
    /// 给 UI 用的短状态词。集中在一处，避免灵动岛三种布局各写一套措辞。
    var shortPhaseText: String {
        switch phase {
        case .thinking:    return "思考中"
        case .tool:        return "执行工具"
        case .downloading: return "下载中"
        case .done:        return "已完成"
        case .failed:      return "已中断"
        case .paused:      return "已暂停"
        }
    }

    /// 该用什么图标（SF Symbol 名）。同样集中一处。
    var symbolName: String {
        switch phase {
        case .thinking:    return "brain"
        case .tool:        return "wrench.and.screwdriver.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .done:        return "checkmark.circle.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        case .paused:      return "pause.circle.fill"
        }
    }
}
