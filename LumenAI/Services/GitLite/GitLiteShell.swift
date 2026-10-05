import Foundation

/// `shell` 里 `git` 子命令的解析层：把参数翻给 `GitRepo`，把结果翻回命令行文本。
///
/// 与其它内置命令一样，这里**只做参数解析与错误码**，业务逻辑全在 `GitRepo` ——
/// GitRepo 不依赖 ShellSandbox，所以能单独拎出来用真实的 `git fsck` 做一致性测试。
enum GitLiteShell {

    /// - Parameters:
    ///   - args: 已经分好词的参数（`["add", "-A", "."]`）。
    ///   - cwd: ShellSandbox 的当前工作目录（仓库发现起点）。
    ///   - resolve: 把命令行里的路径变成绝对路径（由 ShellSandbox 注入，
    ///     这样 git 与其它命令对 `~` / 相对路径 / 越界的处理完全一致）。
    static func run(args: [String],
                    cwd: String,
                    resolve: (String) -> String) -> (text: String, exitCode: Int) {
        guard !args.isEmpty else { return (usage(), 0) }
        let sub = args[0]
        let rest = Array(args.dropFirst())

        do {
            switch sub {
            case "init":
                return (try cmdInit(rest: rest, cwd: cwd, resolve: resolve), 0)

            case "help", "--help", "-h":
                return (usage(), 0)

            default:
                break
            }
            // 以下子命令都需要已有仓库
            let repo = try GitRepo.find(startingAt: cwd)
            switch sub {
            case "add":
                let (text, code) = try cmdAdd(repo: repo, rest: rest, resolve: resolve)
                return (text, code)
            case "rm":
                let (text, code) = try cmdRm(repo: repo, rest: rest, resolve: resolve)
                return (text, code)
            case "status", "st":
                return (try repo.status(), 0)
            case "commit":
                return try cmdCommit(repo: repo, rest: rest)
            case "log":
                return try cmdLog(repo: repo, rest: rest)
            case "diff":
                return try cmdDiff(repo: repo, rest: rest, resolve: resolve)
            case "show":
                return (try repo.show(rev: rest.first), 0)
            case "branch":
                return try cmdBranch(repo: repo, rest: rest)
            case "checkout", "co":
                return try cmdCheckout(repo: repo, rest: rest)
            case "rev-parse":
                return try cmdRevParse(repo: repo, rest: rest)
            case "cat-file":
                return try cmdCatFile(repo: repo, rest: rest)
            case "ls-files":
                let files = try GitIndexCodec.read(at: repo.indexFile).map(\.path).sorted()
                return (files.joined(separator: "\n") + (files.isEmpty ? "" : "\n"), 0)
            default:
                return ("git: '\(sub)' is not supported by this app's built-in git.\n"
                        + "Supported: init add rm status commit log diff show branch checkout rev-parse cat-file ls-files\n", 1)
            }
        } catch let e as GitError {
            let code: Int = {
                if case .notARepo = e { return 128 }
                if case .notGitDir = e { return 128 }
                return 1
            }()
            return ("\(e)", code)
        } catch {
            return ("fatal: \(error.localizedDescription)", 1)
        }
    }

    // MARK: - 子命令

    private static func cmdInit(rest: [String], cwd: String,
                                resolve: (String) -> String) throws -> String {
        let target: String
        if let raw = rest.first, !raw.hasPrefix("-") {
            target = resolve(raw)
        } else {
            target = cwd
        }
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: (target as NSString).appendingPathComponent(".git")) {
            _ = try GitRepo.find(startingAt: target)
            return "Reinitialized existing Git repository in \(target)/.git/\n"
        }
        _ = try GitRepo.initRepo(at: target)
        return "Initialized empty Git repository in \(target)/.git/\n"
    }

    /// 把路径参数换成**仓库内相对路径**（绝对路径必须落在仓库里）。
    private static func relArgs(_ raws: [String], repo: GitRepo,
                                resolve: (String) -> String) throws -> [String] {
        let prefix = repo.workTree + "/"
        return try raws.map { raw in
            if raw == "." || raw == "./" { return "." }
            if raw == ".." || raw.hasPrefix("../") {
                throw GitError.pathspecMismatch(raw)
            }
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                let abs = resolve(raw)
                if abs == repo.workTree { return "." }
                guard abs.hasPrefix(prefix) else { throw GitError.pathspecMismatch(raw) }
                return String(abs.dropFirst(prefix.count))
            }
            return raw
        }
    }

    private static func cmdAdd(repo: GitRepo, rest: [String],
                               resolve: (String) -> String) throws -> (String, Int) {
        var paths = [String]()
        var force = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "-A" || a == "--all" {
                paths = ["."]
                i += 1
                continue
            }
            if a.hasPrefix("-") && !a.hasPrefix("-.") {
                if a == "-f" || a == "--force" { force = true }
                if a == "-n" || a == "--dry-run" {
                    // 不能"先 add 再回滚"：add 会写对象与 index，中途失败就留下半截状态。
                    // 与其做出与 git 不一致的假 dry-run，不如直接指路。
                    return ("git add -n 暂不支持：请改用 git status 查看将被暂存的文件。\n", 1)
                }
                i += 1
                continue
            }
            paths.append(a)
            i += 1
        }
        let rels = try relArgs(paths.isEmpty ? ["."] : paths, repo: repo, resolve: resolve)
        if force {
            // -f 的语义是"忽略 .gitignore 也照加"。内置实现里 add 会无条件跳过被忽略的
            // 文件，静默给出与 git 不同的暂存结果比报错更难查，所以显式拒绝。
            return ("git add -f 暂不支持（内置 git 不处理强制忽略）。\n", 1)
        }
        _ = try repo.add(paths: rels)   // 与真实 git 一样：成功时**什么都不输出**
        return ("", 0)
    }

    private static func cmdRm(repo: GitRepo, rest: [String],
                              resolve: (String) -> String) throws -> (String, Int) {
        var fromDisk = true
        var cachedOnly = false
        var paths = [String]()
        for a in rest {
            if a == "--cached" { cachedOnly = true; continue }
            if a == "-r" || a == "--recursive" { continue }
            if a.hasPrefix("-") { continue }
            paths.append(a)
        }
        guard !paths.isEmpty else { return ("nothing specified, nothing removed.\n", 1) }
        let rels = try relArgs(paths, repo: repo, resolve: resolve)
        if cachedOnly { fromDisk = false }
        let removed = try repo.remove(paths: rels, fromDisk: fromDisk)
        return (removed.map { "rm '\($0)'\n" }.joined(), 0)
    }

    private static func cmdCommit(repo: GitRepo, rest: [String]) throws -> (String, Int) {
        var message: String?
        var allowEmpty = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "-m" || a == "--message" {
                i += 1
                if i < rest.count { message = rest[i] }
            } else if a == "--allow-empty" {
                allowEmpty = true
            } else if a == "-a" || a == "--all" {
                return ("git commit -a 暂不支持：请先 git add -A 再 git commit。", 1)
            } else if a == "-am" || (a.hasPrefix("-") && i + 1 < rest.count && rest[i + 1] == "-m") {
                // 兼容 `-am "msg"` 这种常见简写
                if a == "-am" { i += 1; if i < rest.count { message = rest[i] } }
            }
            i += 1
        }
        guard let msg = message, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("error: switch `m' requires a message\nhint: git commit -m \"你的提交信息\"\n", 1)
        }
        let (sha, text) = try repo.commit(message: msg, allowEmpty: allowEmpty)
        _ = sha
        return (text + "\n", 0)
    }

    private static func cmdLog(repo: GitRepo, rest: [String]) throws -> (String, Int) {
        var limit = 20
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "-n" || a == "--max-count" {
                i += 1
                if i < rest.count, let n = Int(rest[i]) { limit = n }
            } else if a.hasPrefix("-n"), let n = Int(String(a.dropFirst(2))) {
                limit = n
            } else if a == "--oneline" {
                return (try cmdLogOneline(repo: repo, limit: limit), 0)
            } else if a == "-p" || a == "--stat" || a.hasPrefix("--") || a.hasPrefix("-") {
                // 其它修饰符先忽略（--grep/--since 等），不报错：log 的常见用法是裸 log。
            }
            i += 1
        }
        return (try repo.log(limit: limit), 0)
    }

    private static func cmdLogOneline(repo: GitRepo, limit: Int) throws -> String {
        guard let firstSHA = try repo.headCommit() else {
            throw GitError.unknownRevision("HEAD (还没有任何提交)")
        }
        var sha: String? = firstSHA
        var out = ""
        var count = 0
        var seen = Set<String>()
        while let current = sha, seen.insert(current).inserted, count < limit {
            let c = try repo.readCommit(current)
            let subject = c.message.split(separator: "\n").first.map(String.init) ?? ""
            out += "\(String(current.prefix(7))) \(subject)\n"
            count += 1
            sha = c.parents.first
        }
        return out
    }

    private static func cmdDiff(repo: GitRepo, rest: [String],
                                resolve: (String) -> String) throws -> (String, Int) {
        var cached = false
        var paths = [String]()
        for a in rest {
            if a == "--cached" || a == "--staged" { cached = true; continue }
            if a.hasPrefix("-") { continue }
            paths.append(a)
        }
        let rels = paths.isEmpty ? [] : try relArgs(paths, repo: repo, resolve: resolve)
        let text = try repo.diff(cached: cached, paths: rels)
        return (text, 0)
    }

    private static func cmdBranch(repo: GitRepo, rest: [String]) throws -> (String, Int) {
        if rest.isEmpty || rest.first == "-a" || rest.first == "-v" {
            let current = try repo.branchName()
            let branches = try repo.listBranches()
            var out = ""
            for b in branches {
                out += (b == current ? "* " : "  ") + b + "\n"
            }
            if branches.isEmpty { out = "" }
            return (out, 0)
        }
        if rest.first == "-d" || rest.first == "-D" {
            guard rest.count > 1 else { return ("error: branch name required\n", 1) }
            let name = rest[1]
            let current = try repo.branchName()
            guard name != current else {
                return ("error: cannot delete branch '\(name)' checked out\n", 1)
            }
            guard repo.readRef("refs/heads/\(name)") != nil else {
                return ("error: branch '\(name)' not found.\n", 1)
            }
            try FileManager.default.removeItem(
                atPath: (repo.gitDir as NSString).appendingPathComponent("refs/heads/\(name)"))
            return ("已删除分支 \(name)\n", 0)
        }
        let text = try repo.createBranch(rest[0])
        return (text + "\n", 0)
    }

    private static func cmdCheckout(repo: GitRepo, rest: [String]) throws -> (String, Int) {
        guard !rest.isEmpty else {
            return ("error: pathspec '--' expected\nhint: git checkout <branch>\n", 1)
        }
        var target = rest[0]
        // `git checkout -b new` → 建分支并切过去
        if target == "-b" || target == "-B" {
            guard rest.count > 1 else { return ("error: branch name required\n", 1) }
            let name = rest[1]
            if repo.readRef("refs/heads/\(name)") == nil {
                _ = try repo.createBranch(name)
            }
            target = name
        }
        let text = try repo.checkout(target)
        return (text + "\n", 0)
    }

    private static func cmdRevParse(repo: GitRepo, rest: [String]) throws -> (String, Int) {
        var refs = rest.filter { !$0.hasPrefix("-") }
        if refs.isEmpty { refs = ["HEAD"] }
        var out = ""
        for r in refs {
            if r == "--verify" || r == "--quiet" { continue }
            if r == "--is-inside-work-tree" { return ("true\n", 0) }
            if r == "--git-dir" { return (repo.gitDir + "\n", 0) }
            out += try repo.resolveRevision(r) + "\n"
        }
        return (out, 0)
    }

    private static func cmdCatFile(repo: GitRepo, rest: [String]) throws -> (String, Int) {
        let obj = rest.last(where: { !$0.hasPrefix("-") })
        guard let rev = obj else {
            return ("usage: git cat-file [-t|-p] <object>\n", 1)
        }
        let sha = try repo.resolveRevision(rev)
        let (kind, payload) = try repo.objects.read(sha)
        if rest.contains("-t") { return (kind + "\n", 0) }
        if rest.contains("-s") { return ("\(payload.count)\n", 0) }
        if rest.contains("-e") { return ("", 0) }
        // -p / 默认：tree 与 commit 要"像 git 那样"展开成可读文本
        switch kind {
        case "tree":
            var out = ""
            for e in try GitTreeCoder.decode(payload) {
                let mode = e.isTree ? "040000" : e.mode
                out += "\(mode) \(e.isTree ? "tree" : "blob") \(e.sha)\t\(e.name)\n"
            }
            return (out, 0)
        case "commit":
            return (String(decoding: payload, as: UTF8.self), 0)
        default:
            // blob：原样输出（不做编码猜测，交给调用方）
            return (String(decoding: payload, as: UTF8.self), 0)
        }
    }

    private static func usage() -> String {
        """
        git - 内置 git 子集（iOS 无法运行真实 git 二进制）

        用法: git <子命令> [参数]

        可用子命令:
          init [路径]              建立新仓库
          add <路径...>            暂存文件（-A 暂存全部）
          rm [--cached] <路径...>  移出暂存区（--cached 保留文件）
          status                   工作区 / 暂存区状态
          commit -m <信息>         提交（首次提交前请先 git add）
          log [-n N] [--oneline]   提交历史
          diff [--cached] [路径]   改动对比（--cached 比 HEAD 与暂存区）
          show [rev]               查看某次提交
          branch [名字]            列出 / 新建分支
          checkout <分支>          切换分支（-b 新建并切换）
          rev-parse <rev>          解析引用为 commit id
          cat-file -p <object>     查看对象内容
          ls-files                 列出暂存区文件

        限制: 不支持 push / pull / fetch（需要网络与远端协议）；
              不支持 merge / rebase / stash / submodule。
        """
    }
}
