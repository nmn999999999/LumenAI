import Foundation

/// 模型（或用户）编写的"手机操作步骤"。
///
/// 这是**两个变体共用**的数据结构：合规版只执行其中能安全执行的部分
/// （打开 URL / 运行已装快捷指令），Tap 版额外能执行 `tap` 这类合成触摸。
/// 用同一份数据意味着用户在两个变体之间切换时，编好的配方不会作废。
struct ShortcutRecipe: Identifiable, Codable, Equatable, Sendable {

    var id: UUID
    /// 快捷指令 App 里的名字（`run` 就是靠它定位）。
    var name: String
    /// 一句话说明它干什么 —— 模型下次看见这行就知道该不该跑。
    var summary: String
    var actions: [Action]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, summary: String,
         actions: [Action] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.summary = summary
        self.actions = actions
        self.createdAt = createdAt
    }

    enum Action: Codable, Equatable, Sendable {
        /// 运行快捷指令 App 里的一条指令（两个变体都支持）。
        case runShortcut(String)
        /// 打开一个 URL（可跳到别的 App，取决于对方注册的 scheme）。
        case openURL(String)
        /// 在归一化坐标 (0..1) 处点一下 —— **只有 SIMULATE_TAP 变体真能执行**。
        case tap(x: Double, y: Double)
        case wait(seconds: Double)
        /// 打一段字（合规版没有系统级输入注入，只作为记录）。
        case typeText(String)
        /// 纯注释，执行时原样回显。
        case note(String)
    }

    /// 给人看的步骤列表（设置页与 `phone list` 共用）。
    var actionDescriptions: [String] {
        actions.map { action in
            switch action {
            case .runShortcut(let n): return "运行快捷指令「\(n)」"
            case .openURL(let u): return "打开 \(u)"
            case .tap(let x, let y): return "点击 (\(Int(x * 1000) / 10)%, \(Int(y * 1000) / 10)%)"
            case .wait(let s): return "等待 \(String(format: "%.1f", s)) 秒"
            case .typeText(let t): return "输入「\(t)」"
            case .note(let t): return "注：\(t)"
            }
        }
    }

    /// 模型生成配方时用的紧凑文本（也让它能把配方原样贴回 `phone save`）。
    var encodedForModel: String {
        actions.map { action in
            switch action {
            case .runShortcut(let n): return "run \(n)"
            case .openURL(let u): return "open \(u)"
            case .tap(let x, let y): return "tap \(String(format: "%.3f", x)) \(String(format: "%.3f", y))"
            case .wait(let s): return "wait \(String(format: "%.1f", s))"
            case .typeText(let t): return "type \(t)"
            case .note(let t): return "# \(t)"
            }
        }.joined(separator: "\n")
    }

    /// 解析 `encodedForModel` 那种行格式；返回 nil 表示这行不认识。
    static func parseAction(_ line: String) -> Action? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("#") { return .note(String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))) }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = parts.first?.lowercased() else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""
        switch head {
        case "run": return rest.isEmpty ? nil : .runShortcut(rest)
        case "open": return rest.isEmpty ? nil : .openURL(rest)
        case "wait":
            guard let d = Double(rest.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .wait(seconds: min(max(d, 0), 60))
        case "type": return rest.isEmpty ? nil : .typeText(rest)
        case "tap":
            let xy = rest.split(separator: " ").compactMap { Double($0) }
            guard xy.count == 2 else { return nil }
            return .tap(x: min(max(xy[0], 0), 1), y: min(max(xy[1], 0), 1))
        default: return nil
        }
    }
}

// MARK: - 存储

/// 配方存储：Documents/shortcut_recipes.json。
///
/// 与 `PersonaStore` 同一套写法（@MainActor 单例 + @Published + didSet persist），
/// 界面与工具读写同一份数据，避免"模型存了、界面上看不到"。
@MainActor
final class ShortcutStore: ObservableObject {

    static let shared = ShortcutStore()

    @Published var recipes: [ShortcutRecipe] = [] { didSet { persist() } }

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("shortcut_recipes.json")
    }()

    private init() {
        load()
    }

    func recipe(id: String) -> ShortcutRecipe? {
        if let uuid = UUID(uuidString: id) { return recipes.first { $0.id == uuid } }
        return recipes.first { $0.name == id }   // 模型常直接给名字，允许名字匹配
    }

    @discardableResult
    func save(name: String, summary: String, actionsText: String) -> ShortcutRecipe? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var actions = [ShortcutRecipe.Action]()
        for line in actionsText.split(separator: "\n") {
            if let a = ShortcutRecipe.parseAction(String(line)) { actions.append(a) }
        }
        if let existing = recipes.firstIndex(where: { $0.name == trimmed }) {
            var updated = recipes[existing]
            updated.summary = summary.isEmpty ? updated.summary : summary
            if !actions.isEmpty { updated.actions = actions }
            recipes[existing] = updated
            return updated
        }
        let recipe = ShortcutRecipe(name: trimmed,
                                     summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                     actions: actions)
        recipes.append(recipe)
        return recipe
    }

    func delete(id: String) -> String? {
        if let uuid = UUID(uuidString: id), let i = recipes.firstIndex(where: { $0.id == uuid }) {
            return recipes.remove(at: i).name
        }
        if let i = recipes.firstIndex(where: { $0.name == id }) {
            return recipes.remove(at: i).name
        }
        return nil
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([ShortcutRecipe].self, from: data)
        else { return }
        recipes = list
    }

    private func persist() {
        // didSet 也会在 load() 里触发一次 —— 那时写回同样的内容，代价可忽略，
        // 比在 load 里临时关掉 didSet 简单且不会留下"标志位忘了复位"的坑。
        guard let data = try? JSONEncoder().encode(recipes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
