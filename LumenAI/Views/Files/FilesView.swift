import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @State private var path: [String] = []
    @State private var entries: [FileManagerService.Entry] = []
    @State private var toast: String?
    @State private var errorMessage: String?
    @State private var editingFile: String?
    @State private var editingText = ""
    @State private var showImporter = false
    /// v0.3.73：新建文件夹/新建文件/重命名统一走一个居中弹窗。
    /// 原来用系统 .alert + TextField —— 输入框被系统排在标题和按钮之间、
    /// 不在弹窗中间，用户反馈"输入框没在弹窗中间"。改为自定义 overlay 居中卡片。
    @State private var nameDialog: NameDialog?
    @State private var dialogText = ""
    @FocusState private var dialogFocused: Bool
    @State private var pendingDelete: String?
    @State private var shareURL: URL?

    private enum NameDialog: Identifiable {
        case newFolder
        case newFile
        case rename(old: String)

        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .newFile: return "newFile"
            case .rename(let old): return "rename:\(old)"
            }
        }
    }

    private var currentPath: String { path.joined(separator: "/") }

    var body: some View {
        NavigationStack {
            List {
                if path.isEmpty {
                    logsSection
                }
                fileSection
            }
            .scrollContentBackground(.hidden)
            .glassScrollEdges()
            .navigationTitle(path.isEmpty ? t("文件") : path.last!)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable { reload() }
            .onAppear { reload() }
            .onChange(of: path) { reload() }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                let rel = try FileManagerService.shared.importExternal(
                    url, preferredPath: currentPath.isEmpty ? nil : currentPath + "/" + url.lastPathComponent)
                toast = "已导入 \(rel)"
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        // v0.3.73：自定义居中输入弹窗（替代系统 .alert，见 nameDialog 注释）
        .overlay {
            if let dialog = nameDialog {
                nameDialogOverlay(dialog)
            }
        }
        .confirmationDialog(
            t("删除？"),
            isPresented: .init(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { target in
            Button(t("删除"), role: .destructive) {
                do {
                    try FileManagerService.shared.delete(target)
                    pendingDelete = nil
                    toast = "已删除"
                    reload()
                } catch { errorMessage = error.localizedDescription }
            }
            Button(t("取消"), role: .cancel) { pendingDelete = nil }
        } message: { target in
            Text("「\((target as NSString).lastPathComponent)」将被永久删除。")
        }
        .alert(t("操作失败"), isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: Binding(
            get: { editingFile.map { IdentifiedString(id: $0) } },
            set: { if $0 == nil { editingFile = nil } }
        )) { item in
            FileEditorSheet(
                path: item.id,
                initialText: editingText,
                onSaved: {
                    editingFile = nil
                    toast = "已保存"
                    reload()
                },
                onCancel: { editingFile = nil }
            )
        }
        .sheet(isPresented: .init(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .toast($toast)
    }

    private var fileSection: some View {
        Section {
            if entries.isEmpty {
                Text(path.isEmpty
                     ? "工作区为空。可从右上角导入文件，或让 AI 创建与编辑。"
                     : "此目录为空。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.path) { entry in
                row(entry)
            }
        } header: {
            if !path.isEmpty {
                Text(path.joined(separator: " / "))
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: FileManagerService.Entry) -> some View {
        if entry.isDirectory {
            Button {
                path.append(entry.path.components(separatedBy: "/").last ?? entry.path)
            } label: {
                label(entry, systemImage: "folder.fill", tint: .orange)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(t("删除"), role: .destructive) { pendingDelete = entry.path }
                Button(t("重命名")) {
                    dialogText = (entry.path as NSString).lastPathComponent
                    withAnimation(.snappy) { nameDialog = .rename(old: entry.path) }
                }
                .tint(.blue)
            }
        } else {
            Button {
                openFile(entry.path)
            } label: {
                label(entry, systemImage: icon(for: entry.path), tint: .accentColor)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(t("删除"), role: .destructive) { pendingDelete = entry.path }
                Button(t("重命名")) {
                    dialogText = (entry.path as NSString).lastPathComponent
                    withAnimation(.snappy) { nameDialog = .rename(old: entry.path) }
                }
                .tint(.blue)
                Button(t("分享")) { exportFile(entry.path) }
                .tint(.green)
            }
        }
    }

    private func label(_ entry: FileManagerService.Entry, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text((entry.path as NSString).lastPathComponent)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ entry: FileManagerService.Entry) -> String {
        if entry.isDirectory { return "文件夹" }
        var parts: [String] = [ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file)]
        if let modified = entry.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private var logsSection: some View {
        Section {
            let logs = FileManagerService.shared.logs
            if logs.isEmpty {
                Text("暂无 AI 文件操作记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(logs.prefix(10).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 操作记录")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !path.isEmpty {
                Button {
                    path.removeLast()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text(path.count > 1 ? path[path.count - 2] : t("文件"))
                            .lineLimit(1)
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button(t("新建文件夹"), systemImage: "folder.badge.plus") {
                    dialogText = ""
                    withAnimation(.snappy) { nameDialog = .newFolder }
                }
                Button(t("新建文件"), systemImage: "doc.badge.plus") {
                    dialogText = ""
                    withAnimation(.snappy) { nameDialog = .newFile }
                }
                Divider()
                Button(t("导入文件"), systemImage: "square.and.arrow.down") {
                    showImporter = true
                }
            } label: {
                Image(systemName: "plus.circle.fill")
            }
        }
    }

    // MARK: - 居中输入弹窗（新建文件夹 / 新建文件 / 重命名）

    @ViewBuilder
    private func nameDialogOverlay(_ dialog: NameDialog) -> some View {
        // 注意：本函数是 @ViewBuilder，不能写 `title = ...` 这类赋值语句
        // （语句表达式 () 不是 View，会报 "type '()' cannot conform to 'View'"）。
        // 文案用元组一次取出。
        let texts = nameDialogTexts(dialog)

        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { closeNameDialog() }

            VStack(spacing: 18) {
                Text(texts.title)
                    .font(.headline)

                // 弹窗正中的输入框（用户反馈的核心：原来系统 alert 的输入框不居中）
                TextField(texts.placeholder, text: $dialogText)
                    .textFieldStyle(.plain)
                    .focused($dialogFocused)
                    .submitLabel(.done)
                    .onSubmit { confirmNameDialog() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    .frame(maxWidth: 260)

                HStack {
                    Button(t("取消"), role: .cancel) { closeNameDialog() }
                    Spacer()
                    Button(texts.confirm) { confirmNameDialog() }
                        .fontWeight(.semibold)
                        .disabled(dialogText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .font(.subheadline)
            }
            .padding(22)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
        .onAppear {
            // 弹窗出现后自动聚焦（async 让布局先完成，否则 focus 可能不生效）
            DispatchQueue.main.async { dialogFocused = true }
        }
    }

    private func nameDialogTexts(_ dialog: NameDialog) -> (title: String, placeholder: String, confirm: String) {
        switch dialog {
        case .newFolder: return (t("新建文件夹"), t("名称"), t("创建"))
        case .newFile: return (t("新建文件"), t("名称.txt"), t("创建"))
        case .rename: return (t("重命名"), t("新名称"), t("确定"))
        }
    }

    private func closeNameDialog() {
        dialogFocused = false
        withAnimation(.snappy) { nameDialog = nil }
        dialogText = ""
    }

    private func confirmNameDialog() {
        guard let dialog = nameDialog else { return }
        let name = dialogText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            switch dialog {
            case .newFolder:
                try FileManagerService.shared.makeDirectory(join(name))
            case .newFile:
                var final = name
                if !final.contains(".") { final += ".txt" }
                try FileManagerService.shared.write(join(final), content: "")
            case .rename(let old):
                let dir = (old as NSString).deletingLastPathComponent
                let dest = dir.isEmpty ? name : dir + "/" + name
                try FileManagerService.shared.move(old, to: dest)
            }
            closeNameDialog()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 动作

    private func join(_ name: String) -> String {
        currentPath.isEmpty ? name : currentPath + "/" + name
    }

    private func reload() {
        do {
            entries = try FileManagerService.shared.list(currentPath)
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func openFile(_ path: String) {
        do {
            let result = try FileManagerService.shared.read(
                path, offset: 1, limit: FileManagerService.maxWriteBytes)
            editingText = result.text
            editingFile = path
        } catch {
            exportFile(path)
        }
    }

    private func exportFile(_ path: String) {
        let url = FileManagerService.shared.root
            .appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        shareURL = url
    }

    private func icon(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "txt", "md", "markdown": return "doc.text.fill"
        case "json": return "doc.json"
        case "csv": return "tablecells"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo.fill"
        case "pdf": return "doc.richtext.fill"
        case "swift", "py", "js", "ts", "sh", "c", "h": return "chevron.left.forwardslash.chevron.right"
        case "mp3", "wav", "m4a", "aac": return "waveform"
        case "mp4", "mov": return "film.fill"
        case "zip": return "archivebox.fill"
        default: return "doc.fill"
        }
    }
}

private struct IdentifiedString: Identifiable {
    let id: String
}

struct FileEditorSheet: View {
    let path: String
    let initialText: String
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var errorMessage: String?

    init(path: String, initialText: String, onSaved: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.path = path
        self.initialText = initialText
        self.onSaved = onSaved
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .navigationTitle((path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(t("取消"), action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(t("保存")) {
                            do {
                                try FileManagerService.shared.write(path, content: text)
                                onSaved()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        .disabled(text == initialText)
                    }
                }
                .alert(t("保存失败"), isPresented: .init(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button(t("好的"), role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }
}
