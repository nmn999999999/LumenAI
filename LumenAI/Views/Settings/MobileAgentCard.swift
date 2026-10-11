import SwiftUI

/// 「手机协作」卡片（方案 B：agent 在 App 内 + 官方 x-callback-url）。
///
/// 快捷指令只做「截屏 → 提取文本」，用官方 x-callback-url 把屏幕文字回调给 App；
/// App 调云端 LLM 得到「下一步做什么」并展示，用户照做后点「继续」再截一屏。
struct MobileAgentCard: View {

    @StateObject private var bridge = MobileAgentBridge.shared

    private var captureURL: URL? {
        Bundle.main.url(forResource: "LumenCapture", withExtension: "shortcut")
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "手机协作（云端 API）", systemImage: "iphone.gen3")
                    Spacer()
                    Text(bridge.active ? "进行中 · 第 \(bridge.stepIndex) 屏" : "未启动")
                        .font(.caption)
                        .foregroundStyle(bridge.active ? .green : .secondary)
                }

                Text("快捷指令只负责「截屏 → 识别文字」，通过官方 x-callback-url 把屏幕文字回传给 App；App 调云端 LLM 给出「下一步做什么」，你照做后点「继续」再截一屏。无需文件。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                field("采集快捷指令名", text: $bridge.shortcutName, placeholder: "LumenCapture", secure: false)
                field("目标", text: $bridge.task, placeholder: "例如：在设置里把屏幕亮度调到一半", secure: false)
                field("API 端点（OpenAI 兼容）", text: $bridge.endpoint,
                      placeholder: "https://api.openai.com/v1/chat/completions", secure: false)
                field("模型", text: $bridge.model, placeholder: "gpt-4o-mini", secure: false)
                field("API Key", text: $bridge.apiKey, placeholder: "sk-…", secure: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("系统提示词").font(.subheadline)
                    TextEditor(text: $bridge.systemPrompt)
                        .font(.caption).frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 10) {
                    if let url = captureURL {
                        ShareLink(item: url) { Label("安装采集快捷指令", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.glass)
                    }
                    Spacer()
                    if bridge.active {
                        if bridge.isDeciding {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("继续（截下一屏）") { bridge.continueLoop() }
                                .buttonStyle(.glassProminent)
                        }
                        Button("结束") { bridge.endSession() }.buttonStyle(.glass)
                    } else {
                        Button("开始协作") { bridge.startSession() }.buttonStyle(.glassProminent)
                    }
                }

                if let g = bridge.currentGuidance, !g.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("下一步操作").font(.caption).foregroundStyle(.secondary)
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
                            Image(systemName: icon(e.kind)).font(.caption2).foregroundStyle(color(e.kind)).frame(width: 14)
                            Text(e.text).font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("API Key 仅存本机、仅在 App 内用于调用该端点（不再带入快捷指令）。")
                    .font(.caption2).foregroundStyle(.tertiary)
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
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout)
            } else {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout)
            }
        }
    }

    private func icon(_ k: MobileAgentBridge.Event.Kind) -> String {
        switch k {
        case .start:  return "play.circle.fill"
        case .screen: return "rectangle.on.rectangle"
        case .guide:  return "hand.point.up.left.fill"
        case .error:  return "exclamationmark.triangle.fill"
        case .done:   return "checkmark.circle.fill"
        }
    }

    private func color(_ k: MobileAgentBridge.Event.Kind) -> Color {
        switch k {
        case .start:  return .blue
        case .screen: return .secondary
        case .guide:  return .accentColor
        case .error:  return .red
        case .done:   return .green
        }
    }
}
