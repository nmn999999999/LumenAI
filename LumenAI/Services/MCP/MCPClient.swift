import Foundation
import Synchronization

// MARK: - MCP 模型（Model Context Protocol，MCP 支持）

struct MCPTool: Identifiable, Codable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    /// JSON Schema 字符串（inputSchema）
    var inputSchemaJSON: String
}

struct MCPServer: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    /// streamable HTTP 端点，如 https://example.com/mcp
    var url: String
    var headers: [String: String]
    var enabled: Bool
    /// 已发现的工具（持久化，断开后可离线查看）
    var tools: [MCPTool]
    var sessionID: String?
    /// 只承载**真正的失败**（传输 / 协议 / 认证）。UI 用它显示橙色错误行。
    /// 坑：这里曾经被写进「已断开」「已连接，但服务器没有暴露任何工具」这类**状态**，
    /// 后果是用户主动点「断开」被界面当成错误报警，而「连上但零工具」被判成未连接
    /// （菜单给「连接」，再点一次还是同一句自相矛盾的话）。状态文案请写 statusNote。
    var lastError: String?
    /// 非错误的状态说明（如「已断开」「已连接（该服务器未提供工具）」），可为空。
    /// 为什么加在模型上而不是别处：状态和错误是两种语义，混在一个字段里就是上面那个坑的根因。
    /// 兼容性：Optional，合成解码走 decodeIfPresent，旧存档缺这个键也不会解码失败；
    /// 反向（新存档给旧版本读）也只是多一个被忽略的未知键。放在 init 中段是安全的——
    /// 现有构造点（MCPService.addPreset / MCPServerEditSheet.save）全部用标签传参。
    var statusNote: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        headers: [String: String] = [:],
        enabled: Bool = true,
        tools: [MCPTool] = [],
        sessionID: String? = nil,
        lastError: String? = nil,
        statusNote: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.headers = headers
        self.enabled = enabled
        self.tools = tools
        self.sessionID = sessionID
        self.lastError = lastError
        self.statusNote = statusNote
        self.createdAt = createdAt
    }

    /// 是否处于「已连接」状态。
    /// 原来写的是 `sessionID != nil && lastError == nil`：把状态挂到了错误通道上，
    /// 于是任何一次 lastError 赋值（哪怕是「已连接但没工具」这种非错误）都会把服务器
    /// 判成未连接，界面上出现「未连接 · 已连接，但服务器没有暴露任何工具」这种自相矛盾的行。
    /// 现在只认会话：真正的失败会连带把 sessionID 置空（见 MCPService.connect 的 catch），
    /// 所以这个判断依然成立，但状态再也不会被错误污染。
    var connected: Bool { sessionID != nil }
}

// MARK: - 错误

enum MCPError: LocalizedError, Sendable {
    case invalidURL
    case httpError(Int, String)
    case rpcError(String)
    case emptyResult
    /// 端点被出站校验拒绝（scheme 非 https，或公网明文 http）
    case endpointRejected(String)
    /// 用户配置的请求头被拒绝（试图改写 Host/Content-Length 等，或头里含换行）
    case headerRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "MCP 地址无效"
        case .httpError(let code, let body): return "MCP HTTP \(code): \(String(body.prefix(300)))"
        case .rpcError(let msg): return "MCP 错误: \(msg)"
        case .emptyResult: return "MCP 未返回结果"
        case .endpointRejected(let msg): return "MCP 端点被拒绝: \(msg)"
        case .headerRejected(let msg): return "MCP 请求头被拒绝: \(msg)"
        }
    }
}

// MARK: - MCP 客户端（streamable HTTP + JSON-RPC 2.0）

enum MCPClient {

    static let protocolVersion = "2025-03-26"

    /// 建立会话（initialize + notifications/initialized）
    static func initialize(url: String, headers: [String: String]) async throws -> String? {
        let (result, sessionID) = try await request(
            url: url, headers: headers, sessionID: nil,
            method: "initialize",
            params: [
                "protocolVersion": protocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "LumenAI", "version": "1.0"],
            ]
        )
        // notifications/initialized 通知
        _ = try? await request(
            url: url, headers: headers, sessionID: sessionID,
            method: "notifications/initialized", params: [:],
            isNotification: true
        )
        return sessionID
    }

    /// 列出工具
    static func listTools(url: String, headers: [String: String], sessionID: String?) async throws -> [MCPTool] {
        let (result, _) = try await request(
            url: url, headers: headers, sessionID: sessionID,
            method: "tools/list", params: [:]
        )
        guard let dict = result as? [String: Any],
              let tools = dict["tools"] as? [[String: Any]]
        else { return [] }

        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let desc = t["description"] as? String ?? ""
            let schema = t["inputSchema"] as? [String: Any] ?? [:]
            let schemaData = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data()
            return MCPTool(
                name: name,
                description: desc,
                inputSchemaJSON: String(data: schemaData, encoding: .utf8) ?? "{}"
            )
        }
    }

    /// 调用工具，返回文本化结果
    static func callTool(
        url: String, headers: [String: String], sessionID: String?,
        name: String, argumentsJSON: String
    ) async throws -> String {
        var params: [String: Any] = ["name": name]
        if let data = argumentsJSON.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            params["arguments"] = args
        }
        let (result, _) = try await request(
            url: url, headers: headers, sessionID: sessionID,
            method: "tools/call", params: params
        )
        guard let dict = result as? [String: Any] else { throw MCPError.emptyResult }

        // 错误结果
        if let isError = dict["isError"] as? Bool, isError {
            let content = extractText(dict["content"])
            throw MCPError.rpcError(content.isEmpty ? "工具执行失败" : content)
        }
        let text = extractText(dict["content"])
        guard !text.isEmpty else { throw MCPError.emptyResult }
        return text
    }

    private static func extractText(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item -> String? in
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "text": return item["text"] as? String
            case "image": return "[图片 \(item["mimeType"] as? String ?? "")]"
            case "resource", "resource_link": return "[资源 \(item["uri"] as? String ?? "")]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: - JSON-RPC 请求

    private static let requestCounter = Mutex<Int>(0)

    /// 会跟 URLSession/HTTP 框架层抢方向盘的头：Host 决定 SNI 与路由，
    /// Content-Length / Transfer-Encoding 决定报文体长度，Connection 决定连接复用。
    /// 用户配置里塞这些会让请求被静默改写、卡死，或让服务端读到错位的 body。
    private static let forbiddenHeaders: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding",
    ]

    /// 端点出站校验：只允许 https；http 仅限本机/局域网。
    ///
    /// ⚠️ 与 AgentTool.swift 里 http_get 的 SSRF 防护**方向相反**，这不是漏改：
    /// - http_get 的 URL 来自模型/网页内容（不可信输入）→ 那里一律拒绝 http；
    /// - MCP 端点是用户在自己的设置面板里手填的，本地/自托管 MCP（mcp-proxy、
    ///   各种 localhost:3000/mcp 网关、Home Assistant 等）跑在明文 http 上是
    ///   常见且合法的用法，一律拒绝会让「本机 MCP」直接不可用。
    /// 所以这里放行 http，但目的地必须落在回环/私有网段/链路本地/mDNS 名字上：
    /// 公网明文端点仍然拒绝（否则 Authorization token 会明文过网）。
    private static func validatedEndpoint(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw MCPError.invalidURL
        }
        guard let host = url.host, !host.isEmpty else {
            throw MCPError.endpointRejected("地址里没有主机名")
        }
        if scheme == "https" { return url }
        guard scheme == "http" else {
            throw MCPError.endpointRejected("只支持 https（http 仅限本机/局域网），当前是 \(scheme)://")
        }
        guard isLocalOrLANHost(host) else {
            throw MCPError.endpointRejected("http 只允许本机/局域网地址，\(host) 看起来是公网主机；请改用 https")
        }
        return url
    }

    /// 主机名是否属于「本机 / 局域网」。
    /// 只做字面量判断（不解析 DNS）：这里要拦的是「用户手填了一个公网明文地址」，
    /// 不是对抗恶意 DNS（端点本来就是用户自己配的，域名解析权在他手里）。
    private static func isLocalOrLANHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        if h.contains(":") {
            // IPv6：回环、链路本地 fe80::/10、唯一本地 fc00::/7
            return h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd")
        }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            switch (parts[0], parts[1]) {
            case (127, _): return true                       // 回环 127/8
            case (10, _): return true                        // 私有 10/8
            case (192, 168): return true                     // 私有 192.168/16
            case (172, 16...31): return true                 // 私有 172.16/12
            case (169, 254): return true                     // 链路本地 169.254/16
            default: return false
            }
        }
        // 无点的短名（http://nas:3000/mcp）：只能走本地搜索域解析，视作局域网名字放行。
        // 带点又没匹配上私有网段的（如 http://mcp.example.com/mcp）→ 拒绝。
        return !h.contains(".")
    }

    /// ⚠️ 踩过的坑（和本文件 v0.3.40 那段 SSE 解析是同一个 Unicode 陷阱）：
    /// 不能用 `s.contains("\r")` 来判断换行 —— Swift 的 String 按**字形簇**比较，
    /// CRLF 是**一个**字形簇字符，所以 "a\r\nHost: evil.com" 里既 contains 不到 "\r"
    /// 也 contains 不到 "\n"，注入检查会静默失效（实测过：写 contains 的版本放行了注入头）。
    /// 必须在 unicodeScalars 层面查。
    private static func hasHeaderInjection(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\u{0}" }
    }

    /// HTTP 头名只允许 RFC 7230 的 tchar。头名里带空格 / 冒号 / 非 ASCII 时，
    /// URLRequest 会把它静默改写或整个丢掉 —— 正是「用户以为设了、其实没设」的来源。
    private static func isHTTPToken(_ s: String) -> Bool {
        let extra = Set("!#$%&'*+-.^_`|~")
        return !s.isEmpty && s.allSatisfy { c in
            (c.isASCII && (c.isLetter || c.isNumber)) || extra.contains(c)
        }
    }

    /// 应用用户配置的请求头。
    /// 拒绝而不是静默丢弃：静默丢弃最难排查——用户以为头生效了，实际请求里没有，
    /// 表现成「服务器一直 401」这种毫无线索的现象。
    /// Authorization 是允许的（很多 MCP 服务要 Bearer token），但它只来自用户在编辑面板
    /// 填写的 headers，App 自身从不写入 Authorization。
    private static func applyUserHeaders(_ headers: [String: String], to request: inout URLRequest) throws {
        for (name, value) in headers {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { throw MCPError.headerRejected("存在空的请求头名") }
            guard !forbiddenHeaders.contains(key) else {
                throw MCPError.headerRejected("\(name)（该头由 App 自行管理，手填会破坏请求语义）")
            }
            guard isHTTPToken(name) else {
                throw MCPError.headerRejected("\(name)（头名只能是 ASCII 字母/数字和 -_. 等符号，不能有空格或冒号）")
            }
            // 头名/值里的 CR/LF 能伪造出额外的头甚至另一个请求（header injection）。
            // URLRequest 不保证会替你清掉（实测：带 \r\n 的值会被它整条丢掉，静默失效）。
            guard !hasHeaderInjection(name), !hasHeaderInjection(value) else {
                throw MCPError.headerRejected("\(name)（请求头名或值不能包含换行符）")
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func request(
        url: String, headers: [String: String], sessionID: String?,
        method: String, params: [String: Any],
        isNotification: Bool = false
    ) async throws -> (Any?, String?) {
        // 所有请求（initialize / tools/list / tools/call）都从这里出去，端点校验放在这一处即全覆盖
        let requestURL = try validatedEndpoint(url)

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if isNotification {
            if !params.isEmpty { body["params"] = params }
        } else {
            let id = requestCounter.withLock { $0 += 1; return $0 }
            body["id"] = id
            if !params.isEmpty { body["params"] = params }
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        // 用户头放在最后应用（可覆盖上面的默认值，便于对接特殊网关），但要先过白/黑名单校验。
        // 注意：用户若手填 Mcp-Session-Id 会覆盖 App 协商出的会话 ID —— 这是有意的逃生口，
        // 不拦（自托管网关偶有需要固定会话的实现），排查会话类问题时先想到这里。
        try applyUserHeaders(headers, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidURL }
        let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID

        guard (200...299).contains(http.statusCode) else {
            throw MCPError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        // 可能是 SSE 流（streamable HTTP），取第一条 data 行
        // v0.3.40 修复：不能用 split(separator: Character) 切 "\n" —— Swift 的 Unicode 字形簇
        // 把 CRLF 当成一个整体字符，split 切不开 SSE 标准行尾（DeepWiki 等返回 CRLF，
        // 导致整段响应被当一行、data: 解析不到、工具列表全空）。
        // 改用 components(separatedBy:)（子串级切分）+ whitespacesAndNewlines（顺带去掉 \r）。
        var jsonObject: Any?
        let raw = String(data: data, encoding: .utf8) ?? ""
        if raw.contains("data:") {
            for line in raw.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("data:"),
                   let d = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) {
                    jsonObject = obj
                    break
                }
            }
        } else {
            jsonObject = try? JSONSerialization.jsonObject(with: data)
        }

        if isNotification { return (nil, newSessionID) }

        guard let dict = jsonObject as? [String: Any] else { throw MCPError.emptyResult }
        if let error = dict["error"] as? [String: Any],
           let msg = error["message"] as? String {
            throw MCPError.rpcError(msg)
        }
        return (dict["result"], newSessionID)
    }
}
