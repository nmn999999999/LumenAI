import Foundation

/// 嵌入式 Shell 沙箱(iOS 限定在 app 沙盒内的受限 shell)
/// 不依赖真实 `/bin/sh` —— iOS 没有 shell 二进制可调用。本沙箱:
/// - 解析简单 shell 命令(支持 `;` 串联 / `|` 管道 / `>` `>>` 重定向 / `&&` `||` 链)
/// - 路径解析限定在 `appHome/shellbox/` 子树下,任何命令访问越界路径一律转回沙箱根
/// - 内置 19 个核心命令(文件/文本/系统),外加内置纯 Swift `git` 子集(见 GitLite/)
/// - 通配符 `*` `?` 在参数展开时支持
///
/// 用法:`ShellSandbox.run("ls -l *.txt | head -5")` 即可串起命令链。
enum ShellSandbox {

    /// 沙箱根目录:app 沙盒下独立子目录,跟其它模块隔离
    static let sandboxRoot: String = {
        let docs = NSHomeDirectory() + "/Documents"
        let root = docs + "/shellbox"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }()

    // MARK: - 会话状态(cwd / env / history):统一由一把锁保护

    /// 保护 `cwd` / `env` / `history` 的锁。
    ///
    /// 为什么非加不可:这三者原来是 `nonisolated(unsafe) static var`,
    /// 等于"向编译器承诺我自己保证线程安全",但代码里没有任何同步措施 —— 承诺是空的。
    /// 这不是理论风险:调用方 AgentTool.executeShell 在**非隔离 async 上下文**里
    /// 同步调用 `run`,多个对话 / 多个 Task 可以真的并发进来。
    /// 原来的后果:
    ///  - `history.append(...)` / `history.removeFirst(...)` / `env[k] = v` 全是"读-改-写",
    ///    Swift 的 Array / Dictionary 是值类型(COW),并发执行时不是原子的:
    ///    轻则丢更新(刚跑过的命令没进历史),重则两线程同时复制/释放同一块缓冲区
    ///    → 内存错误崩溃(EXC_BAD_ACCESS,线上表现为随机闪退且极难复现)。
    ///  - `cd` 写 cwd 与 `resolvePath` 读 cwd 并发 → 相对路径可能被解析到别人的 cwd 下。
    /// 现在:所有读写都经过同一把 NSLock,达到的最低保证是**无数据竞争**。
    /// ⚠️ 这把锁只保证内存安全,不保证"会话隔离" —— 见下面 resetSession() 的说明。
    private static let stateLock = NSLock()

    /// 会话初始环境(export 会在这份基础上叠加)
    private static func defaultEnv() -> [String: String] {
        [
            "HOME": sandboxRoot,
            "USER": "mobile",
            "PWD": sandboxRoot,
            "SHELL": "LumenAI-SandboxShell",
            "PATH": "/bin:/usr/bin"  // 虚拟 PATH,本沙箱内置命令等价于"在 PATH 中"
        ]
    }

    // 下面是受 stateLock 保护的真实存储(私有);对外仍是 cwd / env / history 三个名字,
    // 名字与类型保持不变,所以其它文件(agentTool 等)即使读它们也不会编译失败。
    private nonisolated(unsafe) static var _cwd: String = sandboxRoot
    private nonisolated(unsafe) static var _env: [String: String] = defaultEnv()
    private nonisolated(unsafe) static var _history: [String] = []

    /// 当前工作目录(加锁读写)。
    /// ⚠️ 语义提醒:它是**进程级单例**,不区分对话 —— 一个对话里的 `cd` 会影响
    /// 其它对话的相对路径解析(跨对话泄漏)。上层应在每次新对话开始时调用
    /// `resetSession()`;想真正隔离必须按会话分片存储(需改调用方签名,本次没做)。
    static var cwd: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _cwd }
        set { stateLock.lock(); defer { stateLock.unlock() }; _cwd = newValue }
    }

    /// 简单会话环境(export 写入的变量)。
    /// 注意:`env["K"] = v` 这种写法会走 get + set **两次加锁**,
    /// 两次加锁之间可能被其它线程插入而丢更新,所以本文件内部一律改用
    /// `setEnvVar(_:_:)` / `updateCwd(_:)` 这类"在锁内一次性完成读-改-写"的辅助函数。
    static var env: [String: String] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _env }
        set { stateLock.lock(); defer { stateLock.unlock() }; _env = newValue }
    }

    /// 命令历史(v0.3.19:history 命令读取;追加去重与 200 上限见 appendHistory)
    static var history: [String] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _history }
        set { stateLock.lock(); defer { stateLock.unlock() }; _history = newValue }
    }

    /// 在锁内完成 env 的单键读-改-写(避免 get/set 两次加锁之间丢更新)
    private static func setEnvVar(_ key: String, _ value: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        _env[key] = value
    }

    /// 在锁内同时更新 cwd 与 PWD —— 两者语义上必须一致,
    /// 分开加锁会出现"cwd 已经换了、PWD 还是旧的"的中间态,`cd` 之后 `env` 输出会自相矛盾。
    private static func updateCwd(_ path: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        _cwd = path
        _env["PWD"] = path
    }

    /// 在锁内追加一条命令历史并裁剪到 200 条上限(原来是两步读-改-写,并发下会丢条目)
    private static func appendHistory(_ line: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        _history.append(line)
        if _history.count > 200 { _history.removeFirst(_history.count - 200) }
    }

    // MARK: - 资源上限(把"跑不完 / 吃光内存"变成"有界")

    /// 单条命令链返回内容的上限(字符数)。
    /// 为什么需要:调用方 AgentTool.executeShell 是在**拿到完整字符串之后**才
    /// `prefix(4000)`,也就是说内存里已经先构造过一遍完整输出;
    /// 本上限保证沙盒自己不会构造出无界字符串。
    static let maxOutputCharacters = 200_000

    /// 单次 `cat` 从文件读取的总字节上限(`cat` 一个几百 MB 的日志原来会直接 OOM)
    private static let maxFileReadBytes = 4 * 1024 * 1024

    /// `find` / `du` 目录遍历的条目总数上限与深度上限
    private static let maxWalkEntries = 20_000
    private static let maxWalkDepth = 6

    /// tokenize / 链切分的迭代步数上限(纯防御:现有循环都会推进,
    /// 这里加一道闸,防止以后改动引入"不推进 i"的分支变成死循环占住线程)
    private static let maxParseIterations = 1_000_000

    /// 输出上限截断(统一在同步入口出口处调用)
    private static func capOutput(_ text: String) -> String {
        guard text.count > maxOutputCharacters else { return text }
        return String(text.prefix(maxOutputCharacters))
            + "\n…(沙箱输出超过 \(maxOutputCharacters) 字符上限，已截断)"
    }

    /// 同步入口:执行一条 shell 命令字符串,返回标准输出
    ///
    /// ⚠️ 这个入口**做不到超时**(如实说明,不要当作已有保护):
    /// 它是同步阻塞实现,一旦进入"读大文件"或长时间运算,调用方只能等它跑完 ——
    /// 同步调用没有取消点,外面套 `Task` / `async` 都无法打断正在执行的这一帧,
    /// `Task.cancel()` 也无效。本文件能做的只有"让单条命令有界":
    ///   - 输出上限(maxOutputCharacters)
    ///   - 单次读文件上限(maxFileReadBytes)
    ///   - 目录遍历上限(maxWalkEntries / maxWalkDepth)
    ///   - 解析循环迭代上限(maxParseIterations,防御性)
    /// 真正的超时只能由调用方实现:用 `withTaskGroup` 让"命令"与 `Task.sleep` 竞速,
    /// 或者改调本文件的 `runAsync(_:timeoutSeconds:)`(超时后调用方不再等待,
    /// 但**不能**让已经在跑的命令停下 —— 见其注释)。
    /// 另外:同步入口还会长时间占用 Swift 并发协作线程池的一个线程(iPhone 上该池
    /// 宽度≈核数),所以新代码应优先用 runAsync。
    static func run(_ input: String) -> String {
        runWithExitCode(input).text
    }

    /// 与 `run` 完全同逻辑,额外返回命令链**最后一段**的退出码(0=成功)。
    ///
    /// 为什么需要:`run` 只返回文本,上层(AgentTool.executeShell)拿不到退出码,
    /// 于是 `ChatMessage.ToolCall.exitCode` 永远填不进去 —— "哪个工具失败多、
    /// 失败是命令本身失败还是沙盒拒绝"这类问题就答不了。
    /// 这里只是把内部本来就有的 lastExit 暴露出来,不改动 `run` 的签名与行为
    /// (调用方在别的文件,签名必须保持稳定)。
    /// ⚠️ 局限:退出码只反映最后一段(`;` / `&&` / `|` 链的最后一段);多段命令
    /// 中前面某段的失败不会体现在这里,与真实 shell 的 `$?` 语义一致,不要过度解读。
    static func runWithExitCode(_ input: String) -> (text: String, exitCode: Int) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", 0) }
        // 支持 && 和 || 链(简单优先匹配)
        let segments = splitByChaining(trimmed)
        var output = ""
        var lastExit = 0
        for seg in segments {
            let (cond, body) = seg
            // 0=success, !=0=fail
            let shouldRun: Bool
            switch cond {
            case .none:    shouldRun = true
            case .and:     shouldRun = (lastExit == 0)
            case .or:      shouldRun = (lastExit != 0)
            }
            if shouldRun {
                let res = execSegment(body)
                output += res.text
                lastExit = res.exitCode
            }
        }
        return (capOutput(output), lastExit)
    }

    // MARK: - 异步入口(推荐的新代码走这里,避免占住 Swift 并发协作线程池)

    /// 沙盒专用的执行队列:承载**同步阻塞**的 `run`。
    ///
    /// 为什么不用 `DispatchQueue.global()`:global 是全局共享队列,
    /// 长任务会跟其它模块抢同一批线程,还可能互相饿死;用一条本模块专属队列,
    /// 至少把"沙盒在阻塞"这件事限制在自己这口锅里。
    /// 为什么用 `.concurrent` 而不是串行队列:串行会让"某个对话的一条慢命令"
    /// 挡住**所有**其它对话的 shell 命令,而 cwd 泄漏问题并不会因此消失
    /// (那是"单份全局状态"的问题,不是并发度的问题)。这里只解决
    /// "不要把协作线程池的线程长期占住"这一件事。
    private static let execQueue = DispatchQueue(
        label: "com.lumenai.shellsandbox.exec",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// 保证 continuation 只被 resume 一次("命令跑完"与"超时"谁先到谁赢)。
    /// CheckedContinuation 被 resume 两次会直接 crash,所以必须用锁守一道。
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fireOnce(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !fired else { return }
            fired = true
            body()
        }
    }

    /// 异步包装:把同步执行挪到专用队列,让 Swift 并发协作线程池不被长期占用
    /// (iPhone 上协作池宽度≈核数,一条 `cat 大文件` 就能占掉其中一个)。
    ///
    /// ⚠️ 局限(如实说明,别当成"已经有超时了"):
    /// 1) 底层 `run` 仍是同步阻塞实现,进入后**没有取消点**:本包装只是
    ///    "不阻塞调用方所在的执行器",并不会让命令变快,`Task.cancel()` 也停不下它。
    /// 2) 传了 `timeoutSeconds` 时,超时的含义是"调用方不再等待":
    ///    被放弃的那条命令仍会在 execQueue 上跑完(继续占一个线程);
    ///    想要"真的中断执行",必须把沙盒改写成可中断的分步实现(每一步检查取消),
    ///    工作量较大,本次没做。
    /// 3) 现状:调用方 AgentTool.executeShell 用的**仍是同步 `run`**,
    ///    所以线上没有任何超时保护 —— 要生效必须由上层改调本函数或自己做竞速,
    ///    而那个文件不在本次允许修改的范围内。
    static func runAsync(_ input: String, timeoutSeconds: Double? = nil) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = OnceFlag()
            execQueue.async {
                let out = run(input)
                once.fireOnce { cont.resume(returning: out) }
            }
            if let timeoutSeconds, timeoutSeconds > 0 {
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    once.fireOnce {
                        cont.resume(returning: "(shell 超时:命令在 \(timeoutSeconds)s 内未返回，已放弃等待；该命令的后台执行仍可能继续)\n")
                    }
                }
            }
        }
    }

    // MARK: - 会话状态重置

    /// 重置"会话级"状态:cwd / PWD 回沙盒根、export 的环境变量清空、命令历史清空。
    ///
    /// 谁该调用:上层(AgentService / ChatView 等)在**每次新对话开始时**调用一次。
    /// 本次改动**没有在任何地方调用它** —— 调用方都在不允许修改的文件里。
    ///
    /// 为什么需要它(cwd 到底该不该跨对话保留):
    /// `cwd` 是进程级单例,不区分对话。于是对话 A 执行 `cd sub` 之后,
    /// 对话 B 的 `cat a.txt` 会在 `<root>/sub` 下解析;A 把 cwd 切到某个深层目录后,
    /// B 的 `rm -r .` / `ls` 的目标也跟着变 —— 跨对话状态泄漏,既难排查也危险。
    /// 所以语义上 cwd **不该**跨对话保留;但不能简单地去掉它(同一条命令链里的
    /// `cd x ; cat y` 就是要共享 cwd),折中方案就是这个显式重置入口。
    ///
    /// ⚠️ 局限(不要声称已经做到会话隔离):这只是"泄漏之后能被补救",
    /// **不是真正的会话隔离**。真正隔离需要把状态按会话 id 分片,即把入口改成
    /// `run(_:session:)` 之类的签名 —— 那要同时改调用方 AgentTool.executeShell,
    /// 不在本次允许的修改范围内。在没人调用本函数之前,cwd/env/history 依然
    /// 是全局共享的;本次改动只保证了**无数据竞争**(见 stateLock 注释)。
    /// 另外:`reset()` 是旧的测试辅助函数,只重置 cwd/PWD 且保留历史与 export 变量,
    /// 新代码请用本函数。
    static func resetSession() {
        stateLock.lock(); defer { stateLock.unlock() }
        _cwd = sandboxRoot
        _env = defaultEnv()
        _history = []
    }

    private enum ChainCond { case none, and, or }

    /// 切分 `cmd1 && cmd2 || cmd3`:在 "&&" 和 "||" 处断开,保留连接符。
    private static func splitByChaining(_ s: String) -> [(ChainCond, String)] {
        var out: [(ChainCond, String)] = []
        var current = ""
        var pending: ChainCond = .none
        var i = s.startIndex
        // 迭代步数闸(防御性):现有分支都会推进 i,这里保证即使以后改错也不会死循环
        var steps = 0
        while i < s.endIndex {
            steps += 1
            if steps > maxParseIterations { break }
            // 检查 &&
            if s[i...].hasPrefix("&&") {
                out.append((pending, current.trimmingCharacters(in: .whitespaces)))
                current = ""
                pending = .and
                i = s.index(i, offsetBy: 2)
                continue
            }
            if s[i...].hasPrefix("||") {
                out.append((pending, current.trimmingCharacters(in: .whitespaces)))
                current = ""
                pending = .or
                i = s.index(i, offsetBy: 2)
                continue
            }
            current.append(s[i])
            i = s.index(after: i)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append((pending, current.trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    /// 执行一段 `cmd1 ; cmd2 ; cmd3`(按顺序,失败也继续)
    private static func execSegment(_ seg: String) -> (text: String, exitCode: Int) {
        // 先 tokenize 让 ; 和 | 提前分离,然后按 ; 切分执行(每段走 executeSubPart 处理 | 与 重定向)
        let tokens = tokenize(seg)
        guard !tokens.isEmpty else { return ("", 0) }
        // 按 ; 切分
        var segments: [[String]] = [[]]
        for t in tokens {
            if t == ";" {
                segments.append([])
            } else {
                segments[segments.count - 1].append(t)
            }
        }
        var lastText = ""
        var lastExit = 0
        for s in segments where !s.isEmpty {
            let r = executePipeline(s)
            lastText = r.text
            lastExit = r.exitCode
        }
        return (lastText, lastExit)
    }

    /// 处理一段形如 `cmd1 | cmd2 | cmd3`(单段内可能有重定向 `>` `>>`)
    private static func executePipeline(_ tokens: [String]) -> (text: String, exitCode: Int) {
        // tokens 已被 tokenize:遇到 > 或 >> 后跟文件名识别为重定向
        // 简化:把整个 pipeline 当若干 subCommand 串接(每个 | 切)
        var groups: [[String]] = [[]]
        for t in tokens {
            if t == "|" {
                groups.append([])
            } else {
                groups[groups.count - 1].append(t)
            }
        }
        var current = ""
        var exitCode = 0
        for (idx, g) in groups.enumerated() where !g.isEmpty {
            let r = executeSingle(g, stdin: (idx == 0 ? "" : current))
            current = r.text
            exitCode = r.exitCode
        }
        return (current, exitCode)
    }

    /// 单条命令:处理 `>` `>>` 重定向
    private static func executeSingle(_ tokens: [String], stdin: String) -> (text: String, exitCode: Int) {
        // 寻找 > / >>
        var argv = tokens
        var redirect: (path: String, append: Bool)? = nil
        if let rIdx = argv.firstIndex(where: { $0 == ">" || $0 == ">>" }),
           rIdx + 1 < argv.count {
            redirect = (argv[rIdx + 1], argv[rIdx] == ">>")
            argv.removeSubrange(rIdx..<min(rIdx + 2, argv.count))
        }
        let result = dispatch(tokens: argv, stdin: stdin)
        if let rd = redirect {
            let resolved = resolvePath(rd.path)
            do {
                if rd.append {
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: resolved))
                    try handle.seekToEnd()
                    if let data = result.text.data(using: .utf8) {
                        try handle.write(contentsOf: data)
                    }
                    try handle.close()
                } else {
                    try (result.text).write(toFile: resolved, atomically: true, encoding: .utf8)
                }
            } catch {
                return (result.text + "（重定向到 \(resolved) 失败: \(error.localizedDescription)）", 1)
            }
        }
        return result
    }

    /// 真正分派:从已 tokenize 的 argv 数组展开通配符,调用对应 builtin
    private static func dispatch(tokens: [String], stdin: String) -> (text: String, exitCode: Int) {
        // 取出环境变量 $VAR 替换(只支持 $FOO, 不支持 ${FOO})
        // 在锁内取一次快照再逐 token 展开:否则每个 token 都会单独读一次 env,
        // 同一个命令里可能出现"前半段用旧值、后半段用新值"的不一致结果
        let envSnapshot = env
        let expanded = tokens.map { expandEnvVars($0, env: envSnapshot) }
        guard let cmd = expanded.first, !cmd.isEmpty else { return ("", 0) }
        var args = Array(expanded.dropFirst())

        // 展开通配符 * ?
        args = args.flatMap { arg -> [String] in
            if arg.contains("*") || arg.contains("?") {
                let matches = globExpand(arg)
                return matches.isEmpty ? [arg] : matches
            }
            return [arg]
        }

        return execBuiltin(cmd, args: args, stdin: stdin)
    }

    /// 内置命令分派
    private static func execBuiltin(_ cmd: String, args: [String], stdin: String) -> (text: String, exitCode: Int) {
        // 记录 history(重复命令去重,上限 200)
        // 走 appendHistory:原来的 "append + 判断 count + removeFirst" 是三步读-改-写,
        // 多 Task 并发时既可能丢条目也可能越界,现在整段在锁内完成
        if !cmd.isEmpty && cmd != "history" {
            appendHistory(cmd + (args.isEmpty ? "" : " " + args.joined(separator: " ")))
        }
        switch cmd {
        case "ls":       return lsCmd(args)
        case "cat":      return catCmd(args, stdin: stdin)
        case "pwd":      return (cwd + "\n", 0)
        case "echo":     return (args.joined(separator: " ") + "\n", 0)
        case "mkdir":    return mkdirCmd(args)
        case "rm":       return rmCmd(args)
        case "cp":       return cpCmd(args)
        case "mv":       return mvCmd(args)
        case "head":     return headTailCmd(args, tail: false, stdin: stdin)
        case "tail":     return tailCmd(args, stdin: stdin)
        case "wc":       return wcCmd(args, stdin: stdin)
        case "grep":     return grepCmd(args, stdin: stdin)
        case "sort":     return sortCmd(args, stdin: stdin)
        case "uniq":     return uniqCmd(args, stdin: stdin)
        case "date":     return (formatDate() + "\n", 0)
        case "whoami":   return ("mobile\n", 0)
        case "env":      return (env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n", 0)
        case "export":   return exportCmd(args)
        case "cd":       return cdCmd(args)
        case "stat":     return statCmd(args)
        case "true":     return ("", 0)
        case "false":    return ("", 1)
        // v0.3.19 新增 POSIX 化命令
        case "sed":      return sedCmd(args, stdin: stdin)
        case "awk":      return awkCmd(args, stdin: stdin)
        case "find":     return findCmd(args)
        case "history":  return historyCmd(args)
        case "tr":       return trCmd(args, stdin: stdin)
        case "cut":      return cutCmd(args, stdin: stdin)
        case "touch":    return touchCmd(args)
        case "tee":      return teeCmd(args, stdin: stdin)
        case "basename": return basenameCmd(args)
        case "dirname":  return dirnameCmd(args)
        case "du":       return duCmd(args)
        case "lz4":      return lz4Cmd(args, stdin: stdin)
        case "git":      return gitCmd(args)
        case "clear":    return ("", 0)
        case "help", "--help", "-h":
            return (helpText(), 0)
        default:
            return ("未知命令: \(cmd)\n(输入 help 查看支持列表)\n", 127)
        }
    }

    // MARK: - git (内置纯 Swift git 子集)

    /// `git` 子命令入口。
    ///
    /// 为什么不调系统 git：iOS 上**没有** `git` 二进制，`posix_spawn` 也拿不到可执行文件，
    /// 所以只能内置实现。业务逻辑全在 `GitLite`（GitRepo / GitLiteShell），
    /// 那边不依赖本文件，可以单独拎出来用真 `git fsck` 做格式一致性验证。
    ///
    /// 路径解析复用 `resolvePath`（同一套 `~` / 相对路径 / 越界回退规则），
    /// 这样 `git add ~/x` 与 `cat ~/x` 的行为完全一致，不会出现"shell 认得、git 不认得"。
    private static func gitCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        GitLiteShell.run(args: args, cwd: cwd, resolve: { resolvePath($0) })
    }

    // MARK: - lz4 (LZ4 压缩/解压, 内置纯 Swift 块编解码器)

    private static func lz4Cmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        guard let flag = args.first else { return (lz4Help(), 2) }
        switch flag {
        case "-i":
            // 内存压缩演示:生成一段可压缩文本,演示 LZ4.Box 内存容器
            var sample = ""
            for i in 0..<400 {
                sample += "LumenAI 会话 #\(i) | 用户: 帮我压缩这段数据 | 助手: LZ4 内存压缩演示内容。"
            }
            let box = LZ4.Box(Data(sample.utf8))
            let pct = String(format: "%.1f%%", (1 - Double(box.compressed.count) / Double(box.originalSize)) * 100)
            let ratio = String(format: "%.2fx", Double(box.originalSize) / Double(max(box.compressed.count, 1)))
            return ("""
            内存压缩演示 (LZ4.Box):
              原文 \(box.originalSize)B → 压缩后 \(box.compressed.count)B
              节省 \(box.savedBytes)B, 压缩率 \(pct) (\(ratio))
            """, 0)

        case "-c", "-d":
            let compress = flag == "-c"
            let srcArg = args.count >= 2 ? args[1] : nil
            let dstArg = args.count >= 3 ? args[2] : nil
            // 输入:文件或 stdin
            var input = Data()
            var fromStdin = false
            if let srcRaw = srcArg {
                let p = resolvePath(srcRaw)
                guard let d = FileManager.default.contents(atPath: p) else {
                    return ("lz4: 无法读取 \(srcRaw)\n", 1)
                }
                input = d
            } else if !stdin.isEmpty {
                input = Data(stdin.utf8)
                fromStdin = true
            } else {
                return ("lz4: 缺少输入(文件参数或 stdin)\n", 2)
            }
            let result: Data
            var stats: String
            if compress {
                result = LZ4.compress(input)
                let r = String(format: "%.2fx", Double(input.count) / Double(max(result.count, 1)))
                stats = "压缩: \(input.count)B → \(result.count)B (\(r))"
            } else {
                guard let d = LZ4.decompress(input) else {
                    return ("lz4: 解压失败(输入不是有效的 LZ4 块)\n", 1)
                }
                result = d
                stats = "解压: \(input.count)B → \(d.count)B"
            }
            // 输出路径:显式 dst > 默认(压缩=.lz4 后缀;解压=去 .lz4 后缀)
            let dst: String
            if let dstRaw = dstArg {
                dst = resolvePath(dstRaw)
            } else if fromStdin {
                dst = resolvePath(compress ? "stdin.lz4" : "stdin.out")
            } else if compress {
                dst = resolvePath(srcArg! + ".lz4")
            } else {
                let s = srcArg!
                dst = resolvePath(s.hasSuffix(".lz4") ? String(s.dropLast(4)) : s + ".out")
            }
            do {
                try result.write(to: URL(fileURLWithPath: dst))
                return (stats + " → \(dst)\n", 0)
            } catch {
                return ("lz4: 写入 \(dst) 失败: \(error.localizedDescription)\n", 1)
            }

        case "-v":
            guard args.count >= 2 else { return ("lz4: 缺少文件参数\n", 2) }
            let p = resolvePath(args[1])
            guard let d = FileManager.default.contents(atPath: p) else {
                return ("lz4: 无法读取 \(args[1])\n", 1)
            }
            let c = LZ4.compress(d)
            let r = d.count > 0 ? String(format: "%.2fx", Double(d.count) / Double(max(c.count, 1))) : "-"
            return ("\(args[1]): \(d.count)B → LZ4 \(c.count)B (\(r))\n", 0)

        default:
            return (lz4Help(), 2)
        }
    }

    private static func lz4Help() -> String {
        return """
        lz4: LZ4 压缩/解压(内置纯 Swift LZ4 块编解码器, 无外部依赖)
          用法:
            lz4 -c <src> [dst]   压缩文件(默认 dst=src+.lz4)
            lz4 -d <src> [dst]   解压文件(默认去掉 .lz4 后缀)
            lz4 -c [dst]         压缩 stdin(管道输入)
            lz4 -v <file>        查看压缩统计
            lz4 -i               内存压缩演示(LZ4.Box)
        """
    }

    // MARK: - 工具方法

    /// 把 `~/foo` 解析为 sandboxRoot/foo;把相对路径解析为 cwd 下
    private static func resolvePath(_ raw: String) -> String {
        let candidate: String
        if raw == "~" {
            candidate = sandboxRoot
        } else if raw.hasPrefix("~/") {
            candidate = sandboxRoot + String(raw.dropFirst(2))
        } else if raw.hasPrefix("/") {
            candidate = raw
        } else {
            candidate = (cwd as NSString).appendingPathComponent(raw)
        }

        // ⚠ 必须先归一化再做前缀校验，否则沙盒是假的。
        // 原实现直接把拼好的字符串返回，两个洞：
        //  1) `appendingPathComponent` **不做 `..` 归一化** —— `cat ../mcp-servers.json`
        //     会由文件系统展开 `..`，读到沙盒外的 Documents/（对话记录、笔记、MCP 配置）；
        //     再往上 `../../Library/Preferences/<bundle>.plist` 就是含 SSH 私钥/密码的
        //     ModelSettings。`rm -r ..` 更糟：路径是 `<root>/..` ≠ sandboxRoot，
        //     rmCmd 里那句"禁止删除沙盒根"的守卫根本不触发 → 删掉整个 Documents/。
        //  2) 绝对路径那句 `raw.hasPrefix(sandboxRoot)` 没有结尾斜杠，
        //     `/…/shellboxEVIL` 会被误判成"在沙盒内"。
        // 现在：先 standardizingPath 折叠 `..` 与多余分隔符，再用 `<root>/` 前缀判定。
        let root = (sandboxRoot as NSString).standardizingPath
        let normalized = (candidate as NSString).standardizingPath
        if normalized == root { return root }
        if normalized.hasPrefix(root + "/") { return normalized }
        // 越界一律落回沙盒根（而不是"重映射"出一个形如 root+/etc/passwd 的怪路径）。
        // 保留"不报错"的行为是为了不改动每个命令的签名；真正的拒绝语义（返回错误）
        // 需要把 resolvePath 改成可失败，属于后续重构。
        return root
    }

    /// `$FOO` 和 `$` 全部展开为 env 中的值(找不到则原样保留)
    /// `env` 参数由调用方一次性取好快照传入(见 dispatch),保证同一条命令看到的是同一份环境
    private static func expandEnvVars(_ s: String, env: [String: String]) -> String {
        var out = s
        // 先展开 $FOO
        let pattern = #"\$([A-Za-z_][A-Za-z0-9_]*)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed()
            for m in matches {
                guard let r = Range(m.range, in: out), r.lowerBound < out.endIndex else { continue }
                var name = ""
                if m.numberOfRanges > 1, let nameR = Range(m.range(at: 1), in: out) {
                    name = String(out[nameR])
                }
                if let val = env[name] {
                    out.replaceSubrange(r, with: val)
                }
            }
        }
        // 展开 ~ 引用
        out = out.replacingOccurrences(of: "~", with: sandboxRoot)
        return out
    }

    /// 极简 tokenize:支持 "双引号" 与 '单引号';`;`、`<`、`>`、`|` 单独成 token;
/// `&&`、`||` 也单独成 token。其余按空白切分。
    private static func tokenize(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuote: Character? = nil
        var i = s.startIndex
        // 迭代步数闸(防御性):同 splitByChaining,防止以后引入不推进 i 的分支
        var steps = 0
        while i < s.endIndex {
            steps += 1
            if steps > maxParseIterations { break }
            let ch = s[i]
            // 检测 `&&` 和 `||` 优先
            if inQuote == nil, i < s.index(s.endIndex, offsetBy: -1, limitedBy: s.startIndex) ?? s.endIndex {
                // 简化检测:在 i 处向前看 2 字符
                let next = s.index(after: i)
                if next < s.endIndex {
                    let two = "\(s[i])\(s[next])"
                    if two == "&&" || two == "||" {
                        if !current.isEmpty { result.append(current); current = "" }
                        result.append(two)
                        i = s.index(after: next)
                        continue
                    }
                }
            }
            if let q = inQuote {
                if ch == q {
                    inQuote = nil
                    if !current.isEmpty { result.append(current); current = "" }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch.isWhitespace || ch == ";" || ch == "|" || ch == "<" {
                // ;、|、< 单独作 token
                if ch == ";" || ch == "|" || ch == "<" {
                    if !current.isEmpty { result.append(current); current = "" }
                    result.append(String(ch))
                } else {
                    if !current.isEmpty {
                        result.append(current)
                        current = ""
                    }
                }
            } else if ch == ">" {
                // > 与 >> 都识别为单一 token
                if !current.isEmpty { result.append(current); current = "" }
                let next = s.index(after: i)
                if next < s.endIndex && s[next] == ">" {
                    result.append(">>")
                    i = s.index(after: next)
                    continue
                } else {
                    result.append(">")
                }
            } else {
                current.append(ch)
            }
            i = s.index(after: i)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 简单 glob 展开:对传入 pattern(可含通配符)列出 sandboxRoot/cwd 下匹配的文件名。
    private static func globExpand(_ pattern: String) -> [String] {
        // 只在 sandboxRoot 内 glob
        let baseDir = (cwd as NSString).appendingPathComponent("")
        let regex = globToRegex(pattern)
        guard let r = try? NSRegularExpression(pattern: regex) else { return [] }
        var matches: [String] = []
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: baseDir) {
            for e in entries {
                let full = NSRange(location: 0, length: (e as NSString).length)
                if r.firstMatch(in: e, range: full) != nil {
                    matches.append(e)
                }
            }
        }
        return matches
    }

    /// 把 glob 模式转成正则
    private static func globToRegex(_ p: String) -> String {
        var out = "^"
        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "?": out += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "|", "^", "$", "\\":
                out += "\\\(ch)"
            default: out += String(ch)
            }
        }
        out += "$"
        return out
    }

    private static func formatDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: Date())
    }

    private static func helpText() -> String {
        return """
        LumenAI Shell 沙箱命令列表 (v0.3.19 POSIX 扩展)
        ------------------
        文件/目录:
          ls [-l|-a] [path]       列出文件
          cat <file...>           输出文件内容(支持 stdin)
          mkdir [-p] <dir>        创建目录
          rm [-r] <path>          删除文件或目录
          cp <src> <dst>          复制
          mv <src> <dst>          移动
          touch <file>            创建空文件 / 更新时间戳
          find [-name PAT] [dir]  递归查找(按名称匹配;省略 -name 列出全部)
          du [-h] [path]          目录/文件占用空间
          pwd                     当前工作目录
          cd <dir>                切换(默认回 sandboxRoot)
          stat <path>             文件元数据
          basename <path>         取文件名部分
          dirname <path>          取目录部分

        文本:
          head [-n N] [file]      前 N 行(默认 10)
          tail [-n N] [file]      后 N 行(默认 10)
          wc [-l|-w|-c] [file]    行/词/字符数
          grep [-i] <pattern>     包含 pattern 的行
          sort [-r|-u]            排序(支持 stdin)
          uniq                    去重(相邻)
          sed 's/旧/新/[g]' [file] 文本替换(支持 stdin)
          awk '{print $1,$2}'     字段处理($1..$n,默认空格分隔)
          tr <set1> <set2>        字符替换/删除
          cut -d: -f1 <file>      按分隔符取字段

        系统:
          echo <args...>          回显
          date                    当前日期时间
          whoami                  当前用户名
          env                     列出环境变量
          export K=V              设置环境变量
          history                 查看命令历史
          tee <file>              输出同时写入文件
          true / false            始终成功 / 失败
          clear                   清屏(占位)
          lz4 -c/-d <src> [dst]   LZ4 压缩/解压(内置纯 Swift 实现)
          lz4 -i                  内存压缩演示 / lz4 -v <file> 压缩统计
          help                    本帮助

        git (内置纯 Swift 子集, 对象/索引格式与真实 git 一致):
          git init [路径]           新建仓库
          git add <path...>         暂存(-A 全部)
          git status                工作区/暂存区状态
          git commit -m <信息>      提交(首次前先 add)
          git log [-n N|--oneline]  提交历史
          git diff [--cached]       改动对比
          git show [rev]            查看提交
          git branch [名字]         分支列表/新建
          git checkout <分支>       切换(-b 新建)
          详见: git help
          ⚠ 无 push/pull/fetch/merge/rebase(需要远端与进程)

        语法:
          ; 顺序执行  && 成功才继续  || 失败才继续
          | 管道     > / >> 重定向
          ~/path    沙盒根目录下路径
          $VAR      展开已 export 的变量
          * ?       通配符展开到当前目录文件
        """
    }

    // MARK: - builtin 实现

    private static func lsCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        var detailed = false
        var all = false
        var target = cwd
        for a in args {
            switch a {
            case "-l": detailed = true
            case "-a": all = true
            case "-la", "-al": detailed = true; all = true
            default: target = resolvePath(a)
            }
        }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: target) else {
            return ("ls: 无法访问 \(target)\n", 1)
        }
        var lines: [String] = []
        var display = entries
        if !all { display = display.filter { !$0.hasPrefix(".") } }
        for e in display.sorted() {
            let p = (target as NSString).appendingPathComponent(e)
            if detailed {
                let attrs = (try? fm.attributesOfItem(atPath: p)) ?? [:]
                let size = (attrs[.size] as? Int) ?? 0
                let mtime = (attrs[.modificationDate] as? Date) ?? Date()
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
                lines.append(String(format: "%8d  %@  %@", size, f.string(from: mtime), e))
            } else {
                lines.append(e)
            }
        }
        return (lines.joined(separator: "\n") + "\n", 0)
    }

    private static func catCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        if args.isEmpty {
            return (stdin, stdin.isEmpty ? 1 : 0)
        }
        var out = ""
        // 读取预算:原来对每个文件直接 `Data(contentsOf:)`,等于把整个文件读进内存
        // —— `cat` 一个几百 MB 的日志会瞬间吃掉大量内存(iOS 上直接被 jetsam 杀进程),
        // 而且它**不会报错**,只是让 App 消失。现在按剩余预算截断读取。
        // 注:预算(4MB)故意大于输出上限(200k 字符),因为 `cat 大文件 | wc -l`
        // 这类管道需要尽量完整的输入,而输出上限由 capOutput 单独负责。
        // 副作用(如实说明):当被截断的内容本身又超过 maxOutputCharacters 时,
        // 下面这句"仅显示前部"的提示会先被 capOutput 截掉,用户看到的只是
        // capOutput 的统一截断提示(提示仍然存在,只是不区分是哪个文件)。
        var budget = maxFileReadBytes
        for f in args {
            let p = resolvePath(f)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                  let size = (attrs[.size] as? NSNumber)?.intValue else {
                return ("cat: \(f): 无法读取\n", 1)
            }
            if size <= budget {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
                    return ("cat: \(f): 无法读取\n", 1)
                }
                budget -= data.count
                out += String(data: data, encoding: .utf8) ?? ""
            } else {
                // 大文件:只读前 budget 字节(FileHandle 按需读,不会整文件进内存)
                guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: p)) else {
                    return ("cat: \(f): 无法读取\n", 1)
                }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: max(0, budget))) ?? Data()
                budget -= data.count
                // 截断点可能落在多字节 UTF-8 字符中间 → 用 lossy 解码,
                // 而不是 String(data:encoding:) 失败后返回空字符串
                out += String(decoding: data, as: UTF8.self)
                out += "\n…(cat: \(f) 共 \(size) 字节，超过沙箱单次读取上限，仅显示前部)"
            }
            if budget <= 0 { break }
        }
        return (out, 0)
    }

    private static func mkdirCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        let recursive = args.contains("-p")
        let paths = args.filter { $0 != "-p" }.map { resolvePath($0) }
        for p in paths {
            do {
                if recursive {
                    try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: false)
                }
            } catch {
                return ("mkdir: \(p): \(error.localizedDescription)\n", 1)
            }
        }
        return ("", 0)
    }

    private static func rmCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        let recursive = args.contains("-r") || args.contains("-rf") || args.contains("-fr")
        let paths = args.filter { !($0.hasPrefix("-")) }.map { resolvePath($0) }
        let fm = FileManager.default
        for p in paths {
            // 安全:禁止删除沙盒根（以及沙盒根的父目录）。
            // 注：`p` 已由 resolvePath 归一化，所以 `..` 这类写法不会再绕过这里；
            // 额外补上"父目录"是因为沙盒根就在 Documents 下，删掉它等于删掉全部用户数据。
            let parent = (p as NSString).deletingLastPathComponent
            if p == sandboxRoot || p == NSHomeDirectory() || parent == NSHomeDirectory() {
                return ("rm: 拒绝删除沙盒根目录 \(p)\n", 1)
            }
            do {
                let isDir = (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeDirectory
                if isDir {
                    if recursive {
                        try fm.removeItem(atPath: p)
                    } else {
                        return ("rm: \(p): 是目录(需要 -r)\n", 1)
                    }
                } else {
                    try fm.removeItem(atPath: p)
                }
            } catch {
                return ("rm: \(p): \(error.localizedDescription)\n", 1)
            }
        }
        return ("", 0)
    }

    private static func cpCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        guard args.count >= 2 else { return ("cp: 需要 src dst 两个参数\n", 1) }
        let src = resolvePath(args[0])
        let dst = resolvePath(args[1])
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue {
            // 复制到目录内:dst/basename(src)
            let base = (src as NSString).lastPathComponent
            let final = (dst as NSString).appendingPathComponent(base)
            do { try fm.copyItem(atPath: src, toPath: final) } catch {
                return ("cp: \(error.localizedDescription)\n", 1)
            }
        } else {
            do { try fm.copyItem(atPath: src, toPath: dst) } catch {
                return ("cp: \(error.localizedDescription)\n", 1)
            }
        }
        return ("", 0)
    }

    private static func mvCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        guard args.count >= 2 else { return ("mv: 需要 src dst 两个参数\n", 1) }
        let src = resolvePath(args[0])
        let dst = resolvePath(args[1])
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue {
            let base = (src as NSString).lastPathComponent
            let final = (dst as NSString).appendingPathComponent(base)
            do { try fm.moveItem(atPath: src, toPath: final) } catch {
                return ("mv: \(error.localizedDescription)\n", 1)
            }
        } else {
            do { try fm.moveItem(atPath: src, toPath: dst) } catch {
                return ("mv: \(error.localizedDescription)\n", 1)
            }
        }
        return ("", 0)
    }

    private static func headTailCmd(_ args: [String], tail: Bool, stdin: String) -> (text: String, exitCode: Int) {
        // 解析 [-n N] [file...]
        var n = 10
        var files: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-n", i + 1 < args.count, let v = Int(args[i+1]) {
                n = v; i += 2
            } else if args[i].hasPrefix("-n") {
                if let v = Int(String(args[i].dropFirst(2))) { n = v }
                i += 1
            } else {
                files.append(args[i]); i += 1
            }
        }
        // 来源:优先 file,否则 stdin
        var text: String = ""
        if !files.isEmpty {
            let p = resolvePath(files[0])
            text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
        } else {
            text = stdin
        }
        let lines = text.components(separatedBy: "\n")
        let picked: [String] = tail ? Array(lines.suffix(n)) : Array(lines.prefix(n))
        return (picked.joined(separator: "\n") + "\n", 0)
    }

    // MARK: - v0.3.19 POSIX 化新增命令

    /// tail 独立(支持 stdin 管道,当 stdin 有内容且无文件参数时作用在 stdin 上)
    private static func tailCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        return headTailCmd(args, tail: true, stdin: stdin)
    }

    /// sed 文本替换:支持 `s/旧/新/[g]` 与 `d`(删除匹配行)
    private static func sedCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        guard let expr = args.first else { return ("sed: 缺少表达式\n", 1) }
        let files = Array(args.dropFirst())
        var text = stdin
        if !files.isEmpty {
            text = (try? String(contentsOfFile: resolvePath(files[0]), encoding: .utf8)) ?? ""
        }
        var lines = text.components(separatedBy: "\n")

        // 匹配 s/pattern/repl/[g]
        if expr.hasPrefix("s/") {
            // 解析 s/pat/repl/[flags] — 支持转义 \/
            var rest = expr.dropFirst(2)
            var pattern = ""
            var replacement = ""
            var current: String = ""
            var inPattern = true
            while let ch = rest.popFirst() {
                if ch == "/" {
                    if inPattern {
                        pattern = current
                        current = ""
                        inPattern = false
                    } else {
                        replacement = current
                        current = ""
                        break
                    }
                } else if ch == "\\", rest.first == "/" {
                    current.append("/")
                    rest.popFirst()
                } else {
                    current.append(ch)
                }
            }
            if pattern.isEmpty && replacement.isEmpty && !current.isEmpty {
                replacement = current
            }
            let global = rest.contains("g")
            let ignoreCase = rest.contains("i")
            // 用 NSRegularExpression 支持 \d \w 等
            var regex: NSRegularExpression?
            if ignoreCase {
                regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } else {
                regex = try? NSRegularExpression(pattern: pattern)
            }
            if regex == nil { regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern)) }
            var out: [String] = []
            for line in lines {
                if let re = regex {
                    let ns = line as NSString
                    let range = NSRange(location: 0, length: ns.length)
                    if global {
                        out.append(re.stringByReplacingMatches(in: line, range: range, withTemplate: replacement))
                    } else if let m = re.firstMatch(in: line, range: range) {
                        var newLine = (line as NSString).replacingCharacters(in: m.range, with: replacement)
                        // 只替换第一个
                        out.append(newLine)
                    } else {
                        out.append(line)
                    }
                } else {
                    if global {
                        out.append(line.replacingOccurrences(of: pattern, with: replacement))
                    } else if line.contains(pattern) {
                        if let r = line.range(of: pattern) {
                            out.append(line.replacingCharacters(in: r, with: replacement))
                        } else { out.append(line) }
                    } else {
                        out.append(line)
                    }
                }
            }
            return (out.joined(separator: "\n") + "\n", 0)
        }

        // 匹配 /pattern/d — 删除匹配行
        if expr.hasPrefix("/"), expr.hasSuffix("/d") {
            let pattern = String(expr.dropFirst().dropLast(2))
            var regex: NSRegularExpression?
            regex = try? NSRegularExpression(pattern: pattern)
            var out: [String] = []
            for line in lines {
                let ns = line as NSString
                let full = NSRange(location: 0, length: ns.length)
                if let re = regex, re.firstMatch(in: line, range: full) == nil {
                    out.append(line)
                } else if !line.contains(pattern) {
                    out.append(line)
                }
            }
            return (out.joined(separator: "\n") + "\n", 0)
        }
        return ("sed: 不支持的表达式 \(expr)(支持 s/旧/新/g 与 /pattern/d)\n", 1)
    }

    /// awk 字段处理:支持 `{print $1,$2}`、`{print $NF}`、`-F<分隔符>`
    private static func awkCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        var fs = " "
        var files: [String] = []
        var program = ""
        for a in args {
            if a.hasPrefix("-F"), a.count > 2 {
                fs = String(a.dropFirst(2))
            } else if a.hasPrefix("{") || a.hasPrefix("print") {
                program = a
            } else if !a.hasPrefix("-") {
                files.append(a)
            }
        }
        if program.isEmpty { return ("awk: 缺少程序\n", 1) }
        var text = stdin
        if !files.isEmpty {
            text = (try? String(contentsOfFile: resolvePath(files[0]), encoding: .utf8)) ?? ""
        }
        var out: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var fields = line.components(separatedBy: fs).map { $0.trimmingCharacters(in: .whitespaces) }
            // 特殊:awk 默认空白分隔(1+ 空白),空字段剔除
            if fs == " " { fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            // 构建变量替换:$1..$n, $NF, $0
            var result = program
            result = result.replacingOccurrences(of: "$0", with: line)
            result = result.replacingOccurrences(of: "$NF", with: fields.last ?? "")
            for (i, f) in fields.enumerated() {
                result = result.replacingOccurrences(of: "$\(i + 1)", with: f)
            }
            // 执行 print 表达式
            if result.contains("print") {
                let body = result.replacingOccurrences(of: "print", with: "")
                var cleaned = body
                    .replacingOccurrences(of: "{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // $n 替换完可能残留裸字段名 → 直接按原样输出
                if cleaned.hasPrefix(",") { cleaned = String(cleaned.dropFirst()) }
                if cleaned.hasPrefix(";") { cleaned = String(cleaned.dropFirst()) }
                out.append(cleaned.isEmpty ? line : cleaned)
            } else {
                out.append(result)
            }
        }
        return (out.joined(separator: "\n") + "\n", 0)
    }

    /// find 递归查找:find [dir] [-name PATTERN]
    private static func findCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        var dir = cwd
        var pattern: String?
        var i = 0
        while i < args.count {
            if args[i] == "-name", i + 1 < args.count {
                pattern = args[i + 1]
                i += 2
            } else if !args[i].hasPrefix("-") {
                dir = resolvePath(args[i])
                i += 1
            } else {
                i += 1
            }
        }
        let fm = FileManager.default
        var results: [String] = []
        // 递归遍历(限制深度防止海量输出)。
        // 追加"条目总数上限":原来只限深度,一棵又宽又深的树(或几十万个小文件)
        // 依然能构造出巨大数组并占住线程很久 —— 深度有界 ≠ 工作量有界。
        var visited = 0
        var hitLimit = false
        func walk(_ path: String, depth: Int) {
            guard depth <= maxWalkDepth, !hitLimit else { return }
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            for e in entries.sorted() {
                if visited >= maxWalkEntries { hitLimit = true; return }
                visited += 1
                let full = (path as NSString).appendingPathComponent(e)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir) {
                    // 名称匹配
                    if let pat = pattern {
                        if matchesGlob(e, pattern: pat) {
                            results.append(relativePath(full))
                        }
                    } else {
                        results.append(relativePath(full))
                    }
                    if isDir.boolValue {
                        walk(full, depth: depth + 1)
                    }
                }
            }
        }
        walk(dir, depth: 0)
        var text = results.joined(separator: "\n") + (results.isEmpty ? "" : "\n")
        if hitLimit {
            text += "…(find: 遍历条目超过 \(maxWalkEntries) 上限，结果已截断)\n"
        }
        return (text, 0)
    }

    /// history 命令
    private static func historyCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        let limit = args.first.flatMap { Int($0) } ?? 20
        // 取一次快照:原来 suffix(limit) 与 count 是两次独立读,
        // 中途被别人 append/裁剪会算出错误的起始编号
        let snapshot = history
        let recent = snapshot.suffix(limit)
        var out = ""
        var idx = max(0, snapshot.count - recent.count)
        for h in recent {
            out += "\(idx)  \(h)\n"
            idx += 1
        }
        return (out, 0)
    }

    /// tr 字符替换/删除:tr 'ab' 'AB'(替换) tr -d 'x'(删除)
    private static func trCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        var deleteMode = false
        var sets: [String] = []
        for a in args {
            if a == "-d" { deleteMode = true }
            else { sets.append(a) }
        }
        var text = stdin
        if sets.count == 2, !deleteMode {
            // 替换
            let from = sets[0], to = sets[1]
            var out = ""
            for ch in text {
                if let idx = from.firstIndex(of: ch) {
                    let offset = from.distance(from: from.startIndex, to: idx)
                    let targetIdx = to.index(to.startIndex, offsetBy: min(offset, to.count - 1))
                    out.append(to[targetIdx])
                } else {
                    out.append(ch)
                }
            }
            return (out + "\n", 0)
        } else if deleteMode, let set = sets.first {
            var out = ""
            for ch in text where !set.contains(ch) {
                out.append(ch)
            }
            return (out + "\n", 0)
        }
        return ("tr: 用法 tr 'set1' 'set2' 或 tr -d 'set'\n", 1)
    }

    /// cut 按分隔符取字段:cut -d: -f1,3 <file>
    private static func cutCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        var delimiter = "\t"
        var fields: Set<Int> = []
        var files: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-d", i + 1 < args.count {
                delimiter = args[i + 1]; i += 2
            } else if args[i] == "-f", i + 1 < args.count {
                for part in args[i + 1].split(separator: ",") {
                    if let n = Int(part) { fields.insert(n) }
                }
                i += 2
            } else if !args[i].hasPrefix("-") {
                files.append(args[i]); i += 1
            } else {
                i += 1
            }
        }
        var text = stdin
        if !files.isEmpty {
            text = (try? String(contentsOfFile: resolvePath(files[0]), encoding: .utf8)) ?? ""
        }
        if fields.isEmpty { fields = [1] }
        var out: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            guard !rawLine.isEmpty else { continue }
            let parts = rawLine.components(separatedBy: delimiter)
            let picked = fields.sorted().compactMap { n in
                n >= 1 && n <= parts.count ? parts[n - 1] : nil
            }
            out.append(picked.joined(separator: delimiter))
        }
        return (out.joined(separator: "\n") + "\n", 0)
    }

    /// touch 创建空文件 / 更新时间戳
    private static func touchCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        for f in args {
            let p = resolvePath(f)
            if FileManager.default.fileExists(atPath: p) {
                do {
                    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: p)
                } catch { return ("touch: \(f): \(error.localizedDescription)\n", 1) }
            } else {
                if !FileManager.default.createFile(atPath: p, contents: nil) {
                    return ("touch: \(f): 创建失败\n", 1)
                }
            }
        }
        return ("", 0)
    }

    /// tee 输出同时写入文件
    private static func teeCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        var files: [String] = []
        for a in args where !a.hasPrefix("-") {
            files.append(a)
        }
        for f in files {
            do {
                try stdin.write(toFile: resolvePath(f), atomically: true, encoding: .utf8)
            } catch {
                return (stdin + "\n(tee: 写入 \(f) 失败: \(error.localizedDescription))", 1)
            }
        }
        return (stdin, 0)
    }

    /// basename:取路径最后一段
    private static func basenameCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        guard let p = args.first else { return ("basename: 缺少参数\n", 1) }
        return ((p as NSString).lastPathComponent + "\n", 0)
    }

    /// dirname:取目录部分
    private static func dirnameCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        guard let p = args.first else { return ("dirname: 缺少参数\n", 1) }
        let dir = (p as NSString).deletingLastPathComponent
        return ((dir.isEmpty ? "." : dir) + "\n", 0)
    }

    /// du 目录/文件占用空间
    private static func duCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        var humanReadable = false
        var target = cwd
        for a in args {
            if a == "-h" || a == "-sh" { humanReadable = true }
            else if a == "-s" { /* 忽略 */ }
            else if !a.hasPrefix("-") { target = resolvePath(a) }
        }
        let fm = FileManager.default
        var total: Int64 = 0
        // 遍历预算:原来 sizeOf 是**完全无界**的递归(既没有深度上限也没有条目上限),
        // 在沙盒根上跑一次 `du` 会遍历整棵文档树;若里面存在符号链接形成的环,
        // 或者只是文件极多,这一步会把调用线程占用很久且没有任何输出。
        var budget = maxWalkEntries
        func sizeOf(_ path: String, depth: Int) -> Int64 {
            guard depth <= maxWalkDepth, budget > 0 else { return 0 }
            budget -= 1
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
            var size: Int64 = 0
            if isDir.boolValue {
                if let entries = try? fm.contentsOfDirectory(atPath: path) {
                    for e in entries {
                        if budget <= 0 { break }
                        size += sizeOf((path as NSString).appendingPathComponent(e), depth: depth + 1)
                    }
                }
            } else {
                size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            }
            return size
        }
        total = sizeOf(target, depth: 0)
        let label: String
        if humanReadable {
            label = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        } else {
            label = "\(total) bytes"
        }
        // 命中上限时明确说明"这是下限,不是全量",避免用户以为目录真的只有这么大
        let suffix = budget <= 0 ? "(超过 \(maxWalkEntries) 条目上限，统计被截断)" : ""
        return ("\(label)\t\(relativePath(target))\(suffix)\n", 0)
    }

    /// glob 匹配辅助
    private static func matchesGlob(_ name: String, pattern: String) -> Bool {
        let regexStr = globToRegex(pattern)
        guard let re = try? NSRegularExpression(pattern: regexStr) else { return name == pattern }
        let ns = name as NSString
        return re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// 相对路径显示:把 sandboxRoot 前缀替换为 ~
    private static func relativePath(_ path: String) -> String {
        if path.hasPrefix(sandboxRoot) {
            return "~/" + String(path.dropFirst(sandboxRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return path
    }

    private static func wcCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        var showLines = true; var showWords = true; var showChars = true
        var files: [String] = []
        for a in args {
            switch a {
            case "-l": showWords = false; showChars = false
            case "-w": showLines = false; showChars = false
            case "-c": showLines = false; showWords = false
            default: files.append(a)
            }
        }
        var text = stdin
        if !files.isEmpty {
            text = (try? String(contentsOfFile: resolvePath(files[0]), encoding: .utf8)) ?? ""
        }
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let charCount = text.count
        var parts: [String] = []
        if showLines { parts.append("\(lineCount)") }
        if showWords { parts.append("\(wordCount)") }
        if showChars { parts.append("\(charCount)") }
        let label = files.first ?? ""
        return (parts.joined(separator: " ") + " " + label + "\n", 0)
    }

    private static func grepCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        var ignoreCase = false
        var pattern = ""
        var files: [String] = []
        for a in args {
            if a == "-i" { ignoreCase = true }
            else if pattern.isEmpty { pattern = a }
            else { files.append(a) }
        }
        if pattern.isEmpty { return ("grep: 缺少 pattern\n", 1) }
        var text = stdin
        if !files.isEmpty {
            text = (try? String(contentsOfFile: resolvePath(files[0]), encoding: .utf8)) ?? ""
        }
        var hits: [String] = []
        for line in text.components(separatedBy: "\n") {
            let matches = ignoreCase
                ? line.lowercased().contains(pattern.lowercased())
                : line.contains(pattern)
            if matches { hits.append(line) }
        }
        return (hits.joined(separator: "\n") + "\n", hits.isEmpty ? 1 : 0)
    }

    private static func sortCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        let reverse = args.contains("-r")
        let unique  = args.contains("-u")
        let files = args.filter { !$0.hasPrefix("-") }
        var text = stdin
        if !files.isEmpty {
            text = (try? String(contentsOfFile: resolvePath(files[0]), encoding: .utf8)) ?? ""
        }
        var lines = text.components(separatedBy: "\n").filter { !$0.isEmpty || true }
        lines.sort()
        if reverse { lines.reverse() }
        if unique {
            var seen: [String] = []
            for l in lines where !seen.contains(l) { seen.append(l) }
            lines = seen
        }
        return (lines.joined(separator: "\n") + "\n", 0)
    }

    private static func uniqCmd(_ args: [String], stdin: String) -> (text: String, exitCode: Int) {
        let files = args.filter { !$0.hasPrefix("-") }
        var text = stdin
        if !files.isEmpty {
            text = (try? String(contentsOfFile: resolvePath(files[0]), encoding: .utf8)) ?? ""
        }
        var last = ""
        var out: [String] = []
        for l in text.components(separatedBy: "\n") where l != last {
            out.append(l); last = l
        }
        return (out.joined(separator: "\n") + "\n", 0)
    }

    private static func exportCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        var changed = false
        for a in args {
            if let eq = a.firstIndex(of: "=") {
                let k = String(a[..<eq])
                let v = String(a[a.index(after: eq)...])
                // 用 setEnvVar:在锁内完成读-改-写(`env[k] = v` 会 get+set 两次加锁,并发下丢更新)
                setEnvVar(k, v)
                changed = true
            }
        }
        return ("", changed ? 0 : 1)
    }

    private static func cdCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        let target = args.first ?? "~"
        let p = resolvePath(target)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            // cwd 与 PWD 一起在锁内更新(见 updateCwd)
            updateCwd(p)
            return ("", 0)
        } else {
            return ("cd: \(target): 不是目录\n", 1)
        }
    }

    private static func statCmd(_ args: [String]) -> (text: String, exitCode: Int) {
        guard let f = args.first else { return ("stat: 缺少文件\n", 1) }
        let p = resolvePath(f)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: p) else {
            return ("stat: 无法访问 \(p)\n", 1)
        }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date).map { String(describing: $0) } ?? "?"
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return ("文件: \(p)\n大小: \(size) 字节\n修改时间: \(mtime)\n类型: \(isDir ? "目录" : "文件")\n", 0)
    }

    /// 重置沙箱(测试用):cwd 回 root、env 只重置 PWD(其它 export 变量与命令历史保留)。
    /// 新代码请用 `resetSession()`(它会把 export 变量与历史也一起清掉)。
    static func reset() {
        stateLock.lock(); defer { stateLock.unlock() }
        _cwd = sandboxRoot
        _env["PWD"] = sandboxRoot
    }
}
