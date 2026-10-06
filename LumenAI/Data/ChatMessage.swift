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
    var files: [FileData]
    var toolCalls: [ToolCall]
    /// 生成速度提示（如 "⚡ 14.3 tok/s"）；nil 不显示。可选字段，旧存档解码兼容。
    var speedText: String?

    struct ImageData: Codable, Sendable, Equatable {
        let data: Data
        let mimeType: String

        #if canImport(UIKit)
        var cgImage: CGImage? {
            guard let uiImage = UIImage(data: data) else { return nil }
            return uiImage.cgImage
        }
        #endif
    }

    /// 文件附件（工作区内的文件路径 + 元数据，不存二进制）。
    /// 为什么不存 Data：文件可能很大（几 MB 甚至几百 MB），把二进制塞进 conversations.json
    /// 会让它瞬间膨胀到几百 MB、存储/解码全卡死。这里只存相对路径 + 元数据，
    /// 真正需要内容时通过 `FileManagerService` 再读。
    struct FileData: Codable, Sendable, Equatable, Identifiable {
        let id: UUID = UUID()
        let name: String
        let path: String         // 相对于 Documents/Files 的相对路径
        let mimeType: String
        let size: Int64
        let createdAt: Date
        var isTextPreviewable: Bool = false  // 解码时根据 mimeType 推断
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
        files: [FileData] = [],
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
        self.files = files
        self.toolCalls = toolCalls
        self.speedText = speedText
    }

    // 显式实现 Codable：所有可选/后加字段用 decodeIfPresent 兼容旧存档
    // 否则编译器的自动实现对每个字段都是必填 → 旧版本（无 speedText）的
    // conversations.json 解码失败 → try? 静默吞错 → 用户对话历史整个丢失。
    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, isStreaming, isAgentRound, images, files, toolCalls, speedText
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
        self.files = try c.decodeIfPresent([FileData].self, forKey: .files) ?? []
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
        try c.encode(files, forKey: .files)
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

    // MARK: - Agent 轮次分段（think / 工具调用 / 正文 按出现顺序穿插）

    /// Agent 气泡里的一个片段。顺序 = 模型真实输出顺序，
    /// 渲染时按此顺序交替摆放思考块与工具 chip，而不是把所有 think 合并到顶部。
    enum AgentPart: Equatable, Sendable {
        /// 一段思考。`closed=false` 表示 `</think>` 还没闭合（流式中 / 被截断）。
        case think(String, closed: Bool)
        /// 对应 `message.toolCalls[i]` 的 chip。
        case toolCall(Int)
        /// 普通正文（渲染前会过 `AgentService.cleanDisplayText`）。
        case text(String)
    }

    /// 把 `content` 切成按序排列的片段，并给每个工具调用 JSON 找到它对应的 chip。
    ///
    /// 为什么不能沿用 `parseThinkBlock`：那个函数把**所有** think 合成一个字符串、
    /// 把所有正文合成另一个 —— 多轮 agent 于是变成"一坨思考 + 一坨正文 + 一排 chip"，
    /// 思考与它所驱动的那次工具调用完全对不上号（用户反馈的"分区不连贯"）。
    ///
    /// 切分规则与**运行时语义**保持一致（见 `AgentService.run`）：
    ///   · 工具 JSON 必须在 think 块**之外**才会被执行（运行时先 `stripThinkTags` 再解析），
    ///     所以 think 块内部一律整块当作思考，不去里面找 JSON；
    ///   · JSON 出现的位置 = 那一轮发生的位置，因此 chip 就渲染在它前面那段思考之后。
    ///
    /// chip 对齐用「名字 + 顺序」匹配而不是纯序号：未知工具/被去重的调用在 `content`
    /// 里有 JSON 却没有 chip，按序号对齐会让后面的 chip 全部错位一格。
    /// 匹配不到的 JSON 当作正文（随后会被 `cleanDisplayText` 清掉，与现状一致）；
    /// 没被任何 JSON 用到的 chip 追加到末尾，保证一个都不丢。
    var agentParts: [AgentPart] {
        Self.splitAgentParts(content: content, toolCalls: toolCalls)
    }

    static func splitAgentParts(content: String, toolCalls: [ToolCall]) -> [AgentPart] {
        guard !content.isEmpty else {
            return toolCalls.indices.map { .toolCall($0) }
        }
        var parts: [AgentPart] = []
        var rest = Substring(content)
        var used = Set<Int>()
        let ws = CharacterSet.whitespacesAndNewlines

        func appendText(_ t: Substring) {
            let trimmed = t.trimmingCharacters(in: ws)
            if !trimmed.isEmpty { parts.append(.text(String(trimmed))) }
        }

        while !rest.isEmpty {
            let openRange = Self.nextThinkOpen(in: rest)
            let jsonStart = Self.nextToolJSONStart(in: rest)

            // think 块与 JSON 同时出现时取位置更靠前的那个；位置相同按 think 处理
            let thinkFirst: Bool = {
                guard let open = openRange else { return false }
                guard let json = jsonStart else { return true }
                return open.lowerBound <= json
            }()
            if thinkFirst, let open = openRange {
                // 整块吃掉，块内不解析 JSON —— 与运行时"先 stripThinkTags 再解析"一致
                appendText(rest[rest.startIndex..<open.lowerBound])
                let afterOpen = rest[open.upperBound...]
                if let close = Self.nextThinkClose(in: afterOpen) {
                    appendThink(parts: &parts, afterOpen[afterOpen.startIndex..<close.lowerBound], closed: true)
                    rest = afterOpen[close.upperBound...]
                } else {
                    appendThink(parts: &parts, afterOpen, closed: false)
                    rest = Substring("")
                }
                continue
            }
            if let start = jsonStart {
                appendText(rest[rest.startIndex..<start])
                guard let end = Self.toolJSONEnd(in: rest[start...]) else {
                    // 未闭合的 JSON（流式中）：当正文，渲染侧会清掉
                    appendText(rest[start...])
                    break
                }
                let object = rest[start...end]
                let name = Self.toolJSONName(in: object)
                if let idx = toolCalls.indices.first(where: {
                    !used.contains($0) && toolCalls[$0].name == name
                }) {
                    used.insert(idx)
                    parts.append(.toolCall(idx))
                }
                rest = rest[rest.index(after: end)...]
                continue
            }
            appendText(rest)
            break
        }

        // 没被 JSON 用上的 chip（未知工具 / 去重 / 存量旧档）：补到末尾，别丢
        for i in toolCalls.indices where !used.contains(i) {
            parts.append(.toolCall(i))
        }
        return parts
    }

    /// think 块内部文本进片段（空思考不占位，避免流式起手的空块撑出一个空折叠区）。
    private static func appendThink(parts: inout [AgentPart], _ think: Substring, closed: Bool) {
        let trimmed = think.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(.think(String(trimmed), closed: closed)) }
    }

    private static func nextThinkOpen(in s: Substring) -> Range<String.Index>? {
        s.range(of: "<think>", options: [.caseInsensitive])
            ?? s.range(of: "<reasoning>", options: [.caseInsensitive])
    }

    private static func nextThinkClose(in s: Substring) -> Range<String.Index>? {
        s.range(of: "</think>", options: [.caseInsensitive])
            ?? s.range(of: "</reasoning>", options: [.caseInsensitive])
    }

    /// 找下一个工具调用 JSON 的起点：`{` + 可选空白 + `"name"`。
    private static func nextToolJSONStart(in s: Substring) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "{" {
                var j = s.index(after: i)
                while j < s.endIndex, s[j].isWhitespace { j = s.index(after: j) }
                if j < s.endIndex, s[j...].hasPrefix("\"name\"") { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// 从 JSON 起点做括号配平，返回最后一个 `}` 的索引（未闭合返回 nil）。
    private static func toolJSONEnd(in s: Substring) -> String.Index? {
        var depth = 0
        var i = s.startIndex
        var inString = false
        var escaped = false
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// 从工具 JSON 里取出 `"name"` 的字符串值。
    private static func toolJSONName(in s: Substring) -> String? {
        guard let key = s.range(of: "\"name\"") else { return nil }
        var i = key.upperBound
        while i < s.endIndex, s[i].isWhitespace || s[i] == ":" { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "\"" else { return nil }
        i = s.index(after: i)
        var name = ""
        while i < s.endIndex, s[i] != "\"" {
            if s[i] == "\\", s.index(after: i) < s.endIndex {
                i = s.index(after: i)
            }
            name.append(s[i])
            i = s.index(after: i)
        }
        return name.isEmpty ? nil : name
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
