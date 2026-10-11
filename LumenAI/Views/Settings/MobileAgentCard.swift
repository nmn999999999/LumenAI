import SwiftUI

/// 「手机协作」卡片（云端 API 版 · 无文件）。
///
/// 独立的 agent 跑在快捷指令里（截屏 → OCR → 调云端 LLM → 拿到「下一步做什么」→ 循环）。
/// 这里只配置云端参数并启动快捷指令。
struct MobileAgentCard: View {

    @StateObject private var bridge = MobileAgentBridge.shared

    private var shortcutURL: URL? {
        Bundle.main.url(forResource: "LumenAgent", withExtension: "shortcut")
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "手机协作（云端 API）", systemImage: "iphone.gen3")
                    Spacer()
                    Text(bridge.active ? "已启动 · 第 \(bridge.stepIndex) 步" : "未启动")
                        .font(.caption)
                        .foregroundStyle(bridge.active ? .green : .secondary)
                }

                Text("独立的 agent 跑在快捷指令里：截屏 → 识别屏幕 → 调云端 LLM 得到「下一步做什么」→ 展示给你 → 你照着点 → 循环。无需任何文件；本 App 只提供云端参数并启动快捷指令。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                field("协作快捷指令名", text: $bridge.shortcutName, placeholder: "LumenAgent", secure: false)
                field("API 端点（OpenAI 兼容）", text: $bridge.endpoint,
                      placeholder: "https://api.openai.com/v1/chat/completions", secure: false)
                field("模型", text: $bridge.model, placeholder: "gpt-4o-mini", secure: false)
                field("API Key", text: $bridge.apiKey, placeholder: "sk-…", secure: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("系统提示词（交给快捷指令里的 agent）").font(.subheadline)
                    TextEditor(text: $bridge.systemPrompt)
                        .font(.caption)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 10) {
                    if let url = shortcutURL {
                        ShareLink(item: url) {
                            Label("安装协作快捷指令", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.glass)
                    }
                    Spacer()
                    if bridge.active {
                        Button("结束") { bridge.endSession() }.buttonStyle(.glass)
                    } else {
                        Button("开始协作") { bridge.startSession() }
                            .buttonStyle(.glassProminent)
                    }
                }

                if let g = bridge.currentGuidance, !g.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前指引").font(.caption).foregroundStyle(.secondary)
                        Text(g).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                if !bridge.events.isEmpty {
                    Divider()
                    Text("进度").font(.subheadline)
                    ForEach(bridge.events.suffix(12).reversed()) { e in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: icon(e.kind))
                                .font(.caption2).foregroundStyle(color(e.kind)).frame(width: 14)
                            Text(e.text).font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("说明：API Key 仅保存在本机并随启动参数传给快捷指令；请使用权限受限的密钥。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, placeholder: String, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            if secure {
                SecureField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
            } else {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
            }
        }
    }

    private func icon(_ kind: MobileAgentBridge.Event.Kind) -> String {
        switch kind {
        case .start: return "play.circle.fill"
        case .step:  return "rectangle.on.rectangle"
        case .guide: return "hand.point.up.left.fill"
        case .done:  return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: MobileAgentBridge.Event.Kind) -> Color {
        switch kind {
        case .start: return .blue
        case .step:  return .secondary
        case .guide: return .accentColor
        case .done:  return .green
        case .error: return .red
        }
    }
}
