import SwiftUI
import Photos
#if canImport(UIKit)
import UIKit
#endif

struct MessageBubble: View {
    let message: ChatMessage
    /// 操作回调（由 ChatView 注入）
    var onRegenerate: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onSpeak: (() -> Void)? = nil
    var isSpeaking: Bool = false

    @State private var copied = false
    @ObservedObject private var settings = SettingsStorage.shared

    /// 图片解码缓存：流式期间气泡会频繁重算 body，避免每次都重新解码 JPEG 数据
    private static let imageCache = NSCache<NSString, UIImage>()

    /// 解码消息内嵌图片（带缓存，key = 消息id-图片序号）
    private func cachedImage(at index: Int) -> UIImage? {
        let key = "\(message.id.uuidString)-\(index)" as NSString
        if let hit = Self.imageCache.object(forKey: key) { return hit }
        guard index < message.images.count,
              let img = UIImage(data: message.images[index].data) else { return nil }
        Self.imageCache.setObject(img, forKey: key)
        return img
    }

    /// 消息时间戳（HH:mm）
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func timeText(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
            }
            content
            if message.role == .assistant || message.role == .tool {
                Spacer(minLength: 40)
            }
        }
        .contextMenu { contextMenuItems }
    }

    /// 气泡最大宽度（user/assistant 统一，保证左右视觉对齐）
    private static let bubbleMaxWidth: CGFloat = 340

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    imageRow
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                Text(Self.timeText(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: Self.bubbleMaxWidth, alignment: .trailing)
            .background(Color.accentColor, in: .rect(cornerRadius: 20))

        case .assistant:
            // 布局修正：先把 frame(maxWidth:) 放在最外层，再加 padding 缩进；所有子组件
            // （ThinkSection / Markdown / toolCallChips / 速度时间戳）都被这个宽度约束，
            // 思考块或长工具结果展开时不会越过 bubbleMaxWidth 与下一条气泡/右侧贴边重叠。
            VStack(alignment: .leading, spacing: 8) {
                if settings.settings.showToolCalls {
                    toolCallChips
                }
                if settings.settings.showThinking, let think = message.thinkContent, !think.isEmpty {
                    ThinkSection(think: think, isThinking: message.isThinking)
                }
                // 生成/多模态图片（assistant）：/draw 云端生图的结果气泡
                if !message.images.isEmpty {
                    generatedImageBlock
                }
                let displayText = message.isAgentRound ? AgentService.cleanDisplayText(message.visibleContent) : message.visibleContent
                if !displayText.isEmpty {
                    MarkdownView(markdown: displayText)
                        .textSelection(.enabled)
                } else if message.isStreaming && message.thinkContent == nil && message.images.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("思考中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                if !message.isStreaming {
                    HStack(spacing: 8) {
                        if let speed = message.speedText, !speed.isEmpty {
                            Text(speed)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        Text(Self.timeText(message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: Self.bubbleMaxWidth, alignment: .leading)
            // 整个 assistant 列容器有了统一背景（轻微材质），思考展开时也不会突兀分离
            .background(.regularMaterial, in: .rect(cornerRadius: 18))

        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Label("工具消息", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: Self.bubbleMaxWidth, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))

        case .system:
            EmptyView()
        }
    }

    private var imageRow: some View {
        HStack(spacing: 6) {
            ForEach(message.images.indices, id: \.self) { idx in
                #if canImport(UIKit)
                if let img = cachedImage(at: idx) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(.rect(cornerRadius: 14))
                }
                #endif
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
    }

    /// assistant 上的生成图（/draw 结果）：大图预览 + 保存到相册
    @ViewBuilder
    private var generatedImageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if canImport(UIKit)
            if let img = cachedImage(at: 0) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 14))
                    .frame(maxWidth: 260)
            }
            #endif
            Button {
                saveFirstImageToAlbum()
            } label: {
                Label(savedToAlbum ? t("已保存到相册") : t("保存到相册"), systemImage: savedToAlbum ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(savedToAlbum)
        }
    }

    @State private var savedToAlbum = false

    /// 把本消息第一张图写入系统相册（请求 addOnly 授权）。
    private func saveFirstImageToAlbum() {
        #if canImport(UIKit)
        guard let data = message.images.first?.data,
              let ui = UIImage(data: data) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: ui)
            }) { success, _ in
                DispatchQueue.main.async { self.savedToAlbum = success }
            }
        }
        #endif
    }

    @ViewBuilder
    private var toolCallChips: some View {
        if !message.toolCalls.isEmpty {
            // M2(REVIEW): 多个玻璃 chip 必须包 GlassEffectContainer（Apple 文档 Best Practices #1），
            // spacing 拉开玻璃合并距离，避免 iOS 26.1 真机上相邻 chip 粘成一片（v0.3.22 经验）。
            GlassEffectContainer(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(message.toolCalls) { call in
                        ToolCallChip(call: call)
                    }
                }
            }
        }
    }

    // MARK: - 操作菜单（复制 / 重新生成 / 编辑 / 删除 / 朗读）

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            UIPasteboard.general.string = message.content
            copied = true
        } label: {
            Label(copied ? t("已复制") : t("复制"), systemImage: "doc.on.doc")
        }

        if message.role == .assistant, let onSpeak {
            Button {
                onSpeak()
            } label: {
                Label(isSpeaking ? t("停止朗读") : t("朗读"), systemImage: "speaker.wave.2")
            }
        }

        if message.role == .assistant, let onRegenerate {
            Button {
                onRegenerate()
            } label: {
                Label(t("重新生成"), systemImage: "arrow.clockwise")
            }
        }

        if message.role == .user, let onEdit {
            Button {
                onEdit()
            } label: {
                Label(t("编辑消息"), systemImage: "pencil")
            }
        }

        if message.role != .system, let onDelete {
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(t("删除消息"), systemImage: "trash")
            }
        }
    }
}

struct ToolCallChip: View {
    let call: ChatMessage.ToolCall
    @State private var expanded = false

    /// 不同状态下应展示的颜色与图标（opencode ToolPart 风格）
    private var statusBadge: (icon: String, tint: Color, label: String) {
        switch call.status {
        case .pending:
            return ("clock", .secondary, "等待调用")
        case .running:
            return ("hourglass", .blue, "执行中…")
        case .awaitingApproval:
            return ("exclamationmark.shield.fill", .orange, "需要授权")
        case .complete:
            return call.truncated
                ? ("checkmark.circle", .secondary, "完成（结果已截断）")
                : ("checkmark.circle.fill", .green, "完成")
        case .error:
            return ("xmark.octagon.fill", .red, "失败")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: statusBadge.icon)
                        .font(.caption2)
                        .foregroundStyle(statusBadge.tint)
                    Text("工具调用: \(call.title ?? call.name)")
                        .font(.caption.weight(.semibold))
                    Text("· \(statusBadge.label)")
                        .font(.caption2)
                        .foregroundStyle(statusBadge.tint)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            if expanded {
                Group {
                    Text(prettyArguments)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let result = call.result {
                        Text(result)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(call.status == .error ? .red : .secondary)
                            .lineLimit(call.truncated ? 24 : 12)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    call.status == .error ? AnyShapeStyle(Color.red.opacity(0.4)) : AnyShapeStyle(.quaternary),
                    lineWidth: 1
                )
        )
    }

    private var prettyArguments: String {
        guard let data = call.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: pretty, encoding: .utf8)
        else { return call.arguments }
        return str
    }
}

// MARK: - 思考内容折叠区（<think>…</think>）

struct ThinkSection: View {
    let think: String
    var isThinking: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.tint)
                    Text(isThinking ? "思考中" : "已深度思考")
                        .font(.footnote.weight(.medium))
                    Spacer()
                    if isThinking {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.caption2.bold())
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(think)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}
