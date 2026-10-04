import Foundation

/// API 服务：处理外部 API 调用（OpenAI 兼容格式）
/// 支持流式和非流式响应
@MainActor
final class APIService: ObservableObject {
    
    static let shared = APIService()
    
    /// API 调用状态
    enum State: Sendable {
        case idle
        case loading
        case streaming
        case error(String)
    }
    
    @Published var state: State = .idle
    
    private init() {}
    
    // MARK: - 流式 API 调用
    
    /// 流式调用 API（OpenAI 兼容格式）
    nonisolated func streamChat(
        messages: [[String: String]],
        settings: ModelSettings
    ) -> AsyncThrowingStream<String, Error> {
        let capturedSettings = settings
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                let service = await APIService.shared
                await service.performStreamChat(
                    messages: messages,
                    settings: capturedSettings,
                    continuation: continuation
                )
            }
        }
    }
    
    private func performStreamChat(
        messages: [[String: String]],
        settings: ModelSettings,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        await MainActor.run { self.state = .streaming }
        defer { 
            Task { @MainActor in
                self.state = .idle
            }
        }
        
        guard let url = URL(string: settings.apiEndpoint) else {
            continuation.finish(throwing: APIError.invalidURL)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        
        // 设置请求头
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // 构建请求体
        let body: [String: Any] = [
            "model": settings.apiModel,
            "messages": messages,
            "temperature": settings.apiTemperature,
            "max_tokens": settings.apiMaxTokens,
            "stream": true
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            continuation.finish(throwing: APIError.encodingFailed)
            return
        }
        
        // 发送请求
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                continuation.finish(throwing: APIError.invalidResponse)
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                }
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                continuation.finish(throwing: APIError.httpError(httpResponse.statusCode, errorMsg))
                return
            }
            
            // 处理流式响应：用 bytes.lines 按行读取（内部缓冲、C 速度切行、整行 UTF-8
            // 解码，避免逐字节处理破坏非 ASCII）。旧实现逐字节 append 且每个字节都从头
            // firstIndex(of: 0x0A) 找换行，单行成本 O(行长²) —— 每个 token 都走这里。
            // 行终止符（\n / \r\n）由 AsyncLineSequence 剥掉；流末尾未换行的最后一行
            // 也会照常产出，覆盖旧"末尾残留数据"分支。
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" {
                        continuation.finish()
                        return
                    }

                    if let jsonData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let delta = firstChoice["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        continuation.yield(content)
                    }
                }
            }

            continuation.finish()
            
        } catch {
            continuation.finish(throwing: APIError.networkError(error))
        }
    }
    
    // MARK: - 非流式 API 调用
    
    /// 非流式调用 API
    nonisolated func complete(
        messages: [[String: String]],
        settings: ModelSettings
    ) async throws -> String {
        let capturedSettings = settings
        let service = await APIService.shared
        return try await service.performComplete(
            messages: messages,
            settings: capturedSettings
        )
    }
    
    private func performComplete(
        messages: [[String: String]],
        settings: ModelSettings
    ) async throws -> String {
        guard let url = URL(string: settings.apiEndpoint) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = [
            "model": settings.apiModel,
            "messages": messages,
            "temperature": settings.apiTemperature,
            "max_tokens": settings.apiMaxTokens,
            "stream": false
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, errorMsg)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIError.parsingFailed
        }
        
        return content
    }
}

// MARK: - API 错误类型

enum APIError: LocalizedError {
    case invalidURL
    case encodingFailed
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)
    case parsingFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .encodingFailed:
            return "请求编码失败"
        case .invalidResponse:
            return "无效的响应"
        case .httpError(let code, let msg):
            return "HTTP 错误 \(code): \(msg)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .parsingFailed:
            return "响应解析失败"
        }
    }
}
