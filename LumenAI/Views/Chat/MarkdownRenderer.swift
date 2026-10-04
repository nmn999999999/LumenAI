import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Markdown 块级模型
// 对应 gpt_markdown 渲染：标题 / 代码高亮 / LaTeX / 表格 / 列表 / 引用

enum MarkdownBlock {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case codeBlock(language: String?, code: String)
    case quote(AttributedString)
    case list(ordered: Bool, items: [AttributedString])
    case table(headers: [String], rows: [[String]])
    case divider
    case mathBlock(String)
}

// MARK: - Markdown 解析器

@MainActor
enum MarkdownRenderer {

    /// 性能：流式期间整文每帧都不同，字符串级缓存从不命中——回退到段落级缓存。
    /// 按空行切块，每块独立缓存：流式中"已闭合"段落稳定不变直接命中，
    /// 只有"最后一个未闭合"段落随 token 流变需重新解析。
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        guard !markdown.isEmpty else { return [] }
        let chunks = markdown.components(separatedBy: "\n\n")
        var blocks: [MarkdownBlock] = []
        for chunk in chunks {
            blocks.append(contentsOf: parseBlockCached(chunk))
        }
        return blocks
    }

    /// 单段落的块级解析 + 字符串级缓存（同一段落重复输入直接命中）
    private static func parseBlockCached(_ chunk: String) -> [MarkdownBlock] {
        guard !chunk.isEmpty else { return [] }
        if let cached = chunkCache[chunk] { return cached }
        let blocks = parseBlocks(chunk)
        if chunkCache.count > 600 { chunkCache.removeAll() }
        chunkCache[chunk] = blocks
        return blocks
    }

    /// 内容级缓存：流式期间同一内容重复解析时直接命中
    @MainActor private static var cache: [String: [MarkdownBlock]] = [:]
    /// 段落级缓存：流式期间"已闭合"段落稳定不变，直接命中避免重新解析
    @MainActor private static var chunkCache: [String: [MarkdownBlock]] = [:]

    // MARK: 块级解析

    private static func parseBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // 空行
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // 围栏代码块 ```lang
            if line.hasPrefix("```") {
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // 跳过闭合围栏
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    code: code.joined(separator: "\n")
                ))
                continue
            }

            // LaTeX 块 $$...$$
            if line.hasPrefix("$$") {
                var tex = String(line.dropFirst(2))
                if !tex.contains("$$") {
                    i += 1
                    while i < lines.count, !lines[i].contains("$$") {
                        tex += "\n" + lines[i]
                        i += 1
                    }
                    if i < lines.count {
                        tex += "\n" + lines[i].replacingOccurrences(of: "$$", with: "")
                        i += 1
                    }
                } else {
                    tex = tex.replacingOccurrences(of: "$$", with: "")
                    i += 1
                }
                blocks.append(.mathBlock(tex.trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            // 标题
            if let h = headingLevel(line) {
                let content = String(line.dropFirst(h)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: h, text: parseInline(content)))
                i += 1
                continue
            }

            // 分隔线
            if isDivider(line) {
                blocks.append(.divider)
                i += 1
                continue
            }

            // 引用块（连续行）
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    quoteLines.append(String(lines[i].dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(parseInline(quoteLines.joined(separator: "\n"))))
                continue
            }

            // 无序列表
            if let item = listItem(line, ordered: false) {
                var items: [AttributedString] = [item]
                i += 1
                while i < lines.count, let next = listItem(lines[i], ordered: false) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.list(ordered: false, items: items))
                continue
            }

            // 有序列表
            if let item = listItem(line, ordered: true) {
                var items: [AttributedString] = [item]
                i += 1
                while i < lines.count, let next = listItem(lines[i], ordered: true) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.list(ordered: true, items: items))
                continue
            }

            // 表格
            if line.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let headers = parseTableRow(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].hasPrefix("|") {
                    rows.append(parseTableRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // 普通段落：累积到空行
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if next.hasPrefix("```") || next.hasPrefix("$$") || next.hasPrefix("#")
                    || next.hasPrefix(">") || isDivider(next)
                    || listItem(next, ordered: false) != nil || listItem(next, ordered: true) != nil
                    || (next.hasPrefix("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                    break
                }
                para.append(next)
                i += 1
            }
            blocks.append(.paragraph(parseInline(para.joined(separator: "\n"))))
        }

        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6 else { return nil }
        // 需有空格分隔
        let idx = line.index(line.startIndex, offsetBy: count)
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        return count
    }

    private static func isDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return false }
        let chs = Set(t)
        return chs.count == 1 && (chs.contains("-") || chs.contains("*") || chs.contains("_"))
    }

    private static func listItem(_ line: String, ordered: Bool) -> AttributedString? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !ordered {
            for marker in ["- ", "* ", "+ "] where t.hasPrefix(marker) {
                return parseInline(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        // 有序: "1. " / "1) " —— 预编译正则（块级解析对每行都要调用，
        // `range(of:options:.regularExpression)` 每次调用都会重新编译 pattern）
        guard let regex = orderedListRegex,
              let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let range = Range(match.range, in: t) else { return nil }
        return parseInline(String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    private static let orderedListRegex = try? NSRegularExpression(pattern: #"^\d+[.)]\s+"#)

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        let inner = t.dropFirst().dropLast()
        let cells = inner.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.hasPrefix("-") && cell.filter { $0 == "-" }.count >= 1
        }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return [] }
        var s = String(t.dropFirst())
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 内联解析（bold / italic / code / link / strikethrough / math）

    private static let inlinePatterns: [(regex: String, kind: InlineKind)] = [
        // 注意顺序：code / math 优先，避免误解析内部内容
        (#"`([^`]+)`"#, .code),
        (#"\$\$([^$]+)\$\$"#, .math),
        (#"\$([^$]+)\$"#, .math),
        (#"\*\*([^*]+)\*\*"#, .strong),
        (#"__([^_]+)__"#, .strong),
        (#"\*([^*]+)\*"#, .emphasis),
        (#"_([^_]+)_"#, .emphasis),
        (#"~~([^~]+)~~"#, .strikethrough),
        (#"\[([^\]]+)\]\(([^)]+)\)"#, .link),
    ]

    /// 预编译内联正则（避免流式渲染时反复编译）
    private static let compiledInline: [(regex: NSRegularExpression, kind: InlineKind)] = inlinePatterns.compactMap { item in
        guard let regex = try? NSRegularExpression(pattern: item.regex) else { return nil }
        return (regex, item.kind)
    }

    private enum InlineKind { case strong, emphasis, code, strikethrough, math, link }

    static func parseInline(_ text: String) -> AttributedString {
        var result = AttributedString()
        // 性能：在 text 上滑动搜索起点，而不是像旧实现那样每匹配一轮
        // `String(remaining)` 拷贝一次剩余全文（长段落 + 多内联标记时是
        // O(全文长 × 匹配数) 的重复拷贝）。NSRange 始终以 text 的索引空间计算。
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            // 找到最早匹配
            var best: (range: Range<String.Index>, kind: InlineKind, groups: [String])?
            let nsRange = NSRange(searchStart..<text.endIndex, in: text)
            for pattern in compiledInline {
                guard let match = pattern.regex.firstMatch(in: text, range: nsRange) else { continue }
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let groups = (0..<match.numberOfRanges).compactMap { idx -> String? in
                    guard let r = Range(match.range(at: idx), in: text) else { return nil }
                    return String(text[r])
                }
                if best == nil || swiftRange.lowerBound < best!.range.lowerBound {
                    best = (swiftRange, pattern.kind, groups)
                }
            }

            guard let found = best else {
                result.append(AttributedString(String(text[searchStart...])))
                break
            }

            // 匹配前文本
            if found.range.lowerBound > searchStart {
                result.append(AttributedString(String(text[searchStart..<found.range.lowerBound])))
            }

            switch found.kind {
            case .strong:
                let inner = parseInline(found.groups.count > 1 ? found.groups[1] : "")
                result.append(styled(inner, intent: .stronglyEmphasized))
            case .emphasis:
                let inner = parseInline(found.groups.count > 1 ? found.groups[1] : "")
                result.append(styled(inner, intent: .emphasized))
            case .code:
                let code = found.groups.count > 1 ? found.groups[1] : ""
                result.append(styled(AttributedString(code), intent: .code))
            case .strikethrough:
                let inner = parseInline(found.groups.count > 1 ? found.groups[1] : "")
                var a = inner
                a.strikethroughStyle = .single
                result.append(a)
            case .math:
                let tex = found.groups.count > 1 ? found.groups[1] : ""
                var a = AttributedString(tex)
                a.font = .system(.body, design: .serif).italic()
                a.backgroundColor = .gray.opacity(0.15)
                result.append(a)
            case .link:
                if found.groups.count >= 3 {
                    var a = parseInline(found.groups[1])
                    if let url = URL(string: found.groups[2]) {
                        a.link = url
                    }
                    result.append(a)
                }
            }

            searchStart = found.range.upperBound
        }

        return result
    }

    private static func styled(_ attr: AttributedString, intent: InlinePresentationIntent) -> AttributedString {
        var a = attr
        if let existing = a.inlinePresentationIntent {
            a.inlinePresentationIntent = existing.union(intent)
        } else {
            a.inlinePresentationIntent = intent
        }
        return a
    }
}

// MARK: - SwiftUI 渲染视图

struct MarkdownView: View {
    let markdown: String
    @Environment(\.colorScheme) private var colorScheme

    private var blocks: [MarkdownBlock] { MarkdownRenderer.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .fontWeight(headingWeight(level))
                .padding(.top, level == 1 ? 4 : 2)
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .quote(let text):
            Text(text)
                .font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: ordered ? 26 : 12, alignment: .leading)
                        Text(item)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .table(let headers, let rows):
            TableView(headers: headers, rows: rows)
        case .divider:
            Divider()
        case .mathBlock(let tex):
            Text(tex)
                .font(.system(.body, design: .serif).italic())
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    private func headingWeight(_ level: Int) -> Font.Weight {
        level <= 3 ? .bold : .semibold
    }
}

// MARK: - 代码块（语言标签 + 复制按钮）

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                    #endif
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().opacity(0.3)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(
            (Color(uiColor: .systemGray6)).opacity(colorScheme == .dark ? 0.4 : 0.7),
            in: .rect(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    @Environment(\.colorScheme) private var colorScheme
}

// MARK: - 表格

private struct TableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表头
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(h)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            .background(.quaternary.opacity(0.5))

            Divider()

            // 表体
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                }
                Divider().opacity(0.2)
            }
        }
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .clipShape(.rect(cornerRadius: 10))
    }
}
