import Foundation

/// MCP 服务器管理 + Agent 工具目录集成
/// MCP 工具通过「服务」页连接发现，加入 Agent 工具目录，由对话循环执行
@MainActor
final class MCPService: ObservableObject {

    static let shared = MCPService()

    @Published var servers: [MCPServer] = [] {
        didSet {
            persist()
            // 旁挂 schema 表跟着服务器列表重建：连接成功、编辑、删除都会经过这里，
            // 所以不会出现「服务器已删、schema 还留着」的幽灵条目，也不用手工在每个改动点维护。
            // 注意启动加载不走这里（属性观察器在 init 期间不触发），load() 里另有一次显式重建。
            rebuildRawSchemas()
        }
    }
    @Published var connectingID: UUID?

    /// 旁挂的原始 JSON Schema 表（工具名 → 服务端返回的 inputSchema 原始 JSON 字符串）。
    ///
    /// 为什么要单独留一份：`AgentToolDefinition.ParameterSchema` 只有 type / description /
    /// enumValues 三个字段，解析成它之后 required、items（数组元素）、嵌套 object、数字枚举
    /// 全都会丢——而这些恰恰是模型最需要的约束。补全它们要扩展 ParameterSchema，也就是要改
    /// AgentTool.swift（本次不可改：另一个改动正在动它，会冲突），所以先把服务端的原始 schema
    /// 原样留档：等类型扩好之后直接取用，不必为了一个字段重新去连一次服务器。
    /// 局限：按「工具名」索引，不同服务器上的同名工具会互相覆盖（与 server(forToolName:)
    /// 先到先得的行为一致）；已断开的服务器仍然保留（工具列表本身就是离线可看的）。
    private(set) var rawSchemas: [String: String] = [:]

    /// 取某个工具原始的 JSON Schema（供后续拼提示词 / 生成 tools payload 用）。
    /// 说明：MCPService 是 @MainActor 单例，静态方法同样主线程隔离，调用方在主线程调用即可。
    static func rawSchema(forToolName name: String) -> String? {
        shared.rawSchemas[name]
    }

    private func rebuildRawSchemas() {
        var table: [String: String] = [:]
        for server in servers {
            for tool in server.tools { table[tool.name] = tool.inputSchemaJSON }
        }
        rawSchemas = table
    }

    /// 免费公共 MCP 服务预设（免密钥 · streamable HTTP）。
    /// 均为公开社区长期运行的服务：连接失败时显示错误，可随时删除。
    struct MCPPreset: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let url: String
        let note: String
    }

    static let freePresets: [MCPPreset] = [
        MCPPreset(
            name: "DeepWiki",
            url: "https://mcp.deepwiki.com/mcp",
            note: "查询任意 GitHub 仓库的官方文档（免费免密钥）"
        ),
        // ⚠️ ContextX·Grok 搜索曾因公共端点不稳定（2026-08-31 起 /mcp 返回 404）被移除。
        // 如需联网搜索，直接用内置 web_search 工具或 Bing/维基（无需任何 MCP）。
    ]

    private let saveURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        saveURL = docs.appendingPathComponent("mcp-servers.json")
        load()
    }

    func server(id: UUID?) -> MCPServer? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    // MARK: - 增删改

    func upsert(_ server: MCPServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
    }

    func delete(_ server: MCPServer) {
        servers.removeAll { $0.id == server.id }
    }

    /// 一键添加免费预设：同名已存在则直接返回（不重复添加）。
    @discardableResult
    func addPreset(_ preset: MCPPreset) -> MCPServer {
        if let existing = servers.first(where: { $0.name == preset.name }) {
            return existing
        }
        let server = MCPServer(name: preset.name, url: preset.url)
        servers.append(server)
        return server
    }

    // MARK: - 连接 / 断开

    func connect(_ server: MCPServer) async {
        connectingID = server.id
        defer { connectingID = nil }

        var updated = server
        updated.lastError = nil    // 每次连接先清掉上一次的失败，避免旧错误挂在成功状态上
        updated.statusNote = nil
        do {
            let sessionID = try await MCPClient.initialize(url: server.url, headers: server.headers)
            let tools = try await MCPClient.listTools(url: server.url, headers: server.headers, sessionID: sessionID)
            updated.sessionID = sessionID
            updated.tools = tools
            // 「连上了但服务器一个工具都没暴露」是**警告**，不是错误：
            // 很多服务器只提供 resources/prompts，或要额外授权才给工具。
            // 以前把这句话写进 lastError，后果有两层：
            //   1. connected 依赖 lastError == nil → 服务器被判成「未连接」，
            //      界面出现「未连接 · 已连接，但服务器没有暴露任何工具」这种自相矛盾的一行；
            //   2. 右键菜单据此给出「连接」，再点一次还是同一句话，用户以为功能坏了。
            // 现在只写状态说明，lastError 保持 nil → 状态是「已连接」（0 个工具）。
            updated.statusNote = tools.isEmpty ? "已连接（该服务器未提供工具）" : nil
        } catch {
            // 只有真正的传输 / 协议 / 认证失败才进 lastError（UI 用它显示橙色错误行）
            updated.sessionID = nil
            updated.statusNote = nil
            updated.lastError = error.localizedDescription
        }
        upsert(updated)
    }

    func disconnect(_ server: MCPServer) {
        var updated = server
        updated.sessionID = nil
        // 用户主动断开是**正常状态**，不是失败：以前写 lastError = "已断开"，
        // 结果界面按错误处理（橙色 +「未连接 · 已断开」），把用户的正常操作报成故障；
        // 而且 lastError 一旦占着，这个字段就再也分不清「状态」和「错误」了。
        // 断开后清空 lastError，状态说明写 statusNote；工具列表保留（离线可查看）。
        updated.lastError = nil
        updated.statusNote = "已断开"
        upsert(updated)
    }

    // MARK: - Agent 集成

    /// 汇总所有已启用且已连接服务器的工具，转为 Agent 工具目录定义
    var toolDefinitions: [AgentToolDefinition] {
        var defs: [AgentToolDefinition] = []
        for server in servers where server.enabled && server.connected {
            for tool in server.tools {
                defs.append(AgentToolDefinition(
                    id: "mcp-\(server.id.uuidString)-\(tool.name)",
                    name: tool.name,
                    description: tool.description.isEmpty ? "MCP 工具（服务器 \(server.name)）" : tool.description,
                    parameters: Self.parseSchema(tool.inputSchemaJSON),
                    requiresApproval: true  // MCP 工具由第三方服务器提供，权限未知 → 默认需要审批（与 opencode 一致）
                ))
            }
        }
        return defs
    }

    /// 按工具名找到所属服务器
    func server(forToolName name: String) -> (server: MCPServer, tool: MCPTool)? {
        for server in servers where server.enabled && server.connected {
            if let tool = server.tools.first(where: { $0.name == name }) {
                return (server, tool)
            }
        }
        return nil
    }

    /// 调用 MCP 工具（Agent 循环分发）
    func callTool(name: String, argumentsJSON: String) async -> String {
        guard let found = server(forToolName: name) else {
            // 项目约定：工具失败一律以「错误: 」开头，上层据此把这一步标成 error。
            // 原来返回「未知工具: X」——不以「错误: 」开头，于是失败被上层当成普通输出，
            // 对话里看起来像工具"成功返回了一句话"。这里能走到说明服务器刚好被断开/删除，
            // 是真的失败，必须走错误通道。
            return "错误: 未知工具 \(name)（服务器可能已断开）"
        }
        return await callTool(server: found.server, name: name, argumentsJSON: argumentsJSON)
    }

    /// 调用指定服务器上的 MCP 工具（UI 测试用，不要求该工具处于「已连接」也能带 session 尝试）
    func callTool(server: MCPServer, name: String, argumentsJSON: String) async -> String {
        do {
            return try await MCPClient.callTool(
                url: server.url,
                headers: server.headers,
                sessionID: server.sessionID,
                name: name,
                argumentsJSON: argumentsJSON
            )
        } catch {
            // 同一个字符串通道里既有成功结果又有失败原因，上层只能靠前缀区分：
            // 以前是「MCP 调用失败: ...」，不匹配「错误: 」约定 → 失败被当成功显示。
            return "错误: MCP 调用失败 — \(error.localizedDescription)"
        }
    }

    /// 解析 MCP JSON Schema → Agent 参数定义
    ///
    /// 现状局限（重要，别当成漏改）：`ParameterSchema` 只有 type / description / enumValues
    /// 三个字段，装不下 required / items / 嵌套 object，而它是所有模型的工具参数来源
    /// （云端走 tools payload，本地走 AgentService 里的目录文本）。
    /// 本次不能改 AgentTool.swift（另一个改动正在动它），所以采取两条并行的低风险做法：
    ///   1. 原始 schema 另存进 rawSchemas，等 ParameterSchema 扩展后直接用；
    ///   2. 把**现在就能影响模型行为**的信息塞进 description 文本——必填/可选、数组元素类型。
    ///      这是唯一不依赖别人改动就能立刻生效的通道：两个消费方都会把 description 原样
    ///      展示给模型，标上「（必填）」模型才知道哪个参数不能省。
    /// 完整支持（required / items 作为结构化字段）要等 type 扩展，届时 rawSchemas 已经有了。
    private static func parseSchema(_ json: String) -> [String: AgentToolDefinition.ParameterSchema] {
        guard let data = json.data(using: .utf8),
              let schema = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let properties = schema["properties"] as? [String: [String: Any]]
        else { return [:] }

        // required 是 Schema 顶层的数组（不是每个属性上的标记），原来整段被忽略。
        // 读不到就当作「没声明」→ 一律标「可选」而不猜「必填」：乱标必填会逼模型编造参数。
        let required = Set((schema["required"] as? [String]) ?? [])

        var params: [String: AgentToolDefinition.ParameterSchema] = [:]
        for (name, prop) in properties {
            let type = prop["type"] as? String ?? "string"
            var desc = (prop["description"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            desc += (required.contains(name) ? "（必填）" : "（可选）")

            // items 装不进 ParameterSchema，但数组元素类型对模型很关键
            // （传 ["a"] 还是 [1] 直接决定调用成败），用一句自然语言补上，成本最低。
            if type == "array" {
                let itemType = (prop["items"] as? [String: Any])?["type"] as? String ?? "未声明"
                desc += "，数组元素类型: \(itemType)"
            } else if type == "object" {
                desc += "，对象参数（字段结构见工具原始 JSON Schema）"
            }

            // 枚举：原来是 `prop["enum"] as? [String]`，数字枚举（{"enum":[1,2,3]}）会整体丢失
            // ——不是报错，是静默消失，模型拿不到取值范围只能瞎猜字符串。
            // 改为把每个值按「JSON 原本的写法」渲染成字符串：字符串原样（不加引号，描述里带引号
            // 反而干扰模型），数字/布尔/null 走 JSON 片段序列化。之所以不自己 `String(describing:)`：
            // JSONSerialization 解出来的是 NSNumber，NSNumber(1) 桥接成 Bool 也是成功的，
            // 手工转换很容易把 1 变成 "true"，JSON 片段序列化不会有这个坑。
            // ParameterSchema.enumValues 只收 [String]，这是在不动类型定义前提下最接近无损的表达。
            let enumValues: [String]? = (prop["enum"] as? [Any]).map { list in
                list.map { Self.jsonScalarText($0) }
            }

            params[name] = AgentToolDefinition.ParameterSchema(
                type: type,
                description: desc,
                enumValues: enumValues
            )
        }
        return params
    }

    /// 把 JSON 值渲染成适合写进描述 / 枚举列表的短文本（见 parseSchema 里的取舍说明）
    private static func jsonScalarText(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601 // 与 persist 的 iso8601 一致
        guard let decoded = try? decoder.decode([MCPServer].self, from: data)
        else { return }

        // 旧存档迁移：老版本把「状态」错写进了 lastError（详见 MCPServer.lastError 的注释）。
        // 不迁移的话，升级后用户主动断开过的服务器会一直顶着一句假的错误文案（橙色），
        // 而「连上但没工具」的服务器会被判成未连接。只认这两句历史文案，
        // 其余（HTTP 401、rpc error、地址无效…）是真正的失败，原样保留。
        let staleStatus: Set<String> = ["已断开", "已连接，但服务器没有暴露任何工具"]
        let migrated = decoded.map { server -> MCPServer in
            guard let err = server.lastError, staleStatus.contains(err) else { return server }
            var fixed = server
            fixed.lastError = nil
            if fixed.statusNote == nil {
                fixed.statusNote = (err == "已断开") ? "已断开" : "已连接（该服务器未提供工具）"
            }
            return fixed
        }

        servers = migrated
        // 必须在这里显式重建一次：Swift 的属性观察器在 init 期间不触发，
        // 而 load() 就是被 init 调用的，所以上面的 servers.didSet 里那次重建不会发生。
        // 少了这行，冷启动后 rawSchemas 是空表，rawSchema(forToolName:) 会对已持久化的工具返回 nil。
        rebuildRawSchemas()
    }

    private func persist() {
        let snapshot = servers
        let url = saveURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
