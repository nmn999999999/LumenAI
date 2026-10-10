import SwiftUI

/// 「手机协作」卡片：快捷指令主导的循环 + 实时进度 + 操作指引。
///
/// 工作方式：快捷指令（截屏 → OCR）把每一屏写进共享目录并唤起 App；
/// Lumen 决策后把「下一步该点哪里 / 输入什么」写回，用户照着操作即可。
/// 本构建不能自动点击，交互由用户完成（见 `ShortcutEngine` 能力边界）。
struct MobileAgentCard: View {

    @StateObject private var bridge = MobileAgentBridge.shared

    private var shortcutURL: URL? {
        Bundle.main.url(forResource: "LumenAgent", withExtension: "shortcut")
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "手机协作", systemImage: "iphone.gen3")
                    Spacer()
                    Text(bridge.active ? "进行中 · 第 \(bridge.stepIndex) 步" : "未开始")
                        .font(.caption)
                        .foregroundStyle(bridge.active ? .green : .secondary)
                }

                Text("快捷指令主导的循环：截屏 → 识别屏幕 → 交给 Lumen 决策 → 把「下一步操作」实时展示给你 → 你照着点 → 继续。本 App 无法自动点击，交互由你完成。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("协作快捷指令名").font(.subheadline)
                    TextField("例如 LumenAgent", text: $bridge.shortcutName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout)
                    Text("与你在「快捷指令」App 里创建的循环指令名称完全一致。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                        Button("结束") { bridge.endSession() }
                            .buttonStyle(.glass)
                    } else {
                        Button("开始协作") {
                            let name = bridge.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            bridge.startSession(shortcutName: name)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }

                if let guidance = bridge.currentGuidance, bridge.active, !guidance.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前操作指引").font(.caption).foregroundStyle(.secondary)
                        Text(guidance).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                if !bridge.events.isEmpty {
                    Divider()
                    Text("实时进度").font(.subheadline)
                    ForEach(bridge.events.suffix(12).reversed()) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: icon(event.kind))
                                .font(.caption2)
                                .foregroundStyle(color(event.kind))
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.text)
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(event.at, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Text("共享目录：文件 App → 我的 iPhone → LumenAI → LumenAgent（inbox.txt / outbox.txt / events.jsonl）。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(_ kind: MobileAgentBridge.Event.Kind) -> String {
        switch kind {
        case .sessionStart: return "play.circle.fill"
        case .step:         return "rectangle.on.rectangle"
        case .guide:        return "hand.point.up.left.fill"
        case .awaitingUser: return "hourglass"
        case .message:      return "paperplane.fill"
        case .done:         return "checkmark.circle.fill"
        case .error:        return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: MobileAgentBridge.Event.Kind) -> Color {
        switch kind {
        case .sessionStart: return .blue
        case .step:         return .secondary
        case .guide:        return .accentColor
        case .awaitingUser: return .orange
        case .message:      return .purple
        case .done:         return .green
        case .error:        return .red
        }
    }
}
