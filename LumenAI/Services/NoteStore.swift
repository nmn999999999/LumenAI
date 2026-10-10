import Foundation

/// 长期记忆（`note` 工具）的**单一数据源**。
///
/// 存在的理由：`note` 是跨对话记忆的唯一接口 —— 也就是这个 App 的核心能力。
/// 但在这次改动之前，它把笔记直接写成 `Documents/agent_notes/*.txt`：纯文件、
/// 没有 Store、界面上**没有任何地方能看到或删除它们**。后果有三个：
///
/// 1. 用户看不见 AI 到底记住了什么，只能在对话里反复问它；
/// 2. 用户在「设置 → 工具」里关掉 `note` 之后，记忆就彻底失管 ——
///    存进去了，却没有任何入口能查看或清理；
/// 3. 最要命的是 `chatStore.deleteAll()`（设置页「删除全部对话记录」）**不会**碰这里。
///    用户以为清干净了，AI 其实还记得全部 —— 这是个隐私问题，不只是体验问题。
///
/// 所以现在：工具和界面都走这一个类，文件读写只有一份实现，界面状态自动跟着变。
///
/// ⚠️ `perform(op:name:content:)` 的返回字符串是**面向模型的文案**：保持简洁、稳定、
/// 与工具描述一致即可，改动时无需考虑训练数据（自训权重已废弃）。
@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    struct Note: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let characters: Int
        let modified: Date
        /// 列表里不读内容（笔记可能很长），展开某条时才从磁盘取。
        let content: String
    }

    @Published private(set) var notes: [Note] = []

    /// 笔记目录。与 `AgentTool` 原来使用的位置完全相同，保证老笔记还读得到。
    static let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("agent_notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        refresh()
    }

    // MARK: - 读

    var totalCharacters: Int { notes.reduce(0) { $0 + $1.characters } }

    /// 从磁盘重建列表。工具写完、外部删完、App 回到前台时都调它。
    func refresh() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        // 排序：工具返回的 list 结果也用这个顺序，两边必须一致，
        // 否则界面上的顺序和模型看到的顺序不同，用户会以为列表坏了。
        let sorted = names.filter { $0.hasSuffix(".txt") }
            .map { String($0.dropLast(4)) }
            .sorted()
        notes = sorted.map { name in
            let url = Self.directory.appendingPathComponent(name + ".txt")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            return Note(name: name, characters: text.count, modified: date, content: text)
        }
    }

    func content(of name: String) -> String? {
        notes.first { $0.name == name }?.content
    }

    // MARK: - 单个删除 / 全部清空（界面用）

    @discardableResult
    func delete(name: String) -> Bool {
        let url = Self.directory.appendingPathComponent(Self.sanitize(name) + ".txt")
        let ok = (try? FileManager.default.removeItem(at: url)) != nil
        refresh()
        return ok
    }

    @discardableResult
    func deleteAll() -> Int {
        let n = notes.count
        for note in notes {
            let url = Self.directory.appendingPathComponent(note.name + ".txt")
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
        return n
    }

    // MARK: - 工具入口（唯一实现）

    /// 笔记名里的 `/` 会被替换成 `-`：否则会被当成路径分隔符写到目录外面去。
    static func sanitize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "-")
    }

    /// `note` 工具的全部行为都在这里。返回值是面向模型的文案，保持简洁稳定即可。
    func perform(op: String, name rawName: String, content: String) -> String {
        let name = Self.sanitize(rawName)

        switch op {
        case "save":
            guard !name.isEmpty else { return "错误: 保存笔记需要 name 参数" }
            let url = Self.directory.appendingPathComponent(name + ".txt")
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                refresh()
                return "已保存笔记「\(rawName)」（\(content.count) 字）"
            } catch {
                return "保存失败: \(error.localizedDescription)"
            }
        case "read":
            guard !name.isEmpty else { return "错误: 读取笔记需要 name 参数" }
            let url = Self.directory.appendingPathComponent(name + ".txt")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "未找到笔记「\(rawName)」"
            }
            return "「\(rawName)」: \(text)"
        case "delete":
            guard !name.isEmpty else { return "错误: 删除笔记需要 name 参数" }
            let url = Self.directory.appendingPathComponent(name + ".txt")
            do {
                try FileManager.default.removeItem(at: url)
                refresh()
                return "已删除笔记「\(rawName)」"
            } catch {
                return "删除失败或不存在: \(error.localizedDescription)"
            }
        default: // list
            let names = notes.map(\.name)
            return names.isEmpty ? "暂无笔记" : "现有笔记: \(names.joined(separator: ", "))"
        }
    }
}
