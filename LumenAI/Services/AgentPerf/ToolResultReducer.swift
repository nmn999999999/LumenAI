import Foundation

// MARK: - Tool Result 压缩（阶段 8）
//
// 目标：**不要把巨大的工具结果原样塞回 LLM**，但也**不能简单粗暴截断**。
//
// 现状：`AgentService.limitResult` 只做「保留头 60% + 尾 40% + 一行省略提示」。
// 对短结果是够用的，但在长任务里会遇到三类真实损失：
//   1. 错误信息在**中段**（例如 JSON 校验失败、shell 前几行报错后跟一长段输出）——
//      头尾截断正好把唯一的线索切掉；
//   2. JSON / MCP 结果里大量**重复 metadata**（id/type/role 每项重复上百次），
//      占了绝大多数 token，却没有新信息；
//   3. web_search / http_get 的网页正文里，模型只需要标题、链接与关键段落。
//
// 所以这里按内容形态分流处理，且**始终把错误信息放在最高优先级**：
//   - JSON 结果 → 结构化瘦身（长字符串截断、超长数组折叠、保留全部 key）
//   - 含错误 → 显式抽取错误行 + 头尾上下文
//   - 普通长文本 → 去重重复行 + 头尾保留 + 省略计数
//
// 兜底策略是「宁可少压缩、不可丢信息」：任何一条分支产出的结果若反而更长，
// 就退回原始的头尾截断逻辑（与改造前行为一致）。
//
// 阈值全部可配置，默认值保守 —— 压缩只作用于**超过 maxChars 的长结果**，
// 短结果逐字返回，因此不会影响绝大多数正常轮次，也不会改变本地模型的提示词契约
// （本地仍是裸文本，只是内容更短）。
enum ToolResultReducer {

    /// 认为「这是一个错误结果」的行内标记（大小写不敏感）。
    private static let errorMarkers = [
        "错误", "error", "failed", "failure", "exception", "traceback",
        "denied", "refused", "timeout", "timed out", "not found",
        "no such", "permission", "invalid", "fatal",
    ]

    /// 压缩一段工具结果。
    ///
    /// - Parameters:
    ///   - raw: 工具原始返回文本。
    ///   - toolName: 工具名（用于裁剪提示与按工具微调；可选）。
    ///   - maxChars: 压缩后允许的最大字符数（保持旧默认 2000，避免行为回退）。
    static func reduce(_ raw: String, toolName: String = "", maxChars: Int = 2000) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 短结果原样返回（返回**未裁剪的原文**）：这是绝大多数轮次，
        // 也是"不改变现有行为"的保证 —— 调用方用 `limited != raw` 判断是否截断，
        // 若这里顺手 trim 了空白，短结果会被误标成 truncated。
        guard text.count > maxChars else { return raw }

        // 1) 整段就是一个 JSON：结构化瘦身（最有效的一类，尤其 MCP / http）。
        if let compacted = compactJSONText(text, maxChars: maxChars) { return compacted }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let isError = ToolResultFormat.isError(text) || lines.contains { containsErrorMarker($0) }

        // 2) 错误优先：抽取错误行，保证线索不丢。
        if isError {
            // ⚠️ 调用方用 `ToolResultFormat.isError(limited)`（前缀判定）决定 UI 上是成功还是失败。
            // 若原结果以 "错误: " 开头，压缩后**必须仍然以它开头**，否则一次长错误会被误判成成功
            // （界面上出现绿勾，而模型按失败处理 —— 两边判断相反）。
            let leading = ToolResultFormat.isError(text)
                ? String((lines.first ?? "").prefix(200))
                : nil
            return reduceError(text, lines: lines, leadingErrorLine: leading,
                               toolName: toolName, maxChars: maxChars)
        }

        // 3) 普通长文本：去重 + 头尾。
        return reduceGeneric(text, lines: lines, maxChars: maxChars)
    }

    // MARK: - JSON 结构化瘦身

    /// 若整段文本可解析为 JSON，则做结构瘦身。否则返回 nil（不动日志 / 网页正文）。
    private static func compactJSONText(_ text: String, maxChars: Int) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }

        let shrunk = shrink(obj, maxString: 400, maxArrayItems: 20, depth: 0)
        guard let out = try? JSONSerialization.data(
            withJSONObject: shrunk, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return nil }

        // 瘦身后仍超限：再走头尾。注意此时内容已被结构化压缩，头尾不会丢字段名。
        return s.count <= maxChars ? s : headTail(s, maxChars: maxChars)
    }

    /// 递归瘦身：保留全部 key，只截断超长字符串 / 折叠超长数组。
    private static func shrink(_ value: Any, maxString: Int, maxArrayItems: Int, depth: Int) -> Any {
        if depth > 12 { return "…(嵌套过深已省略)" }
        if let s = value as? String {
            guard s.count > maxString else { return s }
            return String(s.prefix(maxString)) + "…(省略\(s.count - maxString)字)"
        }
        if let arr = value as? [Any] {
            if arr.count > maxArrayItems {
                var kept = arr.prefix(maxArrayItems).map {
                    shrink($0, maxString: maxString, maxArrayItems: maxArrayItems, depth: depth + 1)
                }
                kept.append("…(另有 \(arr.count - maxArrayItems) 项)")
                return kept
            }
            return arr.map {
                shrink($0, maxString: maxString, maxArrayItems: maxArrayItems, depth: depth + 1)
            }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = shrink(v, maxString: maxString, maxArrayItems: maxArrayItems, depth: depth + 1)
            }
            return out
        }
        return value
    }

    // MARK: - 错误结果

    /// 错误结果：抽取**错误行** + 头部上下文 + 尾部上下文，任一都不因压缩而丢。
    private static func reduceError(_ text: String, lines: [String], leadingErrorLine: String?,
                                    toolName: String, maxChars: Int) -> String {
        let markerLines = lines.filter { containsErrorMarker($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // 错误行本身可能很多（逐行报错）：取前 20 行，足够定位问题。
        let keptMarkers = markerLines.prefix(20)

        var body = keptMarkers.joined(separator: "\n")
        if markerLines.count > keptMarkers.count {
            body += "\n…(另有 \(markerLines.count - keptMarkers.count) 行错误信息已省略)…"
        }

        // 头部（前 8 行）给上下文，尾部（后 8 行）给结论/退出信息。
        let head = lines.prefix(8).joined(separator: "\n")
        let tail = lines.suffix(8).joined(separator: "\n")

        var assembled = ""
        // 若原结果带失败前缀，把它放在最前面，保证 `ToolResultFormat.isError` 语义不变。
        if let leadingErrorLine { assembled += leadingErrorLine + "\n" }
        assembled += """
        [错误优先压缩：以下保留报错行与上下文]
        错误行:
        \(body)

        输出开头:
        \(head)

        输出结尾:
        \(tail)
        """
        let note = "\n…(原结果 \(text.count) 字过长，已保留报错与头尾；如需完整内容请缩小查询范围)…"
        return clamp(assembled, maxChars: maxChars, note: note, fallback: text)
    }

    // MARK: - 普通长文本

    /// 普通长文本：先合并**完全重复的行**（典型是每项重复的 metadata / 日志前缀），
    /// 再做头尾保留。重复行占比不高时直接头尾，避免改变语义。
    private static func reduceGeneric(_ text: String, lines: [String], maxChars: Int) -> String {
        var seen = Set<String>()
        var unique: [String] = []
        var duplicates = 0
        unique.reserveCapacity(lines.count)
        for line in lines {
            let key = line.trimmingCharacters(in: .whitespaces)
            // 空行不参与去重（保留段落的视觉结构交给头尾逻辑）
            if key.isEmpty { unique.append(line); continue }
            if seen.contains(key) { duplicates += 1; continue }
            seen.insert(key)
            unique.append(line)
        }

        // 去重修掉了足够多的重复（≥15% 且至少 10 行）才采用，否则说明"重复"是巧合。
        let worthwhile = duplicates >= 10 && duplicates * 100 / max(1, lines.count) >= 15
        let deduped = worthwhile ? unique.joined(separator: "\n") : text
        let dedupNote = worthwhile ? "\n…(已合并 \(duplicates) 行完全重复内容)…" : ""

        if deduped.count <= maxChars { return deduped + dedupNote }

        let note = dedupNote + "\n…(原结果 \(text.count) 字，已保留头尾；省略 \(max(0, text.count - maxChars)) 字)…"
        return clamp(deduped, maxChars: maxChars, note: note, fallback: text)
    }

    // MARK: - 工具

    /// 头尾保留（与改造前 `limitResult` 同策略，作为所有分支的安全兜底）。
    private static func headTail(_ text: String, maxChars: Int) -> String {
        let headLen = maxChars * 6 / 10
        let tailLen = max(0, maxChars - headLen - 40)
        let omitted = max(0, text.count - headLen - tailLen)
        return String(text.prefix(headLen))
            + "\n…(中间省略 \(omitted) 字，共 \(text.count) 字)…\n"
            + String(text.suffix(tailLen))
    }

    /// 用头尾压缩，并把 `note` 拼在末尾。
    /// 若压缩结果反而更长（极端情况），退回原始头尾，保证不会比改造前更差。
    private static func clamp(_ text: String, maxChars: Int, note: String, fallback: String) -> String {
        let compressed = headTail(text, maxChars: maxChars)
        let candidate = compressed + note
        let plain = headTail(fallback, maxChars: maxChars)
        return candidate.count <= plain.count ? candidate : plain
    }

    private static func containsErrorMarker(_ line: String) -> Bool {
        let lower = line.lowercased()
        for marker in errorMarkers where lower.contains(marker) { return true }
        return false
    }
}