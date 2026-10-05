import SwiftUI

/// 技能市场视图
struct SkillsMarketView: View {
    @ObservedObject private var skillStore = SkillStore.shared
    @State private var searchText = ""
    @State private var selectedCategory: SkillCategory? = nil
    @State private var selectedTab = 0
    @State private var installingID: String?
    @State private var toast: String?
    @State private var showingInstalledTab = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部标签选择器
                Picker("分类", selection: $selectedTab) {
                    Text("推荐").tag(0)
                    Text("分类浏览").tag(1)
                    Text("我的技能").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ScrollView {
                    if selectedTab == 0 {
                        recommendedSection
                    } else if selectedTab == 1 {
                        categorySection
                    } else {
                        installedSection
                    }
                }
            }
            .navigationTitle("技能市场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") {
                        Task { await skillStore.checkForUpdates() }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索技能")
        .toast($toast)
        .task {
            if skillStore.remoteIndex.isEmpty {
                await skillStore.checkForUpdates()
            }
        }
    }

    // MARK: - 推荐区

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("精选技能")
                    .font(.title2.weight(.bold))
                Text("由社区精选的高质量技能")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            let recommended = filteredUpdates().prefix(6)
            if recommended.isEmpty {
                EmptyStateView(
                    title: "暂无推荐技能",
                    description: "点击刷新获取最新技能",
                    icon: "star"
                )
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(Array(recommended), id: \.id) { update in
                        MarketSkillCard(update: update, installingID: installingID) {
                            installOrUpdate(update)
                        }
                    }
                }
                .padding(.horizontal)
            }

            // 查看全部
            if !filteredUpdates().isEmpty {
                NavigationLink {
                    AllSkillsMarketView(searchText: searchText, selectedCategory: selectedCategory)
                } label: {
                    Text("查看全部技能")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
        }
        .padding(.vertical)
    }

    // MARK: - 分类浏览

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 分类图标网格
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
                ForEach(SkillCategory.allCases) { category in
                    CategoryCard(category: category) {
                        selectedCategory = selectedCategory == category ? nil : category
                    }
                }
            }
            .padding(.horizontal)

            if let category = selectedCategory {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(category.displayName)技能")
                        .font(.headline)
                        .padding(.horizontal)

                    let categorySkills = filteredUpdates().filter { $0.entry.category == category }
                    if categorySkills.isEmpty {
                        Text("该分类暂无技能")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        ForEach(categorySkills, id: \.id) { update in
                            MarketSkillRow(update: update, installingID: installingID) {
                                installOrUpdate(update)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .padding(.vertical)
    }

    // MARK: - 我的技能

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("我的技能")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("\(skillStore.skills.filter { $0.isEnabled }.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            let installed = skillStore.skills.filter { skill in
                let matchesSearch = searchText.isEmpty ||
                    skill.manifest.name.localizedCaseInsensitiveContains(searchText) ||
                    skill.manifest.description.localizedCaseInsensitiveContains(searchText)
                return matchesSearch
            }

            if installed.isEmpty {
                EmptyStateView(
                    title: "暂无技能",
                    description: "从市场安装技能或新建自己的技能",
                    icon: "wand.and.stars"
                )
            } else {
                ForEach(installed) { skill in
                    InstalledSkillRow(skill: skill)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private func filteredUpdates() -> [SkillUpdate] {
        let updates = skillStore.updateStates()
        return updates.filter { update in
            let matchesSearch = searchText.isEmpty ||
                update.entry.name.localizedCaseInsensitiveContains(searchText) ||
                update.entry.description.localizedCaseInsensitiveContains(searchText) ||
                update.entry.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesCategory = selectedCategory == nil || update.entry.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    private func installOrUpdate(_ update: SkillUpdate) {
        installingID = update.id
        Task {
            defer { installingID = nil }
            let error = await skillStore.installOrUpdate(update.entry)
            if let error {
                toast = "安装失败: \(error)"
            } else {
                toast = update.installedVersion == nil ? "安装成功" : "已更新到 v\(update.entry.version)"
            }
        }
    }
}

// MARK: - 技能卡片

struct MarketSkillCard: View {
    let update: SkillUpdate
    let installingID: String?
    let action: () -> Void

    @ObservedObject private var skillStore = SkillStore.shared

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: update.entry.icon ?? update.entry.category.systemImage)
                                .foregroundStyle(Color.accentColor)
                        )
                    Spacer()
                    if installingID == update.id {
                        ProgressView().scaleEffect(0.7)
                    } else if update.installedVersion != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Text(update.entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(update.entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack {
                    Text(update.entry.category.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    Text("v\(update.entry.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(installingID != nil)
    }
}

struct MarketSkillRow: View {
    let update: SkillUpdate
    let installingID: String?
    let action: () -> Void

    @ObservedObject private var skillStore = SkillStore.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: update.entry.icon ?? update.entry.category.systemImage)
                            .foregroundStyle(Color.accentColor)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(update.entry.name)
                        .font(.subheadline.weight(.semibold))
                    Text(update.entry.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack {
                        Text(update.entry.category.displayName)
                            .font(.caption2)
                        Spacer()
                        Text("v\(update.entry.version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if installingID == update.id {
                    ProgressView().controlSize(.mini)
                } else if update.installedVersion == nil {
                    Label("安装", systemImage: "arrow.down")
                        .font(.caption)
                } else if update.hasUpdate {
                    Label("更新", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("已安装", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(installingID != nil)
    }
}

struct CategoryCard: View {
    let category: SkillCategory
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                Text(category.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct InstalledSkillRow: View {
    let skill: SkillStore.InstalledSkill

    var body: some View {
        NavigationLink {
            SkillDetailView(skill: skill)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: skill.manifest.icon ?? skill.manifest.category.systemImage)
                            .foregroundStyle(Color.accentColor)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.manifest.name)
                        .font(.subheadline.weight(.semibold))
                    Text(skill.manifest.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("v\(skill.manifest.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let description: String
    let icon: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 所有技能视图

struct AllSkillsMarketView: View {
    let searchText: String
    let selectedCategory: SkillCategory?
    @ObservedObject private var skillStore = SkillStore.shared
    @State private var installingID: String?

    var body: some View {
        NavigationView {
            List {
                ForEach(filteredUpdates(), id: \.id) { update in
                    MarketSkillRow(update: update, installingID: installingID) {
                        installOrUpdate(update)
                    }
                }
            }
            .navigationTitle("所有技能")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func filteredUpdates() -> [SkillUpdate] {
        let updates = skillStore.updateStates()
        return updates.filter { update in
            let matchesSearch = searchText.isEmpty ||
                update.entry.name.localizedCaseInsensitiveContains(searchText) ||
                update.entry.description.localizedCaseInsensitiveContains(searchText)
            let matchesCategory = selectedCategory == nil || update.entry.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    private func installOrUpdate(_ update: SkillUpdate) {
        installingID = update.id
        Task {
            defer { installingID = nil }
            _ = await skillStore.installOrUpdate(update.entry)
        }
    }
}
