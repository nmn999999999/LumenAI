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
    ///
    /// 当前判为 true 的只有 5 个：http_get、web_search（联网）、ssh、shell（执行命令）、
    /// clipboard（读写系统剪贴板）。判定标准是"会不会联网 / 写文件 / 执行命令 / 改系统状态"。
    /// 注意 note 虽然会写盘但仍是 false，理由写在该工具定义处（审批粒度到不了 op，会造成审批疲劳）。
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

// MARK: - 工具结果的成败约定

/// 工具返回值的成败约定：**失败一定以 `errorPrefix` 开头，成功一定不带这个前缀**。
///
/// 为什么要立这条约定：以前成功和失败走同一个字符串通道，且前缀五花八门
/// （`MCP 调用失败: …`、`插件错误: …`、`HTTP 404: …`），上层没法判断这一步到底成没成，
/// 只能全标成 `.complete` —— 于是"工具报错"在对话里显示成一次成功调用，
/// 模型也会把错误正文（比如 404 页面的 HTML）当成有效内容继续总结给用户。
/// 有了这个前缀，上层只要按 `isError` 判定，就能把失败如实标成 `.error`。
///
/// 注意：**不要**给成功结果加这个前缀，也不要给错误结果换别的措辞（如"失败: "），
/// 判定只认这一个前缀。
enum ToolResultFormat {
    /// 所有工具失败时返回的文本都必须以此开头，上层据此把 ToolCall 标成 .error
    static let errorPrefix = "错误: "
    static func isError(_ text: String) -> Bool { text.hasPrefix(errorPrefix) }
}

// MARK: - 工具执行结果

/// 一次工具执行的返回值：给模型看的文本 + 给用户/日志看的可观测性信息。
///
/// 为什么不直接用 String：`ChatMessage.ToolCall` 里那几个可观测性字段
/// （exitCode / durationMs / errorCode）必须有人填。耗时和成败可以从外围量出来，
/// 唯独**退出码只能由真正执行命令的那一层带出来** —— 外面拿不到，事后也推不出来。
/// 所以执行接口必须能表达"文本之外还有一件事要交代"，否则那几个字段就永远是 nil，
/// 界面上做了也白做。
struct ToolExecutionOutcome: Sendable {
    /// 与模型对话的正文（成败约定见 `ToolResultFormat`）。逐字未变。
    let text: String
    /// 进程退出码。**只有真的跑了外部命令的工具才有**（目前是 `shell`）。
    /// 纯计算 / 纯网络 / MCP / 插件工具一律 nil —— 它们没有"退出码"这个概念。
    var exitCode: Int?

    init(text: String, exitCode: Int? = nil) {
        self.text = text
        self.exitCode = exitCode
    }
}

enum BuiltInTools {

    static let allTools: [AgentToolDefinition] = [
        AgentToolDefinition(
            id: "http_get",
            name: "http_get",
            description: "发起 HTTP GET 请求抓取网页 / JSON API 内容(仅 https)。返回文本;若响应是 JSON 会自动美化。适合获取天气 API、GitHub API、新闻 RSS 等公开数据。只能访问公网地址,内网/回环/元数据地址会被拒绝",
            parameters: [
                "url": .init(type: "string", description: "完整 URL(https://...),如 https://api.github.com/repos/nmn999999999/LumenAI/releases/latest", enumValues: nil),
                "timeout": .init(type: "number", description: "超时秒数(可选,默认 15)", enumValues: nil)
            ],
            requiresApproval: true,  // 真实的网络出站：会把内网/外网内容拉回上下文，必须用户点头
        ),
        AgentToolDefinition(
            id: "device_info",
            name: "device_info",
            description: "获取当前 iOS 设备信息:机型、系统版本、内存/存储容量、当前电量、进程架构等",
            parameters: [:],
            // 只读本机信息：不联网、不写盘、不改系统状态，纯查询，不需要授权。
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
            description: "从一段文本中提取所有 URL 链接，返回去重列表。要抓取网页内容用 http_get。",
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
            description: "获取当前日期和时间（本地时区）。时间戳/日期换算用 timestamp。",
            parameters: [:],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "generate_uuid",
            name: "generate_uuid",
            description: "生成一个随机 UUID(v4)。需要唯一标识（文件名/会话/请求 id）时使用。",
            parameters: [:],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "random_number",
            name: "random_number",
            description: "生成指定范围内的随机整数（含端点）。需要不可预测的密钥/密码用 password_generate。",
            parameters: [
                "min": .init(type: "number", description: "最小值（含），默认 1", enumValues: nil),
                "max": .init(type: "number", description: "最大值（含），默认 100", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "word_count",
            name: "word_count",
            description: "统计文本的字数、字符数和行数（纯计数，不做理解）。",
            parameters: [
                "text": .init(type: "string", description: "要统计的文本", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "text_transform",
            name: "text_transform",
            description: "文本格式转换：大写、小写、反转、Base64 编码/解码。命名风格（snake/camel）转换用 case_convert。",
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
            description: "计算两个日期相差的天数（带方向：date2 早于 date1 时为负数）",
            parameters: [
                "date1": .init(type: "string", description: "起始日期 yyyy-MM-dd", enumValues: nil),
                "date2": .init(type: "string", description: "结束日期 yyyy-MM-dd", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "hash_text",
            name: "hash_text",
            description: "计算文本的 MD5 / SHA1 / SHA256 摘要（十六进制）。用于校验/指纹，不是加密。",
            parameters: [
                "text": .init(type: "string", description: "要哈希的文本", enumValues: nil),
                "algorithm": .init(type: "string", description: "算法", enumValues: ["md5", "sha1", "sha256"])
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "json_format",
            name: "json_format",
            description: "美化或压缩 JSON 字符串（只改格式，不改内容）。按路径取值用 json_query。",
            parameters: [
                "json": .init(type: "string", description: "要处理的 JSON 字符串", enumValues: nil),
                "pretty": .init(type: "boolean", description: "是否美化输出（默认 true）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "url_codec",
            name: "url_codec",
            description: "URL 编码(encode)或解码(decode)文本。",
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
            // 取舍：note 确实会持久化写盘（save）甚至删文件（delete），按"写文件就要授权"的
            // 字面规则应该设 true。这里仍然保持 false，理由是**审批疲劳**：
            // 授权粒度是"工具"而不是"op"，而 op 是参数 —— 一旦设 true，模型每次 list/read
            // （跨对话记忆的读路径，一次对话里可能十几次）也会弹同一个框。
            // 用户很快会习惯性点"允许本次会话"，授权形同虚设，真正危险的 delete 也一起被放行了，
            // 反而比不弹更糟；而且 App 的立身之本就是长期记忆，让记忆写入每次都打断用户是产品自杀。
            // 缓解措施：写入范围被限制在 App 私有目录 Documents/agent_notes，
            // 内容在「设置 → 长期记忆」里用户随时可见可删，且不涉及网络外发。
            // 如果将来审批能细到 (工具, op)，save/delete 应该改成 true。
            requiresApproval: false,
        ),
        // ── memory：模型主动读写的**全局长期记忆**（与 UI、自动提炼同一份存储）──
        //
        // 与 `note` 的分工（刻意并存，不是重复实现）：
        //   · `memory` = 跨对话的稳定事实/偏好，**每次对话都注入 system prompt**、自动生效；
        //                 因此必须短（≤80 字）、有条数上限、进 prompt 就有体积代价。
        //   · `note`   = 按需读取的笔记本，不进 prompt，可以很长。
        // 在描述里就把这条边界写死：否则模型会把任务细节、长文档往 memory 里塞，
        // 而那等于让它们每一轮都占着上下文。
        //
        // 审批沿用 `note` 的结论（false）：授权是工具级的，设 true 会让纯读的 list 也弹窗，
        // 造成审批疲劳；写入范围仅 App 私有目录，且「设置 → 长期记忆」可见可删。
        AgentToolDefinition(
            id: "memory",
            name: "memory",
            description: "长期记忆（跨对话，会自动注入每次对话的上下文）：list 列出、save 写入、delete 删除。只存用户稳定事实与偏好（≤80字/条）；任务细节或长文本请用 note",
            parameters: [
                "op": .init(type: "string", description: "操作（必填）", enumValues: ["list", "save", "delete"]),
                "content": .init(type: "string", description: "记忆内容（save 必填）：一句话稳定事实，≤80字", enumValues: nil),
                "id": .init(type: "string", description: "记忆短 id（delete 必填，由 list 返回）", enumValues: nil),
                "limit": .init(type: "number", description: "list 返回的最大条数（可选，默认 20）", enumValues: nil)
            ],
            requiresApproval: false,
        ),
        // ── phone：把"操作手机"这件事变成**有边界、有回执**的能力 ──
        //
        // 能力边界写进描述里是必须的，不是谦虚：合规版只能打开 URL / 触发已装快捷指令
        // （系统还会弹确认），根本没有系统级点击与输入。如果描述里不写死，
        // 模型会拿"tap 成功"这种不存在的返回值去向用户复述 —— 那是这个工具最危险的失败模式。
        //
        // requiresApproval 必须是 true：它会切换到别的 App、跑用户编的自动化。
        // 这是本仓库里少数几个"读也该批"的工具（`probe` 也会打开 URL 做实测）。
        AgentToolDefinition(
            id: "phone",
            name: "phone",
            description: "操作手机 / 操作其他 App（capability-aware，本机构建不能合成点击）：probe 查能力矩阵与实测、capability 查可用动作、list/run/save/delete 管理配方、open/app 打开 URL 或 App、wait 等待 UI 稳定、guide 把操作指引实时展示给用户。⚠️ 点击/输入/切屏本构建无法自动执行：需要交互时用 guide 给出「下一步点哪里 / 输入什么」的指引让用户操作，或把该动作做成快捷指令后用 run 执行。返回 JSON 回执 {status, executed, verified}，取值 success / executed_unverified / failed / timeout / unsupported。只有 status=success 才算成功；executed_unverified 只能说「已执行但未验证」；unsupported 说明本机做不到，不要反复重试同一动作。",
            parameters: [
                "op": .init(type: "string", description: "操作（必填）", enumValues: ["probe", "capability", "stats", "list", "run", "save", "delete", "open", "app", "wait", "screenshot", "guide"]),
                "name": .init(type: "string", description: "配方 / 快捷指令名 / URL / App 名（run/save/delete 用配方名；open 用 URL；app 用 App 名；run 时若无同名配方则直接按名字触发快捷指令）", enumValues: nil),
                "summary": .init(type: "string", description: "一句话说明这条配方干什么（save 可选）", enumValues: nil),
                "steps": .init(type: "string", description: "配方步骤，每行一条：run <快捷指令名> / open <url> / wait <秒> / # 注释（save 时可选，留空则只按 name 触发快捷指令）", enumValues: nil),
                "ms": .init(type: "number", description: "等待毫秒数，0..30000（op=wait 必填）", enumValues: nil),
                "text": .init(type: "string", description: "op=guide 必填：给用户看的下一步操作指引，例如「在设置页点『通用』→『关于本机』」", enumValues: nil)
            ],
            requiresApproval: true,
        ),
        // ⚠️ `todo` **刻意不进** `BuiltInTools.defaultEnabledNames`（见本文件末尾那份清单）。
        //
        // 默认清单只有 12 个位置，是给本地小模型的核心工具箱（顺序即目录顺序）。
        // `todo` 属于偏专用的进度工具，把它塞进默认集会挤掉一个更常用的工具
        // （如 json_query / timestamp）——小模型的上下文里，工具越多单条越容易被忽略。
        //
        // 所以 `todo` 属于"更多工具"：用户可以在「设置 → 工具」里手动勾选启用
        // （那时按 `ToolSettingsStore.setEnabled` 的规则会顶掉一个已启用的内置工具 ——
        // 这是用户的显式选择，不是我们替他做的决定）。
        // 云端模型走的是**全量工具**（`AgentService` 里 `useCloud` 时直接给 `tools`），
        // 不受这 12 个的配额限制，所以云端模型自动就能拿到 `todo`，无需任何额外开关。
        AgentToolDefinition(
            id: "todo",
            name: "todo",
            description: "维护当前任务的步骤清单（进度对用户可见）。任务超过一步时先用 set 写出计划，每完成一步就用 set 更新状态；只有一条 in_progress。op=list 查看、op=clear 清空。不要用它记录与任务无关的内容。",
            parameters: [
                // 「（必填）」三个字是**给云端 schema 用的开关**：CloudChatClient 靠
                // `description.contains("必填")` 决定哪个参数进 `required`（见该文件 230-233 行）。
                // 所以这里必须写在 `op` 上 —— 它是唯一每次调用都必需的参数；漏了它，模型可以
                // 不传 op（我们运行时会报错），却被迫每次都传 todos，接口契约就反了。
                "op": .init(type: "string", description: "操作（必填）", enumValues: ["set", "list", "clear"]),
                // 说明里必须写全"整表替换"和字段含义：模型看不到 TodoStore 的源码，
                // 只能靠这段描述知道 set 要的是**完整清单**而不是"要改的那几条"。
                // 注意**不要**在这里写"必填"（会被上面那条规则误判成所有 op 都必填）。
                "todos": .init(
                    type: "array",
                    description: "完整清单（只在 op=set 时使用，其它 op 忽略）：每项是一个对象，含 content（祈使句，如「检查 AgentService 的解析分支」）与 status（pending / in_progress / completed，省略按 pending）。set 是整表替换：每次都要给出你认为的完整清单，而不是只给变化的那几条",
                    enumValues: nil)
            ],
            // false。取舍理由与 note 相同但更强：
            // ① 它只改 App 自己的内存/私有 JSON，不联网、不写用户文件、不碰系统状态，
            //    不符合"联网/写文件/执行命令"的审批标准；
            // ② 它是**高频**工具 —— 一次多步任务里模型会调用五到十几次，每次都弹窗必然导致
            //    用户习惯性点"允许"，把审批训练成无脑确认，反而削弱真正危险工具（shell/ssh）的把关；
            // ③ 内容在界面上是用户可见、可随手清空的（TodoStore 就是面板的数据源）。
            requiresApproval: false,
        ),
        AgentToolDefinition(
            id: "clipboard",
            name: "clipboard",
            description: "读取(op=get)或覆盖写入(op=set)系统剪贴板。",
            parameters: [
                "op": .init(type: "string", description: "操作", enumValues: ["get", "set"]),
                "text": .init(type: "string", description: "要写入剪贴板的内容（set 必填）", enumValues: nil)
            ],
            // 改成 true。和 note 的取舍不同点在于"频率"和"数据敏感度"：
            // ① op:get 读的是**系统剪贴板**——里面可能是密码管理器复制出来的密码、验证码，
            //    一旦进了上下文就等于泄露给了模型（并留在对话记录里）；
            // ② op:set 会覆盖用户当前的剪贴板内容，是明确的系统状态修改；
            // ③ clipboard 不是高频工具（一次对话通常 0~1 次），弹窗不会造成审批疲劳，
            //    而 note 是每次都写的核心路径，两者不能按同一把尺子判。
            // 代价：op:get 这种只读操作也会弹窗。可接受——真要看剪贴板，用户本来就该确认一次。
            requiresApproval: true,
        ),
        AgentToolDefinition(
            id: "web_search",
            name: "web_search",
            description: "联网搜索网页（Bing 等），返回相关结果标题、链接与摘要",
            parameters: [
                "query": .init(type: "string", description: "搜索关键词", enumValues: nil)
            ],
            // 策略修正：这里原本是 false，但 web_search 是**真联网**工具
            // （executeWebSearch → SearchService → 向 Bing RSS / DuckDuckGo / 维基百科发起请求），
            // 和文件顶部声明的"网络类默认 true"直接矛盾。搜索词是模型根据上下文自己拼的，
            // 可能包含用户没说出口要外发的内容（笔记片段、剪贴板、设备信息），
            // 所以必须让用户在请求真正发出前看到并确认。网络类工具一律 true。
            requiresApproval: true,
        ),
        AgentToolDefinition(
            id: "regex_extract",
            name: "regex_extract",
            description: "用正则表达式从文本中提取匹配的内容。简单的查找替换用 find_replace。",
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
            description: "标识符命名风格互转：snake / camel / Pascal / kebab。",
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
            description: "在远程服务器上通过 SSH 执行命令（需先在「设置 → SSH 连接」配置主机/账号）。本地沙盒操作用 shell，不要用这个。支持密码(password)与私钥PEM(key)两种认证。参数：command(必填)要执行的命令；host/user/port 可选覆盖默认连接；auth_type 可选 password/key；password/private_key/passphrase 可选覆盖默认凭据",
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
            // 排他说明放在**首句**，不是排版讲究：本地模型（model 走 prefix(12) 的本地模型）
            // 的工具说明会被 AgentService 截断到 150 字（maxDesc = useCloud ? Int.max : 150），
            // 写在后面的内容模型根本看不到 —— shell 和 ssh 都叫"执行命令"、参数都叫 command、
            // 审批弹窗长得一模一样，模型最常犯的错就是把远程命令丢进本地沙盒。
            // 所以第一句就必须互相点名（"要操作远程服务器请用 ssh"/"本地沙盒操作用 shell"），
            // 保证截断后仍然保留。
            description: "本地沙盒内执行命令（文件/文本/系统类）。要操作远程服务器请用 ssh，不要用这个。执行文件/文本/系统类命令(ls、cat、echo、grep、sort、wc、head、tail、mkdir、rm、cp、mv、pwd、cd、stat、export 等)，路径限定在 app 沙盒下 ~/Documents/shellbox。支持通配符、管道(|)、重定向(> >>)、链式执行(; && ||)。例如:'ls *.txt | head -5'、'grep -i keyword notes.md'、'echo hello > out.txt'。输入 'help' 查看完整命令列表",
            parameters: [
                "command": .init(type: "string", description: "要执行的 shell 命令字符串(必填)。可一次写多段,用 ; 或 | 或 && 串连", enumValues: nil)
            ],
            requiresApproval: true,  // 沙盒 shell 会写入/删除文件,需要用户授权
        ),
        // 用户文件工作区（Documents/Files）。
        //
        // 为什么要有它：用户明确要「让 AI 自己完成文件管理编辑」。此前模型只能
        // 靠 `note`（单文件键值笔记）和 `shell`（受限命令解释器）绕，两者都不是
        // "文件"语义：note 只能存单块文本、shell 的工作区是另一个目录（shellbox）。
        // 结果是用户问"我那个文件呢"，模型既列不出来也改不了。
        //
        // 与 `shell` 的边界写进**首句**（本地模型工具描述会被截到 150 字，见 shell 的定义处）：
        // 结构化文件读写走这里，跑命令/管道走 shell。两者工作区不同，混用会让模型
        // 在一个目录里写完再去另一个目录找。
        AgentToolDefinition(
            id: "file_op",
            name: "file_op",
            description: "读写用户文件（文件工作区）。读改文件用这个；要跑命令或管道请用 shell。op=list 列出目录、read 读取文本（支持 offset/limit 行号）、write 新建或覆盖、append 追加、mkdir 建目录、move 移动或重命名、delete 删除、stat 查看信息。改一个已有文件的标准做法：先 read 看清原文，再用 write 写回完整内容。path 相对于工作区根目录，如 notes/todo.md",
            parameters: [
                "op": .init(type: "string", description: "操作（必填）", enumValues: ["list", "read", "write", "append", "mkdir", "move", "delete", "stat"]),
                "path": .init(type: "string", description: "文件或目录路径（必填），相对于工作区根目录，如 notes/todo.md；list 可传 \".\" 表示根目录", enumValues: nil),
                "content": .init(type: "string", description: "要写入的完整文本（write / append 必填）", enumValues: nil),
                "to": .init(type: "string", description: "move 的目标路径（move 必填）", enumValues: nil),
                "offset": .init(type: "number", description: "read 的起始行号，从 1 开始（可选，默认 1）", enumValues: nil),
                "limit": .init(type: "number", description: "read 最多返回多少行（可选，默认 200）", enumValues: nil)
            ],
            // false。取舍理由与 note 基本相同，但更硬：作用范围被 `resolve()` 死锁在
            // Documents/Files 之内（越界路径直接抛错，符号链接与 `..` 一并拦下），
            // 碰不到模型权重、聊天存档、笔记这些 App 自己的资产；而这个工具是
            // "让 AI 自己完成文件管理"的唯一入口，属于高频路径 —— 每个 op 都弹窗
            // 会把审批训练成无脑确认（见 note 与 shell 的取舍对比）。
            // delete 是唯一有破坏性的 op：代价是它也不弹窗，但删掉的东西在
            // 「文件」界面里对用户完全可见，且不进废纸篓以外的任何系统位置。
            // 如果将来审批能细到 (工具, op)，delete/move 应该单独设为 true。
            requiresApproval: false,
        ),
        // AI 给自己装能力：模型在对话里生成一个 JS 插件（manifest + tools.js），
        // 用户在安装卡片上确认后落盘，**当轮即可调用**新工具（AgentService 在安装成功后
        // 重建工具目录）。执行入口 PluginCreator（校验/预检/安装都在那里）。
        //
        // requiresApproval 必须是 true：这个工具的副作用 = 把模型生成的代码持久安装进
        // Modules/，没有用户逐次确认就是"模型任意落盘代码"。卡片是自定义的
        // （PluginInstallApprovalSheet，展示权限与完整源码），不走通用 alert。
        //
        // ⚠️ 与 todo 一样**不进** defaultEnabledNames（本文件末尾的默认 12 工具清单）：
        // 本地小模型既没见过这个工具名，也写不好插件代码。它只出现在云端全量目录里。
        AgentToolDefinition(
            id: "create_plugin",
            name: "create_plugin",
            description: "生成并安装一个新的 JS 工具插件，为本 App 扩展可复用能力（用户会看到安装确认卡片，需其批准）。仅当用户明确要求一个「可反复使用的新功能/新工具」时使用；一次性文本处理、普通问答不要用。安装成功后工具在本次任务中立即可用。",
            parameters: [
                "id": .init(type: "string", description: "模块唯一 id（必填）：小写字母开头，只含字母数字 . _ -，不能以点开头，≤64 字符，建议带业务前缀，如 text-tools、json-path-x", enumValues: nil),
                "name": .init(type: "string", description: "给用户看的模块名称（必填），≤40 字，如「文本工具集」", enumValues: nil),
                "description": .init(type: "string", description: "模块做什么的一句话描述（≤300 字）", enumValues: nil),
                "version": .init(type: "string", description: "版本号（可选，默认 1.0.0）；用相同 id 修正插件时递增", enumValues: nil),
                "permissions": .init(type: "array", description: "权限字符串数组（可选，纯计算插件传空数组或省略）：仅支持 \"network\"（联网，nativeFetch 仅支持 https）与 \"storage\"（模块私有键值存储）；其他值会被拒绝", enumValues: nil),
                "tools_js": .init(type: "string", description: "完整 JavaScript 源码（必填，≤20000 字符）。须调用 registerTool({name, description, parameters, run}) 注册一个或多个工具：name 为小写下划线风格且不与已有工具重名；parameters 是 {参数名:{type,description}}；run(args) 返回字符串（对象请 JSON.stringify），也可返回 Promise。需要 HTTP 时用 nativeFetch(url)（需声明 network 权限）；持久化用 storeGet/storeSet（需 storage）", enumValues: nil)
            ],
            requiresApproval: true,
        ),
    ]

    // MARK: - 执行入口

    /// 「不认识这个工具名」的返回值既是给模型看的错误，也是 `executeWithFallbacks` 用来
    /// 判断"要不要接着往 MCP / 插件找"的哨兵。以前这个哨兵是 `"未知工具: X"`，
    /// 不以「错误: 」开头 —— 于是内置工具名打错时，上层会把这句失败当成成功的工具输出。
    /// 现在它带错误前缀，同时用常量保证"产生哨兵"和"识别哨兵"两处不会各写一份字面量而漂移。
    private static let unknownToolMarker = "错误: 未知工具: "

    /// arguments 以 JSON 字符串传入（String 为 Sendable，可安全跨 actor 传递）。
    static func execute(toolName: String, argumentsJSON: String) async -> ToolExecutionOutcome {
        var arguments: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = obj
        }
        // `shell` 单独走一条路：它是唯一真的跑外部命令的工具，退出码是"命令到底成没成功"
        // 唯一可靠的信号（`cat /nope` 返回的也是一段文字，只看文本分不清那是文件内容
        // 还是报错；退出码分得清）。其余 30 多个工具根本没有"退出码"这个概念 ——
        // 给它们编一个 0 出来，事后就没法区分"真跑了命令且成功"和"压根不是命令类工具"。
        if toolName == "shell" { return executeShell(arguments: arguments) }

        return ToolExecutionOutcome(text: await executeBuiltin(toolName: toolName,
                                                              arguments: arguments))
    }

    /// 内置工具的纯文本分派。
    ///
    /// 为什么和 `execute` 拆开：只有 `shell` 需要额外带回退出码。为一个工具把三十多个
    /// `case` 全改成结构体返回值，等于把每一条分支都摸一遍，改动面大且处处可能是新错源；
    /// 拆出一个"只有 shell 例外"的入口，其余分支逐字不动。
    private static func executeBuiltin(toolName: String,
                                       arguments: [String: Any]) async -> String {
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
        case "memory":          return await executeMemory(arguments: arguments)
        case "phone":           return await executePhone(arguments: arguments)
        case "todo":            return await executeTodo(arguments: arguments)
        case "clipboard":       return executeClipboard(arguments: arguments)
        case "file_op":         return executeFileOp(arguments: arguments)
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
        // 注意：`shell` 故意**不在**这里。它由 `execute` 的分支提前接走；
        // 万一将来有人绕开 `execute` 直接调这个方法，会落到 default 报「未知工具」——
        // 一声响亮的不识别，远好过静默丢掉退出码。
        case "http_get":        return await executeHTTPGet(arguments: arguments)
        case "device_info":     return executeDeviceInfo()
        case "json_query":      return executeJSONQuery(arguments: arguments)
        case "timestamp":       return executeTimestamp(arguments: arguments)
        case "extract_urls":    return executeExtractURLs(arguments: arguments)
        case "csv_table":       return executeCSVTable(arguments: arguments)
        case "jwt_decode":      return executeJWTDecode(arguments: arguments)
        default:
            return unknownToolMarker + toolName
        }
    }

    /// 用户文件工作区。真实逻辑全在 `FileManagerService`（同步、带锁、沙盒化路径），
    /// 这里只负责把模型的参数翻成人话再翻回来。
    ///
    /// 返回值一律是**给模型看的文本**，不是给用户看的：包含足够复述给用户的信息
    /// （路径、行号、字节数），但不含实现细节（不吐绝对路径 —— 那是沙盒内部信息，
    /// 对模型没有用处，只是上下文噪音）。
    private static func executeFileOp(arguments: [String: Any]) -> String {
        let service = FileManagerService.shared

        guard let op = (arguments["op"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !op.isEmpty else {
            return "错误: 缺少 op 参数（可用: list/read/write/append/mkdir/move/delete/stat）"
        }
        let path = (arguments["path"] as? String) ?? ""

        /// 把 service 抛出的错误统一成 "错误: ..." 前缀。
        /// 前缀不能省：上层靠它区分"工具真的失败了"和"工具返回了一段含错误字样的正常内容"。
        func failure(_ error: Error) -> String {
            if let fileError = error as? FileManagerService.FileError {
                return "错误: \(fileError.errorDescription ?? "文件操作失败")"
            }
            return "错误: \(error.localizedDescription)"
        }

        do {
            switch op {
            case "list":
                let entries = try service.list(path)
                guard !entries.isEmpty else {
                    return "工作区是空的（路径 \(path.isEmpty ? "." : path)）。可以用 op=write 新建文件。"
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                let lines = entries.map { entry -> String in
                    if entry.isDirectory {
                        return "📁 \(entry.path)/"
                    }
                    let size = ByteCountFormatter.string(
                        fromByteCount: Int64(entry.bytes), countStyle: .file)
                    let stamp = entry.modified.map { formatter.string(from: $0) } ?? "-"
                    return "📄 \(entry.path)  (\(size), \(stamp))"
                }
                return "共 \(entries.count) 项：\n" + lines.joined(separator: "\n")

            case "read":
                let offset = (arguments["offset"] as? Int)
                    ?? Int((arguments["offset"] as? Double) ?? 1)
                let limit = (arguments["limit"] as? Int)
                    ?? Int((arguments["limit"] as? Double) ?? Double(FileManagerService.defaultReadLimit))
                let result = try service.read(path, offset: offset, limit: limit)
                guard !result.text.isEmpty else {
                    return "文件 \(path) 为空，或起始行 \(result.startLine) 超出了总行数 \(result.totalLines)。"
                }
                let lastLine = result.startLine + result.text.components(separatedBy: "\n").count - 1
                let more = lastLine < result.totalLines
                    ? "\n\n（以上是第 \(result.startLine)–\(lastLine) 行，共 \(result.totalLines) 行；"
                      + "需要后面的内容请把 offset 设为 \(lastLine + 1)）"
                    : "\n\n（以上是全文，共 \(result.totalLines) 行）"
                return result.text + more

            case "write", "append":
                guard let content = arguments["content"] as? String else {
                    return "错误: op=\(op) 需要 content 参数"
                }
                if op == "write" {
                    let bytes = try service.write(path, content: content)
                    return "已写入 \(path)（\(bytes) 字节，整体覆盖）"
                }
                let bytes = try service.append(path, content: content)
                return "已追加到 \(path)（追加后共 \(bytes) 字节）"

            case "mkdir":
                try service.makeDirectory(path)
                return "已创建目录 \(path)"

            case "move":
                guard let to = (arguments["to"] as? String), !to.isEmpty else {
                    return "错误: op=move 需要 to 参数（目标路径）"
                }
                try service.move(path, to: to)
                return "已把 \(path) 移动/重命名为 \(to)"

            case "delete":
                try service.delete(path)
                return "已删除 \(path)"

            case "stat":
                return try service.stat(path)

            default:
                return "错误: 不支持的 op「\(op)」（可用: list/read/write/append/mkdir/move/delete/stat）"
            }
        } catch {
            return failure(error)
        }
    }

    /// 全渠道执行：内置工具 → MCP（已连接服务器的工具）→ JS 插件 → 未知。
    /// Agent 循环统一走这里，修复 MCP 工具无法执行的问题并支持插件工具。
    /// @MainActor：访问 MCPService.shared / PluginManager.shared（MainActor 隔离单例）。
    @MainActor
    static func executeWithFallbacks(toolName: String,
                                     argumentsJSON: String) async -> ToolExecutionOutcome {
        // create_plugin 先走专用入口：它不"执行命令"，而是校验+预检+安装模型生成的 JS 插件。
        // 走到这里时 AgentService 的审批已经通过（requiresApproval=true，用户在安装卡片上确认过）。
        if toolName == "create_plugin" {
            return ToolExecutionOutcome(text: await PluginCreator.create(argumentsJSON: argumentsJSON))
        }
        let builtin = await execute(toolName: toolName, argumentsJSON: argumentsJSON)
        // 用共享常量判哨兵：写成字面量的话，两处早晚会漂移成"不再匹配"，
        // 结果是所有 MCP/插件工具突然全部变成"未知工具"。
        if !builtin.text.hasPrefix(unknownToolMarker) { return builtin }

        // MCP 工具（由已连接服务器暴露）
        if MCPService.shared.server(forToolName: toolName) != nil {
            return ToolExecutionOutcome(
                text: await MCPService.shared.callTool(name: toolName, argumentsJSON: argumentsJSON))
        }

        // JS 插件工具
        if PluginManager.shared.hasTool(named: toolName) {
            return ToolExecutionOutcome(
                text: await PluginManager.shared.callTool(name: toolName, argumentsJSON: argumentsJSON))
        }

        return builtin
    }

    // MARK: - 参数读取（"没传" 与 "传错" 必须分开）

    /// 参数读取的统一结果：恰好只有一边非 nil。
    /// 调用点固定写成两行：
    ///     let daysRead = intArgument(arguments, "days", default: 0)
    ///     guard let days = daysRead.value else { return daysRead.error ?? "错误: 参数 days 无效" }
    /// 这么写是为了让「键不存在 → 用默认值」和「键存在但类型不符 → 报错」在代码里一眼可辨。
    /// 原来满文件都是 `(arguments["days"] as? NSNumber)?.intValue ?? 0`：它把这两种情况
    /// 压成同一件事 —— 模型传了 `"days": "三天"` 也会静默用默认值 0 算出一个"看着对"的日期，
    /// 模型看不到任何异常，于是继续基于错结果往下走，用户最后拿到的是错的。
    private enum ArgumentRead<T> {
        case ok(T)
        case fail(String)

        var value: T? {
            if case .ok(let v) = self { return v }
            return nil
        }

        var error: String? {
            if case .fail(let message) = self { return message }
            return nil
        }
    }

    /// 取原始参数值：键不存在、或显式写成 JSON null，都算"没传"（模型常把可选参数写成 null）。
    private static func rawArgument(_ arguments: [String: Any], _ key: String) -> Any? {
        guard let raw = arguments[key] else { return nil }
        if raw is NSNull { return nil }
        return raw
    }

    /// 把参数原值转成给模型看的一小段文本。回显原文很重要：模型收到"期望数字"时
    /// 并不知道自己发的是什么，把收到的值照抄回去，它下一轮才有机会自我纠正。
    private static func describeArgumentValue(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let s = value as? String { return "「\(s)」（字符串）" }
        // JSON 里的 true/false 在 Swift 侧同样是 NSNumber，所以必须先用 CFBoolean 的 typeID
        // 区分开：`as? Bool` 对 NSNumber(1) 也成立（老坑），只按 as? 判断的话
        // `"days": 1` 会被描述成 "true（布尔）"，回显给模型的就是错的信息。
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true（布尔）" : "false（布尔）"
            }
            return n.stringValue
        }
        if let a = value as? [Any] { return "[\(a.count) 个元素的数组]" }
        if let d = value as? [String: Any] { return "{\(d.count) 个键的对象}" }
        return "\(value)"
    }

    /// 数字的核心解析。为什么要把数字**字符串**也当数字收下：
    /// 小参数模型（1B~4B 这一档）经常把数字写成 `"3"`、`"3.5"`，
    /// 老代码的 `as? NSNumber` 对字符串一律失败 → 静默落到默认值。
    /// 所以这里先按 Double 解析字符串，只有真转换不了才报错。
    private static func parseNumber(_ raw: Any, key: String) -> ArgumentRead<Double> {
        if let n = raw as? NSNumber {
            // 布尔不是数字：`"days": true` 不该被当成 1
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .fail("错误: 参数 \(key) 期望数字，实际收到 \(describeArgumentValue(raw))")
            }
            return .ok(n.doubleValue)
        }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Double(trimmed) { return .ok(d) }
        }
        return .fail("错误: 参数 \(key) 期望数字，实际收到 \(describeArgumentValue(raw))")
    }

    private static func doubleArgument(_ arguments: [String: Any], _ key: String, default def: Double) -> ArgumentRead<Double> {
        guard let raw = rawArgument(arguments, key) else { return .ok(def) }
        return parseNumber(raw, key: key)
    }

    private static func intArgument(_ arguments: [String: Any], _ key: String, default def: Int) -> ArgumentRead<Int> {
        guard let raw = rawArgument(arguments, key) else { return .ok(def) }
        switch parseNumber(raw, key: key) {
        case .fail(let message):
            return .fail(message)
        case .ok(let d):
            // 3.7 天的语义不明，与其四舍五入猜一个，不如让模型自己改成整数
            guard d == d.rounded(), Swift.abs(d) < 9.0e15 else {
                return .fail("错误: 参数 \(key) 期望整数，实际收到 \(describeArgumentValue(raw))")
            }
            return .ok(Int(d))
        }
    }

    /// 必填数字参数（没有默认值）：键不存在要明确说"缺少哪个参数"，而不是"缺少参数"。
    private static func requiredDoubleArgument(_ arguments: [String: Any], _ key: String) -> ArgumentRead<Double> {
        guard let raw = rawArgument(arguments, key) else { return .fail("错误: 缺少 \(key) 参数") }
        return parseNumber(raw, key: key)
    }

    /// 布尔参数。同样要容忍字符串写法：模型发 `"dedup": "true"` 时，
    /// 老的 `as? Bool ?? false` 会静默当成 false —— 模型以为去重了，其实没有。
    private static func boolArgument(_ arguments: [String: Any], _ key: String, default def: Bool) -> ArgumentRead<Bool> {
        guard let raw = rawArgument(arguments, key) else { return .ok(def) }
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return .ok(n.boolValue)
        }
        if let s = raw as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y", "是": return .ok(true)
            case "false", "0", "no", "n", "否": return .ok(false)
            default: break
            }
        }
        return .fail("错误: 参数 \(key) 期望布尔值(true/false)，实际收到 \(describeArgumentValue(raw))")
    }

    /// 字符串参数。用在原来是 `as? String ?? 默认值` 的地方：
    /// 键不存在照旧用默认值，键存在却不是字符串就报错（而不是悄悄用默认值）。
    private static func stringArgument(_ arguments: [String: Any], _ key: String, default def: String) -> ArgumentRead<String> {
        guard let raw = rawArgument(arguments, key) else { return .ok(def) }
        if let s = raw as? String { return .ok(s) }
        return .fail("错误: 参数 \(key) 期望字符串，实际收到 \(describeArgumentValue(raw))")
    }

    /// 必填字符串参数：错误信息里点名是哪个参数（"缺少 path 参数" 而不是 "缺少参数"），
    /// 模型才知道该补哪一个。
    private static func requiredStringArgument(_ arguments: [String: Any], _ key: String) -> ArgumentRead<String> {
        guard let raw = rawArgument(arguments, key) else { return .fail("错误: 缺少 \(key) 参数") }
        if let s = raw as? String { return .ok(s) }
        return .fail("错误: 参数 \(key) 期望字符串，实际收到 \(describeArgumentValue(raw))")
    }

    /// 取工具参数在 `allTools` 里**声明**的可选值。真源只留一份：
    /// 如果一边在定义里写着 enum: ["save","read","list","delete"]、一边在执行里另抄一份，
    /// 两边早晚会漂移（加了新 op 却忘了改校验，或者校验里留着早就删掉的 op）。
    private static func allowedValues(tool: String, parameter: String, fallback: [String]) -> [String] {
        allTools.first { $0.name == tool }?.parameters[parameter]?.enumValues ?? fallback
    }

    /// 枚举型字符串参数（op / mode / style / transform / algorithm / auth_type 这类）。
    /// 为什么必须报错而不能兜底：原来 `arguments["op"] as? String ?? "list"` 这种写法里，
    /// 打错的值会**静默降级到默认分支** —— 用户说"删掉那条笔记"，模型发 op="remove"，
    /// 工具却去执行 list 并返回笔记列表，模型看到"有返回"就回复"已删除"。
    /// 失败被伪装成成功，比直接报错危险得多。所以未知取值一律报错，并把可选值列全。
    /// `default` 为 nil 表示这个参数必填。
    private static func enumeratedArgument(
        _ arguments: [String: Any],
        _ key: String,
        label: String,
        allowed: [String],
        default def: String?
    ) -> ArgumentRead<String> {
        guard let raw = rawArgument(arguments, key) else {
            if let def { return .ok(def) }
            return .fail("错误: 缺少 \(key) 参数，可选: \(allowed.joined(separator: ", "))")
        }
        guard let s = raw as? String else {
            return .fail("错误: 参数 \(key) 期望字符串，实际收到 \(describeArgumentValue(raw))")
        }
        // 归一化大小写与空白："Save"、 " save " 都当 save 处理（模型输出大小写不稳），
        // 但真正的错别字（"sav"/"remove"）仍然要拦下来报错。
        let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowed.contains(normalized) else {
            return .fail("错误: 未知\(label) \"\(s)\"，可选: \(allowed.joined(separator: ", "))")
        }
        return .ok(normalized)
    }

    // MARK: - 工具实现

    private static func executeCalculator(arguments: [String: Any]) -> String {
        guard let expression = arguments["expression"] as? String else {
            return "错误: 缺少 expression 参数"
        }
        let value: Double
        switch evaluateMathDetailed(expression) {
        case .ok(let v):
            value = v
        case .badSyntax:
            return "错误: 无法解析表达式「\(expression)」，请检查运算符与括号是否完整"
        case .outOfDomain(let detail):
            // 定义域错误**不能**复用上面那句"请检查运算符与括号"。
            // 实测：`sqrt(-1)`、`ln(0)`、`1/0`、`asin(2)` 全都走的是 nil 分支，
            // 于是模型收到"括号可能不完整"，转头去改一个本来完全正确的表达式 ——
            // 白费一轮，而且下一轮还是同样的错。语法问题与取值问题必须分开说，
            // 并且要把"哪个函数的哪个参数越界"直接讲出来，模型才知道该换什么。
            return "错误: 表达式「\(expression)」语法没问题，但 \(detail)"
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
        // 原写法 `(arguments["min"] as? NSNumber)?.intValue ?? 1`：min 传了 "abc" 也会
        // 静默按 1 算，回给用户的却是"范围 1~100"，请求的范围和实际用的根本不是一回事。
        let minRead = intArgument(arguments, "min", default: 1)
        guard let minV = minRead.value else { return minRead.error ?? "错误: 参数 min 无效" }
        let maxRead = intArgument(arguments, "max", default: 100)
        guard let maxV = maxRead.value else { return maxRead.error ?? "错误: 参数 max 无效" }
        guard minV <= maxV else { return "错误: min 应不大于 max（收到 min=\(minV), max=\(maxV)）" }
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
        // 原来是两条 `as? String` 合在一个 guard 里、报"错误: 缺少参数"：
        // 模型只知道自己少传了东西，却不知道是 text 还是 transform，只能瞎猜一轮。
        let textRead = requiredStringArgument(arguments, "text")
        guard let text = textRead.value else { return textRead.error ?? "错误: 缺少 text 参数" }
        let transformRead = enumeratedArgument(
            arguments, "transform", label: "转换类型",
            allowed: allowedValues(tool: "text_transform", parameter: "transform",
                                   fallback: ["uppercase", "lowercase", "reverse", "base64_encode", "base64_decode"]),
            default: nil)
        guard let transform = transformRead.value else {
            return transformRead.error ?? "错误: 缺少 transform 参数"
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
            // 失败分支也要带「错误: 」前缀：上层靠它把这步标成 error，
            // 否则"Base64解码失败"会被当成一次成功的工具输出喂回给模型。
            guard let data = Data(base64Encoded: text) else { return "错误: Base64 解码失败（输入不是合法的 base64）" }
            guard let decoded = String(data: data, encoding: .utf8) else {
                return "错误: Base64 解码结果不是有效的 UTF-8 文本（原始 \(data.count) 字节）"
            }
            return decoded
        default:
            // enumeratedArgument 已经挡住了未知值，走到这里说明 allowedValues 的声明被人改过，
            // 保守起见仍然报错而不是猜一个分支执行。
            return "错误: 未知转换类型「\(transform)」"
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
        let dateRead = stringArgument(arguments, "date", default: "")
        guard let dateStr = dateRead.value else { return dateRead.error ?? "错误: 参数 date 无效" }
        let daysRead = intArgument(arguments, "days", default: 0)
        guard let days = daysRead.value else { return daysRead.error ?? "错误: 参数 days 无效" }

        // 原写法 `dateFormatter.date(from: dateStr) ?? Date()` 是个隐蔽的坑：
        // date 只在**为空**时才代表"今天"，但解析失败（"2026-8-29"、"2026/08/29"、"明天"）
        // 也被 `?? Date()` 吞成了今天，于是"2026-8-29 加 7 天"会返回"今天 +7 天"这种
        // 看似正确的错误答案 —— 用户完全无法察觉。日期串非空就必须解析成功，否则报错。
        let base: Date
        if dateStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = Date()
        } else if let parsed = dateFormatter.date(from: dateStr) {
            base = parsed
        } else {
            return "错误: 无法解析日期 \"\(dateStr)\"，请用 yyyy-MM-dd 格式"
        }

        guard let result = Calendar.current.date(byAdding: .day, value: days, to: base) else {
            return "错误: 日期计算失败（\(dateStr) 加减 \(days) 天超出可表示范围）"
        }
        return "\(dateFormatter.string(from: base)) + \(days) 天 = \(dateFormatter.string(from: result))"
    }

    private static func executeDateDiff(arguments: [String: Any]) -> String {
        // 原来把两个日期捏在一个 guard 里报"需要有效的 date1 和 date2"，
        // 模型无法知道该修哪一个（甚至不知道是"没传"还是"格式错"），这里逐个点名 + 回显原值。
        let d1Read = requiredStringArgument(arguments, "date1")
        guard let d1 = d1Read.value else { return d1Read.error ?? "错误: 缺少 date1 参数" }
        let d2Read = requiredStringArgument(arguments, "date2")
        guard let d2 = d2Read.value else { return d2Read.error ?? "错误: 缺少 date2 参数" }
        guard let a = dateFormatter.date(from: d1) else {
            return "错误: 无法解析日期 \"\(d1)\"（date1），请用 yyyy-MM-dd 格式"
        }
        guard let b = dateFormatter.date(from: d2) else {
            return "错误: 无法解析日期 \"\(d2)\"（date2），请用 yyyy-MM-dd 格式"
        }
        let days = Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
        // 不再取绝对值。原写法 `Swift.abs(days)` 把方向整个丢掉了：
        // date1=2026-01-01、date2=2025-01-01 会答"相差 365 天"，与顺序无关 ——
        // 而参数名是"起始日期/结束日期"，问"还有几天到期"而日期已过时，
        // 用户需要的是负数（已过期），拿到一个正数会直接得出相反结论。
        // 现在保留符号，并在文字里点明方向，避免模型把负号理解成错误。
        let magnitude = Swift.abs(days)
        if days == 0 { return "\(d1) 与 \(d2) 是同一天" }
        return days > 0
            ? "\(d1) 到 \(d2) 相差 \(magnitude) 天（date2 在 date1 之后）"
            : "\(d1) 到 \(d2) 相差 -\(magnitude) 天（date2 在 date1 之前，即 date1 起算已过去 \(magnitude) 天）"
    }

    private static func executeHashText(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else { return "错误: 缺少 text 参数" }
        // 原来 `(arguments["algorithm"] as? String)?.lowercased() ?? "sha256"`：
        // algorithm 传了数字、或者拼成 "sha-256"，都会静默按 sha256 计算 ——
        // 用户要的是 MD5，拿回来的是 SHA256，值长得一样长，肉眼看不出来。
        let algorithmRead = enumeratedArgument(
            arguments, "algorithm", label: "算法",
            allowed: allowedValues(tool: "hash_text", parameter: "algorithm", fallback: ["md5", "sha1", "sha256"]),
            default: "sha256")
        guard let algorithm = algorithmRead.value else {
            return algorithmRead.error ?? "错误: 参数 algorithm 无效"
        }
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
            return "错误: 未知算法「\(algorithm)」（可选 md5/sha1/sha256）"
        }
        return "\(algorithm) = \(hex)"
    }

    private static func executeJsonFormat(arguments: [String: Any]) -> String {
        guard let json = arguments["json"] as? String else { return "错误: 缺少 json 参数" }
        // 布尔参数同样不能再 `?? true`：模型发 pretty:"false"（字符串）时会被当成 true，
        // 用户明确要求压缩，拿到的却是美化后的多行 JSON。
        let prettyRead = boolArgument(arguments, "pretty", default: true)
        guard let pretty = prettyRead.value else { return prettyRead.error ?? "错误: 参数 pretty 无效" }
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
        // 原来 `arguments["mode"] as? String ?? "encode"`：mode 打成 "decde" 会走 encode，
        // 也就是把已经编码的文本**再编码一次**，返回一坨双重编码的 %25E4%25B8... 给模型，
        // 模型会当成"解码结果"直接展示给用户。
        let modeRead = enumeratedArgument(
            arguments, "mode", label: "模式",
            allowed: allowedValues(tool: "url_codec", parameter: "mode", fallback: ["encode", "decode"]),
            default: "encode")
        guard let mode = modeRead.value else { return modeRead.error ?? "错误: 参数 mode 无效" }
        if mode == "decode" {
            // 解码失败也要走错误通道：原来返回 "解码失败" 不带前缀，
            // 上层会把它当成正常的工具输出，模型于是把"解码失败"四个字当内容用了。
            guard let decoded = text.removingPercentEncoding else {
                return "错误: URL 解码失败（输入里有非法的百分号转义）"
            }
            return decoded
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return "错误: URL 编码失败（输入含无法编码的字符）"
        }
        return encoded
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
    private static func executeNote(arguments: [String: Any]) async -> String {
        // op 必须先校验：`NoteStore.perform` 的 default 分支是 list，所以 op 打错（"remove"/"保存"）
        // 会被静默当成"列出笔记"执行 —— 用户说删笔记，工具返回一份笔记清单，
        // 模型看到"有内容返回"就回复"已删除"，用户以为删了，其实一条没动。
        // 这里归一化大小写后只放行声明过的四个 op，其余一律报错并列出可选值。
        // 没传 op 时的默认值仍然是 "list"（保持向后兼容的旧行为）。
        let opRead = enumeratedArgument(
            arguments, "op", label: "操作",
            allowed: allowedValues(tool: "note", parameter: "op", fallback: ["save", "read", "list", "delete"]),
            default: "list")
        guard let op = opRead.value else { return opRead.error ?? "错误: 参数 op 无效" }
        let rawName = (arguments["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = arguments["content"] as? String ?? ""
        // 工具跑在非隔离的 static async 上下文里，而 NoteStore 是 @MainActor（要给 SwiftUI 用），
        // 所以显式跳一次主线程。笔记都是小文本文件，这点 I/O 放主线程没有影响。
        return await MainActor.run {
            NoteStore.shared.perform(op: op, name: rawName, content: content)
        }
    }

    /// `memory` 工具：读写**全局长期记忆**（PersonaStore.memory）。
    ///
    /// 与 `note` 的差别不只是存储位置：memory 的内容会进 system prompt（STATIC 段），
    /// 所以它的返回值也要短 —— list 最多回 20 条、每行短 id + 正文，
    /// 否则工具结果本身就把上下文撑爆了，而它本该是"被读取的资料"。
    private static func executeMemory(arguments: [String: Any]) async -> String {
        // op 必填、不给默认值（同 `todo`，异于 `note`）：
        // memory 的写入是**每次对话都会带上**的持久副作用，让"漏传 op"静默落进某个分支
        // 比直接报错危险。报错文案会把可选值列给模型，一次就够它改对。
        let opRead = enumeratedArgument(
            arguments, "op", label: "操作",
            allowed: allowedValues(tool: "memory", parameter: "op", fallback: ["list", "save", "delete"]),
            default: nil)
        guard let op = opRead.value else { return opRead.error ?? "错误: 参数 op 无效" }

        let content = arguments["content"] as? String ?? ""
        let rawID = (arguments["id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 在**闭包外**把参数读成 Sendable 原子类型（Int/String）：
        // `arguments` 是 `[String: Any]`，`Any` 不是 Sendable，整个字典传进
        // `MainActor.run` 的闭包会撞 Swift 6 的 sending 检查（与 todos 那段同理）。
        // limit 默认 20：按 80 字正文 + 8 字 id 估算 ≈ 1900 字，正好压在工具结果
        // 2000 字截断线之内 —— 超出会被悄悄砍掉最后几条，模型会以为记忆不存在。
        let limitArg = arguments["limit"]
        let limitRaw = (limitArg as? Int)
            ?? Int(limitArg as? String ?? "")
            ?? 20
        let limit = min(max(limitRaw, 1), PersonaStore.maxEntries)

        // PersonaStore 是 @MainActor（SwiftUI 的数据源），这里显式跳主线程；
        // 它只改内存数组 + 异步落盘，主线程开销可忽略。
        return await MainActor.run { () -> String in
            let store = PersonaStore.shared
            switch op {
            case "list":
                let all = store.listEntries()
                guard !all.isEmpty else { return "（暂无记忆）" }
                let shown = Array(all.suffix(limit).reversed())
                let head = all.count > shown.count
                    ? "共 \(all.count) 条，显示最近 \(shown.count) 条（旧的用 limit 再取）：\n"
                    : ""
                return head + shown.map {
                    "\(PersonaStore.shortID($0)) \($0.content)"
                }.joined(separator: "\n")

            case "save":
                let text = PersonaStore.normalize(content)
                guard !text.isEmpty else {
                    return "错误: content 为空，未写入。save 必须给出一句话（≤\(PersonaStore.maxEntryLength) 字）。"
                }
                guard let result = store.saveEntry(content) else {
                    return "错误: 写入失败，请重试"
                }
                if result.created {
                    return "已记住：\(result.entry.content)（现有 \(store.listEntries().count)/\(PersonaStore.maxEntries) 条）"
                }
                // 命中去重：如实告诉模型"没新增"，否则它会以为写进去了、下次还重复写。
                return "已有相近记忆，未重复写入：\(result.entry.content)"

            case "delete":
                guard !rawID.isEmpty else {
                    return "错误: delete 需要 id（先用 list 获取短 id）"
                }
                guard let removed = store.deleteEntry(id: rawID) else {
                    return "错误: 找不到 id 为 \(rawID) 的记忆（可能已被删或前缀有歧义），先用 list 核对"
                }
                return "已删除：\(removed)"

            default:
                return "错误: 不支持的 op: \(op)"
            }
        }
    }

    /// `phone` 工具：配方管理 + 运行 + 能力探测 + 操作指引（guide）。
    ///
    /// 所有"动作是否真的发生"都由 `ShortcutEngine` 判定并原样回传：
    /// 这里**不补任何乐观文案**。这个工具最坏的失败不是报错，而是让模型
    /// 向用户复述"已经点过了"—— 那会让用户以为自动化生效了，其实屏幕上什么都没发生。
    private static func executePhone(arguments: [String: Any]) async -> String {
        let opRead = enumeratedArgument(
            arguments, "op", label: "操作",
            allowed: allowedValues(tool: "phone", parameter: "op",
                                   fallback: ["probe", "capability", "stats", "list", "run", "save",
                                              "delete", "open", "app", "wait", "screenshot", "guide"]),
            default: nil)
        guard let op = opRead.value else { return opRead.error ?? "错误: 参数 op 无效" }

        let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = arguments["summary"] as? String ?? ""
        let steps = arguments["steps"] as? String ?? ""

        switch op {
        case "list":
            return await MainActor.run {
                let recipes = ShortcutStore.shared.recipes
                guard !recipes.isEmpty else {
                    return "（暂无配方。用 save 保存一条，或直接用 run + 快捷指令名触发系统里的指令）"
                }
                return recipes.map { r in
                    "\(r.id.uuidString.prefix(8)) \(r.name) — \(r.summary.isEmpty ? "(无说明)" : r.summary)"
                        + (r.actions.isEmpty ? "" : "（\(r.actions.count) 步）")
                }.joined(separator: "\n")
            }

        case "save":
            guard !name.isEmpty else {
                return "错误: save 需要 name（快捷指令名或配方名）"
            }
            return await MainActor.run {
                guard let recipe = ShortcutStore.shared.save(name: name, summary: summary, actionsText: steps) else {
                    return "错误: 配方名不能为空"
                }
                let body = recipe.actions.isEmpty
                    ? "（未填 steps，之后 run 会直接按名字触发同名快捷指令）"
                    : "\n\(recipe.actionDescriptions.map { "  · " + $0 }.joined(separator: "\n"))"
                return "已保存「\(recipe.name)」：\(recipe.summary.isEmpty ? "(无说明)" : recipe.summary)\(body)"
            }

        case "delete":
            guard !name.isEmpty else { return "错误: delete 需要 name 或 id" }
            return await MainActor.run {
                guard let removed = ShortcutStore.shared.delete(id: name) else {
                    return "错误: 找不到配方「\(name)」（先用 list 核对）"
                }
                return "已删除配方「\(removed)」"
            }

        case "run":
            guard !name.isEmpty else { return "错误: run 需要 name" }
            // 配方优先：有同名配方就按它执行（run/open/wait/注释），没有就直接触发快捷指令。
            let recipe = await MainActor.run { ShortcutStore.shared.recipe(id: name) }
            if let recipe { return await ShortcutEngine.run(recipe) }
            return await ShortcutEngine.runShortcut(named: name)

        case "probe":
            let caps = await ShortcutEngine.capabilities()
            let matrix = await ShortcutEngine.capabilityText(caps)
            let report = await ShortcutEngine.probe()
            let m = await ShortcutEngine.metrics
            return report
                + "\n\n## 能力矩阵（capability-first）\n" + matrix
                + "\n\n## 步骤指标\n" + m.summaryLine

        case "capability":
            let caps = await ShortcutEngine.capabilities()
            let text = await ShortcutEngine.capabilityText(caps)
            let policy = ComputerRetryPolicy.default
            return "能力矩阵\n" + text
                + "\n重试上限 maxRetries=\(policy.maxRetries)，"
                + "单动作超时 \(policy.actionTimeoutMs)ms —— 超过就停下汇报，不要无限重试。"

        case "stats":
            let m = await ShortcutEngine.metrics
            return "步骤指标：\(m.summaryLine)"

        case "screenshot":
            return (await ShortcutEngine.execute(.screenshot, attempt: 1)).jsonString

        case "wait":
            guard let ms = arguments["ms"] as? Double ?? (arguments["ms"] as? Int).map(Double.init) else {
                return "错误: wait 需要 ms（0..30000）"
            }
            return (await ShortcutEngine.execute(.wait(milliseconds: Int(ms)), attempt: 1)).jsonString

        case "open":
            guard !name.isEmpty else { return "错误: open 需要 name（URL）" }
            return (await ShortcutEngine.execute(.openURL(name), attempt: 1)).jsonString

        case "app":
            guard !name.isEmpty else { return "错误: app 需要 name（App 名）" }
            return (await ShortcutEngine.execute(.openApp(name: name), attempt: 1)).jsonString

        case "guide":
            // 「实时指导用户操作」：本构建不能合成点击，交互由用户完成。
            // 这条指引会进入「手机协作」会话，展示给用户照着做。
            guard let text = arguments["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "错误: guide 需要 text（给用户看的操作指引）"
            }
            await MobileAgentBridge.shared.publishGuidance(text)
            return "已把操作指引展示给用户：\(text)"

        default:
            return "错误: 不支持的 op: \(op)"
        }
    }

    /// 从工具参数里读一个浮点数（模型可能发 Double、整数或字符串）。
    private static func doubleArgument(_ arguments: [String: Any], _ key: String) -> Double? {
        if let d = arguments[key] as? Double { return d }
        if let n = arguments[key] as? NSNumber { return n.doubleValue }
        if let s = arguments[key] as? String { return Double(s) }
        return nil
    }

    /// `todo` 工具：维护当前任务的步骤清单（面板上可见的进度）。
    ///
    /// 数据的读写与文案**全部**交给 `TodoStore` —— 它同时是 UI 面板的数据源，两边各写一份
    /// 状态的话，模型更新完清单界面不会跟着变（和 `NoteStore` 当初的问题一模一样）。
    /// 这个函数只做三件事：校验 op、把 todos 原样转成 JSON、把结果递进主线程。
    /// 形状校验与全部容错文案都在 `TodoStore`（谁的数据谁负责，报错文案只留一份）。
    private static func executeTodo(arguments: [String: Any]) async -> String {
        // op 必填（default: nil）。这里与 `note`/`clipboard` 刻意不同：那两个工具"漏传 op"的
        // 默认分支是只读的 list/get，猜错了最多返回一份多余的内容；而 `todo` 没有任何一个
        // 分支适合当默认值 —— 默认 set 会让模型漏参数时**把用户的清单覆盖成空**，
        // 默认 list 则会让"写计划"变成"看一眼旧计划"，模型看到有返回就以为记下了。
        // 又因为模型看不到自己少发了哪个字段，静默兜底比直接报错危险得多，所以必填。
        let opRead = enumeratedArgument(
            arguments, "op", label: "操作",
            allowed: allowedValues(tool: "todo", parameter: "op", fallback: ["set", "list", "clear"]),
            default: nil)
        guard let op = opRead.value else { return opRead.error ?? "错误: 参数 op 无效" }

        switch op {
        case "set":
            // 参数形态这一步只做"能不能序列化"，**形状校验（缺 todos / 不是数组 / 元素不是对象）
            // 全部交给 TodoStore.replace(withJSON:)** —— 报错文案只有一份，不会两边漂移。
            //
            // 为什么要绕一圈 JSON 字符串：`arguments["todos"]` 从 JSONSerialization 出来是
            // `[[String: Any]]`，而嵌套字典数组**不是 Sendable**，直接捕获进下面 `MainActor.run`
            // 的闭包在 Swift 6 严格并发下是编译错误（sending 'items' risks causing data races）。
            // 转成 String 再跨 actor，与 `execute(toolName:argumentsJSON:)` 收参数的写法同一个道理。
            // `todos` 可能压根不是数组（字符串数组、对象、null，模型都发得出来）：这里全部走
            // `else` 分支交给 store 报错，**不做任何 `as!` 强转** —— 一次参数写错不该让整个 App 崩掉。
            let todosJSON: String
            if let rawTodos = rawArgument(arguments, "todos"),
               JSONSerialization.isValidJSONObject(rawTodos),
               let data = try? JSONSerialization.data(withJSONObject: rawTodos),
               let text = String(data: data, encoding: .utf8) {
                todosJSON = text
            } else {
                // 键不存在、或者值无法序列化：传 "null" 进去，由 store 统一报
                // 「错误: set 需要 todos 数组」。这样那句文案在代码里只有一份。
                todosJSON = "null"
            }
            // 工具跑在非隔离的 static async 上下文里，而 TodoStore 是 @MainActor（要给 SwiftUI 用），
            // 所以显式跳一次主线程 —— 与 executeNote 同样的写法与理由。这里只有内存操作和
            // 一个很小的 JSON 文件写入，放主线程没有影响。
            return await MainActor.run {
                TodoStore.shared.replace(withJSON: todosJSON)
            }
        case "list":
            return await MainActor.run { TodoStore.shared.listText() }
        case "clear":
            // 清空当前对话的清单（其它对话不受影响，隔离在 TodoStore 里做）。
            // 返回文案写死：与 TodoStore 里 set / list 的文案保持一致。
            return await MainActor.run {
                TodoStore.shared.clear()
                return "已清空任务清单"
            }
        default:
            // 正常走不到这里：上面已经按工具定义里的 enum 校验过 op。
            // 留着是为了防止将来往 enum 里加了新 op 却忘了在这个 switch 里实现 ——
            // 那时它会静默落到 clear，把用户的清单清掉。
            return "错误: 未知操作 \"\(op)\"，可选: set, list, clear"
        }
    }

    private static func executeClipboard(arguments: [String: Any]) -> String {
        // 和 note 同样的坑：原来 `arguments["op"] as? String ?? "get"` 里，op 打错（"write"）
        // 会退化成读取剪贴板并返回内容，模型拿到一段文本就以为"已写入"。
        // 默认值仍是 "get"（读取是无副作用的一侧，缺参数时保守取值）。
        let opRead = enumeratedArgument(
            arguments, "op", label: "操作",
            allowed: allowedValues(tool: "clipboard", parameter: "op", fallback: ["get", "set"]),
            default: "get")
        guard let op = opRead.value else { return opRead.error ?? "错误: 参数 op 无效" }
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
        return "错误: 剪贴板在当前平台不可用"
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

    /// 求值结果。区分"写错了"（语法）与"取不到值"（定义域）—— 这两种错的修法完全不同，
    /// 而上层原来只能看到一个 `nil`，于是把 `sqrt(-1)` 也报成"检查括号是否完整"。
    /// 报错的粒度决定了模型下一轮能不能一次改对：说"括号可能不完整"它会去改括号，
    /// 说"sqrt 的参数不能是负数"它才知道要换算式。
    enum MathEvalResult {
        case ok(Double)
        case badSyntax
        case outOfDomain(String)
    }

    private static func evaluateMathDetailed(_ input: String) -> MathEvalResult {
        let cleaned = input
            .lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "π", with: "pi")
        guard let tokens = tokenizeMath(cleaned), !tokens.isEmpty else { return .badSyntax }

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
                if !found { return .badSyntax } // 括号不匹配
                if case .op(let fn)? = stack.last, isFunction(fn) {
                    output.append(stack.removeLast())
                }
            }
        }
        while let top = stack.popLast() {
            if top == .lparen { return .badSyntax } // 括号不匹配
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
                guard values.count >= n else { return .badSyntax }
                let args = Array(values.suffix(n))
                values.removeLast(n)
                let a = args[0]
                let b = n == 2 ? args[1] : 0
                // 每个函数/运算符在**这里**就把越界情况说清楚，而不是先算出 nil
                // 再让上层去猜原因。措辞里必须带上具体的函数名与它的定义域。
                switch name {
                case "+": values.append(a + b)
                case "-": values.append(a - b)
                case "u+": values.append(a)
                case "u-": values.append(-a)
                case "*": values.append(a * b)
                case "/":
                    if b == 0 { return .outOfDomain("除数不能为 0（除以零没有定义）") }
                    values.append(a / b)
                case "%":
                    if b == 0 { return .outOfDomain("取余的除数不能为 0") }
                    values.append(a.truncatingRemainder(dividingBy: b))
                case "^", "pow":
                    let r = pow(a, b)
                    if !r.isFinite {
                        return .outOfDomain("pow(\(fmtNum(a)), \(fmtNum(b))) 的结果超出双精度浮点能表示的范围"
                                            + "（本次计算用 Double，不是任意精度整数）")
                    }
                    values.append(r)
                case "sqrt":
                    if a < 0 { return .outOfDomain("sqrt 的参数不能是负数（sqrt(\(fmtNum(a))) 在实数范围内没有定义）") }
                    values.append(sqrt(a))
                case "abs": values.append(Swift.abs(a))
                case "round": values.append(a.rounded())
                case "floor": values.append(floor(a))
                case "ceil": values.append(ceil(a))
                case "sin": values.append(sin(a))
                case "cos": values.append(cos(a))
                case "tan":
                    if cos(a) == 0 { return .outOfDomain("tan 在该点没有定义（cos = 0）") }
                    values.append(tan(a))
                case "asin":
                    if !(-1...1).contains(a) { return .outOfDomain("asin 的参数必须在 -1 到 1 之间（收到 \(fmtNum(a))）") }
                    values.append(asin(a))
                case "acos":
                    if !(-1...1).contains(a) { return .outOfDomain("acos 的参数必须在 -1 到 1 之间（收到 \(fmtNum(a))）") }
                    values.append(acos(a))
                case "atan": values.append(atan(a))
                case "log", "log10":
                    if a <= 0 { return .outOfDomain("log10 的参数必须大于 0（收到 \(fmtNum(a))）") }
                    values.append(log10(a))
                case "ln":
                    if a <= 0 { return .outOfDomain("ln 的参数必须大于 0（收到 \(fmtNum(a))）") }
                    values.append(log(a))
                case "exp": values.append(exp(a))
                case "min": values.append(min(a, b))
                case "max": values.append(max(a, b))
                default:
                    // 到这里说明 tokenizer 认出了一个求值器不认识的函数名 —— 属于实现内部的
                    // 不一致（不是用户输入的问题），所以如实说"不支持"，不要伪装成语法错。
                    return .outOfDomain("不支持函数 \(name)")
                }
            case .lparen, .rparen, .comma:
                return .badSyntax
            }
        }
        // 结果不是有限数（如 exp(1000) 溢出）同样属于"取不到值"，不是语法问题。
        guard values.count == 1 else { return .badSyntax }
        guard values[0].isFinite else { return .outOfDomain("结果超出双精度浮点能表示的范围") }
        return .ok(values[0])
    }

    /// 报错文案里回显数值用（整数不带小数点，便于模型直接读懂）
    private static func fmtNum(_ v: Double) -> String {
        if v == v.rounded() && Swift.abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%g", v)
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
        // 上限 20 条是为了别撑爆上下文，但**必须把这个截断说出来**。
        // 原来只列 20 条、结尾却写"找到 N 个匹配"，模型会理所当然地认为手上就是全部：
        // 让它统计"一共有多少条日志"，它数了 20 条就报 20 —— 数据是错的，而且看不出错。
        let displayLimit = 20
        for (i, match) in matches.prefix(displayLimit).enumerated() {
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

        let truncated = matches.count > displayLimit
        let header = truncated
            ? "找到 \(matches.count) 个匹配（仅显示前 \(displayLimit) 个，其余 \(matches.count - displayLimit) 个未显示）"
            : "找到 \(matches.count) 个匹配"
        var output = "\(header):\n\(results.joined(separator: "\n"))"
        if truncated {
            // 明确告诉模型"下面这份列表不完整"以及怎么办，否则它会拿前 20 条当全集去做统计/汇总
            output += "\n（注意：以上不是全部结果，不要据此统计总数；需要全部匹配时请用更精确的正则，或先用更小的 text 分段调用）"
        }
        return output
    }

    // MARK: - 文本摘要工具

    private static func executeTextSummary(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else {
            return "错误: 缺少 text 参数"
        }
        
        let maxRead = intArgument(arguments, "max_length", default: 200)
        guard let maxLength = maxRead.value else { return maxRead.error ?? "错误: 参数 max_length 无效" }
        // 下界不能省：max_length 传 1 或 2 时，下面 `String(summary.prefix(maxLength - 3))`
        // 拿到的是**负长度**，prefix 会直接触发运行期崩溃（不是返回错误，是 App 闪退）。
        // 这种崩溃只会在模型恰好传了小数值时才出现，测试很难覆盖到，所以在这里拦住。
        guard maxLength >= 3 else {
            return "错误: max_length 至少为 3（收到 \(maxLength)）"
        }

        if text.count <= maxLength {
            return "原文较短，无需摘要:\n\(text)"
        }
        
        // 智能摘要：提取关键句子
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if sentences.isEmpty {
            return "错误: 无法提取有效内容（文本里没有可分句的句子）"
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
        // from/to 用 stringArgument 而不是 `as? String ?? 默认值`：模型把 from 写成数字 16 时，
        // 老写法会静默按 decimal 解析 —— 输入 "FF" 于是报"无法按 decimal 解析"，
        // 但真正的问题在参数类型，报错信息把模型引到了错误的方向。
        let fromRead = stringArgument(arguments, "from", default: "decimal")
        guard let fromRaw = fromRead.value else { return fromRead.error ?? "错误: 参数 from 无效" }
        let toRead = stringArgument(arguments, "to", default: "hex")
        guard let toRaw = toRead.value else { return toRead.error ?? "错误: 参数 to 无效" }
        let from = fromRaw.lowercased()
        let to = toRaw.lowercased()
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
        // mode 只在最后那个 else 里兜底，等于"能执行的分支"和"可选值清单"各写一份；
        // 改成前面就校验，错误信息里直接把可选值列全，模型不用猜。
        let modeRead = enumeratedArgument(
            arguments, "mode", label: "转换方向",
            allowed: allowedValues(tool: "color_convert", parameter: "mode", fallback: ["to_hex", "to_rgb"]),
            default: nil)
        guard let mode = modeRead.value else { return modeRead.error ?? "错误: 缺少 mode 参数(to_hex/to_rgb)" }
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
        // enumeratedArgument 已经拦掉了非法 mode，这里只是防御：如果将来 allTools 里的
        // enumValues 被改成包含了本函数没实现的值，也要报错而不是悄悄按 to_hex 处理。
        return "错误: 未实现的 mode「\(mode)」（当前支持 to_hex / to_rgb）"
    }

    // MARK: - 文本排序

    private static func executeSortText(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else { return "错误: 缺少 text 参数" }
        // 三个布尔参数原来都是 `as? Bool ?? false`：模型把 true 写成字符串 "true" 时
        // 会静默变成 false —— 用户要求去重，结果原样返回，模型还回复"已去重"。
        let reverseRead = boolArgument(arguments, "reverse", default: false)
        guard let reverse = reverseRead.value else { return reverseRead.error ?? "错误: 参数 reverse 无效" }
        let ignoreCaseRead = boolArgument(arguments, "ignore_case", default: false)
        guard let ignoreCase = ignoreCaseRead.value else { return ignoreCaseRead.error ?? "错误: 参数 ignore_case 无效" }
        let dedupRead = boolArgument(arguments, "dedup", default: false)
        guard let dedup = dedupRead.value else { return dedupRead.error ?? "错误: 参数 dedup 无效" }
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
        // 空 find 不是"替换不了"，而是"没定义要替换什么"：
        // replacingOccurrences(of: "") 会原样返回文本，工具看起来成功了，其实什么都没做。
        guard !find.isEmpty else {
            return "错误: find 不能为空字符串（否则无法确定要替换的内容）"
        }
        let replace = arguments["replace"] as? String ?? ""
        let regexRead = boolArgument(arguments, "regex", default: false)
        guard let regex = regexRead.value else { return regexRead.error ?? "错误: 参数 regex 无效" }
        let allRead = boolArgument(arguments, "all", default: true)
        guard let all = allRead.value else { return allRead.error ?? "错误: 参数 all 无效" }

        // 返回里必须带替换计数：原来是"找不到就 return text"，用户看到的是一段没有任何说明的
        // 原文，模型据此回复"已替换"。带上计数后，"0 处（未找到匹配）"会让模型和用户立刻
        // 意识到 find 写错了（大小写、全半角、正则语法），而不是以为操作成功。
        func report(_ count: Int, _ result: String, onlyFirst: Bool) -> String {
            if count == 0 {
                return "已替换 0 处（未找到匹配）\n\(result)"
            }
            let suffix = onlyFirst ? "（仅替换了首个匹配）" : ""
            return "已替换 \(count) 处\(suffix)\n\(result)"
        }

        if regex {
            guard let re = try? NSRegularExpression(pattern: find) else {
                return "错误: 无效的正则「\(find)」"
            }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            if all {
                let count = re.numberOfMatches(in: text, options: [], range: range)
                let result = re.stringByReplacingMatches(in: text, range: range, withTemplate: replace)
                return report(count, result, onlyFirst: false)
            }
            guard let match = re.firstMatch(in: text, range: range) else {
                return report(0, text, onlyFirst: true)
            }
            let result = re.replacementString(for: match, in: text, offset: 0, template: replace)
            return report(1, nsText.replacingCharacters(in: match.range, with: result), onlyFirst: true)
        }

        if all {
            // 计数用不重叠匹配（与 replacingOccurrences 的行为一致），
            // find 已在上面保证非空，所以不会出现空匹配导致的无限计数。
            var count = 0
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let r = text.range(of: find, range: searchStart..<text.endIndex) {
                count += 1
                searchStart = r.upperBound
            }
            return report(count, text.replacingOccurrences(of: find, with: replace), onlyFirst: false)
        }
        guard let r = text.range(of: find) else {
            return report(0, text, onlyFirst: true)
        }
        return report(1, text.replacingCharacters(in: r, with: replace), onlyFirst: true)
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
        // style 也走统一的枚举校验：原来 `as? String` 失败时报的是"缺少 style 参数"，
        // 但参数其实传了（只是类型/拼写不对），错误信息把模型引向了错误的方向。
        let styleRead = enumeratedArgument(
            arguments, "style", label: "风格",
            allowed: allowedValues(tool: "case_convert", parameter: "style", fallback: ["snake", "camel", "pascal", "kebab"]),
            default: nil)
        guard let style = styleRead.value else { return styleRead.error ?? "错误: 缺少 style 参数" }
        let words = splitIdentifier(text)
        switch style {
        case "snake":  return words.map { $0.lowercased() }.joined(separator: "_")
        case "kebab":  return words.map { $0.lowercased() }.joined(separator: "-")
        case "camel":  return words.enumerated().map { i, w in i == 0 ? w.lowercased() : w.capitalized }.joined()
        case "pascal": return words.map { $0.capitalized }.joined()
        default: return "错误: 未实现的 style「\(style)」（当前支持 snake/camel/pascal/kebab）"
        }
    }

    // MARK: - 密码生成

    private static func executePasswordGenerate(arguments: [String: Any]) -> String {
        let lengthRead = intArgument(arguments, "length", default: 16)
        guard let rawLength = lengthRead.value else { return lengthRead.error ?? "错误: 参数 length 无效" }
        // 越界仍然是"钳制"而不是报错：范围(4~128)是定义里就写明的，钳制后返回值里会回显
        // 真正使用的长度（"生成密码（长度 N）"），模型看得到实际生效值，不算静默失败。
        // 但"传了字符串 / 传了非数字"必须报错 —— 那种情况模型以为自己指定了长度。
        let length = min(max(rawLength, 4), 128)
        // 四个开关同理：`as? Bool ?? true` 会把 "false"（字符串）当成 true，
        // 也就是用户明确要求"不要符号"，密码里照样出现符号。
        let digitsRead = boolArgument(arguments, "digits", default: true)
        guard let digits = digitsRead.value else { return digitsRead.error ?? "错误: 参数 digits 无效" }
        let symbolsRead = boolArgument(arguments, "symbols", default: true)
        guard let symbols = symbolsRead.value else { return symbolsRead.error ?? "错误: 参数 symbols 无效" }
        let uppercaseRead = boolArgument(arguments, "uppercase", default: true)
        guard let uppercase = uppercaseRead.value else { return uppercaseRead.error ?? "错误: 参数 uppercase 无效" }
        let lowercaseRead = boolArgument(arguments, "lowercase", default: true)
        guard let lowercase = lowercaseRead.value else { return lowercaseRead.error ?? "错误: 参数 lowercase 无效" }
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
        // 原来写的是 `(arguments["value"] as? NSNumber)?.doubleValue`：模型把数值写成字符串
        // （"3.5"，很常见）就一律报"缺少或无效 value 参数"，模型只好换个说法再试一轮。
        // requiredDoubleArgument 会接受数字字符串，只有真不是数字时才报错并回显原值。
        let valueRead = requiredDoubleArgument(arguments, "value")
        guard let valueNum = valueRead.value else { return valueRead.error ?? "错误: 缺少 value 参数" }
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
        let portRead = intArgument(arguments, "port", default: s.sshPort > 0 ? s.sshPort : 22)
        guard let portValue = portRead.value else { return portRead.error ?? "错误: 参数 port 无效" }
        guard (1...65535).contains(portValue) else {
            return "错误: port 需在 1~65535 之间（收到 \(portValue)）"
        }
        let port = Int32(portValue)

        // auth_type 原来用 `if authArg == "key" || ... else 走密码` 兜底：打成 "keys"、"公开密钥"
        // 都会静默按密码认证走，然后报"密码为空" —— 真正的问题（认证方式拼错）被掩盖了，
        // 模型会去补密码而不是改认证方式，白烧好几轮。这里未知取值直接报错。
        // 声明里是 ["password","key"]，但历史实现还兼容 "privatekey"/"pem" 两种写法，
        // 一并保留，避免既有提示词失效。
        let authRead = enumeratedArgument(
            arguments, "auth_type", label: "认证方式",
            allowed: allowedValues(tool: "ssh", parameter: "auth_type", fallback: ["password", "key"])
                + ["privatekey", "pem"],
            default: "")
        guard let authValue = authRead.value else { return authRead.error ?? "错误: 参数 auth_type 无效" }
        let authArg = authValue.lowercased()
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
            // 连接/认证层面的失败：以「错误: 」开头，上层才会把这一步标成 error（红色），
            // 而不是当成一次"成功返回了一句话"的工具调用。
            return "错误: SSH 执行失败（错误码 \(rc)）: \(output)"
        }
        if rc > 0 {
            // 命令本身失败（退出码非 0）：也算失败，同样走错误通道，但把输出完整带上 ——
            // 编译报错、grep 无匹配、diff 有差异这些都有用输出，不能丢。
            // 注意区分措辞：连接是好的，失败的是远程命令，模型据此才知道该改命令而不是改主机。
            return "错误: 远程命令退出码 \(rc)（SSH 连接正常）\n--- 输出 ---\n\(output)"
        }
        return "命令退出码: \(rc)\n--- 输出 ---\n\(output)"
    }

    /// 沙盒 shell 执行(走 ShellSandbox 的受限命令解释器)
    ///
    /// 返回 `ToolExecutionOutcome` 而不是 String：退出码只能在这里拿到（`ShellSandbox`
    /// 就在这一层），带不出去上层就永远填不了 `ToolCall.exitCode`。
    private static func executeShell(arguments: [String: Any]) -> ToolExecutionOutcome {
        guard let command = arguments["command"] as? String, !command.isEmpty else {
            return ToolExecutionOutcome(text: "错误: 缺少 command 参数")
        }
        // 输出截断保护:避免一次性 output 巨大撑爆上下文
        //
        // ⚠️ 只能调**一次**。`ShellSandbox.run` 的实现就是 `runWithExitCode(input).text`，
        // 两个都调等于把用户的命令**执行两遍** —— 而 shell 命令是有副作用的
        //（`rm`、`mv`、`tee` 会真的改磁盘）。这里取得 (文本, 退出码) 的完整形态，
        // 文本与原来的 `run` 逐字相同，模型看到的内容一个字都没变，
        // 变的只是"退出码现在能带出去了"。
        let (raw, exitCode) = ShellSandbox.runWithExitCode(command)

        // 失败前缀**只加在"沙盒不认识这条命令"这一种情况**上，判据与改之前完全一致。
        //
        // 为什么不再顺手把"退出码非 0"也判成失败：退出码非 0 不都是错误。
        // `grep` 没匹配到任何行会返回 1，而它的输出是空文本 —— 加上前缀就成了
        // 「错误: 」（一句没有内容的错误），模型会以为命令本身坏了，进而去重写一条
        // 本来正确的命令。`false`、`cat` 空输入同理。退出码的语义按命令而异，
        // 只有真正执行命令的那一层才分得清，所以这里做的是**如实带出去**，
        // 由界面上单独显示，而不是替模型下一个可能下错的结论。
        if raw.hasPrefix("未知命令:") {
            return ToolExecutionOutcome(text: ToolResultFormat.errorPrefix + raw,
                                        exitCode: exitCode)
        }
        if raw.count > 4000 {
            // 截断只动给模型看的文本，退出码照带 —— 截断是"显示不下"，不是"执行结果有变"。
            return ToolExecutionOutcome(text: String(raw.prefix(4000)) + "\n…(输出过长，已截断)",
                                        exitCode: exitCode)
        }
        return ToolExecutionOutcome(text: raw, exitCode: exitCode)
    }

    // MARK: - v0.3.18 新增工具

    /// 重定向链的守卫：URLSession 默认自己跟随 3xx，**跟随后的目标不会再经过入口校验**。
    /// 这不是理论问题：入口校验放行了 https://example.com/r（公网合法域名），
    /// 只要对面回一个 `302 Location: https://169.254.169.254/latest/meta-data/`，
    /// 请求就会把云元数据（实例凭据）拉回来当成"网页内容"总结给用户 —— 入口的 SSRF 校验等于白做。
    /// URLSession 没有"自动跟随但要回调校验"的开关，只能自己实现 delegate 逐跳放行。
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        /// delegate 回调跑在 URLSession 自己的后台队列上，而结果要在请求结束后由主流程读出来，
        /// 所以这份可变状态必须加锁。盒子显式标成 `@unchecked Sendable`：
        /// URLSessionTaskDelegate 隐含 Sendable，直接在 delegate 类里放可变属性会让 Swift 6
        /// 报 "stored property is mutable" 警告 —— 我们用 NSLock 保证安全，
        /// 需要显式声明才能把这个保证告诉编译器。
        private final class ReasonBox: @unchecked Sendable {
            private let lock = NSLock()
            private var reason: String?

            func record(_ value: String) {
                lock.lock(); defer { lock.unlock() }
                // 只记第一跳：链上可能连续被拦，但给用户看的原因保留最早的那个（最接近原始请求）
                if reason == nil { reason = value }
            }

            var current: String? {
                lock.lock(); defer { lock.unlock() }
                return reason
            }
        }

        private let box = ReasonBox()

        var denialReason: String? { box.current }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let target = request.url else {
                box.record("重定向目标缺少 URL")
                completionHandler(nil)
                return
            }
            if case .deny(let reason) = NetworkGuard.validate(target) {
                box.record(reason)
                // 传 nil = 不跟随这一跳。请求不会继续发出，数据也拿不到。
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    /// HTTP GET 抓取网页/API(仅 https;JSON 自动美化)
    private static func executeHTTPGet(arguments: [String: Any]) async -> String {
        guard let urlString = arguments["url"] as? String, !urlString.isEmpty else {
            return "错误: 缺少 url 参数"
        }
        guard let url = URL(string: urlString) else {
            return "错误: 无法解析 URL「\(urlString)」"
        }
        // 目的地校验（防 SSRF）：https 只是最低要求，127.0.0.1 / 10.x / 169.254.169.254 /
        // localhost / 内网单标签主机名这些"看着像外网其实打内网"的地址必须在这里挡掉。
        // 具体规则和理由见 Services/NetworkGuard.swift。
        if case .deny(let reason) = NetworkGuard.validate(url) {
            return "错误: \(reason)"
        }
        let timeoutRead = doubleArgument(arguments, "timeout", default: 15)
        guard let timeout = timeoutRead.value else { return timeoutRead.error ?? "错误: 参数 timeout 无效" }
        guard timeout > 0, timeout <= 300 else {
            return "错误: timeout 需在 0~300 秒之间（收到 \(timeout)）"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("LumenAI-Agent/0.3 (iOS Sandbox)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        // 用带 delegate 的 session 代替 URLSession.shared：只有这样才能在每一跳 3xx 上重新校验。
        // 用 .ephemeral 配置：不落盘 cookie/缓存（工具请求不该在设备上留下痕迹）。
        let guardDelegate = RedirectGuard()
        let session = URLSession(configuration: .ephemeral, delegate: guardDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            // 被拦下的重定向：URLSession 会把 3xx 响应原样返回，这里必须显式转成失败，
            // 否则下面非 2xx 的分支会把这句"错误: HTTP 302"当成一次普通的 HTTP 失败，
            // 看不出真正原因是"重定向去了不允许的地址"。
            if let reason = guardDelegate.denialReason {
                return "错误: 重定向到不允许的地址，已中止请求（\(reason)）"
            }
            guard let http = response as? HTTPURLResponse else {
                return "错误: 无效响应"
            }
            guard (200...299).contains(http.statusCode) else {
                // 非 2xx 必须走「错误: 」前缀并把状态码原因写清楚：
                // 原来是 "HTTP 404: <正文>"，不以错误开头 → 上层标成成功，
                // 模型于是把 404 页面的 HTML（"页面不存在"、"请开启 JavaScript"）
                // 当作接口返回的内容总结给用户，编出根本不存在的"查询结果"。
                let body = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let phrase = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                let preview = body.isEmpty ? "(响应正文为空)" : String(body.prefix(300))
                return "错误: HTTP \(http.statusCode) \(phrase) — \(preview)"
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
            // 失败也要带「错误: 」前缀（原来只有 "请求失败: "）。
            // 网络错误是**已经重试过一跳以上**的结果（比如重定向一被拒就中止），
            // 上层必须能看出这是失败，否则模型会把 error.localizedDescription
            // 当成抓回来的"网页内容"继续总结。
            return "错误: 请求失败 — \(error.localizedDescription)"
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
        // 原来两个参数捏在一个 guard 里报"缺少 json / path 参数"：模型只知道"少了东西"，
        // 不知道是哪一个（更不知道是"没传"还是"类型错了"），下一轮照样可能漏同样的参数。
        let jsonRead = requiredStringArgument(arguments, "json")
        guard let json = jsonRead.value else { return jsonRead.error ?? "错误: 缺少 json 参数" }
        let pathRead = requiredStringArgument(arguments, "path")
        guard let path = pathRead.value else { return pathRead.error ?? "错误: 缺少 path 参数" }
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
        let offsetRead = intArgument(arguments, "timezone_offset", default: 8)
        guard let offsetHours = offsetRead.value else { return offsetRead.error ?? "错误: 参数 timezone_offset 无效" }
        // 范围检查不能省：原来 TimeZone(secondsFromGMT:) 失败会 `?? UTC` 静默改用 UTC，
        // 但返回文本里仍然写着 "UTC+1000" —— 模型和用户都会以为按 UTC+1000 算过，
        // 实际拿到的是 UTC 时间，差了好几天还看不出来。
        guard (-12...14).contains(offsetHours) else {
            return "错误: timezone_offset 需在 -12~14 小时之间（收到 \(offsetHours)）"
        }
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
        // header 是布尔：模型发 "false"（字符串）时老写法会当成 true，
        // 用户要的是"首行是数据"，结果首行被当成表头画了分隔线，数据少了一行。
        let headerRead = boolArgument(arguments, "header", default: true)
        guard let hasHeader = headerRead.value else { return headerRead.error ?? "错误: 参数 header 无效" }

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
    ///
    /// ⚠️ 把 `todo` 保留在"更多工具"里（默认不启用）。默认清单只有 12 个位置，
    /// 是给本地小模型的核心工具箱；`todo` 偏专用，塞进去会挤掉一个更常用的工具。
    /// 用户可在「设置 → 工具」里显式开启；云端模型走全量工具，自动就有它。
    /// 详细理由写在 `todo` 的工具定义处。
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
