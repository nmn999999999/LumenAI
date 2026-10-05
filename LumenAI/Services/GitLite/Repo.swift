import Foundation
import Darwin

/// 一个 git 仓库（worktree + `.git`）。
///
/// 为什么自己实现：iOS 不能 spawn 进程，系统里根本没有 `git` 二进制可调，
/// 所以 `shell` 里的 `git` 必须是内置的。实现范围是**能建库、能提交、能看历史**的
/// 最小真子集，但对象格式/索引格式与真实 git **逐位一致** —— 这是硬要求：
/// 用户总有一天会把仓库拷到 Mac 上用真 git 打开，半真不假的格式比没有 git 更糟。
///
/// 这个类型只依赖 Foundation，不碰 ShellSandbox，因此可以单独拿出来用真 `git fsck` 测试。
struct GitRepo {

    let workTree: String
    let gitDir: String

    // MARK: - 发现与初始化

    /// 从 `path` 逐级向上找 `.git`（与真实 git 一致：支持子目录里工作）。
    static func find(startingAt path: String) throws -> GitRepo {
        var dir = (path as NSString).standardizingPath
        while true {
            let candidate = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir) {
                if isDir.boolValue {
                    return GitRepo(workTree: dir, gitDir: candidate)
                }
                // worktree/submodule 形式的 `.git` 是个文件（内容是 gitdir: ...）
                if let text = try? String(contentsOfFile: candidate, encoding: .utf8),
                   text.hasPrefix("gitdir: ") {
                    let inner = text.dropFirst("gitdir: ".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = inner.hasPrefix("/")
                        ? inner
                        : (dir as NSString).appendingPathComponent(inner)
                    if FileManager.default.fileExists(atPath: resolved) {
                        return GitRepo(workTree: dir, gitDir: resolved)
                    }
                }
                throw GitError.notGitDir(candidate)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        throw GitError.notARepo(path)
    }

    /// `git init`：建出真实 git 认得的最小目录结构。
    static func initRepo(at path: String) throws -> GitRepo {
        let fm = FileManager.default
        let gitDir = (path as NSString).appendingPathComponent(".git")
        let objects = (gitDir as NSString).appendingPathComponent("objects")
        let refs = (gitDir as NSString).appendingPathComponent("refs")
        for d in [gitDir, objects, refs,
                  (refs as NSString).appendingPathComponent("heads"),
                  (refs as NSString).appendingPathComponent("tags"),
                  (gitDir as NSString).appendingPathComponent("info"),
                  (gitDir as NSString).appendingPathComponent("hooks"),
                  (gitDir as NSString).appendingPathComponent("logs")] {
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        // HEAD 指向默认分支；用 main 与现实默认一致（老 git 的 master 会让模型困惑）。
        if !fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent("HEAD")) {
            try "ref: refs/heads/main\n".write(
                toFile: (gitDir as NSString).appendingPathComponent("HEAD"),
                atomically: true, encoding: .utf8)
        }
        let config = """
        [core]
        	repositoryformatversion = 0
        	filemode = true
        	bare = false
        	logallrefupdates = true
        [init]
        	defaultBranch = main
        """
        try config.write(toFile: (gitDir as NSString).appendingPathComponent("config"),
                         atomically: true, encoding: .utf8)
        try? "Unnamed repository; edit this file 'description' to name the repository.\n"
            .write(toFile: (gitDir as NSString).appendingPathComponent("description"),
                   atomically: true, encoding: .utf8)
        // exclude 文件存在时，真 git 会读它；先写空，省得它把我们的 .gitignore 规则搞混。
        try? "" .write(toFile: (gitDir as NSString).appendingPathComponent("info/exclude"),
                       atomically: true, encoding: .utf8)
        return GitRepo(workTree: path, gitDir: gitDir)
    }

    var objects: ObjectStore {
        ObjectStore(objectsDir: (gitDir as NSString).appendingPathComponent("objects"))
    }

    var indexFile: String { (gitDir as NSString).appendingPathComponent("index") }

    // MARK: - 引用

    enum Head {
        /// HEAD 指着还没创建过的分支（仓库刚 init、没提交）。
        case unborn(branch: String)
        case branch(name: String, ref: String, sha: String)
        case detached(sha: String)
    }

    func head() throws -> Head {
        let file = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let raw = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw GitError.notGitDir(gitDir)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref: ") {
            let ref = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
            if let sha = readRef(ref) { return .branch(name: name, ref: ref, sha: sha) }
            return .unborn(branch: name)
        }
        return .detached(sha: text)
    }

    func readRef(_ ref: String) -> String? {
        let direct = (gitDir as NSString).appendingPathComponent(ref)
        if let text = try? String(contentsOfFile: direct, encoding: .utf8) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ObjectStore.isHexID(t) { return t }
        }
        // packed-refs：真 git 会把冷引用打包进它，读引用必须两条路都走。
        let packed = (gitDir as NSString).appendingPathComponent("packed-refs")
        if let text = try? String(contentsOfFile: packed, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line.hasPrefix("#") || line.hasPrefix("^") { continue }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if String(parts[1]) == ref { return String(parts[0]) }
            }
        }
        return nil
    }

    func writeRef(_ ref: String, sha: String) throws {
        let path = (gitDir as NSString).appendingPathComponent(ref)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        // 引用文件必须以 LF 结尾，否则 `git fsck` 报 refMissingNewline（真 git 也这么写）。
        try (sha + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// HEAD 指向的 commit；无提交（unborn）返回 nil。
    func headCommit() throws -> String? {
        switch try head() {
        case .unborn: return nil
        case .branch(_, _, let sha): return sha
        case .detached(let sha): return sha
        }
    }

    func branchName() throws -> String {
        switch try head() {
        case .unborn(let b): return b
        case .branch(let n, _, _): return n
        case .detached: return "HEAD detached"
        }
    }

    /// 作者/提交者身份：先读 `.git/config` 的 user.*，没有就用环境/默认值。
    /// git 在缺 user.email 时会**拒绝提交**，我们放行但给个可辨识的默认身份 ——
    /// 手机上没有 `git config` 可跑，卡住只会让模型一直重试同一个失败。
    func identity() -> (name: String, email: String) {
        let config = (gitDir as NSString).appendingPathComponent("config")
        var name: String?
        var email: String?
        if let text = try? String(contentsOfFile: config, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("name") , let eq = t.firstIndex(of: "=") {
                    name = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                } else if t.hasPrefix("email"), let eq = t.firstIndex(of: "=") {
                    email = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        // iOS 拿不到 `ProcessInfo.userName`（该 API 在 iOS 上不可用），也没有
        // `git config user.name` 可跑。给个可辨识的中性身份，比让提交失败好 ——
        // 用户可以在 `.git/config` 里写 `name` / `email` 覆盖（上面的读取支持它）。
        return (name ?? "LumenAI User", email ?? "user@localhost")
    }

    // MARK: - 对象读取

    func readCommit(_ sha: String) throws -> GitCommit {
        let (kind, payload) = try objects.read(sha)
        guard kind == "commit" else {
            throw GitError.invalidArgument("\(sha) 是 \(kind)，不是 commit")
        }
        return try GitCommit.decode(payload, id: sha)
    }

    /// 把 tree 递归摊平成 `相对路径 → 条目`（只有文件，不含目录节点）。
    func flattenedTree(_ treeSHA: String, prefix: String = "") throws -> [String: GitTreeEntry] {
        let (kind, payload) = try objects.read(treeSHA)
        guard kind == "tree" else {
            throw GitError.invalidArgument("\(treeSHA) 是 \(kind)，不是 tree")
        }
        var out: [String: GitTreeEntry] = [:]
        for entry in try GitTreeCoder.decode(payload) {
            let full = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
            if entry.isTree {
                out.merge(try flattenedTree(entry.sha, prefix: full)) { _, new in new }
            } else {
                out[full] = entry
            }
        }
        return out
    }

    /// HEAD commit 对应的**文件**表；无提交返回空表。
    func headTree() throws -> [String: GitTreeEntry] {
        guard let sha = try headCommit() else { return [:] }
        let commit = try readCommit(sha)
        return try flattenedTree(commit.tree)
    }

    func readBlob(_ sha: String) throws -> Data {
        let (kind, payload) = try objects.read(sha)
        guard kind == "blob" else {
            throw GitError.invalidArgument("\(sha) 是 \(kind)，不是 blob")
        }
        return payload
    }

    // MARK: - 由 index 建 tree

    /// 把暂存区条目建构成 tree（递归建子目录 tree），返回根 tree 的 id。
    /// 目录条目的 mode 写 "40000"（git 的规范是**不带前导 0**）。
    func writeTree(from entries: [GitIndexEntry]) throws -> String {
        struct Node { var dirs: [String: Node] = [:]; var files: [(String, GitIndexEntry)] = [] }

        func insert(_ node: inout Node, parts: ArraySlice<String>, entry: GitIndexEntry) {
            guard let first = parts.first else { return }
            if parts.count == 1 {
                node.files.append((first, entry))
            } else {
                var child = node.dirs[first] ?? Node()
                insert(&child, parts: parts.dropFirst(), entry: entry)
                node.dirs[first] = child
            }
        }

        func emit(_ node: Node) throws -> String {
            var treeEntries = [GitTreeEntry]()
            for (name, entry) in node.files {
                treeEntries.append(GitTreeEntry(mode: String(entry.mode, radix: 8),
                                               name: name, sha: entry.sha))
            }
            for (name, child) in node.dirs {
                let sha = try emit(child)
                treeEntries.append(GitTreeEntry(mode: "40000", name: name, sha: sha))
            }
            let payload = GitTreeCoder.encode(treeEntries)
            return try objects.write(kind: "tree", payload: payload)
        }

        var root = Node()
        for e in entries where !e.path.isEmpty {
            insert(&root, parts: e.path.split(separator: "/").map(String.init)[...], entry: e)
        }
        return try emit(root)
    }

    // MARK: - 忽略规则（.gitignore + .git/info/exclude）

    private func ignorePatterns() -> [String] {
        var out = [String]()
        for file in [(workTree as NSString).appendingPathComponent(".gitignore"),
                     (gitDir as NSString).appendingPathComponent("info/exclude")] {
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    var p = String(line)
                    if p.hasPrefix("#") { continue }
                    p = p.trimmingCharacters(in: .whitespaces)
                    if p.isEmpty { continue }
                    out.append(String(p))
                }
            }
        }
        return out
    }

    /// 把 gitignore 通配符转成正则。`*` 不跨 `/`，`**` 跨 —— 这是 git 的语义，
    /// 直接用 `fnmatch`（`*` 跨路径分隔符）会把 `build/*.o` 错误地应用到整棵子树。
    private func ignoreRegex(for pattern: String) -> NSRegularExpression? {
        var pat = pattern
        var anchored = pat.hasPrefix("/")
        if anchored { pat.removeFirst() }
        let dirOnly = pat.hasSuffix("/")
        if dirOnly { pat.removeLast() }

        var re = ""
        var i = pat.startIndex
        while i < pat.endIndex {
            let c = pat[i]
            if c == "*" {
                if pat.index(after: i) < pat.endIndex, pat[pat.index(after: i)] == "*" {
                    re += ".*"
                    i = pat.index(i, offsetBy: 2)
                    if i < pat.endIndex, pat[i] == "/" { i = pat.index(after: i) }
                    continue
                }
                re += "[^/]*"
            } else if c == "?" {
                re += "[^/]"
            } else if "\\.+^$|()[]{}".contains(c) {
                re += "\\" + String(c)
            } else {
                re += String(c)
            }
            i = pat.index(after: i)
        }
        // 含 `/` 的模式（去掉尾斜杠后）按**整条路径**匹配；否则按任意目录层级的
        // 文件名匹配（`*.log` 应该命中 `a/b/c.log`）。
        if pat.contains("/") { anchored = true }
        let body = dirOnly ? re + "(/.*)?" : re
        let full = anchored ? "^\(body)$" : "(^|/)\(body)(/|$)"
        return try? NSRegularExpression(pattern: full)
    }

    /// 是否被忽略（只对**已存在的文件**问；目录在扫描时整棵跳过）。
    func isIgnored(_ relPath: String) -> Bool {
        for pattern in ignorePatterns() {
            guard let re = ignoreRegex(for: pattern) else { continue }
            let range = NSRange(relPath.startIndex..., in: relPath)
            if re.firstMatch(in: relPath, range: range) != nil { return true }
        }
        return false
    }

    // MARK: - 工作区扫描

    /// 列出工作区所有**受版本控制可能性**的文件（相对路径），跳过 `.git` 与被忽略的。
    func workFiles(skipIgnored: Bool = true) -> [String] {
        var out = [String]()
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: workTree) else { return out }
        while let item = en.nextObject() as? String {
            let rel = item as NSString
            if rel.pathComponents.first == ".git" { en.skipDescendants(); continue }
            var isDir: ObjCBool = false
            let abs = (workTree as NSString).appendingPathComponent(item)
            guard fm.fileExists(atPath: abs, isDirectory: &isDir) else { continue }
            if isDir.boolValue { continue }
            if skipIgnored && isIgnored(item) { continue }
            out.append(item)
        }
        return out
    }
}
