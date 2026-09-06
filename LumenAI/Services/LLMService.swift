import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 错误定义

enum LLMError: LocalizedError, Sendable {
    case modelNotLoaded
    case generationFailed(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "模型未加载，请先在「模型」页下载并加载一个 GGUF 模型"
        case .generationFailed(let msg):
            return "生成失败: \(msg)"
        case .loadFailed(let msg):
            return "模型加载失败: \(msg)"
        }
    }
}

// MARK: - 引擎协议（隔离第三方库依赖）

protocol LLMEngine: AnyObject, Sendable {
    var modelURL: URL { get }
    /// 该引擎是否具备图片理解能力（本地=加载了 mmproj 多模态投影器）。
    var supportsVision: Bool { get }
    /// 流式生成。messages 为渲染好的对话；images 可为空（多模态时使用）。
    func stream(
        messages: [EngineMessage],
        settings: ModelSettings,
        images: [CGImage]
    ) -> AsyncThrowingStream<String, Error>
}

struct EngineMessage: Sendable {
    enum Role: String, Sendable {
        case system, user, assistant, tool
    }
    let role: Role
    let content: String
}

// MARK: - LLMService 门面

@MainActor
final class LLMService: ObservableObject {

    enum EngineState: Equatable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String)
        case apiMode(String)  // API 模式就绪
    }

    @Published private(set) var state: EngineState = .idle
    @Published private(set) var isGenerating = false
    @Published var partialOutput = ""

    private var engine: LLMEngine?
    private var generationTask: Task<Void, Never>?

    var isModelReady: Bool {
        if case .ready = state { return true }
        if case .apiMode = state { return true }
        return false
    }

    /// 是否已选择可用的云端 Provider + 模型（多 Provider 模式）
    var hasCloudSelection: Bool {
        ProviderStore.shared.hasCloudSelection
    }

    /// 当前可用的云 Provider（选中且已配置密钥）
    var currentCloudProvider: ChatProvider? {
        ProviderStore.shared.currentProvider
    }

    var currentCloudModel: String {
        ProviderStore.shared.currentModel
    }

    var isApiMode: Bool {
        if case .apiMode = state { return true }
        return false
    }

    var loadedModelName: String? {
        if case .ready(let name) = state { return name }
        if case .loading(let name) = state { return name }
        if case .apiMode(let name) = state { return name }
        return nil
    }

    /// 当前生效引擎是否支持图片理解。
    /// - 云端：OpenAI/Gemini/Claude 协议均带 image 走 base64，假设所选模型支持视觉（多数旗舰支持）。
    /// - 本地：取决于加载的引擎是否附带 mmproj 多模态投影器（纯文本模型如 OpenELM/Qwen3 无）。
    var supportsVision: Bool {
        if hasCloudSelection { return true }
        return engine?.supportsVision ?? false
    }

    // MARK: 加载 / 卸载

    func load(url: URL, displayName: String) async {
        unload()
        state = .loading(displayName)
        do {
            let engine = try await makeLlamaEngine(url: url)
            self.engine = engine
            state = .ready(displayName)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 切换到 API 模式
    func enableApiMode(settings: ModelSettings) {
        unload()
        let name = settings.apiModel.isEmpty ? "API 模式" : settings.apiModel
        state = .apiMode(name)
    }

    func unload() {
        // 先取消所有正在进行的生成任务
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        partialOutput = ""
        
        // 保存引擎引用，清空状态后再释放
        let oldEngine = engine
        engine = nil
        state = .idle
        
        // 延迟释放引擎，给后台任务时间退出
        if let oldEngine {
            Task.detached(priority: .utility) {
                // 等待一小段时间让正在进行的任务完成
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                _ = oldEngine // 确保引擎在此线程释放
            }
        }
    }

    func stopGeneration() {
        generationTask?.cancel()
        isGenerating = false
    }

    // MARK: 纯文本流式对话（无工具）

    func streamChat(
        history: [ChatMessage],
        settings: ModelSettings,
        images: [CGImage] = [],
        tools: [AgentToolDefinition] = []
    ) -> AsyncThrowingStream<String, Error> {
        // 云端 Provider 模式（多 Provider）
        if hasCloudSelection, let provider = currentCloudProvider {
            return streamCloud(
                provider: provider, model: currentCloudModel,
                history: history, settings: settings, images: images,
                tools: tools
            )
        }

        // 旧 API 模式
        if settings.apiEnabled, case .apiMode = state {
            return streamChatAPI(history: history, settings: settings)
        }

        // 本地模式
        let engine = tryRequireEngine()
        let msgs = toEngineMessages(history, settings: settings)
        return engine.stream(messages: msgs, settings: settings, images: images)
    }

    /// 云端 Provider 流式对话（OpenAI / Gemini / Claude）
    func streamCloud(
        provider: ChatProvider,
        model: String,
        history: [ChatMessage],
        settings: ModelSettings,
        images: [CGImage] = [],
        tools: [AgentToolDefinition] = []
    ) -> AsyncThrowingStream<String, Error> {
        let cloudMessages = makeCloudMessages(history, settings: settings)
        // 仅在 Agent 模式 + 用户真传了 tool 定义时启用 native flow(避免普通对话误注入)
        let effectiveTools: [AgentToolDefinition] = tools.isEmpty ? [] : tools
        return CloudChatClient.stream(
            provider: provider,
            model: model,
            messages: cloudMessages,
            temperature: settings.temperature,
            maxTokens: settings.apiMaxTokens,
            tools: effectiveTools.isEmpty ? nil : effectiveTools
        )
    }

    /// 云端单轮流式调用，聚合返回完整文本
    func completeCloud(
        provider: ChatProvider,
        model: String,
        history: [ChatMessage],
        settings: ModelSettings,
        images: [CGImage] = []
    ) async throws -> String {
        let cloudMessages = makeCloudMessages(history, settings: settings)
        return try await CloudChatClient.complete(
            provider: provider,
            model: model,
            messages: cloudMessages,
            temperature: settings.temperature,
            maxTokens: settings.apiMaxTokens
        )
    }

    /// API 模式流式对话
    private func streamChatAPI(
        history: [ChatMessage],
        settings: ModelSettings
    ) -> AsyncThrowingStream<String, Error> {
        let messages = history.map { msg -> [String: String] in
            var dict: [String: String] = [:]
            switch msg.role {
            case .user: dict["role"] = "user"
            case .assistant: dict["role"] = "assistant"
            case .system: dict["role"] = "system"
            case .tool: dict["role"] = "user"  // 工具结果作为用户消息
            }
            dict["content"] = msg.content
            return dict
        }
        return APIService.shared.streamChat(messages: messages, settings: settings)
    }

    /// 供 Agent 使用：带可选图片的单轮流式调用，聚合返回完整文本。
    func complete(
        messages: [ChatMessage],
        settings: ModelSettings,
        images: [CGImage] = []
    ) async throws -> String {
        // 云端 Provider 模式
        if hasCloudSelection, let provider = currentCloudProvider {
            return try await completeCloud(
                provider: provider,
                model: currentCloudModel,
                history: messages,
                settings: settings,
                images: images
            )
        }

        // API 模式
        if settings.apiEnabled, case .apiMode = state {
            return try await completeAPI(messages: messages, settings: settings)
        }
        
        // 本地模式
        let engine = tryRequireEngine()
        let msgs = toEngineMessages(messages, settings: settings)
        var result = ""
        for try await token in engine.stream(messages: msgs, settings: settings, images: images) {
            try Task.checkCancellation()
            result += token
        }
        return result
    }

    /// API 模式非流式调用
    private func completeAPI(
        messages: [ChatMessage],
        settings: ModelSettings
    ) async throws -> String {
        let msgDicts = messages.map { msg -> [String: String] in
            var dict: [String: String] = [:]
            switch msg.role {
            case .user: dict["role"] = "user"
            case .assistant: dict["role"] = "assistant"
            case .system: dict["role"] = "system"
            case .tool: dict["role"] = "user"
            }
            dict["content"] = msg.content
            return dict
        }
        return try await APIService.shared.complete(messages: msgDicts, settings: settings)
    }

    /// 多模态：图片 + 提问
    func describe(image: CGImage, prompt: String, settings: ModelSettings) async throws -> String {
        let user = ChatMessage(role: .user, content: prompt)
        return try await complete(messages: [user], settings: settings, images: [image])
    }

    // MARK: 私有辅助

    private func tryRequireEngine() -> LLMEngine {
        if let engine { return engine }
        return EchoEngine()
    }

    private func toEngineMessages(_ messages: [ChatMessage], settings: ModelSettings) -> [EngineMessage] {
        var result: [EngineMessage] = []
        // 若消息里已含 system（例如 Agent 注入了工具说明），保留它，不再重复添加设置里的系统提示词
        let hasSystem = messages.contains { $0.role == .system }
        if !hasSystem, !settings.systemPrompt.isEmpty {
            result.append(EngineMessage(role: .system, content: settings.systemPrompt))
        }
        for m in messages {
            switch m.role {
            case .user:
                result.append(.init(role: .user, content: m.content))
            case .assistant:
                result.append(.init(role: .assistant, content: m.content))
            case .tool:
                result.append(.init(role: .tool, content: m.content))
            case .system:
                result.append(.init(role: .system, content: m.content))
            }
        }
        return result
    }

    /// 渲染为云端协议消息（含图片，供 OpenAI / Gemini / Claude）
    func makeCloudMessages(_ messages: [ChatMessage], settings: ModelSettings) -> [CloudMessage] {
        var result: [CloudMessage] = []
        let hasSystem = messages.contains { $0.role == .system }
        if !hasSystem, !settings.systemPrompt.isEmpty {
            result.append(.init(role: .system, content: settings.systemPrompt))
        }
        for m in messages {
            switch m.role {
            case .user:
                // user 消息 content 为空但有图片：OpenAI/Gemini/Claude 都要求 content 字段存在
                let content = m.content.isEmpty && !m.images.isEmpty ? "（附图片）" : m.content
                result.append(.init(role: .user, content: content, images: m.images))
            case .assistant:
                // assistant content 不能为空（OpenAI 拒空 assistant message），
                // 改用单一空格避免 HTTP 400。
                let content = m.content.isEmpty ? " " : m.content
                result.append(.init(role: .assistant, content: content))
            case .tool:
                // OpenAI tool message 必须带 tool_call_id,且必须对应上面 assistant.tool_calls[i].id。
                // 本地模型(DeepSeek-R1/Qwen3)用 <think>...JSON... 这种 prose 风格调用工具,
                // 没生成 tool_calls,直接传 role=tool 会让 provider 报 HTTP 400 "messages with
                // role 'tool' must be a response to a preceeding message with 'tool_calls'".
                // 兜底：把 tool 结果包装成 user-role 消息,加上 [工具结果] 前缀,云端模型
                // 仍能拿到上下文,继续生成 — 不依赖严格的 tool_calls 协议。
                result.append(.init(role: .user, content: "[工具执行结果]\n" + m.content))
            case .system:
                result.append(.init(role: .system, content: m.content))
            }
        }
        return result
    }

    /// 创建 llama.cpp(GGUF) 引擎（本地推理，支持多模态）。
    /// 注意：`LlamaSwiftEngine.init` 内部是同步阻塞的 C 调用 `llama_bridge_load_model`
    /// （含 ggml/Metal 后端初始化），耗时数百毫秒。若在主线程执行会卡 UI
    /// （见 UIKit-runloop 卡顿报告）。用 detached 切到后台线程跑，
    /// 引擎创建完成后再回到调用方 actor（MainActor）写 @Published 状态。
    private func makeLlamaEngine(url: URL) async throws -> LLMEngine {
        let settings = SettingsStorage.shared.settings
        // Metal 自动加速：按设备内存 + 上下文长度推荐 GPU offload 层数（防 OOM）
        let gpuLayers = settings.useMetalAuto
            ? Self.recommendedGpuLayers(contextLength: settings.contextLength)
            : settings.gpuLayers
        return try await Task.detached(priority: .userInitiated) {
            try await LlamaSwiftEngine(modelURL: url, gpuLayers: Int32(gpuLayers))
        }.value
    }

    /// 设备内存（GB）
    static var deviceRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    /// 按设备内存 + 上下文长度推荐 Metal GPU offload 层数：
    /// - <6GB 设备：纯 CPU（Metal 极易 OOM）
    /// - 6GB：16 层；≥8GB：32 层
    /// - 上下文越长 KV 缓存越大，相应降档（4096+ → 1/4，2048+ → 1/2）
    static func recommendedGpuLayers(contextLength: Int) -> Int {
        let ram = deviceRAMGB
        let base: Int
        switch ram {
        case 8...: base = 32
        case 6..<8: base = 16
        default: return 0
        }
        if contextLength > 4096 { return max(0, base / 4) }
        if contextLength > 2048 { return max(0, base / 2) }
        return base
    }
}

// MARK: - 演示引擎（未接入真实模型时保证 App 可运行）

final class EchoEngine: LLMEngine, @unchecked Sendable {
    let modelURL = URL(fileURLWithPath: "/dev/null")
    let supportsVision = false

    func stream(
        messages: [EngineMessage],
        settings: ModelSettings,
        images: [CGImage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""
                let reply = """
                ⚠️ 当前处于演示模式（未集成 LLM.swift 或模型未加载）。

                收到消息: \(lastUser.prefix(120))

                请在「模型」页下载/导入 GGUF 模型后重新加载；
                并按 README 添加 LLM.swift 依赖以启用真实推理。
                """
                for chunk in reply.split(separator: "", omittingEmptySubsequences: true) {
                    continuation.yield(String(chunk))
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
                continuation.finish()
            }
        }
    }
}
