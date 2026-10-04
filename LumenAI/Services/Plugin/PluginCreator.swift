import Foundation

/// 对话内生成插件（`create_plugin` 工具）的执行入口。
///
/// 这是"AI 给自己装能力"叙事的落地点：模型把 manifest 字段 + tools.js 源码作为工具参数
/// 交上来，**经用户在安装卡片上确认后**（审批在 AgentService 层，本类只在批准后被调用），
/// 先在内存里预检、再落盘安装。
///
/// 安全边界（与"远端/手动导入插件"完全同一套，不新增任何能力面）：
/// - 代码跑在 JavaScriptCore 沙盒里（见 JSPluginEngine 头注释）：无文件系统桥、无 shell；
///   network 仅 https / 20s / 2MB；storage 仅模块私有 storage.json；30s 调用看门狗。
/// - id 必须过 PluginManager.safeModuleID（防路径穿越）；
/// - 权限白名单（只认识 network / storage，多一个字符都拒绝安装）；
/// - 工具名正则 + 与内置/MCP/其他模块的冲突检查（冲突的插件工具会被内置静默顶掉，
///   装了等于没装 —— 所以这里直接判失败让模型改名，而不是装完再警告）；
/// - 预检在**不落盘**的前提下真实加载一次脚本（语法错 / 没注册工具 / 顶层死循环都进不来）。
@MainActor
enum PluginCreator {

    /// 生成代码的长度上限。演示/实用插件都是几十行级，20KB 给足空间，
    /// 同时限制模型失误（把整段对话塞进代码）和顶层求值成本。
    static let maxCodeLength = 20_000
    /// 一个生成插件最多注册的工具数。
    static let maxTools = 8
    /// 生成插件的作者标记（在「插件」页可见，与用户手写/远端模块区分）。
    static let generatedAuthor = "AI（对话内生成）"
    /// 预检超时：模型可能交出顶层死循环的脚本。JSCore 无法中止求值（与调用超时同一个
    /// 已知限制），所以预检放后台线程跑并和超时竞速；超时后那个线程只能泄漏到 App 退出，
    /// 但主线程/UI 不受影响（不能在 MainActor 上直接做无超时的 queue.sync 求值）。
    private static let preflightTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// 从工具参数里取展示名（审批卡片/气泡 chip 的标题用）。取不到返回 nil。
    static func displayName(fromArgumentsJSON json: String) -> String? {
        guard let args = parseArgs(json),
              let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return String(name.prefix(40))
    }

    /// 执行安装（返回给模型的文本；遵循"错误: "前缀约定，见 ToolResultFormat）。
    static func create(argumentsJSON: String) async -> String {
        guard let args = parseArgs(argumentsJSON) else {
            return "错误: create_plugin 参数不是合法 JSON 对象，需要 id/name/tools_js 等字段"
        }

        // ── ① 字段解析与基础校验 ─────────────────────────────────────────────
        guard let rawID = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              PluginManager.safeModuleID(rawID) != nil else {
            return "错误: id 缺失或非法（只允许字母数字 . _ -，不能以点开头，长度 ≤64，如 text-tools）"
        }
        let id = rawID
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return "错误: name 必填（给用户看的模块名称，如「文本工具集」）"
        }
        let safeName = String(name.prefix(40))
        let description = String(((args["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        let version = {
            let v = (args["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "1.0.0" : String(v.prefix(20))
        }()
        guard let toolsJS = args["tools_js"] as? String, !toolsJS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "错误: tools_js 必填（插件的完整 JavaScript 源码，需调用 registerTool 注册工具）"
        }
        guard toolsJS.count <= maxCodeLength else {
            return "错误: tools_js 过长（\(toolsJS.count) 字符，上限 \(maxCodeLength)），请精简实现"
        }

        // 权限白名单：宁可拒绝也不带着不认识的权限安装（权限字符串决定引擎暴露哪些原生桥）。
        let permissions = parsePermissions(args["permissions"])
        if case .invalid(let bad) = permissions {
            return "错误: 不支持的权限「\(bad)」，只允许 network（联网，仅 https）与 storage（模块本地存储）；纯计算插件传空数组即可"
        }
        let perms = permissions.value

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let manifest = PluginManifest(
            id: id,
            name: safeName,
            version: version,
            description: description.isEmpty ? "（无描述）" : description,
            author: generatedAuthor,
            minAppVersion: appVersion,
            permissions: perms
        )

        // ── ② 内存预检（不落盘）：真实加载一次脚本 ───────────────────────────
        // JSPluginEngine 初始化失败（init? = nil）只有两类：JSContext 建不起来，
        // 或脚本求值后没有注册出任何工具（语法错/异常也会走到这里）。
        let preflight = await loadEngineOffActor(manifest: manifest, toolsJS: toolsJS)
        guard let engine = preflight else {
            return "错误: 脚本预检失败/超时：tools.js 无法加载，或没有通过 registerTool 注册任何工具。"
                + "请检查 JS 语法（JSCore 环境），确认源码末尾调用了 registerTool({name, description, parameters, run})，然后用修正后的源码重试"
        }
        let registered = engine.tools
        guard !registered.isEmpty else {
            return "错误: 脚本预检通过但没有注册任何工具（registerTool 的参数必须含字符串 name 和函数 run）"
        }
        guard registered.count <= maxTools else {
            return "错误: 一个插件最多注册 \(maxTools) 个工具（当前 \(registered.count) 个），请拆分或只保留核心工具"
        }

        // 工具名校验 + 冲突检查。
        let namePattern = #"^[a-z][a-z0-9_]{0,40}$"#
        var normalizedNames: [String] = []
        for tool in registered {
            guard tool.name.range(of: namePattern, options: .regularExpression) != nil else {
                return "错误: 工具名「\(tool.name.prefix(50))」非法：必须以小写字母开头，只含小写字母/数字/下划线，长度 ≤41"
            }
            // 同插件内重名也判失败：后注册的会被先注册的顶掉，模型无从察觉。
            if normalizedNames.contains(tool.name) {
                return "错误: 插件内存在重复工具名「\(tool.name)」，请改名后重试"
            }
            normalizedNames.append(tool.name)
        }
        if let collision = collisionName(toolNames: normalizedNames, moduleID: id) {
            return "错误: 工具名「\(collision)」与已有工具冲突（内置/MCP/其他插件同名时内置优先，这个工具永远不会被调用）。请换一个独特的名字（建议加业务前缀）后重试"
        }

        // ── ③ 落盘安装（install 内部会再做 id 白名单 + 路径兜底并重载引擎）─────
        let isUpdate = PluginManager.shared.modules.contains { $0.id == id }
        let entry = ModuleIndexEntry(
            id: id,
            name: safeName,
            version: version,
            description: manifest.description,
            author: generatedAuthor,
            minAppVersion: appVersion,
            permissions: perms,
            files: .init(manifest: "", tools: "")
        )
        do {
            try PluginManager.shared.install(entry: entry, manifest: manifest, jsSource: toolsJS)
        } catch {
            return "错误: 插件安装失败: \(error.localizedDescription.prefix(120))"
        }

        // ── ④ 成功回执（给模型看的行动指引，不是给用户的 UI 文案）──────────────
        guard let installed = PluginManager.shared.modules.first(where: { $0.id == id }) else {
            // 理论不可达：install 成功后必然能在 modules 里找到。
            return "错误: 插件已写入但未能加载，请换一个 id 重试"
        }
        let permText = perms.isEmpty ? "纯计算（无额外权限）" : perms.sorted().joined(separator: "、")
        let toolLines = installed.engine.tools.map { tool -> String in
            let params = tool.parameters.keys.sorted()
            let paramText = params.isEmpty ? "无参数" : "参数: \(params.joined(separator: ", "))"
            return "  - \(tool.name): \(tool.description.isEmpty ? "（无描述）" : tool.description)（\(paramText)）"
        }.joined(separator: "\n")
        var lines = [
            "插件「\(safeName)」\(isUpdate ? "已更新到" : "已安装") v\(version)（id: \(id)，权限: \(permText)），注册了 \(installed.engine.tools.count) 个工具：",
            toolLines,
            "这些工具已在**本次任务中立即可用**，你现在就可以直接按其参数调用，不需要再安装；插件会持久保留，以后的对话也能直接用。"
        ]
        if perms.contains("network") {
            lines.append("注意：含 network 权限的工具真正联网前仍会请用户逐次授权。")
        }
        lines.append("如果用户对结果不满意，可用相同 id 提交修正后的 tools_js 完成更新；用户也可以随时在「插件」页删除它。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 私有工具

    private enum PermissionParse {
        case ok([String])
        /// 白名单外的权限名
        case invalid(String)
        var value: [String] { if case .ok(let v) = self { return v }; return [] }
    }

    /// 模型可能把 permissions 传成数组、字符串甚至 null，统一归一化；去重保序。
    private static func parsePermissions(_ raw: Any?) -> PermissionParse {
        var names: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !t.isEmpty, t != "none" else { return }
            guard t == "network" || t == "storage" else {
                names = ["__bad__:\(t)"]
                return
            }
            if !names.contains(t) { names.append(t) }
        }
        if let arr = raw as? [Any] {
            for item in arr {
                if let s = item as? String { add(s) } else { return .invalid(String(String(describing: item).prefix(20))) }
                if let bad = names.first(where: { $0.hasPrefix("__bad__:") }) {
                    return .invalid(String(bad.dropFirst("__bad__:".count)))
                }
            }
        } else if let s = raw as? String {
            // 容错："network,storage" / "network storage"
            s.split(whereSeparator: { [",", " ", "，", ";"].contains($0) }).forEach { add(String($0)) }
            if let bad = names.first(where: { $0.hasPrefix("__bad__:") }) {
                return .invalid(String(bad.dropFirst("__bad__:".count)))
            }
        } else if raw != nil, !(raw is NSNull) {
            return .invalid(String(String(describing: raw ?? "").prefix(20)))
        }
        return .ok(names)
    }

    private static func parseArgs(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// 工具名是否与内置/MCP/其他模块（不含正在更新的同 id 模块）冲突。
    private static func collisionName(toolNames: [String], moduleID: String) -> String? {
        let builtin = Set(BuiltInTools.allTools.map(\.name))
        let mcp = Set(MCPService.shared.toolDefinitions.map(\.name))
        var others: Set<String> = []
        for module in PluginManager.shared.modules where module.id != moduleID {
            module.engine.tools.forEach { others.insert($0.name) }
        }
        return toolNames.first { builtin.contains($0) || mcp.contains($0) || others.contains($0) }
    }

    /// 一次性闸门：竞速的两方只有第一个能"赢"，负者静默丢弃（不 resume 第二次）。
    private actor PreflightGate {
        private var finished = false
        /// 首达者原样返回其载荷（引擎或 nil=超时）；迟到者返回 nil（什么也别做）。
        func win(_ value: JSPluginEngine?) -> JSPluginEngine? {
            if finished { return nil }
            finished = true
            return value
        }
    }

    /// 在后台协作线程上构造预检引擎，并与 10s 超时竞速；**不等待负者**。
    ///
    /// 为什么不能用 withTaskGroup：group 退出前会隐式 await 全部子任务 —— 超时后那个
    /// 顶层死循环的求值任务永不结束，group 也就永不返回，安装流程会被它拖死（只是没冻 UI）。
    /// 这里用两个 detached 任务 + PreflightGate：先到的 resume continuation，
    /// 迟到的（包括泄漏到 App 退出的死循环求值，JSCore 无法中止，这是引擎层已知限制）
    /// 直接丢弃，安装流程按超时失败把错误还给模型。
    private static func loadEngineOffActor(manifest: PluginManifest, toolsJS: String) async -> JSPluginEngine? {
        let gate = PreflightGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<JSPluginEngine?, Never>) in
            Task.detached {
                let engine = JSPluginEngine(manifest: manifest, jsSource: toolsJS, storageFile: nil)
                if let winner = await gate.win(engine) { cont.resume(returning: winner) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: preflightTimeoutNanoseconds)
                if let winner = await gate.win(nil) { cont.resume(returning: winner) }
            }
        }
    }
}
