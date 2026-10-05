import Foundation

// MARK: - Agent 性能观测（阶段 1）
//
// 目标：**在不改变任何行为**的前提下，把 Agent 主循环每一轮的关键成本量化出来，
// 作为后续所有优化（reasoning 预算、工具路由、结果压缩、KV 复用）的 baseline。
//
// 为什么先做观测：当前第一问题不是 Tool 命中率（约 99.6%），而是每轮 reasoning 过长、
// 跨轮重复、以及工具定义/工具结果吃掉大量 context。没有结构化指标就无法判断
// 优化是否真的有效、也不知道收益来自哪一项。日志能打印，但无法聚合成 P50/P95、
// 无法做 A/B 对比 —— 所以这里给出的是**结构化数据**，不是字符串。

/// 本地 llama.cpp 前缀缓存（KV cache）一次 prompt 解码的复用统计。
///
/// 只在本地模式有真实值：云端 Provider 的 KV cache 由服务端管理，客户端拿不到。
struct KVCacheReuseStats: Sendable, Equatable {
    /// 本轮 prompt 中命中上一轮前缀、**未重新解码**的 token 数。
    let reusedTokens: Int
    /// 本轮 prompt 的 token 总数。
    let totalPromptTokens: Int

    var reused: Bool { reusedTokens > 0 }

    /// 复用率 0...1。total 为 0 时返回 0。
    var reuseRatio: Double {
        guard totalPromptTokens > 0 else { return 0 }
        return Double(reusedTokens) / Double(totalPromptTokens)
    }
}

// MARK: - Token 估算

/// 轻量 token 估算器。
///
/// 为什么不用真正的 tokenizer：
///   - 云端没有本地 tokenizer，本地拿 tokenizer 又要跨 C 桥，代价与侵入性都不小；
///   - 观测阶段只需要**相对可比**的数字（baseline vs optimized、哪一项在涨），
///     不需要精确到个位。估算口径固定后，趋势与占比都是可信的。
///
/// 口径（与常见 BPE 词表近似）：
///   - CJK / 假名 / 谚文：约 1 字 ≈ 0.7 token
///   - 其余（拉丁字母、空白、ASCII 符号）：约 4 字符 ≈ 1 token（0.25）
enum TokenEstimator {

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F,   // CJK 标点
             0x3040...0x30FF,   // 平假名 / 片假名
             0x3400...0x4DBF,   // CJK 扩展 A
             0x4E00...0x9FFF,   // CJK 基本区
             0xAC00...0xD7AF,   // 谚文
             0xF900...0xFAFF:   // CJK 兼容表意
            return true
        default:
            return false
        }
    }

    /// 估算一段文本的 token 数。空串返回 0。
    static func tokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        let est = Double(cjk) * 0.7 + Double(other) * 0.25
        return max(1, Int(est.rounded()))
    }

    /// 估算一组消息（只统计 content，与发往模型的正文一致）的 token 数。
    static func tokens(messages: [ChatMessage]) -> Int {
        var total = 0
        for m in messages { total += tokens(in: m.content) }
        return total
    }
}

// MARK: - 单轮指标

/// 一次 Agent 迭代（一轮）的观测数据。
struct AgentIterationMetrics: Sendable, Equatable {
    /// 第几轮（从 1 开始，与 AgentService 的 iteration 对齐）。
    let iteration: Int
    /// 本轮 prompt（含 system + 历史）的估算 token。
    let inputTokens: Int
    /// 本轮注入给模型的工具目录（tool schema）估算 token。
    let toolSchemaTokens: Int
    /// 本轮回填进上下文的工具结果估算 token（含被拒绝/未执行的占位文案）。
    let toolResultTokens: Int
    /// 本轮模型输出（含 think 块）估算 token。
    let outputTokens: Int
    /// 本轮输出里 ` thinking` 部分估算 token（协议可区分时才有意义；否则为 0）。
    let reasoningTokens: Int
    /// 首 token 延迟（毫秒）：从发起生成到收到第一个 token。
    let ttftMs: Double
    /// 生成耗时（毫秒）：从发起生成到流结束（含 TTFT）。
    let generationMs: Double
    /// 本轮工具执行总耗时（毫秒，多调用时为各调用之和）。
    let toolExecutionMs: Double
    /// 本轮从开始到结束的总墙钟耗时（毫秒），含生成 + 工具执行 + 解析/回填。
    let totalLatencyMs: Double
    /// 本轮暴露给模型的工具数量。
    let exposedToolCount: Int
    /// 本地模式下本轮 KV cache 是否命中前缀复用。
    let kvCacheReused: Bool
    /// 本地模式下本轮命中复用的 token 数（云端为 0）。
    let kvCacheReusedTokens: Int
    /// 本轮是否以「有效工具调用」结束（用于区分 reasoning 轮 vs 动作轮）。
    let endedWithToolCall: Bool
}

// MARK: - 一次 run 的聚合指标

/// 一次 Agent run（一个用户任务）的聚合性能指标。
///
/// 字段命名与用户给定的 `AgentPerformanceMetrics { ... }` 对齐：
/// 顶层是**全 run 汇总**，`iterations` 保留每一轮的明细供 P50/P95 与逐轮分析。
struct AgentPerformanceMetrics: Sendable, Equatable {
    var inputTokens: Int = 0
    var toolSchemaTokens: Int = 0
    var toolResultTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var ttftMs: Double = 0
    var generationMs: Double = 0
    var toolExecutionMs: Double = 0
    var totalLatencyMs: Double = 0
    /// 暴露给模型的工具数量（取各轮中的最大值，反映"最坏一轮的上下文占用"）。
    var exposedToolCount: Int = 0
    var kvCacheReused: Bool = false
    /// 本地模式下整 run 命中复用的 token 总数。
    var kvCacheReusedTokens: Int = 0
    /// 本地模式下整 run prompt token 总数（用于计算整 run 复用率）。
    var kvCacheTotalPromptTokens: Int = 0

    var iterations: [AgentIterationMetrics] = []

    /// 全 run 的 KV 复用率 0...1（云端为 0）。
    var kvCacheReuseRatio: Double {
        guard kvCacheTotalPromptTokens > 0 else { return 0 }
        return Double(kvCacheReusedTokens) / Double(kvCacheTotalPromptTokens)
    }

    /// 以工具调用结束的轮数（动作轮）。
    var toolCallRounds: Int { iterations.filter { $0.endedWithToolCall }.count }

    /// 仅思考、未产出动作或结论的轮数 —— 这是"空转 reasoning"的直接度量。
    var reasoningOnlyRounds: Int {
        iterations.filter { !$0.endedWithToolCall && $0.outputTokens > 0 }.count
    }
}

// MARK: - 单轮累积器

/// 在 `AgentService.run` 一轮迭代内累积观测数据。
///
/// 用法：轮首创建 + `defer` 提交。Swift 的 `defer` 在 `continue` / `break` / `return`
/// 离开作用域时都会执行，因此无需在循环里那 5 个出口各写一遍提交逻辑 —— 这正是
/// "最小侵入"的关键：埋点集中在一处，不散落在控制流里。
struct AgentIterationAccumulator {
    let iteration: Int
    var inputTokens = 0
    var toolSchemaTokens = 0
    var toolResultTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var ttftMs: Double = 0
    var generationMs: Double = 0
    var toolExecutionMs: Double = 0
    var exposedToolCount = 0
    var kvStats: KVCacheReuseStats?
    var endedWithToolCall = false
    /// 本轮是否因瞬时错误重试而作废（作废轮不记录，避免污染统计）。
    var aborted = false

    /// 记录本轮生成结果：估算输出 / reasoning token，并记录 KV 复用。
    mutating func recordGeneration(raw: String, kvStats: KVCacheReuseStats?) {
        let (think, answer) = ChatMessage.parseThinkBlock(raw)
        reasoningTokens = TokenEstimator.tokens(in: think)
        outputTokens = TokenEstimator.tokens(in: think) + TokenEstimator.tokens(in: answer)
        self.kvStats = kvStats
    }

    /// 工具结果 token 与执行耗时（云端多调用 / 本地单调用共用）。
    mutating func addToolResult(_ text: String, durationMs: Int?) {
        toolResultTokens += TokenEstimator.tokens(in: text)
        if let durationMs, durationMs > 0 { toolExecutionMs += Double(durationMs) }
    }

    func snapshot(latencyMs: Double) -> AgentIterationMetrics {
        AgentIterationMetrics(
            iteration: iteration,
            inputTokens: inputTokens,
            toolSchemaTokens: toolSchemaTokens,
            toolResultTokens: toolResultTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            ttftMs: ttftMs,
            generationMs: generationMs,
            toolExecutionMs: toolExecutionMs,
            totalLatencyMs: latencyMs,
            exposedToolCount: exposedToolCount,
            kvCacheReused: kvStats?.reused ?? false,
            kvCacheReusedTokens: kvStats?.reusedTokens ?? 0,
            endedWithToolCall: endedWithToolCall
        )
    }
}

// MARK: - 采集器

/// 一次 run 的指标采集器。在主 actor 上使用（与 AgentService 一致），无需额外加锁。
@MainActor
final class AgentPerformanceRecorder {
    private(set) var iterations: [AgentIterationMetrics] = []

    func record(_ m: AgentIterationMetrics) {
        iterations.append(m)
    }

    /// 生成聚合指标。`totalLatencyMs` 由调用方给出（run 的墙钟总耗时）。
    func metrics(totalLatencyMs: Double) -> AgentPerformanceMetrics {
        var m = AgentPerformanceMetrics()
        m.totalLatencyMs = totalLatencyMs
        for it in iterations {
            m.inputTokens += it.inputTokens
            m.toolSchemaTokens += it.toolSchemaTokens
            m.toolResultTokens += it.toolResultTokens
            m.outputTokens += it.outputTokens
            m.reasoningTokens += it.reasoningTokens
            m.generationMs += it.generationMs
            m.toolExecutionMs += it.toolExecutionMs
            m.exposedToolCount = max(m.exposedToolCount, it.exposedToolCount)
            m.kvCacheReused = m.kvCacheReused || it.kvCacheReused
            m.kvCacheReusedTokens += it.kvCacheReusedTokens
            if it.kvCacheReusedTokens > 0 || it.inputTokens > 0 {
                // 只有本地模式会填 reusedTokens；用 inputTokens 作为 prompt 分母的近似，
                // 本地没有更精确的"prompt token 总数"时它也足够支撑复用率趋势。
                m.kvCacheTotalPromptTokens += max(it.kvCacheReusedTokens, it.inputTokens)
            }
        }
        // TTFT：取首轮（用户感知的第一个 token 延迟），比求和无意义。
        m.ttftMs = iterations.first?.ttftMs ?? 0
        m.iterations = iterations
        return m
    }

    /// 生成一行紧凑的结构化摘要（仅用于日志，不替代上面的结构化数据）。
    func summaryLine(_ m: AgentPerformanceMetrics) -> String {
        let p50 = percentile(iterations.map { $0.totalLatencyMs }, 0.5)
        let p95 = percentile(iterations.map { $0.totalLatencyMs }, 0.95)
        return "[agent-perf] rounds=\(m.iterations.count)"
            + " in=\(m.inputTokens) schema=\(m.toolSchemaTokens) result=\(m.toolResultTokens)"
            + " out=\(m.outputTokens) reason=\(m.reasoningTokens)"
            + " ttft=\(Int(m.ttftMs))ms gen=\(Int(m.generationMs))ms tool=\(Int(m.toolExecutionMs))ms"
            + " p50=\(Int(p50))ms p95=\(Int(p95))ms total=\(Int(m.totalLatencyMs))ms"
            + " tools=\(m.exposedToolCount) kvReuse=\(String(format: "%.0f%%", m.kvCacheReuseRatio * 100))"
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }
}