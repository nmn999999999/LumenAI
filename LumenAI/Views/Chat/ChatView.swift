import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var llmService: LLMService
    @EnvironmentObject private var agentService: AgentService
    @EnvironmentObject private var modelManager: ModelManager
    @ObservedObject private var providerStore = ProviderStore.shared
    @ObservedObject private var assistantStore = AssistantStore.shared
    @ObservedObject private var ttsService = TTSService.shared
    @ObservedObject private var asrService = ASRService.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @EnvironmentObject private var theme: LumenAIApp.ThemeObserver
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var inputText = ""
    @State private var isAgentMode = false
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var attachments: [ChatMessage.ImageData] = []
    @State private var showConversationList = false
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var searchResults: [ChatStore.SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    /// Agent 流式 token 缓冲区（按气泡 id），配合时间节流减少重渲染
    @State private var agentTokenBuffers: [UUID: String] = [:]
    @State private var agentLastFlush = Date.distantPast
    @FocusState private var inputFocused: Bool

    /// 工具授权弹窗：当 AgentService 解析到 requiresApproval=true 的工具时挂起等用户决策。
    /// 阻断式 alert：等用户按"允许/拒绝"前，AgentService.run() 在 await bridge.requestApproval 阻塞。
    @State private var pendingApproval: PendingApproval?

    struct PendingApproval: Identifiable {
        let id = UUID()
        let call: ChatMessage.ToolCall
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Agent 模式下整个 agent run() 周期共享同一个 assistant 气泡 id。
    /// 第一次 beginIteration 创建新气泡，后续 iteration 复用同一 id → 内容连成一片；
    /// 这样多轮工具调用 / 思考 / 最终答案都看起来是同一条 assistant 消息,
    /// 视觉上不会"分裂"。run() 完成后清空。
    @State private var currentAgentMessageID: UUID?

    /// 联网搜索开关 / 消息编辑 / 朗读状态 / 语音输入
    @State private var webSearchOn = false
    @State private var editingMessage: ChatMessage?
    @State private var editingContent = ""
    @State private var showEditSheet = false
    @State private var speakingMessageID: UUID?
    @State private var voiceBaseText = ""
    /// AI 自动标题任务（防并发重入）
    @State private var titleTask: Task<Void, Never>?
    /// 记忆自动提炼任务（防并发重入）
    @State private var memoryExtractTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // M3 修复:搜索迁移到系统 .searchable(见 messageList 上的修饰符),
                // 这里只保留搜索结果 overlay(输入框由系统工具栏渲染)。
                if showSearch && !searchResults.isEmpty {
                    searchResultsList
                }
                messageList
                    // 搜索:用系统 .searchable。⚠️ 经验(v0.3.20-22):
                    // - 自定义按钮 toggle + isPresented 绑定 → "点开收不起"(toggle 与系统状态打架)
                    // - .searchToolbarBehavior(.minimize) 的按钮状态机 → "点 x 收起又自动重开"
                    // 稳定组合:自定义按钮只"单向打开"(showSearch = true),关闭完全交给
                    // 系统"取消"按钮(系统把 isPresented 置 false);不用 minimize。
                    .searchable(text: $searchText, isPresented: $showSearch, placement: .toolbar)
                    .onChange(of: searchText) { _, newValue in
                        // 防抖：停止输入 200ms 后再执行全量搜索，避免每个按键都扫描所有会话
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard !Task.isCancelled else { return }
                            searchResults = chatStore.search(query: newValue)
                        }
                    }
                    // 搜索收起时清空状态(系统通过 isPresented 置 false)
                    .onChange(of: showSearch) { _, isPresented in
                        if !isPresented {
                            searchText = ""
                            searchResults = []
                        }
                    }
                if canChat {
                    agentStepsBar
                }
                inputBar
            }
            .background(theme.current.pageBackground(for: colorScheme))
            .navigationTitle(chatStore.currentOrNew.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showConversationList) {
                ConversationListView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showEditSheet) {
                editMessageSheet
            }
            .onChange(of: ttsService.isSpeaking) { _, speaking in
                if !speaking { speakingMessageID = nil }
            }
            // 生成时保持屏幕常亮（keep screen on）
            .onChange(of: isGenerating) { _, generating in
                guard SettingsStorage.shared.settings.keepScreenOn else { return }
                #if canImport(UIKit)
                UIApplication.shared.isIdleTimerDisabled = generating
                #endif
            }
            .alert("出错了", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                "需要执行「\(pendingApproval?.call.title ?? pendingApproval?.call.name ?? "工具")」吗?",
                isPresented: .init(
                    get: { pendingApproval != nil },
                    set: { if !$0 {
                        // 自动关闭（如返回上一级）= 拒绝，避免 AgentService 永久阻塞
                        pendingApproval?.continuation.resume(returning: false)
                        pendingApproval = nil
                    } }
                )
            ) {
                Button("拒绝", role: .destructive) {
                    pendingApproval?.continuation.resume(returning: false)
                    pendingApproval = nil
                }
                Button("允许") {
                    pendingApproval?.continuation.resume(returning: true)
                    pendingApproval = nil
                }
            } message: {
                if let pending = pendingApproval {
                    Text("此工具会运行真实操作（SSH / MCP 等），是否授权?\n\n参数:\n\(prettyArgumentsForApproval(pending.call.arguments))")
                }
            }
        }
    }

    /// 是否可发送：本地模型已加载 或 已配置云端 Provider
    private var canChat: Bool {
        llmService.isModelReady || providerStore.hasCloudSelection
    }

    /// Agent 模式可用性（v0.3.45）：仅云端模型 或 ≥3B 本地模型可用。
    /// 小模型（≤3B，如 Qwen3-0.6B / OpenELM-1.1B）指令遵循能力不足：
    /// 长工具目录下会一直卡在思考、或输出乱码（OpenELM 实测）。
    private var canUseAgentMode: Bool {
        if providerStore.hasCloudSelection { return true }
        guard let name = llmService.loadedModelName else { return false }
        if let scale = PromptStrategyResolver.parameterScale(from: name) {
            return scale > 3.0
        }
        return true   // 无法识别规模（自定义导入）：放行
    }

    // MARK: - 消息列表

    private var messageList: some View {
        // 性能：snapshot 一次当前对话的 messages，外层所有引用都从此数组走，
        // 避免 body 内部多次 chatStore.currentOrNew.messages 调用（重复重算 + 全 conversations 扫描）。
        let msgs = chatStore.currentOrNew.messages
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !canChat && msgs.isEmpty {
                        emptyState
                    }
                    ForEach(msgs) { message in
                        MessageBubble(
                            message: message,
                            onRegenerate: message.role == .assistant ? { regenerate(from: message.id) } : nil,
                            onEdit: message.role == .user ? { editMessage(message) } : nil,
                            onDelete: { deleteMessage(message) },
                            onSpeak: message.role == .assistant ? { speakMessage(message) } : nil,
                            isSpeaking: speakingMessageID == message.id
                        )
                        .id(message.id.uuidString)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            // 性能：只在消息数变化（新消息发送/到达完成时）滚到底。流式 token 期间
            // content 持续变化，但消息数没变，不再每 80ms 触发滚动副作用——后者是卡顿大头。
            .onChange(of: msgs.count) { _, _ in
                if let id = msgs.last?.id.uuidString {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .defaultScrollAnchor(.bottom)
            // 在消息列表上下滑即可收起键盘
            .scrollDismissesKeyboard(.interactively)
            // 点击消息区域任意空白处（含气泡间隙）收起键盘；
            // simultaneousGesture 不阻挡气泡内按钮点击；
            // VoiceOver 开启时跳过，避免与逐条浏览手势冲突（REVIEW m5）
            .simultaneousGesture(TapGesture().onEnded {
                guard !voiceOverEnabled else { return }
                inputFocused = false
            })
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let id = chatStore.currentOrNew.messages.last?.id.uuidString {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(canChat ? t("开始对话吧") : t("还没有加载模型"))
                .font(.title3.weight(.semibold))
            Text(canChat
                 ? (providerStore.hasCloudSelection
                    ? "当前云端: \(providerStore.selectionText)"
                    : (llmService.loadedModelName.map { "本地模型: \($0)" } ?? t("在下方输入消息，或开启 Agent 模式使用工具")))
                 : t("前往「模型」页下载或导入 GGUF 模型"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 120)
    }

    // MARK: - 搜索栏

    /// M3:系统 .searchable 渲染输入框;这里只在展开搜索且有结果时显示结果列表 overlay
    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(searchResults.prefix(20)) { result in
                    searchResultRow(result)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 220)
        .background(.ultraThinMaterial)
    }

    private func searchResultRow(_ result: ChatStore.SearchResult) -> some View {
        Button {
            // 跳转到对应对话
            chatStore.currentConversationID = result.conversationID
            showSearch = false
            searchText = ""
            searchResults = []
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.conversationTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(excerpt(from: result.messageContent, around: result.matchRange))
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func excerpt(from text: String, around range: NSRange) -> String {
        let nsText = text as NSString
        let start = max(0, range.location - 20)
        let end = min(nsText.length, range.location + range.length + 40)
        let excerpt = nsText.substring(with: NSRange(location: start, length: end - start))

        var result = ""
        if start > 0 { result += "..." }
        result += excerpt
        if end < nsText.length { result += "..." }
        return result
    }

    // MARK: - Agent 步骤条

    @ViewBuilder
    private var agentStepsBar: some View {
        let settings = SettingsStorage.shared.settings
        if settings.showToolCalls && !agentService.steps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                // M2 修复:多玻璃 chips 用 GlassEffectContainer 统一包裹
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(agentService.steps) { step in
                            HStack(spacing: 4) {
                                Image(systemName: iconName(for: step.kind))
                                    .font(.caption2)
                                Text(step.detail)
                                    .lineLimit(1)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func iconName(for kind: AgentService.Step.Kind) -> String {
        switch kind {
        case .thinking: return "brain"
        case .executing: return "gearshape.2"
        case .result: return "checkmark.circle"
        case .finalAnswer: return "text.bubble"
        }
    }

    // MARK: - 输入栏（液态玻璃 + iOS 26 苹果相机风格可展开工具岛）
    @State private var showTools = false

    private var inputBar: some View {
        VStack(spacing: 6) {
            // 可展开的工具岛（默认折叠，展开后位于主输入栏上方，GlassEffect 同一容器保持视觉连贯）
            if showTools {
                // 工具岛（v0.3.31）：4 个 .glass 按钮在 iOS 26.1 真机上间距 10 会粘成一片
                // （玻璃合并，spacing 语义不可靠 —— v0.3.10/20/21 多次证实）。
                // 改回 v0.3.12/22 真机验证过的 Material 方案：单一材质胶囊承载图标按钮，
                // 材质与玻璃不同层、天然独立不粘连；按钮 44pt 与主输入行对齐，间距 18 不再紧贴。
                // 每个图标固定纯色（蓝/橙/绿/红）；激活时实心色圈 + 白色图标 → 切换状态颜色反馈清晰。
                HStack(spacing: 18) {
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 3,
                        matching: .images
                    ) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 44, height: 44)
                            .background(.blue.opacity(0.15), in: Circle())
                            .accessibilityLabel(t("添加图片"))
                    }
                    .buttonStyle(.plain)
                    .opacity(canChat ? 1 : 0.35)

                    Button {
                        if isAgentMode || canUseAgentMode {
                            withAnimation(.bouncy) { isAgentMode.toggle() }
                        } else {
                            errorMessage = "Agent 模式仅支持云端模型或 ≥3B 的本地模型。当前小模型指令遵循能力不足（易卡思考/输出乱码），请切换云端模型或稍大本地模型。"
                        }
                    } label: {
                        Image(systemName: isAgentMode ? "wand.and.stars" : "terminal")
                            .font(.system(size: 17, weight: .semibold))
                            .symbolEffect(.bounce, value: isAgentMode)
                            .foregroundStyle(isAgentMode ? Color.white : Color.orange)
                            .frame(width: 44, height: 44)
                            .background(isAgentMode ? Color.orange : Color.orange.opacity(0.15), in: Circle())
                            .accessibilityLabel(t("Agent 模式"))
                    }
                    .buttonStyle(.plain)
                    // Agent 模式在本地模型或云端 Provider 下都可用 → 用 canChat 而非 isModelReady，
                    // 否则云端用户/本地未装载时按钮永久灰色，只能重启恢复（v0.3.34 修复）。
                    .disabled(!canChat)
                    .opacity(canChat ? 1 : 0.35)

                    if providerStore.hasCloudSelection {
                        Button {
                            withAnimation(.bouncy) { webSearchOn.toggle() }
                        } label: {
                            Image(systemName: webSearchOn ? "globe.asia.australia.fill" : "globe.asia.australia")
                                .font(.system(size: 17, weight: .semibold))
                                .symbolEffect(.bounce, value: webSearchOn)
                                .foregroundStyle(webSearchOn ? Color.white : Color.green)
                                .frame(width: 44, height: 44)
                                .background(webSearchOn ? Color.green : Color.green.opacity(0.15), in: Circle())
                                .accessibilityLabel(t("联网搜索"))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        toggleVoiceInput()
                    } label: {
                        Image(systemName: asrService.isListening ? "mic.fill" : "mic")
                            .font(.system(size: 17, weight: .semibold))
                            .symbolEffect(.pulse, isActive: asrService.isListening)
                            .foregroundStyle(asrService.isListening ? Color.white : Color.red)
                            .frame(width: 44, height: 44)
                            .background(asrService.isListening ? Color.red : Color.red.opacity(0.15), in: Circle())
                            .accessibilityLabel(t("语音输入"))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: .rect(cornerRadius: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            GlassEffectContainer(spacing: 12) {
                HStack(alignment: .bottom, spacing: 10) {
                    // iOS 26 苹果相机风格：主行只有 [+] / [输入] / [发送] 三个元素
                    Button {
                        withAnimation(.snappy) { showTools.toggle() }
                    } label: {
                        Image(systemName: showTools ? "xmark" : "plus")
                            .symbolEffect(.bounce, value: showTools)
                            .frame(width: 20, height: 20)
                            .accessibilityLabel(showTools ? t("收起工具") : t("展开工具"))
                    }
                    .buttonStyle(.glass)
                    .frame(width: 44, height: 44)

                    TextField(t("输入消息…"), text: $inputText, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        // ⚠️ 粘连修复(v0.3.22,真机验证):iOS 26.1 上 GlassEffectContainer 内
                        // .glassEffect 输入框 + .glassProminent 发送键必然视觉合并,Apple 文档的
                        // spacing 语义在该组合下无效(v0.3.10/v0.3.20 两次证实)。恢复 v0.3.12
                        // 真机验证过的 Material 方案:材质与左右玻璃按钮不同层,天然独立不粘连。
                        .background(.regularMaterial, in: .rect(cornerRadius: 22))

                    sendButton
                    .frame(width: 44, height: 44)
                    .padding(.leading, 2) // 与输入框之间再多 2pt 视觉呼吸空间
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: selectedItems) { _, items in
            Task { await loadAttachments(items) }
        }
    }

    private var sendButton: some View {
        Button {
            if isGenerating {
                stopGeneration()
            } else {
                sendMessage()
            }
        } label: {
            Image(systemName: isGenerating
                  ? "stop.circle.fill"
                  : (canSend ? "arrow.up.circle.fill" : "arrow.up.circle"))
                .font(.system(size: 26))
                .accessibilityLabel(isGenerating ? t("停止生成") : t("发送消息"))
        }
        .buttonStyle(.glassProminent)
        .disabled(!canSend && !isGenerating)
    }

    private func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    // MARK: - 语音输入（ASR）

    private func toggleVoiceInput() {
        if asrService.isListening {
            asrService.stop()
            return
        }
        voiceBaseText = inputText
        asrService.onPartial = { text in
            inputText = voiceBaseText.isEmpty ? text : voiceBaseText + " " + text
        }
        asrService.onFinal = { text in
            inputText = voiceBaseText.isEmpty ? text : voiceBaseText + " " + text
        }
        asrService.start()
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = !attachments.isEmpty
        return canChat && (hasText || hasImage) && !isGenerating
    }

    // MARK: - 工具栏（模型选择 / 助手选择 / 搜索 / 新对话）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showConversationList = true
            } label: {
                Image(systemName: "sidebar.left")
                    .accessibilityLabel(t("对话列表"))
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // 助手选择
            Menu {
                ForEach(assistantStore.assistants) { assistant in
                    Button {
                        assistantStore.currentAssistantID = assistant.id
                    } label: {
                        Label("\(assistant.emoji) \(assistant.name)", systemImage:
                            assistantStore.currentAssistantID == assistant.id ? "checkmark" : "person")
                    }
                }
            } label: {
                Image(systemName: assistantStore.current?.emoji == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                    .accessibilityLabel(t("选择助手"))
            }

            // 搜索入口按钮:只"打开"(showSearch = true),关闭由系统"取消"完成。
            // 不要 toggle —— toggle 与系统 isPresented 双向绑定打架(v0.3.20 教训)。
            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel(t("搜索"))
            }

            // 模型选择（云端 Provider + 本地 GGUF）
            Menu {
                let cloudProviders = providerStore.providers.filter(\.enabled)
                if !cloudProviders.isEmpty {
                    Section(t("云端模型")) {
                        ForEach(cloudProviders) { provider in
                            if provider.models.isEmpty {
                                Button {
                                    providerStore.select(providerID: provider.id, model: "")
                                } label: {
                                    Label(provider.name, systemImage: "server.rack")
                                }
                            }
                            ForEach(provider.models, id: \.self) { model in
                                Button {
                                    providerStore.select(providerID: provider.id, model: model)
                                } label: {
                                    Label("\(provider.name) · \(model)", systemImage:
                                        (providerStore.currentProviderID == provider.id && providerStore.currentModel == model)
                                        ? "checkmark" : "cloud")
                                }
                            }
                        }
                    }
                }
                if !modelManager.downloadedModels.isEmpty {
                    Section(t("本地模型")) {
                        ForEach(modelManager.downloadedModels) { model in
                            Button {
                                // 选中本地模型 = 明确切换到本地引擎：清除云端选择，避免二者同时选中、
                                // 且 resolveEngine 仍优先走云端导致本地选择无效。
                                providerStore.select(providerID: nil, model: "")
                                Task { await loadModel(model) }
                            } label: {
                                Label(model.name, systemImage:
                                    (!providerStore.hasCloudSelection && llmService.loadedModelName == model.name)
                                    ? "checkmark" : "cpu")
                            }
                        }
                    }
                }
            } label: {
                Label(modelMenuTitle, systemImage: modelMenuIcon)
                    .lineLimit(1)
            }

            Button {
                chatStore.createNew()
            } label: {
                Image(systemName: "square.and.pencil")
                    .accessibilityLabel(t("新建对话"))
            }
        }
    }

    private var modelMenuTitle: String {
        if providerStore.hasCloudSelection {
            return providerStore.selectionText
        }
        return llmService.loadedModelName ?? t("选择模型")
    }

    private var modelMenuIcon: String {
        providerStore.hasCloudSelection ? "cloud" : "cpu"
    }

    // MARK: - 动作

    private func loadModel(_ stored: ModelManager.StoredModel) async {
        let url = modelManager.localFileURL(for: stored)
        await llmService.load(url: url, displayName: stored.name)
        if case .ready = llmService.state {
            modelManager.rememberLastUsed(stored)
        }
        if case .failed(let msg) = llmService.state {
            errorMessage = msg
        }
    }

    private func sendMessage() {
        let rawText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }

        // 文生图命令：/draw <描述>（云端 OpenAI 兼容 images/generations）
        if rawText.hasPrefix("/draw ") || rawText.hasPrefix("/draw\n") || rawText == "/draw" {
            let prompt = rawText.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            runDraw(prompt: prompt.isEmpty ? "一只坐在月球上的宇航员猫，超现实风格" : prompt)
            return
        }

        // 多模态护栏：用户附了图片，但当前引擎不支持图片理解（本地纯文本模型如 OpenELM/
        // Qwen3，或本地模型没配 mmproj 投影器）。不要静默丢图，明确引导到支持视觉的模型。
        if !attachments.isEmpty && !llmService.supportsVision {
            let guide = multimodalGuideText()
            errorMessage = guide
            return
        }

        let settings = SettingsStorage.shared.settings
        let images = attachments
        inputText = ""
        attachments = []
        selectedItems = []
        inputFocused = false

        // 提示词变量解析（Prompt Variables）
        let modelName = providerStore.hasCloudSelection ? providerStore.currentModel : (llmService.loadedModelName ?? "")
        let providerName = providerStore.currentProvider?.name ?? ""
        let text = PromptVariableResolver.resolve(rawText, model: modelName, providerName: providerName)

        var conv = chatStore.currentOrNew
        conv.messages.append(ChatMessage(role: .user, content: text, images: images))
        conv.updateTitle()
        conv.modelName = providerStore.hasCloudSelection ? providerStore.selectionText : llmService.loadedModelName
        chatStore.upsert(conv)

        let effectiveSettings = effectiveSettings(from: settings, modelName: modelName, providerName: providerName)

        if isAgentMode {
            // 小模型不支持 Agent：提示并按普通对话发送（v0.3.45）
            guard canUseAgentMode else {
                isAgentMode = false
                errorMessage = "当前模型不支持 Agent 模式（需云端或 ≥3B 本地模型），已按普通对话发送。"
                startGeneration(history: Array(conv.messages), settings: effectiveSettings, images: images.compactMap { $0.cgImage })
                return
            }
            // Agent 模式：人设提示词（助手/变量/人格）显式放入历史首条，
            // 避免被工具指令 system 消息顶掉（withToolInstructions 会追加到第一条 system）
            var agentHistory = Array(conv.messages)
            if !effectiveSettings.systemPrompt.isEmpty {
                agentHistory.insert(ChatMessage(role: .system, content: effectiveSettings.systemPrompt), at: 0)
            }
            let history = agentHistory
            isGenerating = true
            generationTask = Task {
                defer {
                    isGenerating = false
                    generationTask = nil
                }
                let bridge = AgentService.AgentDisplayBridge(
                    beginIteration: {
                        // 复用气泡：如果当前 agent run() 已有 bubble,直接复用 id;
                        // 否则首次创建。这样多轮思考 + 工具调用 + 最终答案
                        // 都渲染在同一个 assistant 气泡内,不分裂成多个 9:30 卡。
                        if let existing = currentAgentMessageID {
                            return existing
                        }
                        let m = ChatMessage(role: .assistant, content: "", isStreaming: true, isAgentRound: true)
                        var c = chatStore.currentOrNew
                        c.messages.append(m)
                        chatStore.upsert(c)
                        currentAgentMessageID = m.id
                        return m.id
                    },
                    appendToken: { id, token in
                        appendAssistantToken(id: id, token: token)
                    },
                    attachToolCall: { id, call in
                        attachToolCallToMessage(id: id, call: call)
                    },
                    endIteration: { id in
                        finalizeMessage(id: id)
                    },
                    requestApproval: { _, call in
                        // 阻塞等用户在 chat 里点"允许/拒绝"。@MainActor self 才能写 @State。
                        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                            // setState 派发到 main；cont 只在用户点按钮时 resume 一次
                            pendingApproval = PendingApproval(call: call, continuation: cont)
                        }
                    }
                )
                let bubbleId = currentAgentMessageID  // 备份气泡 id,run() 之后会用
                let result = await agentService.run(
                    history: history,
                    settings: effectiveSettings,
                    toolsEnabledTools: BuiltInTools.allTools + MCPService.shared.toolDefinitions + PluginManager.shared.installedToolDefinitions(),
                    llm: llmService,
                    bridge: bridge
                )
                // run() 退出后清空共享气泡 id,下次发送/agent 时重新创建
                currentAgentMessageID = nil

                // 模型兜底：AgentService 可能在「think 块内回答」场景下,用 stripThinkTagsKeepThink
                // 把 final answer 从 raw 里抠出来当 return content。如果 bubble 内的
                // visibleContent(剥离 think 后)为空,把最终答案回填到 message.content 末尾
                // —— 否则用户看到的 assistant 只有 thinking 块而没有最终答案。
                if !result.content.isEmpty, let bubbleId {
                    var conv = chatStore.currentOrNew
                    if let idx = conv.messages.firstIndex(where: { $0.id == bubbleId }) {
                        let visible = AgentService.stripThinkTags(conv.messages[idx].content)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if visible.isEmpty {
                            // 当前 bubble 内容只含 think 块 + tool call chip,没有 user-facing answer。
                            // 把 AgentService 兜底提取的最终答案回填到 message.content 末尾,
                            // 这样 MessageBubble 的 visibleContent(剥离 think 之后)就显示最终答案。
                            conv.messages[idx].content = conv.messages[idx].content + "\n\n" + result.content
                            chatStore.upsert(conv)
                        }
                    }
                }

                if !Task.isCancelled {
                    maybeAutoTitle()
                    maybeAutoExtractMemory()
                }
            }
            return
        }

        startGeneration(history: Array(conv.messages), settings: effectiveSettings, images: images.compactMap { $0.cgImage })
    }

    /// 解析助手绑定 + 提示词变量 + 人格注入 + 提示词策略 → 有效设置
    private func effectiveSettings(from settings: ModelSettings, modelName: String, providerName: String) -> ModelSettings {
        var effective = settings
        let assistant = assistantStore.current
        let prompt = (assistant?.systemPrompt.isEmpty == false ? assistant!.systemPrompt : settings.systemPrompt)
        effective.systemPrompt = PromptVariableResolver.resolve(
            prompt,
            model: modelName,
            providerName: providerName
        )
        // 世界观 / 记忆 / 指令注入（World Book / Memory / Instruction Injection）
        let persona = personaStore.injectionText(settings: effective)
        if !persona.isEmpty {
            effective.systemPrompt = [effective.systemPrompt, persona]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        // 提示词策略：按模型能力自动适配（本地小模型简洁 / 云端旗舰专业）
        let resolved = resolveEngine()
        let useCloud = resolved.provider != nil
        let strategyModel = useCloud ? resolved.model : (llmService.loadedModelName ?? "")
        let strategy = PromptStrategyResolver.detect(
            isCloud: useCloud,
            modelName: strategyModel,
            forced: PromptStrategy(rawValue: settings.promptStrategy) ?? .auto
        )
        let template = PromptStrategyResolver.template(
            for: strategy,
            language: effective.language,
            assistantName: assistant?.name ?? "AI"
        )
        if !template.isEmpty {
            effective.systemPrompt = [effective.systemPrompt, template]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        if let temp = assistant?.temperature {
            effective.temperature = temp
        }
        return effective
    }

    /// 核心生成流程：创建 assistant 气泡并流式渲染（云 / 本地自动路由）
    private func startGeneration(history: [ChatMessage], settings: ModelSettings, images: [CGImage]) {
        isGenerating = true
        generationTask = Task {
            defer {
                isGenerating = false
                generationTask = nil
            }

            let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
            var conv = chatStore.currentOrNew
            conv.messages.append(assistantMsg)
            chatStore.upsert(conv)

            let resolved = resolveEngine()
            var full = ""
            var lastFlush = Date.distantPast
            let genStart = Date()

            do {
                let stream: AsyncThrowingStream<String, Error>

                // 联网搜索结果注入（云/本地通用，Web Search）
                let lastUser = history.last(where: { $0.role == .user })?.content ?? ""
                let searchCtx = await webSearchContext(query: lastUser, settings: settings)

                if let provider = resolved.provider, !resolved.model.isEmpty {
                    // 云端
                    var cloudMessages = llmService.makeCloudMessages(history, settings: settings)
                    if let ctx = searchCtx {
                        cloudMessages.insert(CloudMessage(role: .system, content: ctx), at: 0)
                    }
                    stream = CloudChatClient.stream(
                        provider: provider,
                        model: resolved.model,
                        messages: cloudMessages,
                        temperature: resolved.temp ?? settings.temperature,
                        maxTokens: settings.apiMaxTokens
                    )
                } else {
                    // 本地引擎（或旧 API 模式）
                    var localHistory = history
                    if let ctx = searchCtx {
                        localHistory.insert(ChatMessage(role: .system, content: ctx), at: 0)
                    }
                    stream = llmService.streamChat(history: localHistory, settings: settings, images: images)
                }

                for try await token in stream {
                    full += token
                    // 按时间节流刷新 UI（~80ms），避免高速 token 流频繁触发全量重渲染
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= 0.08 {
                        updateAssistant(id: assistantMsg.id, content: full)
                        lastFlush = now
                    }
                }
                // 生成速度反馈（Metal/CPU 加速效果可见）
                let elapsed = Date().timeIntervalSince(genStart)
                let approxTokens = Int(Double(full.count) * 0.6)
                let speedText: String? = (elapsed >= 0.5 && approxTokens > 0)
                    ? String(format: "⚡ %.1f tok/s", Double(approxTokens) / elapsed)
                    : nil
                updateAssistant(id: assistantMsg.id, content: full, streaming: false, speedText: speedText)
            } catch {
                if full.isEmpty {
                    full = "⚠️ \(error.localizedDescription)"
                }
                updateAssistant(id: assistantMsg.id, content: full, streaming: false)
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            // 生成结束后为新对话自动生成标题（不抢引擎，失败静默；用户取消则不触发）
            if !Task.isCancelled {
                maybeAutoTitle()
                maybeAutoExtractMemory()
            }
        }
    }

    // MARK: - AI 自动标题

    private func maybeAutoTitle() {
        guard titleTask == nil else { return }
        let conv = chatStore.currentOrNew
        guard conv.messages.count >= 3, canChat else { return }

        // 标题是否值得 AI 优化：仍是默认「新对话」，或仍是第一条用户消息的
        // 30 字前缀标题（updateTitle 生成的）→ 生成更简洁的 AI 标题。
        // 旧条件只查 == "新对话"，但 updateTitle 会把前缀标题写入，导致 AI 标题永不触发。
        let firstUser = conv.messages.first { $0.role == .user }?.content ?? ""
        let prefixTitle = String(firstUser.prefix(30))
        let needsTitle = conv.title == "新对话" || (!prefixTitle.isEmpty && conv.title == prefixTitle)
        guard needsTitle else { return }

        let userMessages = conv.messages.filter { $0.role == .user }
        let first = userMessages.first?.content ?? ""
        let second = userMessages.dropFirst().first?.content ?? ""
        let instruction = "根据这段对话，用不超过 12 个字概括主题作为标题。只输出标题本身，不要引号、标点或解释。"
        let history = [
            ChatMessage(role: .user, content: "\(instruction)\n\n第一句：\(first.prefix(80))\n第二句：\(second.prefix(80))")
        ]
        // 精简设置：标题生成不带系统提示词/人格，低温确定性输出，控制成本
        var titleSettings = SettingsStorage.shared.settings
        titleSettings.systemPrompt = ""
        titleSettings.temperature = 0.3
        titleTask = Task {
            defer { titleTask = nil }
            do {
                let text = try await llmService.complete(messages: history, settings: titleSettings)
                let cleaned = Self.cleanTitle(text)
                guard !cleaned.isEmpty else { return }
                // 期间用户没手动改名（仍为默认/前缀标题）才回写 AI 标题
                if var c = chatStore.conversation(id: conv.id), c.title == "新对话" || c.title == prefixTitle {
                    c.title = cleaned
                    chatStore.upsert(c)
                }
            } catch {
                // 失败静默，不打扰用户
            }
        }
    }

    /// 对话结束后自动提炼长期记忆（按设置开关；防并发重入）。
    /// 与自动标题同理：低优先级后台 pipeline，失败静默不打扰用户。
    private func maybeAutoExtractMemory() {
        guard memoryExtractTask == nil else { return }
        guard SettingsStorage.shared.settings.autoExtractMemory else { return }
        let conv = chatStore.currentOrNew
        let userCount = conv.messages.filter { $0.role == .user }.count
        guard userCount >= 3, canChat else { return }
        let messages = conv.messages
        memoryExtractTask = Task {
            defer { memoryExtractTask = nil }
            _ = await personaStore.extractMemories(from: messages, llm: llmService)
        }
    }

    /// 清洗模型输出的标题：去引号/换行/前后缀，限长
    static func cleanTitle(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["\"", "「", "」", "《", "》", "标题：", "标题:", "'", "``", "```"] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        let firstLine = t.split(separator: "\n").first.map(String.init) ?? t
        return String(firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
    }

    /// 多模态引导文案：用户发图但当前引擎不支持视觉时提示如何切换到支持图片的模型。
    private func multimodalGuideText() -> String {
        var s = "当前模型不支持图片理解，图片不会发送。请切换到支持视觉的模型：\n"
        // 本地多模态模型：Gemma 3 4B / Qwen2.5 VL（带 mmproj 才能看图）
        s += "· 本地：在「模型」页下载并加载 Gemma 3 4B 或 Qwen2.5 VL 3B（多模态）。\n"
        s += "· 云端：在顶部模型菜单选择一个视觉模型（如 OpenAI gpt-4o / Gemini）。\n"
        s += "若已用多模态本地模型仍不行，请确认其 gguf 同目录放入了对应的 mmproj 投影器文件。"
        return s
    }

    /// 解析生效引擎：助手绑定优先，其次当前云端选择；否则本地
    private func resolveEngine() -> (provider: ChatProvider?, model: String, temp: Double?) {
        let assistant = assistantStore.current
        if let pid = assistant?.providerID,
           let p = providerStore.provider(id: pid),
           p.enabled, p.hasKey {
            let m = (assistant?.model?.isEmpty == false ? assistant!.model! : p.models.first) ?? ""
            return (p, m, assistant?.temperature)
        }
        if let p = providerStore.currentProvider, p.hasKey, !providerStore.currentModel.isEmpty {
            return (p, providerStore.currentModel, assistant?.temperature)
        }
        return (nil, "", nil)
    }

    /// 联网搜索上下文注入（Web Search 工具）
    private func webSearchContext(query: String, settings: ModelSettings) async -> String? {
        guard !query.isEmpty, settings.cloudWebSearch || webSearchOn else { return nil }
        let result = await SearchService.search(query: query, settings: settings)
        return "以下是针对「\(query)」的联网搜索结果，请基于这些信息回答：\n\n\(result)"
    }

    /// 原位更新流式 assistant 消息（批量更新减少触发频率）。
    private func updateAssistant(
        id: UUID,
        content: String,
        toolCalls: [ChatMessage.ToolCall] = [],
        streaming: Bool = true,
        speedText: String? = nil
    ) {
        var conv = chatStore.currentOrNew
        guard let idx = conv.messages.firstIndex(where: { $0.id == id }) else { return }
        conv.messages[idx].content = content
        conv.messages[idx].toolCalls = toolCalls
        conv.messages[idx].isStreaming = streaming
        if speedText != nil {
            conv.messages[idx].speedText = speedText
        }
        chatStore.upsert(conv)
    }

    // MARK: - 消息操作（重新生成 / 编辑 / 删除 / 朗读）

    private func regenerate(from assistantID: UUID) {
        var conv = chatStore.currentOrNew
        guard let idx = conv.messages.firstIndex(where: { $0.id == assistantID }) else { return }
        guard let userMsg = conv.messages[..<idx].last(where: { $0.role == .user }) else { return }

        conv.messages.removeSubrange(idx...)
        chatStore.upsert(conv)

        let settings = SettingsStorage.shared.settings
        let modelName = providerStore.hasCloudSelection ? providerStore.currentModel : (llmService.loadedModelName ?? "")
        let providerName = providerStore.currentProvider?.name ?? ""
        let effective = effectiveSettings(from: settings, modelName: modelName, providerName: providerName)

        startGeneration(history: Array(conv.messages), settings: effective, images: userMsg.images.compactMap { $0.cgImage })
    }

    private func editMessage(_ message: ChatMessage) {
        editingMessage = message
        editingContent = message.content
        showEditSheet = true
    }

    private func saveEditedMessage() {
        guard let msg = editingMessage else { return }
        var conv = chatStore.currentOrNew
        guard let idx = conv.messages.firstIndex(where: { $0.id == msg.id }) else { return }

        conv.messages[idx].content = editingContent
        // 删除该消息之后的所有内容，再从编辑点重新生成
        if idx + 1 < conv.messages.count {
            conv.messages.removeSubrange((idx + 1)...)
        }
        chatStore.upsert(conv)

        let settings = SettingsStorage.shared.settings
        let modelName = providerStore.hasCloudSelection ? providerStore.currentModel : (llmService.loadedModelName ?? "")
        let providerName = providerStore.currentProvider?.name ?? ""
        let effective = effectiveSettings(from: settings, modelName: modelName, providerName: providerName)

        startGeneration(history: Array(conv.messages), settings: effective, images: msg.images.compactMap { $0.cgImage })
    }

    private func deleteMessage(_ message: ChatMessage) {
        var conv = chatStore.currentOrNew
        conv.messages.removeAll { $0.id == message.id }
        chatStore.upsert(conv)
    }

    private func speakMessage(_ message: ChatMessage) {
        if ttsService.isSpeaking {
            ttsService.stop()
            speakingMessageID = nil
            return
        }
        let text = message.visibleContent
        guard !text.isEmpty else { return }
        speakingMessageID = message.id
        ttsService.speak(text)
    }

    private var editMessageSheet: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $editingContent)
                    .padding(8)
                    .frame(minHeight: 200)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    .padding()
            }
            .navigationTitle(t("编辑消息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消")) { showEditSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("保存")) {
                        showEditSheet = false
                        saveEditedMessage()
                    }
                }
            }
        }
    }

    // MARK: - Agent 流式辅助（逐轮气泡）

    /// 给指定 assistant 气泡追加一个原始 token（含 <think> 标签，气泡自动解析思考/正文）。
    /// token 先入缓冲区，按时间节流（~80ms）批量刷入气泡，减少流式期间的全量重渲染。
    private func appendAssistantToken(id: UUID, token: String) {
        agentTokenBuffers[id, default: ""] += token
        let now = Date()
        guard now.timeIntervalSince(agentLastFlush) >= 0.08 else { return }
        agentLastFlush = now
        flushAgentTokenBuffer(id: id)
    }

    /// 把指定气泡缓冲区里的 token 一次性追加到消息内容。
    private func flushAgentTokenBuffer(id: UUID) {
        guard let buffered = agentTokenBuffers.removeValue(forKey: id), !buffered.isEmpty else { return }
        var conv = chatStore.currentOrNew
        guard let idx = conv.messages.firstIndex(where: { $0.id == id }) else { return }
        conv.messages[idx].content += buffered
        chatStore.upsert(conv)
    }

    /// 格式化工具参数 JSON 用于弹窗展示：缩进排版，截断到 300 字。
    private func prettyArgumentsForApproval(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: pretty, encoding: .utf8)
        else { return json }
        let trimmed = str.count > 300 ? String(str.prefix(300)) + "\n…" : str
        return trimmed
    }

    /// 把解析出的工具调用挂到指定气泡（气泡内以可展开 chip 展示参数与结果）。
    /// 同 record.id 二次调用为「覆盖更新」（状态机变更）：避免 .running → .complete 出现两份。
    private func attachToolCallToMessage(id: UUID, call: ChatMessage.ToolCall) {
        var conv = chatStore.currentOrNew
        guard let idx = conv.messages.firstIndex(where: { $0.id == id }) else { return }
        var calls = conv.messages[idx].toolCalls
        if let existing = calls.firstIndex(where: { $0.id == call.id }) {
            calls[existing] = call
        } else {
            calls.append(call)
        }
        conv.messages[idx].toolCalls = calls
        chatStore.upsert(conv)
    }

    /// 结束指定气泡的流式状态（isStreaming = false），使其可被落盘与正常渲染。
    private func finalizeMessage(id: UUID) {
        // 先刷出缓冲区中尚未上屏的 token，再结束流式
        flushAgentTokenBuffer(id: id)
        var conv = chatStore.currentOrNew
        guard let idx = conv.messages.firstIndex(where: { $0.id == id }) else { return }
        conv.messages[idx].isStreaming = false
        chatStore.upsert(conv)
    }

    private func loadAttachments(_ items: [PhotosPickerItem]) async {
        var loaded: [ChatMessage.ImageData] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let resized = Self.resizedImageData(from: data, maxDimension: 1024) {
                loaded.append(resized)
            }
        }
        attachments = loaded
    }

    /// 压缩图片，避免超出模型/内存限制
    static func resizedImageData(from data: Data, maxDimension: CGFloat) -> ChatMessage.ImageData? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return ChatMessage.ImageData(data: resized.jpegData(compressionQuality: 0.85) ?? data,
                                     mimeType: "image/jpeg")
        #else
        return ChatMessage.ImageData(data: data, mimeType: "image/png")
        #endif
    }

    // MARK: - 云端文生图（/draw 命令）

    /// 处理 `/draw <描述>`：用当前已配置生图模型的云端 Provider 生成图片，
    /// 生成的图片作为 assistant 消息插入对话并展示。
    private func runDraw(prompt: String) {
        let drawProvider: ChatProvider? = {
            // 优先当前选中的 Provider；若无则回退到第一个「已配生图模型」的 OpenAI/兼容 Provider
            if let cur = providerStore.currentProvider, CloudImageClient.canGenerate(on: cur) {
                return cur
            }
            return providerStore.providers.first { $0.enabled && CloudImageClient.canGenerate(on: $0) }
        }()
        guard let provider = drawProvider else {
            errorMessage = "还没有可用的文生图服务。请到「服务」页选择或编辑一个 OpenAI/兼容 Provider，并在「生图模型」中填写模型名（如 gpt-image-1 / black-forest-labs/FLUX.1-schnell）。然后发送 /draw 描述 生成图片。"
            return
        }

        inputText = ""
        attachments = []
        selectedItems = []
        inputFocused = false

        var conv = chatStore.currentOrNew
        conv.messages.append(ChatMessage(role: .user, content: "/draw \(prompt)"))
        conv.updateTitle()
        conv.modelName = "\(provider.name) · 生图"
        chatStore.upsert(conv)

        isGenerating = true
        generationTask = Task {
            defer {
                isGenerating = false
                generationTask = nil
            }
            let placeholder = ChatMessage(role: .assistant, content: "🎨 正在生成图片…", isStreaming: true)
            var c = chatStore.currentOrNew
            c.messages.append(placeholder)
            chatStore.upsert(c)

            do {
                let imageData = try await CloudImageClient.generate(provider: provider, prompt: prompt)
                try Task.checkCancellation()
                // 把返回图片压成 JPEG 存进气泡（避免 PNG 过大占用存档空间）
                let stored = Self.imageDataAsJPEG(imageData)
                var m = chatStore.currentOrNew
                if let idx = m.messages.firstIndex(where: { $0.id == placeholder.id }) {
                    m.messages[idx].content = "🖼️ \(prompt)"
                    m.messages[idx].images = [stored]
                    m.messages[idx].isStreaming = false
                    chatStore.upsert(m)
                }
            } catch {
                var m = chatStore.currentOrNew
                if let idx = m.messages.firstIndex(where: { $0.id == placeholder.id }) {
                    m.messages[idx].content = "⚠️ \(error.localizedDescription)"
                    m.messages[idx].isStreaming = false
                    chatStore.upsert(m)
                }
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func imageDataAsJPEG(_ data: Data) -> ChatMessage.ImageData {
        #if canImport(UIKit)
        if let ui = UIImage(data: data), let jpeg = ui.jpegData(compressionQuality: 0.9) {
            return ChatMessage.ImageData(data: jpeg, mimeType: "image/jpeg")
        }
        #endif
        return ChatMessage.ImageData(data: data, mimeType: "image/png")
    }
}
