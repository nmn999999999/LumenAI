import Foundation

// MARK: - Tool 历史压缩（阶段 9）
//
// 问题：长 Agent 任务里上下文会无限增长成
//   ToolCall → ToolResult → ToolCall → ToolResult → …
// 每一轮都完整保留，几十轮后 prompt 被早期结果塞满。而模型真正需要的
// 往往只是"我之前做过什么、改过哪些文件、有哪些重要结论"，而不是每条原始输出。
//
// 做法（刻意保持轻量，不引入额外模型）：
//   - 识别「工具轮」= assistant(带 toolCalls) + 紧随其后的连续 tool 结果；
//   - 只在**工具结果累计 token 超过阈值**时才动手（短任务完全不受影响）；
//   - 保留最近 `keepRecentToolRounds` 轮完整原文；
//   - 更早的轮次压缩成一条 "Task State"（Files / Actions / Important Results），
//     替换掉原来那一段连续性历史（含中间的空转思考与提示，避免留下悬空引用）。
//
// 为什么在 `trimmedHistory`（每轮调用、只读生成 prompt）里做、而不是改写 `workingHistory`：
//   1. 不改动存档：断点续跑、UI 步骤面板仍能看到完整历史；
//   2. 不破坏会话隔离：压缩只影响"这一轮发给模型的内容"。
// 压缩文本只由**被折叠的那段旧消息**决定，因此同一段旧历史每轮产出相同摘要 ——
// 前缀稳定，KV cache 仍能在"最近未被折叠"的区间复用（阶段 10）。
enum ToolHistoryCompactor {

    struct Config: Sendable {
        /// 是否启用。
        var enabled: Bool = true
        /// 最近多少轮工具交互保留完整原文。
        var keepRecentToolRounds: Int = 2
        /// 工具结果累计估算 token 超过该值才开始压缩。
        var triggerToolResultTokens: Int = 1500
        /// Task State 文本上限（字符）。
        var maxTaskStateChars: Int = 1600

        init() {}
    }

    /// 把旧工具交互压缩成 Task State。不满足条件时原样返回（保证行为不变）。
    static func compact(_ history: [ChatMessage], config: Config = Config()) -> [ChatMessage] {
        guard config.enabled else { return history }

        // 1) 找出所有「工具轮」区间
        var rounds: [(start: Int, end: Int)] = []
        var i = 0
        while i < history.count {
            let m = history[i]
            if m.role == .assistant, !m.toolCalls.isEmpty {
                var j = i
                while j + 1 < history.count, history[j + 1].role == .tool { j += 1 }
                rounds.append((i, j))
                i = j + 1
            } else {
                i += 1
            }
        }
        guard rounds.count > config.keepRecentToolRounds else { return history }

        // 2) 压力信号：所有工具结果消息的估算 token。短任务不触发。
        let toolResultTokens = history
            .filter { $0.role == .tool }
            .reduce(0) { $0 + TokenEstimator.tokens(in: $1.content) }
        guard toolResultTokens > config.triggerToolResultTokens else { return history }

        // 3) 折叠除最近 N 轮以外的全部早期轮次（含它们之间的思考/提示）
        let foldCount = rounds.count - config.keepRecentToolRounds
        let foldStart = rounds[0].start
        let foldEnd = rounds[foldCount - 1].end
        guard foldStart < foldEnd, foldEnd < history.count else { return history }

        let state = makeTaskState(Array(history[foldStart...foldEnd]),
                                  maxChars: config.maxTaskStateChars)

        var out = Array(history[0..<foldStart])
        out.append(ChatMessage(role: .tool, content: state))
        out.append(contentsOf: history[(foldEnd + 1)...])
        return out
    }

    // MARK: - Task State 生成

    private static func makeTaskState(_ folded: [ChatMessage], maxChars: Int) -> String {
        var actions: [String] = []
        var seenActions = Set<String>()
        var files: [String] = []
        var seenFiles = Set<String>()
        var important: [String] = []
        var errorCount = 0

        for m in folded where m.role == .assistant {
            for c in m.toolCalls {
                if seenActions.insert(c.name).inserted { actions.append(c.name) }
                collectPaths(c.arguments, into: &files, seen: &seenFiles)

                if c.status == .error {
                    errorCount += 1
                    let firstLine = firstLine(of: c.result ?? "")
                    important.append("错误：\(c.name) → \(brief(firstLine, 100))")
                } else if let r = c.result, !r.isEmpty {
                    collectPaths(r, into: &files, seen: &seenFiles)
                    // 只收"短且信息量高"的结果首行，避免把长结果再抄一遍
                    let firstLine = firstLine(of: r)
                    if !firstLine.isEmpty, firstLine.count <= 120 {
                        important.append("\(c.name): \(brief(firstLine, 100))")
                    }
                }
            }
        }

        var sections: [String] = ["[Task State] 早期工具交互已压缩为摘要（最近几轮结果仍为原文）。"]
        if !files.isEmpty {
            sections.append("Files:\n" + files.prefix(20).map { "- \($0)" }.joined(separator: "\n"))
        }
        if !actions.isEmpty {
            sections.append("Actions:\n" + actions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !important.isEmpty {
            sections.append("Important Results:\n"
                + important.prefix(12).map { "- \($0)" }.joined(separator: "\n"))
        }
        if errorCount > 0 {
            sections.append("注意：以上有 \(errorCount) 次工具调用失败，不要盲目重复同一调用。")
        }
        sections.append("已经完成的步骤不要重做；需要更早的细节时用工具重新获取，不要凭印象作答。")

        var text = sections.joined(separator: "\n\n")
        if text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n…(Task State 已截断)…"
        }
        return text
    }

    // MARK: - 工具

    private static func firstLine(of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func brief(_ text: String, _ maxLength: Int) -> String {
        text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }

    /// 从文本中提取形似文件路径的 token（用于 Files 段落）。
    /// 每次现建正则：避免静态存储非 Sendable 的 NSRegularExpression 触发并发检查。
    private static func collectPaths(_ text: String, into files: inout [String],
                                     seen: inout Set<String>) {
        guard !text.isEmpty else { return }
        let exts = "swift|json|md|txt|py|js|ts|tsx|yaml|yml|plist|csv|log|sh|html|css|xml|toml|ini|conf"
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9_./~-]+\\.(?:\(exts))\\b") else { return }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let p = ns.substring(with: m.range)
            guard p.count <= 120 else { continue }
            if seen.insert(p).inserted { files.append(p) }
        }
    }
}