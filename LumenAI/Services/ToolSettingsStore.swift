import Foundation

/// 内置工具的选择与开关（持久化到 UserDefaults）。
///
/// 为什么要有这个 store：
///   `BuiltInTools.allTools` 有 33 个工具，而本地模型走 `prefix(12)` 取**声明顺序**的
///   前 12 个。实测 `note`（跨对话记忆的唯一接口）排第 19、`web_search` 第 21，
///   **都被截掉了** —— 本地模型的工具目录里根本不存在记忆工具，核心功能等于不可用。
///
/// 这里的做法是：**上限不变（仍是 12 个），但选择权交给用户** ——
/// 每个内置工具都能单独开关，默认清单把 `note` / `web_search` 纳入
/// （见 `BuiltInTools.defaultEnabledNames`），被挤出去的 `csv_table` / `jwt_decode`
/// 仍可在设置里手动换回来。
///
/// 与 `SettingsStorage` 保持同一套写法（非 MainActor + `@unchecked Sendable` +
/// UserDefaults 持久化），避免在 Swift 6 的隔离检查上引入额外摩擦。
final class ToolSettingsStore: ObservableObject, @unchecked Sendable {

    static let shared = ToolSettingsStore()

    /// 已启用的内置工具名，**有序**（顺序决定它们出现在模型目录里的先后）。
    @Published var enabledNames: [String] {
        didSet { persist() }
    }

    private let key = "tools.enabled.v1"

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: key), !saved.isEmpty {
            enabledNames = Self.sanitize(saved)
        } else {
            enabledNames = BuiltInTools.defaultEnabledNames
        }
    }

    /// 清洗：丢弃已不存在的工具名、去重、并截到上限。
    /// 必须做这一步 —— 旧版本的存档里可能存着后来被删掉的工具名，
    /// 不清洗会让目录里冒出「幽灵工具」。
    static func sanitize(_ names: [String]) -> [String] {
        let known = Set(BuiltInTools.allTools.map { $0.name })
        var seen = Set<String>()
        var out: [String] = []
        for n in names where known.contains(n) && !seen.contains(n) {
            seen.insert(n)
            out.append(n)
            if out.count >= BuiltInTools.catalogLimit { break }
        }
        return out
    }

    var count: Int { enabledNames.count }
    var limit: Int { BuiltInTools.catalogLimit }
    var isFull: Bool { enabledNames.count >= BuiltInTools.catalogLimit }
    var remaining: Int { max(0, BuiltInTools.catalogLimit - enabledNames.count) }

    func isEnabled(_ name: String) -> Bool { enabledNames.contains(name) }

    /// 开关一个工具。返回 false 表示**因为已达上限而拒绝**。
    /// 这里刻意不做「自动顶掉最旧一个」：静默挤掉别人的选项比直接拒绝更难排查。
    @discardableResult
    func setEnabled(_ name: String, _ on: Bool) -> Bool {
        guard BuiltInTools.allTools.contains(where: { $0.name == name }) else { return false }
        if on {
            guard !enabledNames.contains(name) else { return true }
            guard !isFull else { return false }
            // note 这类核心工具插到前面，其余追加到末尾
            enabledNames.append(name)
        } else {
            enabledNames.removeAll { $0 == name }
        }
        return true
    }

    /// 调整顺序（顺序会体现在模型看到的工具目录里）
    func move(from offsets: IndexSet, to destination: Int) {
        enabledNames.move(fromOffsets: offsets, toOffset: destination)
    }

    func resetToDefault() {
        enabledNames = BuiltInTools.defaultEnabledNames
    }

    /// 恢复默认时把上限内、但当前未启用的工具列出来（给「一键恢复」用）
    var disabledNames: [String] {
        enabledNames.count >= BuiltInTools.catalogLimit
            ? []
            : BuiltInTools.allTools.map { $0.name }.filter { !enabledNames.contains($0) }
    }

    /// 交给 `AgentService` 的工具定义（按用户选择的顺序）。
    func enabledTools() -> [AgentToolDefinition] {
        BuiltInTools.tools(named: enabledNames)
    }

    private func persist() {
        UserDefaults.standard.set(enabledNames, forKey: key)
    }
}
