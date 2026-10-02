import Foundation

/// Agent 一轮任务的**断点存档**。
///
/// 要解决的问题：agent 循环被打断之后，用户回来只看到一个停在半路的气泡，
/// 而唯一的出路是**把整件事重新说一遍** —— 前面已经跑完的工具调用、已经查到的信息
/// 全部作废。这个成本在长任务上尤其荒唐：它可能已经跑了十几轮、几十次工具调用。
///
/// 打断的来源有四种，都得能续：
///   1. 用户切到后台、系统把进程挂起（最常见）；
///   2. 网络抖了一下，某一轮生成失败；
///   3. App 被系统回收（内存压力）；
///   4. 用户自己按了停止（这种**不该**自动续 —— 见 `shouldAutoResume`）。
///
/// 设计要点：
/// - **只存必要的东西**：workingHistory + 轮次 + 已产生的工具调用 + 气泡 id。
///   不存模型、不存 UI 状态 —— 那些在续跑时由调用方重新提供，存了反而会有"两份真源"。
/// - **落盘而不是只放内存**：第 3 种打断（App 被回收）只有落盘才能救。
/// - **有次数上限**：反复自动续跑会把一个本来就没救的任务变成无限循环，
///   而且每次都烧电、烧额度。到上限就停下来把原因说清楚。
struct AgentRunCheckpoint: Codable, Sendable {

    /// 属于哪段对话（续跑时要切回去，否则会把内容写进别的对话）
    var conversationID: UUID
    /// 复用哪个 assistant 气泡（续跑的内容必须接在同一条气泡上）
    var bubbleID: UUID
    /// 中断时的工作历史快照
    var history: [ChatMessage]
    /// 中断时已经跑到第几轮
    var iteration: Int
    /// 中断时已经产生的工具调用（用于 UI 与统计）
    var toolCalls: [ChatMessage.ToolCall]
    /// 首次开始的时间
    var startedAt: Date
    /// 中断原因（给用户看）
    var reason: String
    /// 已经被自动续跑过几次
    var resumeCount: Int

    /// 最多自动续跑几次。
    ///
    /// 取 3 的理由：一次是"系统把我打断了"，两次是"网络真不稳"，
    /// 三次还在断就说明这件事在当前环境下跑不完 —— 继续续只是重复烧电。
    /// 到上限后**必须**明确告诉用户，而不是默默放弃（默默放弃正是我们要根除的那类行为）。
    static let maxAutoResume = 3

    var canAutoResume: Bool { resumeCount < Self.maxAutoResume }
}

/// 断点存档的落盘。
///
/// 单独一个类型而不是塞进 AgentService：它就是一个文件读写，
/// 和"agent 怎么跑"无关；塞进去会让 AgentService 再多一份不属于它的职责。
@MainActor
final class AgentCheckpointStore {
    static let shared = AgentCheckpointStore()

    private let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("agent_run_checkpoint.json")
    }()

    private init() {}

    func load() -> AgentRunCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 解不出来就当没有：一份读不动的存档不该让 App 在启动时报错，
        // 它最多只是丢了"续跑"这个便利，用户仍可手动重发。
        return try? JSONDecoder().decode(AgentRunCheckpoint.self, from: data)
    }

    func save(_ checkpoint: AgentRunCheckpoint) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 正常跑完（或用户主动放弃）时清掉 —— 不清的话下次启动会去续一个早就完成的任务。
    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}
