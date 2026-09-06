import Foundation

/// Provider 协议类型（的多 Provider 架构）
enum ProviderType: String, Codable, CaseIterable, Sendable {
    case openAI            // OpenAI Chat Completions 官方协议
    case openAICompatible  // 任意 OpenAI 兼容端点（DeepSeek / SiliconFlow / Ollama 等）
    case gemini            // Google Gemini (generativelanguage.googleapis.com)
    case claude            // Anthropic Claude (api.anthropic.com)

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI 兼容"
        case .gemini: return "Google Gemini"
        case .claude: return "Anthropic Claude"
        }
    }

    /// 默认 Base URL（openAICompatible 为空，由用户填写）
    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .openAICompatible: return ""
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .claude: return "https://api.anthropic.com"
        }
    }

    /// 该 Provider 内置的推荐模型 ID 列表，新建 Provider 时预填,
    /// 让用户点保存就能用,不用先去找模型名字。
    var defaultModels: [String] {
        switch self {
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "o3-mini", "gpt-4-turbo"]
        case .openAICompatible:
            // 通用 OpenAI 兼容端点常见默认值,用户按自己用的服务增删
            return ["deepseek-chat", "deepseek-reasoner", "qwen-plus"]
        case .gemini:
            return ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"]
        case .claude:
            return [
                "claude-sonnet-4-20250514",
                "claude-3-7-sonnet-latest",
                "claude-3-5-haiku-latest"
            ]
        }
    }

    /// CloudChatClient 在该协议下走哪种工具调用规范:
    /// - openAI:        OpenAI Chat Completions tool_calls (choices[0].message.tool_calls)
    /// - openAI_compat: 同 OpenAI(所有 OpenAI 兼容端点共用,本地模型 prose-style fallback 仍兼容)
    /// - claude:        Anthropic Messages tool_use / tool_result blocks
    /// - gemini:        Gemini functionDeclarations / functionResponse parts
    /// 由 ProviderStore / CloudChatClient 根据该字段决定 payload 形态。
    var toolCallProtocol: ToolCallProtocol {
        switch self {
        case .openAI, .openAICompatible: return .openAI
        case .claude: return .anthropic
        case .gemini: return .gemini
        }
    }
}

/// 三种协议的 tool_call 模式
enum ToolCallProtocol: String, Codable, Sendable {
    case openAI      // OpenAI / 兼容
    case anthropic   // Claude
    case gemini      // Gemini
}

/// 云端 Chat Provider（多 Provider、多 Key 轮换、自定义请求头/请求体）
struct ChatProvider: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var type: ProviderType
    var baseURL: String
    /// 多 API Key：请求时轮换使用（的 multi-key load balancing）
    var apiKeys: [String]
    /// 自定义请求头（如 x-api-key 等）
    var headers: [String: String]
    /// 追加到请求体的自定义 JSON（字符串形式，会解析后合并）
    var extraBody: String
    /// 可用模型列表（分号分隔存储为数组）
    var models: [String]
    /// 是否内置 Provider（内置的可删除，但可一键重置）
    var isBuiltIn: Bool
    var enabled: Bool
    var createdAt: Date
    var lastUsedAt: Date?
    /// 云端文生图模型名（如 "gpt-image-1" / "black-forest-labs/FLUX.1-schnell"）。
    /// 为空 = 未启用该 Provider 的生图能力；填充后聊天输入框可用 `/draw <prompt>` 生成图片。
    var imageModel: String

    init(
        id: UUID = UUID(),
        name: String,
        type: ProviderType,
        baseURL: String = "",
        apiKeys: [String] = [],
        headers: [String: String] = [:],
        extraBody: String = "",
        models: [String] = [],
        isBuiltIn: Bool = false,
        enabled: Bool = true,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        imageModel: String = ""
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.apiKeys = apiKeys
        self.headers = headers
        self.extraBody = extraBody
        self.models = models
        self.isBuiltIn = isBuiltIn
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.imageModel = imageModel
    }

    var primaryKey: String { apiKeys.first(where: { !$0.isEmpty }) ?? "" }
    var hasKey: Bool { apiKeys.contains(where: { !$0.isEmpty }) }

    /// 展示用 baseURL（无尾斜杠）
    var cleanBaseURL: String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Codable（手动：imageModel 是后加字段，旧存档缺失时用默认值，避免整表解码失败）
    private enum CodingKeys: String, CodingKey {
        case id, name, type, baseURL, apiKeys, headers, extraBody, models,
             isBuiltIn, enabled, createdAt, lastUsedAt, imageModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(ProviderType.self, forKey: .type)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKeys = try c.decodeIfPresent([String].self, forKey: .apiKeys) ?? []
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        extraBody = try c.decodeIfPresent(String.self, forKey: .extraBody) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        imageModel = try c.decodeIfPresent(String.self, forKey: .imageModel) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(apiKeys, forKey: .apiKeys)
        try c.encode(headers, forKey: .headers)
        try c.encode(extraBody, forKey: .extraBody)
        try c.encode(models, forKey: .models)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try c.encode(imageModel, forKey: .imageModel)
    }
}
