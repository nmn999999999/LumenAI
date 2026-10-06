import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var llmService: LLMService
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var theme: LumenAIApp.ThemeObserver
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var storage = SettingsStorage.shared
    @ObservedObject private var toolStore = ToolSettingsStore.shared
    @ObservedObject private var assistantStore = AssistantStore.shared

    @State private var showDeleteConfirm = false
    /// Kokoro 语音模型删除确认（约 175 MB，删了要重下）
    @State private var showKokoroDeleteConfirm = false
    /// 「Agent 智能体」卡片展示的屏幕自动化能力矩阵（现查现显，与提示词同源）。
    /// 空 = 尚未探测完成，卡片显示"正在检测…"。
    @State private var agentCaps: [ComputerCapability] = []
    @FocusState private var focusedField: Field?
    
    private enum Field: Hashable {
        case apiEndpoint, apiKey, apiModel, systemPrompt
    }

    // MARK: - 系统语音选项（动态列出设备已安装的语音，取每种语言质量最高者）

    private struct VoiceOption: Identifiable {
        let id: String   // AVSpeechSynthesisVoice.identifier 或语言代码
        let label: String
    }

    /// 设备上可用的系统语音。每种语言保留质量最高的一档（premium > enhanced > default），
    /// 归并成精简但够用的列表。前缀命中才展示，避免把几十种冷门语言全铺出来。
    private static var systemVoiceOptions: [VoiceOption] {
        let preferredPrefixes = ["zh-", "yue-", "cmn-", "en-", "ja-", "ko-", "fr-", "de-", "es-", "it-", "pt-", "ru-"]
        let installed = AVSpeechSynthesisVoice.speechVoices()
        // language → best(identifier, name, quality)
        var bestByLang: [String: (id: String, name: String, quality: Int)] = [:]
        for v in installed {
            guard preferredPrefixes.contains(where: { v.language.lowercased().hasPrefix($0) }) else { continue }
            let q: Int = v.quality == .premium ? 3 : (v.quality == .enhanced ? 2 : 1)
            if let cur = bestByLang[v.language], cur.quality >= q { continue }
            bestByLang[v.language] = (v.identifier, v.name, q)
        }
        let langPriority = ["zh-CN", "zh-TW", "zh-HK", "cmn-CN", "en-US", "en-GB", "en-AU", "en-IN",
                            "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"]
        let sortedLangs = bestByLang.keys.sorted { a, b in
            let ai = langPriority.firstIndex(of: a) ?? 99
            let bi = langPriority.firstIndex(of: b) ?? 99
            return ai == bi ? a < b : ai < bi
        }
        return sortedLangs.compactMap { lang -> VoiceOption? in
            guard let v = bestByLang[lang] else { return nil }
            let quality = v.quality >= 3 ? " · 高级" : (v.quality == 2 ? " · 增强" : "")
            let displayLang = lang == "cmn-CN" ? "zh-CN" : lang
            return VoiceOption(id: v.id, label: "\(v.name) (\(displayLang))\(quality)")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // LazyVStack（v0.3.73）：设置页 15 张卡全部急切布局时，body 求值 +
                // layout 会把主线程顶过 461ms（UIKit-runloop 卡顿报告里的最大嫌疑，
                // SettingsView.body.getter 占了 46 个采样里的一半）。懒加载后
                // 屏幕外的卡片不参与首帧计算，切页/滚动都轻了。
                LazyVStack(alignment: .leading, spacing: 20) {
                    apiModeCard
                    generationCard
                    displayCard
                    memoryCard
                    longTermMemoryCard
                    systemPromptCard
                    toolsCard
                    agentCard
                    FeaturesCard
                    cloudStorageCard
                    updateCard
                    searchCard
                    sshCard
                    moduleSettingsCard
                    diagnosticsCard
                    aboutCard
                    dangerZone
                }
                .padding(14)
            }
            .background(theme.current.pageBackground(for: colorScheme))
            .glassScrollEdges()
            .navigationTitle("设置")
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                focusedField = nil
            }
            // 记忆可能在聊天过程中被 AI 改过（note 工具），每次进设置页都重新扫一次磁盘，
            // 否则这里显示的是上次进页面时的旧列表。
            .onAppear { noteStore.refresh() }
        }
    }

    // MARK: - API 模式

    private var apiModeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "API 模式", systemImage: "cloud")
                
                Toggle(isOn: $storage.settings.apiEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用外部 API")
                            .font(.subheadline)
                        Text("使用 OpenAI 兼容 API 获取最大性能（如 GPT-4o、Claude、DeepSeek 等）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.purple)
                .onChange(of: storage.settings.apiEnabled) { _, newValue in
                    if newValue {
                        llmService.enableApiMode(settings: storage.settings)
                    } else {
                        llmService.unload()
                    }
                }
                
                if storage.settings.apiEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        // API 地址
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API 端点").font(.subheadline)
                            TextField("https://api.openai.com/v1/chat/completions", text: $storage.settings.apiEndpoint)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(.quaternary, in: .rect(cornerRadius: 10))
                                .font(.caption)
                                .focused($focusedField, equals: .apiEndpoint)
                        }
                        
                        // API Key
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API 密钥").font(.subheadline)
                            SecureField("sk-...", text: $storage.settings.apiKey)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(.quaternary, in: .rect(cornerRadius: 10))
                                .font(.caption)
                                .focused($focusedField, equals: .apiKey)
                        }
                        
                        // 模型名称
                        VStack(alignment: .leading, spacing: 4) {
                            Text("模型名称").font(.subheadline)
                            TextField("gpt-4o-mini", text: $storage.settings.apiModel)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(.quaternary, in: .rect(cornerRadius: 10))
                                .font(.caption)
                                .focused($focusedField, equals: .apiModel)
                        }
                        
                        // API 参数
                        // 原来是「温度」，与「生成参数」里的本地温度同名不同义，
                        // 用户不知道哪个生效。改成带作用域的名字。
                        sliderRow("API 温度", value: $storage.settings.apiTemperature, in: 0...2)
                        stepperRow("API 最大 Token", value: $storage.settings.apiMaxTokens, in: 256...16384, step: 256)
                        
                        Text("支持所有 OpenAI 兼容 API（OpenAI、Anthropic、DeepSeek、本地 Ollama 等）。密钥仅存储在本地，不会上传。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - 生成参数（液态玻璃卡片 + 玻璃滑块）

    private var generationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "生成参数", systemImage: "slider.horizontal.3")

                sliderRow("本地温度 (temperature)", value: $storage.settings.temperature, in: 0...1.5)
                Text(t("仅本地模型生效；API 模式用「API 模式」卡片里的 API 温度。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                sliderRow("Top-P", value: $storage.settings.topP, in: 0.1...1)
                stepperRow("Top-K", value: $storage.settings.topK, in: 1...100, step: 5)
                // 与上面的「API 最大 Token」同名会让人不知道哪个生效，两处都带上作用域。
                stepperRow("本地最大生成 Token", value: $storage.settings.maxTokens, in: 256...8192, step: 256)
                stepperRow("上下文长度", value: $storage.settings.contextLength, in: 1024...8192, step: 1024)
                // 生成上限可以设得比上下文还大 —— 那不是更长的回答，而是无效设置。
                // 这里直接说清楚，省得用户以为调大就「回答更长」。
                if storage.settings.maxTokens >= storage.settings.contextLength {
                    Label("本地最大生成 Token 已不小于上下文长度：实际可用长度受上下文限制，建议调小生成上限或调大上下文。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Divider()

                // Metal 自动加速（Apple 原生 Metal 后端，按设备内存防 OOM）
                Toggle(isOn: $storage.settings.useMetalAuto) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Metal 自动加速")
                            .font(.subheadline)
                        Text("按设备内存自动决定 GPU offload 层数，兼顾速度与稳定（防显存不足）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.teal)

                if storage.settings.useMetalAuto {
                    let ram = LLMService.deviceRAMGB
                    let rec = LLMService.recommendedGpuLayers(contextLength: storage.settings.contextLength)
                    HStack {
                        Text("当前状态")
                            .font(.subheadline)
                        Spacer()
                        Text(rec > 0 ? "设备 \(ram)GB · 自动 offload \(rec) 层" : "设备 \(ram)GB · 纯 CPU（内存较小，Metal 易不足）")
                            .font(.caption)
                            .foregroundStyle(rec > 0 ? .green : .orange)
                    }
                } else {
                    stepperRow("GPU 层数 (0=纯CPU)", value: $storage.settings.gpuLayers, in: 0...64, step: 4)
                }

                Divider()

                // KV 缓存量化（Q8_0）：KV 内存减半，长上下文/大模型更省内存
                Toggle(isOn: $storage.settings.kvCacheQuantize) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KV 缓存量化 (Q8_0)")
                            .font(.subheadline)
                        Text("KV 缓存内存减半，可支撑更长上下文/更大模型；质量损失很小。需重新加载模型生效")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.indigo)

                Text("参数在下次对话时生效。上下文越长占用内存越高；自动模式下长上下文会自动降低 GPU 层数防 OOM。实测速度会显示在每条回复下方（⚡ tok/s）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 显示设置

    private var displayCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "显示设置", systemImage: "eye")

                Toggle(isOn: $storage.settings.showThinking) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示思考过程")
                            .font(.subheadline)
                        Text("展示模型的 <think> 标签内容（推理模型如 DeepSeek-R1、Qwen3 的思考过程）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.blue)

                Toggle(isOn: $storage.settings.showToolCalls) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示工具调用")
                            .font(.subheadline)
                        Text("展示 Agent 模式下工具调用的参数和结果")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)

                // 主题色切换：5 套配色实时预览
                VStack(alignment: .leading, spacing: 8) {
                    Text("主题色")
                        .font(.subheadline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(AppTheme.allCases, id: \.rawValue) { t in
                                Button {
                                    theme.current = t
                                } label: {
                                    VStack(spacing: 6) {
                                        Circle()
                                            .fill(t.accentColor)
                                            .frame(width: 32, height: 32)
                                            .overlay(
                                                Circle().strokeBorder(
                                                    theme.current == t ? Color.primary : Color.clear,
                                                    lineWidth: 2
                                                )
                                            )
                                            .shadow(color: t.accentColor.opacity(0.4), radius: 4)
                                        Text(t.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(theme.current == t ? .primary : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - 内存优化

    private var memoryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // 明确是 RAM（内存），与「工具」卡片里的跨对话「记忆」不是一回事
                SectionHeader(title: "内存优化（RAM）", systemImage: "memorychip")

                Toggle(isOn: $storage.settings.useMmap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内存映射加载 (mmap)")
                            .font(.subheadline)
                        Text("开启后模型文件映射到虚拟内存，仅访问的页面才加载到RAM，大幅减少内存占用。关闭可提升推理速度但占用更多内存。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
            }
        }
    }

    // MARK: - 长期记忆（note 工具）

    @ObservedObject private var noteStore = NoteStore.shared
    // memory 工具的存储（与注入 prompt 的是同一份）。分开观察会导致：工具写进去了，
    // 这张卡片不刷新，用户以为 AI 没记住 —— 而记忆这种东西必须"看得见"才敢信。
    @ObservedObject private var personaStore = PersonaStore.shared
    @State private var showClearMemoryConfirm = false
    @State private var expandedNote: String?

    /// 跨对话记忆的查看 / 删除界面。
    ///
    /// 补这一块的原因：`note` 是这个 App 的核心能力，但在此之前它**只有写、没有界面** ——
    /// 笔记被直接写成 `Documents/agent_notes/*.txt`，界面上没有任何地方能看到 AI 记住了什么，
    /// 也没有任何办法删掉。两个具体后果：
    ///   1. 用户在「设置 → 工具」里关掉 note 之后，已有记忆就彻底失管；
    ///   2. 「删除全部对话记录」走的是 chatStore.deleteAll()，**碰不到**这些笔记 ——
    ///      用户以为清干净了，AI 其实还记得全部。这是隐私问题，不只是体验问题。
    private var longTermMemoryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "长期记忆", systemImage: "brain.head.profile")
                    Spacer()
                    let memCount = personaStore.memory.count
                    if memCount > 0 || !noteStore.notes.isEmpty {
                        Text("\(memCount) 条自动注入 · \(noteStore.notes.count) 条笔记")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── memory：每轮对话都会注入 prompt 的那部分（有条数/长度上限）──
                VStack(alignment: .leading, spacing: 8) {
                    Text("自动注入：每次对话都带上的用户事实与偏好。AI 可用 `memory` 工具自己增删，这里能看到并纠正。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if personaStore.memory.isEmpty {
                        Text("暂无。AI 在对话里主动记住、或自动提炼出的内容会出现在这里。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(personaStore.memory) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.content)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button(role: .destructive) {
                                    personaStore.deleteEntry(id: entry.id.uuidString)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .padding(.bottom, 4)

                Divider()

                // ── note：不进 prompt、按需读取的笔记本（原有区块）──
                if noteStore.notes.isEmpty {
                    Text("还没有笔记。在对话里让 AI「记住…」时会写到这里（note 工具）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("AI 跨对话记住的内容。这里可以逐条查看、删除，也可以全部清空 —— 注意「删除全部对话记录」不会动这里。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(noteStore.notes) { note in
                        noteRow(note)
                    }

                }

                // 放在 if/else 之外：笔记为空但自动注入记忆不为空时，也得能清空。
                if !personaStore.memory.isEmpty || !noteStore.notes.isEmpty {
                    Button(role: .destructive) {
                        showClearMemoryConfirm = true
                    } label: {
                        Label("清空全部记忆", systemImage: "trash")
                            .font(.caption)
                    }
                }
            }
        }
        .confirmationDialog(
            "清空全部长期记忆？",
            isPresented: $showClearMemoryConfirm,
            titleVisibility: .visible
        ) {
            Button("全部清空", role: .destructive) {
                personaStore.memory = []
                noteStore.deleteAll()
            }
            Button(t("取消"), role: .cancel) {}
        } message: {
            Text("AI 将不再记得这些内容（自动注入的记忆与笔记都会清空），且无法恢复。对话记录不受影响。")
        }
    }

    private func noteRow(_ note: NoteStore.Note) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedNote == note.name },
            set: { expandedNote = $0 ? note.name : nil }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) {
                    noteStore.delete(name: note.name)
                    if expandedNote == note.name { expandedNote = nil }
                } label: {
                    Label("删除这条记忆", systemImage: "trash")
                        .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(note.name).font(.subheadline)
                Spacer()
                Text("\(note.characters) 字")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }

    // MARK: - 系统提示词

    // MARK: - 工具（可开关，总数上限不变）

    /// 「Agent 智能体」卡片：Agent 优化开关 + 思考预算 + 屏幕自动化能力状态。
    ///
    /// 为什么必须有这张卡：`AgentOptimizations` 的四项优化（reasoning 控制 / 工具路由 /
    /// 结果压缩 / 历史压缩）和思考预算此前**没有任何设置入口** —— 代码里只有
    /// `.optimized` / `.baseline` 两档，线上永远是全开，用户既看不到也关不掉。
    /// 现在每一项都落到 `ModelSettings`，由这张卡读写，`ChatView` 发起 run 时
    /// 用 `AgentOptimizations.from(settings:)` 还原成优化集合。
    ///
    /// 右上角的 capability 状态行**现查** `ShortcutEngine.capabilities()`：
    /// 这是模型在提示词里看到的同一份能力矩阵，用户在这儿看到的若与模型不一致，
    /// 就说明两边读的不是同一个真源。
    private var agentCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Agent 智能体", systemImage: "cpu")
                    Spacer()
                    Text(agentCapabilityBadge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("控制 Agent 循环的行为。关掉某项会回到该功能上线前的老行为，用于排查问题或省 token。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                agentToggleRow(
                    isOn: $storage.settings.agentReasoningControl,
                    title: "思考预算与早停",
                    caption: "限制单段思考长度（超预算即强制进动作）、检测重复推理、产出工具调用后立即停止生成。关掉则放任模型一直想。")
                agentToggleRow(
                    isOn: $storage.settings.agentToolRouting,
                    title: "工具路由 + 紧凑目录",
                    caption: "按请求挑出相关工具、用紧凑 schema 渲染，省 tool schema token。关掉则每次全量下发详细目录。")
                agentToggleRow(
                    isOn: $storage.settings.agentResultReduction,
                    title: "工具结果压缩",
                    caption: "按工具类型分流压缩工具返回，错误优先保留。关掉则原文回填（上下文涨得快）。")
                agentToggleRow(
                    isOn: $storage.settings.agentHistoryCompaction,
                    title: "历史压缩（Task State）",
                    caption: "把旧的工具交互压成一份任务状态，避免长会话反复重编码。关掉则保留全部原始往返。")

                Divider()

                // 思考预算：收紧 ReasoningBudgetController 的阶梯上限（256→512→1024→2048 逐级放宽）
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("思考预算上限")
                            .font(.subheadline)
                        Spacer()
                        Text("\(storage.settings.agentThinkBudgetTokens) tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.purple)
                    }
                    Picker("思考预算上限", selection: $storage.settings.agentThinkBudgetTokens) {
                        Text("256（最快）").tag(256)
                        Text("512").tag(512)
                        Text("1024").tag(1024)
                        Text("2048（默认）").tag(2048)
                    }
                    .pickerStyle(.segmented)
                    Text("单段思考允许消耗的 token 上限。每次动作（工具调用/回答）之后重新从最低档起算：先在小预算内出动作，确实想不清楚才逐级放宽到上限。数值越小思考越短、越早进工具。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // 屏幕自动化（phone 工具）能力：现查现显，与提示词里的能力矩阵同源
                VStack(alignment: .leading, spacing: 6) {
                    Text("屏幕自动化能力（phone 工具）")
                        .font(.subheadline)
                    if agentCaps.isEmpty {
                        Text("正在检测…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(agentCaps, id: \.line) { cap in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: agentStatusIcon(cap.status))
                                    .font(.caption2)
                                    .foregroundStyle(agentStatusColor(cap.status))
                                    .frame(width: 14)
                                Text(cap.line)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("以上是模型在提示词里看到的同一份能力矩阵。tap/swipe/type 在合规版不可用 —— 需要合成触控请在「软件更新」里切到 Tap 通道并重新安装。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            agentCaps = await ShortcutEngine.capabilities()
        }
    }

    /// 单个 Agent 开关行：左标题+说明，右 Toggle，绑定到 `ModelSettings` 的一个 Bool 字段。
    private func agentToggleRow(isOn: Binding<Bool>, title: String, caption: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.purple)
    }

    private func agentStatusIcon(_ status: ComputerCapabilityStatus) -> String {
        switch status {
        case .supported: return "checkmark.circle.fill"
        case .restricted: return "exclamationmark.circle.fill"
        case .requiresSpecialEnvironment: return "sparkles"
        case .unsupported: return "xmark.circle.fill"
        }
    }

    private func agentStatusColor(_ status: ComputerCapabilityStatus) -> Color {
        switch status {
        case .supported: return .green
        case .restricted: return .orange
        case .requiresSpecialEnvironment: return .purple
        case .unsupported: return .secondary
        }
    }

    private var agentCapabilityBadge: String {
        if agentCaps.contains(where: { $0.kind == .tap && $0.status.isAttemptable }) {
            return "Tap 可用"
        }
        return ShortcutEngine.Variant.displayName
    }

    /// 内置工具的选择界面。
    ///
    /// 存在的原因：`allTools` 有 33 个，而本地模型按 `prefix(12)` 取**声明顺序**的前 12 个，
    /// 于是 `note`（跨对话记忆的唯一接口，排第 19）和 `web_search`（第 21）都被截掉 ——
    /// 本地模型根本看不到记忆工具。这里保持上限 12 不变，把选择权交给用户。
    private var toolsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "工具", systemImage: "wrench.and.screwdriver")
                    Spacer()
                    Text("已启用 \(toolStore.count)/\(toolStore.limit)")
                        .font(.caption)
                        .foregroundStyle(toolStore.isFull ? .orange : .secondary)
                }

                Text("本地模型只喂前 \(toolStore.limit) 个工具 —— 再多会占满上下文、导致指令漂移。note 是跨对话记忆的唯一接口，默认已开启。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(toolStore.enabledNames, id: \.self) { name in
                    toolToggleRow(name)
                }

                if !toolStore.disabledNames.isEmpty {
                    DisclosureGroup("更多工具（\(toolStore.disabledNames.count)）") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(toolStore.disabledNames, id: \.self) { name in
                                toolToggleRow(name)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.subheadline)
                }

                HStack {
                    Button("恢复默认清单") { toolStore.resetToDefault() }
                        .font(.caption)
                    Spacer()
                    if toolStore.isFull {
                        Text("已达上限，先关掉一个才能再开")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// 按 baseURL 片段找到用户已经配好的那家 Provider，用作预设的一键绑定。
    /// 找不到就返回 nil —— 只填模型与音色，让用户自己选服务，
    /// 而不是硬编一个 id（用户可能压根没配过那家）。
    private func matchingProviderID(forBaseURL hint: String) -> String? {
        guard !hint.isEmpty else { return nil }
        return ProviderStore.shared.providers
            .first { $0.baseURL.lowercased().contains(hint.lowercased()) }?
            .id.uuidString
    }

    private func toolToggleRow(_ name: String) -> some View {
        let def = BuiltInTools.allTools.first { $0.name == name }
        let enabled = toolStore.isEnabled(name)
        return Toggle(isOn: Binding(
            // get 里现读 store，别捕获快照 —— 达上限被拒绝时开关必须保持在原位
            get: { toolStore.isEnabled(name) },
            set: { _ = toolStore.setEnabled(name, $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.subheadline, design: .monospaced))
                if let d = def?.description, !d.isEmpty {
                    Text(d)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .tint(.green)
        // 未启用且已达上限时置灰：直接拒绝比静默顶掉别的工具更容易理解
        .disabled(!enabled && toolStore.isFull)
    }

    private var systemPromptCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "系统提示词", systemImage: "text.quote")
                TextField(
                    "例如：你是一个有帮助的AI助手…",
                    text: $storage.settings.systemPrompt,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .padding(10)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                .focused($focusedField, equals: .systemPrompt)

                // 让用户看得见「当前实际生效的是哪一个」——
                // 否则改完这里的提示词没反应时，用户完全无从判断原因。
                if let a = assistantStore.current,
                   !a.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   a.systemPrompt != AIAssistant.default.systemPrompt {
                    Label("当前由助手「\(a.name)」的提示词覆盖，此处不会生效",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("当前生效：以上全局提示词。若某个助手自定义了提示词，则以该助手的为准。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 语言 / 联网搜索 / 朗读 / 变量

    private var FeaturesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // 去掉「搜索」：搜索相关的开关已归到「搜索服务」卡片，避免两张卡片
                // 都叫搜索却各放一半设置。
                SectionHeader(title: "语言 / 朗读", systemImage: "globe")

                // 语言
                HStack {
                    Text(t("语言")).font(.subheadline)
                    Spacer()
                    Picker(t("语言"), selection: $storage.settings.language) {
                        Text(t("中文")).tag("zh")
                        Text(t("English")).tag("en")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }

                Divider()

                // 朗读引擎
                Picker(t("朗读引擎"), selection: $storage.settings.ttsEngine) {
                    Text(t("系统")).tag("system")
                    Text(t("本地·轻量")).tag("kokoro")
                    Text(t("本地·高音质")).tag("cosyvoice")
                    Text(t("网络")).tag("network")
                }
                .pickerStyle(.segmented)

                if storage.settings.ttsEngine == "network" {
                    // 用哪家服务来合成 —— 这是这次新加的，之前只能"用当前对话的那家"。
                    HStack {
                        Text(t("语音服务")).font(.subheadline)
                        Spacer()
                        Picker(t("语音服务"), selection: $storage.settings.ttsProviderID) {
                            Text(t("跟对话用同一家")).tag("")
                            ForEach(Array(ProviderStore.shared.providers.enumerated()), id: \.offset) { _, p in
                                Text(p.name).tag(p.id.uuidString)
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    Text("跟对话用同一家时，如果那家不支持 /audio/speech（比如 DeepSeek），会自动回退系统 TTS 并提示。想用网络音色的话，在这里单独选一家支持 TTS 的。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 音色预设：省掉"手打模型名和音色名"这一步。
                    // 这些名字（模型 + 音色）都是各家文档里的原文，打错一个字符就是 400，
                    // 而错误提示通常只有一句"invalid request"，很难看出是名字写错。
                    HStack {
                        Text(t("快速预设")).font(.subheadline)
                        Spacer()
                        Menu(t("选择")) {
                            ForEach(TTSPresets.all) { preset in
                                Button("\(preset.providerHint) · \(preset.label)") {
                                    storage.settings.ttsModel = preset.model
                                    storage.settings.ttsVoiceName = preset.voice
                                    // 预设里带服务地址时，顺手把 TTS 服务指到匹配的那家
                                    if let pid = matchingProviderID(forBaseURL: preset.baseURLHint) {
                                        storage.settings.ttsProviderID = pid
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        Text(t("网络音色")).font(.subheadline)
                        Spacer()
                        TextField("alloy", text: $storage.settings.ttsVoiceName)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 140)
                    }
                    HStack {
                        Text(t("语音模型")).font(.subheadline)
                        Spacer()
                        TextField("tts-1", text: $storage.settings.ttsModel)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 200)
                    }
                    if let err = TTSService.shared.lastTTSError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if storage.settings.ttsEngine == "kokoro" {
                    kokoroTTSCard
                } else if storage.settings.ttsEngine == "cosyvoice" {
                    cosyVoiceTTSCard
                } else {
                    HStack {
                        Text(t("系统语音")).font(.subheadline)
                        Spacer()
                        Picker(t("系统语音"), selection: $storage.settings.ttsVoice) {
                            Text(t("跟随 App 语言")).tag("")
                            ForEach(Self.systemVoiceOptions) { opt in
                                Text(opt.label).tag(opt.id)
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    Text("会自动列出设备已安装的系统语音（含增强/高级音色）；空选项表示用 App 当前语言的默认音色。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // 提示词策略
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("提示词策略").font(.subheadline)
                        Spacer()
                        Picker("提示词策略", selection: $storage.settings.promptStrategy) {
                            ForEach(PromptStrategy.allCases, id: \.rawValue) { s in
                                Text(s.displayName).tag(s.rawValue)
                            }
                        }
                        .frame(maxWidth: 210)
                    }
                    Text("自动：本地 ≤3B 小模型用简洁提示词；云端轻量模型用标准；云端旗舰（GPT-4o/Claude/Gemini Pro 等）用深度专业提示词。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // 提示词变量
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("提示词变量")).font(.subheadline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            variableChip("{model}")
                            variableChip("{provider}")
                            variableChip("{date}")
                            variableChip("{time}")
                            variableChip("{datetime}")
                        }
                    }
                    Text("在系统提示词或助手中使用，发送时自动替换为当前模型名 / Provider / 日期时间。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func variableChip(_ name: String) -> some View {
        Text(name)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)
    }

    // MARK: - Kokoro 本地神经 TTS

    @ObservedObject private var kokoroManager = KokoroTTSManager.shared
    @ObservedObject private var cosyManager = CosyVoiceTTSManager.shared
    /// 是否一并下载可选的 461MB 克隆增强包
    @State private var cosyIncludeOptional = false
    @State private var cosySelfTest: KokoroSelfTest = .idle
    @ObservedObject private var cosyVoiceStore = CosyVoiceVoiceStore.shared
    /// 订阅 TTS 服务：试听要读它的 lastDiagnostic（诊断结论）。
    /// 原来这里是直接读 `TTSService.shared.lastTTSError` 的静态调用，
    /// 那个值变了界面不会重绘 —— 诊断信息写出来了也看不见。
    @ObservedObject private var tts = TTSService.shared
    @State private var showVoiceImporter = false

    /// 「测试本地语音」的状态
    enum KokoroSelfTest: Equatable {
        case idle, running, ok
        case failed(String)
    }
    @State private var kokoroSelfTest: KokoroSelfTest = .idle

    /// CosyVoice3 卡片。与 Kokoro 卡片的区别不在样式，而在**必须先说清能不能跑**：
    /// 这是 0.5B 的 MLX 模型，内存不足时会「下完却加载不起来」，
    /// 所以设备判定放在最上面，不满足时连下载按钮都不给。
    private var cosyVoiceTTSCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "CosyVoice3 本地语音", systemImage: "waveform.badge.mic")

            // ── 设备能力 ──
            let verdict = LocalVoiceCapability.verdict(for: .cosyVoice)
            HStack(spacing: 8) {
                Image(systemName: verdict.canUse ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(verdict.canUse ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verdict.canUse ? "你的设备可以运行" : "你的设备无法运行")
                        .font(.subheadline)
                    Text(LocalVoiceCapability.summary)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let msg = verdict.message {
                Text(msg).font(.caption2)
                    .foregroundStyle(verdict.canUse ? .orange : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if verdict.canUse {
                // ── 状态 / 下载 ──
                switch cosyManager.state {
                case .ready:
                    Label("CosyVoice3 模型已就绪", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.green)
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在加载引擎（首次较慢，需要编译 Metal 着色器）…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                case .downloading(let p, let file):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: p)
                        Text("\(Int(p * 100))% · \(file)").font(.caption2).foregroundStyle(.secondary)
                    }
                case .failed(let msg):
                    Text(msg).font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                case .idle:
                    Text("尚未下载。模型约 740MB（必需）+ 461MB（可选）。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                let missingCount = CosyVoiceTTSManager.missingFiles().count
                if case .downloading = cosyManager.state {
                    EmptyView()
                } else if missingCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $cosyIncludeOptional) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("一并下载音色克隆增强包（+461MB）").font(.caption)
                                Text("没有它也能克隆，但相似度上限约 0.83；有了它换情绪也不丢音色。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            cosyManager.download(includeOptional: cosyIncludeOptional)
                        } label: {
                            Label("下载 CosyVoice3 模型", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                    }
                }

                // ── 音色克隆 ──
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("音色克隆").font(.subheadline).fontWeight(.medium)
                    Text("给一段 5~20 秒的清晰人声，之后朗读就用这个音色。不设置则用模型自带音色。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if cosyVoiceStore.hasReference {
                        HStack(spacing: 8) {
                            Label(String(format: "已设置参考音频（%.1f 秒）", cosyVoiceStore.referenceSeconds),
                                  systemImage: "waveform.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Spacer()
                            Button(role: .destructive) {
                                cosyVoiceStore.clear()
                            } label: { Text("移除").font(.caption) }
                        }
                        if let hint = cosyVoiceStore.durationHint {
                            Text(hint).font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("尚未设置参考音频，当前使用模型自带音色。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if let err = cosyVoiceStore.lastImportError {
                        Text(err).font(.caption2).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Button {
                            showVoiceImporter = true
                        } label: {
                            Label(cosyVoiceStore.hasReference ? "更换参考音频" : "选择参考音频",
                                  systemImage: "waveform.badge.plus")
                                .font(.caption)
                        }
                        Button {
                            // 直接合成一句让用户当场听到克隆效果 ——
                            // 「设置完了却不知道像不像」是这类功能最常见的挫败点。
                            //
                            // ⚠️ 必须走 `previewCosyVoice` 而不是全局 `speak()`：
                            // `speak()` 按 `settings.ttsEngine` 分发，引擎选的是 Kokoro
                            // 或系统时，在这里点「试听」测的**根本不是 CosyVoice**。
                            // 用户看到「点了没声音」，而真实原因是被测的是另一个引擎。
                            tts.previewCosyVoice("你好，这是克隆后的声音，听起来像吗？")
                        } label: {
                            Label("试听", systemImage: "play.circle")
                                .font(.caption)
                        }
                        .disabled(missingCount > 0 || tts.isSpeaking)
                    }

                    // ── 试听诊断 ──
                    // 「点了没声音」至少有三种互不相同的原因：引擎没跑起来 /
                    // 模型合成出来的就是静音 / 合成正常但播放没出声。
                    // 不把实测结果摆出来，用户和我们都只能猜。
                    if let diag = tts.lastDiagnostic {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上次试听").font(.caption2).foregroundStyle(.secondary)
                            Text(diag)
                                .font(.caption2)
                                .foregroundStyle(diag.contains("静音") || diag.contains("失败")
                                                 || diag.contains("抛错") || diag.contains("没走到")
                                                 ? .red : .green)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .fileImporter(isPresented: $showVoiceImporter,
                              allowedContentTypes: [.audio],
                              allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { cosyVoiceStore.importReference(from: url) }
                    case .failure(let error):
                        // 用户取消不算错误，只有真正的失败才提示
                        let ns = error as NSError
                        if ns.code != NSUserCancelledError {
                            cosyVoiceStore.setImportError("选择文件失败：\(error.localizedDescription)")
                        }
                    }
                }

                // ── 真机自检 ──
                // 与 Kokoro 那个按钮同样的理由：文件齐全 ≠ 引擎能加载。
                // CosyVoice3 还多一层风险（MLX 需要真实 Metal 设备），所以更需要它。
                HStack(spacing: 8) {
                    Button {
                        cosySelfTest = .running
                        Task {
                            do {
                                _ = try await CosyVoiceTTSManager.shared.loadEngine()
                                cosySelfTest = .ok
                            } catch {
                                cosySelfTest = .failed(error.localizedDescription)
                            }
                        }
                    } label: {
                        Text("测试 CosyVoice3").font(.caption)
                    }
                    .disabled(missingCount > 0)
                    switch cosySelfTest {
                    case .idle:
                        Text("会真的加载引擎并合成一句话").font(.caption2).foregroundStyle(.secondary)
                    case .running:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("加载中…").font(.caption2).foregroundStyle(.secondary)
                        }
                    case .ok:
                        Label("引擎加载成功", systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                    case .failed(let msg):
                        Text(msg).font(.caption2).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("这台设备上建议改用「本地·轻量」（Kokoro）或系统语音 —— 它们对内存的要求低得多。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var kokoroTTSCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 这个卡片原本没有标题，只有一个状态 Label，用户看不出它与上面
            // 「语言 / 朗读」里的「朗读引擎 → 本地神经 TTS」是同一套功能。
            SectionHeader(title: "Kokoro 本地语音", systemImage: "waveform")
            // 模型状态 / 下载
            switch kokoroManager.state {
            case .ready:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("本地语音模型已就绪", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                        Spacer()
                        Button(role: .destructive) {
                            showKokoroDeleteConfirm = true
                        } label: {
                            Text(t("删除模型")).font(.caption)
                        }
                    }

                    // 「真的加载一次」按钮。
                    //
                    // 为什么必须有它：用户报过"切了本地 TTS 但放不出声"，
                    // 而"文件都在"和"引擎能真的加载起来"是两件事 ——
                    // 文件齐全也可能因为内存不足、原生库缺失、模型文件损坏而加载失败。
                    // 原来界面上只显示"模型已就绪"（那只是**文件校验**的结论），
                    // 用户据此以为一切正常，实际合成时才发现不行，而且失败信息还很小。
                    // 这个按钮直接把 `KokoroTTSManager.engine()` 调一次，如实报结果。
                    HStack(spacing: 8) {
                        Button {
                            kokoroSelfTest = .running
                            Task {
                                do {
                                    _ = try KokoroTTSManager.engine()
                                    kokoroSelfTest = .ok
                                } catch {
                                    kokoroSelfTest = .failed(error.localizedDescription)
                                }
                            }
                        } label: {
                            Text("测试本地语音").font(.caption)
                        }
                        switch kokoroSelfTest {
                        case .idle:
                            Text("点一下会真的加载引擎并合成一句话，用来确认能出声")
                                .font(.caption2).foregroundStyle(.secondary)
                        case .running:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("正在加载引擎…").font(.caption2).foregroundStyle(.secondary)
                            }
                        case .ok:
                            Label("引擎加载成功，可以出声", systemImage: "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(.green)
                        case .failed(let msg):
                            Label("加载失败：\(msg)", systemImage: "xmark.octagon.fill")
                                .font(.caption2).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // ── 试听按钮（强制走 Kokoro，不看全局引擎设置）──
                    HStack(spacing: 8) {
                        Button {
                            // 直接合成一句让用户当场听到效果
                            TTSService.shared.previewKokoro("你好，这是 Kokoro 本地语音的试听效果。")
                        } label: {
                            Label("试听", systemImage: "play.circle")
                                .font(.caption)
                        }
                        .disabled(kokoroManager.state == .downloading || TTSService.shared.isSpeaking)

                        switch kokoroSelfTest {
                        case .idle:
                            Text("点一下会真的加载引擎并合成一句话，用来确认能出声")
                                .font(.caption2).foregroundStyle(.secondary)
                        case .running:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("正在加载引擎…").font(.caption2).foregroundStyle(.secondary)
                            }
                        case .ok:
                            Label("引擎加载成功，可以出声", systemImage: "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(.green)
                        case .failed(let msg):
                            Label("加载失败：\(msg)", systemImage: "xmark.octagon.fill")
                                .font(.caption2).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let err = TTSService.shared.lastTTSError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .downloading:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("正在下载语音模型（约 175 MB）…").font(.subheadline)
                        Spacer()
                        Button {
                            kokoroManager.cancelDownload()
                        } label: {
                            Text(t("取消")).font(.caption)
                        }
                    }
                    ProgressView(value: kokoroManager.progress)
                        .tint(.blue)
                    Text(String(
                        format: "%@ · %.0f%%",
                        kokoroManager.currentFile.isEmpty ? "Kokoro int8" : kokoroManager.currentFile,
                        kokoroManager.progress * 100
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button {
                        kokoroManager.startDownload()
                    } label: {
                        Text(t("重试下载")).font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            case .idle:
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        kokoroManager.startDownload()
                    } label: {
                        Label("下载本地语音模型（约 175 MB）", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("Kokoro 神经网络语音：离线、自然、支持中英混合朗读；首次使用需下载模型（支持断点续传），删除后可重新下载。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // 音色选择（按语言分组）
            HStack {
                Text(t("音色")).font(.subheadline)
                Spacer()
                Picker(t("音色"), selection: $storage.settings.ttsKokoroVoice) {
                    ForEach(KokoroVoices.grouped) { group in
                        Section(group.name) {
                            ForEach(group.items) { v in
                                Text(v.label).tag(v.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: 260)
            }

            // 语速
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(t("语速")).font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1f×", storage.settings.ttsSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $storage.settings.ttsSpeed, in: 0.5...2.0, step: 0.1) {
                    Text(t("语速"))
                }
            }
            Text("53 个音色（中文 8 个 + 英/日/西/法等），支持中英文混读；合成在设备本地完成，无需联网。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        // 删除约 175 MB 的模型后要重新下载几分钟，和「删除全部对话」一样属于该确认的操作。
        .confirmationDialog(
            "删除本地语音模型？",
            isPresented: $showKokoroDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(t("删除模型"), role: .destructive) {
                kokoroManager.deleteModel()
            }
            Button(t("取消"), role: .cancel) {}
        } message: {
            Text("将删除已下载的约 175 MB 模型文件；再次使用需要重新下载（支持断点续传）。")
        }
    }

    // MARK: - 云存储 / 屏幕常亮 / 人格记忆

    private var cloudStorageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "云存储 / 屏幕常亮", systemImage: "externaldrive")

                // 屏幕常亮
                Toggle(isOn: $storage.settings.keepScreenOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("生成时保持屏幕常亮")
                            .font(.subheadline)
                        Text("防止长回复时锁屏中断（keep screen on）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.purple)

                Divider()

                // 人格与记忆入口
                NavigationLink {
                    PersonaView()
                } label: {
                    HStack {
                        Label("世界观 / 记忆 / 指令", systemImage: "brain.head.profile")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                // S3 备份
                VStack(alignment: .leading, spacing: 10) {
                    Text("S3 云备份（AWS / MinIO / COS / OSS）")
                        .font(.subheadline.weight(.medium))
                    TextField("端点 https://s3.amazonaws.com", text: $storage.settings.s3Endpoint)
                        .textFieldStyle(.plain)
                        .padding(9)
                        .background(.quaternary, in: .rect(cornerRadius: 9))
                        .font(.caption)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 10) {
                        TextField("Bucket", text: $storage.settings.s3Bucket)
                            .textFieldStyle(.plain)
                            .padding(9)
                            .background(.quaternary, in: .rect(cornerRadius: 9))
                            .font(.caption)
                        TextField("Region", text: $storage.settings.s3Region)
                            .textFieldStyle(.plain)
                            .padding(9)
                            .background(.quaternary, in: .rect(cornerRadius: 9))
                            .font(.caption)
                            .frame(maxWidth: 120)
                    }
                    HStack(spacing: 10) {
                        TextField("Access Key", text: $storage.settings.s3AccessKey)
                            .textFieldStyle(.plain)
                            .padding(9)
                            .background(.quaternary, in: .rect(cornerRadius: 9))
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Secret Key", text: $storage.settings.s3SecretKey)
                            .textFieldStyle(.plain)
                            .padding(9)
                            .background(.quaternary, in: .rect(cornerRadius: 9))
                            .font(.caption)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await uploadToS3() }
                        } label: {
                            if isS3Uploading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("备份到 S3", systemImage: "arrow.up.to.line")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            Task { await downloadFromS3() }
                        } label: {
                            if isS3Downloading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("从 S3 恢复", systemImage: "arrow.down.to.line")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("备份内容与本地导出一致（会话 + Provider + 助手）。密钥仅存本机。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(
            "从 S3 恢复将覆盖当前数据，确认继续？",
            isPresented: $showS3RestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("确认恢复", role: .destructive) {
                if let pkg = pendingS3Restore {
                    BackupService.restore(pkg, chatStore: chatStore)
                    s3Toast = "恢复成功"
                }
            }
            Button(t("取消"), role: .cancel) {}
        }
        // ⚠️ 这里原来**没有自动消失**：`s3Toast` 被赋值后一直挂着，
        // 「恢复成功」会停到用户触发下一个动作为止 —— 而同一个文件里其它提示
        // 是会消失的，用户会以为卡住了。改用统一的 `.toast` 后行为与另外两页一致。
        .toast($s3Toast)
    }

    // MARK: - S3 动作

    @State private var isS3Uploading = false
    @State private var isS3Downloading = false
    @State private var showS3RestoreConfirm = false
    @State private var pendingS3Restore: BackupService.BackupPackage?
    @State private var s3Toast: String?

    private func s3Config() -> S3Client.Config? {
        let s = storage.settings
        guard !s.s3Endpoint.isEmpty, !s.s3Bucket.isEmpty,
              !s.s3AccessKey.isEmpty, !s.s3SecretKey.isEmpty
        else {
            s3Toast = "S3 配置不完整"
            return nil
        }
        return S3Client.Config(
            endpoint: s.s3Endpoint, bucket: s.s3Bucket,
            accessKey: s.s3AccessKey, secretKey: s.s3SecretKey, region: s.s3Region
        )
    }

    private static let s3BackupKey = "backups/localai-latest.json"

    private func uploadToS3() async {
        guard let config = s3Config() else { return }
        isS3Uploading = true
        defer { isS3Uploading = false }
        guard let fileURL = BackupService.makeBackupFile(chatStore: chatStore),
              let data = try? Data(contentsOf: fileURL)
        else {
            s3Toast = "备份生成失败"
            return
        }
        do {
            try await S3Client.upload(config: config, objectKey: Self.s3BackupKey, data: data)
            s3Toast = "已上传: \(Self.s3BackupKey)"
        } catch {
            s3Toast = "上传失败: \(error.localizedDescription.prefix(80))"
        }
    }

    private func downloadFromS3() async {
        guard let config = s3Config() else { return }
        isS3Downloading = true
        defer { isS3Downloading = false }
        do {
            let data = try await S3Client.download(config: config, objectKey: Self.s3BackupKey)
            let pkg = try BackupService.parseBackup(data: data)
            pendingS3Restore = pkg
            showS3RestoreConfirm = true
        } catch {
            s3Toast = "恢复失败: \(error.localizedDescription.prefix(80))"
        }
    }

    // MARK: - 软件更新（滚动更新引导）

    @ObservedObject private var updater = UpdateCheckerService.shared

    private var updateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "软件更新", systemImage: "arrow.triangle.2.circlepath")

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("当前版本 \(updater.currentVersion)")
                                .font(.subheadline)
                            if updater.isTap {
                                Text("Tap 通道")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.purple)
                            }
                            if updater.isGray {
                                Text("灰度通道")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        if updater.hasUpdate {
                            Text("发现新版本 \(updater.latestTag ?? "")" + (updater.isGray ? "（灰度）" : (updater.isTap ? "（Tap）" : "")))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(updater.isGray ? .orange : (updater.isTap ? .purple : .green))
                        } else if updater.lastChecked {
                            if let err = updater.lastError {
                                // 检查失败与「已是最新」分开显示，避免误导
                                Text("检查失败：\(err)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else if let pct = updater.grayPercent {
                                Text("已是最新版本 · 灰度中（\(pct)% 设备可见新版本）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("已是最新版本")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button {
                        Task { await updater.check() }
                    } label: {
                        if updater.isChecking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("检查更新", systemImage: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updater.isChecking)
                }

                Toggle(isOn: $storage.settings.autoCheckUpdate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动时自动检查")
                            .font(.subheadline)
                        Text("每天最多检查一次，发现新版后在此提示")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.blue)

                // 微信式灰度测试：开启后始终能看到并下载灰度版本
                Toggle(isOn: $storage.settings.grayOptIn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("参与灰度测试")
                            .font(.subheadline)
                        Text("抢先体验新版本；灰度版未上 GitHub Release，仅通过灰度通道下发")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)
                .onChange(of: storage.settings.grayOptIn) { _, _ in
                    Task { await updater.check() }
                }

                // 更新通道选择：稳定版 / Tap 增强版（决定「下载新版 IPA」拿的是哪个包）
                Toggle(isOn: $storage.settings.updateTapChannel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("更新到 Tap 增强版")
                            .font(.subheadline)
                        Text("开启后下载 LumenAI-Tap 包（含合成触控能力）；关闭则下载稳定版包")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.purple)
                .onChange(of: storage.settings.updateTapChannel) { _, _ in
                    Task { await updater.check() }
                }

                if updater.hasUpdate {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if let notes = updater.releaseNotes, !notes.isEmpty {
                            Text(String(notes.prefix(400)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                        HStack(spacing: 10) {
                            if let url = updater.downloadURL {
                                Button {
                                    #if canImport(UIKit)
                                    UIApplication.shared.open(url)
                                    #endif
                                } label: {
                                    Label(updater.isTap ? "下载 Tap 版 IPA" : "下载新版 IPA",
                                          systemImage: "arrow.down.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                            }
                            if let url = updater.releaseURL {
                                Button {
                                    #if canImport(UIKit)
                                    UIApplication.shared.open(url)
                                    #endif
                                } label: {
                                    Label("查看发布页", systemImage: "safari")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                        Text("侧载应用无法自动替换安装：下载 IPA 后请用全能签/自签方式重新安装。"
                             + (updater.isTap ? "当前通道：Tap 增强版。" : "当前通道：稳定版（可在上方开关切换）。"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - 搜索服务

    private var searchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "搜索服务", systemImage: "magnifyingglass")

                Picker("搜索引擎", selection: $storage.settings.searchEngine) {
                    Text("网页搜索（内置）").tag("web")
                    Text("维基百科（内置）").tag("wikipedia")
                }
                .pickerStyle(.segmented)

                Text("""
                供 Agent 的 web_search 工具使用。网页搜索由设备直接请求 Bing（失败时依次回退 DuckDuckGo、维基百科），无需自建任何服务。
                """)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                // 原本在「语言 / 朗读 / 搜索」卡片里，与这里的「搜索引擎」是同一主题
                // 却分在两处、卡片名都带「搜索」，用户不知道去哪找。归到一处。
                Toggle(isOn: $storage.settings.cloudWebSearch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("联网搜索"))
                            .font(.subheadline)
                        // 原来说明写的是「与上面的搜索引擎无关」—— 那是错的：
                        // 自动注入走的就是 SearchService，而它读的正是上面这个 searchEngine，
                        // 所以选了「维基百科」之后自动注入也只会查维基。说明必须与行为一致。
                        Text(t("发送消息时自动搜索并注入上下文；使用上面选择的同一个搜索引擎，这里只控制是否自动注入"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.blue)
            }
        }
    }

    // MARK: - 关于

    // MARK: - SSH 配置（Agent ssh 工具默认连接）

    private var sshCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "SSH 连接", systemImage: "terminal")

                VStack(alignment: .leading, spacing: 4) {
                    Text("主机").font(.subheadline)
                    TextField("例如 192.168.1.10 或 example.com", text: $storage.settings.sshHost)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.quaternary, in: .rect(cornerRadius: 10))
                        .font(.caption)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("端口").font(.subheadline)
                        TextField("22", value: $storage.settings.sshPort, format: .number)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary, in: .rect(cornerRadius: 10))
                            .font(.caption)
                            .keyboardType(.numberPad)
                    }
                    .frame(maxWidth: 110)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("用户名").font(.subheadline)
                        TextField("root", text: $storage.settings.sshUser)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary, in: .rect(cornerRadius: 10))
                            .font(.caption)
                    }
                }

                Picker("认证方式", selection: $storage.settings.sshAuthType) {
                    Text("密码").tag("password")
                    Text("私钥").tag("key")
                }
                .pickerStyle(.segmented)

                if storage.settings.sshAuthType == "password" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("密码").font(.subheadline)
                        SecureField("登录密码", text: $storage.settings.sshPassword)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary, in: .rect(cornerRadius: 10))
                            .font(.caption)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("私钥 (PEM)").font(.subheadline)
                        TextEditor(text: $storage.settings.sshPrivateKey)
                            .font(.caption.monospaced())
                            .frame(minHeight: 110, maxHeight: 200)
                            .padding(6)
                            .background(.quaternary, in: .rect(cornerRadius: 10))
                            .overlay(alignment: .topLeading) {
                                if storage.settings.sshPrivateKey.isEmpty {
                                    Text("粘贴 -----BEGIN ... PRIVATE KEY----- 内容")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(10)
                                }
                            }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("私钥口令（可选）").font(.subheadline)
                        SecureField("留空表示无口令", text: $storage.settings.sshPassphrase)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary, in: .rect(cornerRadius: 10))
                            .font(.caption)
                    }
                }

                Text("供 Agent 的 ssh 工具使用：在对话中让 AI「在服务器上执行 xxx」即可。账号信息仅存于本机，私钥不会上传。工具参数可临时覆盖主机/端口/用户/命令。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 模块设置（远程 UI：插件下发的配置卡片，不换底包即可更新）

    @ObservedObject private var pluginManager = PluginManager.shared

    @ViewBuilder
    private var moduleSettingsCard: some View {
        let withUI = pluginManager.modules.filter { $0.manifest.settingsUI?.isEmpty == false }
        if !withUI.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "模块设置", systemImage: "puzzlepiece.extension.fill")
                    ForEach(withUI) { module in
                        VStack(alignment: .leading, spacing: 10) {
                            Label("\(module.manifest.name) · v\(module.manifest.version)", systemImage: "puzzlepiece.extension")
                                .font(.subheadline.weight(.semibold))
                            // 插件下发的远程 UI（JSON 声明式，改配置界面不用换底包）
                            RemoteUIView(module: module, groups: module.manifest.settingsUI ?? [])
                        }
                    }
                }
            }
        }
    }

    // MARK: - 开发者诊断

    /// Agent Runtime 的 A/B benchmark 入口（阶段 12）。
    /// 放在 `aboutCard` 之前、默认不打扰：普通用户不需要它，但性能优化必须能在真机上复现对比。
    private var diagnosticsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "开发者诊断", systemImage: "gauge.with.dots.needle.67percent")
                Text("对比 baseline 与 optimized 的工具命中率、成功率、reasoning/tool token、TTFT 与 P50/P95 延迟。建议在 Release 构建上运行以取得真实数字。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    AgentBenchmarkView()
                } label: {
                    HStack {
                        Label("Agent 性能 A/B Benchmark", systemImage: "chart.bar.xaxis")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "关于", systemImage: "info.circle")
                infoRow("推理引擎", "llama.cpp (GGUF) + mtmd 多模态")
                infoRow("API 支持", "OpenAI / Gemini / Claude / 任意兼容端点")
                infoRow("界面", "SwiftUI · Liquid Glass (iOS 26+)")
                infoRow("隐私", "本地模式：全部推理在本机完成，无网络上传")
                infoRow("项目", "LumenAI · 原生 Swift 本地大模型客户端")
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.subheadline)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 危险区

    private var dangerZone: some View {
        GlassCard(cornerRadius: 18) {
            VStack(spacing: 12) {
                SectionHeader(title: "数据管理", systemImage: "trash")
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除全部对话记录", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .confirmationDialog(
                    "确定删除所有对话？此操作不可撤销。",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("全部删除", role: .destructive) {
                        chatStore.deleteAll()
                        // 任务清单按对话 id 分槽存在 Documents/agent_todos.json，与对话记录
                        // 是两份互不知情的存储。不在这里一起清，那些用户自己写下的任务内容
                        // （「整理妈妈的病理报告」之类）会永远留在磁盘上，而对话已经没了 ——
                        // 界面上再没有任何入口能看到或删掉它们。这与 NoteStore 当初
                        // 「只有写、没有界面」是同一类问题，所以顺手一并堵上。
                        TodoStore.shared.deleteAll()
                    }
                    Button(t("取消"), role: .cancel) {}
                } message: {
                    // 这句必须写：长期记忆不在这里，用户按下确认时以为"全清了"，
                    // 而 AI 仍然记得所有笔记 —— 那是最容易被当成 bug 的行为。
                    Text("只删除对话记录和它们的任务清单。AI 的长期记忆（笔记）不会受影响，需要的话请到上方「长期记忆」卡片里清空。")
                }
            }
        }
    }
}
