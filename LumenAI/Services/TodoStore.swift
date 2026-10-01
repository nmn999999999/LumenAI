import Foundation

/// 目标/任务清单（`todo` 工具）的**单一数据源**。
///
/// 为什么需要它：模型做多步任务时，用户只能看到一段段文字，不知道「现在做到哪了、
/// 还剩几步」。让模型把步骤写成一份清单、每完成一步就更新状态，进度就变成了**界面上可见**的
/// 东西（面板由 `todos` 驱动）。工具层因此不能只把清单拼进返回值就完事 ——
/// 返回值给模型看，`todos` 给用户看，两边必须是同一份数据，否则界面和模型各说各话。
///
/// 设计取舍（每条都对应一个具体的坑，改之前请先读）：
///
/// 1. **整表替换，不做增量修改**。曾经想过用 `op=update` + `index` 只改一条：那要求模型
///    每次数准下标，而模型看不到自己的下标算错了 —— 一旦数错就会改到**别的条目**上，
///    并且返回"已更新"让它以为成功了。整表替换是无状态的：模型每次输出它认为的完整清单，
///    幂等、不会错位，代价只是重复几行文本。DSH 的 `todo_write`、Claude Code 的 `TodoWrite`
///    都是这个做法。
/// 2. **按对话隔离**。清单的语义是"当前这件事的进度"。跨对话共享会串味：
///    对话 A 的计划出现在对话 B 的面板上，用户会认为 App 记错了。
/// 3. **跨启动持久化**。清单是正在进行的任务，App 被系统回收再打开（iOS 常事）后
///    用户会接着做，这时清单必须还在 —— 所以写 `Documents/agent_todos.json`，
///    与 App 其它状态（`NoteStore` 的 `Documents/agent_notes/`）保持同一套习惯。
///    文件损坏一律**静默降级为空清单**：清单丢了只是少个提示，崩掉是丢整个会话。
@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    // MARK: - 数据模型

    /// 条目状态。原始值与工具参数、落盘 JSON **逐字一致**（`in_progress` 用下划线），
    /// 所以不要为了"好看"改成 camelCase —— 已落盘的文件和模型的输出都按这个拼写。
    enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    struct Todo: Identifiable, Codable, Hashable, Sendable {
        /// 稳定 id：同一 `content` 在同一次 set 内复用上一次的 id（见 `replace`）。
        /// UI 靠它做差异更新 —— 每次全换新 id 会让整表重建、动画抖动、列表闪烁。
        var id: String
        /// 祈使句，例如「检查 AgentService 的解析分支」。
        var content: String
        var status: Status
    }

    // MARK: - 上限

    /// 条目数上限。清单是给人看的进度条，不是待办管理器：几十条就已经读不动了，
    /// 而超长清单还会挤占模型上下文。超出部分截断并在返回文本里说明（不静默）。
    static let maxItems = 50

    /// 单条 content 的字数上限。模型偶尔会把整段代码塞进 content，截断并说明。
    static let maxContentLength = 200

    // MARK: - 状态

    /// 当前绑定的对话 id（nil = 未绑定）。切换对话时切到该对话的清单。
    @Published private(set) var boundConversationID: UUID?

    @Published private(set) var todos: [Todo] = []

    /// 落盘文件。结构：`{"<conversationUUID>": [ {id, content, status} ]}`。
    static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("agent_todos.json")
    }()

    /// 未绑定对话时用的槽位。
    ///
    /// 为什么需要它：`todo` 工具可能在 UI 还没绑定对话时被调用（比如启动后第一条消息）。
    /// 那时把条目写进任何一个真实对话都是**串味**；直接丢弃又会让模型以为计划记下了。
    /// 所以给未绑定状态一个独立槽位：绑定之后各对话互不影响，未绑定期间的清单也不会
    /// 冒到某个对话的面板上。
    private static let unboundKey = "__unbound__"

    /// 全量数据：对话 id（或 `unboundKey`）→ 清单。内存里存一份，落盘时整份写出。
    /// 每次改动都回写磁盘（清单很小，几十条），避免"进程被杀就丢"。
    private var storage: [String: [Todo]] = [:]

    private var currentKey: String { boundConversationID?.uuidString ?? Self.unboundKey }

    private init() {
        storage = Self.loadFromDisk()
        // `todos` 始终是 `storage[currentKey]` 的镜像。启动时未绑定，就先显示未绑定槽位
        // （通常是空的）；UI 一调 `bind` 就会切到真实对话的清单。
        todos = storage[currentKey] ?? []
    }

    // MARK: - 对话绑定（UI 用）

    /// 切换当前对话的清单。同一对话的清单会被保留，不同对话互不干扰。
    ///
    /// 同一个 id 重复调用时直接返回：`bind` 常常会被 SwiftUI 的 `onAppear`/`onChange`
    /// 反复触发，若无条件重读会把正在进行的更新覆盖回旧值。
    func bind(conversationID: UUID?) {
        guard conversationID != boundConversationID else { return }
        boundConversationID = conversationID
        todos = storage[currentKey] ?? []
    }

    // MARK: - 工具入口

    /// `set` 参数不合法时的固定报错。字面量只留这一份：这个约束是 **store 的契约**
    /// （`replace` 要的是"每一项都是对象的数组"），工具层只是把参数原样递进来，
    /// 两边各抄一份文案早晚会漂移。
    ///
    /// `nonisolated`：工具代码跑在非隔离上下文里，不该为了拼一句话先跳一次主线程。
    nonisolated static let missingTodosError = "错误: set 需要 todos 数组"

    /// `todo` 工具 set 的入口（工具层用）。与 `replace(with:)` 的区别只是**参数形态**：
    ///
    /// 为什么工具层不直接调 `replace(with: [[String: Any]])`：`[[String: Any]]`（以及
    /// `arguments` 里的任何嵌套字典数组）**不是 Sendable**，把它捕获进 `MainActor.run` 的
    /// 闭包，在 Swift 6 严格并发下是编译错误（`sending 'items' risks causing data races`）。
    /// 这跟 `BuiltInTools.execute(toolName:argumentsJSON:)` 一开始就把参数收成 JSON 字符串
    /// 是同一个理由：String 是 Sendable，可以安全跨 actor 传递。
    ///
    /// 解析失败（缺 todos / 不是数组 / 元素不是对象）一律返回同一句报错，不静默当成空清单。
    func replace(withJSON json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let items = object as? [[String: Any]] else {
            return Self.missingTodosError
        }
        return replace(with: items)
    }

    /// `todo` 工具的 set：**整表替换**当前对话的清单，返回给模型看的文本。
    ///
    /// 参数是原始字典而不是 `[Todo]`：校验（字段缺失、类型不对、超长、超量）必须发生在
    /// store 里，返回文案才能把"跳过了几条、为什么"和清单本身写在同一条回复里 ——
    /// 如果让工具层先转成 `[Todo]`，那些容错信息会在转换时丢掉。
    func replace(with raw: [[String: Any]]) -> String {
        var collected: [Todo] = []
        var skippedEmptyContent = 0
        var truncatedContentCount = 0

        // id 复用表：上一次清单里 `content` → 曾经的 id（同一文本可能有多条，用队列逐个取）。
        // 复用而不是重新生成，是为了让 UI 的差异算法认出"这条还在，只是状态变了"，
        // 从而做位移动画而不是整表重建。
        var reusableIDs: [String: [String]] = [:]
        for todo in todos { reusableIDs[todo.content, default: []].append(todo.id) }

        func takeID(for content: String) -> String {
            if var ids = reusableIDs[content], !ids.isEmpty {
                let id = ids.removeFirst()
                reusableIDs[content] = ids
                return id
            }
            return UUID().uuidString
        }

        for item in raw {
            // ① status 先校验，而且**整次 set 直接失败**（不做部分写入）。
            //    顺序很重要：如果先判 content 再判 status，一条"content 为空 + status 写错"的
            //    脏数据会被当成"跳过"悄悄丢掉，模型看不到自己 status 拼错了，下一轮还会接着错。
            //    另外这里**不把不认识的 status 退化成 pending** —— 那会让模型以为设对了，
            //    用户则会看到一条本该"已完成"的条目还挂在待办里。
            let status: Status
            if let rawStatus = item["status"], !(rawStatus is NSNull) {
                guard let text = rawStatus as? String,
                      let parsed = Self.parseStatus(text) else {
                    return "错误: 未知状态 \"\(Self.describe(rawStatus))\"，可选: pending, in_progress, completed"
                }
                status = parsed
            } else {
                // 缺省 pending：模型只写了 content 时，最合理的默认是"还没开始"。
                status = .pending
            }

            // ② content 缺失或空白 → 跳过这一条，但要计数并在最后一行说明原因（不静默）。
            //    空 content 在面板上就是一行空白，用户看不懂，模型也认不出是哪条。
            guard let rawContent = item["content"] as? String else {
                skippedEmptyContent += 1
                continue
            }
            // 去掉首尾空白再存：模型常带换行/缩进，留着会让同一件事两次的 content 不相等，
            // 于是 id 复用失效（动画抖动），落盘文件里也全是转义。
            var content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                skippedEmptyContent += 1
                continue
            }
            if content.count > Self.maxContentLength {
                content = String(content.prefix(Self.maxContentLength))
                truncatedContentCount += 1
            }

            collected.append(Todo(id: takeID(for: content), content: content, status: status))
        }

        // ③ 条目数上限：截断并说明。注意是**截断**而不是报错 —— 模型写了 60 条时，
        //    前面 50 条仍然是有用的计划，整次失败反而让它丢掉全部工作。
        var truncatedItemCount = 0
        if collected.count > Self.maxItems {
            truncatedItemCount = collected.count - Self.maxItems
            collected = Array(collected.prefix(Self.maxItems))
        }

        todos = collected
        storage[currentKey] = collected
        persist()

        // ④ 同一时刻最多一条 inProgress：只提醒，**不自动改**。
        //    自动把多余的改成 pending 会掩盖模型的错误（它以为三条都在做，界面却只显示一条），
        //    而提醒能让它下一轮自己修正。多线并行本来也不该被工具偷偷改掉。
        var warnings: [String] = []
        if skippedEmptyContent > 0 {
            warnings.append("跳过 \(skippedEmptyContent) 条（缺少 content 或内容为空白）")
        }
        if truncatedItemCount > 0 {
            warnings.append("条目数超过上限 \(Self.maxItems)，已截断 \(truncatedItemCount) 条")
        }
        if truncatedContentCount > 0 {
            warnings.append("有 \(truncatedContentCount) 条内容超过 \(Self.maxContentLength) 字，已截断")
        }
        let inProgressCount = collected.filter { $0.status == .inProgress }.count
        if inProgressCount > 1 {
            warnings.append("有 \(inProgressCount) 条 in_progress，建议保持只有一条在做")
        }

        var lines = [Self.header(prefix: "已更新任务清单", todos: collected)]
        lines.append(contentsOf: Self.rows(for: collected))
        if let note = Self.noteLine(warnings) { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    /// `op=list` 的返回文案。
    ///
    /// 不是 UI 契约的一部分，只是把「逐条格式」的唯一定义留在这个文件里：
    /// 让 `AgentTool` 自己拼的话，`[x] / [~] / [ ]` 就会有第二份实现，早晚与 set 的返回漂移
    /// （模型看到两套格式，行为也会跟着飘）。
    func listText() -> String {
        guard !todos.isEmpty else { return "当前没有任务清单" }
        var lines = [Self.header(prefix: "当前任务清单", todos: todos)]
        lines.append(contentsOf: Self.rows(for: todos))
        return lines.joined(separator: "\n")
    }

    /// 清空当前对话的清单（其它对话不受影响）。
    func clear() {
        // 整个键一起删：留着空数组会让文件随对话数量单调增长。
        storage.removeValue(forKey: currentKey)
        todos = []
        persist()
    }

    // MARK: - 对话被删除时的清理

    /// 删除某段对话时，把它那份清单一起丢掉。
    ///
    /// 为什么必须由删除方显式调用：`TodoStore` 按 `conversationID` 分槽存放，
    /// 而 `ChatStore.delete(_:)` 只认识自己的 `conversations` 数组 —— 两边没有任何引用关系。
    /// 不清理的后果有两个，且都不轻：
    ///   1. **隐私**：清单是用户自己写下的任务内容（「整理妈妈的病理报告」这种），
    ///      对话删了文件里还留着，用户在界面上再也看不到、也就永远删不掉；
    ///   2. **文件单调增长**：`agent_todos.json` 每个删掉的对话都留一个 `UUID` 键，
    ///      只增不减。这与 `NoteStore` 当初"只有写没有界面"是同一类问题。
    ///
    /// 传 `conversationID` 而不是复用 `clear()`：删除发生在列表页，那时 `boundConversationID`
    /// 很可能指向**另一段**对话（用户当前打开的那个）—— 用 `clear()` 会删错对象。
    func delete(conversationID: UUID) {
        let key = conversationID.uuidString
        // 不存在就早退：避免为一个从未用过 todo 的对话白写一次磁盘。
        guard storage.removeValue(forKey: key) != nil else { return }
        // 删的正好是当前绑定对话时，内存镜像也要跟着空 —— 否则面板会继续显示一份
        // 已经不在磁盘上的清单，下次 `bind` 回来还会因为 storage 里没有而"复活"。
        if key == currentKey { todos = [] }
        persist()
    }

    /// 清空**全部**对话的清单（设置页「删除全部对话记录」用）。
    ///
    /// 连未绑定槽位一起清：`__unbound__` 里同样可能有内容，只清真实对话等于漏一块。
    func deleteAll() {
        guard !storage.isEmpty else { return }
        storage.removeAll()
        todos = []
        persist()
    }

    /// 只保留这些对话的清单，其余全部丢弃（从备份恢复时用）。
    ///
    /// 为什么恢复备份也要动这里：`restoreFromBackup` 是**整批替换** `conversations`，
    /// 恢复前的那些对话连同它们的 id 一起消失。清单是按 id 分槽存的，于是旧槽位全部变成
    /// 无人认领的孤儿 —— 与「删单个对话」是同一个泄漏，只是入口在另一处。
    ///
    /// 用白名单（保留哪些）而不是黑名单（删哪些）：恢复之后真实存在的集合才是唯一权威，
    /// 而"恢复前有哪些"在调用点已经不可靠了。
    ///
    /// 备份里**自带**的那些对话 id 会被保留下来 —— 所以如果备份恢复的是同一批 id
    /// （同一台设备、同一次全量备份），任务清单会跟着一起回来，这正是用户期望的。
    func retainOnly(conversationIDs: Set<UUID>) {
        let keep = Set(conversationIDs.map(\.uuidString))
        let before = storage.count
        // 未绑定槽位不在任何对话名下，但它不属于"某个已删除的对话"，
        // 也没有泄漏对象，所以一并保留（它在界面上不可见，清不清都不涉及隐私）。
        storage = storage.filter { keep.contains($0.key) || $0.key == Self.unboundKey }
        guard storage.count != before else { return }
        todos = storage[currentKey] ?? []
        persist()
    }

    // MARK: - UI 派生值

    /// 例如 "2/5"（已完成/总数）；空清单返回 ""（UI 据此隐藏角标）。
    var progressText: String {
        guard !todos.isEmpty else { return "" }
        let done = todos.filter { $0.status == .completed }.count
        return "\(done)/\(todos.count)"
    }

    /// 当前是否应该显示面板（非空即显示）。
    var isActive: Bool { !todos.isEmpty }

    // MARK: - 返回文案（写死，便于将来做训练数据）

    private static func header(prefix: String, todos: [Todo]) -> String {
        let done = todos.filter { $0.status == .completed }.count
        return "\(prefix)（\(todos.count) 条：\(done) 已完成）"
    }

    /// 逐条一行：`[x]` 已完成 / `[~]` 进行中 / `[ ]` 待办（与 Claude Code、DSH 的观感一致）。
    private static func rows(for todos: [Todo]) -> [String] {
        todos.map { "- \(marker(for: $0.status)) \($0.content)" }
    }

    private static func marker(for status: Status) -> String {
        switch status {
        case .completed:  return "[x]"
        case .inProgress: return "[~]"
        case .pending:    return "[ ]"
        }
    }

    /// 提醒/截断信息**合并成最后一行**（固定前缀 "注意: "），保证正文部分逐条稳定：
    /// 将来拿这些文本做训练数据时，正文不会被数量不定的提醒行切碎。
    private static func noteLine(_ warnings: [String]) -> String? {
        guard !warnings.isEmpty else { return nil }
        return "注意: " + warnings.joined(separator: "；")
    }

    /// status 解析：容忍大小写与首尾空白（模型输出不稳），但**不做语义猜测** ——
    /// 拼错的值一律由调用方报错，绝不静默落到 pending。
    private static func parseStatus(_ raw: String) -> Status? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Status(rawValue: normalized)
    }

    /// 把不合法的 status 值原样回显给模型（"1"、「」都照抄）。
    /// 回显原文很重要：模型并不知道自己发的是什么，看到原值下一轮才有机会自我纠正。
    private static func describe(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let a = value as? [Any] { return "[\(a.count) 个元素的数组]" }
        if let d = value as? [String: Any] { return "{\(d.count) 个键的对象}" }
        return "\(value)"
    }

    // MARK: - 落盘

    /// 持久化。写失败**静默忽略**：清单是辅助信息，为它弹错误/崩溃都不值当 ——
    /// 内存里的 `todos` 仍然是对的，界面照常工作，只是这次没存住。
    private func persist() {
        // 空清单不落盘：否则用户每开一个新对话就多一个键，文件会一直长。
        let snapshot = storage.filter { !$0.value.isEmpty }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// 宽松解码：先按严格格式解；整份解不出时再逐条解，**只丢坏掉的那一条**。
    /// 例如某个 status 被外部改成了 "done"，严格解码会让所有对话的清单一起消失，
    /// 而这里只丢一条（`compactMap` 掉 nil）。
    private struct LenientTodo: Decodable {
        let value: Todo?
        init(from decoder: Decoder) throws {
            value = try? Todo(from: decoder)
        }
    }

    private static func loadFromDisk() -> [String: [Todo]] {
        // 读不到文件（首次启动）算正常路径，直接空清单。
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let strict = try? JSONDecoder().decode([String: [Todo]].self, from: data) {
            return strict.filter { !$0.value.isEmpty }
        }
        guard let lenient = try? JSONDecoder().decode([String: [LenientTodo]].self, from: data) else {
            // 文件损坏 / 不是合法 JSON：静默降级为空清单。下次 persist 会覆盖掉坏文件，
            // 用户只会看到"清单没了"，而不是 App 打不开。
            return [:]
        }
        return lenient.compactMapValues { entries -> [Todo]? in
            let todos = entries.compactMap(\.value)
            return todos.isEmpty ? nil : todos
        }
    }
}
