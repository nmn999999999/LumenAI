import SwiftUI

/// 技能管理：已安装技能 / 市场 / 分类浏览
struct SkillsView: View {
    @ObservedObject private var skillStore = SkillStore.shared
    @State private var installingID: String?
    @State private var toast: String?
    @State private var showImporter = false
    @State private var importError: String?
    @State private var pendingDelete: SkillStore.InstalledSkill?
    @State private var searchText = ""
    @State private var selectedCategory: SkillCategory? = nil
    @State private var showingCreateSheet = false
    @State private var showingMarket = false

    var body: some View {
        NavigationStack {
            List {
                // 搜索和筛选行
                filterToolbar

                // 已安装技能
                installedSection

                // 市场推荐
                if !showingMarket {
                    remoteSection
                }
            }
            .scrollContentBackground(.hidden)
            .glassScrollEdges()
            .navigationTitle("技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingMarket = true
                    } label: {
                        Label("市场", systemImage: "square.grid.2x2")
                    }
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索技能")
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                
                if ext == "md" {
                    try skillStore.importSkillMarkdown(data: data)
                    toast("从 SKILL.md 导入成功")
                } else {
                    try skillStore.importBundle(data: data)
                    toast("导入成功")
                }
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("操作失败", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task { await skillStore.checkForUpdates() }
        .toast($toast)
        .confirmationDialog(
            "删除这个技能？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { skill in
            Button("删除", role: .destructive) {
                skillStore.remove(skill)
                pendingDelete = nil
                toast("已删除技能")
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { skill in
            Text("「\(skill.manifest.name)」及其所有设置都会被删除，无法撤销。")
        }
        .sheet(isPresented: $showingCreateSheet) {
            SkillCreationView()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 筛选工具栏

    private var filterToolbar: some View {
        let skills = filteredSkills()
        let categoryCount = SkillCategory.allCases.count
        return Group {
            if skills.isEmpty {
                Text("无匹配技能")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            // 分类筛选
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedCategory = nil
                    } label: {
                        Text("全部")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedCategory == nil ? Color.accentColor : Color.secondary.opacity(0.2), in: Capsule())
                            .foregroundStyle(selectedCategory == nil ? .white : .primary)
                    }

                    ForEach(SkillCategory.allCases) { category in
                        Button {
                            selectedCategory = selectedCategory == category ? nil : category
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: category.systemImage)
                                    .font(.caption2)
                                Text(category.displayName)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background((selectedCategory == category ? Color.accentColor : Color.secondary.opacity(0.2)), in: Capsule())
                            .foregroundStyle(selectedCategory == category ? .white : .primary)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 已安装技能

    private var installedSection: some View {
        Section {
            FilteredSkillsView(
                skills: filteredInstalledSkills(),
                showingDelete: { skill in
                    pendingDelete = skill
                }
            )
        } header: {
            Text("我的技能")
        }
    }

    private func filteredInstalledSkills() -> [SkillStore.InstalledSkill] {
        skillStore.skills
            .filter { $0.manifest.isEnabled }
            .filter { skill in
                let matchesSearch = searchText.isEmpty || 
                    skill.manifest.name.localizedCaseInsensitiveContains(searchText) ||
                    skill.manifest.description.localizedCaseInsensitiveContains(searchText) ||
                    skill.manifest.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                let matchesCategory = selectedCategory == nil || skill.manifest.category == selectedCategory
                return matchesSearch && matchesCategory
            }
    }

    private func filteredSkills() -> [SkillStore.InstalledSkill] {
        filteredInstalledSkills()
    }

    // MARK: - 远程技能

    private var remoteSection: some View {
        Section {
            if skillStore.remoteIndex.isEmpty {
                Text("点击右上角刷新获取可用技能。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(skillStore.updateStates()) { update in
                SkillMarketRow(update: update, installingID: installingID) {
                    installOrUpdate(update)
                }
            }
        } header: {
            Text("技能市场")
        } footer: {
            Text("技能 = 可复用的提示词模板，支持参数化、分类和工作流。")
                .font(.caption2)
        }
    }

    private func installOrUpdate(_ update: SkillUpdate) {
        installingID = update.id
        Task {
            defer { installingID = nil }
            let error = await skillStore.installOrUpdate(update.entry)
            if let error {
                importError = error
            } else {
                toast(update.installedVersion == nil ? "安装成功" : "已更新到 v\(update.entry.version)")
            }
        }
    }

    private func toast(_ message: String) {
        toast = message
    }
}

// MARK: - 已安装技能视图

struct FilteredSkillsView: View {
    let skills: [SkillStore.InstalledSkill]
    let showingDelete: (SkillStore.InstalledSkill) -> Void

    var body: some View {
        if skills.isEmpty {
            Text("暂无技能。可通过市场安装或新建。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            ForEach(skills) { skill in
                NavigationLink {
                    SkillDetailView(skill: skill)
                } label: {
                    HStack(spacing: 12) {
                        // 图标
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: skill.manifest.icon ?? skill.manifest.category.systemImage)
                                    .foregroundStyle(Color.accentColor)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(skill.manifest.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if skill.isBuiltIn {
                                    Text("内置")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(skill.manifest.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                Text(skill.manifest.category.displayName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                if skill.manifest.useCount > 0 {
                                    Text("已使用 \(skill.manifest.useCount) 次")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button(role: .destructive) {
                            showingDelete(skill)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            // 复制
                            Task {
                                do {
                                    try SkillStore.shared.duplicate(skill, newName: "\(skill.manifest.name) 副本")
                                    // 简单提示
                                } catch {
                                    print("复制失败: \(error)")
                                }
                            }
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 技能市场行

struct SkillMarketRow: View {
    let update: SkillUpdate
    let installingID: String?
    let action: () -> Void

    @ObservedObject private var skillStore = SkillStore.shared

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(update.entry.name)
                            .font(.subheadline.weight(.semibold))
                        if skillStore.isGraySkill(update.entry) {
                            Text("灰度")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(update.entry.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(installedText(update))
                        .font(.caption2)
                        .foregroundStyle(update.hasUpdate ? .orange : .secondary)
                }
                Spacer()
                if installingID == update.id {
                    ProgressView().controlSize(.mini)
                } else if update.installedVersion == nil {
                    Label("安装", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                } else if update.hasUpdate {
                    Label("更新", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Label("已安装", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(installingID != nil || !update.hasUpdate && update.installedVersion != nil)
    }

    private func installedText(_ update: SkillUpdate) -> String {
        if let v = update.installedVersion {
            return update.hasUpdate ? "已安装 v\(v) → 可更新 v\(update.entry.version)" : "已安装 v\(v)（最新）"
        }
        return "v\(update.entry.version) · 未安装"
    }
}
