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

    init() {}

    init(reasoningControl: Bool,
         toolRouting: ToolRoutingConfig,
         resultReduction: Bool,
         historyCompaction: Bool) {
        self.reasoningControl = reasoningControl
        self.toolRouting = toolRouting
        self.resultReduction = resultReduction
        self.historyCompaction = historyCompaction
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