import Foundation
import Speech
import AVFoundation
import Combine

/// 语音输入（ASR 能力，iOS 侧用 SFSpeechRecognizer）
/// 使用系统在线/离线识别，中英文自动跟随界面语言
///
/// Swift 6 strict concurrency 修复历史：
/// - v0.3.6：在 init() 直接调 requestAuthorization → TCC 后台 queue 触碰 @MainActor 状态 → trap。
/// - v0.3.7：在闭包内 `guard let self` + DispatchQueue.main.async → 仍 trap（closure escape 路径仍 leak）。
/// - v0.3.9：改 @unchecked Sendable → 关闭 actor 检查，仍可能被 SwiftUI 严格访问触发其他问题。
/// - v0.3.10（本版）：保留 `@MainActor`，把请求授权封到 `static` 函数 → 闭包**不接收 self**，
///                  `Task { @MainActor in ASRService.shared.isAuthorized = ... }` 安全切到主线程。
@MainActor
final class ASRService: ObservableObject {

    static let shared = ASRService()

    /// UI 订阅的 published 状态
    @Published private(set) var isAuthorized = false
    @Published var isListening = false
    @Published var partialText = ""

    /// 识别出最终文本（回调设置在主线程）
    var onFinal: ((String) -> Void)?
    /// 识别到中间结果（用于实时上屏）
    var onPartial: ((String) -> Void)?
    /// 错误反馈（权限被拒 / 引擎起不来…）。v0.3.73 前这些错误全被静默吞掉，
    /// 用户点麦克风没反应、也不知道为什么 —— 表现为"语音用不了"。
    var onError: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 音频实时线程与主线程共享的请求引用（见 SpeechRequestBox 注释）
    private var requestBox: SpeechRequestBox?

    /// 音频 tap 线程（非主线程）需要 append buffer 到 Speech 请求。
    /// SFSpeechAudioBufferRecognitionRequest 本身无 actor 隔离（SDK 无 @MainActor），
    /// 但它的 append 设计上就是给音频实时线程调用（Apple 官方样例同款）。
    /// 用 @unchecked Sendable 盒子跨线程持有引用；闭包只捕获这个盒子，不触碰 @MainActor 状态。
    private final class SpeechRequestBox: @unchecked Sendable {
        var request: SFSpeechAudioBufferRecognitionRequest?
    }

    private init() {
        updateLocale()
    }

    func updateLocale() {
        let lang = SettingsStorage.shared.settings.language == "en" ? "en-US" : "zh-CN"
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang))
    }

    var permissionDenied: Bool { !isAuthorized }

    /// 开始/停止听写
    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        task?.cancel()
        task = nil
        guard isAuthorized else {
            // 主线程发起的请求；回调路径完全 self-contained，不捕获 self
            ASRService.requestPermissionAndStart()
            return
        }
        // ⚠️ Speech 授权 ≠ 麦克风授权。v0.3.72 及以前从不请求 mic 权限：
        // 被拒后 AVAudioEngine.start() 抛错、被下面的 catch 静默吞掉，
        // 用户点麦克风永远"没反应"。先显式请求 mic，再起引擎。
        Task { @MainActor in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                self.onError?("麦克风权限被拒绝。请到「设置 → 隐私与安全性 → 麦克风」为 LumenAI 开启后重试。")
                return
            }
            self.startEngine()
        }
    }

    /// 已拿到 Speech + 麦克风双权限后的引擎启动流程
    private func startEngine() {
        let lang = SettingsStorage.shared.settings.language == "en" ? "en-US" : "zh-CN"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)),
              recognizer.isAvailable
        else {
            onError?("当前语言的语音识别不可用（请检查系统语言与网络）。")
            return
        }
        self.recognizer = recognizer

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.audioEngine = engine
        self.request = request

        let requestBox = SpeechRequestBox()
        requestBox.request = request
        self.requestBox = requestBox

        // 结果回调：显式 @Sendable，避免继承 @MainActor 隔离（v0.3.32 崩溃修复：
        // 非 @Sendable 闭包在 @MainActor 上下文创建会继承隔离，Speech 在后台队列回调时
        // _swift_task_checkIsolatedSwift 断言 → SIGTRAP）。状态写回统一 Task { @MainActor }。
        let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, error in
            // 先在外层把非 Sendable 的 result 降级为 Sendable 数据（String/Bool），
            // 再把它们送进 Task —— 直接把 result 对象送进 @Sendable Task 会报 data race。
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.partialText = text
                    self.onPartial?(text)
                    if isFinal {
                        if !text.isEmpty { self.onFinal?(text) }
                        self.stop()
                    }
                }
                if hasError {
                    // 识别任务出错（超时/被打断…）：已有上屏内容就安静收尾；
                    // 一个字都没识别出来则明确提示，否则用户又会觉得"点了没反应"。
                    let nothingHeard = self.partialText.isEmpty
                    self.stop()
                    if nothingHeard {
                        self.onError?("没有听到语音，请靠近麦克风重试。")
                    }
                }
            }
        }
        task = recognizer.recognitionTask(with: request, resultHandler: resultHandler)

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.removeTap(onBus: 0)
        // 音频 tap：@Sendable 闭包在音频实时线程执行（RealtimeMessenger 队列），
        // 只捕获线程安全的 box，不触碰任何 @MainActor 状态。
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            requestBox.request?.append(buffer)
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock)

        engine.prepare()
        do {
            try engine.start()
            isListening = true
            partialText = ""
        } catch {
            // v0.3.72 前：静默 stop()，用户点麦克风永远没反应
            stop()
            onError?("无法启动麦克风录音：\(error.localizedDescription)")
        }
    }

    func stop() {
        request?.endAudio()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request = nil
        requestBox?.request = nil
        requestBox = nil
        isListening = false
        partialText = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 静态、非隔离 —— 闭包路径**完全不捕获 self**，杜绝 actor isolation trap。
    /// 回调里 `Task { @MainActor in ... }` 切回主线程，单次主线程访问 `shared` 写 isAuthorized。
    nonisolated private static func requestPermissionAndStart() {
        SFSpeechRecognizer.requestAuthorization { rawStatus in
            // TCC 后台 queue：不碰 self，仅 Sendable 局部值
            let captured: SFSpeechRecognizerAuthorizationStatus = rawStatus
            Task { @MainActor in
                // 此处安全：通过单例访问 @MainActor 隔离状态
                let ok = (captured == .authorized)
                let svc = ASRService.shared
                svc.isAuthorized = ok
                if ok {
                    // start() 内部会 guard isListening / isAuthorized
                    svc.start()
                } else if captured != .notDetermined {
                    // 被拒过：系统不会再弹窗，必须明确告诉用户去哪开
                    svc.onError?("语音识别权限被拒绝。请到「设置 → 隐私与安全性 → 语音识别」为 LumenAI 开启。")
                }
            }
        }
    }
}
