import Foundation

// MARK: - A/B Benchmark（阶段 12）
//
// 目的：**保留现有行为作为 baseline**，用同一批场景对比 baseline 与 optimized，
// 确认"性能优化没有以降低任务成功率为代价"。
//
// 设计取舍：
//   - 这里**不直接依赖**某个具体的 LLMService / 视图层。benchmark 通过注入的
//     `Executor` 闭包执行场景，因此可以在真机上用云端或本地模型跑，也可以在测试里
//     用假实现跑。Runner 只负责编排、计时、聚合与对比。
//   - 场景覆盖用户要求的 10 类：简单问答 / 单 Tool Call / 多 Tool Call /
//     Tool→Result→Tool / 长任务 / Tool error recovery / 多轮对话 / MCP Tool /
//     文件操作 / Web Search。
//   - 成败判定收在 `BenchmarkVerdict`（纯函数，见 `BenchmarkVerdict.swift`）：
//     每个场景声明自己的 `BenchmarkContract`（必须调用哪些工具 / 是否一个都不能少 /
//     禁用哪些 / 是否至少要有一次调用 / 最终答案要满足什么）。
//     baseline 与 optimized 跑**同一份**判定代码，不存在"某一边更容易过"的可能。
//   - 等价的多条路径（列目录既可以 `file_op` 也可以 `shell`）用
//     `requiresAllRequiredTools = false` 表达"命中其一即可"，避免把合理换路误判成失败。

/// benchmark 变体：baseline = 改造前行为，optimized = 全部优化开启。
enum AgentBenchmarkVariant: String, Sendable, CaseIterable {
    case baseline
    case optimized

    /// 该变体对应的优化开关集合（直接传给 `AgentService.run(optimizations:)`）。
    var optimizations: AgentOptimizations {
        switch self {
        case .baseline:  return .baseline
        case .optimized: return .optimized
        }
    }
}

/// 单个 benchmark 场景。
struct AgentBenchmarkScenario: Sendable, Identifiable {
    let id: String
    let category: String
    /// 用户请求（作为该场景的 user 消息）。
    let prompt: String
    /// 本场景的成功判定契约（必须调用的工具、是否全要、禁用工具、
    /// 是否至少一次调用、答案要满足什么）。
    ///
    /// 原来这里是 `expectedAnyTools: [String]`，一个字段同时表达四种互斥语义
    /// （全都要 / 调一个就行 / 不许调工具 / 没指定但得调一个），导致
    /// 「multi_tool 只调了 current_time」也算命中。现在这四种语义各自有名字。
    let contract: BenchmarkContract
    /// 是否要求最终给出非空的、成功的回答（映射进 `contract.answerCheck` 的兜底层）。
    let expectsAnswer: Bool
    /// 该场景的「前情」消息（多轮对话场景用）。
    ///
    /// 为什么需要：像「我刚才让你算的那个数再乘 2」这种请求，只有在**前面真的有一轮**
    /// 用户诉求 + assistant 结果时才是多轮测试；否则模型面对的是一个悬空指代，
    /// 测出来的是"看不懂问题"，而不是"多轮上下文能不能用"。
    let priorTurns: [ChatMessage]

    init(id: String, category: String, prompt: String,
         requiredTools: [String] = [],
         requiresAllRequiredTools: Bool = true,
         optionalTools: [String] = [],
         forbiddenTools: [String] = [],
         requiresTool: Bool = false,
         requiresExternalTool: Bool = false,
         expectsAnswer: Bool = true,
         answerCheck: BenchmarkAnswerCheck? = nil,
         priorTurns: [ChatMessage] = []) {
        self.id = id
        self.category = category
        self.prompt = prompt
        self.expectsAnswer = expectsAnswer
        self.priorTurns = priorTurns

        var c = BenchmarkContract(
            requiredTools: requiredTools,
            requiresAllRequiredTools: requiresAllRequiredTools,
            optionalTools: optionalTools,
            forbiddenTools: forbiddenTools,
            requiresTool: requiresTool,
            requiresExternalTool: requiresExternalTool,
            answerCheck: nil)
        // `expectsAnswer` 是历史字段，保留它的语义：要求回答 = 回答必须非空。
        // 场景自带的 answerCheck 是**额外**要求（要含正确结果），两条同时生效 ——
        // 不能因为写了具体校验就把"没给回答"这条也一起放开。
        if expectsAnswer {
            c.answerCheck = answerCheck.map { .all([.nonEmpty, $0]) } ?? .nonEmpty
        } else {
            c.answerCheck = answerCheck
        }
        self.contract = c
    }
}

/// 一次场景执行的观测样本。
struct AgentBenchmarkSample: Sendable {
    let scenarioID: String
    let variant: AgentBenchmarkVariant
    /// Agent 产出的最终回答。
    let answer: String
    /// 实际发起的工具名（按顺序）。
    let calledTools: [String]
    /// 该 run 的结构化性能指标。
    let metrics: AgentPerformanceMetrics
    /// 每次调用的明细（参数、是否失败、错误码）—— 轨迹指标要用，名字/次数不够。
    let callRecords: [BenchmarkToolCallRecord]

    /// 场景契约（由 Runner 在构造时填入，与样本同进同出，避免样本丢失上下文）。
    var contract: BenchmarkContract = BenchmarkContract()
    /// 本次 run 实际可用的外部工具名（MCP + 插件），由执行器填入。
    /// 只在 `requiresExternalTool` 的场景里参与判定；为空时该场景判 `.notApplicable`。
    var externalTools: [String] = []

    /// 判定结论（纯函数，同一份代码服务两个变体）。
    var verdict: BenchmarkVerdict {
        BenchmarkVerdict.evaluate(contract: contract,
                                  called: calledTools,
                                  answer: answer,
                                  externalTools: Set(externalTools))
    }
    /// 工具侧是否达成（原 `toolHit` 的语义，但现在要求**全部** requiredTools 而非其一）。
    var toolHit: Bool { verdict.toolPassed }
    /// 轨迹指标（重复调用、覆盖率、无效调用……）。
    var trajectory: BenchmarkTrajectory {
        BenchmarkTrajectory.compute(called: calledTools, records: callRecords, contract: contract)
    }
    /// 任务是否成功：工具侧达成 **且** 答案通过。
    var taskSuccess: Bool { verdict.passed }
}

/// 聚合指标。
struct AgentBenchmarkAggregate: Sendable {
    var sampleCount: Int = 0
    /// 参与成功率统计的样本数 = `sampleCount - notApplicableCount`。
    ///
    /// 为什么要分母：环境不满足（一个外部工具都没装却要测 MCP 场景）的样本
    /// 既不能算成功也不能算失败。把它们从两个变体的分母里**同样地**剔除，
    /// 既不会污染成功率，也不存在"靠剔样本把分数做高"的空间（两边剔的是同一批）。
    var applicableCount: Int = 0
    var notApplicableCount: Int = 0
    var toolHitRate: Double = 0
    var taskSuccessRate: Double = 0
    var avgReasoningTokens: Double = 0
    var avgOutputTokens: Double = 0
    var avgToolSchemaTokens: Double = 0
    var avgToolResultTokens: Double = 0
    var avgTTFTMs: Double = 0
    var p50LatencyMs: Double = 0
    var p95LatencyMs: Double = 0
    var avgKVReuseRatio: Double = 0
    var avgExposedToolCount: Double = 0

    // MARK: 轨迹指标（baseline 与 optimized 同口径）
    /// 每个场景实际发起的工具调用次数（均值，含失败的尝试）。
    var avgToolCalls: Double = 0
    /// 实际用过的不同工具数（均值）。
    var avgUniqueToolCount: Double = 0
    /// 完全相同（工具 + 参数）的重复调用总次数。
    var totalDuplicateToolCalls: Int = 0
    /// 「工具不存在」类无效调用（均值）。
    var avgInvalidToolCalls: Double = 0
    /// 执行失败的调用（均值）。
    var avgErrorToolCalls: Double = 0
    /// `requiredTools` 覆盖率均值；没有任何场景声明 requiredTools 时为 nil。
    var avgRequiredCoverage: Double?
    /// 平均每个**成功**任务用了多少次工具；无成功任务时为 nil。
    var toolCallsPerSuccessfulTask: Double?
}

/// baseline vs optimized 对比报告。
struct AgentBenchmarkReport: Sendable {
    let baseline: AgentBenchmarkAggregate
    let optimized: AgentBenchmarkAggregate
    let samples: [AgentBenchmarkSample]

    /// 一行行可读的对比文本（也便于贴进 PR / 日志）。
    var summaryText: String {
        func row(_ name: String, _ b: Double, _ o: Double, _ fmt: String = "%.1f") -> String {
            let delta = o - b
            let pct = b == 0 ? 0 : delta / b * 100
            // 避免 %@ 宽度在不同平台的差异：先各自格式化再拼接。
            let bs = String(format: fmt, b)
            let os = String(format: fmt, o)
            let ds = String(format: fmt, delta)
            let ps = String(format: "%.0f", pct)
            let padded = name.padding(toLength: 24, withPad: " ", startingAt: 0)
            return "\(padded) baseline=\(bs) optimized=\(os) Δ=\(ds) (\(pct >= 0 ? "+" : "")\(ps)%)"
        }
        /// 可能没有数据的指标（均值分母可能为 0）：没有就打 "-"，不要伪装成 0。
        func optionalRow(_ name: String, _ b: Double?, _ o: Double?, _ fmt: String = "%.1f") -> String {
            guard let b, let o else {
                let padded = name.padding(toLength: 24, withPad: " ", startingAt: 0)
                return "\(padded) baseline=- optimized=-"
            }
            return row(name, b, o, fmt)
        }
        var lines: [String] = ["=== Agent A/B Benchmark ==="]
        lines.append("samples              baseline=\(baseline.sampleCount) (n/a \(baseline.notApplicableCount))"
                     + " optimized=\(optimized.sampleCount) (n/a \(optimized.notApplicableCount))")
        lines.append(row("tool hit rate", baseline.toolHitRate, optimized.toolHitRate, "%.3f"))
        lines.append(row("task success rate", baseline.taskSuccessRate, optimized.taskSuccessRate, "%.3f"))
        lines.append(row("avg reasoning tokens", baseline.avgReasoningTokens, optimized.avgReasoningTokens, "%.0f"))
        lines.append(row("avg output tokens", baseline.avgOutputTokens, optimized.avgOutputTokens, "%.0f"))
        lines.append(row("avg tool schema tokens", baseline.avgToolSchemaTokens, optimized.avgToolSchemaTokens, "%.0f"))
        lines.append(row("avg tool result tokens", baseline.avgToolResultTokens, optimized.avgToolResultTokens, "%.0f"))
        lines.append(row("avg TTFT (ms)", baseline.avgTTFTMs, optimized.avgTTFTMs, "%.0f"))
        lines.append(row("P50 latency (ms)", baseline.p50LatencyMs, optimized.p50LatencyMs, "%.0f"))
        lines.append(row("P95 latency (ms)", baseline.p95LatencyMs, optimized.p95LatencyMs, "%.0f"))
        lines.append(row("KV reuse rate", baseline.avgKVReuseRatio, optimized.avgKVReuseRatio, "%.3f"))
        lines.append(row("avg exposed tools", baseline.avgExposedToolCount, optimized.avgExposedToolCount, "%.1f"))
        lines.append("-- trajectory --")
        lines.append(row("actual tool calls", baseline.avgToolCalls, optimized.avgToolCalls, "%.2f"))
        lines.append(row("unique tool count", baseline.avgUniqueToolCount, optimized.avgUniqueToolCount, "%.2f"))
        lines.append(row("duplicate tool calls", Double(baseline.totalDuplicateToolCalls),
                         Double(optimized.totalDuplicateToolCalls), "%.0f"))
        lines.append(row("invalid tool calls", baseline.avgInvalidToolCalls, optimized.avgInvalidToolCalls, "%.2f"))
        lines.append(row("error tool calls", baseline.avgErrorToolCalls, optimized.avgErrorToolCalls, "%.2f"))
        lines.append(optionalRow("required tool coverage", baseline.avgRequiredCoverage,
                                 optimized.avgRequiredCoverage, "%.3f"))
        lines.append(optionalRow("tool calls/success", baseline.toolCallsPerSuccessfulTask,
                                 optimized.toolCallsPerSuccessfulTask, "%.2f"))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Runner

@MainActor
final class AgentBenchmarkRunner {

    /// 场景执行器：跑一个场景、返回样本。
    /// 由调用方决定用云端还是本地模型、以及如何构造 history/settings/tools。
    typealias Executor = @MainActor (AgentBenchmarkScenario, AgentBenchmarkVariant) async -> AgentBenchmarkSample

    /// 跑全部场景 × 两个变体，返回对比报告。
    ///
    /// 顺序执行（不并发）：benchmark 要量的是延迟与 token，并发会互相抢占
    /// GPU / 网络，把测量本身变成噪声。
    static func run(scenarios: [AgentBenchmarkScenario] = defaultScenarios,
                    onProgress: (@MainActor (String) -> Void)? = nil,
                    executor: Executor) async -> AgentBenchmarkReport {
        var samples: [AgentBenchmarkSample] = []
        let total = scenarios.count * AgentBenchmarkVariant.allCases.count
        var done = 0
        for variant in AgentBenchmarkVariant.allCases {
            for scenario in scenarios {
                done += 1
                // 进度回调：一次 benchmark 是 2×场景数 次真实生成，可能跑很久；
                // 没有进度的话用户无法判断"是在跑还是卡住了"。
                onProgress?("\(variant.rawValue) · \(scenario.category)（\(done)/\(total)）")
                var s = await executor(scenario, variant)
                s.contract = scenario.contract
                samples.append(s)
            }
        }
        let baseline = aggregate(samples.filter { $0.variant == .baseline })
        let optimized = aggregate(samples.filter { $0.variant == .optimized })
        return AgentBenchmarkReport(baseline: baseline, optimized: optimized, samples: samples)
    }

    /// 聚合一组样本。
    ///
    /// 成功率 / 命中率的分母只含**环境适用**的样本（`notApplicable` 单独计数），
    /// 两个变体剔除的是同一批样本，因此对比仍然完全对称。
    static func aggregate(_ samples: [AgentBenchmarkSample]) -> AgentBenchmarkAggregate {
        var a = AgentBenchmarkAggregate()
        a.sampleCount = samples.count
        a.notApplicableCount = samples.filter { $0.verdict.isNotApplicable }.count
        let applicable = samples.filter { !$0.verdict.isNotApplicable }
        a.applicableCount = applicable.count
        guard !samples.isEmpty else { return a }

        let n = Double(samples.count)
        a.avgReasoningTokens = Double(samples.reduce(0) { $0 + $1.metrics.reasoningTokens }) / n
        a.avgOutputTokens = Double(samples.reduce(0) { $0 + $1.metrics.outputTokens }) / n
        a.avgToolSchemaTokens = Double(samples.reduce(0) { $0 + $1.metrics.toolSchemaTokens }) / n
        a.avgToolResultTokens = Double(samples.reduce(0) { $0 + $1.metrics.toolResultTokens }) / n
        a.avgTTFTMs = Double(samples.reduce(0) { $0 + $1.metrics.ttftMs }) / n
        a.avgKVReuseRatio = samples.reduce(0) { $0 + $1.metrics.kvCacheReuseRatio } / n
        a.avgExposedToolCount = Double(samples.reduce(0) { $0 + $1.metrics.exposedToolCount }) / n

        let latencies = samples.map { $0.metrics.totalLatencyMs }
        a.p50LatencyMs = percentile(latencies, 0.5)
        a.p95LatencyMs = percentile(latencies, 0.95)

        // 命中率 / 成功率：分母只算适用样本（不适用的样本没有"跑成没跑成"可言）。
        if !applicable.isEmpty {
            let an = Double(applicable.count)
            a.toolHitRate = Double(applicable.filter(\.toolHit).count) / an
            a.taskSuccessRate = Double(applicable.filter(\.taskSuccess).count) / an
        }

        // 轨迹指标：**全部样本**都参与（它们只是事实计数，与成败判定无关）。
        let trajectories = samples.map { $0.trajectory }
        a.avgToolCalls = trajectories.reduce(0) { $0 + Double($1.toolCallCount) } / n
        a.avgUniqueToolCount = trajectories.reduce(0) { $0 + Double($1.uniqueToolCount) } / n
        a.totalDuplicateToolCalls = trajectories.reduce(0) { $0 + $1.duplicateCallCount }
        a.avgInvalidToolCalls = trajectories.reduce(0) { $0 + Double($1.invalidCallCount) } / n
        a.avgErrorToolCalls = trajectories.reduce(0) { $0 + Double($1.errorCallCount) } / n

        let coverages = trajectories.compactMap(\.requiredCoverage)
        a.avgRequiredCoverage = coverages.isEmpty
            ? nil
            : coverages.reduce(0, +) / Double(coverages.count)

        let successful = applicable.filter(\.taskSuccess)
        a.toolCallsPerSuccessfulTask = successful.isEmpty
            ? nil
            : Double(successful.reduce(0) { $0 + $1.trajectory.toolCallCount }) / Double(successful.count)
        return a
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }

    // MARK: - 默认场景（覆盖用户要求的 10 类）

    // 场景契约的三条原则（写死在这里，避免后来者把判定改松）：
    //  1. 多工具任务必须声明 `requiresAllRequiredTools: true` —— 调一半不算完成；
    //  2. 有唯一预期结果的场景必须给 answerCheck —— 只看"调没调对工具"会把
    //     「调了 calculator 但算错」算成成功；
    //  3. 同一目的有多条等价路径（列目录、联网）才允许 `requiresAllRequiredTools: false`，
    //     这是原来 expectedAnyTools「命中其一」的正确留下的语义，不能扩大到别的场景。
    static let defaultScenarios: [AgentBenchmarkScenario] = [
        .init(id: "simple_qa", category: "简单问答",
              prompt: "用一句话解释什么是 HTTP 状态码。",
              requiredTools: [], expectsAnswer: true),
        .init(id: "single_tool", category: "单 Tool Call",
              prompt: "帮我算一下 (23*17+5)/4 等于多少。",
              requiredTools: ["calculator"],
              answerCheck: .contains("99")),          // (391+5)/4 = 99
        .init(id: "multi_tool", category: "多 Tool Call",
              prompt: "先获取当前时间，再生成一个 UUID，把两个结果一起告诉我。",
              requiredTools: ["current_time", "generate_uuid"],
              answerCheck: .all([
                .regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
                .regex("[0-9]{1,2}:[0-9]{2}"),
              ])),
        .init(id: "chained_tool", category: "Tool→Result→Tool",
              prompt: "先算 128*64 的结果，再用这个结果除以 8，告诉我最终的数。",
              requiredTools: ["calculator"],
              answerCheck: .contains("1024")),        // 8192 / 8 = 1024
        .init(id: "long_task", category: "长任务",
              prompt: "请分步骤完成：1) 统计下面这段文字的字数；2) 把它转成大写；"
                    + "3) 给出一句总结。文字：the quick brown fox jumps over the lazy dog",
              requiredTools: ["word_count", "text_transform", "text_summary"],
              // 大写结果必须出现在答案里（证明转换真的落到输出）；字数是 9 词 / 44 字符，
              // 模型两种口径都算对，所以两个候选值都接受 —— 这一条刻意保持宽松，
              // 强证据是上面的三工具全覆盖 + 大写串命中。
              answerCheck: .all([
                .contains("THE QUICK BROWN FOX"),
                .containsAny(["9", "44"]),
              ])),
        .init(id: "error_recovery", category: "Tool error recovery",
              prompt: "读取名为 definitely-not-exist-12345.txt 的文件内容。",
              requiredTools: ["file_op"],
              // 正确结果是「文件不存在」这类如实汇报；编造内容才是真失败。
              answerCheck: .containsAny([
                "不存在", "找不到", "未找到", "没有找到", "无法读取", "无法打开",
                "not found", "not exist", "does not exist", "no such file",
                "failed", "失败", "错误", "error", "cannot", "unable",
              ])),
        .init(id: "multi_turn", category: "多轮对话",
              prompt: "我刚才让你算的那个数，再乘以 2 是多少？",
              requiredTools: ["calculator"],
              answerCheck: .contains("288"),          // 144 * 2 = 288
              priorTurns: [
                ChatMessage(role: .user, content: "帮我算一下 12*12 等于多少。"),
                ChatMessage(role: .assistant, content: "144。"),
              ]),
        // 语义是「用你当前**真的有**的外部工具做一件事」，不是「不许调工具」，
        // 也不是「必须叫某个写死的插件名」。因此用 requiresTool + requiresExternalTool：
        // 外部宇宙为空 → 判 notApplicable（不算成功也不算失败，单独计数）。
        .init(id: "mcp_tool", category: "MCP Tool",
              prompt: "用你当前可用的外部（MCP/插件）工具帮我完成一个简单操作。",
              requiresTool: true,
              requiresExternalTool: true,
              expectsAnswer: true),
        // 列目录有两条等价路径（file_op / shell），允许其一 —— 这是原来「命中其一」
        // 语义唯一该保留的地方。
        .init(id: "file_ops", category: "文件操作",
              prompt: "在当前工作目录下列出所有文件。",
              requiredTools: ["file_op", "shell"],
              requiresAllRequiredTools: false),
        .init(id: "web_search", category: "Web Search",
              prompt: "搜索一下今天有什么科技新闻。",
              requiredTools: ["web_search", "http_get"],
              requiresAllRequiredTools: false,
              answerCheck: .containsAny(["http", "新闻", "news", "报道", "科技"])),
    ]
}

// MARK: - 便捷执行器（真机使用）
extension AgentBenchmarkRunner {

    /// 用真实 `AgentService.run` 跑场景的执行器。
    ///
    /// 调用方负责提供 settings / 工具目录 / 初始 history / LLMService —— 这些依赖
    /// 视图层与用户设置，benchmark 不替它们做决定，只负责"把 variant 映射成
    /// `optimizations` 并回收结构化指标"，保证 baseline 与 optimized 只有**一个变量**不同。
    static func agentServiceExecutor(
        settings: ModelSettings,
        tools: [AgentToolDefinition],
        /// 外部（MCP + 已装插件）工具名。`mcp_tool` 场景用它判断"是否真的调了外部工具"：
        /// 一个都没装时该场景判 `.notApplicable`，而不是把环境缺失误算成 agent 失败。
        externalToolNames: [String] = [],
        /// 初始 history 构造器。传 nil 用默认实现
        /// （system(settings.systemPrompt) + user(prompt)，与 ChatView 发起 agent 时一致）。
        historyBuilder: (@MainActor (AgentBenchmarkScenario) -> [ChatMessage])? = nil,
        llm: @escaping @MainActor () -> LLMService
    ) -> Executor {
        let buildHistory: @MainActor (AgentBenchmarkScenario) -> [ChatMessage]
        if let historyBuilder = historyBuilder {
            buildHistory = historyBuilder
        } else {
            buildHistory = { scenario in
                var h: [ChatMessage] = []
                if !settings.systemPrompt.isEmpty {
                    h.append(ChatMessage(role: .system, content: settings.systemPrompt))
                }
                h.append(contentsOf: scenario.priorTurns)
                h.append(ChatMessage(role: .user, content: scenario.prompt))
                return h
            }
        }
        return { scenario, variant in
            let service = AgentService()
            // 无头桥（benchmark 专用）：要量的是「工具链路 + 生成」，不是「用户点不点同意」。
            // 生产里 requiresApproval 的工具会阻塞等弹窗；benchmark 若不传桥，
            // AgentService 对这类调用会**默认拒绝** —— web_search / shell 这些场景将全部失败，
            // 命中率与延迟随之失真。所以这里统一自动放行（本 run 内总是允许），
            // 其余 UI 回调都是 no-op（不渲染气泡，也不影响控制流）。
            let bridge = AgentService.AgentDisplayBridge(
                beginIteration: { UUID() },
                appendToken: { _, _ in },
                attachToolCall: { _, _ in },
                endIteration: { _ in },
                requestApproval: { _, _ in .alwaysForSession }
            )
            let (content, calls) = await service.run(
                history: buildHistory(scenario),
                settings: settings,
                toolsEnabledTools: tools,
                llm: llm(),
                bridge: bridge,
                optimizations: variant.optimizations)
            // 调用明细：判定与轨迹指标只吃这份纯数据（不依赖 ChatMessage 类型）。
            let records = calls.map {
                BenchmarkToolCallRecord(name: $0.name,
                                        arguments: $0.arguments,
                                        isError: $0.status == .error,
                                        errorCode: $0.errorCode)
            }
            return AgentBenchmarkSample(
                scenarioID: scenario.id,
                variant: variant,
                answer: content,
                calledTools: calls.map(\.name),
                metrics: service.lastMetrics ?? AgentPerformanceMetrics(),
                callRecords: records,
                externalTools: externalToolNames)
        }
    }
}