import Foundation

/// 用户文件工作区（App 沙盒 `Documents/Files`）。
///
/// 设计取舍：
///  - **只有这一棵目录树**。所有路径都先 `resolve` 成 root 下的绝对路径，
///    任何 `..` / 绝对路径 / 符号链接逃逸都会被拒绝。AI 拿不到 App 的其他私有目录
///    （模型权重、聊天记录、笔记），也就没法在一轮幻觉里把用户的东西删掉。
///  - **同步 API + `NSLock`**，不是 `@MainActor`：调用点（工具执行、分享面板导入）
///    本来就在主线程上，把整棵类的隔离域抬到 MainActor 只会让每个调用点都要 `await`，
///    却在语义上没有任何收益 —— 这里没有 UI 状态，只有磁盘。
///  - **非 Sendable 的共享状态只有 `_logs`**，用锁保护；其余全是纯函数式的磁盘访问。
final class FileManagerService: @unchecked Sendable {

    static let shared = FileManagerService()

    // MARK: - 目录

    /// 工作区根目录：`Documents/Files`。
    ///
    /// 为什么不直接用 `Documents`：那一层平铺着模型权重、聊天存档、笔记等 App 自己的东西。
    /// 给 AI 一个"能读能写能列"的根，等于把这些一起交出去 —— 列目录时会看到
    /// `Models/` 里几个 GB 的文件名，读文件时可能读到聊天记录。隔一层子目录，
    /// 能力范围就和用户能看懂的"我的文件"完全对齐。
    let root: URL = {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Files", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 单次读取的默认行数上限。防止模型 `read` 一个几万行的文件把上下文顶爆。
    static let defaultReadLimit = 200
    /// 单次写入的字节上限（2 MB）。文本编辑够用，同时挡住"把整个模型写进笔记"。
    static let maxWriteBytes = 2 * 1024 * 1024

    // MARK: - 操作日志

    private let lock = NSLock()
    private var _logs: [String] = []

    /// 最近的操作记录（最新的在前），供 UI 展示与排错。
    var logs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _logs
    }

    private func record(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _logs.insert(line, at: 0)
        if _logs.count > 200 { _logs.removeLast(_logs.count - 200) }
    }

    // MARK: - 错误

    enum FileError: LocalizedError {
        case badPath(String)
        case outsideRoot(String)
        case notFound(String)
        case isDirectory(String)
        case notDirectory(String)
        case tooLarge(Int)
        case notText(String)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .badPath(let p):     return "路径不合法: \(p)"
            case .outsideRoot(let p): return "路径超出了文件工作区: \(p)"
            case .notFound(let p):    return "文件不存在: \(p)"
            case .isDirectory(let p): return "这是一个目录而不是文件: \(p)"
            case .notDirectory(let p):return "这是一个文件而不是目录: \(p)"
            case .tooLarge(let n):    return "内容太大（\(n) 字节，上限 \(FileManagerService.maxWriteBytes) 字节）"
            case .notText(let p):     return "不是文本文件（二进制或编码无法识别）: \(p)"
            case .io(let m):          return m
            }
        }
    }

    // MARK: - 路径解析

    /// 把模型给的相对路径解析成 root 下的绝对路径，并挡住越界。
    ///
    /// 非法输入的三种形态都必须在这里被拦下，而不是靠调用方自觉：
    ///   1. 绝对路径（`/etc/passwd`）—— `appendingPathComponent` 会直接拼出一串怪路径；
    ///   2. `..` 上跳 —— 解析后前缀不再等于 root；
    ///   3. 空路径 —— 表示 root 本身，语义上应由具体操作决定要不要允许。
    func resolve(_ relative: String) throws -> URL {
        var cleaned = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("/") { cleaned.removeFirst() }
        // 统一去掉 "files/" 前缀：模型经常会照工具说明把根目录名也写进去
        let lowered = cleaned.lowercased()
        for prefix in ["documents/files/", "files/"] where lowered.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
            break
        }
        guard !cleaned.isEmpty, !cleaned.contains("\0") else {
            throw FileError.badPath(relative)
        }

        let candidate = URL(fileURLWithPath: cleaned, relativeTo: root)
            .standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.path
        // 必须严格落在 root 之内（相等表示 root 本身）
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw FileError.outsideRoot(relative)
        }
        return candidate
    }

    /// 相对 root 的展示路径（用于返回给模型/界面）。
    func displayPath(_ url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        var rel = String(path.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? "." : rel
    }

    // MARK: - 列目录

    struct Entry {
        let path: String
        let isDirectory: Bool
        let bytes: Int
        let modified: Date?
    }

    /// 列出工作区内容。`path` 为空/`.` 表示根目录。
    ///
    /// 只列一层（不递归）：递归列出在文件一多的时候会变成几百行噪音，
    /// 而模型真正需要的是"这一层有什么"，需要更深就再 list 一次 ——
    /// 与人类用 `ls` 的习惯一致。
    func list(_ path: String = "") throws -> [Entry] {
        let target = try resolve(path.isEmpty ? "." : path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            throw FileError.notFound(path.isEmpty ? "." : path)
        }
        guard isDir.boolValue else { throw FileError.notDirectory(path) }

        let urls = try FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])

        return urls.map { url in
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return Entry(
                path: displayPath(url),
                isDirectory: values?.isDirectory ?? false,
                bytes: values?.fileSize ?? 0,
                modified: values?.contentModificationDate)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    // MARK: - 读

    /// 读取文本文件，带行区间。返回 `(内容, 总行数, 实际返回的起始行)`。
    func read(_ path: String, offset: Int = 1, limit: Int = FileManagerService.defaultReadLimit) throws -> (text: String, totalLines: Int, startLine: Int) {
        let url = try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileError.notFound(path)
        }
        guard !isDir.boolValue else { throw FileError.isDirectory(path) }

        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw FileError.io("读取失败: \(error.localizedDescription)") }

        guard let text = String(data: data, encoding: .utf8) else {
            throw FileError.notText(path)
        }

        let allLines = text.components(separatedBy: "\n")
        let total = allLines.count
        let start = max(1, offset)
        let count = max(1, min(limit, total))
        guard start <= total else { return ("", total, start) }
        let slice = allLines[(start - 1)..<min(start - 1 + count, total)]
        return (slice.joined(separator: "\n"), total, start)
    }

    // MARK: - 写

    /// 新建或整体覆盖一个文本文件（父目录不存在时自动建）。
    @discardableResult
    func write(_ path: String, content: String) throws -> Int {
        let url = try resolve(path)
        let bytes = content.lengthOfBytes(using: .utf8)
        guard bytes <= Self.maxWriteBytes else { throw FileError.tooLarge(bytes) }

        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw FileError.io("写入失败: \(error.localizedDescription)")
        }
        record("写入 \(displayPath(url))（\(bytes) 字节）")
        return bytes
    }

    /// 追加到文件末尾（不存在则创建）。
    @discardableResult
    func append(_ path: String, content: String) throws -> Int {
        let url = try resolve(path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let combined = existing + content
        let bytes = combined.lengthOfBytes(using: .utf8)
        guard bytes <= Self.maxWriteBytes else { throw FileError.tooLarge(bytes) }
        return try write(path, content: combined)
    }

    // MARK: - 目录 / 移动 / 删除

    func makeDirectory(_ path: String) throws {
        let url = try resolve(path)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw FileError.io("建目录失败: \(error.localizedDescription)")
        }
        record("新建目录 \(displayPath(url))")
    }

    /// 移动或重命名。`to` 同样必须落在工作区内。
    func move(_ path: String, to destination: String) throws {
        let from = try resolve(path)
        let to = try resolve(destination)
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw FileError.notFound(path)
        }
        let parent = to.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: to.path) {
            throw FileError.io("目标已存在: \(destination)")
        }
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            throw FileError.io("移动失败: \(error.localizedDescription)")
        }
        record("移动 \(displayPath(from)) → \(displayPath(to))")
    }

    /// 删除文件或目录（目录连同内容一起删）。
    func delete(_ path: String) throws {
        let url = try resolve(path)
        guard url.standardizedFileURL.path != root.standardizedFileURL.path else {
            throw FileError.badPath("不能删除工作区根目录")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileError.notFound(path)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FileError.io("删除失败: \(error.localizedDescription)")
        }
        record("删除 \(displayPath(url))")
    }

    /// 文件/目录信息。
    func stat(_ path: String) throws -> String {
        let url = try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileError.notFound(path)
        }
        let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [
            "路径: \(displayPath(url))",
            "类型: \(isDir.boolValue ? "目录" : "文件")"
        ]
        if !isDir.boolValue {
            lines.append("大小: \(values?.fileSize ?? 0) 字节")
            lines.append("可读文本: \((try? read(path, offset: 1, limit: 1)) != nil ? "是" : "否")")
        }
        if let modified = values?.contentModificationDate {
            lines.append("修改时间: \(formatter.string(from: modified))")
        }
        if let created = values?.creationDate {
            lines.append("创建时间: \(formatter.string(from: created))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 外部导入

    /// 把外部来源（分享面板 / 文件选择器）的文件拷进工作区。
    ///
    /// 安全作用域资源必须在这里成对开合：分享进来的 URL 在 App 沙盒外，
    /// 不开作用域读到的会是权限错误，而不是"文件不存在" —— 两者在日志里长得一样，
    /// 所以这里分开报错。
    @discardableResult
    func importExternal(_ source: URL, preferredPath: String? = nil) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data: Data
        do { data = try Data(contentsOf: source) }
        catch {
            throw FileError.io(scoped
                ? "读取失败: \(error.localizedDescription)"
                : "无法访问该文件（未取得访问授权）: \(source.lastPathComponent)")
        }

        let relative = preferredPath ?? source.lastPathComponent
        let url = try resolve(relative)
        if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do { try data.write(to: url, options: .atomic) }
        catch { throw FileError.io("写入失败: \(error.localizedDescription)") }

        record("导入 \(source.lastPathComponent) → \(displayPath(url))")
        return displayPath(url)
    }

    /// 把工作区里的文件导出到外部 URL（写进"文件"App / 分享目标）。
    func export(_ path: String, to destination: URL) throws {
        let url = try resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileError.notFound(path)
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw FileError.io("导出失败: \(error.localizedDescription)")
        }
        record("导出 \(displayPath(url)) → \(destination.lastPathComponent)")
    }
}
