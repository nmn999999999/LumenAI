import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 手机协作（云端 API 版 · 无文件）
//
// 架构：**独立的 agent 跑在快捷指令里**。
//   · 快捷指令自循环：截屏 → 提取文本(OCR) → 用 `Get Contents of URL` 调云端 LLM →
//     拿到「下一步做什么」→ 展示给用户 → 用户照做 → 再来一轮。
//   · App 只负责两件事：① 保存云端配置（endpoint / model / key / 系统提示词）；
//     ② 用 `shortcuts://run-shortcut` 把配置当 input 传给快捷指令并启动它。
//
// **不落任何文件**：没有 inbox/outbox/events.jsonl。进度是内存态，可选用
// `lumenai://agent?report=` 回传（URL 参数，不写盘），或干脆只在快捷指令里展示。
//
// 为什么用 URL 传配置而不是文件/App Group：快捷指令唯一能「同步拿到回复」的通道是
// HTTP（Get Contents of URL）；配置是单向传给快捷指令的，用 run-shortcut 的 input 最干净。

@MainActor
final class MobileAgentBridge: ObservableObject {

    static let shared = MobileAgentBridge()

    // MARK: 云端配置（持久化到 UserDefaults；不写文件）

    /// OpenAI 兼容的 chat completions 端点，如 https://api.openai.com/v1/chat/completions
    @Published var endpoint: String { didSet { save() } }
    /// 模型名，如 gpt-4o-mini / qwen-plus / deepseek-chat
    @Published var model: String { didSet { save() } }
    /// 密钥（Bearer）。仅存本机 UserDefaults，随 input 传给快捷指令。
    @Published var apiKey: String { didSet { save() } }
    /// 交给快捷指令里那个 agent 的系统提示词。
    @Published var systemPrompt: String { didSet { save() } }
    /// 协作快捷指令名（与快捷指令 App 里一致）。
    @Published var shortcutName: String { didSet { save() } }

    // MARK: 进度（内存态，不落盘）

    struct Event: Identifiable, Equatable {
        enum Kind: String, Sendable { case start, step, guide, done, error }
        let id = UUID()
        let kind: Kind
        let text: String
        let at: Date
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var active = false
    @Published private(set) var stepIndex = 0
    @Published private(set) var currentGuidance: String?

    private static let keyPrefix = "mobileAgent."
    private static let defaultSystemPrompt = """
    你是一个手机操作助手。用户正在操作 iPhone，下面是当前屏幕的文字内容。
    请只输出「下一步该做什么」——要具体到点哪里或输入什么（例如「点击顶部的『设置』图标」）。
    如果任务已经完成，就输出「✅ 已完成」，不要输出别的内容。
    """

    private init() {
        let d = UserDefaults.standard
        endpoint = d.string(forKey: Self.keyPrefix + "endpoint") ?? "https://api.openai.com/v1/chat/completions"
        model = d.string(forKey: Self.keyPrefix + "model") ?? "gpt-4o-mini"
        apiKey = d.string(forKey: Self.keyPrefix + "apiKey") ?? ""
        systemPrompt = d.string(forKey: Self.keyPrefix + "systemPrompt") ?? Self.defaultSystemPrompt
        shortcutName = d.string(forKey: Self.keyPrefix + "shortcutName") ?? "LumenAgent"
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(endpoint, forKey: Self.keyPrefix + "endpoint")
        d.set(model, forKey: Self.keyPrefix + "model")
        d.set(apiKey, forKey: Self.keyPrefix + "apiKey")
        d.set(systemPrompt, forKey: Self.keyPrefix + "systemPrompt")
        d.set(shortcutName, forKey: Self.keyPrefix + "shortcutName")
    }

    // MARK: 传给快捷指令的配置

    /// 供快捷指令解析的配置 JSON（endpoint / model / key / systemPrompt）。
    var configJSON: String {
        let obj: [String: Any] = [
            "endpoint": endpoint,
            "model": model,
            "apiKey": apiKey,
            "systemPrompt": systemPrompt,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: 启动 / 消息

    /// 启动协作：把配置当 input 传给快捷指令并运行。
    func startSession(extraMessage: String = "") {
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        active = true
        stepIndex = 0
        events = []
        append(.start, "启动协作快捷指令「\(name)」")
        launchShortcut(named: name, text: configJSON)
    }

    func endSession() {
        active = false
        append(.done, "会话结束")
    }

    /// 给快捷指令发一条消息（作为新的 input 重新运行它）。
    func sendMessageToShortcut(_ message: String) {
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        append(.guide, message)
        launchShortcut(named: name, text: message)
    }

    private func launchShortcut(named name: String, text: String) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let urlString = text.isEmpty
            ? "shortcuts://run-shortcut?name=\(enc(name))"
            : "shortcuts://run-shortcut?name=\(enc(name))&input=text&text=\(enc(text))"
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: 进度（内存 + 可选 URL 回传）

    /// App 内 Agent 的 `phone` 工具 `op=guide` 调用：把指引推给用户看。
    func publishGuidance(_ text: String) {
        currentGuidance = text
        append(.guide, text)
    }

    /// 处理 `lumenai://agent?report=...&step=...`（快捷指令可选地回传进度；不写盘）。
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "lumenai",
              url.host?.lowercased() == "agent" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? {
            comps?.queryItems?.first(where: { $0.name == name })?.value
        }
        if let report = q("report"), !report.isEmpty {
            active = true
            append(.step, report)
        }
        if let guide = q("guide"), !guide.isEmpty {
            active = true
            publishGuidance(guide)
        }
        if (q("action") ?? "") == "end" { endSession() }
    }

    private func append(_ kind: Event.Kind, _ text: String) {
        events.append(Event(kind: kind, text: text, at: Date()))
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }
}
