import Foundation

/// 纯文本逐行 diff（LCS）+ unified 输出。
///
/// 为什么自己写：iOS 没有 `diff` 二进制，而"看到改了什么"是 git 最常用的能力 ——
/// 只给 `git status` 一行 modified，模型就没法回答"改了哪几行"。
/// 算法先削掉公共前后缀再跑 LCS：真实改动通常是局部的，削完剩下的矩阵很小；
/// 万一碰到整文件重写的极端情况，超过阈值就退化成"全删全加"（结果仍合法，
/// 只是少了上下文合并 —— 好过在 5000×5000 的 DP 上卡死 UI）。
enum GitTextDiff {

    enum Op { case equal, del, insert }

    static let contextLines = 3
    /// 超过这个规模就不再跑 LCS（2500×2500 = 625 万个单元，Swift 里已明显卡顿）。
    static let lcsCellCap = 2500 * 2500

    static func splitLines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// 产出 unified hunk 文本；内容相同返回空串。
    /// `oldLabel` / `newLabel` 只用于 `---`/`+++` 行（形如 `a/file`、`b/file`）。
    static func unified(old: String, new: String,
                        oldLabel: String, newLabel: String,
                        oldMode: String? = nil, newMode: String? = nil) -> String {
        if old == new { return "" }

        var out = ""
        out += "--- \(oldLabel)\n+++ \(newLabel)\n"

        let a = splitLines(old)
        let b = splitLines(new)
        let ops = diffOps(old: a, new: b)

        // 编辑脚本 → (op, 旧侧行号, 新侧行号)：equal 两侧同增、del 旧侧增、insert 新侧增。
        // 行号存 0-based，-1 表示该侧没有这一行。
        var indexed = [(op: Op, ai: Int, bi: Int)]()
        var ai = 0, bi = 0
        for op in ops {
            switch op {
            case .equal:
                indexed.append((.equal, ai, bi)); ai += 1; bi += 1
            case .del:
                indexed.append((.del, ai, -1)); ai += 1
            case .insert:
                indexed.append((.insert, -1, bi)); bi += 1
            }
        }

        // 变更点下标
        let changed = indexed.indices.filter { indexed[$0].op != .equal }
        guard !changed.isEmpty else { return out }

        // 向两侧扩上下文并合并重叠 hunk
        var hunks = [(start: Int, end: Int)]()
        for c in changed {
            let s = max(0, c - contextLines)
            let e = min(indexed.count - 1, c + contextLines)
            if let last = hunks.last, s <= last.end + 1 {
                hunks[hunks.count - 1] = (last.start, max(last.end, e))
            } else {
                hunks.append((s, e))
            }
        }

        // 上一个 hunk 在旧文件里覆盖到的行号（-1 = 还没有 hunk）：
        // git 只在"两个 hunk 之间的上下文"里找函数名，不会回溯到更早的地方。
        var prevOldEnd = -1
        for hunk in hunks {
            let slice = indexed[hunk.start...hunk.end]
            let oldStart = slice.first(where: { $0.ai >= 0 })?.ai ?? ai
            let newStart = slice.first(where: { $0.bi >= 0 })?.bi ?? bi
            var oldCount = 0, newCount = 0
            var lastOld = oldStart
            var body = ""
            for item in slice {
                switch item.op {
                case .equal:
                    oldCount += 1; newCount += 1
                    if item.ai >= 0 { lastOld = item.ai + 1 }
                    body += " \(itemText(a, item.ai))\n"
                case .del:
                    oldCount += 1
                    if item.ai >= 0 { lastOld = item.ai + 1 }
                    body += "-\(itemText(a, item.ai))\n"
                case .insert:
                    newCount += 1; body += "+\(itemText(b, item.bi))\n"
                }
            }
            // git 默认会在 `@@` 行尾带出"函数名上下文"（xdl 的 funcname 启发式）：
            // 从上一个 hunk 之后到本 hunk 之前，找最后一行以字母/`_`/`$` 开头的行。
            // 少了这段，与真 git 的输出会逐字节不同（模型对照时会以为自己算错了）。
            var heading = ""
            if oldCount > 0 || newCount > 0 {
                // 区间是 [prevOldEnd, oldStart-1]：上一个 hunk 结束处（不含）到本 hunk 开始前，
                // 正好是两个 hunk 之间的上下文 —— git 只在这里找函数名。
                var idx = min(oldStart, a.count) - 1
                while idx >= prevOldEnd, idx >= 0 {
                    if idx >= 0, idx < a.count, Self.isFuncNameLine(a[idx]) { heading = " " + a[idx]; break }
                    idx -= 1
                }
            }
            prevOldEnd = max(prevOldEnd, lastOld)

            let oldH = hunkHeader(start: oldStart, count: oldCount, sign: "-")
            let newH = hunkHeader(start: newStart, count: newCount, sign: "+")
            out += "@@ \(oldH) \(newH) @@\(heading)\n" + body
        }
        return out
    }

    /// git 默认 funcname 规则（`user_diff` 的 `^[A-Za-z_$]` 近似）。
    static func isFuncNameLine(_ line: String) -> Bool {
        guard let c = line.first else { return false }
        return c.isASCII && (c.isLetter || c == "_" || c == "$")
    }

    private static func itemText(_ arr: [String], _ idx: Int) -> String {
        guard idx >= 0, idx < arr.count else { return "" }
        return arr[idx]
    }

    /// `@@ -3,4 +3,6 @@` 中单侧的 `<sign>start,count`（start 是 1-based）。
    static func hunkHeader(start: Int, count: Int, sign: String) -> String {
        // git 的省略规则（xdl 输出）：
        //   count == 0 → `<start>,0`（空文件那一侧，如 `@@ -1 +0,0 @@`）
        //   count == 1 → 只写行号（`-1`，不写 `,1`）
        //   其它      → `<start>,<count>`
        if count == 0 { return "\(sign)\(start),0" }
        if count == 1 { return "\(sign)\(start + 1)" }
        return "\(sign)\(start + 1),\(count)"
    }

    /// 编辑脚本（只含 op 的顺序）。先削公共前后缀，再对中段跑 LCS。
    static func diffOps(old a: [String], new b: [String]) -> [Op] {
        var prefix = 0
        let maxPrefix = min(a.count, b.count)
        while prefix < maxPrefix, a[prefix] == b[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < maxPrefix - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var ops = [Op](repeating: .equal, count: prefix)
        if midA.isEmpty && midB.isEmpty {
            ops.append(contentsOf: [Op](repeating: .equal, count: suffix))
            return ops
        }
        ops.append(contentsOf: middleOps(old: midA, new: midB))
        ops.append(contentsOf: [Op](repeating: .equal, count: suffix))
        return ops
    }

    private static func middleOps(old a: [String], new b: [String]) -> [Op] {
        if a.count * b.count > lcsCellCap {
            // 退化：整段替换。仍然是合法 unified diff，只是不合并中间的相同行。
            return [Op](repeating: .del, count: a.count) + [Op](repeating: .insert, count: b.count)
        }
        // 经典 DP：dp[i][j] = a[i...] 与 b[j...] 的 LCS 长度。
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var ops = [Op]()
        ops.reserveCapacity(n + m)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { ops.append(.equal); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ops.append(.del); i += 1 }
            else { ops.append(.insert); j += 1 }
        }
        while i < n { ops.append(.del); i += 1 }
        while j < m { ops.append(.insert); j += 1 }
        return ops
    }
}
