import Foundation

// MARK: - Skill 技能模型
//
// 技能 = 用户可复用的提示词模板 + 参数 + 可选的工具调用链
// 与 Plugin(JS 插件)的区别：
// - Plugin: 模型生成的代码，运行在 JavaScriptCore 沙箱，扩展工具能力
// - Skill: 用户创建/管理的模板，面向人类使用，简化重复性提示词输入
// - 两者互补：Skill 可在模板中引用 Plugin 提供的工具

/// 技能分类
enum SkillCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case coding = "coding"
    case writing = "writing"
    case analysis = "analysis"
    case automation = "automation"
    case learning = "learning"
    case creative = "creative"
    case productivity = "productivity"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coding: return "编程开发"
        case .writing: return "写作创作"
        case .analysis: return "分析研究"
        case .automation: return "自动化"
        case .learning: return "学习教育"
        case .creative: return "创意设计"
        case .productivity: return "效率工具"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .writing: return "pencil.and.outline"
        case .analysis: return "chart.bar.doc.horizontal"
        case .automation: return "gearshape.2.fill"
        case .learning: return "graduationcap.fill"
        case .creative: return "paintbrush.fill"
        case .productivity: return "timer"
        case .other: return "square.grid.2x2"
        }
    }

    var color: String {
        switch self {
        case .coding: return "blue"
        case .writing: return "green"
        case .analysis: return "orange"
        case .automation: return "purple"
        case .learning: return "indigo"
        case .creative: return "pink"
        case .productivity: return "teal"
        case .other: return "gray"
        }
    }
}

/// 技能参数定义
struct SkillParameter: Codable, Sendable, Identifiable, Hashable {
    let id: String
    var name: String
    var label: String
    var type: ParameterType
    var description: String
    var defaultValue: String?
    var isRequired: Bool
    var enumValues: [String]?

    init(
        id: String = UUID().uuidString,
        name: String,
        label: String,
        type: ParameterType = .string,
        description: String = "",
        defaultValue: String? = nil,
        isRequired: Bool = true,
        enumValues: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.type = type
        self.description = description
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.enumValues = enumValues
    }
}

enum ParameterType: String, Codable, Sendable, CaseIterable {
    case string = "string"
    case number = "number"
    case boolean = "boolean"
    case select = "select"
    case multiline = "multiline"
    case json = "json"

    var displayName: String {
        switch self {
        case .string: return "文本"
        case .number: return "数字"
        case .boolean: return "开关"
        case .select: return "下拉选择"
        case .multiline: return "多行文本"
        case .json: return "JSON"
        }
    }
}

/// 技能步骤（用于多步工作流）
struct SkillStep: Codable, Sendable, Identifiable, Hashable {
    let id: String
    var name: String
    var type: StepType
    var promptTemplate: String
    var parameters: [SkillParameter]
    var toolCalls: [String]?  // 预期调用的工具名
    var condition: String?     // 条件表达式（可选）
    var outputVariable: String? // 将结果存入的变量名

    init(
        id: String = UUID().uuidString,
        name: String,
        type: StepType = .prompt,
        promptTemplate: String,
        parameters: [SkillParameter] = [],
        toolCalls: [String]? = nil,
        condition: String? = nil,
        outputVariable: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.promptTemplate = promptTemplate
        self.parameters = parameters
        self.toolCalls = toolCalls
        self.condition = condition
        self.outputVariable = outputVariable
    }
}

enum StepType: String, Codable, Sendable, CaseIterable {
    case prompt = "prompt"
    case tool = "tool"
    case conditional = "conditional"
    case loop = "loop"

    var displayName: String {
        switch self {
        case .prompt: return "提示词"
        case .tool: return "工具调用"
        case .conditional: return "条件分支"
        case .loop: return "循环"
        }
    }
}

/// 技能清单（类似 PluginManifest，但面向用户技能）
struct SkillManifest: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var category: SkillCategory
    var tags: [String]
    var icon: String? // SF Symbol 名称
    var color: String? // 十六进制颜色

    // 核心内容
    var promptTemplate: String // 主提示词模板，支持 {{param}} 变量替换
    var parameters: [SkillParameter] // 模板参数
    var steps: [SkillStep]? // 可选：多步工作流

    // 元数据
    var minAppVersion: String?
    var isBuiltIn: Bool
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var useCount: Int
    var lastUsedAt: Date?

    // 远程设置界面（类似 Plugin 的 RemoteUI）
    var settingsUI: [RemoteUIGroup]?

    init(
        id: String = UUID().uuidString,
        name: String,
        version: String = "1.0.0",
        description: String,
        author: String? = nil,
        category: SkillCategory = .other,
        tags: [String] = [],
        icon: String? = nil,
        color: String? = nil,
        promptTemplate: String,
        parameters: [SkillParameter] = [],
        steps: [SkillStep]? = nil,
        minAppVersion: String? = nil,
        isBuiltIn: Bool = false,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        settingsUI: [RemoteUIGroup]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.category = category
        self.tags = tags
        self.icon = icon
        self.color = color
        self.promptTemplate = promptTemplate
        self.parameters = parameters
        self.steps = steps
        self.minAppVersion = minAppVersion
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.settingsUI = settingsUI
    }

    /// 生成最终提示词（填充参数）
    func renderPrompt(with values: [String: String]) -> String {
        var result = promptTemplate
        for param in parameters {
            let key = "{{\(param.name)}}"
            let value = values[param.name] ?? param.defaultValue ?? ""
            result = result.replacingOccurrences(of: key, with: value)
        }
        return result
    }

    /// 验证参数是否完整
    func validateParameters(_ values: [String: String]) -> [String] {
        var missing: [String] = []
        for param in parameters where param.isRequired {
            if values[param.name] == nil, param.defaultValue == nil {
                missing.append(param.label.isEmpty ? param.name : param.label)
            }
        }
        return missing
    }
}

/// 远程技能索引条目（技能市场）
struct SkillIndexEntry: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var category: SkillCategory
    var tags: [String]
    var icon: String?
    var color: String?
    var minAppVersion: String?
    var gray: ModuleGrayPolicy?
    var sha256: String?
    var files: SkillFiles

    struct SkillFiles: Codable, Sendable {
        var manifest: String
        // skills 不需要单独的 tools.js，manifest 包含所有内容
    }

    init(
        id: String,
        name: String,
        version: String,
        description: String,
        author: String? = nil,
        category: SkillCategory = .other,
        tags: [String] = [],
        icon: String? = nil,
        color: String? = nil,
        minAppVersion: String? = nil,
        gray: ModuleGrayPolicy? = nil,
        sha256: String? = nil,
        files: SkillFiles
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.category = category
        self.tags = tags
        self.icon = icon
        self.color = color
        self.minAppVersion = minAppVersion
        self.gray = gray
        self.sha256 = sha256
        self.files = files
    }
}

/// 技能更新状态
struct SkillUpdate: Identifiable, Sendable {
    let entry: SkillIndexEntry
    var id: String { entry.id }
    let installedVersion: String?
    var hasUpdate: Bool { installedVersion != entry.version }
}

/// 技能导出包格式
struct SkillBundle: Codable, Sendable {
    var manifest: SkillManifest
    var exportedAt: Date
    var exportedFrom: String // "LumenAI"

    init(manifest: SkillManifest, exportedFrom: String = "LumenAI") {
        self.manifest = manifest
        self.exportedAt = Date()
        self.exportedFrom = exportedFrom
    }
}

/// 远程技能索引（技能市场）
struct SkillIndex: Codable, Sendable {
    var skills: [SkillIndexEntry]
}

// MARK: - 内置技能扩展

extension SkillManifest {
    /// 内置技能列表（随 App 发布）
    static func builtInSkills() -> [SkillManifest] {
        [
            SkillManifest(
                id: "quick_summary",
                name: "快速总结",
                version: "1.0.0",
                description: "一键生成文本摘要，支持多语言和多种长度",
                author: "LumenAI",
                category: .analysis,
                tags: ["总结", "摘要", "快速"],
                icon: "doc.text.fill",
                color: "#007AFF",
                promptTemplate: "请将以下文本总结为{{summaryLength}}长度的{{style}}风格摘要：\n\n{{text}}\n\n主要要点：",
                parameters: [
                    SkillParameter(name: "text", label: "待总结文本", type: .multiline, description: "需要总结的文本内容", isRequired: true),
                    SkillParameter(name: "summaryLength", label: "摘要长度", type: .select, description: "摘要的详细程度", defaultValue: "简短", isRequired: true, enumValues: ["简短", "中等", "详细"]),
                    SkillParameter(name: "style", label: "总结风格", type: .select, description: "摘要的表达风格", defaultValue: "客观", isRequired: false, enumValues: ["客观", "要点式", "叙述性", "正式"])
                ],
                isBuiltIn: true,
                isEnabled: true
            ),
            SkillManifest(
                id: "translation_assist",
                name: "翻译助手",
                version: "1.0.0",
                description: "多语言翻译，保留原文风格和格式",
                author: "LumenAI",
                category: .productivity,
                tags: ["翻译", "语言", "多语言"],
                icon: "globe",
                color: "#34C759",
                promptTemplate: "请将以下{{sourceLanguage}}文本翻译为{{targetLanguage}}，保持原文风格和格式：\n\n{{text}}\n\n要求：\n- 准确传达原意\n- 自然流畅的表达\n- 保留原文的格式和标点",
                parameters: [
                    SkillParameter(name: "text", label: "待翻译文本", type: .multiline, description: "需要翻译的文本", isRequired: true),
                    SkillParameter(name: "sourceLanguage", label: "源语言", type: .string, description: "原文语言", defaultValue: "中文", isRequired: true),
                    SkillParameter(name: "targetLanguage", label: "目标语言", type: .string, description: "翻译目标语言", defaultValue: "英文", isRequired: true)
                ],
                isBuiltIn: true,
                isEnabled: true
            ),
            SkillManifest(
                id: "email_draft",
                name: "邮件起草",
                version: "1.0.0",
                description: "专业邮件模板生成，适配不同商务场景",
                author: "LumenAI",
                category: .writing,
                tags: ["邮件", "商务", "沟通"],
                icon: "envelope.fill",
                color: "#FF9500",
                promptTemplate: "请帮我起草一封{{emailType}}邮件：\n\n收件人：{{recipient}}\n主题：{{subject}}\n\n主要内容：\n{{mainContent}}\n\n语气要求：{{tone}}\n\n请确保邮件格式规范、语言得体、重点突出。",
                parameters: [
                    SkillParameter(name: "emailType", label: "邮件类型", type: .select, description: "邮件的用途", defaultValue: "商务沟通", isRequired: true, enumValues: ["商务沟通", "邀请函", "感谢信", "道歉信", "合作提案", "跟进邮件"]),
                    SkillParameter(name: "recipient", label: "收件人", type: .string, description: "接收邮件的对象或部门", defaultValue: "", isRequired: true),
                    SkillParameter(name: "subject", label: "邮件主题", type: .string, description: "邮件标题", isRequired: true),
                    SkillParameter(name: "mainContent", label: "主要内容", type: .multiline, description: "邮件需要表达的核心信息", isRequired: true),
                    SkillParameter(name: "tone", label: "语气", type: .select, description: "邮件的语气风格", defaultValue: "正式", isRequired: false, enumValues: ["正式", "友好", "专业", "亲切"])
                ],
                isBuiltIn: true,
                isEnabled: true
            ),
            SkillManifest(
                id: "code_explainer",
                name: "代码解释器",
                version: "1.0.0",
                description: "详细解释代码逻辑、工作原理和最佳实践",
                author: "LumenAI",
                category: .coding,
                tags: ["代码", "学习", "理解"],
                icon: "chevron.left.forwardslash.chevron.right",
                color: "#5856D6",
                promptTemplate: "请详细解释以下{{language}}代码：\n\n```{{language}}\n{{code}}\n```\n\n请说明：\n1. 代码的整体功能和用途\n2. 逐行/逐段的关键逻辑说明\n3. 使用的设计模式或技术\n4. 潜在的问题或改进建议\n5. 应用场景和注意事项",
                parameters: [
                    SkillParameter(name: "language", label: "编程语言", type: .string, description: "代码使用的编程语言", defaultValue: "Swift", isRequired: true),
                    SkillParameter(name: "code", label: "代码内容", type: .multiline, description: "需要解释的代码", isRequired: true)
                ],
                isBuiltIn: true,
                isEnabled: true
            ),
            SkillManifest(
                id: "brainstorm_ideas",
                name: "头脑风暴",
                version: "1.0.0",
                description: "快速生成创意想法，突破思维局限",
                author: "LumenAI",
                category: .creative,
                tags: ["创意", " brainstorming", "想法"],
                icon: "lightbulb.fill",
                color: "#FF2D55",
                promptTemplate: "请为以下主题进行头脑风暴，生成至少{{ideaCount}}个创新想法：\n\n主题：{{topic}}\n\n背景信息：\n{{background}}\n\n目标受众：{{audience}}\n\n限制条件：\n{{constraints}}\n\n请确保想法：\n- 具有创新性和可行性\n- 符合目标受众需求\n- 在限制条件下可实现\n- 有明确的价值主张",
                parameters: [
                    SkillParameter(name: "topic", label: "主题", type: .string, description: "头脑风暴的核心主题", isRequired: true),
                    SkillParameter(name: "background", label: "背景信息", type: .multiline, description: "相关背景和上下文", isRequired: false),
                    SkillParameter(name: "audience", label: "目标受众", type: .string, description: "想法面向的群体", defaultValue: "通用", isRequired: false),
                    SkillParameter(name: "constraints", label: "限制条件", type: .multiline, description: "需要考虑的限制和约束", isRequired: false),
                    SkillParameter(name: "ideaCount", label: "想法数量", type: .number, description: "期望生成的想法数量", defaultValue: "10", isRequired: false)
                ],
                isBuiltIn: true,
                isEnabled: true
            )
        ]
    }
}