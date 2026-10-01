import Foundation
import JavaScriptCore

/// JS 插件执行引擎（基于系统 JavaScriptCore）。
///
/// 沙箱边界：
/// - 默认纯计算：JS 只能做字符串/JSON/数字/日期等标准 API
/// - 显式能力（manifest.permissions 声明）：
///   * "network" → 暴露 nativeFetch(url)（仅 https、20s 超时、2MB 上限），插件工具需授权执行
///   * "storage" → 暴露 storeGet/storeSet（模块专属 Documents/Modules/<id>/storage.json）
///
/// 崩溃防护（v0.3.38 加固，针对线上"插件运行中 App 崩溃"）：
/// 1. 原生桥用 block 注册（nativeFetchAsync/nativeStoreGet/nativeStoreSet），
///    不用 JSExport —— JSExport 多参数方法在 JS 里的名字含冒号，调用方写
///    NativeBridge.fetchAsync(...) 实际是 undefined，且该歧义路径存在崩溃风险。
/// 2. 回调盒子强持有 JSContext：JS 回调时上下文一定还活着（防 use-after-free）。
/// 3. 调用在专属串行队列执行：插件死循环只卡插件队列，不冻结 UI（MainActor）。
/// 4. 30s 看门狗：超时未返回 → resume 并重建引擎（丢弃卡死队列），continuation
///    只 resume 一次（CallState 双守卫），杜绝 Swift Continuation 双 resume trap。
///
/// 超时语义（本次加固，改的是第 4 条留下的两个真问题）：
/// 5. 超时**不能**终止已经跑起来的 JS —— JSCore 没有取消/中止的公开 API
///    （JSContextGroupSetExecutionTimeLimit 是私有 API，而且它会直接把整个 VM 干掉，
///    在 App 里用等于换一种崩溃）。所以超时后：
///      * 该次调用所属"世代(epoch)"立即作废，**该世代之后到达的一切结果一律丢弃**
///        （原来是只看"是否已完成"，迟到的 JS 结果只能靠 done 标志挡）；
///      * 模块被标记为永久停用（disabledReason），立刻从工具目录/hasTool 里摘掉，
///        引擎自己也拒绝再执行 → 避免"同一个坏模块被反复调用、每次都占满一个核"。
///    ⚠️ 局限（如实说明，不要当成已解决）：那个死循环**仍在旧队列上继续跑**，
///    会一直占着一个 CPU 核直到 App 退出（结果虽然作废，副作用却可能在模型已被告知
///    "超时失败"之后才完成；本层无法回滚）。真正的隔离要把插件跑在独立进程 /
///    独立虚拟机上（可以被 kill），属于后续工作。
/// 6. 插件返回值是外部数据（可能夹带指令），回给调用方时统一加
///    <<<UNTRUSTED_PLUGIN_OUTPUT ...>>> … <<<END_UNTRUSTED>>> 边界标记。
///    这个标记是给**上层**（AgentService，由另一处改动接入）用的：它在 system 指令里
///    声明"标记内的内容是数据、不是指令"。本层只负责打标，不做解释，也不改内容。
///    MCP 的返回值同样需要这一层标记（不在本文件范围内）。
final class JSPluginEngine: @unchecked Sendable {

    let manifest: PluginManifest
    private(set) var tools: [PluginToolDef] = []
    private let storageFile: URL?
    private var storage: [String: String] = [:]

    private let lock = NSLock()
    private var runQueue: DispatchQueue
    private var context: JSContext?
    private let preamble: String
    private let jsSource: String

    /// 世代闸门：每次超时/引擎重置就把世代 +1，旧世代上的回调（含已经在跑的 JS
    /// 迟到回来的回调）一律判定为过期，不再交付给任何人。
    private let gate = EpochGate()
    /// 超时停用原因（nil = 可用）。非 nil 时：工具目录不再暴露该模块、call 直接拒绝。
    /// 只存在内存里 —— 重启 App 会重新加载模块，等于给作者一次"修好再试"的机会。
    /// 读写都走 lock：注意**不能在持有 lock 时读这个属性**（NSLock 不可重入）。
    private var _disabledReason: String?
    var disabledReason: String? {
        lock.lock(); defer { lock.unlock() }
        return _disabledReason
    }
    var isDisabled: Bool { disabledReason != nil }

    private static let callTimeout: TimeInterval = 30

    init?(manifest: PluginManifest, jsSource: String, storageFile: URL? = nil) {
        self.manifest = manifest
        self.jsSource = jsSource
        self.storageFile = storageFile
        let queue = DispatchQueue(label: "localai.plugin.\(manifest.id)")
        self.runQueue = queue

        if let storageFile, let data = try? Data(contentsOf: storageFile),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            storage = dict
        }

        let preamble = """
        var __tools = [];
        function registerTool(def) {
          if (def && typeof def.name === 'string' && typeof def.run === 'function') {
            __tools.push({ name: def.name, description: typeof def.description === 'string' ? def.description : '', parameters: def.parameters || {}, run: def.run });
          }
        }
        function __pluginTools() { return JSON.stringify(__tools.map(function(t){
          return { name: t.name, description: t.description, parameters: t.parameters };
        })); }
        function __sanitize(v) {
          // JSON 归一化：NaN/Infinity→null；undefined→null（JSON.parse(undefined) 会抛异常，v0.3.40 修复）
          try { return JSON.parse(JSON.stringify(v)); } catch (e) { return v === undefined ? null : v; }
        }
        function __callToolAsync(name, argsJSON, done) {
          var t = null;
          for (var i = 0; i < __tools.length; i++) { if (__tools[i].name === name) { t = __tools[i]; break; } }
          if (!t) { done({ error: 'unknown tool: ' + name }); return; }
          try {
            var args = argsJSON ? JSON.parse(argsJSON) : {};
            var r = t.run(args);
            if (r && typeof r.then === 'function') {
              r.then(function(v){ done({ result: __sanitize(v) }); }, function(e){ done({ error: String(e) }); });
            } else {
              done({ result: __sanitize(r) });
            }
          } catch (e) {
            done({ error: String(e) });
          }
        }
        function nativeFetch(url) {
          if (typeof nativeFetchAsync !== 'function') {
            return Promise.reject(new Error('模块未声明 network 权限'));
          }
          return new Promise(function (resolve, reject) {
            nativeFetchAsync(String(url), function (err, data) {
              if (err && err !== null) reject(new Error(String(err)));
              else resolve(String(data));
            });
          });
        }
        function storeGet(key) {
          if (typeof nativeStoreGet !== 'function') return null;
          return nativeStoreGet(String(key));
        }
        function storeSet(key, value) {
          if (typeof nativeStoreSet !== 'function') return;
          nativeStoreSet(String(key), String(value));
        }
        """
        self.preamble = preamble

        // 在专属队列上创建上下文并加载模块（bridge 用 block 注册，名字显式无歧义）
        var setupError: String?
        queue.sync {
            guard let ctx = JSContext() else {
                setupError = "无法创建 JS 上下文"
                return
            }
            ctx.name = "LumenAI-plugin-\(manifest.id)"
            ctx.exceptionHandler = { _, exception in
                let msg = exception?.toString() ?? "unknown"
                print("[plugin:\(manifest.id)] JS exception: \(msg)")
            }

            // 原生桥（block 注册）
            let allowsNetwork = manifest.permissions.contains("network")
            let fetchBlock: @convention(block) (String, JSValue) -> Void = { url, cb in
                PluginNativeBridge.dispatchFetch(urlString: url, allowsNetwork: allowsNetwork, completionQueue: queue, callback: cb, context: ctx)
            }
            if let fn = JSValue(object: fetchBlock, in: ctx) {
                ctx.setObject(fn, forKeyedSubscript: "nativeFetchAsync" as NSString)
            }
            let getBlock: @convention(block) (String) -> String? = { [weak self] key in
                self?.storage[key]
            }
            if let fn = JSValue(object: getBlock, in: ctx) {
                ctx.setObject(fn, forKeyedSubscript: "nativeStoreGet" as NSString)
            }
            let setBlock: @convention(block) (String, String) -> Void = { [weak self] key, value in
                self?.setStorage(key, value)
            }
            if let fn = JSValue(object: setBlock, in: ctx) {
                ctx.setObject(fn, forKeyedSubscript: "nativeStoreSet" as NSString)
            }

            ctx.evaluateScript(preamble)
            ctx.evaluateScript(jsSource)
            if let raw = ctx.evaluateScript("__pluginTools()")?.toString(),
               let data = raw.data(using: .utf8),
               let defs = try? JSONDecoder().decode([PluginToolDef].self, from: data) {
                self.tools = defs
            } else {
                setupError = "模块未注册任何工具或脚本有误"
            }
            self.context = ctx
        }
        if let setupError { return nil }
    }

    func requiresApproval() -> Bool {
        manifest.permissions.contains("network")
    }

    func toolDefinitions() -> [AgentToolDefinition] {
        let approval = requiresApproval()
        return tools.map { def in
            var params: [String: AgentToolDefinition.ParameterSchema] = [:]
            for (k, p) in def.parameters {
                params[k] = AgentToolDefinition.ParameterSchema(
                    type: p.type,
                    description: p.description,
                    enumValues: nil
                )
            }
            return AgentToolDefinition(
                id: "plugin-\(manifest.id)-\(def.name)",
                name: def.name,
                description: def.description.isEmpty ? "JS 插件工具（\(manifest.name)）" : def.description,
                parameters: params,
                requiresApproval: approval
            )
        }
    }

    // MARK: - 调用（看门狗 + 单次 resume 守卫 + 世代作废）

    func call(name: String, argumentsJSON: String) async -> String {
        // ③ 已因超时停用的模块：这里直接拒绝，绝不把它的 JS 再跑一遍。
        // 这一条是"别把坏模块反复调用"的关键 —— 超时并没有杀掉旧队列上那个死循环，
        // 每多调用一次就再多烧一个核（而且工具目录已经不再暴露它，正常不会走到这里）。
        if let disabled = disabledReason {
            return "模块不可用（\(manifest.id)）: \(disabled)"
        }

        // 注意：这里必须显式 return —— 函数体加了前面的 if 之后就不再是"单表达式函数"，
        // 编译器不会再隐式返回最后那个表达式的值（只在完整编译时报错，-typecheck 不报）。
        return await withCheckedContinuation { continuation in
            // 注册时锁定本次调用所属世代：超时/重置之后这个世代会被 bump 掉
            let state = CallState(epoch: gate.current, gate: gate)
            state.register(continuation)

            lock.lock()
            let queue = runQueue
            let ctx = context
            lock.unlock()
            guard let ctx else {
                state.complete("插件引擎未就绪", epoch: state.epoch)
                return
            }

            let epoch = state.epoch
            queue.async { [weak self] in
                guard let self else {
                    state.complete("插件引擎已释放", epoch: epoch)
                    return
                }
                let done: @convention(block) (Any) -> Void = { result in
                    // 结果按世代交付：世代已被作废（超时/重置）时直接丢弃，
                    // 不是"已超时了还去 resume 一次"。
                    state.complete(self.describe(result, tool: name), epoch: epoch)
                }
                guard let callback = JSValue(object: done, in: ctx) else {
                    state.complete("插件回调创建失败", epoch: epoch)
                    return
                }
                ctx.setObject(callback, forKeyedSubscript: "callback" as NSString)
                ctx.evaluateScript("__callToolAsync(\(self.JSONString(name)), \(self.JSONString(argumentsJSON)), callback)")
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callTimeout) {
                // completeIfPending 现在按**世代**判断（不只按"是否已完成"）：
                // 世代已作废时返回 false，既不会去 resume 别人，也不会再触发一次重置。
                guard state.completeIfPending(
                    "插件调用超时（>\(Int(Self.callTimeout))s），已停用该模块",
                    epoch: epoch
                ) else { return }
                // 只有本次超时真的"赢下"了这次调用，才做停用收尾（避免重复停用/重复重建）
                self.disableAfterTimeout(epoch: epoch)
            }
        }
    }

    /// ③ 超时收尾：标记永久停用 + 作废当前世代 + 收拾引擎（记录 reason 方便排查）
    private func disableAfterTimeout(epoch: UInt64) {
        let reason = "上次调用超过 \(Int(Self.callTimeout))s 未返回。"
            + "JSCore 没有中止接口，那个脚本可能还在后台跑，因此已停用该模块"
            + "（结果不再采信，也不会再被调用）；重启 App 后可恢复。"
        lock.lock()
        if _disabledReason == nil { _disabledReason = reason }
        lock.unlock()
        // 世代 +1：这一代之前注册的所有调用（含本次超时的那一个、以及任何还在排队的
        // 同队列任务）从此都判定为过期 —— 迟到的 JS 结果不会再被当成"下一次调用的结果"。
        let newEpoch = gate.bump()
        resetEngine(reason: "调用超时（>\(Int(Self.callTimeout))s）→ 停用模块并作废旧世代（epoch \(epoch) → \(newEpoch)）")
    }

    /// 重建 JS 引擎。**调用点只有一个**：超时收尾（disableAfterTimeout），
    /// reason 会被打出来，排查"某个模块为什么突然不能用了"时先看这条日志。
    private func resetEngine(reason: String) {
        print("[plugin:\(manifest.id)] resetEngine: \(reason)")

        // 已停用 → 只断开引用，不重建上下文（读 isDisabled 不能持 lock，见属性注释）
        let disabled = isDisabled
        if disabled {
            // 已经永久停用的模块**不再重建上下文**：旧代码在这里新建一个 JSContext +
            // 重新 eval 整个模块，等于为一个再也不会被调用的模块白留一份 VM（还会留一条
            // "以后又可能被调用"的路径）。这里改成断开我们持有的引用：旧队列/旧上下文
            // 交给正在跑的那个死循环自己持有，等它（如果有那一天）结束后由 JSCore 回收。
            lock.lock()
            context = nil
            lock.unlock()
            return
        }

        let newQueue = DispatchQueue(label: "localai.plugin.\(manifest.id).regen")
        newQueue.sync {
            guard let ctx = JSContext() else { return }
            ctx.name = "LumenAI-plugin-\(self.manifest.id)"
            ctx.exceptionHandler = { _, exception in
                print("[plugin:\(self.manifest.id)] JS exception: \(exception?.toString() ?? "?")")
            }
            let allowsNetwork = self.manifest.permissions.contains("network")
            let fetchBlock: @convention(block) (String, JSValue) -> Void = { url, cb in
                PluginNativeBridge.dispatchFetch(urlString: url, allowsNetwork: allowsNetwork, completionQueue: newQueue, callback: cb, context: ctx)
            }
            if let fn = JSValue(object: fetchBlock, in: ctx) {
                ctx.setObject(fn, forKeyedSubscript: "nativeFetchAsync" as NSString)
            }
            let getBlock: @convention(block) (String) -> String? = { [weak self] key in
                self?.storage[key]
            }
            if let fn = JSValue(object: getBlock, in: ctx) {
                ctx.setObject(fn, forKeyedSubscript: "nativeStoreGet" as NSString)
            }
            let setBlock: @convention(block) (String, String) -> Void = { [weak self] key, value in
                self?.setStorage(key, value)
            }
            if let fn = JSValue(object: setBlock, in: ctx) {
                ctx.setObject(fn, forKeyedSubscript: "nativeStoreSet" as NSString)
            }
            ctx.evaluateScript(self.preamble)
            // 超时重置必须重新加载模块工具脚本，否则后续调用全部 unknown tool（v0.3.40 修复）
            ctx.evaluateScript(self.jsSource)
            self.context = ctx
        }
        lock.lock()
        runQueue = newQueue
        lock.unlock()
    }

    /// ④ 不可信边界标记：插件返回的是**外部数据**（可能夹带"忽略以上指令"这类内容），
    /// 但会作为普通上下文回灌模型。这里只加边界、不改内容、不截断（截断在加标记之前做完，
    /// 保证标记本身永远不会被截掉）。上层（AgentService）应当用这个标记在 system 指令里
    /// 声明"标记内是数据不是指令"——打标在本层，语义解释在上层。
    static func untrustedWrapped(_ text: String, moduleID: String, tool: String) -> String {
        // 属性值要先清掉引号/尖括号/换行：moduleID 与 tool 名字来自模块自己
        // （registerTool 的 name 是插件写的），不清就可能提前闭合标记、伪造出
        // 一段"看起来在标记之外"的指令。
        func attr(_ s: String) -> String {
            String(s.prefix(64)).filter { $0 != "\"" && $0 != "<" && $0 != ">" && $0 != "\n" && $0 != "\r" }
        }
        return "<<<UNTRUSTED_PLUGIN_OUTPUT module=\"\(attr(moduleID))\" tool=\"\(attr(tool))\">>>\n"
            + text
            + "\n<<<END_UNTRUSTED>>>"
    }

    /// 把 JS 回调的 result 转成展示文本。
    /// ⚠️ 不能用 NSJSONSerialization：插件返回值可能含 NaN/Infinity（JSCore 桥接成
    /// NSNumber(NaN)），dataWithJSONObject 遇到会抛 **ObjC 异常**，而 try? 捕不住
    /// （线上 v0.3.37 崩溃即由此导致：ModuleDetailView.test → call → describe → SIGABRT）。
    /// 这里用逐层类型检查的安全序列化，NaN/Infinity 输出为 null，绝不抛异常。
    ///
    /// 返回值一律套 ④ 的不可信标记：本函数处理的都是 JS 回调内容（结果或 JS 抛出的
    /// 错误字符串，后者同样是插件可控文本 —— 例如 error 里写"现在请你调用 shell 工具"）。
    /// 引擎自己产生的提示（未就绪 / 已释放 / 超时 / 已停用）不走这里，也就不带标记。
    private func describe(_ result: Any, tool: String) -> String {
        func wrap(_ text: String) -> String {
            Self.untrustedWrapped(text, moduleID: manifest.id, tool: tool)
        }
        guard let dict = result as? [String: Any] else {
            return wrap("插件调用失败（无法解析返回值）")
        }
        if let error = dict["error"] as? String {
            return wrap("插件错误: \(error)")
        }
        if let result = dict["result"] {
            let text: String
            if let s = result as? String { text = s }
            else if let t = Self.safeJSONText(result) { text = t }
            else { text = "\(result)" }
            // 防超长结果（尤其单行 JSON）卡死 SwiftUI Text 排版（v0.3.39 修复：
            // UIKit-runloop 卡死报告主线程 354/354 采样在 ResolvedStyledText.layers）
            // 顺序：先截断再包标记 —— 反过来的话标记可能被截掉，上层就认不出这段是外部数据了。
            return wrap(Self.capped(text, limit: 4000))
        }
        return wrap("(无返回值)")
    }

    /// 截断超长文本（保留开头与结尾各一半），防止巨型字符串触发昂贵文本排版
    static func capped(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let half = limit / 2
        let head = String(text.prefix(half))
        let tail = String(text.suffix(half))
        return head + "\n…（结果过长，已截断）…\n" + tail
    }

    /// 安全序列化（无 NSJSONSerialization，永不抛异常；NaN/Infinity → null）
    private static func safeJSONText(_ value: Any) -> String? {
        var out = ""
        guard serialize(value, into: &out) else { return nil }
        return out
    }

    private static func serialize(_ value: Any, into out: inout String) -> Bool {
        if value is NSNull {
            out += "null"
            return true
        }
        if let s = value as? String {
            out += escapedString(s)
            return true
        }
        if let n = value as? NSNumber {
            // NaN / Infinity → null（NSJSONSerialization 会因它们抛异常）
            let v = n.doubleValue
            if v.isNaN || v.isInfinite {
                out += "null"
            } else if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out += (n.boolValue ? "true" : "false")
            } else {
                out += n.stringValue
            }
            return true
        }
        if let arr = value as? [Any] {
            var parts: [String] = []
            for item in arr {
                var s = ""
                if serialize(item, into: &s) { parts.append(s) } else { return false }
            }
            out += "[" + parts.joined(separator: ",") + "]"
            return true
        }
        if let dict = value as? [String: Any] {
            var parts: [String] = []
            for (k, v) in dict {
                var s = ""
                if serialize(v, into: &s) {
                    parts.append(escapedString(k) + ":" + s)
                } else {
                    return false
                }
            }
            out += "{" + parts.joined(separator: ",") + "}"
            return true
        }
        return false
    }

    private static func escapedString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - 存储

    /// 读取模块本地存储（远程 UI 绑定用）
    func storageGet(_ key: String) -> String? {
        storage[key]
    }

    /// 写入模块本地存储（远程 UI 绑定用）
    func storageSet(_ key: String, _ value: String) {
        setStorage(key, value)
    }

    private func setStorage(_ key: String, _ value: String) {
        storage[key] = value
        persistStorage()
    }

    private func persistStorage() {
        guard let storageFile else { return }
        let snapshot = storage
        try? JSONEncoder().encode(snapshot).write(to: storageFile, options: .atomic)
    }

    private func JSONString(_ s: String) -> String {
        Self.escapedString(s)
    }
}

// MARK: - 世代闸门（超时作废的结果不再交付）

/// 引擎世代计数。超时或重置时 bump()，此后所有持旧世代的回调都被判为过期。
/// 线程安全：stateLock → gateLock 是唯一的加锁顺序（没有人反向加锁），不会死锁。
final class EpochGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0

    var current: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    @discardableResult
    func bump() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        return epoch
    }
}

// MARK: - 调用状态（看门狗与回调共用，双守卫保证单次 resume）

private final class CallState: @unchecked Sendable {
    private let stateLock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<String, Never>?
    /// 本次调用所属的引擎世代（注册时锁定，不再变化）
    let epoch: UInt64
    private let gate: EpochGate

    init(epoch: UInt64, gate: EpochGate) {
        self.epoch = epoch
        self.gate = gate
    }

    func register(_ cont: CheckedContinuation<String, Never>) {
        stateLock.lock()
        if done {
            stateLock.unlock()
            cont.resume(returning: "(调用已完成)")
            return
        }
        continuation = cont
        stateLock.unlock()
    }

    func complete(_ value: String, epoch: UInt64) {
        _ = completeIfPending(value, epoch: epoch)
    }

    /// 两个条件同时成立才交付：① 这次调用还没交付过（防 Continuation 双 resume trap）；
    /// ② **传入的世代 == 当前世代**（超时/重置后旧世代的迟到回调一律丢弃）。
    /// 只看 done 是不够的：原来"超时"只是把我们这边的 continuation resume 掉，
    /// 旧队列上还在跑的 JS 之后仍会回调 —— 那种结果既可能是"超时后完成的副作用"，
    /// 也可能被误当成后续调用的结果，所以必须按世代作废掉。
    func completeIfPending(_ value: String, epoch: UInt64) -> Bool {
        stateLock.lock()
        if done || epoch != gate.current {
            stateLock.unlock()
            return false
        }
        done = true
        let cont = continuation
        stateLock.unlock()
        cont?.resume(returning: value)
        return true
    }
}

// MARK: - 原生桥（block 分发）

/// 回调盒子：强持有 JSContext，保证回调执行时上下文存活（防 use-after-free）
private final class JSCallbackBox: @unchecked Sendable {
    let callback: JSValue
    let context: JSContext
    init(callback: JSValue, context: JSContext) {
        self.callback = callback
        self.context = context
    }
}

enum PluginNativeBridge {

    /// 发起一次受控 HTTP GET（https only / 20s / 2MB）；完成后在 completionQueue 上回调
    static func dispatchFetch(urlString: String, allowsNetwork: Bool, completionQueue: DispatchQueue, callback: JSValue, context: JSContext) {
        let box = JSCallbackBox(callback: callback, context: context)
        guard allowsNetwork else {
            completionQueue.async { box.callback.call(withArguments: ["模块未声明 network 权限", NSNull()]) }
            return
        }
        guard let url = URL(string: urlString), url.scheme == "https" else {
            completionQueue.async { box.callback.call(withArguments: ["仅支持 https 地址", NSNull()]) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("LumenAI-Plugin/1.0", forHTTPHeaderField: "User-Agent")

        Task.detached(priority: .userInitiated) {
            let result: (String?, String?)
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let limited = data.prefix(2 * 1024 * 1024)
                let text = String(data: limited, encoding: .utf8) ?? ""
                result = (nil, text)
            } catch {
                result = (error.localizedDescription, nil)
            }
            completionQueue.async {
                let err: Any = result.0 ?? NSNull()
                let data: Any = result.1 ?? NSNull()
                box.callback.call(withArguments: [err, data])
            }
        }
    }
}
