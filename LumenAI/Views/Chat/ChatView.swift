import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// 文件选择按钮（DocumentPicker 封装）
struct DocumentPickerButton: View {
    @Binding var selectedFiles: [URL]
    let onPick: ([URL]) -> Void

    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 44, height: 44)
                .background(.purple.opacity(0.15), in: Circle())
                .accessibilityLabel("添加文件")
        }
        .buttonStyle(.plain)
        // 不再按 canChat 置灰：选文件不需要模型，"没有模型"应该是发送时给出
        // 明确提示，而不是让文件按钮点了没反应（"没办法提交文件"的一种）。
        .sheet(isPresented: $showPicker) {
            // v0.3.74：换 UIKit asCopy 选择器（见 UIKitFilePicker 注释 ——
            // SwiftUI .fileImporter 在 iOS 26 真机有读权限/弹窗不关闭的已知问题）
            UIKitFilePicker(
                allowedTypes: [.data, .pdf, .text, .spreadsheet, .presentation, .archive, .audio, .video, .image],
                allowsMultipleSelection: true
            ) { urls in
                showPicker = false
                selectedFiles = urls
                onPick(urls)
            } onCancelled: {
                showPicker = false
            }
            .ignoresSafeArea()
        }
    }
}

/// 附件 chip 里的小缩略图：body 每帧重算时不再重复解码 JPEG（解码一次存 @State）
private struct ChipThumbnail: View {
    let data: Data
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.25)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(.rect(cornerRadius: 5))
        .onAppear {
            guard image == nil else { return }
            image = UIImage(data: data)
        }
    }
}

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
    /// agent 的任务清单（PlanPanel 的数据源）。
    /// 观察点放在 ChatView、再以参数传给 PlanPanel：数据源只有一份，
    /// 面板不需要自己再持有一个 shared 引用（两个 @ObservedObject 指同一对象也不会坏事，
    /// 但会让"谁负责绑定对话"这件事变模糊 —— 绑定的责任在下面 onAppear/onChange 这一处）。
    @ObservedObject private var todoStore = TodoStore.shared
    /// 待授权请求现在由它统一持有（灵动岛上的按钮也要能恢复同一个请求）。
    @ObservedObject private var approvalCenter = AgentApprovalCenter.shared
    /// 聊天页要直接读写设置里的「联网搜索」开关（与设置页共用同一份值）。
    @ObservedObject private var chatSettings = SettingsStorage.shared
    @EnvironmentObject private var theme: LumenAIApp.ThemeObserver
    @Environment(\.colorScheme) private var colorScheme
    /// 回到前台时要检查有没有被打断的 agent 任务需要续跑
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var inputText = ""
    @State private var isAgentMode = false
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var attachments: [ChatMessage.ImageData] = []
    @State private var selectedFiles: [URL] = []
    @State private var fileAttachments: [ChatMessage.FileData] = []
    @State private var showConversationList = false
    /// 任务清单整页（工具栏入口）。见 toolbarContent 里那个 checklist 按钮的注释。
    @State private var showTaskList = false
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var showSearch = false
    /// 滚离消息底部时显示「回到最新」浮球（见 messageList 的 onScrollGeometryChange）。
    @State private var showScrollToBottom = false
    @State private var searchText = ""
    @State private var searchResults: [ChatStore.SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    /// Agent 流式 token 缓冲区（按气泡 id），配合时间节流减少重渲染。
    ///
    /// **故意是普通引用类型，不是 `@State [UUID: String]`** —— 这是修「agent 跑任务时卡到划不动」的关键。
    ///
    /// 原来这里写的是 `@State private var agentTokenBuffers: [UUID: String] = [:]`，
    /// 而 `appendAssistantToken` 里**每一个 token** 都做一次
    /// `agentTokenBuffers[id, default: ""] += token`。`@State` 的任何写入都会让
    /// **整个 ChatView 重新求值**，所以真实行为是「每生成一个 token 就重建整个聊天页」：
    /// 消息列表（含可见气泡的 Markdown 重排）+ 步骤条 + 计划面板 + 输入栏全部重算，
    /// 而 ChatView 上挂着 12 个观察对象。本地模型 20~40 tok/s，就是每秒重建几十次。
    ///
    /// 下面那句「按时间节流（~80ms）批量刷入气泡」的注释其实**只对了一半**：
    /// 80ms 节流挡住的是"写入 chatStore"那一步（那个确实挡住了），
    /// 而每个 token 对 `@State` 的写入根本没被挡 —— 节流形同虚设。
    ///
    /// 换成引用类型后，SwiftUI 只在**盒子身份**变化时重建，而这个盒子从头到尾是同一个对象，
    /// 改它的属性不触发任何重建。真正的上屏仍由 80ms 的 flush 驱动（12.5 次/秒，
    /// 而不是每个 token 一次）。
    @State private var tokenBuffer = AgentTokenBuffer()
    @FocusState private var inputFocused: Bool
    /// in-content 搜索行的焦点（v0.3.75 起替代系统 .searchable，见 searchBarRow 注释）。
    @FocusState private var searchFieldFocused: Bool

    /// 工具授权弹窗：当 AgentService 解析到 requiresApproval=true 的工具时挂起等用户决策。
    /// 阻断式 alert：等用户按「允许 / 本会话内总是允许 / 拒绝」前，AgentService.run() 在
    /// await bridge.requestApproval 阻塞。
    /// 三态而不是 Bool 的原因：同一个副作用工具在一次 agent 任务里常被调用多次，
    /// 只有「允许/拒绝」就意味着弹窗也来 N 次 —— 用户到第三次会开始无脑点「允许」，
    /// 审批反而失去了把关作用。见 AgentService.ApprovalDecision。
    @State private var pendingApproval: PendingApproval?

    struct PendingApproval: Identifiable {
        let id = UUID()
        let call: ChatMessage.ToolCall
        let continuation: CheckedContinuation<ApprovalDecision, Never>
    }

    /// Agent 模式下整个 agent run() 周期共享同一个 assistant 气泡 id。
    /// 第一次 beginIteration 创建新气泡，后续 iteration 复用同一 id → 内容连成一片；
    /// 这样多轮工具调用 / 思考 / 最终答案都看起来是同一条 assistant 消息,
    /// 视觉上不会"分裂"。run() 完成后清空。
    @State private var currentAgentMessageID: UUID?

    /// 消息编辑 / 朗读状态 / 语音输入
    ///
    /// 注意「联网搜索」**不在这里**：它曾经是这个文件里的一份 `@State webSearchOn`，
    /// 与设置页的 `cloudWebSearch` 各存一份、互不知情 —— 聊天页点亮了球，设置页却显示关闭，
    /// 在设置页关掉也关不掉聊天页那份。而且这份内存态在切到本地模型后按钮被隐藏
    /// （原来只在 hasCloudSelection 时显示）却仍然生效，成了「看不见也关不掉的静默联网」。
    /// 现在只有设置里那一份持久化状态，按钮直接读写它。
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
                // v0.3.75:搜索改为 in-content 输入行（searchBarRow），不再用系统 .searchable。
                // 卡顿报告（UIKit-runloop，0.3.74，timeout 375ms，切 tab 时）显示：
                // 导航栏每次布局都要走 UISearchController / _UISearchBarVisualProviderIOS /
                // hidesSearchBarWhenScrolling 的高度计算（37 采样中约三分之一带搜索栏栈帧），
                // 再与 SwiftUI HostingScrollView 的 contentInset→导航栏滚动观察者互相踢，
                // 形成 UIKit↔SwiftUI 反馈环。把搜索栏从导航项上摘掉即打断该环。
                // （v0.3.20-22 的 toggle 教训针对"自定义按钮 ↔ 系统 isPresented 状态机"，
                //  自绘输入行没有这台状态机，showSearch 完全自主，按钮可安全 toggle。）
                if showSearch {
                    searchBarRow
                    if !searchResults.isEmpty {
                        searchResultsList
                    }
                }
                messageList
                    .onChange(of: searchText) { _, newValue in
                        // 防抖：停止输入 200ms 后再执行全量搜索，避免每个按键都扫描所有会话
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard !Task.isCancelled else { return }
                            searchResults = chatStore.search(query: newValue)
                        }
                    }
                    // 搜索收起时清空状态
                    .onChange(of: showSearch) { _, isPresented in
                        if !isPresented {
                            searchText = ""
                            searchResults = []
                            searchFieldFocused = false
                        }
                    }
                if canChat {
                    agentStepsBar
                }
                // 任务清单面板：夹在消息列表与输入栏之间。
                // 为什么在消息列表**下方**而不是浮在消息之上：agent 的正文/工具结果仍要能完整读，
                // 浮层会遮内容。放在输入栏**上方**则是因为它描述的是"接下来要发生什么"，
                // 与输入框同属"操作区"，跟手指所在的区域一致。
                // 空清单时 PlanPanel 内部整块不渲染，这里不需要额外 if。
                PlanPanel(store: todoStore)
                // 从顶栏搬下来的动作（模型 / 助手 / 任务 / 搜索）。
                // 放在 PlanPanel 与输入栏之间：它们都属于"操作区"，与手指所在的位置一致；
                // 而消息列表那一侧保持干净，不被任何常驻控件挤占。
                composerActionsBar
                    .padding(.bottom, 6)
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
            .sheet(isPresented: $showTaskList) {
                TaskListSheet(store: todoStore)
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
            // 任务清单跟对话走：TodoStore 内部按 conversationID 分槽存放，
            // 切对话必须重新绑定，否则上一个对话的清单会留在面板上（"串味"）。
            .onChange(of: chatStore.currentConversationID) { _, id in
                todoStore.bind(conversationID: id)
            }
            // 后台被打断的说明：接到既有的错误提示通道上，用户回来就能看到为什么停了。
            .onChange(of: agentService.interruptionNote) { _, note in
                guard let note, !note.isEmpty else { return }
                errorMessage = note
                agentService.interruptionNote = nil
            }
            // 首次进入页面也要绑一次：onChange 只在值**变化**时触发，
            // 而冷启动直接落在某个已有对话上时 currentConversationID 从未"变过"，
            // 只挂 onChange 的话面板会一直停在未绑定槽位（空的）。
            // 重复调用是安全的：TodoStore.bind 对同一个 id 直接 return。
            .onAppear {
                todoStore.bind(conversationID: chatStore.currentConversationID)
                // 清掉上次残留的灵动岛卡片：App 被强杀时活动**不会自动消失**
                // （它是系统的，不是我们的），用户会一直看到一张永远不动的旧卡片。
                Task { await LiveActivityManager.shared.endAllStale() }
                // 启动时先看有没有"上次被打断、还没续上"的 agent 任务。
                // 放在 onAppear 而不是只在 scenePhase 变化里：冷启动时 scenePhase
                // 本来就已经是 .active，**不会**触发 onChange —— 只挂 onChange 的话，
                // "App 被系统回收后重新打开"这条最常见的路径永远不会续跑。
                resumeInterruptedAgentRunIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { resumeInterruptedAgentRunIfNeeded() }
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
                    // 同时看中心：用户在**灵动岛**上按了按钮时，弹窗这边没有直接改
                    // `pendingApproval`，而它必须自己消失 —— 否则 App 里会留着一个
                    // "还在问你要不要执行"的弹窗，而那个请求早就被答复过了。
                    get: { pendingApproval != nil && approvalCenter.isWaiting },
                    set: { if !$0 {
                        // 自动关闭（如返回上一级）= 拒绝，避免 AgentService 永久阻塞
                        // 走中心恢复：它保证只生效一次 ——
                        // 用户可能在弹窗和灵动岛按钮之间"两个都点到"。
                        AgentApprovalCenter.shared.resolve(.deny)
                        pendingApproval = nil
                    } }
                )
            ) {
                Button("拒绝", role: .destructive) {
                    AgentApprovalCenter.shared.resolve(.deny)
                    pendingApproval = nil
                }
                // 本会话内总是允许：消掉「同一个工具在循环里被反复弹窗」造成的审批疲劳。
                // 作用域是 AgentService 本次 run（一个 agent 任务），不是整个对话 ——
                // 理由见 AgentService.run 里 runApprovedTools 的注释（对话级授权会让
                // 被注入污染过的上下文拥有静默触发副作用工具的能力）。
                Button("本会话内总是允许") {
                    AgentApprovalCenter.shared.resolve(.alwaysForSession)
                    pendingApproval = nil
                }
                Button("允许") {
                    AgentApprovalCenter.shared.resolve(.once)
                    pendingApproval = nil
                }
            } message: {
                if let pending = pendingApproval {
                    // 工具名单独列一行（原来只在标题里，标题过长时会被截断），参数用缩进 JSON 展示；
                    // lineLimit 限制弹窗高度：参数很长时 alert 会被撑破、按钮被挤出屏幕点不到。
                    // 完整参数仍可在气泡里的工具 chip 中展开查看。
                    Text("""
                    此工具会运行真实操作（SSH / MCP 等），是否授权?

                    工具: \(pending.call.name)

                    参数:
                    \(prettyArgumentsForApproval(pending.call.arguments))
                    """)
                    .lineLimit(16)
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
                        // `.equatable()` 让"内容没变的气泡"整棵子树跳过重算。
                        // 为什么值得加：流式期间这个 LazyVStack 每 80ms 重建一次，
                        // 而里面**所有可见气泡**都会被重新求值 body ——
                        // 包括已完成的、内容根本不会变的历史消息（它们要做 Markdown
                        // 重排、工具 chip 展开态、时间戳格式化）。加了它之后只有真正
                        // 变化的那一条（正在流式的那条）会重算。
                        // 依据是 MessageBubble 的 `==` 只比 message / isSpeaking。
                        .equatable()
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
            .glassScrollEdges()
            // 滚离底部时浮现「回到最新」按钮；距底超过一屏的 1/6 才出现，
            // 否则刚发完消息就会闪一下。
            .onScrollGeometryChange(for: Bool.self, of: { geometry in
                geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height) > 160
            }, action: { _, show in
                showScrollToBottom = show
            })
            // 在消息列表上下滑即可收起键盘
            .scrollDismissesKeyboard(.interactively)
            // 点击消息区域任意空白处（含气泡间隙）收起键盘；
            // simultaneousGesture 不阻挡气泡内按钮点击；
            // VoiceOver 开启时跳过，避免与逐条浏览手势冲突（REVIEW m5）
            .simultaneousGesture(TapGesture().onEnded {
                guard !voiceOverEnabled else { return }
                inputFocused = false
            })
            // 回到最新消息：滚远了才出现，玻璃胶囊不遮字。
            .overlay(alignment: .bottomTrailing) {
                if showScrollToBottom {
                    Button {
                        withAnimation(.snappy) { scrollToBottom(proxy) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .padding(.trailing, 18)
                    .padding(.bottom, 4)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(t("回到最新消息"))
                }
            }
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

    /// in-content 搜索输入行（v0.3.75 起替代系统 .searchable，背景见 body 里的注释）。
    /// 展开时渲染在消息列表上方；焦点与清除/取消全部自管，不依赖任何系统状态机。
    private var searchBarRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(t("搜索消息..."), text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($searchFieldFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("清除"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

            Button(t("取消")) {
                showSearch = false
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .onAppear {
            // 打开搜索时把焦点从输入栏挪到搜索框（键盘平滑交接）
            inputFocused = false
            searchFieldFocused = true
        }
    }

    /// 展开搜索且有结果时，显示结果列表（贴在搜索输入行下方）
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

    /// 联网搜索按钮。单独抽出来是因为内联进 `inputBar` 时，那个大表达式里
    /// 三元运算符太多，编译器直接放弃：「unable to type-check this expression
    /// in reasonable time」。拆开之后每个表达式都很小，类型检查立刻通过。
    /// （功能上它就是一个读写设置里 cloudWebSearch 的开关。）
    private var webSearchToolButton: some View {
        let on = chatSettings.settings.cloudWebSearch
        return Button {
            withAnimation(.bouncy) { chatSettings.settings.cloudWebSearch.toggle() }
        } label: {
            Image(systemName: on ? "globe.asia.australia.fill" : "globe.asia.australia")
                .font(.system(size: 17, weight: .semibold))
                .symbolEffect(.bounce, value: on)
                .foregroundStyle(on ? Color.white : Color.green)
                .frame(width: 44, height: 44)
                .background(on ? Color.green : Color.green.opacity(0.15), in: Circle())
                .accessibilityLabel(t("联网搜索"))
        }
        .buttonStyle(.plain)
    }

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
                    // 文件选择按钮（放在图片前面，更符合"先选文件再选图"的认知顺序）
                    DocumentPickerButton(selectedFiles: $selectedFiles) { urls in
                        Task { await importFiles(urls) }
                    }

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
                    // 同文件按钮：选图不需要模型，发送时再校验（v0.3.74）

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

                    // 联网搜索：直接绑定设置里那一份持久化开关，不再另存一份内存态。
                    // 按钮也不再依赖 hasCloudSelection —— 否则切到本地模型后按钮消失，
                    // 用户既看不到它开着、也没法关掉。
                    webSearchToolButton

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

            // 附件待发 chips（v0.3.73）：选中的文件/图片必须看得见、可单个移除。
            // 此前输入区完全没有附件预览 —— 用户选完文件像没反应，以为上传失败。
            if !fileAttachments.isEmpty || !attachments.isEmpty {
                attachmentChips
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

    /// 输入区上方的附件 chips（文件 + 图片），带单个移除
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(fileAttachments) { f in
                    HStack(spacing: 6) {
                        Image(systemName: Self.fileIcon(for: f.mimeType))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.purple)
                        Text(f.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            withAnimation(.snappy) { fileAttachments.removeAll { $0.id == f.id } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
                }
                ForEach(attachments.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        ChipThumbnail(data: attachments[i].data)
                        Button {
                            // 不用 remove(at:)：Swift 6 在此上下文把它判成
                            // Array.remove / RangeReplaceableCollection.remove 二义性。
                            withAnimation(.snappy) {
                                attachments = attachments.enumerated()
                                    .filter { $0.offset != i }.map(\.element)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                }
            }
        }
    }

    /// 文件类型 → SF Symbol 图标
    private static func fileIcon(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.contains("zip") || mimeType.contains("tar") || mimeType.contains("gzip") { return "archivebox" }
        if mimeType.contains("sheet") || mimeType.contains("excel") || mimeType.contains("csv") { return "tablecells" }
        return "doc"
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
        // v0.3.73：权限被拒/引擎起不来时必须有可见反馈（原来静默失败 = "语音用不了"）
        asrService.onError = { msg in
            errorMessage = msg
        }
        asrService.start()
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = !attachments.isEmpty
        // v0.3.73：只选文件不打字也应能发送 —— 原来漏了 fileAttachments，
        // 用户选完文件发送键还是灰的，表现为"文件无法上传"。
        let hasFile = !fileAttachments.isEmpty
        // v0.3.74：不再把 canChat 混进来 —— 没有模型时灰按钮是"点了没反应"，
        // 改为允许按下、sendMessage 里给出"先去装载模型"的明确指引。
        return (hasText || hasImage || hasFile) && !isGenerating
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
        // 顶栏**只留这两个**。原来这里是 6 个按钮（对话列表 / 任务清单 / 助手 / 搜索 /
        // 模型 / 新建），其中模型菜单还带一个**文字标签**（"deepseek · deepseek-chat" 这种），
        // 宽度直接吃掉了 inline 标题 —— 用户反馈"会挡住标题"指的就是它。
        //
        // 分工原则（改动的依据）：顶栏放**和"这一段对话"有关的导航动作**，
        // 底栏放**和"这一句话怎么发出去"有关的动作**（模型 / 助手 / 任务 / 搜索）。
        // 这不是纯粹按好看分的：模型和助手是"发消息前要确认的上下文"，
        // 放在输入框旁边（手指所在的位置）比放在屏幕最上方更贴合使用顺序。
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                chatStore.createNew()
            } label: {
                Image(systemName: "square.and.pencil")
                    .accessibilityLabel(t("新建对话"))
            }
            // 生成期间不能切走对话：流式回写是按「当前对话」定位气泡的
            // （`chatStore.currentOrNew` + firstIndex(where: id)），一旦切了当前对话，
            // 正在生成的 token 就再也写不回原来那条气泡 —— 那条气泡会永远停在「思考中…」，
            // 而且没有任何报错提示。禁掉比静默丢内容好。
            .disabled(isGenerating)
        }
    }

    // MARK: - 输入框上方的动作条（模型 / 助手 / 任务 / 搜索）

    /// 从顶栏搬下来的那批动作。
    ///
    /// 为什么用 `.regularMaterial` 而不是玻璃：本工程在 iOS 26.1 真机上反复验证过
    /// （v0.3.10 / v0.3.20 / v0.3.21 / v0.3.31），**同一 GlassEffectContainer 里相邻的
    /// `.glassEffect` 按钮会视觉粘连成一片**，Apple 文档里的 spacing 语义在那个组合下不生效。
    /// 所以这里沿用工具栏岛已经验证过的方案：一个 Material 胶囊承载一排**普通**按钮 ——
    /// 材质与玻璃按钮不同层，天然独立，不会粘。
    private var composerActionsBar: some View {
        HStack(spacing: 0) {
            // 模型：这一条最关键 —— 它原来是顶栏里最宽的元素（图标 + 文字标签）。
            Menu {
                modelMenuContent
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: modelMenuIcon)
                        .font(.caption2)
                    Text(modelMenuTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // 限宽而不是让它自己撑：模型名可以是 "siliconflow · Qwen/Qwen3-8B"
                        // 这种很长的串，不限宽会把后面三个按钮全挤出去。
                        .frame(maxWidth: 128, alignment: .leading)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(t("选择模型"))：\(modelMenuTitle)")

            divider

            // 助手
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
                HStack(spacing: 5) {
                    Text(assistantStore.current?.emoji ?? "🙂")
                        .font(.caption)
                    Text(assistantStore.current?.name ?? t("助手"))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 84, alignment: .leading)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(t("选择助手"))：\(assistantStore.current?.name ?? "")")

            divider

            // 任务清单。**无条件存在**：常驻面板只在"已经有清单"时才渲染，
            // 所以一个还没触发过它的用户根本不知道这个功能存在 —— 没有清单就没有入口，
            // 没有入口就更不会有清单，闭环锁死。这个按钮把环打开。
            Button {
                showTaskList = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checklist")
                        .font(.caption2)
                    if todoStore.isActive {
                        Text(todoStore.progressText)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    } else {
                        Text("任务")
                            .font(.caption.weight(.medium))
                    }
                }
                .foregroundStyle(todoStore.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("任务清单")

            divider

            // 搜索入口（v0.3.75 起搜索是 in-content 行，showSearch 完全自管，可安全 toggle）
            Button {
                showSearch.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(showSearch ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t("搜索"))
        }
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: .capsule)
        // 整条合成一个无障碍组：四个动作会各自被单独朗读，容器本身不该再被当成一个元素。
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 14)
    }

    /// 分隔线。用 1pt 的 Divider 而不是 Spacer：四个动作紧挨着时，
    /// 没有了图标之间的天然留白，需要一条视觉边界告诉用户"这是四个独立按钮"。
    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 16)
    }

    /// 模型菜单的内容。从原来的顶栏 Menu 里整段搬过来，逻辑一字未改
    /// （云端 Provider 分组 + 本地 GGUF 分组 + 各自的选中态）。
    @ViewBuilder
    private var modelMenuContent: some View {
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

        // 没有可用模型：以前是发送键直接灰掉（点了没反应），
        // 现在按下去给出明确指引；附件/文字都保留不清空。
        guard canChat else {
            errorMessage = "还没有可用的模型：请先到「模型」页装载一个本地模型，或到「服务」页选择云端模型，再发送。你选的附件已保留。"
            return
        }

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
        let files = fileAttachments
        inputText = ""
        attachments = []
        selectedItems = []
        fileAttachments = []
        selectedFiles = []
        inputFocused = false

        // 提示词变量解析（Prompt Variables）
        let modelName = providerStore.hasCloudSelection ? providerStore.currentModel : (llmService.loadedModelName ?? "")
        let providerName = providerStore.currentProvider?.name ?? ""
        let text = PromptVariableResolver.resolve(rawText, model: modelName, providerName: providerName)

        var conv = chatStore.currentOrNew
        conv.messages.append(ChatMessage(role: .user, content: text, images: images, files: files))
        conv.updateTitle()
        conv.modelName = providerStore.hasCloudSelection ? providerStore.selectionText : llmService.loadedModelName
        chatStore.upsert(conv)

        let effectiveSettings = effectiveSettings(from: settings, modelName: modelName, providerName: providerName)

        if isAgentMode {
            // 小模型不支持 Agent：提示并按普通对话发送（v0.3.45）
            guard canUseAgentMode else {
                isAgentMode = false
                errorMessage = "当前模型不支持 Agent 模式（需云端或 ≥3B 本地模型），已按普通对话发送。"
                // ⚠️ 必须传局部 files：fileAttachments 在上面已被清空（line ~966），
                // 传它等于传 []，附件全部静默丢失（v0.3.72 的"文件无法上传"根因）。
                startGeneration(history: Array(conv.messages), settings: effectiveSettings, images: images.compactMap { $0.cgImage }, files: files)
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
            // 申请后台保活：agent 任务可能跑几分钟，用户切出去是常态。
            // 不申请的话进程被挂起、这一轮直接死掉，气泡永远停在「思考中…」且**没有任何报错**。
            // 到期回调里主动取消 —— 体面地停，比被系统杀掉好得多（后者状态是"卡住"）。
            // ⚠️ 两个编译错误都是这里犯的，记下来免得再犯：
            //   1. `AgentService` **没有** `.shared` —— 它是 App 里 `@StateObject` 创建、
            //      经 `environmentObject` 注入的，全局单例并不存在。用手上的 agentService 引用。
            //   2. `generationTask` 是 `Task<Void, Never>`（**struct**，不是 class），
            //      所以不能 `[weak generationTask]`。改用捕获 self 再读属性。
            //      ChatView 是 struct，捕获的是那一刻的副本，而 agentService 是类引用，
            //      副本里指向的还是同一个实例 —— 所以这句赋值确实会落到真实对象上。
            BackgroundTaskKeeper.shared.begin(.generation) { [self] in
                self.generationTask?.cancel()
                self.agentService.interruptionNote =
                    "切到后台的时间用尽，这一轮已暂停。回到 App 后重新发送即可继续。"
            }
            // ⚠️ 这里**不能**写 `[weak self]`：`ChatView` 是 struct 不是 class，
            // weak 只对类生效（同一类错误我在这个文件里已经犯过一次 —— 给 Task 加 weak）。
            // struct 的闭包捕获的是那一刻的副本，而副本里的 agentService / chatStore
            // 都是类引用、指向同一实例，所以行为是对的。
            // 代价是必须显式写 self.（逃逸闭包里的成员访问规则）。
            generationTask = Task { [history, effectiveSettings] in
                defer {
                    self.isGenerating = false
                    self.generationTask = nil
                    BackgroundTaskKeeper.shared.end(.generation)
                }
                await self.performAgentTurn(history: history, settings: effectiveSettings, resuming: nil)
            }
            return
        }

        // 同上：局部 files（清空后的 fileAttachments 是 []，附件会被静默丢弃）
        startGeneration(history: Array(conv.messages), settings: effectiveSettings, images: images.compactMap { $0.cgImage }, files: files)
    }

    // MARK: - 断点续跑

    /// 回到前台 / 冷启动时，检查有没有被打断的 agent 任务，有就自动接着跑。
    ///
    /// 触发点有两个且都必须有：
    ///   · `scenePhase == .active` —— 覆盖"切后台被系统收走、又切回来"；
    ///   · `onAppear` —— 覆盖"App 被回收后重新打开"。冷启动时 scenePhase 本来就是
    ///     `.active`，不会产生 onChange 事件，所以只挂 onChange 会漏掉这条最常见的路径。
    ///
    /// 三种情况**不**续跑，各有理由：
    ///   · 正有一个任务在跑（`isGenerating`）—— 续跑会和它抢同一段对话与同一条气泡；
    ///   · 没有存档 —— 没什么可续的；
    ///   · 续跑次数已达上限 —— 见 `AgentRunCheckpoint.maxAutoResume`。反复续跑会把一个
    ///     在当前环境下根本跑不完的任务变成无限循环，每次都烧电、烧额度。
    ///     到上限时**必须明确告诉用户**，而不是默默放弃（默默放弃正是要根除的那类行为）。
    private func resumeInterruptedAgentRunIfNeeded() {
        guard !isGenerating, generationTask == nil else { return }
        guard let cp = AgentCheckpointStore.shared.load() else { return }

        guard cp.canAutoResume else {
            AgentCheckpointStore.shared.clear()
            errorMessage = "上一轮 agent 任务自动续跑了 \(cp.resumeCount) 次仍被打断（原因：\(cp.reason)），已停止。"
                + "可以重新发送，或把这个任务拆小一点。"
            return
        }

        // 切回那段对话：存档属于哪段对话就写回哪段，
        // 否则续跑的内容会跑到用户当前看的另一段对话里去（串味且极难察觉）。
        if chatStore.currentConversationID != cp.conversationID {
            chatStore.currentConversationID = cp.conversationID
        }
        // 复用原气泡：续跑应该接在同一条 assistant 气泡里，看起来是"接着写"，
        // 而不是新冒出一条"又回答了一次"。
        currentAgentMessageID = cp.bubbleID
        isAgentMode = true

        let modelName = providerStore.hasCloudSelection ? providerStore.currentModel : (llmService.loadedModelName ?? "")
        let providerName = providerStore.currentProvider?.name ?? ""
        let settings = effectiveSettings(from: chatSettings.settings,
                                         modelName: modelName, providerName: providerName)

        let resumed = AgentRunCheckpoint(
            conversationID: cp.conversationID,
            bubbleID: cp.bubbleID,
            history: cp.history,
            iteration: cp.iteration,
            toolCalls: cp.toolCalls,
            startedAt: cp.startedAt,
            reason: cp.reason,
            resumeCount: cp.resumeCount + 1
        )
        // 先把计数写回去：万一这次又被打断，下次读到的就是 +1 后的值，
        // 否则上限永远到不了（每次都从 0 开始续）。
        AgentCheckpointStore.shared.save(resumed)

        isGenerating = true
        BackgroundTaskKeeper.shared.begin(.generation) { [self] in
            self.generationTask?.cancel()
        }
        generationTask = Task { [resumed, settings] in
            defer {
                self.isGenerating = false
                self.generationTask = nil
                BackgroundTaskKeeper.shared.end(.generation)
            }
            await self.performAgentTurn(history: resumed.history, settings: settings, resuming: resumed)
        }
    }

    // MARK: - Agent 一轮任务（首次发送与断点续跑共用同一条路）

    /// 跑完一轮 agent 任务，并把结果落进气泡。
    ///
    /// 为什么把它抽成方法：**断点续跑必须走完全相同的流程** —— 包括审批弹窗、
    /// 后台保活、以及"最终答案一定要能被用户看到"那段回填。
    /// 如果续跑另写一条简化路径，那它就会缺掉审批（敏感工具静默被拒）
    /// 或缺掉回填（答案又被丢掉）—— 而这两件事恰恰都是我们已经踩过的坑。
    /// 所以宁可在首次发送那里多一层调用，也不让两条路分叉。
    private func performAgentTurn(history: [ChatMessage],
                                  settings effectiveSettings: ModelSettings,
                                  resuming: AgentRunCheckpoint?) async {
        // 起一张灵动岛卡片。用户切出去之后**完全不知道 App 还在不在干活**，
        // 只能反复切回来看 —— 这张卡片解决的就是这件事。
        // 它不负责让任务活下去（那是 BackgroundTaskKeeper 与后台会话的事）。
        let liveStartedAt = Date()
        LiveActivityManager.shared.start(
            conversationTitle: chatStore.currentOrNew.title,
            state: .init(title: resuming == nil ? "正在处理你的请求" : "继续未完成的任务",
                         phase: .thinking, step: 0, totalSteps: nil,
                         detail: nil, progress: nil, startedAt: liveStartedAt))

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
                // 阻塞等用户在 chat 里点「允许 / 本会话内总是允许 / 拒绝」。
                // @MainActor self 才能写 @State。
                await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
                    // 交给中心持有：灵动岛的按钮是**另一个进程**渲染、由系统拉起 App 执行的，
                    // 它拿不到这个视图的 @State，只能通过中心找到这个等待中的请求。
                    AgentApprovalCenter.shared.park(callName: call.title ?? call.name, cont)
                    pendingApproval = PendingApproval(call: call, continuation: cont)
                }
            }
        )
        let bubbleId = currentAgentMessageID  // 备份气泡 id,run() 之后会用
        let result = await agentService.run(
            history: history,
            settings: effectiveSettings,
            // 这里传**全部**内置工具（+ MCP / 插件）。
            // 按「设置 → 工具」勾选过滤的动作在 AgentService 里做，且只对本地模型生效 ——
            // 过滤放这里会让云端也只拿到 12 个（用户已反馈此 bug）。
            toolsEnabledTools: BuiltInTools.allTools
                + MCPService.shared.toolDefinitions
                + PluginManager.shared.installedToolDefinitions(),
            llm: llmService,
            bridge: bridge,
            // 断点存档要用：没有这两个 id，续跑时不知道该把内容写回哪条对话的哪条气泡
            conversationID: chatStore.currentOrNew.id,
            bubbleID: bubbleId,
            resuming: resuming
        )
        // run() 退出后清空共享气泡 id,下次发送/agent 时重新创建
        currentAgentMessageID = nil

        // 保证 run() 返回的最终答案**一定能被用户看到**。
        //
        // 这里原来的判据是「剥离 think 之后 bubble 里还有没有可见文本」，为空才回填。
        // 那个判据是错的，而且错得正好落在最常见的收尾形态上：**最后一轮是工具调用**时，
        // bubble 里留着那一轮的原始 JSON 文本 —— 它当然不是空的，于是回填被跳过；
        // 可那段 JSON 在气泡里会被 `cleanDisplayText` 清掉，用户在界面上什么也看不到。
        // 结果就是模型**确实**产出了收尾文字，却被这段判据静默丢弃。
        // 这和"宣布任务完成、实际没有产物"是同一个病。
        if !result.content.isEmpty, let bubbleId {
            var conv = chatStore.currentOrNew
            if let idx = conv.messages.firstIndex(where: { $0.id == bubbleId }) {
                let raw = conv.messages[idx].content
                let stripped = AgentService.stripThinkTags(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let visible = conv.messages[idx].isAgentRound
                    ? AgentService.cleanDisplayText(stripped)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : stripped
                let answer = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if visible.isEmpty || !visible.contains(answer) {
                    conv.messages[idx].content = raw + "\n\n" + result.content
                    chatStore.upsert(conv)
                }
            }
        }

        if !Task.isCancelled {
            maybeAutoTitle()
            maybeAutoExtractMemory()
        }

        // 收卡片。三种收尾状态**必须区分**，因为对用户含义完全不同：
        //   · 正常结束 → 已完成
        //   · 被取消（多半是切后台超时 / 进程被回收）→ **已暂停**，而且回来自动续跑。
        //     用红色"失败"去表示它，用户会以为任务废了然后手动重发 ——
        //     而重发恰好会和自动续跑撞在同一段对话、同一条气泡上。
        //   · 真出错 → 已中断
        let phase: LumenAIActivityAttributes.Phase = Task.isCancelled ? .paused : .done
        let title: String = Task.isCancelled
            ? "已暂停，回到 App 会自动继续"
            : (result.content.isEmpty ? "已完成" : String(result.content.prefix(60)))
        LiveActivityManager.shared.end(state: .init(
            title: title, phase: phase, step: 0, totalSteps: nil,
            detail: Task.isCancelled ? "回到 App 后自动继续" : nil,
            progress: nil, startedAt: liveStartedAt))
        // 兜底：别把一个"永远等不到答复"的授权请求留在中心里，
        // 那会让下一次授权直接卡死（park 时会把旧的按拒绝收掉，但更干净的是这里主动收）。
        AgentApprovalCenter.shared.cancelIfWaiting()
    }

    /// 解析助手绑定 + 提示词变量 + 人格注入 + 提示词策略 → 有效设置
    private func effectiveSettings(from settings: ModelSettings, modelName: String, providerName: String) -> ModelSettings {
        var effective = settings
        let assistant = assistantStore.current
        // 助手的提示词**只在用户真的改过时**才覆盖全局设置。
        //
        // 原来的写法是「助手提示词非空就用它」，而 AssistantStore 保证一定存在一个
        // 默认助手（AIAssistant.default 的 systemPrompt 非空），于是
        // 「设置 → 系统提示词」这个控件**永远不生效** —— 用户改完没有任何反应，
        // 属于典型的不符合用户逻辑。现在与内置默认值相同即视为「未改过」，
        // 回落到全局设置；设置页也会提示当前实际生效的是哪一个。
        let assistantPrompt = (assistant?.systemPrompt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isCustomized = !assistantPrompt.isEmpty
            && assistantPrompt != AIAssistant.default.systemPrompt
        let prompt = isCustomized ? assistantPrompt : settings.systemPrompt
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
    private func startGeneration(history: [ChatMessage], settings: ModelSettings, images: [CGImage], files: [ChatMessage.FileData] = []) {
        isGenerating = true
        // 见上面 agent 那处的说明：切后台要能多活一会儿，到期则主动收尾。
        BackgroundTaskKeeper.shared.begin(.generation) { [self] in
            self.generationTask?.cancel()
        }
        generationTask = Task {
            defer {
                isGenerating = false
                generationTask = nil
                BackgroundTaskKeeper.shared.end(.generation)
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
                    var cloudMessages = llmService.makeCloudMessages(history, settings: settings, files: files)
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
                    stream = llmService.streamChat(history: localHistory, settings: settings, images: images, files: files)
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
        guard !query.isEmpty, settings.cloudWebSearch else { return nil }
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

        startGeneration(history: Array(conv.messages), settings: effective, images: userMsg.images.compactMap { $0.cgImage }, files: [])
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

        startGeneration(history: Array(conv.messages), settings: effective, images: msg.images.compactMap { $0.cgImage }, files: [])
    }

    private func deleteMessage(_ message: ChatMessage) {
        var conv = chatStore.currentOrNew
        conv.messages.removeAll { $0.id == message.id }
        chatStore.upsert(conv)
    }

    private func speakMessage(_ message: ChatMessage) {
        // 分支必须按「点的是不是正在朗读的那一条」判断，而不是「有没有任何一条在朗读」。
        // 原来是后者，而气泡菜单的文字是按前者显示的（MessageBubble: `isSpeaking ? "停止朗读" : "朗读"`），
        // 于是 A 正在读时对 B 点「朗读」，实际发生的事情是「把 A 停掉、B 一个字都不读」——
        // 按钮说它会读 B，它却只是停了 A。
        let isThisOne = speakingMessageID == message.id
        if ttsService.isSpeaking {
            ttsService.stop()
            speakingMessageID = nil
            // 点的就是正在读的那条 → 这次点击的语义就是"停止"，到此结束。
            if isThisOne { return }
            // 点的是别的条 → 停掉旧的，继续往下把这一条读出来。
        }
        // ⚠️ 必须用**和气泡显示同一份**文本。
        //
        // 气泡渲染走的是 `AgentService.cleanDisplayText(visibleContent)`
        // （剔除工具调用 JSON、结束暗号、代码围栏标记），而这里原来直接读
        // `visibleContent` —— 于是屏幕上明明看不到工具调用，朗读却把那段
        // JSON 念了出来。朗读和显示不是同一份文本，是这类"念出奇怪东西"
        // 的通用根因，所以这里直接复用显示用的同一个函数，而不是再写一套清理。
        let text = message.isAgentRound
            ? AgentService.cleanDisplayText(message.visibleContent)
            : message.visibleContent
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
    ///
    /// ⚠️ 缓冲区**必须**是引用类型（见 `tokenBuffer` 的注释）：换成 `@State` 字典的话，
    /// 这一行 `+= token` 每个 token 都会让整个 ChatView 重建一次，节流就白做了。
    private func appendAssistantToken(id: UUID, token: String) {
        tokenBuffer.text[id, default: ""] += token
        let now = Date()
        guard now.timeIntervalSince(tokenBuffer.lastFlush) >= 0.08 else { return }
        // 时间戳也放在盒子里而不是 @State：它同样每次 flush 都被写，
        // 写在 @State 上等于每秒又白白触发 12.5 次全页重建。
        tokenBuffer.lastFlush = now
        flushAgentTokenBuffer(id: id)
    }

    /// 把指定气泡缓冲区里的 token 一次性追加到消息内容。
    private func flushAgentTokenBuffer(id: UUID) {
        guard let buffered = tokenBuffer.text.removeValue(forKey: id), !buffered.isEmpty else { return }
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

    /// 导入外部文件到工作区，并生成 FileData 附件列表
    private func importFiles(_ urls: [URL]) async {
        let fm = FileManagerService.shared
        var loaded: [ChatMessage.FileData] = []
        var failures: [String] = []
        for url in urls {
            do {
                let path = try fm.importExternal(url)
                // 拿到相对路径后，从工作区再 stat 一下拿元数据
                let full = fm.root.appendingPathComponent(path)
                let values = try? full.resourceValues(
                    forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey])
                let mime = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
                let size = Int64(values?.fileSize ?? 0)
                let created = values?.creationDate ?? Date()
                let isText = mime.hasPrefix("text/") || mime == "application/json" ||
                             mime == "application/xml" || path.hasSuffix(".md") || path.hasSuffix(".txt") ||
                             path.hasSuffix(".swift") || path.hasSuffix(".py") || path.hasSuffix(".json")
                loaded.append(ChatMessage.FileData(
                    name: full.lastPathComponent,
                    path: path,
                    mimeType: mime,
                    size: size,
                    createdAt: created,
                    isTextPreviewable: isText
                ))
            } catch {
                // 导入失败记录但不阻断其它文件；最后统一弹给用户看
                // （原来只 print，用户看不到任何失败反馈 —— "文件无法上传"的观感之一）
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // 追加而不是覆盖：分两次选文件时第一次的不丢
        let known = Set(fileAttachments.map(\.path))
        fileAttachments.append(contentsOf: loaded.filter { !known.contains($0.path) })
        if !failures.isEmpty {
            errorMessage = "文件导入失败：\n" + failures.joined(separator: "\n")
        }
        selectedFiles = []
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
        fileAttachments = []
        selectedFiles = []
        inputFocused = false

        var conv = chatStore.currentOrNew
        conv.messages.append(ChatMessage(role: .user, content: "/draw \(prompt)"))
        conv.updateTitle()
        conv.modelName = "\(provider.name) · 生图"
        chatStore.upsert(conv)

        isGenerating = true
        // 云端生图是纯网络等待，切后台被挂起就会白等一场；同样申请保活。
        BackgroundTaskKeeper.shared.begin(.generation) { [self] in
            self.generationTask?.cancel()
        }
        generationTask = Task {
            defer {
                isGenerating = false
                generationTask = nil
                BackgroundTaskKeeper.shared.end(.generation)
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

// MARK: - 流式 token 缓冲区

/// Agent 流式输出的 token 暂存盒。
///
/// 为什么必须是**引用类型**：它被放在 `ChatView` 的 `@State` 里，而 `@State` 只关心
/// 盒子的**身份**。改盒子内部的属性不会让 SwiftUI 重建任何视图 —— 这正是我们要的：
/// 每个 token 都往 `text` 里追加，但**只有 80ms 一次的 flush 写入 chatStore 时才上屏**。
///
/// 反面教材（这就是它存在的原因）：原先直接在 `@State` 上放 `[UUID: String]` 字典，
/// 每个 token 写一次 → 整个 ChatView 重建一次 → agent 跑任务时界面卡到划不动。
///
/// 不标 `@MainActor`：它只被 ChatView 的 main-actor 方法访问，
/// 加隔离反而会让 `@State` 的初始化语法变复杂，收益为零。
final class AgentTokenBuffer {
    /// 每个气泡累积的、还没上屏的原始 token。
    var text: [UUID: String] = [:]
    /// 上次真正刷入气泡的时刻（时间节流用）。同样不能放 `@State`，理由同上。
    var lastFlush: Date = .distantPast
}
