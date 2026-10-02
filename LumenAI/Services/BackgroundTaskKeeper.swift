import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 让「正在进行的事」在 App 切到后台之后还能多活一会儿。
///
/// 为什么需要它：iOS 在 App 进入后台后很快就挂起进程 —— 网络流断开、正在生成的那一轮
/// 直接死掉。表现是用户切出去看一眼消息再回来，气泡永远停在「思考中…」，
/// 而且**没有任何报错**（因为进程根本没机会写错误）。
/// `beginBackgroundTask` 是系统给的官方手段：申请一段时间继续执行，
/// 到期时系统回调 expirationHandler，我们必须在那个回调里**主动收尾**。
///
/// 一个必须讲清楚的限制（不写下来就会被当成 bug）：
/// 这段延长时间是**系统给的，通常只有几十秒**，不是无限的。
/// 所以这里的定位不是"让长任务在后台跑完"（iOS 不给这个能力，除非换成
/// 后台 URLSession 那种由系统托管的传输），而是：
///   1. 给短任务（一次网络请求、一次工具调用、一轮生成）争取时间跑完；
///   2. 到期时**体面地收尾**并把状态落盘，而不是被系统直接杀掉留下一个僵住的气泡。
@MainActor
final class BackgroundTaskKeeper {
    static let shared = BackgroundTaskKeeper()

    /// 任务标识（同一 key 重复 begin 是幂等的：后一次返回已有的 token）
    enum Key: String {
        /// 一轮生成 / agent 循环
        case generation
        /// 模型下载（后台 URLSession 由系统托管，这里只覆盖"收尾"那一段）
        case download
    }

    private var tokens: [Key: UIBackgroundTaskIdentifier] = [:]
    /// 到期的回调：注册方在这里做「停止并落盘」。
    private var onExpire: [Key: () -> Void] = [:]
    /// 供 UI 显示（"正在后台继续…"之类）
    private(set) var activeKeys: Set<Key> = []

    private init() {}

    var isHolding: Bool { !tokens.isEmpty }

    /// 申请继续执行。`onExpire` 会在系统给的时间用尽时被调用 ——
    /// 实现里**必须**尽快停下手上的活并保存状态，否则进程随时会被挂起。
    func begin(_ key: Key, onExpire handler: (() -> Void)? = nil) {
        #if canImport(UIKit)
        // 已经在持有就不重复申请：重复申请会返回一个新 token 而旧的那个再也没人 end，
        // 泄漏一个 background task 会让 App 被系统判为滥用（进而在真机上被限制）。
        guard tokens[key] == nil else { return }
        // ⚠️ 参数名不能叫 onExpire：这里同时有一个同名字典 `onExpire` 存回调，
        // 参数会把它遮蔽掉，于是 `onExpire[key] = ...` 变成"给一个闭包做下标"，
        // 编译报 "value of type '() -> Void' has no subscripts"。
        if let handler { onExpire[key] = handler }
        let token = UIApplication.shared.beginBackgroundTask(withName: key.rawValue) { [weak self] in
            // ⚠️ 这个回调在**主线程**上、并且系统给的时间已经用尽。
            // 从这里返回之后如果还没 end，进程就会被挂起甚至被杀。
            Task { @MainActor in
                self?.expire(key)
            }
        }
        tokens[key] = token
        activeKeys.insert(key)
        #endif
    }

    /// 主动结束（干完了就立刻调，别占着额度）。
    func end(_ key: Key) {
        #if canImport(UIKit)
        guard let token = tokens.removeValue(forKey: key) else { return }
        activeKeys.remove(key)
        onExpire[key] = nil
        UIApplication.shared.endBackgroundTask(token)
        #endif
    }

    private func expire(_ key: Key) {
        #if canImport(UIKit)
        guard let token = tokens.removeValue(forKey: key) else { return }
        activeKeys.remove(key)
        let handler = onExpire.removeValue(forKey: key)
        // 顺序很重要：先 end 再把控制权交出去。
        // 反过来的话，handler 里如果做了一点耗时的事（落盘、拼一句提示），
        // 这段时间里我们仍然持有 token，而系统已经认为额度用尽 —— 有点自欺欺人。
        // 先 end 表示"我们知道时间到了"，然后立刻收尾。
        UIApplication.shared.endBackgroundTask(token)
        handler?()
        #endif
    }
}
