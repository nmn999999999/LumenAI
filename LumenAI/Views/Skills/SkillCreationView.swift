import SwiftUI

/// 技能创建/编辑视图
struct SkillCreationView: View {
    enum Mode {
        case create
        case edit(SkillStore.InstalledSkill)

        /// `InstalledSkill` 不是 Equatable，Mode 无法隐式合成 `==`；
        /// 调用点要的只是"是不是新建"，用显式判断即可。
        var isCreate: Bool {
            if case .create = self { return true }
            return false
        }
    }

    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var skillStore = SkillStore.shared

    @State private var name = ""
    @State private var descriptionText = ""
    @State private var category: SkillCategory = .productivity
    @State private var tags = ""
    @State private var promptTemplate = ""
    @State private var selectedIcon = "sparkles"
    @State private var isEnabled = true
    @State private var useWorkflow = false
    @State private var parameters: [SkillParameter] = []
    @State private var showingParameterSheet = false

    @State private var toast: String?

    init(mode: Mode = .create) {
        self.mode = mode
    }

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("技能名称", text: $name)
                    TextField("描述", text: $descriptionText, axis: .vertical)
                        .lineLimit(3...6)
                    Picker("分类", selection: $category) {
                        ForEach(SkillCategory.allCases) { cat in
                            Text(cat.displayName).tag(cat)
                        }
                    }
                    HStack {
                        Text("标签")
                        Spacer()
                        Text(verbatim: "用逗号分隔")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("标签", text: $tags)
                        .lineLimit(1)
                    HStack {
                        Text("图标")
                        Spacer()
                        Picker("图标", selection: $selectedIcon) {
                            ForEach(allIcons, id: \.self) { icon in
                                Image(systemName: icon).tag(icon)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle("启用技能", isOn: $isEnabled)
                }

                Section("参数配置") {
                    Button {
                        showingParameterSheet = true
                    } label: {
                        Label("添加参数 (\(parameters.count))", systemImage: "plus.circle")
                    }
                    if !parameters.isEmpty {
                        ForEach(parameters) { param in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(param.label.isEmpty ? param.name : param.label)
                                    .font(.subheadline)
                                Text(param.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(param.type.displayName + (param.isRequired ? " · 必填" : " · 可选"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { indices in
                            parameters.remove(atOffsets: indices)
                        }
                    } else {
                        Text("暂无参数。点击添加参数以支持模板变量。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("提示词模板") {
                    TextEditor(text: $promptTemplate)
                        .frame(height: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    Text("使用 {{paramName}} 插入参数，参数名与上方的参数名称一致。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if useWorkflow {
                    Section("多步工作流") {
                        Text("多步工作流功能即将上线...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(mode.isCreate ? "新建技能" : "编辑技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveSkill()
                    }
                    .disabled(name.isEmpty || promptTemplate.isEmpty)
                }
            }
            .sheet(isPresented: $showingParameterSheet) {
                ParameterEditView(parameters: $parameters)
            }
            .toast($toast)
        }
        .onAppear {
            if case .edit(let skill) = mode {
                loadSkill(skill)
            }
        }
    }

    private var allIcons: [String] {
        [
            "sparkles", "star.fill", "bell.fill", "bolt.fill", "flame.fill",
            "heart.fill", "brain.head.profile", "lightbulb.fill", "wrench.fill",
            "hammer.fill", "pencil.and.outline", "doc.text.fill", "chart.bar.fill",
            "globe", "paperplane.fill", "gearshape.fill", "wand.and.stars",
            "face.smiling.fill", "graduationcap.fill", "books.vertical.fill"
        ]
    }

    private func loadSkill(_ skill: SkillStore.InstalledSkill) {
        name = skill.manifest.name
        descriptionText = skill.manifest.description
        category = skill.manifest.category
        tags = skill.manifest.tags.joined(separator: ", ")
        promptTemplate = skill.manifest.promptTemplate
        selectedIcon = skill.manifest.icon ?? "sparkles"
        isEnabled = skill.manifest.isEnabled
        parameters = skill.manifest.parameters
    }

    private func saveSkill() {
        let skillManifest = SkillManifest(
            id: mode.isCreate ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description : getExistingID(),
            name: name,
            version: "1.0.0",
            description: descriptionText,
            category: category,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            icon: selectedIcon,
            promptTemplate: promptTemplate,
            parameters: parameters,
            isEnabled: isEnabled
        )

        do {
            try skillStore.save(skillManifest)
            toast = "技能\(mode.isCreate ? "创建" : "更新")成功"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dismiss()
            }
        } catch {
            toast = "保存失败: \(error.localizedDescription)"
        }
    }

    private func getExistingID() -> String {
        if case .edit(let skill) = mode {
            return skill.id
        } else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
        }
    }
}

// MARK: - 参数编辑视图

struct ParameterEditForm: View {
    @Binding var parameter: SkillParameter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("参数名(英文, 用于模板中)", text: Binding(
                        get: { parameter.name },
                        set: { parameter.name = $0.lowercased().replacingOccurrences(of: " ", with: "_") }
                    ))
                    TextField("显示标签", text: Binding(
                        get: { parameter.label },
                        set: { parameter.label = $0 }
                    ))
                    Picker("类型", selection: $parameter.type) {
                        ForEach(ParameterType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Toggle("必填", isOn: Binding(
                        get: { parameter.isRequired },
                        set: { parameter.isRequired = $0 }
                    ))
                }

                Section("参数说明") {
                    TextField("描述", text: Binding(
                        get: { parameter.description },
                        set: { parameter.description = $0 }
                    ), axis: .vertical)
                        .lineLimit(3...6)
                    if parameter.type == .select {
                        TextField("选项值(逗号分隔)", text: Binding(
                            get: { parameter.enumValues?.joined(separator: ", ") ?? "" },
                            set: { parameter.enumValues = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } }
                        ))
                    }
                }
            }
            .navigationTitle("编辑参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ParameterEditView: View {
    @Binding var parameters: [SkillParameter]
    @State private var editingParam: SkillParameter?

    var body: some View {
        NavigationView {
            List {
                ForEach($parameters) { $param in
                    Button {
                        editingParam = param
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(param.label.isEmpty ? param.name : param.label)
                                .font(.subheadline.weight(.medium))
                            Text(param.type.displayName + (param.isRequired ? " · 必填" : " · 可选"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indices in
                    parameters.remove(atOffsets: indices)
                }

                Button {
                    let newParam = SkillParameter(
                        name: "param_\(parameters.count + 1)",
                        label: "",
                        type: .string,
                        description: "",
                        isRequired: true
                    )
                    parameters.append(newParam)
                    editingParam = parameters.last
                } label: {
                    Label("添加参数", systemImage: "plus")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .navigationTitle("管理参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        // 关闭
                    }
                }
            }
            .sheet(item: Binding(
                get: { editingParam },
                set: { newValue in
                    if let newValue = newValue,
                       let index = parameters.firstIndex(where: { $0.id == newValue.id }) {
                        parameters[index] = newValue
                    }
                    editingParam = newValue
                }
            )) { param in
                ParameterEditForm(parameter: Binding(
                    get: { param },
                    set: { _ in }
                ))
            }
        }
    }
}
