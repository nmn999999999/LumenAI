import SwiftUI

/// 模块详情：信息 / 权限 / 工具列表（可逐个测试）
struct ModuleDetailView: View {
    let module: PluginManager.InstalledModule
    @State private var results: [String: String] = [:]
    @State private var testing: String?

    var body: some View {
        List {
            Section {
                LabeledContent("名称", value: module.manifest.name)
                LabeledContent("版本", value: "v\(module.manifest.version)")
                if let author = module.manifest.author, !author.isEmpty {
                    LabeledContent("作者", value: author)
                }
                LabeledContent("工具数", value: "\(module.toolCount)")
                LabeledContent("权限", value: permissionsText)
            } header: {
                Text("模块信息")
            }

            Section {
                if module.engine.tools.isEmpty {
                    Text("该模块没有注册任何工具")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(module.engine.tools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tool.name)
                            .font(.subheadline.weight(.semibold))
                        if !tool.description.isEmpty {
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !tool.parameters.isEmpty {
                            Text("参数: " + tool.parameters.keys.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                test(tool)
                            } label: {
                                if testing == tool.name {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Label("测试", systemImage: "play.circle")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(testing != nil)

                            if module.engine.requiresApproval() {
                                Label("需授权", systemImage: "shield.lefthalf.filled")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let result = results[tool.name] {
                            Text(result)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(20)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("工具")
            } footer: {
                Text("「测试」以空参数调用工具（无参数工具可直接看效果）；联网工具会真实发起网络请求。")
                    .font(.caption2)
            }
        }
        .scrollContentBackground(.hidden)
        .glassScrollEdges()
        .navigationTitle(module.manifest.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var permissionsText: String {
        if module.manifest.permissions.isEmpty { return "无（纯计算）" }
        return module.manifest.permissions.map { p -> String in
            switch p {
            case "network": return "联网"
            case "storage": return "本地存储"
            default: return p
            }
        }.joined(separator: " / ")
    }

    private func test(_ tool: PluginToolDef) {
        testing = tool.name
        Task {
            defer { testing = nil }
            let result = await module.engine.call(name: tool.name, argumentsJSON: "{}")
            results[tool.name] = result
        }
    }
}
