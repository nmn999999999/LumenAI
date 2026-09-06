import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// 本地 llama.cpp + mtmd 推理引擎（替代 LLM.swift）。
// 通过 LlamaBridge.h 的 C API 调用，支持纯文本与多模态（图片）。

final class LlamaSwiftEngine: LLMEngine, @unchecked Sendable {
    let modelURL: URL
    /// 是否加载了多模态投影器(mmproj) → 支持图片理解。
    let supportsVision: Bool
    private var bridge: OpaquePointer?          // llama_bridge *
    private var lastError: String?

    // iOS 上 Metal 后端存在兼容性问题（解码失败/输出退化），默认纯 CPU 推理最稳定。
    // 需要加速可在「设置」里调高 GPU 层数。
    private let nGpuLayers: Int32
    // 推理线程数：按设备核心数自适应（4..8）。比写死 4 在多数 iPhone 上明显提速，
    // 同时封顶 8 避免小核过多引发的调度开销/发热。
    private let nThreads: Int32 = {
        let cores = ProcessInfo.processInfo.processorCount
        return Int32(min(max(cores, 4), 8))
    }()

    init(modelURL: URL, gpuLayers: Int32 = 0) async throws {
        self.modelURL = modelURL
        self.nGpuLayers = gpuLayers

        // iPhone 统一内存有限：开启 GPU 层时把上下文上限卡到 2048，避免 Metal OOM。
        var requestedCtx = SettingsStorage.shared.settings.contextLength
        if nGpuLayers > 0 && requestedCtx > 2048 {
            print("[LlamaSwiftEngine] GPU layers enabled (\(nGpuLayers)); clamp contextLength \(requestedCtx) -> 2048 to avoid Metal OOM")
            requestedCtx = 2048
        }

        var bridge: OpaquePointer?
        let createResult = llama_bridge_create(&bridge)
        guard createResult == 0, let handle = bridge else {
            throw LLMError.loadFailed("无法创建推理上下文: \(createResult == -1 ? "内存不足" : "未知错误")")
        }

        let mmproj = LlamaSwiftEngine.detectMMProj(nextTo: modelURL)
        self.supportsVision = (mmproj != nil)
        let ok = llama_bridge_load_model(
            handle,
            modelURL.path,
            mmproj ?? "",
            Int32(requestedCtx),
            nGpuLayers,
            nThreads,
            SettingsStorage.shared.settings.useMmap ? 1 : 0,     // 1 = LLAMA_LOAD_MODE_MMAP, 0 = LLAMA_LOAD_MODE_NONE
            SettingsStorage.shared.settings.kvCacheQuantize ? 1 : 0  // 1 = Q8_0 KV cache, 0 = F16
        )
        if !ok {
            let err = String(cString: llama_bridge_last_error(handle))
            throw LLMError.loadFailed("模型加载失败: \(err)")
        }
        self.bridge = handle
    }

    deinit {
        close()
    }
    
    /// 安全释放资源
    private func close() {
        guard let b = bridge else { return }
        bridge = nil
        llama_bridge_stop(b)  // 先停止可能正在进行的生成
        // 在后台线程释放，避免阻塞主线程
        Task.detached {
            llama_bridge_free(b)
        }
    }

    // 自动探测同目录下的 mmproj 文件
    private static func detectMMProj(nextTo modelURL: URL) -> String? {
        let dir = modelURL.deletingLastPathComponent()
        let name = modelURL.deletingPathExtension().lastPathComponent.lowercased()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        // 优先：同名 mmproj，其次任意 *mmproj*.gguf
        for f in files where f.lastPathComponent.lowercased().contains("mmproj") &&
            f.pathExtension.lowercased() == "gguf" {
            if f.deletingPathExtension().lastPathComponent.lowercased().contains(name) {
                return f.path
            }
        }
        for f in files where f.lastPathComponent.lowercased().contains("mmproj") &&
            f.pathExtension.lowercased() == "gguf" {
            return f.path
        }
        return nil
    }

    func stream(
        messages: [EngineMessage],
        settings: ModelSettings,
        images: [CGImage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let b = bridge else {
                continuation.finish(throwing: LLMError.modelNotLoaded)
                return
            }

            // 消息 JSON
            var msgArr: [[String: String]] = []
            for m in messages {
                msgArr.append(["role": m.role.rawValue, "content": m.content])
            }
            guard let msgData = try? JSONSerialization.data(withJSONObject: msgArr),
                  let msgJSON = String(data: msgData, encoding: .utf8) else {
                continuation.finish(throwing: LLMError.generationFailed("消息序列化失败"))
                return
            }

            let settingsDict: [String: Any] = [
                "temp": settings.temperature,
                "top_k": settings.topK,
                "top_p": settings.topP,
                "max_tokens": settings.maxTokens,
            ]
            guard let setData = try? JSONSerialization.data(withJSONObject: settingsDict),
                  let setJSON = String(data: setData, encoding: .utf8) else {
                continuation.finish(throwing: LLMError.generationFailed("设置序列化失败"))
                return
            }

            // 图片写入临时 PNG，传路径给 C 桥
            var imgPaths: [String] = []
            for img in images {
                if let url = LlamaSwiftEngine.writeTempPNG(img) {
                    imgPaths.append(url.path)
                }
            }
            let imgArr = imgPaths
            guard let imgData = try? JSONSerialization.data(withJSONObject: imgArr),
                  let imgJSON = String(data: imgData, encoding: .utf8) else {
                continuation.finish(throwing: LLMError.generationFailed("图片序列化失败"))
                return
            }

            let forwarder = TokenForwarder(continuation: continuation)
            let ud = Unmanaged.passRetained(forwarder).toOpaque()

            // 消费者取消（停止生成 / 离开页面）时，通知 C 桥在下一个 token 边界停止
            // OpaquePointer 非 Sendable，转成位模式在 @Sendable 闭包里传递
            let bridgeBits = UInt(bitPattern: b)
            continuation.onTermination = { _ in
                llama_bridge_stop(OpaquePointer(bitPattern: bridgeBits))
            }

            Task.detached(priority: .userInitiated) {
                let rc = llama_bridge_chat(
                    b,
                    msgJSON,
                    setJSON,
                    imgJSON,
                    llamaBridgeTokenCallback,
                    ud
                )
                let fwd = Unmanaged<TokenForwarder>.fromOpaque(ud).takeUnretainedValue()
                fwd.flush()
                Unmanaged<TokenForwarder>.fromOpaque(ud).release()
                if rc != 0 {
                    let err = String(cString: llama_bridge_last_error(b))
                    continuation.finish(throwing: LLMError.generationFailed(err))
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private static func writeTempPNG(_ img: CGImage) -> URL? {
        #if canImport(UIKit)
        let ui = UIImage(cgImage: img)
        guard let data = ui.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try? data.write(to: url)
        return url
        #else
        return nil
        #endif
    }
}

private final class TokenForwarder {
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var buffer = ""
    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }
    func yield(_ piece: UnsafePointer<CChar>) {
        let s = String(cString: piece, encoding: .utf8) ?? String(cString: piece, encoding: .ascii) ?? ""
        buffer += s
        if buffer.count >= 4 || s.last == "\n" || s.last == "。" || s.last == "." {
            continuation.yield(buffer)
            buffer = ""
        }
    }
    func flush() {
        if !buffer.isEmpty {
            continuation.yield(buffer)
            buffer = ""
        }
    }
}

private let llamaBridgeTokenCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { piece, userdata in
    guard let userdata, let piece else { return }
    let fwd = Unmanaged<TokenForwarder>.fromOpaque(userdata).takeUnretainedValue()
    fwd.yield(piece)
}
