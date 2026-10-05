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
//   - 命中率判定用 `expectedAnyTools`（命中其一即算命中），避免把"换了一条合理的路"
//     误判成失败 —— 我们关心的是**能力可用**，不是唯一正确解。

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
    /// 期望被调用的工具（命中任一即算命中）；空数组表示"预期不调用工具"。
    let expectedAnyTools: [String]
    /// 是否要求最终给出非空的、成功的回答。
    let expectsAnswer: Bool
    /// 该场景的「前情」消息（多轮对话场景用）。
    ///
    /// 为什么需要：像「我刚才让你算的那个数再乘 2」这种请求，只有在**前面真的有一轮**
    /// 用户诉求 + assistant 结果时才是多轮测试；否则模型面对的是一个悬空指代，
    /// 测出来的是"看不懂问题"，而不是"多轮上下文能不能用"。
    let priorTurns: [ChatMessage]

    init(id: String, category: String, prompt: String,
         expectedAnyTools: [String] = [], expectsAnswer: Bool = true,
         priorTurns: [ChatMessage] = []) {
        self.id = id
        self.category = category
        self.prompt = prompt
        self.expectedAnyTools = expectedAnyTools
        self.expectsAnswer = expectsAnswer
        self.priorTurns = priorTurns
    }
}

/// 一次场景执行的观测样本。
struct AgentBenchmarkSample: Sendable {
    let scenarioID: String
    let variant: AgentBenchmarkVariant
    /// Agent 产出的最终回答。
    let answer: String
    /// 实际发起的工具调用名（按顺序）。
    let calledTools: [String]
    /// 该 run 的结构化性能指标。
    let metrics: AgentPerformanceMetrics

    /// 工具命中：场景期望为空时，只要没乱调工具就算命中。
    var toolHit: Bool {
        let expected = scenarioExpectedTools
        if expected.isEmpty { return calledTools.isEmpty }
        return !Set(expected).isDisjoint(with: Set(calledTools))
    }
    /// 由 Runner 在构造时填入（把场景期望带进来，避免样本丢失上下文）。
    var scenarioExpectedTools: [String] = []
    /// 任务是否成功：给出回答，且工具命中。
    var taskSuccess: Bool {
        (answer.isEmpty == false) && toolHit
    }
}

/// 聚合指标。
struct AgentBenchmarkAggregate: Sendable {
    var sampleCount: Int = 0
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
        var lines: [String] = ["=== Agent A/B Benchmark ==="]
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
                s.scenarioExpectedTools = scenario.expectedAnyTools
                samples.append(s)
            }
        }
        let baseline = aggregate(samples.filter { $0.variant == .baseline })
        let optimized = aggregate(samples.filter { $0.variant == .optimized })
        return AgentBenchmarkReport(baseline: baseline, optimized: optimized, samples: samples)
    }

    /// 聚合一组样本。
    static func aggregate(_ samples: [AgentBenchmarkSample]) -> AgentBenchmarkAggregate {
        var a = AgentBenchmarkAggregate()
        a.sampleCount = samples.count
        guard !samples.isEmpty else { return a }

        let n = Double(samples.count)
        a.toolHitRate = Double(samples.filter(\.toolHit).count) / n
        a.taskSuccessRate = Double(samples.filter(\.taskSuccess).count) / n
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

    static let defaultScenarios: [AgentBenchmarkScenario] = [
        .init(id: "simple_qa", category: "简单问答",
              prompt: "用一句话解释什么是 HTTP 状态码。",
              expectedAnyTools: [], expectsAnswer: true),
        .init(id: "single_tool", category: "单 Tool Call",
              prompt: "帮我算一下 (23*17+5)/4 等于多少。",
              expectedAnyTools: ["calculator"]),
        .init(id: "multi_tool", category: "多 Tool Call",
              prompt: "先获取当前时间，再生成一个 UUID，把两个结果一起告诉我。",
              expectedAnyTools: ["current_time", "generate_uuid"]),
        .init(id: "chained_tool", category: "Tool→Result→Tool",
              prompt: "先算 128*64 的结果，再用这个结果除以 8，告诉我最终的数。",
              expectedAnyTools: ["calculator"]),
        .init(id: "long_task", category: "长任务",
              prompt: "请分步骤完成：1) 统计下面这段文字的字数；2) 把它转成大写；"
                    + "3) 给出一句总结。文字：the quick brown fox jumps over the lazy dog",
              expectedAnyTools: ["word_count", "text_transform", "text_summary"]),
        .init(id: "error_recovery", category: "Tool error recovery",
              prompt: "读取名为 definitely-not-exist-12345.txt 的文件内容。",
              expectedAnyTools: ["file_op"]),
        .init(id: "multi_turn", category: "多轮对话",
              prompt: "我刚才让你算的那个数，再乘以 2 是多少？",
              expectedAnyTools: ["calculator"],
              priorTurns: [
                ChatMessage(role: .user, content: "帮我算一下 12*12 等于多少。"),
                ChatMessage(role: .assistant, content: "144。"),
              ]),
        .init(id: "mcp_tool", category: "MCP Tool",
              prompt: "用你当前可用的外部（MCP/插件）工具帮我完成一个简单操作。",
              expectedAnyTools: [], expectsAnswer: true),
        .init(id: "file_ops", category: "文件操作",
              prompt: "在当前工作目录下列出所有文件。",
              expectedAnyTools: ["file_op", "shell"]),
        .init(id: "web_search", category: "Web Search",
              prompt: "搜索一下今天有什么科技新闻。",
              expectedAnyTools: ["web_search", "http_get"]),
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
            return AgentBenchmarkSample(
                scenarioID: scenario.id,
                variant: variant,
                answer: content,
                calledTools: calls.map(\.name),
                metrics: service.lastMetrics ?? AgentPerformanceMetrics())
        }
    }
}