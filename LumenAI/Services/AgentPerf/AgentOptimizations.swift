import Foundation

// MARK: - 优化开关集合（用于 A/B benchmark 与快速回滚）
//
// 为什么需要它：阶段 12 要求"保留现有行为作为 baseline"。但优化点分散在
// reasoning 门控、工具路由、结果压缩、历史压缩四处 —— 如果每个开关都要在调用侧
// 拼装，baseline 就不可复现。把它们收进一个值类型：
//   · `.optimized` = 全部开启（默认）；
//   · `.baseline`  = 全部关闭（等价于改造前行为）。
// 这样 benchmark 只切换一个参数，出问题时也能一行回滚到 baseline。
//
// 刻意**不**包含采样参数（temperature / top-p / ctx / gpu layers）：阶段 11 明确
// 要求不轻易动推理参数，它们也不在本结构管辖范围内。
struct AgentOptimizations: Sendable {

    /// 阶段 2-4：reasoning 预算 / 门控 / 重复检测 + 早停。
    var reasoningControl: Bool = true

    /// 阶段 5-7：工具路由 + compact schema（内含开关）。
    var toolRouting: ToolRoutingConfig = ToolRoutingConfig()

    /// 阶段 8：工具结果压缩（含按类型分流、错误优先保留）。
    var resultReduction: Bool = true

    /// 阶段 9：旧工具交互压缩成 Task State。
    var historyCompaction: Bool = true

    /// 单段思考的 token 预算上限（渐进阶梯最高档）。默认 2048 = 原行为；
    /// 设置页「思考预算」调低后阶梯整体收紧，思考更短、更快进入动作。
    var thinkBudgetMax: Int = 2048

    init() {}

    init(reasoningControl: Bool,
         toolRouting: ToolRoutingConfig,
         resultReduction: Bool,
         historyCompaction: Bool,
         thinkBudgetMax: Int = 2048) {
        self.reasoningControl = reasoningControl
        self.toolRouting = toolRouting
        self.resultReduction = resultReduction
        self.historyCompaction = historyCompaction
        self.thinkBudgetMax = thinkBudgetMax
    }

    /// 从用户设置构造（设置页「Agent 智能体」卡片的开关即由此生效）。
    /// 每一项都带 `?? 兼容默认` —— 旧存档缺字段时解码已给了默认值，这里再兜一层，
    /// 保证任何一条设置被污染成异常值时整体仍是"线上默认行为"而不是崩/关光。
    static func from(settings: ModelSettings) -> AgentOptimizations {
        var routing = ToolRoutingConfig()
        routing.enabled = settings.agentToolRouting
        // 关掉路由时 compact schema 也一并关掉 —— 它们是同一组优化，
        // 只留 compact 会让 baseline 对比失去意义（用户开关的语义是"回到旧行为"）。
        routing.useCompactSchema = settings.agentToolRouting
        let budget = (64...8192).contains(settings.agentThinkBudgetTokens)
            ? settings.agentThinkBudgetTokens : 2048
        return AgentOptimizations(
            reasoningControl: settings.agentReasoningControl,
            toolRouting: routing,
            resultReduction: settings.agentResultReduction,
            historyCompaction: settings.agentHistoryCompaction,
            thinkBudgetMax: budget)
    }

    /// 全部开启（线上默认）。
    static let optimized = AgentOptimizations()

    /// 全部关闭（= 改造前行为，用于 benchmark baseline 与紧急回滚）。
    static let baseline: AgentOptimizations = {
        var routing = ToolRoutingConfig()
        routing.enabled = false
        routing.useCompactSchema = false
        return AgentOptimizations(
            reasoningControl: false,
            toolRouting: routing,
            resultReduction: false,
            historyCompaction: false)
    }()
}