import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 手机协作（方案 B：agent 在 App 内 + 官方 x-callback-url）
//
// 官方机制（Apple Shortcuts 使用手册已文档化）：
//   · 启动：shortcuts://x-callback-url/run-shortcut?name=<采集指令>&x-success=lumenai://agent
//   · 快捷指令跑完，会把**文本输出**（最后一个动作的结果）作为 `result` 参数追加到 x-success，
//     即回调打开 `lumenai://agent?result=<OCR 文本>`（无需文件、无需本地服务器）。
//
// 分工：
//   · 快捷指令（LumenCapture，只有两个动作）：截屏 → 从图像中提取文本。输出即屏幕文字。
//   · App（本类）：收到屏幕文字 → 调云端 LLM 得到「下一步做什么」→ 展示给用户 →
//     用户照着操作 → 点「继续」→ App 再次启动采集指令，循环。
//
// 为什么这样更稳：快捷指令里**不再**包含 HTTP/JSON/循环等复杂动作（那些 `.shortcut`
// 属性表没有官方规范、极易写错）。agent 逻辑全在可编译、可验证的 Swift 里。

@MainActor
final class MobileAgentBridge: ObservableObject {

    static let shared = MobileAgentBridge()

    // MARK: 配置（持久化到 UserDefaults；不写文件）

    /// 采集快捷指令名（只有「截屏 → 提取文本」两个动作）。
    @Published var shortcutName: String { didSet { save() } }
    /// 用户的目标（交给 LLM 的上下文）。
    @Published var task: String { didSet { save() } }
    /// OpenAI 兼容的 chat completions 端点。
    @Published var endpoint: String { didSet { save() } }
    @Published var model: String { didSet { save() } }
    @Published var apiKey: String { didSet { save() } }
    @Published var systemPrompt: String { didSet { save() } }

    // MARK: 进度（内存态，不落盘）

    struct Event: Identifiable, Equatable {
        enum Kind: String, Sendable { case start, screen, guide, error, done }
        let id = UUID()
        let kind: Kind
        let text: String
        let at: Date
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var active = false
    @Published private(set) var stepIndex = 0
    @Published private(set) var currentGuidance: String?
    @Published private(set) var lastScreen: String = ""
    @Published private(set) var isDeciding = false

    private static let kp = "mobileAgent."
    private static let defaultSystemPrompt = """
    你是一个手机操作助手。用户会给你当前屏幕上的文字内容和他的目标。
    请只输出「下一步该做什么」，要具体到点哪里或输入什么（例如「点击顶部的『设置』」）。
    如果目标已经完成，只输出「✅ 已完成」。
    """

    private init() {
        let d = UserDefaults.standard
        shortcutName = d.string(forKey: Self.kp + "captureShortcut") ?? "LumenCapture"
        task = d.string(forKey: Self.kp + "task") ?? ""
        endpoint = d.string(forKey: Self.kp + "endpoint") ?? "https://api.openai.com/v1/chat/completions"
        model = d.string(forKey: Self.kp + "model") ?? "gpt-4o-mini"
        apiKey = d.string(forKey: Self.kp + "apiKey") ?? ""
        systemPrompt = d.string(forKey: Self.kp + "systemPrompt") ?? Self.defaultSystemPrompt
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(shortcutName, forKey: Self.kp + "captureShortcut")
        d.set(task, forKey: Self.kp + "task")
        d.set(endpoint, forKey: Self.kp + "endpoint")
        d.set(model, forKey: Self.kp + "model")
        d.set(apiKey, forKey: Self.kp + "apiKey")
        d.set(systemPrompt, forKey: Self.kp + "systemPrompt")
    }

    // MARK: 会话

    func startSession() {
        active = true
        stepIndex = 0
        events = []
        currentGuidance = nil
        lastScreen = ""
        append(.start, "开始协作：\(task.isEmpty ? "（未填写目标）" : task)")
        launchCapture()
    }

    /// 用户照做后点「继续」：再截一屏。
    func continueLoop() {
        guard active else { return }
        launchCapture()
    }

    func endSession() {
        active = false
        append(.done, "会话结束")
    }

    /// 启动采集快捷指令，并让它用官方 x-callback-url 把屏幕文字回调给 App。
    func launchCapture() {
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        // x-success / x-cancel / x-error 都回到本 App 的 agent host。
        let urlStr = "shortcuts://x-callback-url/run-shortcut"
            + "?name=\(enc(name))"
            + "&x-success=\(enc("lumenai://agent"))"
            + "&x-cancel=\(enc("lumenai://agent?cancelled=1"))"
            + "&x-error=\(enc("lumenai://agent?failed=1"))"
        guard let url = URL(string: urlStr) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: URL 回调（快捷指令 → App）

    /// `lumenai://agent?result=<屏幕文字>`（官方 x-success 回调）或 cancelled/failed。
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "lumenai",
              url.host?.lowercased() == "agent" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ n: String) -> String? { comps?.queryItems?.first(where: { $0.name == n })?.value }

        if q("cancelled") != nil { append(.error, "用户在快捷指令里取消了"); return }
        if q("failed") != nil { append(.error, "快捷指令出错了"); return }

        let screen = q("result") ?? ""
        guard !screen.isEmpty else { return }
        active = true
        lastScreen = screen
        stepIndex += 1
        append(.screen, "第 \(stepIndex) 屏：\(screen.prefix(200))")
        Task { await decide(screen: screen) }
    }

    // MARK: 调云端 LLM 决策

    private func decide(screen: String) async {
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            append(.error, "未配置 API 端点"); return
        }
        isDeciding = true
        defer { isDeciding = false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let userContent = "用户目标：\(task.isEmpty ? "（未提供，请根据屏幕推断合理目标）" : task)\n\n当前屏幕文字：\n\(screen)\n\n请给出下一步操作。"
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(code) else {
                let text = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                append(.error, "接口返回 HTTP \(code)：\(text)")
                return
            }
            let guidance = Self.extractContent(data) ?? ""
            guard !guidance.isEmpty else { append(.error, "接口返回为空"); return }
            currentGuidance = guidance
            append(.guide, guidance)
        } catch {
            append(.error, "请求失败：\(error.localizedDescription)")
        }
    }

    /// 兼容 OpenAI 风格的 `choices[0].message.content`；取不到就退而用整段文本。
    static func extractContent(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = obj["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: 进度

    func publishGuidance(_ text: String) {
        currentGuidance = text
        append(.guide, text)
    }

    private func append(_ kind: Event.Kind, _ text: String) {
        events.append(Event(kind: kind, text: text, at: Date()))
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }
}
