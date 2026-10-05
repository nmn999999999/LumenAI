import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

/// 服务页：Provider 管理 / 自定义助手 / 数据备份与 QR 分享
/// （Provider 管理、自定义助手、QR 分享、数据备份）
struct ProvidersView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @ObservedObject private var providerStore = ProviderStore.shared
    @ObservedObject private var assistantStore = AssistantStore.shared

    @State private var editingProvider: ChatProvider?
    @State private var addingProvider = false
    @State private var editingAssistant: AIAssistant?
    @State private var addingAssistant = false
    @State private var sharingProvider: ChatProvider?
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var showDocumentPicker = false
    @State private var pendingRestore: BackupService.BackupPackage?
    @State private var showRestoreConfirm = false
    @State private var showImportPhotoPicker = false
    @State private var importPhotoItems: [PhotosPickerItem] = []
    @State private var toastMessage: String?
    @State private var testingProviderID: UUID?
    /// 删除/重置的二次确认。
    /// 加这些的原因：删除 Provider 会连多 Key + 自定义请求头一起丢掉、无法撤销，
    /// 「重置内置」会清掉内置项上填的密钥 —— 而同一个文件里「恢复备份」早就有确认框了。
    /// 危险程度不一致比没有确认更容易误导：用户会以为这个 App 的删除都是安全的。
    @State private var pendingDeleteProvider: ChatProvider?
    @State private var pendingDeleteAssistant: AIAssistant?
    @State private var pendingDeleteMCPServer: MCPServer?
    @State private var showResetBuiltInsConfirm = false
    /// MCP
    @ObservedObject private var mcpService = MCPService.shared
    @State private var editingMCPServer: MCPServer?
    @State private var addingMCPServer = false
    @State private var callingTool: (server: MCPServer, tool: MCPTool)?

    var body: some View {
        NavigationStack {
            List {
                providerSection
                assistantSection
                mcpSection
                pluginSection
                backupSection
                aboutSection
            }
            // 玻璃化：列表不带自己的不透明底色，透出窗口渐变背景；
            // 滚动到边缘显示玻璃高光。
            .scrollContentBackground(.hidden)
            .glassScrollEdges()
            .navigationTitle(t("服务"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        addingProvider = true
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel(t("添加 Provider"))
                    }
                    Menu {
                        Button(t("重置内置"), systemImage: "arrow.counterclockwise") {
                            showResetBuiltInsConfirm = true
                        }
                        // 原名「扫码导入」名不符实：全项目没有相机，只有相册选图，
                        // 用户以为能对着屏幕扫，实际得先截图存相册。
                        Button(t("从相册导入二维码"), systemImage: "photo.on.rectangle") {
                            showImportPhotoPicker = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel(t("更多"))
                    }
                }
            }
            .sheet(isPresented: $addingProvider) {
                ProviderEditSheet()
            }
            .sheet(item: $editingProvider) { p in
                ProviderEditSheet(existing: p)
            }
            .sheet(isPresented: $addingAssistant) {
                AssistantEditSheet()
            }
            .sheet(item: $editingAssistant) { a in
                AssistantEditSheet(existing: a)
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
            .sheet(item: $sharingProvider) { p in
                ProviderQRShareSheet(provider: p)
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPicker { data in
                    handleRestore(data: data)
                }
            }
            .sheet(isPresented: $showImportPhotoPicker) {
                importPhotoPicker
            }
            .confirmationDialog(
                t("恢复将覆盖当前数据，确认继续？"),
                isPresented: $showRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button(t("确认恢复"), role: .destructive) {
                    if let pkg = pendingRestore {
                        BackupService.restore(pkg, chatStore: chatStore)
                        toast(t("恢复成功"))
                    }
                }
                Button(t("取消"), role: .cancel) {}
            }
            .confirmationDialog(
                t("重置内置 Provider？"),
                isPresented: $showResetBuiltInsConfirm,
                titleVisibility: .visible
            ) {
                Button(t("重置内置"), role: .destructive) {
                    providerStore.resetBuiltIns()
                    toast(t("已重置内置 Provider"))
                }
                Button(t("取消"), role: .cancel) {}
            } message: {
                Text(t("内置项上填写的 API Key 与自定义请求头会被清空，无法撤销。你自己添加的 Provider 不受影响。"))
            }
            .confirmationDialog(
                t("删除 Provider？"),
                isPresented: Binding(
                    get: { pendingDeleteProvider != nil },
                    set: { if !$0 { pendingDeleteProvider = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteProvider
            ) { p in
                Button(t("删除"), role: .destructive) {
                    providerStore.delete(p)
                    pendingDeleteProvider = nil
                    toast(t("已删除"))
                }
                Button(t("取消"), role: .cancel) { pendingDeleteProvider = nil }
            } message: { p in
                Text("「\(p.name)」的 API Key、自定义请求头与模型列表会一起删除，无法撤销。")
            }
            .confirmationDialog(
                t("删除助手？"),
                isPresented: Binding(
                    get: { pendingDeleteAssistant != nil },
                    set: { if !$0 { pendingDeleteAssistant = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteAssistant
            ) { a in
                Button(t("删除"), role: .destructive) {
                    assistantStore.delete(a)
                    pendingDeleteAssistant = nil
                    toast(t("已删除"))
                }
                Button(t("取消"), role: .cancel) { pendingDeleteAssistant = nil }
            } message: { a in
                Text("助手「\(a.name)」及其自定义提示词会被删除，无法撤销。")
            }
            .confirmationDialog(
                t("删除 MCP 服务器？"),
                isPresented: Binding(
                    get: { pendingDeleteMCPServer != nil },
                    set: { if !$0 { pendingDeleteMCPServer = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteMCPServer
            ) { s in
                Button(t("删除"), role: .destructive) {
                    mcpService.delete(s)
                    pendingDeleteMCPServer = nil
                    toast(t("已删除"))
                }
                Button(t("取消"), role: .cancel) { pendingDeleteMCPServer = nil }
            } message: { s in
                Text("「\(s.name)」的地址与请求头会被删除，其工具将从 Agent 工具目录中移除。")
            }
            // 轻提示统一走 `.toast`（原来这里是三份复制粘贴里的一份）
            .toast($toastMessage)
        }
    }

    // MARK: - Provider 列表

    private var providerSection: some View {
        Section {
            ForEach(providerStore.providers) { provider in
                ProviderRow(
                    provider: provider,
                    isSelected: providerStore.currentProviderID == provider.id,
                    isTesting: testingProviderID == provider.id,
                    onSelect: {
                        // 停用的 Provider 不能被选成「当前」：否则行上同时出现 OFF 徽标和勾选，
                        // 而 currentProvider 要求 enabled，实际生效的是本地模型 ——
                        // 界面说切过去了，行为说没切。
                        guard provider.enabled else {
                            toast(t("该 Provider 已停用，请先启用"))
                            return
                        }
                        let model = providerStore.currentModel
                        let keepModel = provider.models.contains(model) ? model : (provider.models.first ?? "")
                        providerStore.select(providerID: provider.id, model: keepModel)
                    },
                    onEdit: { editingProvider = provider },
                    onShare: { sharingProvider = provider },
                    onTest: { testProvider(provider) },
                    onDelete: { pendingDeleteProvider = provider }
                )
            }
        } header: {
            Text(t("Provider 管理"))
        } footer: {
            Text("选中即切换聊天使用的云端模型；支持多 Key 自动轮换、自定义请求头与请求体")
                .font(.caption2)
        }
    }

    // MARK: - 助手列表

    private var assistantSection: some View {
        Section {
            ForEach(assistantStore.assistants) { assistant in
                Button {
                    assistantStore.currentAssistantID = assistant.id
                } label: {
                    HStack(spacing: 12) {
                        Text(assistant.emoji.isEmpty ? "🤖" : assistant.emoji)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(assistant.name)
                                .font(.subheadline.weight(.medium))
                            Text(systemPromptPreview(assistant.systemPrompt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if assistantStore.currentAssistantID == assistant.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(t("删除"), role: .destructive) {
                        pendingDeleteAssistant = assistant
                    }
                    Button(t("编辑")) {
                        editingAssistant = assistant
                    }
                    .tint(.blue)
                }
            }
        } header: {
            HStack {
                Text(t("自定义助手"))
                Spacer()
                Button {
                    addingAssistant = true
                } label: {
                    Label(t("添加"), systemImage: "plus")
                        .font(.caption)
                }
            }
        } footer: {
            Text("聊天时助手的系统提示词将自动注入，并支持 {model} {date} 等变量")
                .font(.caption2)
        }
    }

    // MARK: - MCP 工具

    private var mcpSection: some View {
        Section {
            ForEach(mcpService.servers) { server in
                MCPServerRow(
                    server: server,
                    isConnecting: mcpService.connectingID == server.id,
                    onEdit: { editingMCPServer = server },
                    onConnect: {
                        Task { await mcpService.connect(server) }
                    },
                    onDisconnect: { mcpService.disconnect(server) },
                    onDelete: { pendingDeleteMCPServer = server },
                    onCallTool: { tool in
                        callingTool = (server, tool)
                    }
                )
            }
            if mcpService.servers.isEmpty {
                Text("未添加 MCP 服务器。连接后工具自动加入 Agent 工具目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 免费公共 MCP 服务预设（一键添加 + 连接）
            Text("🎁 免费公共 MCP（免密钥）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(MCPService.freePresets) { preset in
                Button {
                    let server = mcpService.addPreset(preset)
                    Task { await mcpService.connect(server) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.subheadline.weight(.medium))
                            Text(preset.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("MCP 工具")
                Spacer()
                Button {
                    addingMCPServer = true
                } label: {
                    Label(t("添加"), systemImage: "plus")
                        .font(.caption)
                }
            }
        } footer: {
            Text("Model Context Protocol：连接外部 MCP 服务器，把它的工具接入 Agent 对话循环（OpenAI/Gemini/Claude/本地模型均可用）")
                .font(.caption2)
        }
        .sheet(isPresented: $addingMCPServer) {
            MCPServerEditSheet()
        }
        .sheet(item: $editingMCPServer) { server in
            MCPServerEditSheet(existing: server)
        }
        .sheet(item: Binding(
            get: { callingTool.map { MCPToolCallKey(server: $0.server, tool: $0.tool) } },
            set: { if $0 == nil { callingTool = nil } }
        )) { key in
            MCPToolCallSheet(server: key.server, tool: key.tool)
        }
    }

    // MARK: - 模块（JS 插件）

    private var pluginSection: some View {
        Section {
            NavigationLink {
                PluginsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模块 / JS 插件")
                            .font(.subheadline.weight(.semibold))
                        Text("安装独立更新的工具模块（App 内更新，基础包不动）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if PluginManager.shared.updatableCount > 0 {
                        Text("\(PluginManager.shared.updatableCount) 可更新")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            NavigationLink {
                SkillsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("技能")
                            .font(.subheadline.weight(.semibold))
                        Text("可复用提示词模板，参数化工作流，一键生成")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if SkillStore.shared.updatableCount > 0 {
                        Text("\(SkillStore.shared.updatableCount) 可更新")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.15), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
            }
        } header: {
            Text("扩展")
        }
    }

    // MARK: - 备份

    private var backupSection: some View {
        Section {
            Button {
                if let url = BackupService.makeBackupFile(chatStore: chatStore) {
                    shareItems = [url]
                    showShareSheet = true
                }
            } label: {
                Label(t("导出备份"), systemImage: "square.and.arrow.up")
            }

            Button {
                showDocumentPicker = true
            } label: {
                Label(t("恢复备份"), systemImage: "arrow.down.doc")
            }

            Button {
                if let json = ProviderShareCodec.export(providerStore.providers) {
                    shareItems = [json]
                    showShareSheet = true
                }
            } label: {
                Label(t("分享 Provider 配置"), systemImage: "qrcode")
            }
        } header: {
            Text(t("数据备份"))
        } footer: {
            Text(t("导出备份将包含全部会话、Provider 与助手配置"))
                .font(.caption2)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text(t("关于"))
                Spacer()
                Text("LumenAI")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 相册扫码导入

    private var importPhotoPicker: some View {
        VStack(spacing: 14) {
            Text(t("从相册选择二维码图片导入 Provider 配置"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            PhotosPicker(selection: $importPhotoItems, maxSelectionCount: 1, matching: .images) {
                Label(t("扫码导入"), systemImage: "qrcode.viewfinder")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.tint, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .onChange(of: importPhotoItems) { _, items in
                Task {
                    await importFromPhoto(items)
                }
            }
            Spacer()
        }
        .presentationDetents([.medium])
    }

    private func importFromPhoto(_ items: [PhotosPickerItem]) async {
        defer {
            importPhotoItems = []
            showImportPhotoPicker = false
        }
        guard let item = items.first,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return }
        guard let text = QRCodeGenerator.decode(image: image) else {
            toast(t("未识别到二维码"))
            return
        }
        let providers = ProviderShareCodec.parseImport(text)
        guard !providers.isEmpty else {
            toast(t("未识别到二维码"))
            return
        }
        for p in providers {
            providerStore.upsert(p)
        }
        toast("\(t("导入成功")) (\(providers.count))")
    }

    // MARK: - 测试连接

    private func testProvider(_ provider: ChatProvider) {
        testingProviderID = provider.id
        let probe = CloudMessage(role: .user, content: "ping")
        Task {
            defer { testingProviderID = nil }
            do {
                let model = provider.models.first ?? "gpt-4o-mini"
                let reply = try await CloudChatClient.complete(
                    provider: provider,
                    model: model,
                    messages: [probe],
                    temperature: 0,
                    maxTokens: 8
                )
                toast("\(t("连接成功")) · \(reply.prefix(40))")
            } catch {
                toast("\(t("连接失败")): \(error.localizedDescription.prefix(80))")
            }
        }
    }

    private func handleRestore(data: Data) {
        do {
            let pkg = try BackupService.parseBackup(data: data)
            pendingRestore = pkg
            showRestoreConfirm = true
        } catch {
            toast("\(t("恢复失败")): \(error.localizedDescription)")
        }
    }

    private func systemPromptPreview(_ prompt: String) -> String {
        let s = prompt.replacingOccurrences(of: "\n", with: " ")
        return s.count > 60 ? String(s.prefix(60)) + "…" : s
    }

    /// 显示一条轻提示。自动消失与动画都由 `ToastModifier` 负责。
    private func toast(_ message: String) {
        toastMessage = message
    }
}

// MARK: - Provider 行

private struct ProviderRow: View {
    let provider: ChatProvider
    let isSelected: Bool
    let isTesting: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onShare: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.subheadline.weight(.semibold))
                        if provider.isBuiltIn {
                            Text(t("内置"))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                                .foregroundStyle(.secondary)
                        }
                        if !provider.enabled {
                            Text("OFF")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(provider.cleanBaseURL.isEmpty ? provider.type.displayName : provider.cleanBaseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(keyStatus)
                        .font(.caption2)
                        .foregroundStyle(provider.hasKey ? .green : .orange)
                }
                Spacer()

                if isTesting {
                    ProgressView()
                        .controlSize(.mini)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(t("编辑"), systemImage: "pencil") { onEdit() }
            Button(t("测试连接"), systemImage: "bolt") { onTest() }
            Button(t("导出配置"), systemImage: "qrcode") { onShare() }
            if !provider.isBuiltIn {
                Divider()
                Button(t("删除"), systemImage: "trash", role: .destructive) { onDelete() }
            }
        }
    }

    private var iconName: String {
        switch provider.type {
        case .openAI: return "sparkles"
        case .openAICompatible: return "server.rack"
        case .gemini: return "star.circle"
        case .claude: return "leaf"
        }
    }

    private var keyStatus: String {
        let n = provider.apiKeys.filter { !$0.isEmpty }.count
        if n > 0 {
            return t("已配置 N 个密钥").replacingOccurrences(of: "N", with: "\(n)")
        }
        return t("未配置密钥")
    }
}

// MARK: - Provider 二维码分享

struct ProviderQRShareSheet: View {
    let provider: ChatProvider
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            Text(t("配置二维码"))
                .font(.headline)
                .padding(.top, 24)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 16))
            } else {
                ProgressView()
                    .frame(height: 260)
            }

            Text(provider.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                if let json = ProviderShareCodec.export([provider]) {
                    UIPasteboard.general.string = json
                    dismiss()
                }
            } label: {
                Label(t("复制配置文本"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .presentationDetents([.medium])
        .onAppear {
            if let json = ProviderShareCodec.export([provider]) {
                qrImage = QRCodeGenerator.generate(from: json)
            }
        }
    }
}

// MARK: - MCP 服务器行

private struct MCPServerRow: View {
    let server: MCPServer
    let isConnecting: Bool
    let onEdit: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onDelete: () -> Void
    let onCallTool: (MCPTool) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: server.connected ? "link.circle.fill" : "link.circle")
                        .font(.title3)
                        .foregroundStyle(server.connected ? .green : .secondary)
                        .frame(width: 34, height: 34)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name)
                            .font(.subheadline.weight(.semibold))
                        Text(server.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(statusColor)
                    }
                    Spacer()
                    if isConnecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if server.tools.isEmpty {
                        Text(server.connected ? "该服务器没有暴露工具" : "未连接，无工具列表")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(server.tools) { tool in
                        HStack(spacing: 8) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(.tint)
                            Text(tool.name)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Button(t("调用")) {
                                onCallTool(tool)
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.leading, 46)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .contextMenu {
            Button(t("编辑"), systemImage: "pencil") { onEdit() }
            if server.connected {
                Button(t("断开"), systemImage: "xmark.circle") { onDisconnect() }
            } else {
                Button(t("连接"), systemImage: "link") { onConnect() }
            }
            Divider()
            Button(t("删除"), systemImage: "trash", role: .destructive) { onDelete() }
        }
    }

    /// 三态：已连接 / 正常断开 / 真错误。
    ///
    /// 为什么要分三态：`MCPService` 那边刚把「状态」和「错误」拆开
    /// （`statusNote` 承载"已断开""已连接但没有工具"这类**正常状态**，
    /// `lastError` 只承载真正的失败），而这里原来只看 `connected/lastError`，
    /// 于是用户主动点「断开」会被显示成橙色故障。
    /// 最后那句 `t("未配置密钥").replacingOccurrences(of: "密钥", with: "连接")` 也是错的：
    /// 英文词条是 "No API key"，不含「密钥」，替换不生效 —— 英文界面下会显示
    /// 「No API key」这种与 MCP 无关的文案（MCP 没有密钥这个概念）。已改为直接词条。
    private var statusText: String {
        if isConnecting { return t("正在测试…") }
        if server.connected { return "已连接 · \(server.tools.count) 个工具" }
        if let note = server.statusNote, !note.isEmpty { return note }
        if let err = server.lastError, !err.isEmpty { return "未连接 · \(err.prefix(40))" }
        return t("未连接")
    }

    /// 状态颜色：只有**真错误**才用警告色，正常断开用次要色。
    /// 原来 `server.connected ? .green : .orange` 会把"用户主动断开"也染成橙色警报。
    private var statusColor: Color {
        if server.connected { return .green }
        if let err = server.lastError, !err.isEmpty { return .orange }
        return .secondary
    }
}

/// sheet(item:) 用包装：MCP 服务器 + 工具
struct MCPToolCallKey: Identifiable {
    let id = UUID()
    let server: MCPServer
    let tool: MCPTool
}
