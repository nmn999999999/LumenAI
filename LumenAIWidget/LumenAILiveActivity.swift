import ActivityKit
import WidgetKit
import SwiftUI

/// 灵动岛 / 锁屏上的实时活动。
///
/// 布局分四块，必须**全部**提供（少一块在真机上就是空白或系统占位符）：
///   · compactLeading / compactTrailing —— 岛上胶囊被别的活动挤压时左右两个小图标
///   · minimal —— 只留一个图标（多个活动并存时最窄的形态）
///   · expanded —— 长按（或系统展示）时的完整卡片
///   · 锁屏 —— 锁屏上的横幅，用户不解锁也能看
struct LumenAILiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LumenAIActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.shortPhaseText)
                            .font(.caption2.weight(.semibold))
                    } icon: {
                        Image(systemName: context.state.symbolName)
                            .foregroundStyle(tint(for: context.state.phase))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 右侧显示"已经跑了多久"，而不是一个静止的图标 ——
                    // 用户切出去最想知道的是"它还在动吗"，
                    // 一个持续走动的计时器比任何文字都能回答这个问题。
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 56)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let progress = context.state.progress {
                            ProgressView(value: min(max(progress, 0), 1))
                                .tint(tint(for: context.state.phase))
                        }
                        HStack(spacing: 6) {
                            Text(subtitle(context))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(tint(for: context.state.phase))
            } compactTrailing: {
                // 紧凑态只放一个字：这里宽度只有十几 pt，放两个字符就会截断成省略号，
                // 而截断后的内容比一个图标更没信息量。
                Text(compactText(context.state))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint(for: context.state.phase))
            } minimal: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(tint(for: context.state.phase))
            }
            // 点一下回到 App：不带这个 key，用户点灵动岛只会展开卡片、进不去 App。
            .widgetURL(URL(string: "lumenai://chat"))
        }
    }

    private func tint(for phase: LumenAIActivityAttributes.Phase) -> Color {
        switch phase {
        case .thinking:    return .blue
        case .tool:        return .orange
        case .downloading: return .blue
        case .done:        return .green
        case .failed:      return .red
        case .paused:      return .orange
        }
    }

    private func compactText(_ s: LumenAIActivityAttributes.ContentState) -> String {
        // 下载有明确百分比就显示数字；其余阶段显示轮次，没有轮次就显示一个点。
        if s.phase == .downloading, let p = s.progress { return "\(Int(p * 100))%" }
        if let total = s.totalSteps, total > 0 { return "\(s.step)/\(total)" }
        if s.step > 0 { return "\(s.step)" }
        return "•"
    }

    private func subtitle(_ c: ActivityViewContext<LumenAIActivityAttributes>) -> String {
        var parts: [String] = []
        if let total = c.state.totalSteps, total > 0 {
            parts.append("第 \(c.state.step)/\(total) 步")
        } else if c.state.step > 0 {
            parts.append("第 \(c.state.step) 步")
        }
        if let d = c.state.detail, !d.isEmpty { parts.append(d) }
        if parts.isEmpty { parts.append(c.attributes.conversationTitle) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 锁屏

/// 锁屏横幅。内容比灵动岛宽松，所以在岛上省掉的那条补充说明在这里显示出来。
///
/// 为什么锁屏要单独写而不是复用 expanded：两者的宽度、圆角与安全区都不同，
/// 复用出来的结果是在其中一处必然错位（尤其左侧标题会被灵动岛的圆角切掉）。
private struct LockScreenView: View {
    let context: ActivityViewContext<LumenAIActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(.white)
                Text(context.state.shortPhaseText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(context.state.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text(context.state.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            if let progress = context.state.progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(.white)
            }
            if let detail = context.state.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
        }
        .padding(14)
    }
}
