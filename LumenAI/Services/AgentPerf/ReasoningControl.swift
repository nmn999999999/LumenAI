import Foundation

// MARK: - Adaptive Reasoning Budget / ReasoningGate / Repetition Detector（阶段 2-4）
//
// 设计前提（与现有架构对齐，不强行套结构）：
//   - Agent 主循环是「一轮生成 → 解析 → 可能执行工具 → 回填 → 下一轮」。
//   - Runtime 拥有终止 reasoning 的最终控制权，不要求模型自己决定何时停。
//   - 不过度修改采样参数（阶段 11）：这里只做"预算 + 门控 + 重复检测 + 提示强化"，
//     不改 temperature / top-p / context size。
//
// 三段渐进式预算：256 → 512 → 1024 → 2048（上限）。默认从最小开始，
// 只有"本轮没能做出可靠动作"时才升档；一旦成功动作就回到起点。

/// ReasoningGate 状态：Runtime 对当前 reasoning 的判定结果。
enum ReasoningGateState: String, Sendable {
    /// 仍在思考，未触发任何停止条件。
    case thinking
    /// 已产生合法 Tool Call → 应立即停止 reasoning，进入工具执行。
    case toolReady
    /// 已产生最终答案 → 应立即停止 reasoning。
    case finalReady
    /// 已达到当前 reasoning 预算 → 停止 reasoning，强制动作/收尾。
    case budgetExceeded
    /// 检测到明显重复 reasoning → 停止 reasoning，优先执行已确定的动作。
    case repetitionDetected
}

// MARK: - 渐进式预算

/// 轻量 reasoning 预算控制器。
///
/// 为什么是"累计 reasoning token + 渐进升档"而不是"每轮固定上限"：
///   - 简单任务（多数请求）在 256 内就该出结果，给 2048 只会诱导它多想；
///   - 复杂任务确实需要更多思考，所以按"未推进就升档"的方式逐级放宽；
///   - 上限 2048 是硬顶，防止无限扩大。
struct ReasoningBudgetController: Sendable {
    /// 档位阶梯（token）。默认最高档 = 2048。
    static let ladder: [Int] = [256, 512, 1024, 2048]

    /// 本实例实际使用的阶梯（按 `maxBudget` 裁剪，见 init）。
    let ladder: [Int]
    private(set) var budget: Int
    private(set) var tierIndex: Int = 0

    /// - Parameter maxBudget: 本段思考允许的 token 上限（设置页「思考预算」）。
    ///   阶梯被裁成"不超过 maxBudget 的档位 + maxBudget 本身"：
    ///   · maxBudget = 2048（默认）→ 与原阶梯 [256,512,1024,2048] 完全一致，行为不变；
    ///   · maxBudget = 512         → [256, 512]，即两档内必须出动作；
    ///   · maxBudget 小于最小档     → 只有一档 = maxBudget（仍然可用，不崩）。
    ///   这样"思考更短"是通过**收紧阶梯**实现的，而不是给每轮一刀切的硬截断 ——
    ///   渐进放宽的语义（没推进才升档）保持不变。
    init(maxBudget: Int = 2048) {
        let clamped = max(64, maxBudget)
        var tiers = Self.ladder.filter { $0 < clamped }
        tiers.append(clamped)
        self.ladder = tiers
        self.budget = tiers[0]
    }

    /// 升一档（到上限即停）。返回是否发生了升档。
    @discardableResult
    mutating func escalate() -> Bool {
        guard tierIndex < ladder.count - 1 else { return false }
        tierIndex += 1
        budget = ladder[tierIndex]
        return true
    }

    /// 回到起点预算（一次成功动作之后：下一段任务从最小预算重新开始）。
    mutating func reset() {
        tierIndex = 0
        budget = ladder[0]
    }

    /// 累计 reasoning 是否已超出当前预算。
    func exceeded(totalReasoningTokens: Int) -> Bool {
        totalReasoningTokens > budget
    }
}

// MARK: - 重复检测（无 embedding）

/// 轻量 reasoning 重复检测。
///
/// 目标场景（实测问题）：
///   - 同一张繁简映射表被重复生成；
///   - 同一方案跨轮重新推导；
///   - 已有结论后继续反复验证；
///   - 大量"我应该…然后…再检查…"的循环。
///
/// 手段（刻意不引入大模型）：
///   - 按 ~64-128 token 切 chunk；
///   - 为每个 chunk 计算 3-gram 集合（对中英文都成立：CJK 无空格，字符 n-gram 更稳）；
///   - 相邻 chunk 用 Jaccard 相似度 + SimHash 汉明相似度叠加判定；
///   - 需要**连续**多对超过阈值才判定重复，避免"自然语言里重复一个短语"被误杀。
///
/// 所有阈值可配置。
struct ReasoningRepetitionDetector {

    // 可配置阈值（默认值来自实测经验，落在用户建议区间 0.82~0.9 内）
    var chunkTokenTarget: Int
    var similarityThreshold: Double
    var minConsecutiveRepeats: Int
    /// 最小 chunk 字符数：太短的 chunk 不参与判定（防止把一句正常寒暄判成重复）。
    var minChunkChars: Int

    private var pending = ""
    private var lastSignature: Set<String>?
    private var lastSimHash: UInt64?
    private var consecutive = 0

    init(chunkTokenTarget: Int = 96,
         similarityThreshold: Double = 0.86,
         minConsecutiveRepeats: Int = 2,
         minChunkChars: Int = 48) {
        self.chunkTokenTarget = chunkTokenTarget
        self.similarityThreshold = similarityThreshold
        self.minConsecutiveRepeats = minConsecutiveRepeats
        self.minChunkChars = minChunkChars
    }

    /// 摄入本轮 reasoning 文本。返回是否判定为"明显重复"。
    mutating func ingest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pending += "\n" + trimmed

        var repeated = false
        // 按估算 token 切成若干 chunk 后逐个比较
        while TokenEstimator.tokens(in: pending) >= chunkTokenTarget {
            let chunk = takeChunk(approximately: chunkTokenTarget)
            guard !chunk.isEmpty else { break }
            if compareAndUpdate(chunk) { repeated = true }
        }
        return repeated
    }

    /// 重置（一次成功动作后：全新的推理段落不应背上一段的重复账）。
    mutating func reset() {
        pending = ""
        lastSignature = nil
        lastSimHash = nil
        consecutive = 0
    }

    // MARK: 私有

    /// 从 pending 头部按大约 target token 切一段出来。按字符近似映射（与 TokenEstimator 同口径）。
    private mutating func takeChunk(approximately target: Int) -> String {
        guard !pending.isEmpty else { return "" }
        // 目标字符数：CJK 1 字≈0.7 token → 约 target/0.7；拉丁 4 字≈1 token。
        // 这里用保守的中间值，切开即可，不必精确。
        let targetChars = max(minChunkChars, Int(Double(target) * 1.4))
        if pending.count <= targetChars {
            let all = pending
            pending = ""
            return all
        }
        let idx = pending.index(pending.startIndex, offsetBy: targetChars)
        let chunk = String(pending[pending.startIndex..<idx])
        pending = String(pending[idx...])
        return chunk
    }

    private mutating func compareAndUpdate(_ chunk: String) -> Bool {
        let sig = Self.ngramSet(chunk, n: 3)
        guard sig.count >= 8 else {
            // chunk 太短/信息量太低：不参与判定，也不更新基准，避免误判
            return false
        }
        let sh = Self.simHash(chunk, n: 3)

        var isRepeat = false
        if let prev = lastSignature {
            let jaccard = Self.jaccard(prev, sig)
            let hammingSim = (lastSimHash.map { Self.hammingSimilarity($0, sh) }) ?? 0
            // 两个信号取较大者：Jaccard 对"同义改写"敏感，SimHash 对"整体结构雷同"敏感。
            let sim = max(jaccard, hammingSim)
            if sim >= similarityThreshold { isRepeat = true }
        }

        if isRepeat {
            consecutive += 1
        } else {
            consecutive = 0
        }
        lastSignature = sig
        lastSimHash = sh
        return consecutive >= minConsecutiveRepeats
    }

    // MARK: 相似度原语

    /// n-gram（字符级）集合。先归一化：转小写、折叠空白。
    static func ngramSet(_ text: String, n: Int) -> Set<String> {
        let normalized = normalize(text)
        let chars = Array(normalized)
        guard chars.count >= n else { return Set([normalized]) }
        var set = Set<String>()
        set.reserveCapacity(chars.count)
        for i in 0...(chars.count - n) {
            set.insert(String(chars[i..<(i + n)]))
        }
        return set
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(inter) / Double(union)
    }

    /// 稳定 64-bit SimHash：对 n-gram 的 FNV-1a 哈希做加权投票。
    static func simHash(_ text: String, n: Int) -> UInt64 {
        var v = [Int](repeating: 0, count: 64)
        for gram in ngramSet(text, n: n) {
            let h = fnv1a(gram)
            for bit in 0..<64 where (h >> UInt64(bit)) & 1 == 1 { v[bit] += 1 }
            for bit in 0..<64 where (h >> UInt64(bit)) & 1 == 0 { v[bit] -= 1 }
        }
        var out: UInt64 = 0
        for bit in 0..<64 where v[bit] > 0 { out |= (UInt64(1) << UInt64(bit)) }
        return out
    }

    static func hammingSimilarity(_ a: UInt64, _ b: UInt64) -> Double {
        let x = a ^ b
        let distance = x.nonzeroBitCount
        return 1.0 - Double(distance) / 64.0
    }

    private static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace { out.unicodeScalars.append(" "); lastWasSpace = true }
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out
    }

    /// FNV-1a 64-bit（对 UTF-8 字节）。
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

// MARK: - Runtime 门面

/// 把「预算 + 门控 + 重复检测」组合成主循环里一个易用的控制器。
///
/// 线程/隔离：与 AgentService 一致，在主 actor 上使用。
@MainActor
final class ReasoningRuntime {

    private(set) var budget: ReasoningBudgetController
    private var detector = ReasoningRepetitionDetector()
    private(set) var cumulativeReasoningTokens = 0
    private(set) var gate: ReasoningGateState = .thinking
    /// 本轮任务内纯 reasoning 的轮数（"空转"的直接度量）。
    private(set) var pureReasoningRounds = 0

    /// - Parameter maxBudget: 单段思考的 token 上限（透传给 `ReasoningBudgetController`）。
    ///   默认 2048 = 改造前行为；设置页「思考预算」调低后阶梯整体收紧。
    init(maxBudget: Int = 2048) {
        self.budget = ReasoningBudgetController(maxBudget: maxBudget)
    }

    /// 一次成功动作（有效工具调用 / 最终答案）之后调用：
    /// 重置累计与重复检测 —— 新的一段任务应从最小预算重新开始。
    func registerAction() {
        gate = .thinking
        cumulativeReasoningTokens = 0
        pureReasoningRounds = 0
        budget.reset()
        detector.reset()
    }

    /// 标记已就绪的门控（供主循环在解析出结果后调用，确保状态可观测）。
    func markToolReady() { gate = .toolReady }
    func markFinalReady() { gate = .finalReady }

    /// 本轮是纯 reasoning（既无有效工具调用、也无最终答案）。
    /// 返回本轮的 gate 判定；同时按需升档预算。
    func registerReasoningTurn(text: String, tokens: Int) -> ReasoningGateState {
        pureReasoningRounds += 1
        cumulativeReasoningTokens += max(0, tokens)

        // 1) 重复优先：重复是"再给预算也没用"的信号。
        if detector.ingest(text) {
            gate = .repetitionDetected
            return gate
        }
        // 2) 预算：累计超当前档 → 本轮强制动作，并为**下一次**思考升一档。
        //
        // 只在"确实超了"时才升档 —— 这才是用户要求的渐进语义：
        // 默认停在最小预算，只有本轮没能在预算内做出可靠动作，才允许下一段用更多预算。
        // 若无条件每轮升档，那么"连发几轮短思考"也会把预算一路推到 2048，等于默认最大预算。
        if budget.exceeded(totalReasoningTokens: cumulativeReasoningTokens) {
            _ = budget.escalate()
            gate = .budgetExceeded
            return gate
        }
        gate = .thinking
        return gate
    }

    /// 当前 gate 下应追加给模型的强化指令（nil = 继续用普通提示）。
    func forcedActionDirective() -> String? {
        switch gate {
        case .repetitionDetected:
            return """
            检测到你正在重复相同的推理内容。立即停止复述与重新验证：
            - 若还需要外部信息 → 只输出一个工具调用 JSON（不要附带任何解释）；
            - 若已有足够信息 → 先输出 \(AgentService.endSignal)，随后直接给出最终回答正文。
            不要重述已经完成的步骤。
            """
        case .budgetExceeded:
            return """
            本轮推理已达允许上限。不要再继续思考：
            - 若还需要外部信息 → 只输出一个工具调用 JSON；
            - 若已有足够信息 → 先输出 \(AgentService.endSignal)，随后直接给出最终回答正文。
            """
        default:
            return nil
        }
    }
}