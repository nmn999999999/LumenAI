import Foundation

// MARK: - Tool 分组（阶段 7）
//
// 把工具按「能力域」归组。分组不是给模型看的协议，而是 Runtime 内部用来
// 做候选筛选的粒度：先判断请求属于哪些 group，再展开该 group 内的具体工具。
// 这样既不改变 Tool Executor 的 API，也不需要模型先学一套"先问组、再展开"的新协议
// （那会显著提高本地/云端模型的指令遵循成本，得不偿失）。
enum ToolGroup: String, CaseIterable, Sendable {
    case web          // 联网：搜索 / 抓取 / 链接
    case filesystem   // 文件与命令：读写 / shell / 远程执行
    case developer    // 开发相关：json / 正则 / 编码 / 插件
    case system       // 系统信息：设备 / 时间 / 剪贴板
    case computation  // 计算与生成：数学 / 随机 / 文本变换
    case memory       // 记忆与计划：note / todo
    case other        // MCP / 插件等外部工具（按名字启发式归类，兜底）
}

// MARK: - Tool Router（阶段 5）+ Compact Schema（阶段 6）

/// 工具路由配置。全部字段可调，便于 A/B 与回滚。
struct ToolRoutingConfig: Sendable {
    /// 总开关。关掉 = 回到"全量工具 + 详细 schema"的旧行为（仅用于 A/B baseline）。
    var enabled: Bool = true
    /// 是否使用 compact schema 渲染（不改变选中集合，只改变表达形式）。
    /// 这是**零风险**的 token 优化：工具集合不变，模型仍看得到全部工具。
    var useCompactSchema: Bool = true
    /// compact 时单条描述的最大字符数。
    var compactDescriptionLimit: Int = 90

    init() {}
}

/// 路由结果。
struct ToolRoutedCatalog: Sendable {
    /// 最终暴露给模型的工具（顺序保持原始声明顺序 → 提示词前缀稳定）。
    let tools: [AgentToolDefinition]
    /// 已渲染的工具目录文本。
    let catalog: String
    /// 是否真的做了裁剪（false = 全量，只是可能换成了 compact 表达）。
    let routed: Bool

    var exposedCount: Int { tools.count }
}

/// 轻量工具路由器。
///
/// 设计原则（**命中率优先**）：
///   1. **compact schema 永远可用**：即使不做裁剪，也用紧凑表达降低 schema token ——
///      工具集合不变，因此对命中率零影响。
///   2. **只在信号明确时才裁剪**：请求里若匹配不到任何 group 关键词，
///      直接返回全量（只做 compact），绝不"猜"着砍工具。
///   3. **核心能力组始终保留**：note / todo / 搜索 / 文件等常用工具永远在列。
///   4. **本 run 已用过的工具永远保留**：已经在使用的工具绝不会因为路由被隐藏。
///   5. 命中某个 group 时**整组展开**，而不是只取该组里排名最高的几个 ——
///      否则"请求确实属于这个域，但恰好需要的那个工具被 Top-K 挤掉"，命中率必然下降。
enum ToolRouter {

    /// 核心工具：无论路由结果如何都保留，作为"能力下限"。
    static let coreToolNames: [String] = [
        "note", "todo", "web_search", "http_get",
        "current_time", "calculator", "device_info",
        "file_op", "shell", "create_plugin",
    ]

    /// 内置工具 → group 的显式映射。
    static let explicitGroup: [String: ToolGroup] = [
        "http_get": .web, "web_search": .web, "extract_urls": .web,
        "file_op": .filesystem, "shell": .filesystem, "ssh": .filesystem,
        "create_plugin": .developer, "json_query": .developer, "json_format": .developer,
        "regex_extract": .developer, "jwt_decode": .developer, "hash_text": .developer,
        "url_codec": .developer, "number_base": .developer, "color_convert": .developer,
        "case_convert": .developer, "csv_table": .developer, "find_replace": .developer,
        "sort_text": .developer, "text_transform": .developer, "text_summary": .developer,
        "device_info": .system, "current_time": .system, "timestamp": .system,
        "date_add": .system, "date_diff": .system, "clipboard": .system,
        "calculator": .computation, "random_number": .computation,
        "generate_uuid": .computation, "unit_convert": .computation,
        "roman": .computation, "word_count": .computation, "password_generate": .computation,
        "note": .memory, "todo": .memory,
    ]

    /// group → 触发关键词（大小写不敏感；中英混合，避免只覆盖一种语言）。
    static let groupAliases: [ToolGroup: [String]] = [
        .web: ["搜索", "搜一下", "查一下", "联网", "上网", "网页", "网站", "网址", "链接",
               "抓取", "爬取", "新闻", "天气", "汇率", "股票", "接口", "api",
               "http", "https", "url", "web", "search", "fetch", "browse", "crawl"],
        .filesystem: ["文件", "目录", "文件夹", "路径", "读写", "保存", "写入", "创建", "删除",
                      "重命名", "列出", "命令", "终端", "脚本", "服务器", "远程",
                      "file", "folder", "directory", "path", "shell", "bash", "command",
                      "script", "ssh", "server", "remote"],
        .developer: ["json", "正则", "regex", "哈希", "摘要", "md5", "sha", "编码", "解码",
                     "base64", "jwt", "token", "插件", "plugin", "代码", "格式化", "csv",
                     "表格", "替换", "提取", "进制", "颜色", "命名", "开发", "编程"],
        .system: ["设备", "机型", "系统版本", "电量", "内存", "存储", "剪贴板", "时间", "日期",
                  "时间戳", "时区", "device", "clipboard", "time", "date", "timestamp"],
        .computation: ["计算", "数学", "算术", "随机", "密码", "uuid", "编号", "字数",
                       "统计", "单位", "换算", "罗马", "大小写", "排序", "去重", "转换"],
        .memory: ["记住", "记一下", "笔记", "记忆", "备忘录", "待办", "计划", "步骤",
                  "清单", "进度", "任务", "note", "todo", "memory", "plan"],
    ]

    /// 归类一个工具（内置查表；外部工具按名字启发式）。
    static func group(of name: String) -> ToolGroup {
        if let g = explicitGroup[name] { return g }
        let n = name.lowercased()
        if n.contains("search") || n.contains("web") || n.contains("http") || n.contains("fetch") {
            return .web
        }
        if n.contains("file") || n.contains("shell") || n.contains("fs") || n.contains("ssh") {
            return .filesystem
        }
        return .other
    }

    /// 路由：返回本轮应暴露的工具 + 渲染好的目录文本。
    ///
    /// - Parameters:
    ///   - request: 本轮用户请求（取最近一条 user 消息即可）。
    ///   - tools: 完整工具目录（Registry 本体，绝不会被修改）。
    ///   - recentlyUsed: 本 run 已经调用过的工具名（永远保留）。
    ///   - config: 配置。
    static func route(request: String,
                      tools: [AgentToolDefinition],
                      recentlyUsed: Set<String>,
                      config: ToolRoutingConfig = ToolRoutingConfig()) -> ToolRoutedCatalog {
        // 总开关关闭：全量，仅按需 compact（用于 A/B baseline）。
        guard config.enabled else {
            return ToolRoutedCatalog(
                tools: tools,
                catalog: ToolSchemaFormatter.render(tools, compact: false),
                routed: false)
        }

        let req = request.lowercased()

        // 1) 命中的 group（整组展开）
        var matchedGroups = Set<ToolGroup>()
        for (group, aliases) in groupAliases where aliases.contains(where: { req.contains($0) }) {
            matchedGroups.insert(group)
        }

        // 2) 工具名 token 直接命中（覆盖 MCP / 插件这类没有别名表的工具）
        var nameMatched = Set<String>()
        for t in tools {
            for token in t.name.lowercased().split(separator: "_") where token.count >= 3 {
                if req.contains(token) { nameMatched.insert(t.name); break }
            }
        }

        // 3) 无任何信号：不裁剪，只做 compact —— 命中率零风险
        if matchedGroups.isEmpty && nameMatched.isEmpty {
            return ToolRoutedCatalog(
                tools: tools,
                catalog: ToolSchemaFormatter.render(tools, compact: config.useCompactSchema,
                                                    descriptionLimit: config.compactDescriptionLimit),
                routed: false)
        }

        // 4) 组装选中集合（保持原始顺序）
        let core = Set(coreToolNames)
        let selectedNames = Set(
            tools.filter { t in
                core.contains(t.name)
                || recentlyUsed.contains(t.name)
                || nameMatched.contains(t.name)
                || matchedGroups.contains(group(of: t.name))
                // MCP / 插件工具（.other）**永远保留**：它们是用户自己装的，
                // 名字/描述多为英文或自定义，路由关键词覆盖不到；一旦被隐藏，
                // 用户会看到"装好的工具调不到"，这是比多花几个 token 严重得多的问题。
                || group(of: t.name) == .other
            }.map(\.name)
        )

        // 全量等价：同样是"没裁剪"
        if selectedNames.count >= tools.count {
            return ToolRoutedCatalog(
                tools: tools,
                catalog: ToolSchemaFormatter.render(tools, compact: config.useCompactSchema,
                                                    descriptionLimit: config.compactDescriptionLimit),
                routed: false)
        }

        let selected = tools.filter { selectedNames.contains($0.name) }
        return ToolRoutedCatalog(
            tools: selected,
            catalog: ToolSchemaFormatter.render(selected, compact: config.useCompactSchema,
                                                descriptionLimit: config.compactDescriptionLimit),
            routed: true)
    }
}

// MARK: - Compact Tool Schema（阶段 6）

/// LLM-facing 的工具目录渲染。
///
/// ⚠️ 这里**只改变暴露给模型的表达形式**，绝不动 `AgentToolDefinition` /
/// Tool Executor 的真实 schema —— 执行侧仍然拿完整参数定义。
///
/// compact 形式：`- tool_name(arg1, arg2) — 一句话说明`
/// 完整形式：保持改造前的 `- name: desc` + `参数:` 明细（本地冻结契约用）。
enum ToolSchemaFormatter {

    /// 渲染整个目录。
    static func render(_ tools: [AgentToolDefinition],
                       compact: Bool,
                       descriptionLimit: Int = 90) -> String {
        if compact {
            return tools.map { compactLine($0, descriptionLimit: descriptionLimit) }
                .joined(separator: "\n")
        }
        return tools.map { fullText($0) }.joined(separator: "\n")
    }

    /// compact 单行：工具名(参数名列表) — 截断描述。
    static func compactLine(_ tool: AgentToolDefinition, descriptionLimit: Int = 90) -> String {
        var desc = tool.description
        if desc.count > descriptionLimit { desc = String(desc.prefix(descriptionLimit)) + "…" }
        let args = tool.parameters.keys.sorted().joined(separator: ", ")
        let signature = args.isEmpty ? "" : "(\(args))"
        return "- \(tool.name)\(signature) — \(desc)"
    }

    /// 完整形式（改造前行为，逐字保持；本地冻结契约使用）。
    static func fullText(_ tool: AgentToolDefinition, descriptionLimit: Int = Int.max) -> String {
        var desc = tool.description
        if desc.count > descriptionLimit { desc = String(desc.prefix(descriptionLimit)) + "…" }
        var lines = "- \(tool.name): \(desc)"
        if !tool.parameters.isEmpty {
            let params = tool.parameters.map { name, schema -> String in
                var s = "  - \(name) (\(schema.type))"
                if !schema.description.isEmpty { s += ": \(schema.description)" }
                if let enums = schema.enumValues, !enums.isEmpty {
                    s += " [可选: \(enums.joined(separator: " / "))]"
                }
                return s
            }.joined(separator: "\n")
            lines += "\n  参数:\n\(params)"
        }
        return lines
    }
}