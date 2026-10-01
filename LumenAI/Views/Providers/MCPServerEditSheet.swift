import SwiftUI

/// MCP 服务器 新建/编辑
struct MCPServerEditSheet: View {
    let existing: MCPServer?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MCPService.shared

    @State private var name: String
    @State private var url: String
    @State private var headersText: String
    @State private var enabled: Bool

    init(existing: MCPServer? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _url = State(initialValue: existing?.url ?? "")
        _headersText = State(initialValue: existing.map {
            (try? JSONSerialization.data(withJSONObject: $0.headers, options: [.prettyPrinted]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        } ?? "")
        _enabled = State(initialValue: existing?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器名称", text: $name)
                    TextField("https://example.com/mcp", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle(t("启用"), isOn: $enabled)
                } header: {
                    Text("MCP Server")
                } footer: {
                    Text("地址为 MCP streamable HTTP 端点（JSON-RPC over HTTP）。连接后自动发现可用工具，并加入 Agent 工具目录。")
                        .font(.caption2)
                }

                Section {
                    TextField(#"{ "Authorization": "Bearer xxx" }"#, text: $headersText, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("自定义请求头 (JSON)")
                }
            }
            .navigationTitle(existing == nil ? "添加 MCP 服务器" : "编辑 MCP 服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("保存")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let headers: [String: String]
        if let data = headersText.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            headers = obj.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
        } else {
            headers = [:]
        }
        let server = MCPServer(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            url: url.trimmingCharacters(in: .whitespaces),
            headers: headers,
            enabled: enabled,
            tools: existing?.tools ?? [],
            sessionID: existing?.sessionID,
            lastError: existing?.lastError,
            // 保留状态说明：编辑一次不该把「已断开」「已连接（无工具）」这类
            // 正常状态文案清掉（MCPService 刚把状态与错误拆开，这里要对齐）。
            statusNote: existing?.statusNote,
            createdAt: existing?.createdAt ?? Date()
        )
        store.upsert(server)
        dismiss()
    }
}

/// MCP 工具调用（测试工具）
struct MCPToolCallSheet: View {
    let server: MCPServer
    let tool: MCPTool
    @Environment(\.dismiss) private var dismiss
    @State private var argsText = "{}"
    @State private var resultText: String?
    @State private var isRunning = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(tool.description.isEmpty ? "无描述" : tool.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("工具描述")
                }

                Section {
                    TextField("{}", text: $argsText, axis: .vertical)
                        .lineLimit(4...12)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("参数 (JSON)")
                } footer: {
                    if let schema = prettySchema {
                        Text(schema)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let resultText {
                    Section {
                        Text(resultText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } header: {
                        Text("结果")
                    }
                }
            }
            .navigationTitle(tool.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        call()
                    } label: {
                        if isRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("调用")
                        }
                    }
                    .disabled(isRunning)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var prettySchema: String? {
        guard let data = tool.inputSchemaJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private func call() {
        isRunning = true
        resultText = nil
        errorMessage = nil
        Task {
            defer { isRunning = false }
            let result = await MCPService.shared.callTool(
                server: server,
                name: tool.name,
                argumentsJSON: argsText
            )
            resultText = result
        }
    }
}
