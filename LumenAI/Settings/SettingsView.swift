import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var llmService: LLMService
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var theme: LumenAIApp.ThemeObserver
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var storage = SettingsStorage.shared

    @State private var showDeleteConfirm = false
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
                VStack(alignment: .leading, spacing: 20) {
                    apiModeCard
                    generationCard
                    displayCard
                    memoryCard
                    systemPromptCard
                    FeaturesCard
                    cloudStorageCard
                    updateCard
                    searchCard
                    sshCard
                    moduleSettingsCard
                    aboutCard
                    dangerZone
                }
                .padding(14)
            }
            .background(theme.current.pageBackground(for: colorScheme))
            .scrollEdgeEffectStyle(.hard, for: .top)
            .navigationTitle("设置")
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                focusedField = nil
            }
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
                        sliderRow("温度", value: $storage.settings.apiTemperature, in: 0...2)
                        stepperRow("最大 Token", value: $storage.settings.apiMaxTokens, in: 256...16384, step: 256)
                        
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

                sliderRow("温度 (temperature)", value: $storage.settings.temperature, in: 0...1.5)
                sliderRow("Top-P", value: $storage.settings.topP, in: 0.1...1)
                stepperRow("Top-K", value: $storage.settings.topK, in: 1...100, step: 5)
                stepperRow("最大生成 Token", value: $storage.settings.maxTokens, in: 256...8192, step: 256)
                stepperRow("上下文长度", value: $storage.settings.contextLength, in: 1024...8192, step: 1024)

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
                SectionHeader(title: "内存优化", systemImage: "memorychip")

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

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
            }
        }
    }

    // MARK: - 语言 / 联网搜索 / 朗读 / 变量

    private var FeaturesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "语言 / 朗读 / 搜索", systemImage: "globe")

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

                // 云端联网搜索
                Toggle(isOn: $storage.settings.cloudWebSearch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("云端联网搜索"))
                            .font(.subheadline)
                        Text(t("发送消息时自动搜索互联网并注入上下文"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.blue)

                Divider()

                // 朗读引擎
                Picker(t("朗读引擎"), selection: $storage.settings.ttsEngine) {
                    Text(t("系统 TTS")).tag("system")
                    Text(t("网络 TTS")).tag("network")
                }
                .pickerStyle(.segmented)

                if storage.settings.ttsEngine == "network" {
                    HStack {
                        Text(t("网络音色")).font(.subheadline)
                        Spacer()
                        TextField("alloy", text: $storage.settings.ttsVoiceName)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 140)
                    }
                    Text("使用当前云端 Provider 的 OpenAI 兼容 /audio/speech 接口；不可用时自动回退系统 TTS。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        .overlay(alignment: .bottom) {
            if let s3Toast {
                Text(s3Toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.bottom, 12)
            }
        }
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
                            Text("发现新版本 \(updater.latestTag ?? "")" + (updater.isGray ? "（灰度）" : ""))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(updater.isGray ? .orange : .green)
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
                                    Label("下载新版 IPA", systemImage: "arrow.down.circle.fill")
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
                        Text("侧载应用无法自动替换安装：下载 IPA 后请用全能签/自签方式重新安装。")
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
                    }
                }
            }
        }
    }
}
