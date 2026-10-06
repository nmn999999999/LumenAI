import SwiftUI

// MARK: - A/B Benchmark 的 UI 入口（阶段 12）
//
// 为什么需要它：`AgentBenchmarkRunner` 本身只是编排逻辑，而工程的性能数字必须在
// **真机 + Release 构建** 上量（Debug 下 Swift 未优化，TTFT/延迟会差一个数量级）。
// 没有 test target，也不该为了跑 benchmark 去加一个 —— 这里给一个设置页里的入口，
// 用**线上同一套** settings / 工具目录 / LLMService 跑，跑完把对比报告就地展示。
//
// 它不改任何线上行为：只在用户主动点「运行」时创建独立的 AgentService 实例。
struct AgentBenchmarkView: View {
    @EnvironmentObject private var llmService: LLMService
    @ObservedObject private var storage = SettingsStorage.shared

    @State private var isRunning = false
    @State private var progressText = ""
    @State private var report: AgentBenchmarkReport?
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("""
                用同一批场景分别跑 baseline（优化全关）与 optimized（优化全开），对比任务成功率、\
                工具轨迹（重复/无效/错误调用、required 覆盖率）、token、TTFT 与 P50/P95 延迟。
                成败判定是场景自己的 BenchmarkContract（必须调用哪些工具 + 答案要满足什么），\
                两个变体走同一份代码 —— 优化不能以降低任务成功率为代价。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                controls

                if let report {
                    Text(report.summaryText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: .rect(cornerRadius: 12))

                    failuresSection
                }
            }
            .padding(14)
        }
        .navigationTitle("A/B Benchmark")
        .navigationBarTitleDisplayMode(.inline)
        // 离开页面即取消：benchmark 会长时间占用模型，留在后台空跑既费电也污染后续测量。
        .onDisappear { runTask?.cancel() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                runTask?.cancel()
                runTask = Task { await run() }
            } label: {
                Label(isRunning ? "运行中…" : "运行 A/B Benchmark", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(isRunning)

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(progressText.isEmpty ? "准备中…" : progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("顺序跑（不并发），避免互相抢占模型；请留在本页，离开会自动停止。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("停止", role: .destructive) { runTask?.cancel() }
            }
        }
    }

    private var failuresSection: some View {
        let samples = report?.samples ?? []
        let failures = samples.filter { !$0.taskSuccess && !$0.verdict.isNotApplicable }
        let notApplicable = samples.filter { $0.verdict.isNotApplicable }
        return VStack(alignment: .leading, spacing: 8) {
            if !notApplicable.isEmpty {
                Text("环境不适用（不计入成功率）：\(notApplicable.map(\.scenarioID).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if failures.isEmpty {
                Text("全部场景达标 ✓")
                    .font(.subheadline.weight(.medium))
            } else {
                Text("未达标场景（\(failures.count)）")
                    .font(.subheadline.weight(.medium))
                ForEach(failures.indices, id: \.self) { i in
                    let s = failures[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.variant.rawValue) · \(s.scenarioID)")
                            .font(.caption.weight(.semibold))
                        Text("调用: \(s.calledTools.isEmpty ? "（无）" : s.calledTools.joined(separator: ", "))"
                             + "（\(s.trajectory.toolCallCount) 次，重复 \(s.trajectory.duplicateCallCount)）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !s.verdict.failureSummary.isEmpty {
                            Text(s.verdict.failureSummary)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !s.answer.isEmpty {
                            Text(String(s.answer.prefix(140)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @MainActor
    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        progressText = ""
        defer {
            isRunning = false
            progressText = ""
        }

        let settings = storage.settings
        // 与 ChatView 发起 agent 时**完全一致**的工具目录：内置全量 + MCP + 已装插件。
        let tools = BuiltInTools.allTools
            + MCPService.shared.toolDefinitions
            + PluginManager.shared.installedToolDefinitions()
        // 外部宇宙（MCP + 插件）：mcp_tool 场景靠它判断"是不是真的调了外部工具"。
        // 一个都没装时该场景判 notApplicable，报告里单独计数，不混进失败率。
        let externalNames = MCPService.shared.toolDefinitions.map(\.name)
            + PluginManager.shared.installedToolDefinitions().map(\.name)

        // 保护真实断点存档：`AgentService.run` 正常结束时会对**全局**断点文件调用 clear()。
        // benchmark 不是用户的真实任务，绝不能顺手删掉用户可能还在等的「续跑」存档。
        // 先快照，跑完原样写回（benchmark 自身不传 conversationID/bubbleID，所以不会写档）。
        let savedCheckpoint = AgentCheckpointStore.shared.load()

        let llm = llmService
        let executor = AgentBenchmarkRunner.agentServiceExecutor(
            settings: settings,
            tools: tools,
            externalToolNames: externalNames,
            llm: { llm })

        let result = await AgentBenchmarkRunner.run(
            onProgress: { text in progressText = text },
            executor: executor)

        if let savedCheckpoint { AgentCheckpointStore.shared.save(savedCheckpoint) }
        if Task.isCancelled { return }
        report = result
        // 同时打到控制台：便于把完整报告贴走（手机上选中复制长文本不方便）。
        print(result.summaryText)
    }
}