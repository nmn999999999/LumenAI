import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 手机协作桥（快捷指令 ↔ Lumen）
//
// 背景：本构建**不能合成点击**，屏幕识别与交互改由「快捷指令主导」的循环完成：
//   快捷指令：截屏 → 提取文本（OCR）→ 写共享文件 → 唤起 Lumen 决策 → 读回指引 → 用户照着点 → 循环
//
// 为什么共享通道是 App 的 Documents 目录，而不是 App Group：
//   **快捷指令只能读写「文件」App 里可见的位置**，App Group 容器对快捷指令不可见。
//   所以通道落在 `Documents/LumenAgent/`（配合 Info.plist 的 UIFileSharingEnabled +
//   LSSupportsOpeningDocumentsInPlace，用户与快捷指令都能在「文件 → 我的 iPhone/LumenAI」里看到）。
//   若将来配了 App Group，本类会优先用它做 App 内部读写；但快捷指令侧始终走 Files 可见目录。
//
// 共享文件（约定，快捷指令与 App 两侧必须一致）：
//   · inbox.txt    快捷指令写：本轮屏幕 OCR 文本（可选首行 `#step N`）
//   · outbox.txt   App 写：给快捷指令读回的下一步指引
//   · events.jsonl App 写：逐行 JSON 进度事件（快捷指令可读来汇报/展示）
//   · status.json  App 写：会话状态快照 {active, step, updatedAt}

@MainActor
final class MobileAgentBridge: ObservableObject {

    static let shared = MobileAgentBridge()

    // MARK: 数据模型

    struct Event: Codable, Identifiable, Equatable {
        enum Kind: String, Codable, Sendable {
            case sessionStart   // 会话开始
            case step           // 收到一步屏幕内容
            case guide          // 给用户的操作指引
            case awaitingUser   // 等待用户操作
            case message        // App → 快捷指令 的消息
            case done           // 会话结束
            case error          // 出错
        }
        var id: UUID
        var kind: Kind
        var text: String
        var at: Date

        init(kind: Kind, text: String, at: Date = Date()) {
            self.id = UUID()
            self.kind = kind
            self.text = text
            self.at = at
        }
    }

    struct Status: Codable, Equatable {
        var active: Bool
        var step: Int
        var updatedAt: Date
    }

    // MARK: 状态

    /// 实时进度（UI 直接订阅）。
    @Published private(set) var events: [Event] = []
    @Published private(set) var active = false
    @Published private(set) var stepIndex = 0
    /// 当前要给用户看的指引（最近一条 guide）。
    @Published private(set) var currentGuidance: String?

    /// 正在协作的快捷指令名（用于 App → 快捷指令 回发消息）。持久化到 UserDefaults。
    @Published var shortcutName: String = "" {
        didSet { UserDefaults.standard.set(shortcutName, forKey: Self.shortcutKey) }
    }

    private static let shortcutKey = "mobileAgent.shortcutName"

    private var pollTimer: Timer?
    private var lastInbox: String = ""

    private init() {
        shortcutName = UserDefaults.standard.string(forKey: Self.shortcutKey) ?? ""
        // 会话默认从持久化状态恢复（App 被杀后回来仍能看到进度）。
        if let s = readStatus() {
            active = s.active
            stepIndex = s.step
        }
        events = readEvents()
        currentGuidance = events.last(where: { $0.kind == .guide })?.text
    }

    // MARK: 目录

    /// 共享目录。优先 App Group（若已配置），否则 Documents/LumenAgent。
    nonisolated static func sharedDirectory() -> URL {
        let fm = FileManager.default
        let base: URL
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.lumenai.app") {
            base = group
        } else {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            base = docs
        }
        let dir = base.appendingPathComponent("LumenAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var inboxURL: URL { Self.sharedDirectory().appendingPathComponent("inbox.txt") }
    private var outboxURL: URL { Self.sharedDirectory().appendingPathComponent("outbox.txt") }
    private var eventsURL: URL { Self.sharedDirectory().appendingPathComponent("events.jsonl") }
    private var statusURL: URL { Self.sharedDirectory().appendingPathComponent("status.json") }

    // MARK: 会话控制

    /// 开始一次协作会话。会清空上一轮的进度、写状态文件，并按需唤起快捷指令。
    /// - Parameter launch: true 时立即用 `shortcuts://run-shortcut` 拉起它。
    func startSession(shortcutName: String, seedMessage: String = "", launch: Bool = true) {
        self.shortcutName = shortcutName
        active = true
        stepIndex = 0
        currentGuidance = nil
        events = []
        lastInbox = ""
        writeStatus()
        appendEvent(.sessionStart, shortcutName.isEmpty ? "会话开始" : "会话开始：\(shortcutName)")
        if !seedMessage.isEmpty { sendMessageToShortcut(seedMessage) }
        if launch, !shortcutName.isEmpty { launchShortcut(named: shortcutName, input: seedMessage) }
        startPolling()
    }

    /// 结束会话（写 done 事件并落盘）。
    func endSession(note: String = "会话结束") {
        active = false
        appendEvent(.done, note)
        writeStatus()
        stopPolling()
    }

    // MARK: 进度发布（供 AgentService / phone 工具 / URL 入口调用）

    func publishGuidance(_ text: String) {
        currentGuidance = text
        appendEvent(.guide, text)
        // 写回 outbox，快捷指令可「获取文件内容」读回展示给用户。
        try? text.write(to: outboxURL, atomically: true, encoding: .utf8)
    }

    func publish(_ kind: Event.Kind, _ text: String) {
        appendEvent(kind, text)
    }

    /// 记录一步到的屏幕内容（快捷指令 OCR 后写入）。
    func noteStep(screen: String) {
        stepIndex += 1
        appendEvent(.step, screen.isEmpty ? "（收到一步，无文本）" : screen)
        writeStatus()
    }

    // MARK: App → 快捷指令

    /// 通过 URL scheme 把一条消息发给快捷指令（作为 `input` 传入）。
    func sendMessageToShortcut(_ message: String) {
        guard !shortcutName.isEmpty else { return }
        appendEvent(.message, message)
        launchShortcut(named: shortcutName, input: message)
    }

    private func launchShortcut(named name: String, input: String) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        // Shortcuts 的 input 参数：有 input 时用 input，否则只带名字。
        let urlString = input.isEmpty
            ? "shortcuts://run-shortcut?name=\(enc(name))"
            : "shortcuts://run-shortcut?name=\(enc(name))&input=text&text=\(enc(input))"
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: URL 入口（快捷指令 → App）

    /// 处理 `lumenai://agent?...`。支持的参数：
    ///   · action=start|end  开始 / 结束会话（start 可带 shortcut=<名> 覆盖）
    ///   · step=<文本>       记一步屏幕 OCR 内容（小段文本；大段请写 inbox.txt）
    ///   · guide=<文本>      把一条指引推给用户
    ///   · message=<文本>    App → 快捷指令 的消息（转发）
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "lumenai",
              url.host?.lowercased() == "agent" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? {
            comps?.queryItems?.first(where: { $0.name == name })?.value
        }
        switch (q("action") ?? "").lowercased() {
        case "start":
            let name = q("shortcut") ?? shortcutName
            if !active { startSession(shortcutName: name, seedMessage: q("message") ?? "", launch: false) }
        case "end":
            endSession()
        default:
            if !active { startSession(shortcutName: shortcutName, launch: false) }
        }
        if let step = q("step"), !step.isEmpty { noteStep(screen: step) }
        if let guide = q("guide"), !guide.isEmpty { publishGuidance(guide) }
        if let msg = q("message"), !msg.isEmpty {
            appendEvent(.message, msg)
            if !shortcutName.isEmpty { launchShortcut(named: shortcutName, input: msg) }
        }
    }

    // MARK: 轮询 inbox（快捷指令 → App）

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollInbox() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 读 inbox.txt：内容变了就记一步（快速识别「快捷指令写入了新一屏」）。
    func pollInbox() {
        guard active else { return }
        guard let text = try? String(contentsOf: inboxURL, encoding: .utf8),
              !text.isEmpty, text != lastInbox else { return }
        lastInbox = text
        noteStep(screen: text)
    }

    // MARK: 持久化

    private func appendEvent(_ kind: Event.Kind, _ text: String) {
        let e = Event(kind: kind, text: text)
        events.append(e)
        if events.count > 300 { events.removeFirst(events.count - 300) }
        let line = (try? JSONEncoder().encode(e)).flatMap { String(data: $0, encoding: .utf8) }
        let existing = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? ""
        try? (existing + (line ?? "") + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
    }

    private func writeStatus() {
        let s = Status(active: active, step: stepIndex, updatedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(s) { try? data.write(to: statusURL, options: .atomic) }
    }

    private func readStatus() -> Status? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Status.self, from: data)
    }

    private func readEvents() -> [Event] {
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            line.data(using: .utf8).flatMap { try? dec.decode(Event.self, from: $0) }
        }
    }
}
