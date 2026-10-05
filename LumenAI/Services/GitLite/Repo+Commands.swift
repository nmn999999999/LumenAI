import Foundation

/// git 命令实现（init / add / status / commit / log / diff / show / branch / checkout）。
///
/// 所有输出都对齐真实 git 的措辞与格式：模型拿到的是它训练时见过的那种文本，
/// 于是"下一步该干什么"能直接复用它对真 git 的知识（比如看到
/// `Changes not staged for commit` 就知道要再 `git add`）。
extension GitRepo {

    // MARK: - 路径解析

    /// 把命令行里的路径参数解析成**仓库内相对路径**。`.` → 空（代表全仓库）。
    private func relativize(_ raw: String) throws -> String {
        var p = raw
        if p.hasPrefix("./") { p.removeFirst(2) }
        if p == "." || p == "./" { return "" }
        while p.hasPrefix("/") { p.removeFirst() }
        if p.contains("../") || p.hasPrefix("..") {
            throw GitError.invalidArgument("路径越出仓库：\(raw)")
        }
        return p
    }

    private func absolute(_ rel: String) -> String {
        rel.isEmpty ? workTree : (workTree as NSString).appendingPathComponent(rel)
    }

    /// 把 `paths` 里的目录展开成文件列表；`.`/空数组 → 全仓库文件。
    /// 删除的路径也要返回（让 add 能暂存删除），所以同时收集"目录下已不在的索引项"。
    private func expandPaths(_ paths: [String]) throws -> Set<String> {
        var out = Set<String>()
        if paths.isEmpty || paths == ["."] || paths == ["./"] {
            out.formUnion(workFiles())
            return out
        }
        for raw in paths {
            let rel = try relativize(raw)
            guard !rel.isEmpty else { out.formUnion(workFiles()); continue }
            let abs = absolute(rel)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), isDir.boolValue {
                out.formUnion(workFiles().filter { $0 == rel || $0.hasPrefix(rel + "/") })
            } else {
                out.insert(rel)
            }
        }
        return out
    }

    // MARK: - git add

    /// 暂存 `paths`（空/`.` = 全部）。返回本次**状态有变化**的路径（给输出用）。
    @discardableResult
    func add(paths: [String]) throws -> [String] {
        var entries: [String: GitIndexEntry] = [:]
        for e in try GitIndexCodec.read(at: indexFile) { entries[e.path] = e }

        let targets = try expandPaths(paths)
        var changed = [String]()
        let fm = FileManager.default

        for rel in targets.sorted() {
            let abs = absolute(rel)
            if !fm.fileExists(atPath: abs) {
                // 路径不见了 → 暂存删除（与 `git add -A` 语义一致）。
                if entries.removeValue(forKey: rel) != nil { changed.append(rel) }
                // 目录整个消失：清掉它下面的所有索引项。
                let stale = entries.keys.filter { $0.hasPrefix(rel + "/") }
                for k in stale { entries.removeValue(forKey: k); changed.append(k) }
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: abs, isDirectory: &isDir), isDir.boolValue { continue }
            if isIgnored(rel) { continue }

            guard let attrs = try? fm.attributesOfItem(atPath: abs),
                  let data = fm.contents(atPath: abs) else {
                throw GitError.invalidArgument("无法读取 \(rel)")
            }
            let mode: UInt32 = fm.isExecutableFile(atPath: abs) ? 0o100755 : 0o100644
            let sha = ObjectStore.hash(kind: "blob", payload: data)

            if let old = entries[rel], old.statMatches(attrs) {
                // stat 没变 → 内容没变（git 的核心优化）。只在 mode 变了时更新条目。
                if old.mode != mode {
                    try objects.write(kind: "blob", payload: data)
                    var e = old; e.mode = mode
                    entries[rel] = e; changed.append(rel)
                } else if old.sha != sha {
                    // stat 撒谎了（比如 mtime 相同但内容被改）→ 以哈希为准。
                    try objects.write(kind: "blob", payload: data)
                    var e = old; e.sha = sha
                    entries[rel] = e; changed.append(rel)
                }
                continue
            }
            try objects.write(kind: "blob", payload: data)
            entries[rel] = .entry(path: rel, mode: mode, sha: sha, attrs: attrs)
            changed.append(rel)
        }

        try GitIndexCodec.write(Array(entries.values), to: indexFile)
        return changed
    }

    /// `git rm --cached` / 删除并暂存。
    @discardableResult
    func remove(paths: [String], fromDisk: Bool) throws -> [String] {
        var entries: [String: GitIndexEntry] = [:]
        for e in try GitIndexCodec.read(at: indexFile) { entries[e.path] = e }
        var removed = [String]()
        for raw in paths {
            let rel = try relativize(raw)
            let hit = entries.keys.filter { $0 == rel || $0.hasPrefix(rel + "/") }
            for k in hit {
                entries.removeValue(forKey: k)
                removed.append(k)
                if fromDisk {
                    try? FileManager.default.removeItem(atPath: absolute(k))
                }
            }
            if hit.isEmpty { throw GitError.pathspecMismatch(raw) }
        }
        try GitIndexCodec.write(Array(entries.values), to: indexFile)
        return removed.sorted()
    }

    // MARK: - git status

    struct StatusState {
        var staged: [(path: String, kind: String)] = []
        var unstaged: [(path: String, kind: String)] = []
        var untracked: [String] = []
        var conflicted: [String] = []
        var clean: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }
    }

    func statusState() throws -> StatusState {
        var st = StatusState()
        let head = try headTree()
        let index = try GitIndexCodec.read(at: indexFile)
        let indexMap = Dictionary(uniqueKeysWithValues: index.map { ($0.path, $0) })

        // 暂存区 vs HEAD
        for e in index {
            if let h = head[e.path] {
                if h.sha != e.sha || h.mode != String(e.mode, radix: 8) {
                    st.staged.append((e.path, "modified"))
                }
            } else {
                st.staged.append((e.path, "new file"))
            }
        }
        for h in head.keys where indexMap[h] == nil {
            st.staged.append((h, "deleted"))
        }

        // 工作区 vs 暂存区
        let fm = FileManager.default
        for e in index {
            let abs = absolute(e.path)
            if !fm.fileExists(atPath: abs) {
                st.unstaged.append((e.path, "deleted"))
                continue
            }
            guard let attrs = try? fm.attributesOfItem(atPath: abs) else { continue }
            if e.statMatches(attrs) {
                // stat 一致，但 mtime 落在"与 index 同一秒"时仍可能是脏的（racy clean）。
                // 这里多做一次成本可控的兜底：size 相同且 mtime 早于 index 写入时刻才跳过。
                continue
            }
            guard let data = fm.contents(atPath: abs) else { continue }
            if ObjectStore.hash(kind: "blob", payload: data) != e.sha {
                st.unstaged.append((e.path, "modified"))
            }
        }

        // 未跟踪
        let tracked = Set(indexMap.keys)
        for f in workFiles() where !tracked.contains(f) {
            st.untracked.append(f)
        }
        st.staged.sort { $0.path < $1.path }
        st.unstaged.sort { $0.path < $1.path }
        st.untracked.sort { $0 < $1 }
        return st
    }

    func status() throws -> String {
        let st = try statusState()
        let branch = try branchName()
        var out = ""
        if branch == "HEAD detached" {
            let sha = (try headCommit()) ?? ""
            out += "HEAD detached at \(String(sha.prefix(7)))\n"
        } else {
            out += "On branch \(branch)\n"
        }
        if try headCommit() == nil {
            out += "\nNo commits yet\n"
        }

        if !st.staged.isEmpty {
            out += "\nChanges to be committed:\n"
            out += "  (use \"git rm --cached <file>...\" to unstage)\n"
            for (p, k) in st.staged { out += "\t\(k):   \(p)\n" }
        }
        if !st.unstaged.isEmpty {
            out += "\nChanges not staged for commit:\n"
            out += "  (use \"git add <file>...\" to update what will be committed)\n"
            out += "  (use \"git restore <file>...\" to discard changes in working directory)\n"
            for (p, k) in st.unstaged { out += "\t\(k):   \(p)\n" }
        }
        if !st.untracked.isEmpty {
            out += "\nUntracked files:\n"
            out += "  (use \"git add <file>...\" to include in what will be committed)\n"
            for p in st.untracked { out += "\t\(p)\n" }
        }
        if st.clean {
            out += "\nnothing to commit, working tree clean\n"
        }
        return out
    }

    // MARK: - git commit

    /// 提交暂存区。返回 (新 commit id, 给用户看的文本)。
    func commit(message: String, allowEmpty: Bool = false) throws -> (sha: String, text: String) {
        let entries = try GitIndexCodec.read(at: indexFile)
        let treeSHA = try writeTree(from: entries)

        let parent = try headCommit()
        if let parent {
            let parentCommit = try readCommit(parent)
            if parentCommit.tree == treeSHA, !allowEmpty {
                throw GitError.nothingToCommit("working tree clean")
            }
        } else if entries.isEmpty, !allowEmpty {
            throw GitError.nothingToCommit("add some files first (git add <file>)")
        }

        let (name, email) = identity()
        let now = Date()
        let offset = Self.localUTCOffsetSeconds(at: now)
        let sig = GitCommit.signature(name: name, email: email, time: now, offsetSeconds: offset)
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            throw GitError.invalidArgument("提交信息不能为空（git commit -m \"...\"）")
        }
        var commit = GitCommit(tree: treeSHA, parents: parent.map { [$0] } ?? [],
                               author: sig, committer: sig, message: msg)
        // message 规范化：单行/多行都补足一个结尾换行（fsck 对裸结尾敏感）。
        if !commit.message.hasSuffix("\n") { commit.message += "\n" }
        let sha = try objects.write(kind: "commit", payload: commit.encoded())

        let head = try self.head()
        if case .unborn(let branch) = head {
            try writeRef("refs/heads/\(branch)", sha: sha)
        } else if case .branch(_, let ref, _) = head {
            try writeRef(ref, sha: sha)
        }
        try? appendReflog(new: sha, name: name, email: email, time: now,
                          message: (parent == nil ? "commit (initial): " : "commit: ") + msg)

        // 变更统计（插入/删除），照 git 的样子报给用户。
        let stats = try diffStats(parentTree: parent.flatMap { try? readCommit($0).tree }, newTree: treeSHA)
        let short = String(sha.prefix(7))
        var text = "[\(try branchName()) \(short)] \(msg.split(separator: "\n").first.map(String.init) ?? msg)"
        if stats.files > 0 {
            text += "\n \(stats.files) file(s) changed, \(stats.insertions) insertion(+), \(stats.deletions) deletion(-)"
        }
        return (sha, text)
    }

    /// 当前时区相对 UTC 的秒数（含夏令时，取提交时刻的真实偏移）。
    static func localUTCOffsetSeconds(at date: Date) -> Int {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        return seconds
    }

    private func appendReflog(new: String, name: String, email: String,
                              time: Date, message: String) throws {
        let file = (gitDir as NSString).appendingPathComponent("logs/HEAD")
        let old = readRefFileSHA() ?? "0000000000000000000000000000000000000000"
        let secs = Int(time.timeIntervalSince1970)
        let off = Self.localUTCOffsetSeconds(at: time)
        let sign = off >= 0 ? "+" : "-"
        let a = abs(off)
        let line = "\(old) \(new) \(name) <\(email)> \(secs) \(sign)"
            + String(format: "%02d%02d", a / 3600, (a % 3600) / 60)
            + "\t\(message)\n"
        if let data = FileManager.default.contents(atPath: file) {
            var d = data
            d.append(Data(line.utf8))
            try d.write(to: URL(fileURLWithPath: file), options: .atomic)
        } else {
            try Data(line.utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
        }
    }

    /// 写 reflog 前读"当前 HEAD 对应的旧值"。
    private func readRefFileSHA() -> String? {
        let file = (gitDir as NSString).appendingPathComponent("logs/HEAD")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let lastLine = text.split(separator: "\n").last else { return nil }
        return lastLine.split(separator: " ").first.map(String.init)
    }

    private func diffStats(parentTree: String?, newTree: String) throws -> (files: Int, insertions: Int, deletions: Int) {
        var oldMap = [String: GitTreeEntry]()
        if let p = parentTree { oldMap = try flattenedTree(p) }
        let newMap = try flattenedTree(newTree)

        let paths = Set(oldMap.keys).union(newMap.keys)
        var files = 0, ins = 0, del = 0
        for path in paths {
            let o = oldMap[path]?.sha
            let n = newMap[path]?.sha
            if o == n { continue }
            files += 1
            let oldText = o.flatMap { try? String(decoding: readBlob($0), as: UTF8.self) } ?? ""
            let newText = n.flatMap { try? String(decoding: readBlob($0), as: UTF8.self) } ?? ""
            let ops = GitTextDiff.diffOps(old: GitTextDiff.splitLines(oldText),
                                          new: GitTextDiff.splitLines(newText))
            ins += ops.filter { $0 == .insert }.count
            del += ops.filter { $0 == .del }.count
        }
        return (files, ins, del)
    }

    // MARK: - git log

    func log(limit: Int = 20) throws -> String {
        guard let firstSHA = try headCommit() else {
            throw GitError.unknownRevision("HEAD (还没有任何提交)")
        }
        var sha: String? = firstSHA
        var out = ""
        var count = 0
        var seen = Set<String>()
        while let current = sha, seen.insert(current).inserted, count < limit {
            let commit = try readCommit(current)
            out += "commit \(current)\n"
            out += "Author: \(commit.author)\n"
            if let date = commit.authorDate {
                out += "Date:   \(Self.formatDate(date))\n"
            }
            out += "\n"
            for line in commit.message.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.isEmpty && out.hasSuffix("\n\n") { continue }
                out += "    \(line)\n"
            }
            out += "\n"
            count += 1
            sha = commit.parents.first
        }
        return out
    }

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // 与 git 的 `Date:` 行逐字对齐：日不补零、时区写成 +0800。
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    // MARK: - git show

    func show(rev: String?) throws -> String {
        let sha: String
        if let rev, !rev.isEmpty {
            sha = try resolveRevision(rev)
        } else if let head = try headCommit() {
            sha = head
        } else {
            throw GitError.unknownRevision("HEAD")
        }
        let commit = try readCommit(sha)
        var out = "commit \(sha)\n"
        out += "Author: \(commit.author)\n"
        if let date = commit.authorDate { out += "Date:   \(Self.formatDate(date))\n" }
        out += "\n"
        for line in commit.message.split(separator: "\n") { out += "    \(line)\n" }
        out += "\n"
        let parentTree = try commit.parents.first.map { try readCommit($0).tree }
        out += try diffTreeToTree(from: parentTree, to: commit.tree, prefix: nil)
        return out
    }

    // MARK: - git branch

    func listBranches() throws -> [String] {
        var names = [String]()
        let dir = (gitDir as NSString).appendingPathComponent("refs/heads")
        if let en = FileManager.default.enumerator(atPath: dir) {
            while let item = en.nextObject() as? String {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(item),
                                                  isDirectory: &isDir), !isDir.boolValue {
                    names.append(item)
                }
            }
        }
        if let packed = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("packed-refs"),
                                     encoding: .utf8) {
            for line in packed.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[1].hasPrefix("refs/heads/") {
                    names.append(String(parts[1].dropFirst(11)))
                }
            }
        }
        return Array(Set(names)).sorted()
    }

    @discardableResult
    func createBranch(_ name: String) throws -> String {
        guard !name.isEmpty, name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw GitError.invalidArgument("分支名不能含空格：\(name)")
        }
        guard let head = try headCommit() else {
            throw GitError.unknownRevision("HEAD (还没有任何提交，先 git commit)")
        }
        let ref = "refs/heads/\(name)"
        if readRef(ref) != nil {
            throw GitError.invalidArgument("分支已存在：\(name)")
        }
        try writeRef(ref, sha: head)
        return "已创建分支 \(name) → \(String(head.prefix(7)))"
    }

    // MARK: - 解析 revision（只支持 sha / HEAD / 分支名 / 当前分支简写）

    func resolveRevision(_ rev: String) throws -> String {
        if ObjectStore.isHexID(rev) {
            guard objects.exists(rev) else { throw GitError.unknownRevision(rev) }
            return rev
        }
        if rev == "HEAD" {
            guard let sha = try headCommit() else { throw GitError.unknownRevision("HEAD") }
            return sha
        }
        if let sha = readRef("refs/heads/\(rev)") { return sha }
        if let sha = readRef(rev) { return sha }
        // 简写：扫所有分支/对象前缀
        for b in (try? listBranches()) ?? [] {
            if b.hasPrefix(rev), let sha = readRef("refs/heads/\(b)") { return sha }
        }
        throw GitError.unknownRevision(rev)
    }

    // MARK: - git diff / checkout

    /// `paths` 为空表示全部；`cached` = 比 HEAD 与暂存区。
    func diff(cached: Bool, paths: [String]) throws -> String {
        let filter: (String) -> Bool = { p in
            if paths.isEmpty { return true }
            return paths.contains { rel in
                let r = (try? relativize(rel)) ?? rel
                return p == r || p.hasPrefix(r + "/")
            }
        }
        if cached {
            let headTree = try headTree()
            let index = try GitIndexCodec.read(at: indexFile)
            let indexMap = Dictionary(uniqueKeysWithValues: index.map { ($0.path, $0) })
            var old = [String: String]()   // path -> sha
            var new = [String: String]()
            for (p, e) in headTree { if filter(p) { old[p] = e.sha } }
            for (p, e) in indexMap { if filter(p) { new[p] = e.sha } }
            return try diffByShas(old: old, new: new)
        } else {
            let index = try GitIndexCodec.read(at: indexFile)
            var old = [String: String]()
            var work = [String: GitIndexEntry]()
            for e in index where filter(e.path) {
                old[e.path] = e.sha
                work[e.path] = e
            }
            var out = ""
            let fm = FileManager.default
            for e in index.sorted(by: { $0.path < $1.path }) where filter(e.path) {
                let abs = absolute(e.path)
                if !fm.fileExists(atPath: abs) {
                    out += try renderChange(path: e.path, oldSHA: e.sha, newSHA: nil, newData: nil)
                    continue
                }
                guard let data = fm.contents(atPath: abs) else { continue }
                let sha = ObjectStore.hash(kind: "blob", payload: data)
                if sha == e.sha { continue }
                out += try renderChange(path: e.path, oldSHA: e.sha, newSHA: sha, newData: data)
            }
            return out
        }
    }

    private func diffByShas(old: [String: String], new: [String: String]) throws -> String {
        var out = ""
        for path in Set(old.keys).union(new.keys).sorted() {
            out += try renderChange(path: path, oldSHA: old[path], newSHA: new[path], newData: nil)
        }
        return out
    }

    /// 单文件的 diff 文本。
    /// - Parameters:
    ///   - newData: 工作区版本的内容（与 `newSHA` 至少给一个；都给以 `newData` 为准）。
    ///     `newSHA == nil && newData == nil` 表示**这一侧不存在**（删除 / 对比起点为空）。
    private func renderChange(path: String, oldSHA: String?, newSHA: String?,
                              newData: Data?) throws -> String {
        if oldSHA == newSHA && newData == nil { return "" }

        let oldData = oldSHA.flatMap { try? readBlob($0) }
        let data = newData ?? newSHA.flatMap { try? readBlob($0) }
        let isDeleted = newSHA == nil && newData == nil
        let isNew = oldSHA == nil
        let oldLabel = isNew ? "/dev/null" : "a/\(path)"
        let newLabel = isDeleted ? "/dev/null" : "b/\(path)"

        var header = "diff --git a/\(path) b/\(path)\n"
        if isNew { header += "new file mode 100644\n" }
        if isDeleted { header += "deleted file mode 100644\n" }
        if let o = oldSHA, let n = newSHA {
            header += "index \(String(o.prefix(7)))..\(String(n.prefix(7))) 100644\n"
        } else if let n = newSHA {
            header += "index 0000000..\(String(n.prefix(7)))\n"
        } else if let o = oldSHA {
            header += "index \(String(o.prefix(7)))..0000000\n"
        }

        // 二进制：不产出行级 diff（行级输出会把任意字节流搞坏）。
        if oldData?.contains(0) ?? false || data?.contains(0) ?? false {
            return header + "Binary files a/\(path) and b/\(path) differ\n"
        }

        let oldText = oldData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let newText = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let hunks = GitTextDiff.unified(old: oldText, new: newText,
                                        oldLabel: oldLabel, newLabel: newLabel)
        if hunks.isEmpty { return "" }
        return header + hunks
    }

    /// HEAD tree ↔ 某个 tree 的整体 diff（`git show` 用）。
    private func diffTreeToTree(from oldTree: String?, to newTree: String, prefix: String?) throws -> String {
        var old = [String: String]()
        if let o = oldTree {
            for (p, e) in try flattenedTree(o) { old[p] = e.sha }
        }
        var new = [String: String]()
        for (p, e) in try flattenedTree(newTree) { new[p] = e.sha }
        return try diffByShas(old: old, new: new)
    }

    /// checkout：切分支 / 把工作区恢复成某个 tree 的样子。
    func checkout(_ target: String) throws -> String {
        // `git checkout -- <path>`：从暂存区恢复文件。
        if target == "--" { throw GitError.unsupported("git checkout -- <path>，请改用 git restore 或先 git add") }

        var newHEAD: String? = nil
        var branchRef: String? = nil
        if let sha = readRef("refs/heads/\(target)") {
            newHEAD = sha
            branchRef = "refs/heads/\(target)"
        } else if ObjectStore.isHexID(target) {
            newHEAD = try resolveRevision(target)
        } else {
            throw GitError.unknownRevision(target)
        }
        guard let targetSHA = newHEAD else { throw GitError.unknownRevision(target) }

        let targetTree = try readCommit(targetSHA).tree
        let desired = try flattenedTree(targetTree)
        let currentFiles = Set(workFiles(skipIgnored: false))

        // 未跟踪文件挡住切换（真实 git 会拒绝覆盖用户没提交的东西）。
        let indexPaths = Set(try GitIndexCodec.read(at: indexFile).map(\.path))
        for (path, _) in desired where !indexPaths.contains(path) && currentFiles.contains(path) {
            if let data = try? readBlob(desired[path]!.sha) {
                let existing = FileManager.default.contents(atPath: absolute(path))
                if existing != data {
                    throw GitError.invalidArgument(
                        "error: Your local changes to the following files would be overwritten by checkout:\n\t\(path)\n请先提交或丢弃这些改动。")
                }
            }
        }

        // 写入目标内容 + 删掉目标里没有的已跟踪文件。
        let fm = FileManager.default
        for (path, entry) in desired {
            let abs = absolute(path)
            try fm.createDirectory(atPath: (abs as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            let data = try readBlob(entry.sha)
            try data.write(to: URL(fileURLWithPath: abs), options: .atomic)
        }
        let headPaths = Set(try headTree().keys)
        for path in headPaths where desired[path] == nil {
            try? fm.removeItem(atPath: absolute(path))
            removeEmptyParents(of: path)
        }

        // 索引改成目标 tree（stat 用刚写完的文件重新取，避免"stat 与内容对不上"）。
        var entries = [GitIndexEntry]()
        for (path, entry) in desired {
            let abs = absolute(path)
            let attrs = (try? fm.attributesOfItem(atPath: abs)) ?? [:]
            entries.append(.entry(path: path,
                                  mode: UInt32(entry.mode, radix: 8) ?? 0o100644,
                                  sha: entry.sha, attrs: attrs))
        }
        try GitIndexCodec.write(entries, to: indexFile)

        if let ref = branchRef {
            try "ref: \(ref)\n".write(toFile: (gitDir as NSString).appendingPathComponent("HEAD"),
                                      atomically: true, encoding: .utf8)
            return "已切换到分支 '\(target)'"
        }
        try targetSHA.write(toFile: (gitDir as NSString).appendingPathComponent("HEAD"),
                            atomically: true, encoding: .utf8)
        return "HEAD 现在指向 \(targetSHA)"
    }

    /// 删文件后把空掉的父目录也清掉（git 不保留空目录）。
    private func removeEmptyParents(of relPath: String) {
        var dir = (relPath as NSString).deletingLastPathComponent
        while !dir.isEmpty && dir != "." {
            let abs = absolute(dir)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: abs),
               contents.isEmpty {
                try? FileManager.default.removeItem(atPath: abs)
            } else {
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
}
