import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

struct AgentToolDefinition: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let parameters: [String: ParameterSchema]
    /// 该工具调用前是否需要用户授权(opencode 风格).
    /// 网络/IPC 类副作用工具(SSH、MCP)默认 true；纯计算类(calculator/encoder)默认 false。
    /// 旧存档反序列化时若缺该字段，fallback 为 false（保持旧行为，向后兼容）。
    let requiresApproval: Bool

    struct ParameterSchema: Codable, Sendable {
        let type: String
        let description: String
        let enumValues: [String]?

        enum CodingKeys: String, CodingKey {
            case type, description
            case enumValues = "enum"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, parameters, requiresApproval
    }

    init(
        id: String,
        name: String,
        description: String,
        parameters: [String: ParameterSchema],
        requiresApproval: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresApproval = requiresApproval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decode(String.self, forKey: .description)
        self.parameters = try c.decode([String: ParameterSchema].self, forKey: .parameters)
        // 旧存档没有 requiresApproval：默认 false（保持旧行为，向后兼容）
        self.requiresApproval = try c.decodeIfPresent(Bool.self, forKey: .requiresApproval) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(requiresApproval, forKey: .requiresApproval)
    }
}

struct ToolCallRequest: Codable {
    let name: String
    let arguments: [String: AnyCodable]

    struct AnyCodable: Codable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) {
                value = intVal
            } else if let doubleVal = try? container.decode(Double.self) {
                value = doubleVal
            } else if let boolVal = try? container.decode(Bool.self) {
                value = boolVal
            } else if let stringVal = try? container.decode(String.self) {
                value = stringVal
            } else if let arrayVal = try? container.decode([AnyCodable].self) {
                value = arrayVal.map(\.value)
            } else if let dictVal = try? container.decode([String: AnyCodable].self) {
                value = dictVal.mapValues(\.value)
            } else {
                value = ""
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let intVal = value as? Int {
                try container.encode(intVal)
            } else if let doubleVal = value as? Double {
                try container.encode(doubleVal)
            } else if let boolVal = value as? Bool {
                try container.encode(boolVal)
            } else if let stringVal = value as? String {
                try container.encode(stringVal)
            } else if let arrayVal = value as? [Any] {
                try container.encode(arrayVal.map { AnyCodable($0) })
            } else if let dictVal = value as? [String: Any] {
                try container.encode(dictVal.mapValues { AnyCodable($0) })
            } else {
                try container.encode("")
            }
        }
    }
}

enum BuiltInTools {

    static let allTools: [AgentToolDefinition] = [
        AgentToolDefinition(
            id: "http_get",
            name: "http_get",
            description: "发起 HTTP GET 请求抓取网页 / JSON API 内容(仅 https)。返回文本;若响应是 JSON 会自动美化。适合获取天气 API、GitHub API、新闻 RSS 等公开数据",
            parameters: [
                "url": .init(type: "string", description: "完整 URL(https://...),如 https://api.github.com/repos/nmn999999999/LumenAI/releases/latest", enumValues: nil),
                "timeout": .init(type: "number", description: "超时秒数(可选,默认 15)", enumValues: nil)
            ],
            requiresApproval: true,  // 网络请求会访问外部站点
        ),
        AgentToolDefinition(
            id: "device_info",
            name: "device_info",
            description: "获取当前 iOS 设备信息:机型、系统版本、内存/存储容量、当前电量、进程架构等",
            parameters: [:],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "json_query",
            name: "json_query",
            description: "从 JSON 字符串中提取指定 key 的值(支持 a.b.c 点路径与 [0] 数组下标),返回格式化文本",
            parameters: [
                "json": .init(type: "string", description: "要查询的 JSON 字符串", enumValues: nil),
                "path": .init(type: "string", description: "取值路径,如 user.name、items[0].title", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "timestamp",
            name: "timestamp",
            description: "Unix 时间戳与日期互转:给 0-1e10 之间数字按秒解释,给 '2026-08-29 10:00:00' 或 '2026-08-29' 转时间戳;支持时区偏移(hours)",
            parameters: [
                "value": .init(type: "string", description: "要转换的值:秒级时间戳(如 1756483200)或日期字符串(如 2026-08-29 10:00:00)", enumValues: nil),
                "timezone_offset": .init(type: "number", description: "时区偏移小时数(可选,默认 +8 中国时区)", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "extract_urls",
            name: "extract_urls",
            description: "从一段文本中提取所有 URL 链接,返回去重列表",
            parameters: [
                "text": .init(type: "string", description: "要提取链接的文本", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "csv_table",
            name: "csv_table",
            description: "把 CSV / TSV 文本解析为对齐的表格展示,可选带表头;分隔符默认逗号",
            parameters: [
                "text": .init(type: "string", description: "CSV/TSV 原始文本(每行一条记录)", enumValues: nil),
                "delimiter": .init(type: "string", description: "分隔符(可选,默认 ,;传 tab 用 \\t)", enumValues: nil),
                "header": .init(type: "boolean", description: "首行是否为表头(默认 true)", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "jwt_decode",
            name: "jwt_decode",
            description: "解码 JWT(不验签):提取 header 与 payload 的 JSON 内容并美化,附带过期时间解读",
            parameters: [
                "token": .init(type: "string", description: "JWT 字符串(形如 eyJhbGciOi... .eyJzdWIiOi... .signature)", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "calculator",
            name: "calculator",
            description: "计算数学表达式，支持 + - * / % ^、括号、函数(sqrt/abs/round/sin/cos/tan/log/exp/min/max/pow)与常量(pi/e)",
            parameters: [
                "expression": .init(type: "string", description: "数学表达式，如 2+3*4 或 sqrt(16)", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "current_time",
            name: "current_time",
            description: "获取当前日期和时间",
            parameters: [:],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "generate_uuid",
            name: "generate_uuid",
            description: "生成一个UUID",
            parameters: [:],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "random_number",
            name: "random_number",
            description: "生成指定范围内的随机整数",
            parameters: [
                "min": .init(type: "number", description: "最小值（含），默认 1", enumValues: nil),
                "max": .init(type: "number", description: "最大值（含），默认 100", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "word_count",
            name: "word_count",
            description: "统计文本的字数、字符数和行数",
            parameters: [
                "text": .init(type: "string", description: "要统计的文本", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "text_transform",
            name: "text_transform",
            description: "转换文本格式：大写、小写、反转、Base64编码/解码",
            parameters: [
                "text": .init(type: "string", description: "要转换的文本", enumValues: nil),
                "transform": .init(type: "string", description: "转换类型", enumValues: ["uppercase", "lowercase", "reverse", "base64_encode", "base64_decode"])
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "date_add",
            name: "date_add",
            description: "计算某个日期加减 N 天后的日期，date 为空表示今天",
            parameters: [
                "date": .init(type: "string", description: "日期，格式 yyyy-MM-dd，可省略表示今天", enumValues: nil),
                "days": .init(type: "number", description: "加减的天数，负数表示往前", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "date_diff",
            name: "date_diff",
            description: "计算两个日期相差的天数",
            parameters: [
                "date1": .init(type: "string", description: "起始日期 yyyy-MM-dd", enumValues: nil),
                "date2": .init(type: "string", description: "结束日期 yyyy-MM-dd", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "hash_text",
            name: "hash_text",
            description: "计算文本的 MD5 / SHA1 / SHA256 摘要",
            parameters: [
                "text": .init(type: "string", description: "要哈希的文本", enumValues: nil),
                "algorithm": .init(type: "string", description: "算法", enumValues: ["md5", "sha1", "sha256"])
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "json_format",
            name: "json_format",
            description: "格式化或压缩 JSON 字符串",
            parameters: [
                "json": .init(type: "string", description: "要处理的 JSON 字符串", enumValues: nil),
                "pretty": .init(type: "boolean", description: "是否美化输出（默认 true）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "url_codec",
            name: "url_codec",
            description: "URL 编码或解码文本",
            parameters: [
                "text": .init(type: "string", description: "要处理的文本", enumValues: nil),
                "mode": .init(type: "string", description: "模式", enumValues: ["encode", "decode"])
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "note",
            name: "note",
            description: "持久化笔记（本机存储，可跨对话记忆）：save 保存、read 读取、list 列出全部、delete 删除",
            parameters: [
                "op": .init(type: "string", description: "操作", enumValues: ["save", "read", "list", "delete"]),
                "name": .init(type: "string", description: "笔记名称（save/read/delete 必填）", enumValues: nil),
                "content": .init(type: "string", description: "笔记内容（save 必填）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "clipboard",
            name: "clipboard",
            description: "读取或设置系统剪贴板",
            parameters: [
                "op": .init(type: "string", description: "操作", enumValues: ["get", "set"]),
                "text": .init(type: "string", description: "要写入剪贴板的内容（set 必填）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "web_search",
            name: "web_search",
            description: "联网搜索网页（Bing 等），返回相关结果标题、链接与摘要",
            parameters: [
                "query": .init(type: "string", description: "搜索关键词", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "regex_extract",
            name: "regex_extract",
            description: "使用正则表达式从文本中提取匹配的内容",
            parameters: [
                "text": .init(type: "string", description: "要搜索的文本", enumValues: nil),
                "pattern": .init(type: "string", description: "正则表达式模式", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "text_summary",
            name: "text_summary",
            description: "对文本进行智能摘要，提取关键信息",
            parameters: [
                "text": .init(type: "string", description: "要摘要的文本", enumValues: nil),
                "max_length": .init(type: "number", description: "摘要最大长度（可选，默认200）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "number_base",
            name: "number_base",
            description: "进制转换：在 decimal(十进制)/binary(二进制)/octal(八进制)/hex(十六进制) 之间互转",
            parameters: [
                "value": .init(type: "string", description: "要转换的数值，如 255 或 FF", enumValues: nil),
                "from": .init(type: "string", description: "原进制", enumValues: ["decimal", "binary", "octal", "hex"]),
                "to": .init(type: "string", description: "目标进制", enumValues: ["decimal", "binary", "octal", "hex"])
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "color_convert",
            name: "color_convert",
            description: "颜色转换：十六进制(#RRGGBB)与 RGB(255,0,0) 互转",
            parameters: [
                "mode": .init(type: "string", description: "转换方向", enumValues: ["to_hex", "to_rgb"]),
                "value": .init(type: "string", description: "to_hex 时传 RGB 如 255,0,0；to_rgb 时传十六进制如 #ff0000 或 ff0000", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "sort_text",
            name: "sort_text",
            description: "按行排序文本，可选去重/忽略大小写/逆序",
            parameters: [
                "text": .init(type: "string", description: "要排序的文本（按换行分行）", enumValues: nil),
                "reverse": .init(type: "boolean", description: "是否逆序（默认 false）", enumValues: nil),
                "ignore_case": .init(type: "boolean", description: "排序时忽略大小写（默认 false）", enumValues: nil),
                "dedup": .init(type: "boolean", description: "是否去除重复行（默认 false）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "find_replace",
            name: "find_replace",
            description: "在文本中查找并替换内容，支持正则与普通文本",
            parameters: [
                "text": .init(type: "string", description: "原文本", enumValues: nil),
                "find": .init(type: "string", description: "要查找的内容", enumValues: nil),
                "replace": .init(type: "string", description: "替换为的内容（默认空串）", enumValues: nil),
                "regex": .init(type: "boolean", description: "find 是否按正则匹配（默认 false）", enumValues: nil),
                "all": .init(type: "boolean", description: "是否替换全部（默认 true；false 仅替换首个）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "case_convert",
            name: "case_convert",
            description: "标识符命名风格转换：snake/camel/Pascal/kebab",
            parameters: [
                "text": .init(type: "string", description: "要转换的标识符", enumValues: nil),
                "style": .init(type: "string", description: "目标风格", enumValues: ["snake", "camel", "pascal", "kebab"])
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "password_generate",
            name: "password_generate",
            description: "生成高强度随机密码，可指定长度与字符类别",
            parameters: [
                "length": .init(type: "number", description: "长度（默认 16，范围 4~128）", enumValues: nil),
                "digits": .init(type: "boolean", description: "包含数字（默认 true）", enumValues: nil),
                "symbols": .init(type: "boolean", description: "包含符号（默认 true）", enumValues: nil),
                "uppercase": .init(type: "boolean", description: "包含大写字母（默认 true）", enumValues: nil),
                "lowercase": .init(type: "boolean", description: "包含小写字母（默认 true）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "roman",
            name: "roman",
            description: "罗马数字与阿拉伯数字互转（自动识别方向）",
            parameters: [
                "value": .init(type: "string", description: "阿拉伯数字(如 1994)或罗马数字(如 MCMXCIV)", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "unit_convert",
            name: "unit_convert",
            description: "单位换算：长度/重量/温度/体积/数据量。from 与 to 为同一类别的单位名",
            parameters: [
                "value": .init(type: "number", description: "数值", enumValues: nil),
                "from": .init(type: "string", description: "原单位（如 km/m/kg/g/°C/°F/K/L/ml/MB/GB）", enumValues: nil),
                "to": .init(type: "string", description: "目标单位", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "ssh",
            name: "ssh",
            description: "通过 SSH 在远程服务器上执行命令（默认使用「设置 → SSH 连接」中配置的主机/账号，也可在参数中临时覆盖）。支持密码(password)与私钥PEM(key)两种认证。参数：command(必填)要执行的命令；host/user/port 可选覆盖默认连接；auth_type 可选 password/key；password/private_key/passphrase 可选覆盖默认凭据",
            parameters: [
                "command": .init(type: "string", description: "要在远程执行的命令（必填），如 uname -a、df -h、systemctl status nginx", enumValues: nil),
                "host": .init(type: "string", description: "主机地址（可选，默认使用设置中的主机）", enumValues: nil),
                "user": .init(type: "string", description: "登录用户名（可选，默认使用设置中的用户名）", enumValues: nil),
                "port": .init(type: "number", description: "端口（可选，默认 22 或设置中的端口）", enumValues: nil),
                "auth_type": .init(type: "string", description: "认证方式", enumValues: ["password", "key"]),
                "password": .init(type: "string", description: "密码（auth_type=password 时使用；留空则用设置中的密码）", enumValues: nil),
                "private_key": .init(type: "string", description: "私钥 PEM 内容（auth_type=key 时使用；留空则用设置中的私钥）", enumValues: nil),
                "passphrase": .init(type: "string", description: "私钥口令（可选，留空则用设置中的口令）", enumValues: nil)
            ],
            requiresApproval: true,  // SSH 会真实执行远程命令，必须经用户授权
        ),
        AgentToolDefinition(
            id: "shell",
            name: "shell",
            description: "iOS 沙盒内受限 shell,执行文件 / 文本 / 系统类命令(ls、cat、echo、grep、sort、wc、head、tail、mkdir、rm、cp、mv、pwd、cd、stat、export 等),路径限定在 app 沙盒下 ~/Documents/shellbox。支持通配符、管道(|)、重定向(> >>)、链式执行(; && ||)。例如:'ls *.txt | head -5'、'grep -i keyword notes.md'、'echo hello > out.txt'。输入 'help' 查看完整命令列表",
            parameters: [
                "command": .init(type: "string", description: "要执行的 shell 命令字符串(必填)。可一次写多段,用 ; 或 | 或 && 串连", enumValues: nil)
            ],
            requiresApproval: true,  // 沙盒 shell 会写入/删除文件,需要用户授权
        ),
    ]

    // MARK: - 执行入口

    /// arguments 以 JSON 字符串传入（String 为 Sendable，可安全跨 actor 传递）。
    static func execute(toolName: String, argumentsJSON: String) async -> String {
        var arguments: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = obj
        }
        switch toolName {
        case "calculator":      return executeCalculator(arguments: arguments)
        case "current_time":    return executeCurrentTime()
        case "generate_uuid":   return UUID().uuidString
        case "random_number":   return executeRandomNumber(arguments: arguments)
        case "word_count":      return executeWordCount(arguments: arguments)
        case "text_transform":  return executeTextTransform(arguments: arguments)
        case "date_add":        return executeDateAdd(arguments: arguments)
        case "date_diff":       return executeDateDiff(arguments: arguments)
        case "hash_text":       return executeHashText(arguments: arguments)
        case "json_format":     return executeJsonFormat(arguments: arguments)
        case "url_codec":       return executeUrlCodec(arguments: arguments)
        case "note":            return await executeNote(arguments: arguments)
        case "clipboard":       return executeClipboard(arguments: arguments)
        case "web_search":      return await executeWebSearch(arguments: arguments)
        case "regex_extract":   return executeRegexExtract(arguments: arguments)
        case "text_summary":    return executeTextSummary(arguments: arguments)
        case "number_base":     return executeNumberBase(arguments: arguments)
        case "color_convert":   return executeColorConvert(arguments: arguments)
        case "sort_text":       return executeSortText(arguments: arguments)
        case "find_replace":    return executeFindReplace(arguments: arguments)
        case "case_convert":    return executeCaseConvert(arguments: arguments)
        case "password_generate": return executePasswordGenerate(arguments: arguments)
        case "roman":           return executeRoman(arguments: arguments)
        case "unit_convert":    return executeUnitConvert(arguments: arguments)
        case "ssh":             return executeSSH(arguments: arguments)
        case "shell":           return executeShell(arguments: arguments)
        case "http_get":        return await executeHTTPGet(arguments: arguments)
        case "device_info":     return executeDeviceInfo()
        case "json_query":      return executeJSONQuery(arguments: arguments)
        case "timestamp":       return executeTimestamp(arguments: arguments)
        case "extract_urls":    return executeExtractURLs(arguments: arguments)
        case "csv_table":       return executeCSVTable(arguments: arguments)
        case "jwt_decode":      return executeJWTDecode(arguments: arguments)
        default:
            return "未知工具: \(toolName)"
        }
    }

    /// 全渠道执行：内置工具 → MCP（已连接服务器的工具）→ JS 插件 → 未知。
    /// Agent 循环统一走这里，修复 MCP 工具无法执行的问题并支持插件工具。
    /// @MainActor：访问 MCPService.shared / PluginManager.shared（MainActor 隔离单例）。
    @MainActor
    static func executeWithFallbacks(toolName: String, argumentsJSON: String) async -> String {
        let builtin = await execute(toolName: toolName, argumentsJSON: argumentsJSON)
        if !builtin.hasPrefix("未知工具:") { return builtin }

        // MCP 工具（由已连接服务器暴露）
        if MCPService.shared.server(forToolName: toolName) != nil {
            return await MCPService.shared.callTool(name: toolName, argumentsJSON: argumentsJSON)
        }

        // JS 插件工具
        if PluginManager.shared.hasTool(named: toolName) {
            return await PluginManager.shared.callTool(name: toolName, argumentsJSON: argumentsJSON)
        }

        return builtin
    }

    // MARK: - 工具实现

    private static func executeCalculator(arguments: [String: Any]) -> String {
        guard let expression = arguments["expression"] as? String else {
            return "错误: 缺少 expression 参数"
        }
        guard let value = evaluateMath(expression) else {
            return "错误: 无法解析表达式「\(expression)」，请检查运算符与括号是否完整"
        }
        // 整数结果不显示小数
        let text: String
        if value == value.rounded() && Swift.abs(value) < 1e15 {
            text = String(Int64(value))
        } else {
            text = String(format: "%.10g", value)
        }
        return "\(expression) = \(text)"
    }

    private static func executeCurrentTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        return "当前时间: \(formatter.string(from: Date()))"
    }

    private static func executeRandomNumber(arguments: [String: Any]) -> String {
        let minV = (arguments["min"] as? NSNumber)?.intValue ?? 1
        let maxV = (arguments["max"] as? NSNumber)?.intValue ?? 100
        guard minV <= maxV else { return "错误: min 应不大于 max" }
        return "随机数: \(Int.random(in: minV...maxV))（范围 \(minV)~\(maxV)）"
    }

    private static func executeWordCount(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else {
            return "错误: 缺少 text 参数"
        }
        let charCount = text.count
        let wordCount = text.split(separator: /\s+/).count
        let lineCount = text.components(separatedBy: .newlines).count
        return "字符数: \(charCount), 单词数: \(wordCount), 行数: \(lineCount)"
    }

    private static func executeTextTransform(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String,
              let transform = arguments["transform"] as? String else {
            return "错误: 缺少参数"
        }
        switch transform {
        case "uppercase":
            return text.uppercased()
        case "lowercase":
            return text.lowercased()
        case "reverse":
            return String(text.reversed())
        case "base64_encode":
            return Data(text.utf8).base64EncodedString()
        case "base64_decode":
            guard let data = Data(base64Encoded: text) else { return "Base64解码失败" }
            return String(data: data, encoding: .utf8) ?? "解码结果非有效UTF-8文本"
        default:
            return "未知转换类型: \(transform)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        return f
    }()

    private static func executeDateAdd(arguments: [String: Any]) -> String {
        let dateStr = arguments["date"] as? String ?? ""
        let days = (arguments["days"] as? NSNumber)?.intValue ?? 0
        let base = dateStr.isEmpty ? Date() : (dateFormatter.date(from: dateStr) ?? Date())
        guard let result = Calendar.current.date(byAdding: .day, value: days, to: base) else {
            return "日期计算失败"
        }
        return "\(dateFormatter.string(from: base)) + \(days) 天 = \(dateFormatter.string(from: result))"
    }

    private static func executeDateDiff(arguments: [String: Any]) -> String {
        guard let d1 = arguments["date1"] as? String,
              let d2 = arguments["date2"] as? String,
              let a = dateFormatter.date(from: d1),
              let b = dateFormatter.date(from: d2) else {
            return "错误: 需要有效的 date1 和 date2（格式 yyyy-MM-dd）"
        }
        let days = Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
        return "\(d1) 到 \(d2) 相差 \(Swift.abs(days)) 天"
    }

    private static func executeHashText(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else { return "错误: 缺少 text 参数" }
        let algorithm = (arguments["algorithm"] as? String)?.lowercased() ?? "sha256"
        let data = Data(text.utf8)
        let hex: String
        switch algorithm {
        case "md5":
            hex = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha1":
            hex = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha256":
            hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            return "未知算法: \(algorithm)（可选 md5/sha1/sha256）"
        }
        return "\(algorithm) = \(hex)"
    }

    private static func executeJsonFormat(arguments: [String: Any]) -> String {
        guard let json = arguments["json"] as? String else { return "错误: 缺少 json 参数" }
        let pretty = (arguments["pretty"] as? Bool) ?? true
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return "错误: JSON 解析失败"
        }
        let options: JSONSerialization.WritingOptions =
            pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: options),
              let text = String(data: out, encoding: .utf8) else {
            return "错误: JSON 序列化失败"
        }
        return text
    }

    private static func executeUrlCodec(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else { return "错误: 缺少 text 参数" }
        let mode = arguments["mode"] as? String ?? "encode"
        if mode == "decode" {
            return text.removingPercentEncoding ?? "解码失败"
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static let notesDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("agent_notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 笔记的读写**全部**交给 `NoteStore` —— 它同时也是「设置 → 长期记忆」界面的数据源。
    /// 两边各写一份 file I/O 的话，模型写完笔记后界面列表不会刷新，用户看到的还是旧列表。
    /// 目录定义也随之收敛成一处（`NoteStore.directory`），不再有两个「同一个目录」的字面量。
    ///
    /// 注意：返回的字符串必须与训练数据逐字一致 —— lumen3 / lumen4 就是照这些字符串
    /// 练出来的记忆行为（真源在 `build_lumen_train.py`），改文案会让模型在真实 App 里对不上。
    private static func executeNote(arguments: [String: Any]) async -> String {
        let op = arguments["op"] as? String ?? "list"
        let rawName = (arguments["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = arguments["content"] as? String ?? ""
        // 工具跑在非隔离的 static async 上下文里，而 NoteStore 是 @MainActor（要给 SwiftUI 用），
        // 所以显式跳一次主线程。笔记都是小文本文件，这点 I/O 放主线程没有影响。
        return await MainActor.run {
            NoteStore.shared.perform(op: op, name: rawName, content: content)
        }
    }

    private static func executeClipboard(arguments: [String: Any]) -> String {
        let op = arguments["op"] as? String ?? "get"
        #if canImport(UIKit)
        if op == "set" {
            guard let text = arguments["text"] as? String else { return "错误: 缺少 text 参数" }
            UIPasteboard.general.string = text
            return "已写入剪贴板（\(text.count) 字）"
        }
        let current = UIPasteboard.general.string
        if let current, !current.isEmpty {
            return "剪贴板内容: \(current.prefix(2000))"
        }
        return "剪贴板为空"
        #else
        return "剪贴板在当前平台不可用"
        #endif
    }

    private static func executeWebSearch(arguments: [String: Any]) async -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "错误: 缺少 query 参数"
        }
        // 优先 SearXNG（自托管搜索服务，可在设置中配置），失败自动回退维基百科
        return await SearchService.search(query: query, settings: SettingsStorage.shared.settings)
    }

    // MARK: - 安全数学表达式求值（Shunting-yard + RPN，纯 Swift 无崩溃风险）

    private enum MathToken: Equatable {
        case number(Double)
        case op(String)        // + - * / % ^、一元 u+/u-、函数名
        case constant(String)  // pi / e
        case lparen
        case rparen
        case comma
    }

    private static let binaryOps = ["+", "-", "*", "/", "%", "^", "min", "max", "pow"]
    private static let unaryOps = ["u+", "u-", "sqrt", "abs", "round", "floor", "ceil",
                                   "sin", "cos", "tan", "asin", "acos", "atan",
                                   "log", "ln", "log10", "exp"]

    private static func tokenizeMath(_ input: String) -> [MathToken]? {
        var tokens: [MathToken] = []
        let chars = Array(input)
        var idx = 0
        let count = chars.count
        var expectOperand = true

        while idx < count {
            let c = chars[idx]
            if c.isWhitespace { idx += 1; continue }
            if c.isNumber || c == "." {
                var num = ""
                while idx < count, chars[idx].isNumber || chars[idx] == "." {
                    num.append(chars[idx])
                    idx += 1
                }
                // 科学计数法 1e3 / 2.5e-2
                if idx + 1 < count, chars[idx] == "e" || chars[idx] == "E" {
                    let next = chars[idx + 1]
                    if next.isNumber || next == "+" || next == "-" {
                        num.append("e")
                        idx += 1
                        if chars[idx] == "+" || chars[idx] == "-" {
                            num.append(chars[idx])
                            idx += 1
                        }
                        while idx < count, chars[idx].isNumber {
                            num.append(chars[idx])
                            idx += 1
                        }
                    }
                }
                guard let v = Double(num) else { return nil }
                tokens.append(.number(v))
                expectOperand = false
                continue
            }
            if c.isLetter {
                var ident = ""
                while idx < count, chars[idx].isLetter {
                    ident.append(chars[idx])
                    idx += 1
                }
                let lower = ident.lowercased()
                if lower == "pi" || lower == "π" {
                    tokens.append(.constant("pi"))
                    expectOperand = false
                } else if lower == "e" {
                    tokens.append(.constant("e"))
                    expectOperand = false
                } else if isFunction(lower) {
                    tokens.append(.op(lower))
                    expectOperand = true
                } else {
                    return nil
                }
                continue
            }
            switch c {
            case "+", "-", "*", "/", "%", "^":
                if (c == "+" || c == "-") && expectOperand {
                    tokens.append(.op(c == "-" ? "u-" : "u+"))
                } else {
                    tokens.append(.op(String(c)))
                }
                expectOperand = true
                idx += 1
            case "(", "（":
                tokens.append(.lparen)
                expectOperand = true
                idx += 1
            case ")", "）":
                tokens.append(.rparen)
                expectOperand = false
                idx += 1
            case ",", "，":
                tokens.append(.comma)
                expectOperand = true
                idx += 1
            default:
                return nil
            }
        }
        return tokens
    }

    private static func isFunction(_ name: String) -> Bool {
        unaryOps.contains(name) || binaryOps.contains(name)
    }

    private static func precedence(_ op: String) -> Int {
        switch op {
        case "+", "-": return 1
        case "*", "/", "%": return 2
        case "^": return 3
        default: return 4 // 一元运算符与函数
        }
    }

    private static func evaluateMath(_ input: String) -> Double? {
        let cleaned = input
            .lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "π", with: "pi")
        guard let tokens = tokenizeMath(cleaned), !tokens.isEmpty else { return nil }

        // Shunting-yard → RPN
        var output: [MathToken] = []
        var stack: [MathToken] = []

        for token in tokens {
            switch token {
            case .number, .constant:
                output.append(token)
            case .op(let name):
                let prec = precedence(name)
                while let top = stack.last, case .op(let topName) = top {
                    let topPrec = precedence(topName)
                    let rightAssoc = name == "^"
                    if topPrec > prec || (topPrec == prec && !rightAssoc && topName != "^") {
                        output.append(stack.removeLast())
                    } else {
                        break
                    }
                }
                stack.append(token)
            case .lparen:
                stack.append(token)
            case .comma:
                while let top = stack.last, top != .lparen {
                    output.append(stack.removeLast())
                }
            case .rparen:
                var found = false
                while let top = stack.last {
                    if top == .lparen {
                        stack.removeLast()
                        found = true
                        break
                    }
                    output.append(stack.removeLast())
                }
                if !found { return nil } // 括号不匹配
                if case .op(let fn)? = stack.last, isFunction(fn) {
                    output.append(stack.removeLast())
                }
            }
        }
        while let top = stack.popLast() {
            if top == .lparen { return nil } // 括号不匹配
            output.append(top)
        }

        // RPN 求值
        var values: [Double] = []
        for token in output {
            switch token {
            case .number(let v):
                values.append(v)
            case .constant(let name):
                values.append(name == "pi" ? .pi : M_E)
            case .op(let name):
                let n = binaryOps.contains(name) ? 2 : 1
                guard values.count >= n else { return nil }
                let args = Array(values.suffix(n))
                values.removeLast(n)
                let a = args[0]
                let b = n == 2 ? args[1] : 0
                let result: Double?
                switch name {
                case "+": result = a + b
                case "-": result = a - b
                case "u+": result = a
                case "u-": result = -a
                case "*": result = a * b
                case "/": result = b == 0 ? nil : a / b
                case "%": result = b == 0 ? nil : a.truncatingRemainder(dividingBy: b)
                case "^": result = pow(a, b)
                case "sqrt": result = a >= 0 ? sqrt(a) : nil
                case "abs": result = Swift.abs(a)
                case "round": result = a.rounded()
                case "floor": result = floor(a)
                case "ceil": result = ceil(a)
                case "sin": result = sin(a)
                case "cos": result = cos(a)
                case "tan": result = cos(a) == 0 ? nil : tan(a)
                case "asin": result = (-1...1).contains(a) ? asin(a) : nil
                case "acos": result = (-1...1).contains(a) ? acos(a) : nil
                case "atan": result = atan(a)
                case "log", "log10": result = a > 0 ? log10(a) : nil
                case "ln": result = a > 0 ? log(a) : nil
                case "exp": result = exp(a)
                case "min": result = min(a, b)
                case "max": result = max(a, b)
                case "pow": result = pow(a, b)
                default: result = nil
                }
                guard let result else { return nil }
                values.append(result)
            case .lparen, .rparen, .comma:
                return nil
            }
        }
        return values.count == 1 ? values[0] : nil
    }

    // MARK: - 正则表达式提取工具

    private static func executeRegexExtract(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else {
            return "错误: 缺少 text 参数"
        }
        guard let pattern = arguments["pattern"] as? String else {
            return "错误: 缺少 pattern 参数"
        }
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return "错误: 无效的正则表达式模式「\(pattern)」"
        }
        
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        
        if matches.isEmpty {
            return "未找到匹配「\(pattern)」的内容"
        }
        
        var results: [String] = []
        for (i, match) in matches.prefix(20).enumerated() {
            // 完整匹配
            let fullMatch = nsText.substring(with: match.range)
            
            // 捕获组（如果有）
            var groups: [String] = []
            if match.numberOfRanges > 1 {
                for j in 1..<match.numberOfRanges {
                    let groupRange = match.range(at: j)
                    if groupRange.location != NSNotFound {
                        groups.append(nsText.substring(with: groupRange))
                    }
                }
            }
            
            var line = "\(i + 1). \(fullMatch)"
            if !groups.isEmpty {
                line += " [捕获组: \(groups.joined(separator: ", "))]"
            }
            results.append(line)
        }
        
        return "找到 \(matches.count) 个匹配:\n\(results.joined(separator: "\n"))"
    }

    // MARK: - 文本摘要工具

    private static func executeTextSummary(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else {
            return "错误: 缺少 text 参数"
        }
        
        let maxLength = (arguments["max_length"] as? NSNumber)?.intValue ?? 200
        
        if text.count <= maxLength {
            return "原文较短，无需摘要:\n\(text)"
        }
        
        // 智能摘要：提取关键句子
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if sentences.isEmpty {
            return "无法提取有效内容"
        }
        
        // 简单的关键词提取和句子重要性评分
        var scoredSentences: [(sentence: String, score: Double)] = []
        
        // 常见关键词（中文）
        let keywords = ["重要", "关键", "核心", "主要", "首先", "其次", "最后", "总结", "结论", 
                       "important", "key", "main", "first", "conclusion", "summary"]
        
        for sentence in sentences {
            var score = 0.0
            
            // 位置得分：开头和结尾的句子更重要
            if let index = sentences.firstIndex(of: sentence) {
                if index < 3 { score += 2.0 }
                if index >= sentences.count - 2 { score += 1.5 }
            }
            
            // 长度得分：中等长度的句子更可能是关键句
            let length = sentence.count
            if length > 10 && length < 100 {
                score += 1.0
            }
            
            // 关键词得分
            let lowerSentence = sentence.lowercased()
            for keyword in keywords {
                if lowerSentence.contains(keyword) {
                    score += 1.5
                }
            }
            
            scoredSentences.append((sentence, score))
        }
        
        // 按得分排序，取前几句
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map(\.sentence)
        
        var summary = topSentences.joined(separator: "。")
        
        // 截断到指定长度
        if summary.count > maxLength {
            summary = String(summary.prefix(maxLength - 3)) + "..."
        }
        
        return "摘要:\n\(summary)"
    }

    // MARK: - 进制转换

    private static func radixFor(name: String) -> Int? {
        switch name {
        case "decimal": return 10
        case "binary": return 2
        case "octal": return 8
        case "hex", "hexadecimal": return 16
        default: return nil
        }
    }

    private static func executeNumberBase(arguments: [String: Any]) -> String {
        guard let value = (arguments["value"] as? String)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return "错误: 缺少 value 参数" }
        let from = (arguments["from"] as? String)?.lowercased() ?? "decimal"
        let to = (arguments["to"] as? String)?.lowercased() ?? "hex"
        guard let fr = radixFor(name: from), let tr = radixFor(name: to) else {
            return "错误: from/to 必须是 decimal/binary/octal/hex 之一"
        }
        guard let num = Int(value, radix: fr) else {
            return "错误: 无法将「\(value)」按 \(from) 进制解析"
        }
        let out: String = (tr == 10) ? String(num) : String(num, radix: tr)
        return "\(value) (\(from)) = \(out) (\(to))"
    }

    // MARK: - 颜色转换

    private static func executeColorConvert(arguments: [String: Any]) -> String {
        guard let mode = arguments["mode"] as? String else { return "错误: 缺少 mode 参数(to_hex/to_rgb)" }
        guard let value = (arguments["value"] as? String)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return "错误: 缺少 value 参数" }
        if mode == "to_hex" {
            let parts = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3,
                  let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]),
                  (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else {
                return "错误: to_hex 需要 RGB 形如 255,0,0（各分量 0~255）"
            }
            return String(format: "#%02X%02X%02X", r, g, b)
        } else if mode == "to_rgb" {
            var h = value
            if h.hasPrefix("#") { h.removeFirst() }
            guard h.count == 6, let intVal = Int(h, radix: 16) else {
                return "错误: to_rgb 需要十六进制形如 #ff0000"
            }
            let r = (intVal >> 16) & 0xFF
            let g = (intVal >> 8) & 0xFF
            let b = intVal & 0xFF
            return "\(r), \(g), \(b)"
        }
        return "错误: mode 必须是 to_hex 或 to_rgb"
    }

    // MARK: - 文本排序

    private static func executeSortText(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else { return "错误: 缺少 text 参数" }
        let reverse = (arguments["reverse"] as? Bool) ?? false
        let ignoreCase = (arguments["ignore_case"] as? Bool) ?? false
        let dedup = (arguments["dedup"] as? Bool) ?? false
        var lines = text.components(separatedBy: .newlines)
        lines.sort {
            ignoreCase ? ($0.localizedCaseInsensitiveCompare($1) == .orderedAscending) : ($0 < $1)
        }
        if reverse { lines.reverse() }
        if dedup {
            var out: [String] = []
            for l in lines where out.last != l { out.append(l) }
            lines = out
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 查找替换

    private static func executeFindReplace(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else { return "错误: 缺少 text 参数" }
        guard let find = arguments["find"] as? String else { return "错误: 缺少 find 参数" }
        let replace = arguments["replace"] as? String ?? ""
        let regex = (arguments["regex"] as? Bool) ?? false
        let all = (arguments["all"] as? Bool) ?? true
        if regex {
            guard let re = try? NSRegularExpression(pattern: find) else {
                return "错误: 无效的正则「\(find)」"
            }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            if all {
                return re.stringByReplacingMatches(in: text, range: range, withTemplate: replace)
            } else if let match = re.firstMatch(in: text, range: range) {
                let result = re.replacementString(for: match, in: text, offset: 0, template: replace)
                return nsText.replacingCharacters(in: match.range, with: result)
            }
            return text
        } else if all {
            return text.replacingOccurrences(of: find, with: replace)
        } else if let r = text.range(of: find) {
            return text.replacingCharacters(in: r, with: replace)
        }
        return text
    }

    // MARK: - 命名风格转换

    private static func splitIdentifier(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(s)
        for i in 0..<chars.count {
            let c = chars[i]
            if c.isLetter || c.isNumber {
                if c.isUppercase, !current.isEmpty, let prev = current.last, !prev.isUppercase {
                    result.append(current)
                    current = ""
                }
                current.append(c)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.isEmpty }
    }

    private static func executeCaseConvert(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String, !text.isEmpty else { return "错误: 缺少 text 参数" }
        guard let style = arguments["style"] as? String else { return "错误: 缺少 style 参数" }
        let words = splitIdentifier(text)
        switch style {
        case "snake":  return words.map { $0.lowercased() }.joined(separator: "_")
        case "kebab":  return words.map { $0.lowercased() }.joined(separator: "-")
        case "camel":  return words.enumerated().map { i, w in i == 0 ? w.lowercased() : w.capitalized }.joined()
        case "pascal": return words.map { $0.capitalized }.joined()
        default: return "错误: style 必须是 snake/camel/pascal/kebab"
        }
    }

    // MARK: - 密码生成

    private static func executePasswordGenerate(arguments: [String: Any]) -> String {
        let length = min(max((arguments["length"] as? NSNumber)?.intValue ?? 16, 4), 128)
        let digits = (arguments["digits"] as? Bool) ?? true
        let symbols = (arguments["symbols"] as? Bool) ?? true
        let uppercase = (arguments["uppercase"] as? Bool) ?? true
        let lowercase = (arguments["lowercase"] as? Bool) ?? true
        let lowers = "abcdefghijklmnopqrstuvwxyz"
        let uppers = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let digs = "0123456789"
        let syms = "!@#$%^&*()-_=+[]{};:,.<>?"
        var pool = ""
        if lowercase { pool += lowers }
        if uppercase { pool += uppers }
        if digits { pool += digs }
        if symbols { pool += syms }
        guard !pool.isEmpty else { return "错误: 至少启用一种字符类别" }
        var chars = (0..<length).map { _ in pool.randomElement()! }
        if lowercase { chars[0] = lowers.randomElement()! }
        if uppercase, chars.count > 1 { chars[1] = uppers.randomElement()! }
        if digits, chars.count > 2 { chars[2] = digs.randomElement()! }
        if symbols, chars.count > 3 { chars[3] = syms.randomElement()! }
        return "生成密码（长度 \(length)）: \(String(chars))"
    }

    // MARK: - 罗马数字

    private static let romanMap: [(String, Int)] = [
        ("M", 1000), ("CM", 900), ("D", 500), ("CD", 400), ("C", 100),
        ("XC", 90), ("L", 50), ("XL", 40), ("X", 10), ("IX", 9),
        ("V", 5), ("IV", 4), ("I", 1)
    ]

    private static func intToRoman(_ n: Int) -> String {
        var n = n
        var s = ""
        for (sym, val) in romanMap {
            while n >= val { s += sym; n -= val }
        }
        return s
    }

    private static func romanToInt(_ s: String) -> Int? {
        var total = 0
        var i = 0
        let chars = Array(s)
        while i < chars.count {
            let two = (i + 1 < chars.count) ? String(chars[i]) + String(chars[i + 1]) : nil
            if let two, let val = romanMap.first(where: { $0.0 == two })?.1 {
                total += val
                i += 2
                continue
            }
            guard let val = romanMap.first(where: { $0.0 == String(chars[i]) })?.1 else { return nil }
            total += val
            i += 1
        }
        return total
    }

    private static func executeRoman(arguments: [String: Any]) -> String {
        guard let value = (arguments["value"] as? String)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return "错误: 缺少 value 参数" }
        if let num = Int(value) {
            guard (1...3999).contains(num) else { return "错误: 阿拉伯数字需在 1~3999" }
            return "\(num) = \(intToRoman(num))"
        }
        let upper = value.uppercased()
        guard let num = romanToInt(upper) else { return "错误: 无法解析罗马数字「\(value)」" }
        return "\(value) = \(num)"
    }

    // MARK: - 单位换算

    private static let lengthToMeter = ["m": 1.0, "km": 1000.0, "cm": 0.01, "mm": 0.001,
                                        "mile": 1609.344, "yard": 0.9144, "foot": 0.3048, "inch": 0.0254]
    private static let weightToKg = ["kg": 1.0, "g": 0.001, "mg": 0.000001, "t": 1000.0, "ton": 1000.0,
                                    "lb": 0.45359237, "pound": 0.45359237, "oz": 0.028349523125, "ounce": 0.028349523125]
    private static let volumeToLiter = ["l": 1.0, "liter": 1.0, "ml": 0.001, "m3": 1000.0,
                                       "gallon": 3.785411784, "cup": 0.2365882365]
    private static let dataToByte = ["b": 1.0, "byte": 1.0, "kb": 1024.0, "mb": 1048576.0,
                                    "gb": 1073741824.0, "tb": 1099511627776.0]

    private static func unitCategory(_ u: String) -> String? {
        if lengthToMeter[u] != nil { return "length" }
        if weightToKg[u] != nil { return "weight" }
        if volumeToLiter[u] != nil { return "volume" }
        if dataToByte[u] != nil { return "data" }
        if ["c", "°c", "f", "°f", "k"].contains(u) { return "temp" }
        return nil
    }

    private static func unitToBase(_ u: String, value: Double) -> Double? {
        if let f = lengthToMeter[u] { return value * f }
        if let f = weightToKg[u] { return value * f }
        if let f = volumeToLiter[u] { return value * f }
        if let f = dataToByte[u] { return value * f }
        if u == "c" || u == "°c" { return value }
        if u == "f" || u == "°f" { return (value - 32) / 1.8 }
        if u == "k" { return value - 273.15 }
        return nil
    }

    private static func baseToUnit(_ u: String, base: Double) -> Double? {
        if let f = lengthToMeter[u] { return base / f }
        if let f = weightToKg[u] { return base / f }
        if let f = volumeToLiter[u] { return base / f }
        if let f = dataToByte[u] { return base / f }
        if u == "c" || u == "°c" { return base }
        if u == "f" || u == "°f" { return base * 1.8 + 32 }
        if u == "k" { return base + 273.15 }
        return nil
    }

    private static func executeUnitConvert(arguments: [String: Any]) -> String {
        guard let valueNum = (arguments["value"] as? NSNumber)?.doubleValue else {
            return "错误: 缺少或无效 value 参数"
        }
        guard let from = (arguments["from"] as? String)?.lowercased(), !from.isEmpty else {
            return "错误: 缺少 from 参数"
        }
        guard let to = (arguments["to"] as? String)?.lowercased(), !to.isEmpty else {
            return "错误: 缺少 to 参数"
        }
        guard let catFrom = unitCategory(from), let catTo = unitCategory(to), catFrom == catTo else {
            return "错误: from 与 to 单位类别不一致或未知"
        }
        guard let base = unitToBase(from, value: valueNum) else { return "错误: 未知单位「\(from)」" }
        guard let out = baseToUnit(to, base: base) else { return "错误: 未知单位「\(to)」" }
        let text = (out == out.rounded()) ? String(Int64(out)) : String(format: "%.6g", out)
        return "\(valueNum) \(from) = \(text) \(to)"
    }

    // MARK: - SSH 远程命令执行（C 桥接 ssh_exec，底层 libssh2 + mbedTLS）

    private static func trimmed(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func executeSSH(arguments: [String: Any]) -> String {
        let command = trimmed(arguments["command"] as? String)
        guard !command.isEmpty else {
            return "错误: 缺少 command 参数（要在远程执行的命令）"
        }
        let s = SettingsStorage.shared.settings
        let host = trimmed(arguments["host"] as? String).isEmpty
            ? trimmed(s.sshHost) : trimmed(arguments["host"] as? String)
        guard !host.isEmpty else {
            return "错误: 未配置 SSH 主机（请在「设置 → SSH 连接」填写，或在工具参数中提供 host）"
        }
        let user = trimmed(arguments["user"] as? String).isEmpty
            ? trimmed(s.sshUser) : trimmed(arguments["user"] as? String)
        guard !user.isEmpty else {
            return "错误: 未配置 SSH 用户名（请在设置中填写，或提供 user 参数）"
        }
        let port = Int32((arguments["port"] as? NSNumber)?.intValue
                         ?? (s.sshPort > 0 ? s.sshPort : 22))

        let authArg = trimmed(arguments["auth_type"] as? String).lowercased()
        let useKey: Bool
        if !authArg.isEmpty {
            useKey = (authArg == "key" || authArg == "privatekey" || authArg == "pem")
        } else {
            useKey = (trimmed(s.sshAuthType).lowercased() == "key")
        }

        let password = trimmed(arguments["password"] as? String).isEmpty
            ? s.sshPassword : (arguments["password"] as? String) ?? ""
        let privateKey = trimmed(arguments["private_key"] as? String).isEmpty
            ? s.sshPrivateKey : (arguments["private_key"] as? String) ?? ""
        let passphrase = trimmed(arguments["passphrase"] as? String).isEmpty
            ? s.sshPassphrase : (arguments["passphrase"] as? String) ?? ""

        if useKey {
            guard !trimmed(privateKey).isEmpty else {
                return "错误: 使用私钥认证但未提供私钥（请在设置填写，或提供 private_key 参数）"
            }
        } else {
            guard !trimmed(password).isEmpty else {
                return "错误: 密码为空，请提供密码（设置中填写或传 password 参数）"
            }
        }

        // utf8CString 以 NUL 结尾；用 Array 包一层以便隐式转为 UnsafePointer<CChar>
        let hostC = Array(host.utf8CString)
        let userC = Array(user.utf8CString)
        let pwC = Array(password.utf8CString)
        let keyC = Array(privateKey.utf8CString)
        let passC = Array(passphrase.utf8CString)
        let cmdC = Array(command.utf8CString)

        var outBuf = [CChar](repeating: 0, count: 65536)
        let rc = ssh_exec(hostC, port, userC,
                         useKey ? 1 : 0,
                         pwC, keyC, passC, cmdC,
                         &outBuf, Int32(outBuf.count))
        let output = outBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        if rc < 0 {
            return "SSH 执行失败（错误码 \(rc)）: \(output)"
        }
        return "命令退出码: \(rc)\n--- 输出 ---\n\(output)"
    }

    /// 沙盒 shell 执行(走 ShellSandbox 的受限命令解释器)
    private static func executeShell(arguments: [String: Any]) -> String {
        guard let command = arguments["command"] as? String, !command.isEmpty else {
            return "错误: 缺少 command 参数"
        }
        // 输出截断保护:避免一次性 output 巨大撑爆上下文
        let raw = ShellSandbox.run(command)
        if raw.count > 4000 {
            return String(raw.prefix(4000)) + "\n…(输出过长，已截断)"
        }
        return raw
    }

    // MARK: - v0.3.18 新增工具

    /// HTTP GET 抓取网页/API(仅 https;JSON 自动美化)
    private static func executeHTTPGet(arguments: [String: Any]) async -> String {
        guard let urlString = arguments["url"] as? String, !urlString.isEmpty else {
            return "错误: 缺少 url 参数"
        }
        // 强制 https(ATS 默认允许;http 直接提示改用 https)
        guard let lower = URL(string: urlString), lower.scheme?.lowercased() == "https" else {
            return "错误: 仅支持 https URL(ATS 默认禁止明文 http)"
        }
        let timeout = (arguments["timeout"] as? NSNumber)?.doubleValue ?? 15
        var request = URLRequest(url: lower)
        request.timeoutInterval = timeout
        request.setValue("LumenAI-Agent/0.3 (iOS Sandbox)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "错误: 无效响应"
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return "HTTP \(http.statusCode): \(String(body.prefix(300)))"
            }
            // JSON 美化输出
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: pretty, encoding: .utf8) {
                return str.count > 6000 ? String(str.prefix(6000)) + "\n…(内容过长，已截断)" : str
            }
            let text = String(data: data, encoding: .utf8) ?? "(非 UTF-8 内容,返回 \(data.count) 字节)"
            return text.count > 6000 ? String(text.prefix(6000)) + "\n…(内容过长，已截断)" : text
        } catch {
            return "请求失败: \(error.localizedDescription)"
        }
    }

    /// 设备信息(iOS)
    private static func executeDeviceInfo() -> String {
        #if os(iOS)
        let device = UIDevice.current
        let system = ProcessInfo.processInfo
        let fm = FileManager.default
        let fileSystem: String
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = attrs[.systemSize] as? Int64,
           let free = attrs[.systemFreeSize] as? Int64 {
            let gb = 1024.0 * 1024.0 * 1024.0
            fileSystem = String(format: "总容量 %.1f GB,可用 %.1f GB", Double(total)/gb, Double(free)/gb)
        } else {
            fileSystem = "未知"
        }
        let battery: String
        if device.isBatteryMonitoringEnabled {
            let level = device.batteryLevel
            battery = level < 0 ? "未知" : "\(Int(level * 100))%"
        } else {
            battery = "未启用"
        }
        var lines = [
            "机型: \(device.model)",
            "系统: \(device.systemName) \(device.systemVersion)",
            "内存: \(system.physicalMemory / (1024*1024)) MB",
            "文件系统: \(fileSystem)",
            "电量: \(battery)",
        ]
        #if arch(arm64)
        lines.insert("架构: arm64", at: 2)
        #elseif arch(x86_64)
        lines.insert("架构: x86_64", at: 2)
        #endif
        #if targetEnvironment(simulator)
        lines.append("环境: 模拟器")
        #else
        lines.append("环境: 真机")
        #endif
        return lines.joined(separator: "\n")
        #else
        return "设备信息: 仅 iOS 可用"
        #endif
    }

    /// JSON 取值(a.b.c 点路径 + [n] 下标)
    private static func executeJSONQuery(arguments: [String: Any]) -> String {
        guard let json = arguments["json"] as? String,
              let path = arguments["path"] as? String else {
            return "错误: 缺少 json / path 参数"
        }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return "错误: JSON 解析失败"
        }
        // 解析路径:a.b[0].c
        let components = path.components(separatedBy: ".").filter { !$0.isEmpty }
        var current: Any = root
        for comp in components {
            // 处理 [n] 下标
            if let idx = comp.firstIndex(of: "["), comp.hasSuffix("]") {
                let key = String(comp[..<idx])
                let numStr = String(comp[comp.index(after: idx)..<comp.index(before: comp.endIndex)])
                if let dict = current as? [String: Any], !key.isEmpty {
                    guard let next = dict[key] else { return "错误: 路径 \(key) 不存在" }
                    current = next
                }
                if let arr = current as? [Any], let n = Int(numStr) {
                    guard n >= 0 && n < arr.count else { return "错误: 下标 \(n) 越界" }
                    current = arr[n]
                } else {
                    return "错误: \(comp) 不是数组下标"
                }
            } else {
                guard let dict = current as? [String: Any],
                      let next = dict[comp] else {
                    return "错误: 路径 \(comp) 不存在"
                }
                current = next
            }
        }
        // 输出:标量直接转字符串,对象/数组美化
        if let v = current as? String { return v }
        if let v = current as? NSNumber {
            return v.stringValue
        }
        if let v = current as? Bool { return v ? "true" : "false" }
        if let obj = current as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        if let arr = current as? [Any],
           let d = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "\(current)"
    }

    /// Unix 时间戳与日期互转(时区偏移默认 +8)
    private static func executeTimestamp(arguments: [String: Any]) -> String {
        guard let value = arguments["value"] as? String, !value.isEmpty else {
            return "错误: 缺少 value 参数"
        }
        let offsetHours = (arguments["timezone_offset"] as? NSNumber)?.intValue ?? 8
        var tz = TimeZone(identifier: "UTC")!
        if offsetHours != 0 {
            tz = TimeZone(secondsFromGMT: offsetHours * 3600) ?? TimeZone(identifier: "UTC")!
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = tz

        // 判断是数字(时间戳)还是日期
        if let ts = Double(value), ts >= 0, ts < 4.1e9 {
            let date = Date(timeIntervalSince1970: ts)
            return "\(Int64(ts)) → \(formatter.string(from: date))"
        } else {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
            for fmt in formats {
                let f = DateFormatter()
                f.dateFormat = fmt
                f.timeZone = tz
                if let date = f.date(from: trimmed) {
                    return "\(trimmed) → \(Int64(date.timeIntervalSince1970)) 秒 (UTC\(offsetHours >= 0 ? "+" : "")\(offsetHours))"
                }
            }
            return "错误: 无法解析日期(支持 yyyy-MM-dd [HH:mm[:ss]])"
        }
    }

    /// 从文本提取所有 URL
    private static func executeExtractURLs(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String, !text.isEmpty else {
            return "错误: 缺少 text 参数"
        }
        // 宽松 URL 检测:http(s):// 或 www.
        let pattern = #"(?:https?://[^\s<>\"]+|www\.[^\s<>\"]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return "错误: 正则初始化失败"
        }
        let ns = text as NSString
        var urls: [String] = []
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let s = ns.substring(with: m.range).trimmingCharacters(in: .punctuationCharacters)
            if !s.isEmpty && !urls.contains(s) { urls.append(s) }
        }
        return urls.isEmpty ? "(未找到 URL)" : urls.joined(separator: "\n")
    }

    /// CSV/TSV → 对齐表格
    private static func executeCSVTable(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String, !text.isEmpty else {
            return "错误: 缺少 text 参数"
        }
        var delimiter = ","
        if let d = arguments["delimiter"] as? String, !d.isEmpty {
            delimiter = d == "\\t" ? "\t" : d
        }
        let hasHeader = (arguments["header"] as? Bool) ?? true

        var rows: [[String]] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            rows.append(parseCSVLine(line, delimiter: delimiter))
        }
        guard !rows.isEmpty else { return "(空表格)" }

        // 计算每列最大宽度
        let colCount = rows.map { $0.count }.max() ?? 0
        var widths = [Int](repeating: 0, count: colCount)
        for row in rows {
            for (i, cell) in row.enumerated() where i < colCount {
                widths[i] = max(widths[i], cell.count)
            }
        }
        // 防止超宽列撑爆(限 40 字符)
        for i in widths.indices { widths[i] = min(widths[i], 40) }

        var out = ""
        func fmt(_ row: [String]) -> String {
            row.enumerated().map { i, cell in
                let c = cell.count > 40 ? String(cell.prefix(40)) + "…" : cell
                return c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: " | ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bodyStart = hasHeader ? 1 : 0
        if hasHeader, rows.count > 0 {
            out += fmt(rows[0]) + "\n"
            out += widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-") + "\n"
        }
        for row in rows.dropFirst(bodyStart) {
            out += fmt(row) + "\n"
        }
        return out.trimmingCharacters(in: .newlines)
    }

    /// 简单 CSV 行解析(支持 "..." 内逗号)
    private static func parseCSVLine(_ line: String, delimiter: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuote = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if inQuote {
                if ch == "\"" {
                    // "" 转义
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        i = line.index(after: next)
                        continue
                    } else {
                        inQuote = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuote = true
                } else if delimiter.count == 1, String(ch) == delimiter {
                    fields.append(current)
                    current = ""
                } else if delimiter.count == 1 {
                    current.append(ch)
                } else {
                    // 多字符分隔符(罕见,按前缀匹配)
                    if line[i...].hasPrefix(delimiter) {
                        fields.append(current)
                        current = ""
                        i = line.index(i, offsetBy: delimiter.count, limitedBy: line.endIndex) ?? line.endIndex
                        continue
                    }
                    current.append(ch)
                }
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    /// JWT 解码(不验签):header + payload 美化 + exp 解读
    private static func executeJWTDecode(arguments: [String: Any]) -> String {
        guard let token = arguments["token"] as? String, !token.isEmpty else {
            return "错误: 缺少 token 参数"
        }
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return "错误: JWT 需含 header.payload 两段" }

        func decodePart(_ s: String) -> String {
            // base64url → base64
            var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64) else { return "(无法解码)" }
            return String(data: data, encoding: .utf8) ?? "(非 UTF-8)"
        }

        func prettyJSON(_ s: String) -> String {
            guard let d = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let str = String(data: pretty, encoding: .utf8) else { return s }
            return str
        }

        var out = "=== Header ===\n" + prettyJSON(decodePart(parts[0])) + "\n\n=== Payload ===\n"
        let payloadRaw = decodePart(parts[1])
        let payloadPretty = prettyJSON(payloadRaw)
        out += payloadPretty

        // exp 解读
        if let d = payloadRaw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let exp = obj["exp"] as? Double {
            let date = Date(timeIntervalSince1970: exp)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = .current
            let expired = date < Date()
            out += "\n\n=== 过期时间 ===\n\(f.string(from: date))(\(expired ? "已过期" : "未过期"))"
        }
        if parts.count == 3 {
            out += "\n\n=== 签名 ===\n\(String(parts[2].prefix(40)))\(parts[2].count > 40 ? "…" : "")"
        }
        return out
    }
}

// MARK: - 默认启用清单（可开关，总数不变）

extension BuiltInTools {

    /// 工具目录的硬上限。与 `AgentService.withToolInstructions` 里的 `maxTools` 一致：
    /// 本地模型只喂 12 个，防止 4B 级模型的上下文被工具说明占满（解码失败/指令漂移）。
    static let catalogLimit = 12

    /// 默认启用的内置工具名（**有序**，顺序即模型工具目录里的出现顺序）。
    ///
    /// 为什么需要这份清单：`allTools` 有 33 个，而本地模型走 `prefix(12)` 取**声明顺序**
    /// 的前 12 个。实测 `note`（持久化笔记 = 跨对话记忆的唯一接口）排在第 19 位、
    /// `web_search` 第 21 位，**都被截掉了** —— 也就是说本地模型的工具目录里
    /// 根本不存在记忆工具。对一款以「长期记忆」为立身之本的本地 App，这等于核心功能不可用。
    ///
    /// 所以这里显式给出默认 12 个，把 `note` 提到最前（核心诉求）、`web_search` 也纳入，
    /// 代价是把两个较专用的 `csv_table` / `jwt_decode` 移出默认集 —— 它们仍可在
    /// 设置里手动开启，总数上限保持 12 不变。
    static let defaultEnabledNames: [String] = [
        "http_get",
        "note",
        "web_search",
        "device_info",
        "json_query",
        "calculator",
        "current_time",
        "timestamp",
        "extract_urls",
        "random_number",
        "word_count",
        "generate_uuid",
    ]

    /// 按名字取工具（保持传入顺序；未知名字直接忽略）。
    static func tools(named names: [String]) -> [AgentToolDefinition] {
        let by = allTools.reduce(into: [String: AgentToolDefinition]()) { acc, t in
            acc[t.name] = t
        }
        return names.compactMap { by[$0] }
    }

    /// 默认启用的工具定义（给 `AgentService.run` 的默认参数用）。
    static var defaultEnabledTools: [AgentToolDefinition] {
        tools(named: defaultEnabledNames)
    }
}
