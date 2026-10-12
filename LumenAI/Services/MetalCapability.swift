import Foundation
import Metal

/// Metal（本地模型 GPU 加速）能力探测。
///
/// 为什么单独做一个可断言的探测，而不是只看设置开关：
/// 「设置里开启了 Metal 自动加速」只表达**意图**，真正决定能否加速的是两件事 ——
/// ① 设备上有可用的 `MTLDevice`；② 链接进来的 llama.cpp 编译时带了 ggml-metal 后端。
/// ② 已在构建产物上核对过（`libllama-ios.a` 里有 `ggml_backend_metal_init`、`ggml_metal_init`，
/// 以及内嵌的 metal kernel 目标文件），① 只能在运行时真值探测。
/// 把两者合在一起显示，用户才不会以为"开了开关就等于在跑 GPU"。
enum MetalCapability {

    /// 设备是否有可用的 Metal 设备（模拟器 / 极旧设备上可能为 nil）。
    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// Metal 设备名（如 "Apple A17 Pro GPU"）；不可用时为 nil。
    static var deviceName: String? { MTLCreateSystemDefaultDevice()?.name }

    /// **运行期证据**：最近一次成功加载模型时，llama.cpp **自己**报的后端结论。
    /// 例："load_tensors: offloaded 32/33 layers to GPU" / "… offloaded 0/33 layers to GPU"。
    /// nil = 本次 App 运行里还没成功加载过模型。
    static var lastLoadBackendNote: String? { LlamaSwiftEngine.lastBackendNote }

    /// 给设置页显示的一行。没有运行期证据时**如实说没有**，不拿配置开关冒充结论 ——
    /// 这正是这个字段存在的意义：`useMetalAuto` / `gpuLayers` 只表达"我们要求了多少层"，
    /// 真正跑没跑 GPU 只有后端自己知道（Metal 初始化失败会静默回落 CPU）。
    static var runtimeEvidence: String {
        guard isAvailable else { return "无 MTLDevice —— 不可能走 GPU（纯 CPU）" }
        guard let note = lastLoadBackendNote else {
            return "本次运行还没成功加载过模型（无运行期证据）"
        }
        return note
    }

    /// 一句话状态：给设置页 / 终端页显示。
    ///
    /// 注意这里读的是**当前设置下会实际生效**的 offload 层数（自动模式按设备内存与
    /// 上下文长度换算），不是"是否支持 Metal"这种笼统结论 —— 后者对排查没有帮助。
    ///
    /// `@MainActor`：`LLMService.deviceRAMGB` 与 `recommendedGpuLayers` 都在 MainActor 上
    /// （`LLMService` 是 UI 侧单例），从 nonisolated 上下文同步取用会被 Swift 6 拒绝。
    /// 调用方（设置页、终端页）本来就在主线程，加这个标注不改变任何调用方式。
    @MainActor
    static var statusLine: String {
        let settings = SettingsStorage.shared.settings
        let ram = LLMService.deviceRAMGB
        guard let name = deviceName else {
            return "Metal 不可用（无 MTLDevice）· 走 CPU"
        }
        if settings.useMetalAuto {
            let layers = LLMService.recommendedGpuLayers(contextLength: settings.contextLength)
            return layers > 0
                ? "Metal 可用（\(name)）· 自动 offload \(layers) 层 · 内存 \(ram)GB"
                : "Metal 可用（\(name)）· 内存 \(ram)GB，自动判定走纯 CPU"
        }
        return settings.gpuLayers > 0
            ? "Metal 可用（\(name)）· 手动 offload \(settings.gpuLayers) 层"
            : "Metal 可用（\(name)）· 已手动关闭（纯 CPU）"
    }
}
