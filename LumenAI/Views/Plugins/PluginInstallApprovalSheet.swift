import SwiftUI

/// 对话内生成插件的**安装确认卡**（create_plugin 的审批 UI）。
///
/// 为什么不用通用 alert：alert 撑不下完整工具源码，而"是否信任这段即将被安装的代码"
/// 这个决定必须建立在看得到权限与代码的前提上 —— 这是整个特性的安全闸门，
/// 也是现场演示"AI 获得权限"的关键镜头。
///
/// 决策只有两种：拒绝 / 确认安装（.deny / .once）。刻意没有"本会话总是允许"：
/// 每个插件内容都不同，一次隐式放行等于给后续所有生成代码开空白支票。
struct PluginInstallApprovalSheet: View {
    let call: ChatMessage.ToolCall
    let onDecision: (ApprovalDecision) -> Void

    /// 从工具参数解析出的安装规格（模型生成，一律按不可信数据展示）。
    private struct Spec {
        var id: String = ""
        var name: String = ""
        var version: String = "1.0.0"
        var detail: String = ""
        var permissions: [String] = []
        var toolsJS: String = ""
    }

    /// 解析失败说明（缺字段 / 非合法 JSON）。非 nil 时只允许拒绝。
    private let parseError: String?
    private let spec: Spec

    init(call: ChatMessage.ToolCall, onDecision: @escaping (ApprovalDecision) -> Void) {
        self.call = call
        self.onDecision = onDecision
        if let data = call.arguments.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var s = Spec()
            s.id = (dict["id"] as? String) ?? ""
            s.name = (dict["name"] as? String) ?? ""
            s.version = (dict["version"] as? String)?.isEmpty == false ? (dict["version"] as? String ?? "1.0.0") : "1.0.0"
            s.detail = (dict["description"] as? String) ?? ""
            if let perms = dict["permissions"] as? [String] {
                s.permissions = perms
            } else if let single = dict["permissions"] as? String, !single.isEmpty {
                s.permissions = [single]
            }
            s.toolsJS = (dict["tools_js"] as? String) ?? ""

            if s.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || s.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.parseError = "插件参数缺少 id 或 name，无法安装。拒绝后 AI 会收到提示并重新生成。"
            } else if s.toolsJS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.parseError = "插件没有提供 tools.js 源码，无法安装。"
            } else {
                self.parseError = nil
            }
            self.spec = s
        } else {
            self.spec = Spec()
            self.parseError = "工具参数不是合法 JSON，无法安装。拒绝后 AI 会收到提示并重新生成。"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            header

            if let parseError {
                ContentUnavailableViewCompat(message: parseError)
            } else {
                metadataCard
                permissionsCard
                codeSection
            }

            Spacer(minLength: 0)
            actionButtons
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text("AI 请求安装新能力")
                .font(.headline)
            Text("插件会持久保留在本机，可随时在「插件」页删除；运行在 JS 沙盒中，不能触碰沙盒外的数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("名称", spec.name)
            row("ID", spec.id)
            row("版本", spec.version)
            if !spec.detail.isEmpty {
                row("描述", spec.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("申请权限")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if spec.permissions.isEmpty {
                chip("纯计算 · 无额外权限", systemImage: "function", tint: .green)
            }
            ForEach(spec.permissions, id: \.self) { perm in
                switch perm {
                case "network":
                    chip("可联网（仅 https，20s / 2MB 上限）", systemImage: "network", tint: .orange)
                case "storage":
                    chip("模块本地存储（私有键值）", systemImage: "internaldrive", tint: .blue)
                default:
                    chip("未知权限：\(perm)（安装将被拒绝）", systemImage: "exclamationmark.triangle", tint: .red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text).font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: .capsule)
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("tools.js 源码")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(spec.toolsJS.count) 字符")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ScrollView {
                Text(spec.toolsJS)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1)
            )
        }
        .frame(maxHeight: .infinity)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                onDecision(.deny)
            } label: {
                Text("拒绝安装")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button {
                onDecision(.once)
            } label: {
                Label("确认安装", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(parseError != nil)
        }
    }
}

/// 解析失败时的占位（兼容低系统，不依赖 iOS 17 的 ContentUnavailableView）。
private struct ContentUnavailableViewCompat: View {
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }
}

/// App 根层（MainTabView）的安装卡挂载锚点。
///
/// 为什么挂在根层而不是 ChatView.body：
/// 1. 安装审批是 App 级事件 —— 用户停留在任意 tab 时都该看到这张卡；
/// 2. ChatView.body 的 ViewBuilder 已在 Swift 类型检查器的临界点，任何内联 sheet
///    泛型链都会让整个 body 编译超时（"unable to type-check in reasonable time"）。
///
/// 零尺寸 + hidden：不占布局。待决请求由 AgentApprovalCenter.pendingInstallCall 驱动，
/// resolve 后该值被清空，sheet 自动关闭；因此卡片内部只需调 center.resolve。
struct PluginInstallSheetAnchor: View {
    @Binding var item: ChatMessage.ToolCall?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .hidden()
            .sheet(item: $item) { call in
                PluginInstallApprovalSheet(call: call) { decision in
                    AgentApprovalCenter.shared.resolve(decision)
                }
                .interactiveDismissDisabled()
                .onDisappear {
                    // 异常路径（任务取消把等待按拒绝收掉等）卡片消失却没走按钮时：
                    // 若中心仍在等待，按拒绝兜底，绝不让 AgentService 永久阻塞。
                    if AgentApprovalCenter.shared.isWaiting {
                        AgentApprovalCenter.shared.resolve(.deny)
                    }
                }
            }
    }
}
