import Foundation

/// 失败自动重试的统一判据。
///
/// 为什么要有这一层：原来每个网络调用各自处理错误 —— 模型下载、云端对话、
/// 插件索引、更新检查、MCP 连接，五处各写一遍，结果是**谁都不重试**，
/// 而失败提示一律是"网络请求失败"，用户唯一能做的就是手动再点一次。
/// 而实际发生的事里，绝大多数是**瞬时**的：连接被重置、DNS 抖动、对面 5xx、
/// 或者被限流 429 —— 这些隔一两秒重试就过了。
///
/// 反面同样重要：**不能对所有错误都重试**。400/401/404 这类是"请求本身就是错的"，
/// 重试只会把同一个错误重复三遍、让用户多等三倍时间，最后还是失败。
/// 所以这里把"值得重试"和"不值得"分开，而不是无脑循环。
enum RetryPolicy {

    /// 默认重试次数（含首次之外的重试次数）
    static let defaultAttempts = 3
    /// 首次退避
    static let baseDelay: Double = 1.0
    /// 退避上限，避免第 N 次等到几十秒
    static let maxDelay: Double = 16.0

    /// 这个错误值不值得重试。
    ///
    /// 判据按可靠性排序（先看能确定的结构化信息，再看文本）：
    /// 1. `URLError` 的 code —— 最可靠；
    /// 2. HTTP 状态码（通过 `HTTPURLResponse` 带出来的自定义错误）；
    /// 3. 兜底：一律**不重试**。
    ///
    /// 第 3 条是刻意的：无法判断时选择不重试，因为"该重试而没重试"用户还能手动再点，
    /// 而"不该重试却重试了三次"会让一个明确的错误（比如模型文件 404）每次都拖 7 秒才报出来。
    static func isTransient(_ error: Error) -> Bool {
        let ns = error as NSError

        // ① 明确的取消：不是失败，是用户/我们主动停的，重试等于把用户的操作撤销
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return false }

        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,     // 断网：网络恢复后重试是唯一有意义的动作
                 NSURLErrorResourceUnavailable,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorSecureConnectionFailed,     // TLS 握手抖动，很常见
                 NSURLErrorBadServerResponse:
                return true
            default:
                return false
            }
        }

        // ② HTTP 状态码：5xx 与 429 是"服务器现在不行/让我慢点"，等一下再说有意义
        if let code = httpStatusCode(of: error) {
            if code == 408 || code == 429 { return true }
            return (500...599).contains(code)
        }

        return false
    }

    /// 第 `attempt` 次重试前该等多久（attempt 从 1 开始）。
    ///
    /// 指数退避 + **少量随机抖动**。抖动不是装饰：没有它的话，
    /// 断网恢复的瞬间所有待重试的请求会在同一毫秒一起打出去（惊群），
    /// 对面要是刚起来很容易又被压垮，然后大家一起再等下一轮。
    static func delay(attempt: Int, base: Double = baseDelay, cap: Double = maxDelay) -> Double {
        let exp = base * pow(2.0, Double(max(0, attempt - 1)))
        let capped = min(exp, cap)
        // ±25% 抖动
        return capped * Double.random(in: 0.75...1.25)
    }

    /// 带自动重试地执行一段异步操作。
    ///
    /// - Parameter shouldRetry: 允许调用方追加自己的判据（比如"流读到一半断了"这种
    ///   只有调用方才知道的情况）。默认只看 `isTransient`。
    static func run<T>(
        attempts: Int = defaultAttempts,
        label: String,
        shouldRetry: ((Error) -> Bool)? = nil,
        onRetry: ((Int, Error) -> Void)? = nil,
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            do {
                return try await operation()
            } catch {
                lastError = error
                let retryable = shouldRetry?(error) ?? isTransient(error)
                if !retryable || attempt == max(1, attempts) { throw error }
                let wait = delay(attempt: attempt)
                onRetry?(attempt, error)
                print("[retry] \(label) 第 \(attempt) 次失败（\(type(of: error))），"
                      + "\(String(format: "%.1f", wait))s 后重试")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    // MARK: - 辅助

    /// 从任意错误里尽力挖出 HTTP 状态码。
    /// 为什么这么绕：状态码可能藏在 NSError 的 userInfo 里（URLSession 的
    /// `URLErrorNetworkConnectionLost` 就常带着 `NSErrorFailingURLStringKey` 等），
    /// 也可能被上游包成自己的错误类型。挖不到就返回 nil，由调用方决定。
    static func httpStatusCode(of error: Error) -> Int? {
        let ns = error as NSError
        for key in ["HTTPStatus", "statusCode", "httpStatusCode"] {
            if let v = ns.userInfo[key] as? Int { return v }
        }
        if ns.domain == "HTTP", let code = Int(ns.localizedDescription.prefix(3)) {
            return code
        }
        return nil
    }
}
