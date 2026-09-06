import Foundation

// MARK: - 云端文生图（text → image，OpenAI 兼容 /images/generations）

/// 用当前选中的云端 Provider（OpenAI / OpenAI 兼容端点）生成图片。
/// 仅支持 type == .openAI / .openAICompatible（Claude/Gemini 无 OpenAI images 接口）。
/// Provider 需在设置中填写「生图模型」(imageModel)，否则返回 .noImageModel。
enum CloudImageClient {

    enum ImageGenError: LocalizedError, Sendable {
        case notSupportedProvider
        case noImageModel
        case invalidURL
        case httpError(Int, String)
        case networkError(String)
        case emptyResult
        case badImageData

        var errorDescription: String? {
            switch self {
            case .notSupportedProvider:
                return "当前 Provider 不支持文生图（仅 OpenAI / OpenAI 兼容端点支持）。请切换到支持生图的 Provider。"
            case .noImageModel:
                return "该 Provider 尚未配置「生图模型」。请在服务页编辑此 Provider，在「生图模型」填写模型名（如 gpt-image-1 或 black-forest-labs/FLUX.1-schnell）。"
            case .invalidURL:
                return "无效的 API 地址"
            case .httpError(let code, let body):
                let snippet = String(body.prefix(400))
                return "生成失败 HTTP \(code): \(snippet.isEmpty ? "未知错误" : snippet)"
            case .networkError(let msg):
                return "网络错误: \(msg)"
            case .emptyResult:
                return "模型未返回任何图片"
            case .badImageData:
                return "返回的图片数据无法解析"
            }
        }
    }

    /// 生成一张图片，返回解码后的 PNG/JPEG Data。
    @MainActor
    static func generate(provider: ChatProvider, prompt: String) async throws -> Data {
        guard provider.type == .openAI || provider.type == .openAICompatible else {
            throw ImageGenError.notSupportedProvider
        }
        let model = provider.imageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ImageGenError.noImageModel }
        let key = provider.primaryKey
        guard !key.isEmpty else { throw CloudError.noAPIKey }
        guard let url = URL(string: provider.cleanBaseURL + "/images/generations") else {
            throw ImageGenError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for (k, v) in provider.headers { request.setValue(v, forHTTPHeaderField: k) }

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": 1,
            "response_format": "b64_json",  // OpenAI 及多数兼容端点（SiliconFlow 等）支持 base64
        ]
        // 允许自定义请求体补充/覆盖（如 image_size / size 差异）
        if let extra = parseJSON(provider.extraBody) {
            for (k, v) in extra {
                if !["model", "prompt", "n", "response_format"].contains(k) {
                    body[k] = v
                }
            }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if CloudChatClient.isCancellation(error) { throw CancellationError() }
            throw ImageGenError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ImageGenError.networkError("无效响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let errText = String(data: data, encoding: .utf8) ?? ""
            throw ImageGenError.httpError(http.statusCode, errText)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first else {
            throw ImageGenError.emptyResult
        }
        if let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String {
            throw ImageGenError.httpError(0, msg)
        }

        // 优先 base64，其次 url（部分端点返回 url）
        if let b64 = first["b64_json"] as? String,
           let imgData = Data(base64Encoded: b64) {
            return imgData
        }
        if let urlStr = first["url"] as? String, let imgURL = URL(string: urlStr) {
            let (imgData, _) = try await URLSession.shared.data(from: imgURL)
            return imgData
        }
        throw ImageGenError.badImageData
    }

    /// Provider 是否可用文生图（类型 + 已配生图模型 + 有 Key）
    @MainActor
    static func canGenerate(on provider: ChatProvider?) -> Bool {
        guard let provider,
              provider.hasKey,
              provider.type == .openAI || provider.type == .openAICompatible else { return false }
        return !provider.imageModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func parseJSON(_ text: String?) -> [String: Any]? {
        guard let text, !text.isEmpty,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
