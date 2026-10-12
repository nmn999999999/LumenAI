import SwiftUI

/// 终端（Shell）页。
///
/// 为什么要有这个页面：agent 的 `shell` 工具用的就是 `ShellSandbox` 这套受限命令解释器，
/// 但在本页之前，用户既看不到 agent 在沙盒里到底跑了什么，也没法自己敲一条命令验证。
/// 这里把**同一个**沙盒直接接到界面上，并且与 agent 共用同一份 transcript
/// （`ShellTranscript`）—— 手敲的命令和 agent 调用的命令会依次出现在同一个滚动区，
/// 每条都带命令、输出和退出码。
///
/// 边界（如实说明，不要当成本页是真实 Linux）：
/// · 这不是 POSIX shell —— iOS 没有 `/bin/sh` 可调，命令由 ShellSandbox 在 Swift 里解释，
///   路径被限制在 `~/Documents/shellbox` 子树内，能用的命令是内置的那一批。
/// · 与 agent **共用同一个进程级会话**（cwd / env / history 都是单例）：这里跑的命令会
///   真实改动磁盘，也会影响 agent 接下来对相对路径的解析。要另起一份干净状态就点「重置会话」。
/// · 真 Linux 在里面那块 `LinuxSessionPanel`（iSH Linux 模式：真内核 + rootfs + pty）：
///   导入 rootfs → 启动内核 → 进去敲命令。它和这里的沙盒 shell **完全是两条路**，别混。
///   顶部状态如实显示引擎/会话状态，不假装能跑 Linux（rootfs 没导入时会明说）。
struct ShellView: View {

    private struct InfoLine: Identifiable {
        let id = UUID()
        let text: String
    }

    // MARK: - 状态

    /// 终端页自己的说明行（不是命令记录）。命令记录统一在 `ShellTranscript` 里，
    /// 这样 agent 跑的命令也会出现在同一处。
    @State private var infoLines: [InfoLine] = []
    @ObservedObject private var transcript = ShellTranscript.shared

    @State private var input = ""
    @State private var isRunning = false
    @State private var cwd = ShellSandbox.cwd
    /// 本页的输入历史（用于上下翻阅；与 transcript 分开，这里保留的是原文）
    @State private var typedHistory: [String] = []
    @State private var historyCursor: Int? = nil
    @State private var toast: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                LinuxSessionPanel()
                Divider().opacity(0.35)
                terminal
                Divider().opacity(0.35)
                quickBar
                inputBar
            }
            .navigationTitle(t("终端"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .toast($toast)
            .onAppear {
                if infoLines.isEmpty { bootstrap() }
                cwd = ShellSandbox.cwd
            }
        }
    }

    // MARK: - 顶部状态

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(systemImage: "terminal.fill", text: LinuxMode.statusLine,
                      tint: LinuxMode.isLinked ? .green : .orange)
            statusRow(systemImage: "cpu.fill", text: MetalCapability.statusLine,
                      tint: MetalCapability.isAvailable ? .teal : .orange)
            statusRow(systemImage: "folder.fill",
                      text: cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                      tint: .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - 输出区

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(infoLines) { line in
                        Text(line.text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(transcript.entries) { entry in
                        entryView(entry)
                    }

                    // 滚动锚点：新记录追加后滚到底
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .glassScrollEdges()
            .onChange(of: transcript.entries.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private var bottomAnchor: String { "shell-bottom" }

    @ViewBuilder
    private func entryView(_ entry: ShellTranscript.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.source == .agent ? "agent" : t("你"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(entry.source == .agent ? Color.teal.opacity(0.22) : Color.green.opacity(0.18),
                                in: .rect(cornerRadius: 4))
                    .foregroundStyle(entry.source == .agent ? Color.teal : Color.green)
                Text("$ " + entry.command)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(entry.source == .agent ? Color.teal : Color.green)
                    .textSelection(.enabled)
            }

            if !entry.output.trimmingCharacters(in: .newlines).isEmpty {
                Text(entry.output)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(entry.exitCode == 0 ? Color.primary : Color.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if entry.exitCode != 0 {
                Text("退出码: \(entry.exitCode)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 快捷命令

    private let quickCommands = ["help", "pwd", "ls -la", "df -h", "history", "cd ..", "git status"]

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommands, id: \.self) { cmd in
                    Button {
                        input = cmd
                        inputFocused = true
                    } label: {
                        Text(cmd)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.glass)
                    .disabled(isRunning)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 输入行

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.green)

            TextField(t("输入命令…"), text: $input)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($inputFocused)
                .onSubmit { submit() }
                .disabled(isRunning)

            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        // 三元里两侧必须是同一类型：`.secondary` 会先被推成 HierarchicalShapeStyle，
                        // 与 `.green`（Color）对不上。显式写 Color 才能通过类型检查。
                        .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.green)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                if let cmd = recallPrevious() { input = cmd; inputFocused = true }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(typedHistory.isEmpty)

            Button {
                if let cmd = recallNext() { input = cmd; inputFocused = true }
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(typedHistory.isEmpty)

            Menu {
                Button(t("清空输出"), systemImage: "eraser") {
                    transcript.clear()
                    infoLines.removeAll()
                }
                Button(t("复制全部输出"), systemImage: "doc.on.doc") { copyAll() }
                Button(t("重置会话"), systemImage: "arrow.counterclockwise", role: .destructive) { resetSession() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 行为

    private func bootstrap() {
        infoLines.append(.init(text: "LumenAI 终端 · 沙盒 shell（非 POSIX，命令内置，路径限定在 shellbox 内）"))
        infoLines.append(.init(text: "\(LinuxMode.statusLine)｜\(MetalCapability.statusLine)"))
        infoLines.append(.init(text: "上面那块是真 Linux（iSH 内核 + rootfs）。这一块是沙盒 shell。"))
        infoLines.append(.init(text: "输入 help 查看可用命令。这里与 agent 的 shell 工具共用同一个沙盒会话，"))
        infoLines.append(.init(text: "两边跑过的命令都会按顺序出现在下面（agent 的记录带 agent 标记）。"))
    }

    private func submit() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !isRunning else { return }
        input = ""
        historyCursor = nil
        typedHistory.append(cmd)
        isRunning = true
        inputFocused = false

        Task {
            let (text, code) = await ShellSandbox.runWithExitCodeAsync(cmd, timeoutSeconds: 30)
            // 记进共享 transcript（与 agent 同一条通路），滚动区由它驱动。
            ShellTranscript.shared.record(source: .user, command: cmd, output: text, exitCode: code)
            cwd = ShellSandbox.cwd
            isRunning = false
            inputFocused = true
        }
    }

    /// 上翻历史：从最新往更早走。游标在末尾时返回最后一条。
    private func recallPrevious() -> String? {
        guard !typedHistory.isEmpty else { return nil }
        let next: Int
        if let cursor = historyCursor {
            next = max(0, cursor - 1)
        } else {
            next = typedHistory.count - 1
        }
        historyCursor = next
        return typedHistory[next]
    }

    /// 下翻历史：走到末尾就回到"新命令"空档。
    private func recallNext() -> String? {
        guard let cursor = historyCursor else { return nil }
        if cursor >= typedHistory.count - 1 {
            historyCursor = nil
            return ""
        }
        historyCursor = cursor + 1
        return typedHistory[cursor + 1]
    }

    /// 复制当前滚动区内容（说明行 + 全部命令记录），方便贴给别人排查。
    private func copyAll() {
        var flat = infoLines.map(\.text)
        for entry in transcript.entries {
            flat.append("[\(entry.source.rawValue)] $ \(entry.command)")
            if !entry.output.isEmpty { flat.append(entry.output) }
            if entry.exitCode != 0 { flat.append("退出码: \(entry.exitCode)") }
        }
        UIPasteboard.general.string = flat.joined(separator: "\n")
        toast = t("已复制全部输出")
    }

    private func resetSession() {
        ShellSandbox.resetSession()
        cwd = ShellSandbox.cwd
        transcript.clear()
        infoLines.removeAll()
        bootstrap()
        toast = t("已重置会话（cwd / 环境变量 / 历史已清空）")
    }
}
