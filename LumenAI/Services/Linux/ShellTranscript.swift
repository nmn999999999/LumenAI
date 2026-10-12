import Foundation

/// 终端会话记录（transcript）：把「谁在 ShellSandbox 里跑了什么」集中到一处。
///
/// 为什么需要它：agent 的 `shell` 工具与终端页手敲的命令用的是**同一个**
/// `ShellSandbox` 会话，但 agent 那条路的输出只回到对话气泡里 —— 用户在终端页
/// 看不到，排查「agent 到底跑了什么命令、退出码是多少」只能翻聊天记录。
/// 这个 store 让两边写同一份记录，终端页一次就能看到全部。
///
/// 线程模型：`record` 可能在任意线程被调用（agent 走 AsyncTask，终端页走主线程），
/// 所以它把追加动作统一跳回主线程执行；`entries` 因此只在主线程被读写，
/// SwiftUI 直接绑定它是安全的。类标 `@unchecked Sendable` 是因为内部只有这一个
/// 受约束的可变状态，由「只在主线程改」这条规则守住。
final class ShellTranscript: ObservableObject, @unchecked Sendable {
    static let shared = ShellTranscript()

    struct Entry: Identifiable, Sendable {
        /// 谁跑的：用户手敲 / agent 工具调用
        enum Source: String, Sendable {
            case user
            case agent
        }

        let id: UUID
        let source: Source
        let command: String
        let output: String
        let exitCode: Int
        let date: Date
    }

    /// 只显示最近这些条，避免长时间运行把内存吃光。
    private static let limit = 200

    /// 单条输出在记录里的上限（与给模型看的 4000 字上限一致，避免这里成为内存黑洞）。
    private static let outputLimit = 4000

    /// 主线程读（SwiftUI 绑定），写经由 `record` 跳回主线程。
    @Published private(set) var entries: [Entry] = []

    private init() {}

    /// 追加一条记录。任意线程可调。
    func record(source: Entry.Source, command: String, output: String, exitCode: Int) {
        let trimmed = output.count > Self.outputLimit
            ? String(output.prefix(Self.outputLimit)) + "\n…(输出过长，记录已截断)"
            : output
        let entry = Entry(id: UUID(),
                          source: source,
                          command: command,
                          output: trimmed,
                          exitCode: exitCode,
                          date: Date())
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(entry) }
        }
    }

    /// 清空记录。同样归一到主线程，保证与 `append` 不交错。
    func clear() {
        if Thread.isMainThread {
            entries.removeAll()
        } else {
            DispatchQueue.main.async { [weak self] in self?.entries.removeAll() }
        }
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }
}
