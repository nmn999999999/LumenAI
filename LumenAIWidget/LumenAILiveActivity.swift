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
                        // 只有"等待授权"这一阶段出现按钮。
                        //
                        // 为什么别的阶段不给按钮：其它阶段（思考中/执行工具/下载中）都是
                        // "它自己在干活"，这时露出按钮会让人以为**必须点一下才会继续**，
                        // 于是本该自动跑完的任务被人工打断。
                        // 而"等待授权"是唯一一个**不给答复就不会继续**的阶段。
                        if context.state.phase == .awaitingApproval {
                            HStack(spacing: 8) {
                                Button(intent: ApproveToolIntent()) {
                                    Label("允许", systemImage: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .tint(.green)
                                Button(intent: DenyToolIntent()) {
                                    Label("拒绝", systemImage: "xmark")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .tint(.red)
                            }
                            .buttonStyle(.borderedProminent)
                        }
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
        case .awaitingApproval: return .yellow
        }
    }

    private func compactText(_ s: LumenAIActivityAttributes.ContentState) -> String {
        // 下载有明确百分比就显示百分比。
        if s.phase == .downloading, let p = s.progress { return "\(Int(p * 100))%" }
        // **只有在有真实计划时才显示分数**（x/y）。
        // 没有分母时显示成 "3/50" 之类是错的：那个 50 是内部轮数软上限，
        // 不是任务步数 —— 用户会以为"才完成 6%"而放弃一个其实快结束的任务。
        // 没有计划时只显示轮数，不带斜杠、不带分母。
        if let total = s.totalSteps, total > 0 { return "\(s.step)/\(total)" }
        if s.step > 0 { return "第\(s.step)轮" }
        return "•"
    }

    private func subtitle(_ c: ActivityViewContext<LumenAIActivityAttributes>) -> String {
        var parts: [String] = []
        // 有真实计划 → "已完成 x/y 步"（这是用户理解的进度）；
        // 没有 → "第 N 轮"（只说事实，不编分母）。
        if let total = c.state.totalSteps, total > 0 {
            parts.append("已完成 \(c.state.step)/\(total) 步")
        } else if c.state.step > 0 {
            parts.append("第 \(c.state.step) 轮")
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
            // 锁屏上同样给按钮：很多人是锁屏状态下看到卡片提示的，
            // 这时为了"允许一次 ssh"还要解锁、开 App、再找到弹窗，
            // 等于这个功能白做。
            if context.state.phase == .awaitingApproval {
                HStack(spacing: 8) {
                    Button(intent: ApproveToolIntent()) {
                        Label("允许", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                    Button(intent: DenyToolIntent()) {
                        Label("拒绝", systemImage: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }
}
