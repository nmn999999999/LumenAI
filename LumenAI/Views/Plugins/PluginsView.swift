import SwiftUI

/// 模块（JS 插件）管理：已安装模块 / 可更新模块 / 检查更新
/// 基础包（IPA）不动，模块在 App 内单独更新。
struct PluginsView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var installingID: String?
    @State private var toast: String?
    @State private var showImporter = false
    @State private var importError: String?
    /// 待确认删除的模块。删除会连模块自己的 storage.json 一起清掉，不能一击即删。
    @State private var pendingDelete: PluginManager.InstalledModule?

    var body: some View {
        List {
            installedSection
            remoteSection
        }
        .scrollContentBackground(.hidden)
        .glassScrollEdges()
        .navigationTitle("模块 / JS 插件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task { await pluginManager.checkForUpdates() }
                } label: {
                    if pluginManager.isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(pluginManager.isChecking)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                let warning = try pluginManager.importBundle(data: data)
                toast(warning ?? "导入成功")
            } catch {
                importError = error.localizedDescription
            }
        }
        // 标题不能写死「导入失败」：安装/更新失败也走这个 alert，
        // 说成「导入失败」会让用户不知道是刚才哪一步出的问题。
        .alert("操作失败", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task { await pluginManager.checkForUpdates() }
        // 轻提示统一走 `.toast`：样式、动效、自动消失都只定义一次
        //（这三处原来各抄一份，设置页那份还漏了自动消失）。
        .toast($toast)
        .alert("模块更新", isPresented: .init(
            get: { pluginManager.lastCheckError != nil },
            set: { if !$0 { pluginManager.lastCheckError = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(pluginManager.lastCheckError ?? "")
        }

        // 删除模块的二次确认。放在 body 而不是 installedSection：那个 Section 的表达式
        // 本来就很大（ForEach + NavigationLink + 多行文本），再挂一个 presenting: 的
        // dialog 会让编译器报 "unable to type-check this expression in reasonable time"。
        .confirmationDialog(
            "删除这个模块？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { module in
            Button("删除", role: .destructive) {
                pluginManager.remove(module)
                pendingDelete = nil
                toast("已删除模块")
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { module in
            Text("「\(module.manifest.name)」及其本地配置与存储数据（storage.json）都会被删除，无法撤销。")
        }
    }

    /// 已安装模块区的说明文案。抽成常量是为了不让 Section 的类型检查超时（见上文）。
    private static let deleteFootnote = "模块存放于本机 Documents/Modules。删除模块会连它的本地配置与存储数据（storage.json）一起删除，且无法撤销；对话数据不受影响。删除后 Agent 工具目录立即更新。"

    // MARK: - 已安装

    private var installedSection: some View {
        Section {
            if pluginManager.modules.isEmpty {
                Text("未安装任何模块。下方列表可一键安装免费模块。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(pluginManager.modules) { module in
                NavigationLink {
                    ModuleDetailView(module: module)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(module.manifest.name)
                                .font(.subheadline.weight(.semibold))
                            Text(module.manifest.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("v\(module.manifest.version) · \(module.toolCount) 个工具"
                                 + (module.engine.requiresApproval() ? " · 需授权" : ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = module
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("已安装")
        } footer: {
            // 原来这句只说「不影响对话数据」，会让人以为删除是安全的 ——
            // 实际 `pluginManager.remove` 删的是整个模块目录，模块自己的
            // storage.json（在「模块设置」里配的开关/密钥等）会一起消失。说明必须写全。
            // 文案抽成常量还有一个原因：内联进来会让这个 Section 的类型检查超时。
            Text(Self.deleteFootnote)
                .font(.caption2)
        }
    }

    // MARK: - 远程模块

    private var remoteSection: some View {
        Section {
            if pluginManager.remoteIndex.isEmpty {
                Text(pluginManager.lastCheckError == nil ? "点击右上角「检查更新」获取可用模块。" : "索引拉取失败，请检查网络后重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(pluginManager.updateStates()) { update in
                Button {
                    installOrUpdate(update)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(update.entry.name)
                                    .font(.subheadline.weight(.semibold))
                                if pluginManager.isGrayModule(update.entry) {
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
                            Label("已是最新", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(installingID != nil || !update.hasUpdate && update.installedVersion != nil)
            }
        } header: {
            Text("可安装 / 可更新（免费）")
        } footer: {
            Text("模块 = manifest.json + tools.js（JavaScriptCore 纯计算沙箱），独立版本独立更新；基础包不需要重装。")
                .font(.caption2)
        }
    }

    private func installedText(_ update: ModuleUpdate) -> String {
        if let v = update.installedVersion {
            return update.hasUpdate ? "已安装 v\(v) → 可更新 v\(update.entry.version)" : "已安装 v\(v)（最新）"
        }
        return "v\(update.entry.version) · 未安装"
    }

    private func installOrUpdate(_ update: ModuleUpdate) {
        installingID = update.id
        Task {
            defer { installingID = nil }
            let error = await pluginManager.installOrUpdate(update.entry)
            // 原来这里直接给 @State toast 赋值，绕过了下面的 toast() 助手 ——
            // 而自动清除逻辑只在那个助手里，于是安装完成的提示会一直挂在屏幕上，
            // 直到用户离开这个页面。失败也应该走既有的「导入失败」alert，
            // 而不是显示成一个同样样式的成功胶囊（用户会把失败读成成功）。
            if let error {
                importError = error
            } else {
                toast(update.installedVersion == nil ? "安装成功" : "已更新到 v\(update.entry.version)")
                // 成功但"有保留"的信息（未经验证的模块 / 工具名冲突）随后补一条提示。
                // 不用 alert：模块已经装好了，弹一个需要用户点确认的报错框会把
                // "装成功了吗"这件事本身变得含糊。toast 会互相覆盖，所以后一条
                // 就是最需要用户看到的那条 —— 而"未经验证"比"安装成功"重要得多。
                if let notice = pluginManager.installNotice {
                    toast(notice)
                }
            }
        }
    }

    /// 显示一条轻提示。自动消失与动画都由 `ToastModifier` 负责，
    /// 这里只赋值 —— 三处的显示行为因此必然一致。
    private func toast(_ message: String) {
        toast = message
    }
}
