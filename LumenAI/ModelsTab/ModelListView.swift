import SwiftUI
import UniformTypeIdentifiers
import Foundation

extension ModelManager.StoredModel {
    var sizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }
}

struct ModelListView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var llmService: LLMService
    @EnvironmentObject private var theme: LumenAIApp.ThemeObserver
    @Environment(\.colorScheme) private var colorScheme

    @State private var showImporter = false
    @State private var showCustomURL = false
    @State private var customName = ""
    @State private var customURLText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    loadedSection
                    downloadedSection
                    catalogSection
                }
                .padding(14)
            }
            .background(theme.current.pageBackground(for: colorScheme))
            // iOS 26 液态玻璃：滚动到顶部边界时导航栏恢复"浮动圆球"折叠效果
            .scrollEdgeEffectStyle(.hard, for: .top)
            .navigationTitle("模型")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showCustomURL = true
                    } label: {
                        Label("URL", systemImage: "link")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: ggufTypes,
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                do {
                    try modelManager.importFromFiles(url: url, name: nil)
                } catch {
                    modelManager.lastError = "导入失败: \(error.localizedDescription)"
                }
            }
            .alert("从 URL 下载 GGUF", isPresented: $showCustomURL) {
                TextField("模型名称", text: $customName)
                TextField("https://…/model.gguf", text: $customURLText)
                // 原来这里直接 `if let url = URL(string:)` —— URL 留空时返回 nil，
                // 整个 if 被跳过，但弹窗照样关闭、输入框被清空、没有任何提示，
                // 用户视角就是「点了没反应」。改成不合法就禁用按钮 + 说明原因。
                Button("下载") {
                    if let url = parsedCustomURL {
                        modelManager.downloadCustom(name: customName, remoteURL: url)
                        customName = ""
                        customURLText = ""
                    }
                }
                .disabled(parsedCustomURL == nil)
                Button("取消", role: .cancel) {}
            } message: {
                if let reason = customURLProblem {
                    Text(reason)
                } else {
                    Text("粘贴指向 .gguf 文件的直链")
                }
            }
            .alert("出错了", isPresented: .init(
                get: { modelManager.lastError != nil },
                set: { if !$0 { modelManager.lastError = nil } }
            )) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(modelManager.lastError ?? "")
            }
        }
    }

    /// 解析用户输入的下载地址；不合法时返回 nil（「下载」按钮会被禁用）。
    private var parsedCustomURL: URL? {
        guard customURLProblem == nil else { return nil }
        return URL(string: customURLText.trimmingCharacters(in: .whitespaces))
    }

    /// 地址不合法的**具体原因**，直接显示给用户。
    /// 之前这里什么都不提示：URL 为空时 `URL(string:)` 返回 nil，if 被跳过，
    /// 但弹窗照关、输入框被清空 —— 用户只能反复点，不知道哪里不对。
    private var customURLProblem: String? {
        let text = customURLText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "请先填写 .gguf 文件的直链地址" }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "地址需要以 http:// 或 https:// 开头"
        }
        let path = url.path.lowercased()
        guard path.hasSuffix(".gguf") else {
            return "这个地址看起来不是 .gguf 文件，请确认链接指向模型本体"
        }
        return nil
    }

    private var ggufTypes: [UTType] {
        var types: [UTType] = [.data]
        if let gguf = UTType(filenameExtension: "gguf") {
            types.insert(gguf, at: 0)
        }
        return types
    }

    // MARK: - 已加载

    @ViewBuilder
    private var loadedSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "当前引擎", systemImage: "bolt.horizontal.circle")
                switch llmService.state {
                case .idle:
                    statusRow("未加载模型", icon: "circle.dashed", color: .secondary)
                case .loading(let name):
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在加载 \(name)…")
                            .foregroundStyle(.secondary)
                    }
                case .ready(let name):
                    statusRow("\(name) 已就绪", icon: "checkmark.seal.fill", color: .green)
                case .apiMode(let name):
                    statusRow("API 模式: \(name)", icon: "cloud.fill", color: .purple)
                case .failed(let msg):
                    statusRow(msg, icon: "exclamationmark.triangle.fill", color: .red)
                }

                // 这个按钮原来用 `llmService.isModelReady` 判断，而 API 模式也算「就绪」
                // （LLMService: `if case .apiMode = state { return true }`）—— 于是内存里
                // 根本没有模型时，按钮却写着「卸载模型（释放内存）」；点下去 state 变 idle，
                // API 模式静默失效，对话直接变成演示引擎的回复。按钮文字必须与真实后果一致。
                if case .ready = llmService.state {
                    Button(role: .destructive) {
                        llmService.unload()
                    } label: {
                        Label("卸载模型（释放内存）", systemImage: "eject")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func statusRow(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).lineLimit(2)
        }
    }

    // MARK: - 已下载

    @ViewBuilder
    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "本地模型", systemImage: "internaldrive")
            if modelManager.downloadedModels.isEmpty {
                GlassCard(cornerRadius: 18) {
                    Text("暂无本地模型。可从下方目录下载，或通过右上角按钮从「文件」导入自行下载的 .gguf 文件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(modelManager.downloadedModels) { stored in
                    StoredModelRow(stored: stored)
                }
            }
        }
    }

    // MARK: - 推荐目录

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "推荐模型（HuggingFace）", systemImage: "globe")
            ForEach(AIModelInfo.catalog) { model in
                CatalogModelRow(model: model)
            }
        }
    }
}

// MARK: - 行组件

struct StoredModelRow: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var llmService: LLMService
    let stored: ModelManager.StoredModel
    @State private var loadingNow = false
    /// 待确认删除的模型。几 GB 的文件删掉就得重新下载，必须让用户先看清楚。
    @State private var pendingDelete: ModelManager.StoredModel?

    var body: some View {
        GlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stored.name)
                            .font(.headline)
                        Text("\(stored.sizeFormatted) · \(stored.fileName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if llmService.loadedModelName == stored.name {
                        ModelBadge(text: "使用中", tint: .green)
                    }
                }

                if loadingNow {
                    ProgressView("加载中，首次可能较慢…")
                } else {
                    HStack(spacing: 10) {
                        Button {
                            loadingNow = true
                            Task {
                                let url = modelManager.localFileURL(for: stored)
                                // 选中本地模型 = 明确切到本地引擎：必须**先清掉云端选择**。
                                // 聊天页早就为这个 bug 打过补丁（ChatView 里那段带注释的
                                // `providerStore.select(providerID: nil, model: "")`），
                                // 而模型页漏了 —— 于是已有云端选中时在这里点「加载」，
                                // 徽标变成「使用中」、引擎显示「已就绪」，但真正回答的仍是
                                // 云端模型（LLMService 里云端优先级高于本地）。
                                ProviderStore.shared.select(providerID: nil, model: "")
                                await llmService.load(url: url, displayName: stored.name)
                                loadingNow = false
                                if case .failed(let msg) = llmService.state {
                                    modelManager.lastError = msg
                                } else {
                                    // 同一个「加载模型」动作有两个入口（这里和聊天页），
                                    // 而 rememberLastUsed 原先只有聊天页调 —— 从模型页加载
                                    // 的模型不会被记住，下次启动自动加载的还是旧的那个。
                                    // 两个入口必须做同一件事。
                                    modelManager.rememberLastUsed(stored)
                                }
                            }
                        } label: {
                            Label(llmService.loadedModelName == stored.name ? "重新加载" : "加载",
                                  systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)

                        // 原来是只有垃圾桶图标的按钮，一点就 `modelManager.delete` ——
                        // 几 GB 的 gguf 文件瞬间消失、没有确认也没有撤销，
                        // 而且正在「使用中」的模型也能直接删掉（文件没了，引擎却还显示「已就绪」）。
                        Button(role: .destructive) {
                            pendingDelete = stored
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .confirmationDialog(
            "删除这个模型？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { target in
            Button("删除", role: .destructive) {
                // 正在使用的模型要先卸载：否则文件删了、列表项没了，
                // 而「当前引擎」还显示「已就绪」，再发消息就会莫名失败。
                if llmService.loadedModelName == target.name {
                    llmService.unload()
                }
                modelManager.delete(target)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { target in
            let gb = Double(target.sizeBytes) / 1_073_741_824
            let size = gb >= 1
                ? String(format: "%.1f GB", gb)
                : String(format: "%.0f MB", Double(target.sizeBytes) / 1_048_576)
            Text("将删除本地文件「\(target.fileName)」（约 \(size)），删除后需要重新下载。"
                 + (llmService.loadedModelName == target.name ? "该模型正在使用中，会先被卸载。" : ""))
        }
    }
}

struct CatalogModelRow: View {
    @EnvironmentObject private var modelManager: ModelManager
    let model: AIModelInfo

    var body: some View {
        GlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(.headline)
                        Text(model.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ModelBadge(text: model.sizeDescription)
                            ModelBadge(text: model.estimatedRAMDescription, tint: .blue)
                            if model.supportsMultimodal {
                                ModelBadge(text: "多模态", tint: .purple)
                            }
                            if model.supportsToolCalling {
                                ModelBadge(text: "工具调用", tint: .orange)
                            }
                        }
                    }
                    Spacer()
                }

                if let progress = modelManager.progressFor(model.id) {
                    ProgressView(value: progress) {
                        Text("下载中 \(Int(progress * 100))%")
                            .font(.caption)
                    }
                    Button("取消", role: .destructive) {
                        modelManager.cancelDownload(id: model.id)
                    }
                    .buttonStyle(.glass)
                } else if modelManager.isDownloaded(model) {
                    Label("已下载 · 在「本地模型」中加载", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button {
                        modelManager.download(model)
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }
}
