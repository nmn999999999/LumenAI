import Foundation
import Combine

/// Provider 数据存储（多 Provider + 多 Key 轮换 + 内置 Provider）
@MainActor
final class ProviderStore: ObservableObject {

    static let shared = ProviderStore()

    @Published var providers: [ChatProvider] = [] {
        didSet { persist() }
    }

    /// 当前选中的云 Provider（nil = 使用本地 GGUF 模型）
    @Published var currentProviderID: UUID? {
        didSet { persistSelection() }
    }
    /// 当前选中的云模型名（跟随 currentProviderID）
    @Published var currentModel: String {
        didSet { persistSelection() }
    }

    /// 请求计数器：用于多 Key 轮换
    private var requestCounter = 0

    private let providersURL: URL
    private let selectionKey = "provider.selection.v1"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        providersURL = docs.appendingPathComponent("providers.json")
        currentModel = ""
        load()
        if providers.isEmpty {
            providers = Self.builtInProviders()
            migrateLegacyAPISettings()
        }
        loadSelection()
    }

    // MARK: - 访问

    var currentProvider: ChatProvider? {
        guard let id = currentProviderID else { return nil }
        return providers.first { $0.id == id && $0.enabled }
    }

    var hasCloudSelection: Bool {
        guard let p = currentProvider else { return false }
        return p.hasKey && !currentModel.isEmpty
    }

    func provider(id: UUID?) -> ChatProvider? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    /// 当前选择的展示文本（provider · model）
    var selectionText: String {
        guard let p = currentProvider else { return "" }
        return "\(p.name) · \(currentModel)"
    }

    /// 轮换取下一个可用的 API Key（multi-key load balancing）
    func nextKey(for provider: ChatProvider) -> String? {
        let keys = provider.apiKeys.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }
        requestCounter += 1
        return keys[requestCounter % keys.count]
    }

    // MARK: - 修改

    func upsert(_ provider: ChatProvider) {
        let isNew = !providers.contains { $0.id == provider.id }
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        // 只在**新增**时自动选中。
        // 原来对「编辑」也生效，于是用户只是给一个没在用的 Provider 改个名字或补上 Key
        // 并保存，聊天就被静默切过去；更糟的是只改了 currentProviderID、没同步
        // currentModel —— 顶部显示「新 Provider · 上一家的模型名」，下一条消息直接报
        // 模型不存在。自动选中必须把两个字段一起改。
        guard isNew, provider.enabled, provider.hasKey else { return }
        currentProviderID = provider.id
        if !provider.models.contains(currentModel) {
            currentModel = provider.models.first ?? ""
        }
    }

    func delete(_ provider: ChatProvider) {
        providers.removeAll { $0.id == provider.id }
        if currentProviderID == provider.id {
            currentProviderID = providers.first(where: { $0.enabled })?.id
            currentModel = currentProvider?.models.first ?? ""
        }
    }

    func select(providerID: UUID?, model: String) {
        currentProviderID = providerID
        currentModel = model
        if let idx = providers.firstIndex(where: { $0.id == providerID }) {
            providers[idx].lastUsedAt = Date()
            persist()
        }
    }

    func resetBuiltIns() {
        // 保留用户自定义 Provider，重置内置项
        let custom = providers.filter { !$0.isBuiltIn }
        var builtins = Self.builtInProviders()
        builtins.append(contentsOf: custom)
        providers = builtins
        // 内置项每次都是全新的 UUID，所以重置前指向内置项的 currentProviderID 会变成
        // 悬空指针 —— currentProvider 查不到，hasCloudSelection 变 false，聊天静默回退
        // 本地模型，用户完全不知道原因。这里必须重新校验一次选中状态。
        refreshSelectionAfterRestore()
        persist()
    }

    /// 恢复/导入后校验选中状态：当前选中 Provider 不存在时回退到第一个可用项
    func refreshSelectionAfterRestore() {
        if let current = currentProvider, providers.contains(where: { $0.id == current.id }) {
            return
        }
        if let first = providers.first(where: { $0.enabled && $0.hasKey }) {
            currentProviderID = first.id
            currentModel = first.models.first ?? ""
        } else {
            currentProviderID = nil
            currentModel = ""
        }
    }

    // MARK: - 内置 Provider（参考 内置 Provider 种子）

    static func builtInProviders() -> [ChatProvider] {
        [
            ChatProvider(
                name: "OpenAI",
                type: .openAI,
                baseURL: "https://api.openai.com/v1",
                models: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o3-mini"],
                isBuiltIn: true
            ),
            ChatProvider(
                name: "Google Gemini",
                type: .gemini,
                baseURL: "https://generativelanguage.googleapis.com",
                models: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash", "gemini-1.5-flash"],
                isBuiltIn: true
            ),
            ChatProvider(
                name: "Anthropic",
                type: .claude,
                baseURL: "https://api.anthropic.com",
                models: ["claude-sonnet-4-5", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022"],
                isBuiltIn: true
            ),
            ChatProvider(
                name: "DeepSeek",
                type: .openAICompatible,
                baseURL: "https://api.deepseek.com/v1",
                models: ["deepseek-chat", "deepseek-reasoner"],
                isBuiltIn: true
            ),
            ChatProvider(
                name: "硅基流动 SiliconFlow",
                type: .openAICompatible,
                baseURL: "https://api.siliconflow.cn/v1",
                models: ["Qwen/Qwen2.5-72B-Instruct", "deepseek-ai/DeepSeek-V3", "THUDM/glm-4-9b-chat"],
                isBuiltIn: true
            ),
            ChatProvider(
                name: "智谱 GLM",
                type: .openAICompatible,
                baseURL: "https://open.bigmodel.cn/api/paas/v4",
                models: ["glm-4-plus", "glm-4-flash", "glm-4-air"],
                isBuiltIn: true
            ),
            ChatProvider(
                name: "月之暗面 Moonshot",
                type: .openAICompatible,
                baseURL: "https://api.moonshot.cn/v1",
                models: ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"],
                isBuiltIn: true
            ),
            ChatProvider(
                name: "Ollama 本机",
                type: .openAICompatible,
                baseURL: "http://localhost:11434/v1",
                models: ["llama3.1", "qwen2.5"],
                isBuiltIn: true
            ),
        ]
    }

    // MARK: - 旧版 API 设置迁移（apiEndpoint/apiKey/apiModel → Provider）

    private func migrateLegacyAPISettings() {
        let settings = SettingsStorage.shared.settings
        guard settings.apiEnabled, !settings.apiEndpoint.isEmpty else { return }
        let endpoint = settings.apiEndpoint
            .replacingOccurrences(of: "/chat/completions", with: "")
            .replacingOccurrences(of: "/v1", with: "/v1")
        let provider = ChatProvider(
            name: "自定义 API（旧设置）",
            type: .openAICompatible,
            baseURL: endpoint,
            apiKeys: settings.apiKey.isEmpty ? [] : [settings.apiKey],
            models: settings.apiModel.isEmpty ? [] : [settings.apiModel],
            enabled: true
        )
        providers.append(provider)
        currentProviderID = provider.id
        currentModel = settings.apiModel
        persist()
        persistSelection()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: providersURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601 // 与 persist 的 iso8601 一致，否则 Date 解码失败导致数据被重置
        guard let decoded = try? decoder.decode([ChatProvider].self, from: data)
        else { return }
        providers = decoded
    }

    private func persist() {
        let snapshot = providers
        let url = providersURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadSelection() {
        guard let data = UserDefaults.standard.data(forKey: selectionKey),
              let decoded = try? JSONDecoder().decode(Selection.self, from: data)
        else {
            // 默认：若存在可用 Provider 则选中第一个
            if let first = providers.first(where: { $0.enabled && $0.hasKey }) {
                currentProviderID = first.id
                currentModel = first.models.first ?? ""
            }
            return
        }
        currentProviderID = decoded.providerID
        currentModel = decoded.model
    }

    private func persistSelection() {
        let sel = Selection(providerID: currentProviderID, model: currentModel)
        if let data = try? JSONEncoder().encode(sel) {
            UserDefaults.standard.set(data, forKey: selectionKey)
        }
    }

    private struct Selection: Codable {
        let providerID: UUID?
        let model: String
    }
}
