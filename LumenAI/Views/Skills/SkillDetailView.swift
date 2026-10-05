import SwiftUI

/// 技能详情视图
struct SkillDetailView: View {
    let skill: SkillStore.InstalledSkill
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var skillStore = SkillStore.shared
    @State private var showingEditSheet = false
    @State private var showingApplySheet = false
    @State private var paramValues: [String: String] = [:]
    @State private var paramErrors: [String] = []
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            // 头部信息
            headerSection

            ScrollView {
                VStack(spacing: 20) {
                    // 基本信息
                    basicInfoSection

                    // 参数配置
                    parameterSection

                    // 提示词预览
                    promptPreviewSection

                    // 使用统计
                    statsSection
                }
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(skill.manifest.name)
                    .font(.headline)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    skillStore.setEnabled(skill, enabled: !skill.manifest.isEnabled)
                } label: {
                    Image(systemName: skill.manifest.isEnabled ? "toggle.on.fill" : "toggle.off")
                        .foregroundStyle(skill.manifest.isEnabled ? .green : .gray)
                }
                Button {
                    showingEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            SkillCreationView(mode: .edit(skill))
        }
        .sheet(isPresented: $showingApplySheet) {
            SkillApplySheet(
                skill: skill.manifest,
                paramValues: $paramValues,
                paramErrors: $paramErrors
            ) { renderedPrompt in
                applySkill(renderedPrompt)
            }
        }
        .toast($toast)
    }

    // MARK: - 头部区域

    private var headerSection: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: skill.manifest.icon ?? skill.manifest.category.systemImage)
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                )

            Text(skill.manifest.author ?? "未知作者")
                .font(.caption)
                .foregroundStyle(.secondary)

            if skill.isBuiltIn {
                Label("内置技能", systemImage: "star.fill")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 20)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.accentColor.opacity(0.1), Color.clear]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 基本信息

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(skill.manifest.name, systemImage: "tag.fill")
                .font(.title2.weight(.bold))

            Text(skill.manifest.description)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label(skill.manifest.category.displayName, systemImage: skill.manifest.category.systemImage)
                    .font(.caption)
                Label("v\(skill.manifest.version)", systemImage: "tag")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            if !skill.manifest.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(skill.manifest.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 参数配置

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("参数")
                    .font(.headline)
                Spacer()
                Text("\(skill.manifest.parameters.count) 个参数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if skill.manifest.parameters.isEmpty {
                Text("该技能无需参数，直接使用即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(skill.manifest.parameters) { param in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(param.label.isEmpty ? param.name : param.label)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if param.isRequired {
                                    Text("必填")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.red)
                                }
                            }
                            Text(param.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let defaultValue = param.defaultValue, !defaultValue.isEmpty {
                                Text("默认值: \(defaultValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - 提示词预览

    private var promptPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("提示词模板")
                    .font(.headline)
                Spacer()
                Button("应用技能") {
                    showingApplySheet = true
                }
                .buttonStyle(.borderedProminent)
            }

            TextEditor(text: .constant(skill.manifest.promptTemplate))
                .frame(height: 150)
                .font(.caption)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
    }

    // MARK: - 使用统计

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("使用统计")
                .font(.headline)

            HStack(spacing: 20) {
                StatItem(label: "使用次数", value: "\(skill.manifest.useCount)")
                if let lastUsed = skill.manifest.lastUsedAt {
                    StatItem(label: "最后使用", value: formatDate(lastUsed))
                }
                StatItem(label: "创建", value: formatDate(skill.manifest.createdAt))
            }

            if skill.manifest.updatedAt != skill.manifest.createdAt {
                Text("更新于 \(formatDate(skill.manifest.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func applySkill(_ renderedPrompt: String) {
        // 记录使用统计
        if let idx = skillStore.skills.firstIndex(where: { $0.id == skill.id }) {
            skillStore.recordUse(skillStore.skills[idx])
        }

        // 将渲染后的提示词复制到剪贴板或直接发送到聊天
        // 这里简化为复制到剪贴板，实际可以使用 ChatService 将其发送到当前对话
        UIPasteboard.general.string = renderedPrompt
        toast = "已复制到剪贴板"
    }
}

// MARK: - 辅助视图

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = performLayout(subviews: subviews, width: proposal.width ?? 0)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = performLayout(subviews: subviews, width: bounds.width)
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    func performLayout(subviews: Subviews, width: CGFloat) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxWidth = max(maxWidth, x)
        }
        y += lineHeight

        return (maxWidth, y)
    }
}

// MARK: - 技能应用表单

struct SkillApplySheet: View {
    let skill: SkillManifest
    @Binding var paramValues: [String: String]
    @Binding var paramErrors: [String]
    @Environment(\.dismiss) private var dismiss
    let onApply: (String) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("技能: \(skill.name)") {
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("输入参数") {
                    ForEach(skill.parameters) { param in
                        ParameterInputView(param: param, value: Binding(
                            get: { paramValues[param.name] ?? param.defaultValue ?? "" },
                            set: { paramValues[param.name] = $0 }
                        ))
                    }
                }

                Section("预览") {
                    TextEditor(text: .constant(renderedPreview))
                        .frame(height: 200)
                        .font(.caption)
                        .disabled(true)
                }
            }
            .navigationTitle("应用技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        apply()
                    }
                    .disabled(!isValid)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var renderedPreview: String {
        skill.renderPrompt(with: paramValues)
    }

    private var isValid: Bool {
        paramErrors.isEmpty && skill.validateParameters(paramValues).isEmpty
    }

    private func apply() {
        let missing = skill.validateParameters(paramValues)
        if !missing.isEmpty {
            paramErrors = missing
            return
        }
        onApply(renderedPreview)
        dismiss()
    }
}

struct ParameterInputView: View {
    let param: SkillParameter
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(param.label.isEmpty ? param.name : param.label)
                    .font(.subheadline)
                if param.isRequired {
                    Text("*")
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            switch param.type {
            case .string, .multiline:
                if param.type == .multiline {
                    TextEditor(text: $value)
                        .frame(height: 100)
                } else {
                    TextField(param.description, text: $value)
                }
            case .number:
                TextField("数字", text: $value)
                    .keyboardType(.numberPad)
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { value.lowercased() == "true" || value == "1" },
                    set: { value = $0 ? "true" : "false" }
                ))
            case .select:
                if let options = param.enumValues {
                    Picker(param.name, selection: $value) {
                        ForEach(options, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    TextField(param.description, text: $value)
                }
            case .json:
                TextEditor(text: $value)
                    .frame(height: 120)
            }
        }
        .padding(.vertical, 4)
    }
}
