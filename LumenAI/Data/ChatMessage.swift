import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// `Equatable` 不是可有可无的装饰：聊天页的 `MessageBubble` 会在父视图重建时
/// 重新求值 body，而流式期间父视图每 80ms 就重建一次。没有 Equatable，SwiftUI 只能
/// 老老实实把**可见的每一条**气泡都重算一遍（含 Markdown 重排）；有了它才能用
/// `.equatable()` 让"内容没变的那些"整棵子树跳过。字段全是值类型/字符串/数组，
/// 合成实现即可 —— 不要去手写，手写迟早会漏掉新加的字段。
struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var isStreaming: Bool
    var isAgentRound: Bool
    var images: [ImageData]
    var toolCalls: [ToolCall]
    /// 生成速度提示（如 "⚡ 14.3 tok/s"）；nil 不显示。可选字段，旧存档解码兼容。
    var speedText: String?

    struct ImageData: Codable, Sendable, Equatable {
        let data: Data
        let mimeType: String

        var cgImage: CGImage? {
            guard let uiImage = UIImage(data: data) else { return nil }
            return uiImage.cgImage
        }
    }

    /// opencode 风格的 ToolPart 状态机：
    /// `.pending` — 已解析工具调用、还没开始执行
    /// `.running` — 工具正在执行（长任务时显示等待 spinner）
    /// `.complete` — 执行成功（含结果字符串）
    /// `.error` — 执行失败（result 字段含错误信息）
    /// `.awaitingApproval` — 工具需要用户授权（requiresApproval=true，进入前弹窗）
    struct ToolCall: Codable, Sendable, Identifiable, Equatable {
        enum Status: String, Codable, Sendable, Equatable {
            case pending, running, awaitingApproval
            case complete, error
        }
        let id: String
        let name: String
        let arguments: String
        var result: String?
        var status: Status = .complete
        var title: String?
        var truncated: Bool = false

        // MARK: - 可观测性字段（v0.3.51 新增，供上层填充）
        //
        // 为什么加：原来只有 id/name/arguments/result/status/title/truncated，
        // 事后再看一条历史对话，**无法回答**"这次是哪个工具慢、哪个工具失败多、
        // 失败到底是因为超时还是被用户拒绝还是沙盒拦了路径" —— status 只有
        // complete/error 两态，error 的原因全被压进 result 字符串里，只能靠人读文本。
        //
        // 全部是 `Optional`（或带默认值），且都在 CodingKeys 里用 decodeIfPresent 解码：
        // 老对话存档里没有这些键 → 解出 nil → **不会**解码失败。
        // 反过来，新版本写出的多字段 JSON 被老版本 App 读到时，Codable 会忽略
        // 未知键，所以向前兼容（新档能被旧版本打开，只是看不到这些信息）。

        /// 工具开始执行的时刻（上层在发起调用前写入）
        var startedAt: Date?
        /// 工具结束的时刻（成功 / 失败 / 被拒绝都写）
        var finishedAt: Date?
        /// 执行耗时（毫秒）。优先取这个字段，缺失时 durationDescription 会用
        /// startedAt/finishedAt 现算，所以上层只填时间戳也能看到耗时。
        var durationMs: Int?
        /// 进程/命令退出码：当前只有 `shell` 这类"真执行外部命令"的工具能给出
        /// （ShellSandbox 的 (text, exitCode) 里就有）；纯网络/纯计算工具留 nil。
        var exitCode: Int?
        /// 机器可读的失败原因码，便于统计"失败原因分布"。
        /// 建议取值（上层约定，别塞自由文本）："timeout" | "cancelled" | "denied"
        /// （用户拒绝授权）| "sandbox_denied"（路径越界被沙盒拦下）| "not_found"
        /// （工具不存在）| "invalid_args" | "network" | "unknown"。
        var errorCode: String?

        /// 耗时的人类可读描述，例："850ms" / "1.2s" / "2m3s"。
        /// 没有 durationMs 时用 startedAt/finishedAt 现算；两者都没有则返回 nil
        /// （UI 可以据此决定不显示耗时标签，而不是显示 "0ms" 误导用户）。
        var durationDescription: String? {
            let ms: Int
            if let durationMs {
                ms = durationMs
            } else if let startedAt, let finishedAt {
                ms = Int((finishedAt.timeIntervalSince(startedAt) * 1000).rounded())
            } else {
                return nil
            }
            if ms < 0 { return nil }                     // 时钟回拨等异常值：宁可不显示
            if ms < 1000 { return "\(ms)ms" }
            // 59.95s 起进位到分钟档，避免显示 "60.0s" 这种别扭的值；
            // 分钟档先把总秒数四舍五入再拆，避免出现 "0m0s"
            if ms < 59_950 { return String(format: "%.1fs", Double(ms) / 1000) }
            let totalSeconds = Int((Double(ms) / 1000).rounded())
            return "\(totalSeconds / 60)m\(totalSeconds % 60)s"
        }

        /// Memberwise init: 给 AgentService / UI 等代码路径直接构造。
        /// status 默认 .complete（与旧行为一致，向上兼容）：
        /// 历史已保存的 toolCalls 全部走 decode(from:) → 不经此 init → 不受影响。
        /// 新的可观测性参数都排在最后且都有默认值，所以现有调用点无需改动。
        init(
            id: String,
            name: String,
            arguments: String,
            result: String? = nil,
            status: Status = .complete,
            title: String? = nil,
            truncated: Bool = false,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            durationMs: Int? = nil,
            exitCode: Int? = nil,
            errorCode: String? = nil
        ) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.result = result
            self.status = status
            self.title = title
            self.truncated = truncated
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.durationMs = durationMs
            self.exitCode = exitCode
            self.errorCode = errorCode
        }

        // 显式 Codable：旧存档没有 status/title/truncated，用 decodeIfPresent 兜底
        private enum CodingKeys: String, CodingKey {
            case id, name, arguments, result, status, title, truncated
            // 可观测性字段（v0.3.51 新增）
            case startedAt, finishedAt, durationMs, exitCode, errorCode
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.arguments = try c.decode(String.self, forKey: .arguments)
            self.result = try c.decodeIfPresent(String.self, forKey: .result)
            // status 在 v0.3.11 之前都是隐式 complete；解析旧存档时默认 complete
            let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? "complete"
            self.status = Status(rawValue: raw) ?? .complete
            self.title = try c.decodeIfPresent(String.self, forKey: .title)
            self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
            // 旧存档没有这五个键 → decodeIfPresent 返回 nil → 不抛错，旧对话照常打开。
            // （这就是为什么不能用合成的 init(from:)：合成实现把每个非 Optional 字段
            //   当必填，缺键直接抛 keyNotFound，配合上层的 `try?` 会静默吞掉整份历史。）
            self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
            self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
            self.exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
            self.errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(arguments, forKey: .arguments)
            try c.encodeIfPresent(result, forKey: .result)
            try c.encode(status.rawValue, forKey: .status)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encode(truncated, forKey: .truncated)
            // 全部用 encodeIfPresent：为 nil 时不写键，旧档写回去也不会多出 null 噪音
            try c.encodeIfPresent(startedAt, forKey: .startedAt)
            try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
            try c.encodeIfPresent(exitCode, forKey: .exitCode)
            try c.encodeIfPresent(errorCode, forKey: .errorCode)
        }
    }

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isAgentRound: Bool = false,
        images: [ImageData] = [],
        toolCalls: [ToolCall] = [],
        speedText: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isAgentRound = isAgentRound
        self.images = images
        self.toolCalls = toolCalls
        self.speedText = speedText
    }

    // 显式实现 Codable：所有可选/后加字段用 decodeIfPresent 兼容旧存档
    // 否则编译器的自动实现对每个字段都是必填 → 旧版本（无 speedText）的
    // conversations.json 解码失败 → try? 静默吞错 → 用户对话历史整个丢失。
    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, isStreaming, isAgentRound, images, toolCalls, speedText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(MessageRole.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        self.isAgentRound = try c.decodeIfPresent(Bool.self, forKey: .isAgentRound) ?? false
        self.images = try c.decodeIfPresent([ImageData].self, forKey: .images) ?? []
        self.toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        self.speedText = try c.decodeIfPresent(String.self, forKey: .speedText)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encode(isAgentRound, forKey: .isAgentRound)
        try c.encode(images, forKey: .images)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(speedText, forKey: .speedText)
    }
}

struct Conversation: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    var modelName: String?

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        modelName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelName = modelName
    }

    // 显式 Codable：防御旧存档字段缺失（modelName/updatedAt 都是后加的）
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, modelName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.messages = try c.decode([ChatMessage].self, forKey: .messages)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(messages, forKey: .messages)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(modelName, forKey: .modelName)
    }

    mutating func updateTitle() {
        if let firstUserMessage = messages.first(where: { $0.role == .user }) {
            title = String(firstUserMessage.content.prefix(30))
        }
    }
}

// MARK: - think 块解析（DeepSeek-R1 / Qwen3 风格的 <think>…</think>）

extension ChatMessage {
    /// 思考内容（不含标签）。流式中若 `</think>` 尚未出现，未闭合部分也算作思考内容。
    var thinkContent: String? {
        let parsed = Self.parseThinkBlock(content)
        return parsed.think.isEmpty ? nil : parsed.think
    }

    /// 展示给用户的正文字（已剔除 think 块）。
    var visibleContent: String {
        Self.parseThinkBlock(content).answer
    }

    /// 是否仍处于思考阶段（存在未闭合的 think 标签）。
    var isThinking: Bool {
        let lower = content.lowercased()
        let hasOpen = lower.contains("<think>") || lower.contains("<reasoning>")
        guard hasOpen else { return false }
        let hasClose = lower.contains("</think>") || lower.contains("</reasoning>")
        return !hasClose
    }

    static func parseThinkBlock(_ content: String) -> (think: String, answer: String) {
        var think = ""
        var answer = ""
        var rest = Substring(content)

        while true {
            let open = rest.range(of: "<think>", options: [.caseInsensitive])
                ?? rest.range(of: "<reasoning>", options: [.caseInsensitive])
            guard let open else {
                answer += rest
                break
            }
            answer += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: "</think>", options: [.caseInsensitive])
                ?? afterOpen.range(of: "</reasoning>", options: [.caseInsensitive]) {
                think += afterOpen[afterOpen.startIndex..<close.lowerBound]
                rest = afterOpen[close.upperBound...]
            } else {
                think += afterOpen
                break
            }
        }

        let ws = CharacterSet.whitespacesAndNewlines
        return (
            think.trimmingCharacters(in: ws),
            answer.trimmingCharacters(in: ws)
        )
    }
}
