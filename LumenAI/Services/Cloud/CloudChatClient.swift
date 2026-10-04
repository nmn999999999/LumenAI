import Foundation

// MARK: - 云端消息模型

struct CloudMessage: Sendable {
    enum Role: String, Sendable { case system, user, assistant, tool }
    let role: Role
    let content: String
    /// 可选的多模态图片
    var images: [ChatMessage.ImageData] = []

    init(role: Role, content: String, images: [ChatMessage.ImageData] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

// MARK: - 错误

enum CloudError: LocalizedError, Sendable {
    case invalidURL
    case noAPIKey
    case httpError(Int, String)
    case networkError(String)
    case emptyResponse
    case invalidProvider

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 API 地址"
        case .noAPIKey: return "未配置 API Key，请先在「服务」页为当前 Provider 填写密钥"
        case .httpError(let code, let body):
            let snippet = String(body.prefix(500))
            return "HTTP \(code): \(snippet.isEmpty ? "未知错误" : snippet)"
        case .networkError(let msg): return "网络错误: \(msg)"
        case .emptyResponse: return "模型未返回任何内容"
        case .invalidProvider: return "Provider 配置无效"
        }
    }
}

// MARK: - 统一云端聊天客户端（provider-independent 流式层）

/// 三种协议的流式解码器 + 请求构造，统一输出文本增量。
/// 设计对应 StreamChunkDecoder：协议知识只存在于各 provider 实现中。
enum CloudChatClient {

    /// 判断是否为用户主动取消
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    // MARK: - 流式对话

    @MainActor
    static func stream(
        provider: ChatProvider,
        model: String,
        messages: [CloudMessage],
        temperature: Double?,
        maxTokens: Int?,
        extraHeaders: [String: String] = [:],
        extraBody: String? = nil,
        /// Agent 模式注入的工具定义:OpenAI/Anthropic/Gemini 三种协议会用各自的 native tool_call 形态。
        /// 传 nil 时按纯文本对话处理（不发送 tools 字段）。
        tools: [AgentToolDefinition]? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // 在 MainActor 上完成 Key 轮换，网络请求在后台线程执行
            let key = ProviderStore.shared.nextKey(for: provider)
            Task.detached(priority: .userInitiated) {
                do {
                    let mergedHeaders = provider.headers.merging(extraHeaders) { _, new in new }
                    switch provider.type {
                    case .openAI, .openAICompatible:
                        try await openAIStream(
                            provider: provider, model: model, key: key,
                            messages: messages, temperature: temperature, maxTokens: maxTokens,
                            headers: mergedHeaders, extraBody: extraBody, tools: tools,
                            continuation: continuation
                        )
                    case .gemini:
                        try await geminiStream(
                            provider: provider, model: model, key: key,
                            messages: messages, temperature: temperature, maxTokens: maxTokens,
                            headers: mergedHeaders, tools: tools, continuation: continuation
                        )
                    case .claude:
                        try await claudeStream(
                            provider: provider, model: model, key: key,
                            messages: messages, temperature: temperature, maxTokens: maxTokens,
                            headers: mergedHeaders, extraBody: extraBody, tools: tools,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch {
                    if isCancellation(error) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - 非流式对话（供 Agent / 标题生成等使用）

    @MainActor
    static func complete(
        provider: ChatProvider,
        model: String,
        messages: [CloudMessage],
        temperature: Double?,
        maxTokens: Int?
    ) async throws -> String {
        var result = ""
        let stream = stream(
            provider: provider, model: model, messages: messages,
            temperature: temperature, maxTokens: maxTokens
        )
        for try await token in stream {
            result += token
        }
        return result
    }

    // MARK: - OpenAI / 兼容端点

    private static func openAIStream(
        provider: ChatProvider, model: String, key: String?,
        messages: [CloudMessage], temperature: Double?, maxTokens: Int?,
        headers: [String: String], extraBody: String?,
        tools: [AgentToolDefinition]?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let key, !key.isEmpty else { throw CloudError.noAPIKey }
        guard let url = URL(string: provider.cleanBaseURL + "/chat/completions") else {
            throw CloudError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        var body: [String: Any] = [
            "model": model,
            "messages": openAIMessages(messages),
            "stream": true,
        ]
        if let temperature { body["temperature"] = temperature }
        if let maxTokens { body["max_tokens"] = maxTokens }

        // Native tool_calls 协议（Agent 模式 + 云端模型原生 function-call 支持）
        if let tools, !tools.isEmpty {
            body["tools"] = openAIToolsPayload(tools)
            body["tool_choice"] = "auto"
        }
        mergeExtraBody(extraBody, into: &body)

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // DeepSeek 等推理模型：reasoning_content 缓冲成 <think>，正文出现时先冲刷
        var thinkBuffer = ""
        var thinkFlushed = false
        func flushThink() {
            guard !thinkFlushed, !thinkBuffer.isEmpty else { return }
            thinkFlushed = true
            let wrapped = "\n<think>\n\(thinkBuffer)\n</think>\n\n"
            continuation.yield(wrapped)
        }

        try await streamSSE(request: request, continuation: continuation, onDone: {
            flushThink()
        }) { json in
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first {
                if let delta = first["delta"] as? [String: Any] {
                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        thinkBuffer += reasoning
                    }
                    if let content = delta["content"] as? String, !content.isEmpty {
                        flushThink()
                        continuation.yield(content)
                    }
                    // OpenAI native tool_calls（流式）：args 字段是 incremental，
                    // 用 onDone accumulator 一次性 yield 完整 JSON,避免流式增量把多个
                    // 半成品 args 串成多个闭合 JSON 让 AgentService 重复解析。
                }
                // 累积 native tool_calls：当 finish_reason=tool_calls 时,把所有函数的
                // name + 已累积 arguments 包装成 prose-style,让 AgentService.parseToolCall
                // (走 extractJSONObjects)也能消费 native flow。
                if let finish = first["finish_reason"] as? String, finish == "tool_calls" {
                    flushThink()
                    if let assistant = first["message"] as? [String: Any],
                       let tcs = assistant["tool_calls"] as? [[String: Any]] {
                        for tc in tcs {
                            if let fn = tc["function"] as? [String: Any] {
                                let name = (fn["name"] as? String) ?? ""
                                let args = (fn["arguments"] as? String) ?? "{}"
                                if !name.isEmpty {
                                    let payload = "<tool_call>\n{\"name\":\"\(name)\",\"arguments\":\(args)}\n</tool_call>"
                                    continuation.yield(payload)
                                }
                            }
                        }
                    }
                }
            }
            if let error = json["error"] as? [String: Any],
               let msg = error["message"] as? String {
                throw CloudError.httpError(200, msg)
            }
        }
    }

    // MARK: - OpenAI tools 协议

    /// OpenAI Chat Completions: tools 字段格式
    /// https://platform.openai.com/docs/guides/function-calling
    static func openAIToolsPayload(_ tools: [AgentToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            // 收集所有"必填"参数：参数描述里包含"(必填)" 字样的视为必填
            let requiredNames = tool.parameters.compactMap { name, schema -> String? in
                let desc = schema.description
                if desc.contains("必填") { return name }
                return nil
            }
            let params = tool.parameters.mapValues { schema -> [String: Any] in
                var d: [String: Any] = ["type": schema.type, "description": schema.description]
                if let enums = schema.enumValues, !enums.isEmpty { d["enum"] = enums }
                return d
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": params,
                        "required": requiredNames
                    ]
                ]
            ]
        }
    }

    // MARK: - Gemini

    private static func geminiStream(
        provider: ChatProvider, model: String, key: String?,
        messages: [CloudMessage], temperature: Double?, maxTokens: Int?,
        headers: [String: String],
        tools: [AgentToolDefinition]?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let key, !key.isEmpty else { throw CloudError.noAPIKey }
        let modelID = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        guard let url = URL(string:
            "\(provider.cleanBaseURL)/v1beta/models/\(modelID):streamGenerateContent?alt=sse&key=\(encodedKey)"
        ) else { throw CloudError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        var contents: [[String: Any]] = []
        var systemInstruction: String?
        for msg in messages {
            switch msg.role {
            case .system:
                systemInstruction = (systemInstruction ?? "") + msg.content
            case .assistant:
                contents.append(["role": "model", "parts": geminiParts(msg)])
            default:
                contents.append(["role": "user", "parts": geminiParts(msg)])
            }
        }

        var body: [String: Any] = ["contents": contents]
        if let systemInstruction, !systemInstruction.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        var generationConfig: [String: Any] = [:]
        if let temperature { generationConfig["temperature"] = temperature }
        if let maxTokens { generationConfig["maxOutputTokens"] = maxTokens }
        if !generationConfig.isEmpty { body["generationConfig"] = generationConfig }

        // Gemini native function-calling tools 字段
        // https://ai.google.dev/gemini-api/docs/function-calling
        if let tools, !tools.isEmpty {
            body["tools"] = geminiToolsPayload(tools)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await streamSSE(request: request, continuation: continuation, onDone: {}) { json in
            if let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        continuation.yield(text)
                    }
                    // Gemini functionCall → 转 prose-style 让 AgentService.parseToolCall 消费
                    if let fc = part["functionCall"] as? [String: Any],
                       let name = fc["name"] as? String {
                        let args = (fc["args"] as? [String: Any]) ?? [:]
                        let argsJSON = (try? JSONSerialization.data(withJSONObject: args)).flatMap {
                            String(data: $0, encoding: .utf8)
                        } ?? "{}"
                        let payload = "<tool_call>\n{\"name\":\"\(name)\",\"arguments\":\(argsJSON)}\n</tool_call>"
                        continuation.yield(payload)
                    }
                }
            }
            if let error = json["error"] as? [String: Any],
               let msg = error["message"] as? String {
                throw CloudError.httpError(200, msg)
            }
        }
    }

    /// Gemini tools 协议：functionDeclarations (与 Anthropic / OpenAI 不一样)
    static func geminiToolsPayload(_ tools: [AgentToolDefinition]) -> [String: Any] {
        let declarations: [[String: Any]] = tools.map { tool in
            let params = tool.parameters.mapValues { schema -> [String: Any] in
                var d: [String: Any] = ["type": schema.type, "description": schema.description]
                if let enums = schema.enumValues, !enums.isEmpty { d["enum"] = enums }
                return d
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": params,
                    "required": tool.parameters.keys.map { $0 }
                ]
            ]
        }
        return ["functionDeclarations": declarations]
    }

    private static func geminiParts(_ msg: CloudMessage) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        if !msg.images.isEmpty {
            for img in msg.images {
                parts.append([
                    "inline_data": [
                        "mime_type": img.mimeType,
                        "data": img.data.base64EncodedString(),
                    ]
                ])
            }
        }
        if !msg.content.isEmpty {
            parts.append(["text": msg.content])
        }
        return parts
    }

    // MARK: - Claude

    private static func claudeStream(
        provider: ChatProvider, model: String, key: String?,
        messages: [CloudMessage], temperature: Double?, maxTokens: Int?,
        headers: [String: String], extraBody: String?,
        tools: [AgentToolDefinition]?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let key, !key.isEmpty else { throw CloudError.noAPIKey }
        guard let url = URL(string: provider.cleanBaseURL + "/v1/messages") else {
            throw CloudError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(key)", forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        var apiMessages: [[String: Any]] = []
        var systemTexts: [String] = []
        for msg in messages {
            switch msg.role {
            case .system:
                systemTexts.append(msg.content)
            case .assistant, .user, .tool:
                apiMessages.append([
                    "role": msg.role == .assistant ? "assistant" : "user",
                    "content": claudeContent(msg),
                ])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": maxTokens ?? 4096,
            "stream": true,
        ]
        if !systemTexts.isEmpty { body["system"] = systemTexts.joined(separator: "\n") }
        if let temperature { body["temperature"] = temperature }
        // Anthropic native tool_use 协议
        // https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview
        if let tools, !tools.isEmpty {
            body["tools"] = claudeToolsPayload(tools)
        }
        mergeExtraBody(extraBody, into: &body)

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await streamSSE(request: request, continuation: continuation, onDone: {}) { json in
            if let type = json["type"] as? String {
                switch type {
                case "content_block_delta":
                    if let delta = json["delta"] as? [String: Any] {
                        if let text = delta["text"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                        // Anthropic 流式 tool_use：argsJSON 是 incremental 字符串,
                        // 用 onDone 处 message_stop 一次性 yield 完整 JSON
                        if delta["type"] as? String == "input_json_delta",
                           let partialJSON = delta["partial_json"] as? String, !partialJSON.isEmpty {
                            // incremental 暂存:onDone 时按 message 累积
                            ToolCallAccumulator.shared.append(partial: partialJSON)
                        }
                    }
                case "content_block_start":
                    if let block = json["content_block"] as? [String: Any],
                       block["type"] as? String == "tool_use",
                       let id = block["id"] as? String,
                       let name = block["name"] as? String {
                        ToolCallAccumulator.shared.begin(id: id, name: name)
                    }
                case "content_block_stop":
                    if let acc = ToolCallAccumulator.shared.flush() {
                        // 包装成 prose-style 让 AgentService.parseToolCall 消费
                        let payload = "<tool_call>\n{\"name\":\"\(acc.name)\",\"arguments\":\(acc.arguments)}\n</tool_call>"
                        continuation.yield(payload)
                    }
                case "message_stop":
                    ToolCallAccumulator.shared.reset()
                case "error":
                    if let error = json["error"] as? [String: Any],
                       let msg = error["message"] as? String {
                        throw CloudError.httpError(0, msg)
                    }
                default:
                    break
                }
            }
        }
    }

    /// Anthropic tools 协议：name + description + input_schema
    static func claudeToolsPayload(_ tools: [AgentToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            let params = tool.parameters.mapValues { schema -> [String: Any] in
                var d: [String: Any] = ["type": schema.type, "description": schema.description]
                if let enums = schema.enumValues, !enums.isEmpty { d["enum"] = enums }
                return d
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "input_schema": [
                    "type": "object",
                    "properties": params,
                    "required": tool.parameters.keys.map { $0 }
                ]
            ]
        }
    }

    // MARK: - 跨 provider 的 native tool_call 流式 accumulator
    /// Claude 的 tool_use 协议是流式返回(input_json_delta),
    /// 每块只给增量 JSON,要等到 content_block_stop 时才拿到完整 args。
    /// 用线程安全的 final class + 锁(因为 streamSSE 的 onJSON closure 不是 actor 上下文)。
    /// static shared 在多流并发时可能撞车;实际 Claude 流式一次只一个 tool_use,风险可控。
    final class ToolCallAccumulator: @unchecked Sendable {
        static let shared = ToolCallAccumulator()
        private let lock = NSLock()
        private var pending: (name: String, argsBuilder: String)?
        func begin(id: String, name: String) {
            lock.lock(); defer { lock.unlock() }
            pending = (name, "")
        }
        func append(partial: String) {
            lock.lock(); defer { lock.unlock() }
            if pending != nil { pending?.argsBuilder.append(partial) }
        }
        func flush() -> (name: String, arguments: String)? {
            lock.lock(); defer { lock.unlock() }
            guard let p = pending else { return nil }
            pending = nil
            return (p.name, p.argsBuilder.isEmpty ? "{}" : p.argsBuilder)
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            pending = nil
        }
    }

    private static func claudeContent(_ msg: CloudMessage) -> Any {
        if msg.images.isEmpty {
            return msg.content
        }
        var parts: [[String: Any]] = []
        for img in msg.images {
            parts.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": img.mimeType,
                    "data": img.data.base64EncodedString(),
                ],
            ])
        }
        if !msg.content.isEmpty {
            parts.append(["type": "text", "text": msg.content])
        }
        return parts
    }

    // MARK: - 消息构造（OpenAI）

    private static func openAIMessages(_ messages: [CloudMessage]) -> [[String: Any]] {
        messages.map { msg -> [String: Any] in
            let role: String
            switch msg.role {
            case .system: role = "system"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            case .user: role = "user"
            }
            if msg.images.isEmpty {
                return ["role": role, "content": msg.content]
            }
            var content: [[String: Any]] = []
            for img in msg.images {
                content.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(img.mimeType);base64,\(img.data.base64EncodedString())"
                    ],
                ])
            }
            if !msg.content.isEmpty {
                content.append(["type": "text", "text": msg.content])
            }
            return ["role": role, "content": content]
        }
    }

    // MARK: - SSE 通用解析

    private static func streamSSE(
        request: URLRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onDone: @escaping () -> Void,
        onJSON: @escaping ([String: Any]) throws -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.networkError("无效响应")
        }
        guard (200...299).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw CloudError.httpError(http.statusCode, String(data: errorData, encoding: .utf8) ?? "")
        }

        // 性能：用 bytes.lines 按行读取（内部缓冲、C 速度切行、整行 UTF-8 解码）。
        // 旧实现逐字节 append 且**每追加一个字节就从头 firstIndex(of: 0x0A) 找换行**，
        // 单行成本 O(行长²)，外加每字节一次异步序列迭代开销 —— 云端流式输出每个
        // token 都走这条路，是实测热点。
        // AsyncLineSequence 会剥掉行终止符（\n / \r\n），且流末尾未换行的最后一行
        // 也会照常产出，语义上覆盖了旧代码的"末尾残留数据"分支。
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("data:") {
                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    onDone()
                    return
                }
                guard let payloadData = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
                else { continue }
                try onJSON(json)
            }
        }
        onDone()
    }

    /// 解析并合并自定义请求体（Custom Requests）
    private static func mergeExtraBody(_ extra: String?, into body: inout [String: Any]) {
        guard let extra, !extra.isEmpty,
              let data = extra.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        for (k, v) in obj {
            // 不允许覆盖核心字段（model/messages/stream）
            if ["model", "messages", "stream"].contains(k) { continue }
            body[k] = v
        }
    }
}
