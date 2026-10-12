import SwiftUI
import UniformTypeIdentifiers

/// 终端页里的「真 Linux 会话」面板：导入 rootfs → 启动内核 → 交互。
///
/// 为什么单独一块：这是**真内核**（iSH Linux 模式），和上面那个沙盒 shell 是两条完全不同的路。
/// 混成一个输入框会让用户以为 `ls` 走的是 Linux —— 不是，沙盒命令由 Swift 解释、路径锁在
/// `shellbox` 里。所以这一块有自己的状态、自己的输入、自己的输出区。
///
/// 边界（如实）：rootfs 不随包发（约 3 MB），要下载或从「文件」导入；终端按**原始字节**显示
/// （做了 ANSI 清洗），没有 VT100 屏幕语义 —— 全屏程序（vim / top）显示会不对。
struct LinuxSessionPanel: View {

    @ObservedObject private var linux = LinuxBoot.shared
    @State private var input = ""
    @State private var showImporter = false
    @State private var errorText: String?

    private let bottomAnchor = "linux-session-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            diagnostics
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.teal.opacity(0.08), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 10)
        .onAppear {
            linux.refresh()
            Task { await linux.refreshDiagnostics() }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.gzip, .archive, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    // 从「文件」选的 URL 是 security-scoped：拷贝前必须显式开权限。
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    _ = await linux.importRootfs(from: url)
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text("真 Linux（iSH 内核）")
                    .font(.caption2.weight(.semibold))
                Spacer()
                if case .running = linux.phase {
                    Text("pid \(linux.sessionPid)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(linux.phase.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            actions
        }
    }

    private var tint: Color {
        switch linux.phase {
        case .unlinked, .failed: return .orange
        case .needsRootfs: return .secondary
        case .ready: return .teal
        case .booting: return .yellow
        case .running: return .green
        case .stopped: return .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch linux.phase {
        case .unlinked:
            Text("这个构建里没有链进 Linux 内核（`scripts/build-ish-libs.sh` 的 ISH_BUILD_LINUX=1 没跑）。")
                .font(.caption2)
                .foregroundStyle(.orange)

        case .needsRootfs:
            HStack(spacing: 8) {
                Button("下载官方 rootfs") {
                    errorText = nil
                    Task { _ = await linux.downloadOfficialRootfs() }
                }
                .buttonStyle(.glass)
                Button("从文件导入…") { showImporter = true }
                    .buttonStyle(.glass)
            }
            .font(.caption)

        case .ready:
            Button("启动 Linux 内核并开会话") {
                errorText = nil
                Task {
                    if await linux.boot() { _ = linux.startShell() }
                }
            }
            .buttonStyle(.glass)
            .font(.caption)

        case .booting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("内核启动中（rootfs 已挂载，等用户空间起来）…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .running:
            HStack(spacing: 8) {
                if linux.sessionPid == 0 {
                    Button("开一个会话") { _ = linux.startShell() }
                        .buttonStyle(.glass)
                        .font(.caption)
                }
                Button("清空输出") { linux.clearSessionOutput() }
                    .buttonStyle(.glass)
                    .font(.caption)
                Button("关闭 Linux", role: .destructive) {
                    Task { _ = await linux.shutdown() }
                }
                .buttonStyle(.glass)
                .font(.caption)
            }

        case .stopped:
            Text("客户机里的用户进程已经全部终止。iSH 没有「卸载内核」的接口（客户机里敲 halt/poweroff 走的是 `exit(0)`，会把整个 App 一起结束掉），所以这里只停客户机、不关内核。要重新启动 Linux 只能重启 App。")
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.caption2).foregroundStyle(.red)
                Button("重试") {
                    linux.refresh()
                    Task { await linux.refreshDiagnostics() }
                }
                    .buttonStyle(.glass)
                    .font(.caption)
            }
        }
    }

    // MARK: - 诊断（内存 / 联网）

    /// 只在内核起来过（含已停止）时显示：这些数都在**内核里**，没起来就没有可看的。
    @ViewBuilder
    private var diagnostics: some View {
        if LinuxMode.isBootedOrStopped {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("诊断").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    if linux.readingDiagnostics {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(linux.mem.takenAt == .distantPast ? "未取数"
                             : linux.mem.takenAt.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        Task { await linux.refreshDiagnostics() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(linux.readingDiagnostics)
                }
                diagnosticLine("网卡", linux.netSummary, ok: linux.netOK)
                diagnosticLine("客户机 DNS", linux.dnsSummary, ok: linux.dnsRC == 0)
                diagnosticLine("客户机内存",
                               linux.mem.hasGuest
                                 ? "已用 \(Self.mb(linux.mem.guestUsed)) / 共 \(Self.mb(linux.mem.guestTotal))"
                                 : "取不到（内核还没建好内存账）",
                               ok: linux.mem.hasGuest)
                diagnosticLine("宿主内存",
                               linux.mem.hostFootprint > 0
                                 ? "footprint \(Self.mb(linux.mem.hostFootprint)) · resident \(Self.mb(linux.mem.hostResident))"
                                 : "—",
                               ok: linux.mem.hostFootprint > 0)
            }
        }
    }

    private func diagnosticLine(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
                .font(.system(size: 10))
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - 会话区

    @ViewBuilder
    private var content: some View {
        if case .running = linux.phase {
            VStack(alignment: .leading, spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(linux.sessionText.isEmpty ? "（等 tty 输出…）" : linux.sessionText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .frame(height: 170)
                    .onChange(of: linux.sessionText.count) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .padding(6)
                .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 8))

                HStack(spacing: 8) {
                    Text("#").font(.system(.caption, design: .monospaced)).foregroundStyle(.green)
                    TextField("Linux 命令（进 /bin/sh）", text: $input)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit(sendLine)
                    Button(action: sendLine) {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .disabled(input.isEmpty)
                }
            }
        }
    }

    private func sendLine() {
        let line = input
        input = ""
        linux.send(line)
    }
}
