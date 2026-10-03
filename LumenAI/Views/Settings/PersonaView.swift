import SwiftUI

/// 世界观 / 记忆 / 指令编辑（World Book / Memory / Instruction Injection）
struct PersonaView: View {
    @ObservedObject private var store = PersonaStore.shared
    @ObservedObject private var settings = SettingsStorage.shared
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var llmService: LLMService

    @State private var extracting = false
    @State private var extractionToast: String?
    @State private var editingWorld: WorldBookEntry?
    @State private var addingWorld = false
    @State private var editingMemory: MemoryEntry?
    @State private var addingMemory = false
    @State private var editingInstruction: InstructionGroup?
    @State private var addingInstruction = false

    var body: some View {
        List {
            // 世界观
            Section {
                Toggle(t("注入世界观设定"), isOn: $settings.settings.worldBookEnabled)
                    .tint(.purple)
                ForEach(store.worldBook) { entry in
                    HStack {
                        Image(systemName: entry.enabled ? "book.fill" : "book")
                            .foregroundStyle(entry.enabled ? .purple : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.subheadline.weight(.medium))
                            Text(entry.content)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { entry.enabled },
                            set: { newValue in
                                if let idx = store.worldBook.firstIndex(where: { $0.id == entry.id }) {
                                    store.worldBook[idx].enabled = newValue
                                }
                            }
                        ))
                        .labelsHidden()
                        // 总开关关掉时条目开关拨了也不会生效：PersonaStore 里是
                        // `if settings.worldBookEnabled { ... }` 直接跳过，条目的 enabled 根本不参与计算。
                        // 让它看起来还能用，用户就会以为设置生效了。这里只禁开关本身，
                        // 点击条目编辑内容仍然可用（改内容不会误导任何人）。
                        .disabled(!settings.settings.worldBookEnabled)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingWorld = entry }
                }
                .onDelete { idx in store.worldBook.remove(atOffsets: idx) }
                if !settings.settings.worldBookEnabled && !store.worldBook.isEmpty {
                    Text("总开关已关闭，上面的条目开关暂不生效。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } header: {
                HStack {
                    Text("世界观设定")
                    Spacer()
                    Button { addingWorld = true } label: {
                        Label(t("添加"), systemImage: "plus").font(.caption)
                    }
                }
            } footer: {
                Text("定义角色、世界规则、背景设定；开启后注入每次对话的系统提示词")
                    .font(.caption2)
            }

            // 记忆
            Section {
                Toggle(t("注入长期记忆"), isOn: $settings.settings.memoryEnabled)
                    .tint(.blue)
                Toggle(t("对话后自动提炼记忆"), isOn: $settings.settings.autoExtractMemory)
                    .tint(.teal)
                Button {
                    Task { await extractMemoriesNow() }
                } label: {
                    HStack {
                        Label(t("从最近对话提炼"), systemImage: "wand.and.stars")
                        Spacer()
                        if extracting {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .disabled(extracting)
                ForEach(store.memory) { entry in
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.blue)
                        Text(entry.content)
                            .font(.subheadline)
                            .lineLimit(2)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { entry.enabled },
                            set: { newValue in
                                if let idx = store.memory.firstIndex(where: { $0.id == entry.id }) {
                                    store.memory[idx].enabled = newValue
                                }
                            }
                        ))
                        .labelsHidden()
                        // 同世界观那条：总开关关闭时条目不参与注入计算，开关就别装成能用。
                        .disabled(!settings.settings.memoryEnabled)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingMemory = entry }
                }
                .onDelete { idx in store.memory.remove(atOffsets: idx) }
                if !settings.settings.memoryEnabled && !store.memory.isEmpty {
                    Text("「注入长期记忆」总开关已关闭，上面的条目开关暂不生效。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } header: {
                HStack {
                    Text("长期记忆")
                    Spacer()
                    Button { addingMemory = true } label: {
                        Label(t("添加"), systemImage: "plus").font(.caption)
                    }
                }
            } footer: {
                Text("跨会话记住的事实（如「用户是 iOS 开发者」）；开启后注入系统提示词。\n「自动提炼」在对话结束后用当前模型把新事实写入记忆（本地/云端均可，失败静默）。")
                    .font(.caption2)
            }

            // 指令
            Section {
                Toggle(t("注入指令"), isOn: $settings.settings.instructionEnabled)
                    .tint(.orange)
                ForEach(store.instructions) { group in
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.subheadline.weight(.medium))
                            Text(group.instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { group.enabled },
                            set: { newValue in
                                if let idx = store.instructions.firstIndex(where: { $0.id == group.id }) {
                                    store.instructions[idx].enabled = newValue
                                }
                            }
                        ))
                        .labelsHidden()
                        // 同 worldview / memory：总开关关闭时条目不参与注入计算。
                        .disabled(!settings.settings.instructionEnabled)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingInstruction = group }
                }
                .onDelete { idx in store.instructions.remove(atOffsets: idx) }
                if !settings.settings.instructionEnabled && !store.instructions.isEmpty {
                    Text("「注入指令」总开关已关闭，上面的条目开关暂不生效。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } header: {
                HStack {
                    Text("指令")
                    Spacer()
                    Button { addingInstruction = true } label: {
                        Label(t("添加"), systemImage: "plus").font(.caption)
                    }
                }
            } footer: {
                Text("分组指令（如「回答尽量简短」「永远用中文」），每次对话强制遵守")
                    .font(.caption2)
            }
        }
        .scrollContentBackground(.hidden)
        .glassScrollEdges()
        .navigationTitle("人格与记忆")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingWorld) { PersonaEntrySheet(kind: .world) }
        .sheet(item: $editingWorld) { e in PersonaEntrySheet(kind: .world, world: e) }
        .sheet(isPresented: $addingMemory) { PersonaEntrySheet(kind: .memory) }
        .sheet(item: $editingMemory) { e in PersonaEntrySheet(kind: .memory, memory: e) }
        .sheet(isPresented: $addingInstruction) { PersonaEntrySheet(kind: .instruction) }
        .sheet(item: $editingInstruction) { e in PersonaEntrySheet(kind: .instruction, instruction: e) }
        .alert("记忆提炼", isPresented: .init(
            get: { extractionToast != nil },
            set: { if !$0 { extractionToast = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(extractionToast ?? "")
        }
    }

    /// 手动触发：用当前对话提炼记忆（立即执行一次 pipeline）
    private func extractMemoriesNow() async {
        guard !extracting else { return }
        extracting = true
        defer { extracting = false }
        let conv = chatStore.currentOrNew
        let added = await store.extractMemories(from: conv.messages, llm: llmService)
        extractionToast = added > 0 ? "\(t("已提炼")) \(added) \(t("条记忆"))" : t("没有新的记忆可提炼")
    }
}

// MARK: - 条目编辑

struct PersonaEntrySheet: View {
    enum Kind { case world, memory, instruction }

    let kind: Kind
    var worldEntry: WorldBookEntry?
    var memoryEntry: MemoryEntry?
    var instructionEntry: InstructionGroup?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PersonaStore.shared

    @State private var name: String
    @State private var content: String

    init(kind: Kind, world: WorldBookEntry? = nil, memory: MemoryEntry? = nil, instruction: InstructionGroup? = nil) {
        self.kind = kind
        if let w = world {
            self.worldEntry = w
            _name = State(initialValue: w.name)
            _content = State(initialValue: w.content)
        } else if let m = memory {
            self.memoryEntry = m
            _name = State(initialValue: "")
            _content = State(initialValue: m.content)
        } else if let i = instruction {
            self.instructionEntry = i
            _name = State(initialValue: i.name)
            _content = State(initialValue: i.instructions)
        } else {
            _name = State(initialValue: "")
            _content = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if kind != .memory {
                    Section("名称") {
                        TextField(kind == .world ? "角色/规则名" : "指令组名", text: $name)
                    }
                }
                Section(kind == .memory ? "内容" : "内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 140)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("保存")) { save() }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (kind != .memory && name.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var titleText: String {
        switch kind {
        case .world: return "世界观设定"
        case .memory: return "长期记忆"
        case .instruction: return "指令"
        }
    }

    private func save() {
        switch kind {
        case .world:
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = worldEntry, let idx = store.worldBook.firstIndex(where: { $0.id == existing.id }) {
                store.worldBook[idx].name = name.trimmingCharacters(in: .whitespaces)
                store.worldBook[idx].content = text
            } else {
                store.worldBook.append(WorldBookEntry(name: name.trimmingCharacters(in: .whitespaces), content: text))
            }
        case .memory:
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = memoryEntry, let idx = store.memory.firstIndex(where: { $0.id == existing.id }) {
                store.memory[idx].content = text
            } else {
                store.memory.append(MemoryEntry(content: text))
            }
        case .instruction:
            if let existing = instructionEntry, let idx = store.instructions.firstIndex(where: { $0.id == existing.id }) {
                store.instructions[idx].name = name.trimmingCharacters(in: .whitespaces)
                store.instructions[idx].instructions = content
            } else {
                store.instructions.append(InstructionGroup(name: name.trimmingCharacters(in: .whitespaces), instructions: content))
            }
        }
        dismiss()
    }
}
