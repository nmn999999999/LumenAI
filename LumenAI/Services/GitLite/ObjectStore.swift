import Foundation
import CryptoKit

/// git 的可恢复错误。文案给**模型/用户**看，因此直接写中文，
/// 并且刻意模仿 git 的措辞（"nothing to commit" / "pathspec ... did not match"），
/// 让模型能把 `shell` 里的这段输出当成真正的 git 输出来判断下一步。
enum GitError: Error, CustomStringConvertible {
    case notARepo(String)
    case notGitDir(String)
    case unknownRevision(String)
    case pathspecMismatch(String)
    case nothingToCommit(String)
    case corrupt(String)
    case unsupported(String)
    case invalidArgument(String)

    var description: String {
        switch self {
        case .notARepo(let p):
            return "fatal: not a git repository (or any of the parent directories): \(p)"
        case .notGitDir(let p):
            return "fatal: not a git directory: \(p)"
        case .unknownRevision(let r):
            return "fatal: bad revision '\(r)'"
        case .pathspecMismatch(let p):
            return "fatal: pathspec '\(p)' did not match any files"
        case .nothingToCommit(let hint):
            return "nothing to commit" + (hint.isEmpty ? "" : " (\(hint))")
        case .corrupt(let detail):
            return "error: corrupt git object: \(detail)"
        case .unsupported(let detail):
            return "error: 本 App 内置的 git 子集暂不支持该操作：\(detail)"
        case .invalidArgument(let detail):
            return "error: \(detail)"
        }
    }
}

/// 对象存储（`.git/objects`，loose object）。
///
/// 对象内容 = `"<类型> <字节数>\0<负载>"`，SHA-1 取这段整体的哈希，
/// 落盘时整段做 zlib 压缩，路径按 `objects/<前2位>/<后38位>` 分片 —— 三者都必须与
/// 真实 git 完全一致，否则外部 `git fsck` / `git clone` 读不了我们写的库。
struct ObjectStore {

    let objectsDir: String

    // MARK: - 哈希

    /// `"<type> <len>\0<payload>"` 的 SHA-1（hex）。git 对象 id 的定义就是它。
    static func hash(kind: String, payload: Data) -> String {
        let header = "\(kind) \(payload.count)\0"
        var buf = Data(header.utf8)
        buf.append(payload)
        return sha1Hex(buf)
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 校验字符串是不是 40 位 hex（我们只支持 SHA-1 对象，sha256 仓库直接拒掉）。
    static func isHexID(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy { $0.isHexDigit }
    }

    // MARK: - 路径

    private func path(for shaHex: String) -> String {
        let first = NSString(string: objectsDir).appendingPathComponent(String(shaHex.prefix(2)))
        return NSString(string: first).appendingPathComponent(String(shaHex.dropFirst(2)))
    }

    func exists(_ shaHex: String) -> Bool {
        guard Self.isHexID(shaHex) else { return false }
        return FileManager.default.fileExists(atPath: path(for: shaHex))
    }

    // MARK: - 读写

    /// 写入并返回对象 id。已存在则直接返回（幂等，重复 add/commit 不会堆垃圾）。
    @discardableResult
    func write(kind: String, payload: Data) throws -> String {
        let sha = Self.hash(kind: kind, payload: payload)
        let target = path(for: sha)
        if FileManager.default.fileExists(atPath: target) { return sha }

        let header = "\(kind) \(payload.count)\0"
        var raw = Data(header.utf8)
        raw.append(payload)
        guard let packed = GitZlib.compress(raw) else {
            throw GitError.corrupt("zlib 压缩失败（\(kind) \(payload.count) 字节）")
        }
        let dir = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 先写临时文件再改名：中途被杀（iOS 后台回收是常事）不会留下半截对象 ——
        // 半截对象会让后续 `git fsck` 报 corrupt，而用户根本不知道是哪次写坏的。
        let tmp = target + ".tmp-\(UUID().uuidString.prefix(8))"
        do {
            try packed.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            try FileManager.default.moveItem(atPath: tmp, toPath: target)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw GitError.corrupt("写入 \(kind) 对象失败：\(error.localizedDescription)")
        }
        return sha
    }

    /// 读取对象。返回类型与负载（已剥掉头部）。
    func read(_ shaHex: String) throws -> (kind: String, payload: Data) {
        guard Self.isHexID(shaHex) else { throw GitError.unknownRevision(shaHex) }
        let file = path(for: shaHex)
        guard let packed = FileManager.default.contents(atPath: file) else {
            throw GitError.corrupt("找不到对象 \(shaHex)")
        }
        guard let raw = GitZlib.decompress(packed) else {
            throw GitError.corrupt("对象 \(shaHex) 解压失败")
        }
        guard let nul = raw.firstIndex(of: 0), nul < raw.endIndex else {
            throw GitError.corrupt("对象 \(shaHex) 缺少类型头")
        }
        let header = String(decoding: raw[..<nul], as: UTF8.self)
        guard let sp = header.firstIndex(of: " ") else {
            throw GitError.corrupt("对象 \(shaHex) 头部格式错误：\(header)")
        }
        let kind = String(header[..<sp])
        let declared = Int(header[header.index(after: sp)...]) ?? -1
        let payload = raw[raw.index(after: nul)...]
        guard declared == payload.count else {
            throw GitError.corrupt("对象 \(shaHex) 长度不符（声明 \(declared)，实际 \(payload.count)）")
        }
        // 顺手校验哈希：对象文件可能被外部工具改过 / 存储出错。
        // 早失败比"拿坏数据继续建树"好得多 —— 后者会一路错到 commit 才爆。
        if Self.hash(kind: kind, payload: payload) != shaHex.lowercased() {
            throw GitError.corrupt("对象 \(shaHex) 内容与 id 不匹配")
        }
        return (kind, payload)
    }
}

// MARK: - tree 对象

/// tree 里的一条记录。`mode` 是 6 位八进制字符串（"100644" / "40000" / "100755"）。
struct GitTreeEntry: Equatable {
    var mode: String
    var name: String
    var sha: String

    var isTree: Bool { mode == "40000" || mode == "040000" }

    /// tree 对象里的原始字节：`<mode> <name>\0<20字节id>`（mode 不带前导 0，"40000" 而非 "040000"）。
    var encoded: Data {
        var d = Data("\(normalizedMode) \(name)\0".utf8)
        d.append(contentsOf: Self.hexToBytes(sha))
        return d
    }

    /// git 写 tree 时用的规范形式：目录是 "40000"，文件是 "100644"/"100755"（无前导零）。
    var normalizedMode: String {
        if isTree { return "40000" }
        return mode
    }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return out
    }
}

enum GitTreeCoder {
    static func encode(_ entries: [GitTreeEntry]) -> Data {
        // git 要求 tree 条目按"目录名后带 '/' 再比较"的规则排序：
        // 即 `foo.txt` 与 `foo/` 比较时，前者按 "foo.txt"、后者按 "foo/" 比。
        // 少了这一条，真实 git 会认为 tree 没排序（fsck 报 "not properly sorted"）。
        let sorted = entries.sorted { lhs, rhs in
            let l = lhs.isTree ? lhs.name + "/" : lhs.name
            let r = rhs.isTree ? rhs.name + "/" : rhs.name
            return l.utf8.lexicographicallyPrecedes(r.utf8)
        }
        var d = Data()
        for e in sorted { d.append(e.encoded) }
        return d
    }

    static func decode(_ payload: Data) throws -> [GitTreeEntry] {
        var entries = [GitTreeEntry]()
        var i = payload.startIndex
        while i < payload.endIndex {
            guard let space = payload[i...].firstIndex(of: 0x20) else {
                throw GitError.corrupt("tree 缺少 mode/name 分隔符")
            }
            let mode = String(decoding: payload[i..<space], as: UTF8.self)
            guard let nul = payload[payload.index(after: space)...].firstIndex(of: 0) else {
                throw GitError.corrupt("tree 条目缺少名字终止符")
            }
            let nameStart = payload.index(after: space)
            let name = String(decoding: payload[nameStart..<nul], as: UTF8.self)
            let shaStart = payload.index(after: nul)
            guard payload.distance(from: shaStart, to: payload.endIndex) >= 20 else {
                throw GitError.corrupt("tree 条目 \(name) 缺少对象 id")
            }
            let shaEnd = payload.index(shaStart, offsetBy: 20)
            let sha = payload[shaStart..<shaEnd].map { String(format: "%02x", $0) }.joined()
            entries.append(GitTreeEntry(mode: mode, name: name, sha: sha))
            i = shaEnd
        }
        return entries
    }
}

// MARK: - commit 对象

struct GitCommit {
    var tree: String
    var parents: [String]
    var author: String
    var committer: String
    var message: String

    /// 作者行的规范形式：`Name <email> <unix> +0800`。
    static func signature(name: String, email: String, time: Date, offsetSeconds: Int = 0) -> String {
        let secs = Int(time.timeIntervalSince1970)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let abs = abs(offsetSeconds)
        let oh = String(format: "%02d", abs / 3600)
        let om = String(format: "%02d", (abs % 3600) / 60)
        return name + " <" + email + "> " + String(secs) + " " + sign + oh + om
    }

    func encoded() -> Data {
        var s = "tree \(tree)\n"
        for p in parents { s += "parent \(p)\n" }
        s += "author \(author)\ncommitter \(committer)\n\n"
        // git 要求 message 以换行结尾（且不追加额外换行），否则 fsck 会警告。
        let msg = message.hasSuffix("\n") ? message : message + "\n"
        s += msg
        return Data(s.utf8)
    }

    static func decode(_ payload: Data, id: String) throws -> GitCommit {
        let text = String(decoding: payload, as: UTF8.self)
        guard let headerEnd = text.range(of: "\n\n") else {
            throw GitError.corrupt("commit \(id) 缺少头部/正文分隔")
        }
        var tree = ""
        var parents = [String]()
        var author = ""
        var committer = ""
        for line in text[..<headerEnd.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("tree ") { tree = String(line.dropFirst(5)) }
            else if line.hasPrefix("parent ") { parents.append(String(line.dropFirst(7))) }
            else if line.hasPrefix("author ") { author = String(line.dropFirst(7)) }
            else if line.hasPrefix("committer ") { committer = String(line.dropFirst(10)) }
            // 其它头（gpgsig / encoding / mergetag）暂时忽略 —— 我们不产生它们，
            // 读到时保留原文在父 commit 的情况下也不影响遍历。
        }
        guard !tree.isEmpty else { throw GitError.corrupt("commit \(id) 没有 tree") }
        let message = String(text[headerEnd.upperBound...])
        return GitCommit(tree: tree, parents: parents, author: author,
                         committer: committer, message: message)
    }

    /// 从 author/committer 行里取出名字（给 `git log` 用）。
    var authorName: String {
        if let lt = author.firstIndex(of: "<"), author.lastIndex(of: ">") != nil {
            return String(author[..<lt]).trimmingCharacters(in: .whitespaces)
        }
        return author
    }

    /// 从 author 行解析提交时间。
    var authorDate: Date? {
        guard let lt = author.lastIndex(of: ">") else { return nil }
        let rest = author[author.index(after: lt)...].split(separator: " ")
        guard let secs = rest.first.flatMap({ Int($0) }) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }
}
