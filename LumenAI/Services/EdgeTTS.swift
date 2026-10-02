import Foundation
import CryptoKit

/// 微软 Edge「朗读」的在线语音合成 —— **免费、无需 API Key、无需注册**。
///
/// 为什么把它做成一个独立引擎，而不是塞进现有那条「网络 TTS」：
/// 现有那条走的是 OpenAI 兼容的 `/audio/speech`，**必须先配一家 Provider 和 Key**。
/// 而 Edge 这条路不需要任何账号，开箱即用 —— 对「本地模型跑不动」的设备来说，
/// 这是唯一零门槛的出路。
///
/// 代价是它**不是公开 API**：用的是 Edge 浏览器朗读功能的内部端点，
/// 所以微软随时可能改协议或封禁。因此这里把失败原因如实往外抛，
/// 由上层回退系统语音，而不是静默无声。
enum EdgeTTS {

    // MARK: - 协议常量

    /// Edge 朗读功能内置的固定 token（所有客户端共用，不是用户凭证）
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    /// 伪装成的 Edge 版本。服务端会校验 `Sec-MS-GEC-Version` 的第一段。
    static let chromiumVersion = "143.0.3650.75"
    /// Windows 文件时间纪元（1601-01-01）到 Unix 纪元（1970-01-01）的秒数
    static let windowsEpoch: Int64 = 11_644_473_600
    /// 输出格式。48kbps 单声道 mp3 —— 24kHz 采样，AVAudioPlayer 直接可播。
    static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"

    // MARK: - DRM 令牌

    /// 生成 `Sec-MS-GEC`。
    ///
    /// 没有它握手会被拒（403）。算法是把「当前时间向下取整到 5 分钟」
    /// 换算成 100 纳秒刻度，拼上固定 token 后取 SHA-256 大写十六进制。
    ///
    /// ⚠️ 全程用 `Int64` 而不是 `Double`：结果约 1.34e17，
    /// 而 `Double` 只能精确表示到 9e15 附近的整数 —— 中途转成浮点会**悄悄丢精度**，
    /// 算出来的令牌就是错的，表现为莫名其妙的 403，且极难排查。
    static func secMsGec(now: Date = Date()) -> String {
        let seconds = Int64(now.timeIntervalSince1970) + windowsEpoch
        let rounded = seconds - (seconds % 300)      // 5 分钟一档，与服务端对齐
        let ticks = rounded * 10_000_000             // 秒 → 100ns 刻度
        let payload = String(ticks) + trustedClientToken
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - 音色表

    struct Voice: Identifiable, Hashable {
        let id: String        // 传给服务端的 voice name
        let label: String     // 界面上显示的名字
        let group: String
    }

    /// 精选音色。
    ///
    /// 刻意**不**去调 `/voices/list` 拉全量：那个端点需要额外的 token 参数、
    /// 而且返回上百个音色（大部分是小语种），对选音色没有帮助。
    /// 这里只列中文与英文里实际好用的那些。
    static let voices: [Voice] = [
        Voice(id: "zh-CN-XiaoxiaoNeural", label: "晓晓 · 中文女声（最自然）", group: "中文"),
        Voice(id: "zh-CN-XiaoyiNeural",   label: "晓伊 · 中文女声（年轻）", group: "中文"),
        Voice(id: "zh-CN-YunxiNeural",    label: "云希 · 中文男声（活泼）", group: "中文"),
        Voice(id: "zh-CN-YunjianNeural",  label: "云健 · 中文男声（沉稳）", group: "中文"),
        Voice(id: "zh-CN-YunyangNeural",  label: "云扬 · 中文男声（播报）", group: "中文"),
        Voice(id: "zh-CN-YunxiaNeural",   label: "云夏 · 中文男声（少年）", group: "中文"),
        Voice(id: "zh-CN-liaoning-XiaobeiNeural", label: "晓北 · 东北话", group: "方言"),
        Voice(id: "zh-CN-shaanxi-XiaoniNeural",   label: "晓妮 · 陕西话", group: "方言"),
        Voice(id: "zh-HK-HiuMaanNeural",  label: "曉曼 · 粤语女声", group: "粤语 / 台湾"),
        Voice(id: "zh-HK-WanLungNeural",  label: "雲龍 · 粤语男声", group: "粤语 / 台湾"),
        Voice(id: "zh-TW-HsiaoChenNeural", label: "曉臻 · 台湾女声", group: "粤语 / 台湾"),
        Voice(id: "zh-TW-YunJheNeural",   label: "雲哲 · 台湾男声", group: "粤语 / 台湾"),
        Voice(id: "en-US-AvaMultilingualNeural",   label: "Ava · 美音女声（多语言）", group: "英文"),
        Voice(id: "en-US-EmmaMultilingualNeural",  label: "Emma · 美音女声（多语言）", group: "英文"),
        Voice(id: "en-US-JennyNeural",    label: "Jenny · 美音女声", group: "英文"),
        Voice(id: "en-US-GuyNeural",      label: "Guy · 美音男声", group: "英文"),
        Voice(id: "en-GB-SoniaNeural",    label: "Sonia · 英音女声", group: "英文"),
        Voice(id: "en-GB-RyanNeural",     label: "Ryan · 英音男声", group: "英文"),
        Voice(id: "ja-JP-NanamiNeural",   label: "ナナミ · 日文女声", group: "其他"),
        Voice(id: "ja-JP-KeitaNeural",    label: "ケイタ · 日文男声", group: "其他"),
    ]

    static let defaultVoice = "zh-CN-XiaoxiaoNeural"

    static func voiceLabel(for id: String) -> String {
        voices.first { $0.id == id }?.label ?? id
    }

    struct VoiceGroup: Identifiable {
        let name: String
        let items: [Voice]
        var id: String { name }
    }

    static var groupedVoices: [VoiceGroup] {
        var order: [String] = []
        var buckets: [String: [Voice]] = [:]
        for voice in voices {
            if buckets[voice.group] == nil { order.append(voice.group) }
            buckets[voice.group, default: []].append(voice)
        }
        return order.map { VoiceGroup(name: $0, items: buckets[$0] ?? []) }
    }

    // MARK: - 错误

    enum EdgeTTSError: Error, LocalizedError {
        case noAudio
        case handshakeFailed(String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .noAudio:
                return "Edge 语音服务没有返回音频（可能是文本为空，或这段文本被服务端判为无需合成）。"
            case .handshakeFailed(let why):
                return "连接 Edge 语音服务失败：\(why)"
            case .badResponse(let why):
                return "Edge 语音服务返回了异常内容：\(why)"
            }
        }
    }

    // MARK: - 合成

    /// 把一段文本合成为 mp3 数据。
    ///
    /// - Parameters:
    ///   - rate: 百分比字符串，如 `"+0%"` / `"-20%"`（见 `rateString(for:)`）
    static func synthesize(
        text: String,
        voice: String = defaultVoice,
        rate: String = "+0%",
        pitch: String = "+0Hz",
        volume: String = "+0%",
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EdgeTTSError.noAudio }

        // ── 握手 URL ──
        // Sec-MS-GEC 每 5 分钟才变一次，但每次请求都重新算没有代价，也不会有缓存问题。
        var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")
        components?.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: secMsGec()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(chromiumVersion)"),
        ]
        guard let url = components?.url else {
            throw EdgeTTSError.handshakeFailed("URL 拼接失败")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let majorVersion = chromiumVersion.split(separator: ".").first.map(String.init) ?? "143"
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/\(majorVersion).0.0.0 Safari/537.36 "
            + "Edg/\(majorVersion).0.0.0",
            forHTTPHeaderField: "User-Agent")
        // Origin 必须伪装成 Edge 的朗读扩展，否则同样会被拒
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
                         forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let timestamp = javascriptDate()

        // ── 1) speech.config：告诉服务端要什么格式 ──
        // 不订阅句/词边界事件（"false"）：我们用不上，而开着会多收一堆元数据帧。
        let configMessage =
            "X-Timestamp:\(timestamp)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"\#(outputFormat)"}}}}"#
            + "\r\n"
        try await socket.send(.string(configMessage))

        // ── 2) SSML ──
        let ssml =
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(voice)'>"
            + "<prosody pitch='\(pitch)' rate='\(rate)' volume='\(volume)'>"
            + escapeXML(trimmed)
            + "</prosody></voice></speak>"

        // X-RequestId 用无横线 UUID（与服务端其它客户端一致）
        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // ⚠️ 时间戳后面这个 "Z" 不是笔误，是 Edge 自己的格式，上游照抄即可
        let ssmlMessage =
            "X-RequestId:\(requestId)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestamp)Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
        try await socket.send(.string(ssmlMessage))

        // ── 3) 收音频 ──
        var audio = Data()
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                // 已经收到音频但连接被服务端关掉：把收到的交出去，不算失败
                if !audio.isEmpty { return audio }
                throw EdgeTTSError.handshakeFailed(error.localizedDescription)
            }

            switch message {
            case .data(let frame):
                // 音频帧 = ASCII 头 + \r\n\r\n + 二进制音频
                guard let (headers, payload) = splitFrame(frame) else { continue }
                guard headers["Path"] == "audio" else { continue }
                // 结束时服务端会发一个「无 Content-Type、无数据」的帧，是正常现象
                if headers["Content-Type"] == nil && payload.isEmpty { continue }
                audio.append(payload)

            case .string(let textMessage):
                // 服务端在收尾时发 `Path:turn.end`
                if textMessage.contains("Path:turn.end") {
                    guard !audio.isEmpty else { throw EdgeTTSError.noAudio }
                    return audio
                }
                // 服务端偶发会回错误说明，如实带出去而不是当成空音频
                if textMessage.contains("\"error\"") || textMessage.lowercased().contains("error code") {
                    throw EdgeTTSError.badResponse(String(textMessage.prefix(200)))
                }

            @unknown default:
                continue
            }
        }
    }

    /// 把 App 的语速（1.0 = 正常）换算成 Edge 的百分比字符串。
    static func rateString(for speed: Double) -> String {
        let value = speed > 0 ? speed : 1.0
        // 服务端接受范围大约是 -50% ~ +100%，越界会被拒
        let percent = Int(((value - 1.0) * 100).rounded())
        let clamped = max(-50, min(100, percent))
        return clamped >= 0 ? "+\(clamped)%" : "\(clamped)%"
    }

    // MARK: - 内部工具

    /// 按 Edge 的格式输出 UTC 时间戳。
    /// 形如 `Sat Oct 03 2026 03:20:00 GMT+0000 (Coordinated Universal Time)`。
    private static func javascriptDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: date)
    }

    /// 拆出二进制帧的头部与音频数据。
    private static func splitFrame(_ data: Data) -> ([String: String], Data)? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])   // \r\n\r\n
        guard let range = data.range(of: separator) else { return nil }
        let headerSlice = data[data.startIndex..<range.lowerBound]
        let payload = Data(data[range.upperBound...])
        guard let headerText = String(data: headerSlice, encoding: .utf8) else { return nil }

        var headers: [String: String] = [:]
        for line in headerText.split(separator: "\r\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return (headers, payload)
    }

    /// SSML 是 XML，`&` `<` `>` 必须转义 —— 否则文本里出现一个 `<` 就会
    /// 让整个请求被服务端判为非法 XML，而错误信息只会说"合成失败"。
    private static func escapeXML(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        // XML 1.0 不允许这些控制字符，留着会让整个请求被拒
        out = out.unicodeScalars.filter { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || scalar.value >= 0x20
        }.map(String.init).joined()
        return out
    }

    /// 连通性自检：拿一小段文本试合成，成功就返回音频字节数。
    static func selfTest(voice: String = defaultVoice) async throws -> Int {
        let data = try await synthesize(text: "你好，这是一次语音服务连通性测试。", voice: voice)
        return data.count
    }
}
