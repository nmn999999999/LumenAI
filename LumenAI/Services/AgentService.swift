import Foundation

@MainActor
final class AgentService: ObservableObject {

    struct Step: Identifiable {
        let id = UUID()
        var kind: Kind
        var detail: String

        enum Kind {
            case thinking      // 模型决定调用工具
            case executing     // 正在执行工具
            case result        // 工具结果
            case finalAnswer   // 最终回答
        }
    }

    /// 流式展示桥：Agent 循环过程中通过它把每一轮的「思考 / 正文 / 工具调用」实时推给聊天 UI。
    /// UI 负责创建与更新气泡；AgentService 只负责在正确的时机调用对应方法。
    /// 无桥（bridge == nil）时回退为「整轮收集后一次性返回」的旧行为，保证降级兼容。
    struct AgentDisplayBridge {
        /// 开始新一轮迭代：UI 创建一条 streaming 的 assistant 气泡并返回其 id。
        let beginIteration: () -> UUID
        /// 给指定气泡追加原始 token（含 `<think>` 标签，气泡会自动解析为思考/正文流）。
        let appendToken: (UUID, String) -> Void
        /// 当前轮解析出工具调用：把记录挂到该气泡（含结果），气泡内以可展开 chip 展示。
        let attachToolCall: (UUID, ChatMessage.ToolCall) -> Void
        /// 结束当前轮迭代：气泡停止 streaming（isStreaming = false）。
        let endIteration: (UUID) -> Void
        /// 请求用户授权执行 requiresApproval=true 的工具（SSH / MCP / 网络等副作用工具）。
        /// 返回 true = 用户允许执行；false = 拒绝（UI 展示"用户拒绝"并回填上下文继续循环）。
        let requestApproval: (UUID, ChatMessage.ToolCall) async -> Bool
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false

    /// 循环不设硬性轮数上限：正常终止条件是模型输出结束暗号（或生成失败/任务取消）。
    /// 但设一个很大的「软上限」兜底：防止模型永远不输出暗号导致死循环烧电。
    /// 到达软上限前一轮会先通知模型强制收尾；若仍无暗号则优雅退出并返回最后一轮内容。
    static let softIterationLimit = 50

    /// 工作历史上限（条数）。超过后丢弃最旧的对话消息（保留 system 工具说明），
    /// 防止超长 Agent 会话把 prompt 撑爆上下文、并降低反复重编码的开销。
    static let maxWorkingMessages = 48

    /// Agent 循环结束「暗号」：模型给出最终回答前必须先输出它，
    /// 循环据此判定"模型已收集够信息，可以结束"。
    static let endSignal = "[[FINAL_ANSWER]]"

    /// 检测暗号并提取最终回答。返回 nil 表示输出中没有暗号。
    /// 兼容暗号在前（`暗号+正文`）与在后（`正文+暗号`）两种写法。
    /// 暗号对用户永远隐藏——展示/返回的只有正文。
    static func extractFinalAnswer(from text: String) -> String? {
        guard text.range(of: endSignal, options: [.caseInsensitive]) != nil else { return nil }
        let cleaned = text
            .replacingOccurrences(
                of: endSignal, with: "\n",
                options: [.caseInsensitive]
            )
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只输出了暗号没有正文：交给上层兜底
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 去除推理模型（DeepSeek-R1 / Qwen3 等）的 `<think>…</think>` / `<reasoning>…</reasoning>` 块，
    /// 含未闭合的情况（生成被 max_tokens 截断或中止时常见）。
    /// Agent 模式下模型常把工具 JSON / 最终答案整段裹在思考块里，
    /// 若不剥离，`extractFinalAnswer` / `parseToolCall` 会把答案误判为"思考内容"而吞掉正文。


    /// 统一的思考块解析：返回 (思考内容, 正文答案)
    /// 兼容常见格式：<think>...<\/think> / <reasoning>...</reasoning> / 未闭合。
    /// 返回的 think 内容可能包含未闭合的尾部， caller 须自行判断。
    static func parseThinkBlock(_ text: String) -> (think: String, answer: String) {
        // 与 ChatMessage.parseThinkBlock 保持一致（<think> / <reasoning>，含未闭合），
        // 避免两套解析逻辑漂移导致思考块剥离不一致。
        ChatMessage.parseThinkBlock(text)
    }

    /// 去除推理模型的 think 块。
    /// 兼容常见格式：<think>...<\/think> / <reasoning>...</reasoning> / 未闭合。
    /// Agent 模式下模型常把工具 JSON / 最终答案整段裹在思考块里，
    /// 若不剥离，后续解析会把答案误判为"思考内容"而吞掉正文。
    static func stripThinkTags(_ text: String) -> String {
        let (_, answer) = parseThinkBlock(text)
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 Agent 原始输出清理为可展示给用户的正文：移除结束暗号、工具调用 JSON、markdown 围栏。
    /// 仅用于 Agent 轮次的气泡渲染；普通聊天内容不会经过此处。
    static func cleanDisplayText(_ text: String) -> String {
        // 1) 先移除结束暗号（不区分大小写）
        var result = text.replacingOccurrences(of: Self.endSignal, with: "", options: [.caseInsensitive])

        // 2) 移除 markdown 代码围栏标记
        result = result.replacingOccurrences(of: "```json", with: "", options: [.caseInsensitive])
        result = result.replacingOccurrences(of: "```", with: "")

        // 3) 移除工具调用 JSON：找到顶层 {...}，若包含 "name"/"arguments" 则去掉
        for candidate in Self.extractJSONObjects(in: result) {
            let lower = candidate.lowercased()
            if lower.contains("\"name\"") && lower.contains("\"arguments\"") {
                result = result.replacingOccurrences(of: candidate, with: "")
            }
        }

        // 4) 清理不完整的工具调用 JSON（流式输出中常见）：
        //    检测 "{\"name": 或 {"name": 开头但尚未闭合的 JSON 片段
        result = cleanPartialToolCallJSON(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 清理流式输出中不完整的工具调用 JSON 片段。
    /// 当模型正在输出工具调用 JSON 但尚未完成时，这些片段会显示在气泡中。
    private static func cleanPartialToolCallJSON(_ text: String) -> String {
        var result = text

        // 检测可能的工具调用 JSON 开始：{"name": 或 "name":
        // 从这个位置开始，如果后面没有完整的闭合 }，则移除从这里到结尾的内容
        let patterns = ["{\"name\":", "{\"name\":", "{ \"name\":", "{\n\"name\":"]
        for pattern in patterns {
            while let range = result.range(of: pattern, options: .caseInsensitive) {
                let afterStart = result[range.upperBound...]
                // 检查是否有完整的闭合（深度平衡的 }）
                var depth = 1
                var foundClose = false
                for ch in afterStart {
                    if ch == "{" { depth += 1 }
                    else if ch == "}" {
                        depth -= 1
                        if depth == 0 {
                            foundClose = true
                            break
                        }
                    }
                }
                if !foundClose {
                    // 没有找到闭合的 }，移除这个不完整的片段
                    result.removeSubrange(range.lowerBound..<result.endIndex)
                } else {
                    // 找到了闭合，但这个片段可能已经被上面的 extractJSONObjects 处理了
                    // 跳过这个位置避免无限循环
                    break
                }
            }
        }

        return result
    }

    /// 在对话中执行 Agent 循环，返回最终 assistant 消息内容与全部工具调用记录。
    /// 传入 `bridge` 时改为流式：每一轮迭代实时通过桥把思考/正文/工具调用推给 UI；
    /// 不传 `bridge` 则回退为整轮收集后一次性返回（降级兼容 / 测试用）。
    func run(
        history: [ChatMessage],
        settings: ModelSettings,
        toolsEnabledTools: [AgentToolDefinition] = BuiltInTools.defaultEnabledTools,
        llm: LLMService,
        bridge: AgentDisplayBridge? = nil
    ) async -> (content: String, toolCalls: [ChatMessage.ToolCall]) {

        steps.removeAll()
        isRunning = true
        defer { isRunning = false }

        var workingHistory = history
        var allToolCalls: [ChatMessage.ToolCall] = []
        var lastThinking: String?
        var iteration = 0

        while true {
            guard !Task.isCancelled else { break }
            iteration += 1

            // 软上限前一轮：通知模型这是最后一轮，必须收尾
            if iteration == Self.softIterationLimit {
                appendStep(.thinking, "已连续思考 \(iteration - 1) 轮未结束，通知模型收尾")
                workingHistory.append(ChatMessage(role: .tool, content: """
                你已连续思考很多轮。本轮是最后一轮：不要再调用工具，\
                立即输出 \(Self.endSignal)，然后基于以上所有信息给出最终回答正文。
                """))
            }
            // 超过软上限仍未结束：优雅退出，返回最后一轮内容
            if iteration > Self.softIterationLimit { break }

            let iterationID = bridge?.beginIteration()
            // 提示词分化（v0.3.45）：云端模型 → 全量工具目录 + 英文强化指令；
            // 本地模型 → 压缩目录（12 工具 + 短描述）+ 中文指令。
            let useCloud = llm.hasCloudSelection
            let promptMessages = withToolInstructions(
                history: Self.trimmedHistory(workingHistory),
                tools: toolsEnabledTools,
                useCloud: useCloud
            )

            var raw = ""
            do {
                if let bridge {
                    // 流式：逐 token 透传原始文本，气泡自动解析 <think> 思考块与正文
                    let stream = llm.streamChat(history: promptMessages, settings: settings)
                    for try await token in stream {
                        try Task.checkCancellation()
                        raw += token
                        bridge.appendToken(iterationID!, token)
                    }
                } else {
                    raw = try await llm.complete(messages: promptMessages, settings: settings)
                }
            } catch {
                let msg = "生成失败: \(error.localizedDescription)"
                if let id = iterationID { bridge?.endIteration(id) }
                appendStep(.finalAnswer, msg)
                return (msg, allToolCalls)
            }

            // 1) 结束暗号优先：在【原始文本】上检测，避免答案被裹在 <think> 内时
            //    被提前剥离思考块而连暗号一起丢失。命中后再对最终答案单独剥离思考块，
            //    保证正文干净、不被当成"思考内容"吞掉。
            if let pre = Self.extractFinalAnswer(from: raw) {
                let answer = Self.stripThinkTags(pre)
                appendStep(.finalAnswer, "检测到结束暗号，输出最终回答")
                if let id = iterationID { bridge?.endIteration(id) }
                return (answer, allToolCalls)
            }

            // 其余路径：推理模型会把工具 JSON 裹在 <think> 里，先剥离思考块再解析
            let content = Self.stripThinkTags(raw)

            // 2) 有效的工具调用：执行并把结果回填上下文，进入下一轮
            if let call = Self.parseToolCall(from: content) {
                let argsJSON = Self.compactJSON(call.arguments)
                appendStep(.thinking, "调用工具 \(call.name)(\(argsJSON))")
                appendStep(.executing, call.name)

                // 授权检查（opencode 风格）：requiresApproval=true 的工具（SSH / MCP / 网络等）
                // 先以 .awaitingApproval 状态挂到气泡，阻塞等用户决策；
                // 无桥（非交互 / 测试）时默认拒绝，绝不静默执行敏感操作。
                let definition = toolsEnabledTools.first { $0.name == call.name }
                let needsApproval = definition?.requiresApproval ?? false
                var record = ChatMessage.ToolCall(
                    id: UUID().uuidString,
                    name: call.name,
                    arguments: argsJSON,
                    status: needsApproval ? .awaitingApproval : .running
                    // title 留空：UI 各处均回退到 name，避免长描述挤占授权弹窗标题
                )
                if let id = iterationID { bridge?.attachToolCall(id, record) }

                var approved = true
                if needsApproval {
                    appendStep(.thinking, "等待用户授权 \(call.name)…")
                    if let bridge {
                        // 第一个参数是气泡 id（ChatView 当前忽略，仅透传 call）
                        approved = await bridge.requestApproval(iterationID ?? UUID(), record)
                    } else {
                        approved = false   // 无交互环境：默认拒绝
                    }
                }

                if approved {
                    record.status = .running
                    if let id = iterationID { bridge?.attachToolCall(id, record) }

                    let result = await BuiltInTools.executeWithFallbacks(toolName: call.name, argumentsJSON: argsJSON)
                    let limited = Self.limitResult(result)
                    record.result = limited
                    record.status = .complete
                    record.truncated = limited != result
                    allToolCalls.append(record)
                    appendStep(.result, "\(call.name) → \(limited)")
                    if let id = iterationID { bridge?.attachToolCall(id, record) }

                    // 把工具结果作为新一轮上下文
                    workingHistory.append(
                        ChatMessage(role: .assistant, content: content, toolCalls: [record])
                    )
                    workingHistory.append(
                        ChatMessage(role: .tool, content: "[\(call.name) 结果]\n\(limited)")
                    )
                } else {
                    // 用户拒绝：记录错误并回填上下文，让模型决定换路或直接回答
                    record.status = .error
                    record.result = "用户拒绝执行"
                    allToolCalls.append(record)
                    appendStep(.result, "\(call.name) 已被用户拒绝")
                    if let id = iterationID { bridge?.attachToolCall(id, record) }

                    workingHistory.append(
                        ChatMessage(role: .assistant, content: content, toolCalls: [record])
                    )
                    workingHistory.append(
                        ChatMessage(role: .tool, content: "[\(call.name) 结果]\n用户拒绝执行该工具，请根据情况换用其他工具或直接回答。")
                    )
                }
                if let id = iterationID { bridge?.endIteration(id) }
            } else {
                // 3) 无暗号、无有效工具调用：视为模型的中间思考，
                //    自动触发下一轮思考（思考内容展示在步骤里，不被吞掉）。
                lastThinking = content
                appendStep(.thinking, "思考：\(Self.brief(content))")
                if let id = iterationID { bridge?.endIteration(id) }

                workingHistory.append(ChatMessage(role: .assistant, content: content))

                // 若看起来是想调工具但 JSON 写坏了，顺带纠正格式
                let hint: String
                if Self.looksLikeToolCall(content, tools: toolsEnabledTools),
                   Self.looksLikeBrokenJSON(content) {
                    hint = """
                    你的输出看起来想调用工具，但不是合法 JSON。规则：
                    - 调用工具时只输出一个 JSON 对象：{"name": "<工具名>", "arguments": {...}}
                    - 继续思考就直接输出思考内容
                    - 得出最终结论时，先输出 \(Self.endSignal)，再输出最终回答正文
                    请继续。
                    """
                } else {
                    hint = """
                    继续。若需调用工具，只输出工具 JSON；
                    若已得出最终结论，先输出 \(Self.endSignal)，然后输出最终回答正文（正常中文）。
                    """
                }
                workingHistory.append(ChatMessage(role: .tool, content: hint))
            }
        }

        // 循环仅在「取消」或「软上限耗尽」时到达这里：返回最后一轮思考内容（保证不吞回答）
        if let last = lastThinking, !last.isEmpty {
            appendStep(.finalAnswer, "已停止（未输出结束暗号），返回最后一轮内容")
            return (last, allToolCalls)
        }

        let fallback = "已停止思考（达到轮数上限或被取消）。以上为当前结果。"
        appendStep(.finalAnswer, fallback)
        return (fallback, allToolCalls)
    }

    func reset() {
        steps.removeAll()
    }

    /// 把工作历史裁剪到最多 `maxWorkingMessages` 条：保留 system 消息（工具说明所在），
    /// 丢弃最旧的对话消息，保留最近的上下文。返回新的数组，不修改入参。
    private static func trimmedHistory(_ history: [ChatMessage]) -> [ChatMessage] {
        // 上限内无需裁剪
        if history.count <= maxWorkingMessages { return history }

        var system: ChatMessage?
        var rest: [ChatMessage] = []
        for m in history {
            if m.role == .system, system == nil {
                system = m          // system 只保留第一条（含工具说明）
            } else {
                rest.append(m)
            }
        }
        let keep = max(0, maxWorkingMessages - (system != nil ? 1 : 0))
        let tail = rest.suffix(keep)
        return (system.map { [$0] } ?? []) + Array(tail)
    }

    // MARK: - 工具说明注入

    /// 提示词分化（v0.3.45）：
    /// - 云端（useCloud=true）：完整工具目录 + 英文强化指令（GPT-4o/Claude/Gemini 对英文指令遵循更稳）
    /// - 本地（useCloud=false）：压缩目录（前 12 个核心工具 + 描述截 150 字）+ 中文指令，
    ///   防止 4B 级本地模型上下文被 33 个工具占满（解码失败/指令漂移）。
    private func withToolInstructions(
        history: [ChatMessage],
        tools: [AgentToolDefinition],
        useCloud: Bool
    ) -> [ChatMessage] {
        let maxTools = useCloud ? tools.count : 12
        let maxDesc = useCloud ? Int.max : 150

        // 本地模型：内置工具按「设置 → 工具」的勾选过滤（顺序也按用户选择，
        // 因为 note 被默认放在第 2 位，训练数据也是这个顺序）。
        // 云端：用全部内置工具 —— 过滤必须放在这里而不是调用方，
        // 否则云端也会被砍到 12 个（用户反馈过这个 bug）。
        // MCP / 插件工具不属于内置，不受勾选影响，照常附带。
        let selected: [AgentToolDefinition]
        if useCloud {
            selected = tools
        } else {
            let builtinNames = Set(BuiltInTools.allTools.map { $0.name })
            let external = tools.filter { !builtinNames.contains($0.name) }
            selected = ToolSettingsStore.shared.enabledTools() + external
        }

        let catalog = selected.prefix(maxTools).map { tool -> String in
            var desc = tool.description
            if desc.count > maxDesc { desc = String(desc.prefix(maxDesc)) + "…" }
            var lines = "- \(tool.name): \(desc)"
            if !tool.parameters.isEmpty {
                let params = tool.parameters.map { name, schema -> String in
                    var s = "  - \(name) (\(schema.type))"
                    if !schema.description.isEmpty { s += ": \(schema.description)" }
                    if let enums = schema.enumValues, !enums.isEmpty {
                        s += " [可选: \(enums.joined(separator: " / "))]"
                    }
                    return s
                }.joined(separator: "\n")
                lines += "\n  参数:\n\(params)"
            }
            return lines
        }.joined(separator: "\n")

        let instruction: String
        if useCloud {
            instruction = """
            ## Available Tools
            When you need to call a tool, output ONLY a single JSON object. Do not output any other text, explanation, or code fences:

            {"name": "<tool_name>", "arguments": {"<arg>": <value>, ...}}

            ## Rules
            1. Call at most ONE tool per turn; argument names must exactly match the tool definitions.
            2. Numbers as plain values (e.g. 5, 3.14); booleans as true/false; everything else as strings.
            3. Call a tool only when you need data, calculation, or an operation; otherwise finish (see END SIGNAL below).

            ## Multi-round Thinking & Execution
            You may take multiple turns: each turn you may call one tool, or output a pure thinking passage (without the end signal) — the system will let you continue and your thinking is preserved. Observe the tool results, then decide the next step.

            ## END SIGNAL (IMPORTANT)
            Once you have gathered enough information and are ready to give the final answer, you MUST first output the end signal:

            \(Self.endSignal)

            Then immediately output the final answer text, in the user's language.
            The end signal is the ONLY signal to end the loop: as long as you do not output it, the system assumes you are still thinking and will continue.

            ## Tool List
            \(catalog)

            Begin.
            """
        } else {
            instruction = """
            ## 你能调用的工具
            当需要调用工具时，只输出一个 JSON 对象，不要输出任何其他文字、解释或代码块：

            {"name": "<工具名>", "arguments": {"<参数名>": <值>, ...}}

            ## 调用规则
            1. 一次最多调用一个工具；参数名必须与工具定义完全一致。
            2. 数字参数直接写数值（如 5、3.14）；布尔写 true/false；其余一律写字符串。
            3. 需要查数据/算数/操作时才调用工具；否则直接结束（见下方结束暗号）。

            ## 多轮思考与执行
            你可以连续多轮：每轮可以调用一个工具，也可以输出一段纯思考内容（不带暗号）——
            系统会自动让你继续思考，你的思考会被保留。观察工具结果后再决定下一步。

            ## 结束暗号（重要！）
            当你已经收集到足够信息、准备给出最终回答时，必须先输出结束暗号：

            \(Self.endSignal)

            然后紧接着输出最终回答正文（正常中文）。
            暗号是循环结束的唯一信号：只要不输出暗号，系统就会认为你仍在思考并让你继续。

            ## 工具列表
            \(catalog)

            请开始。
            """
        }

        var messages = history
        if let sysIdx = messages.firstIndex(where: { $0.role == .system }) {
            messages[sysIdx].content += "\n\n" + instruction
        } else {
            messages.insert(ChatMessage(role: .system, content: instruction), at: 0)
        }
        return messages
    }

    // MARK: - 工具调用解析

    struct ParsedCall {
        let name: String
        let arguments: [String: Any]
    }

    static func parseToolCall(from text: String) -> ParsedCall? {
        // 去掉 markdown 代码围栏干扰后，寻找包含 name/arguments 的 JSON 对象
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for candidate in extractJSONObjects(in: cleaned) {
            guard let data = candidate.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String
            else { continue }

            // arguments 可能是对象，也可能被模型序列化成了字符串
            var args: [String: Any] = [:]
            if let dict = obj["arguments"] as? [String: Any] {
                args = dict
            } else if let str = obj["arguments"] as? String {
                if let d = str.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    args = parsed
                }
            }

            if BuiltInTools.allTools.contains(where: { $0.name == name }) {
                return ParsedCall(name: name, arguments: args)
            }
        }
        return nil
    }

    /// 结尾检测辅助：判断模型输出是否"看起来想调用工具"（但 JSON 解析失败）。
    /// 用于区分「工具调用格式错误（重试）」与「最终回答（结束）」。
    private static func looksLikeToolCall(_ text: String, tools: [AgentToolDefinition]) -> Bool {
        let lower = text.lowercased()
        if lower.contains("\"name\"") || lower.contains("\"arguments\"") { return true }
        return tools.contains { text.contains($0.name) }
    }

    /// 输出里确实有 JSON 花括号结构（而非普通文本里恰好提到工具名），
    /// 才值得让模型重试；否则直接按最终回答结束。
    private static func looksLikeBrokenJSON(_ text: String) -> Bool {
        text.contains("{") && text.contains("}")
    }

    /// 截断过长的工具结果，避免撑爆上下文。
    private static func limitResult(_ result: String, maxLength: Int = 2000) -> String {
        if result.count <= maxLength { return result }
        let head = String(result.prefix(maxLength))
        return head + "\n…(结果过长，已截断)"
    }

    /// 步骤面板里展示的思考摘要（截断，避免刷屏）。
    private static func brief(_ text: String, maxLength: Int = 300) -> String {
        let oneLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength)) + "…"
    }

    /// 粗略提取顶层平衡的 {...} 子串（快速路径：无花括号直接返回空）
    fileprivate static func extractJSONObjects(in text: String) -> [String] {
        guard text.contains("{") else { return [] }
        
        var results: [String] = []
        var depth = 0
        var start: String.Index?

        for i in text.indices {
            let ch = text[i]
            if ch == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        results.append(String(text[s...i]))
                        start = nil
                    }
                }
            }
        }
        return results
    }




    private static func compactJSON(_ dict: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else { return "\(dict)" }
        return String(data: data, encoding: .utf8) ?? "\(dict)"
    }

    private func appendStep(_ kind: Step.Kind, _ detail: String) {
        steps.append(Step(kind: kind, detail: detail))
    }
}
