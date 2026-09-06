import SwiftUI

/// 新建 / 编辑 Provider（Provider 配置：类型 / 地址 / 多 Key / 自定义请求头与体）
struct ProviderEditSheet: View {
    let existing: ChatProvider?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProviderStore.shared

    @State private var name: String
    @State private var type: ProviderType
    @State private var baseURL: String
    @State private var keysText: String
    @State private var headersText: String
    @State private var extraBodyText: String
    @State private var modelsText: String
    @State private var imageModel: String
    @State private var enabled: Bool
    @State private var errorMessage: String?

    init(existing: ChatProvider? = nil) {
        self.existing = existing
        let initialType = existing?.type ?? .openAICompatible
        _name = State(initialValue: existing?.name ?? "")
        _type = State(initialValue: initialType)
        _baseURL = State(initialValue: existing?.baseURL ?? initialType.defaultBaseURL)
        _keysText = State(initialValue: existing?.apiKeys.joined(separator: ",") ?? "")
        _headersText = State(initialValue: Self.prettyJSON(existing?.headers))
        _extraBodyText = State(initialValue: existing?.extraBody ?? "")
        // 新建 Provider 时预填类型对应的默认模型 ID,让用户选好类型就有可用模型列表可改
        _modelsText = State(initialValue: existing?.models.joined(separator: ", ") ?? initialType.defaultModels.joined(separator: ", "))
        _imageModel = State(initialValue: existing?.imageModel ?? "")
        _enabled = State(initialValue: existing?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField(t("提供商名称"), text: $name)

                    Picker(t("类型"), selection: $type) {
                        ForEach(ProviderType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .onChange(of: type) { _, newType in
                        // 切换类型时若 Base URL / models 都为空,自动填入默认值
                        if baseURL.isEmpty {
                            baseURL = newType.defaultBaseURL
                        }
                        if modelsText.isEmpty {
                            modelsText = newType.defaultModels.joined(separator: ", ")
                        }
                    }

                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle(t("启用"), isOn: $enabled)
                }

                Section {
                    TextField("API Key", text: $keysText, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(t("多个 Key 用逗号分隔，自动轮换"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(t("API Key"))
                }

                Section {
                    TextField(t("模型名（逗号分隔）"), text: $modelsText, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(t("模型列表"))
                }

                Section {
                    TextField("gpt-image-1 / FLUX.1-schnell…", text: $imageModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(t("仅 OpenAI/兼容 端点支持文生图。填写后聊天输入框可用 /draw <描述> 生成图片。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(t("生图模型（可选）"))
                }

                Section {
                    TextField(#"{ "X-API-Key": "xxx" }"#, text: $headersText, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(t("自定义请求头 (JSON)"))
                }

                Section {
                    TextField(#"{ "top_p": 0.9 }"#, text: $extraBodyText, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(t("自定义请求体 (JSON)"))
                }
            }
            .navigationTitle(existing == nil ? t("添加 Provider") : t("编辑"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("保存")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .alert("无法保存", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let keys = keysText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let models = modelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard validateJSON(headersText), validateJSON(extraBodyText) else {
            errorMessage = "JSON 格式不正确"
            return
        }

        let provider = ChatProvider(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            type: type,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            apiKeys: keys,
            headers: parseJSONDict(headersText),
            extraBody: extraBodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            models: models,
            isBuiltIn: existing?.isBuiltIn ?? false,
            enabled: enabled,
            createdAt: existing?.createdAt ?? Date(),
            lastUsedAt: existing?.lastUsedAt,
            imageModel: imageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        store.upsert(provider)
        dismiss()
    }

    private static func prettyJSON(_ dict: [String: String]?) -> String {
        guard let dict, !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    private func validateJSON(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func parseJSONDict(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (k, v) in obj {
            result[k] = "\(v)"
        }
        return result
    }
}
