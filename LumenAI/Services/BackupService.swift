import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 数据备份与恢复（Data Backup）
/// 导出：会话 + Provider + 助手 → 单个 JSON 文件（系统分享）
/// 导入：从「文件」选择备份 JSON → 校验后整体恢复
enum BackupService {

    struct BackupPackage: Codable {
        var localai_backup: Int
        var createdAt: Date
        var conversations: [Conversation]
        var providers: [ChatProvider]
        var assistants: [AIAssistant]

        // 兼容旧版备份:字段曾叫 kelivo_backup,重命名后旧文件仍能解析
        private enum CodingKeys: String, CodingKey {
            case localai_backup, kelivo_backup, createdAt, conversations, providers, assistants
        }
        init(
            localai_backup: Int,
            createdAt: Date,
            conversations: [Conversation],
            providers: [ChatProvider],
            assistants: [AIAssistant]
        ) {
            self.localai_backup = localai_backup
            self.createdAt = createdAt
            self.conversations = conversations
            self.providers = providers
            self.assistants = assistants
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.localai_backup = try c.decodeIfPresent(Int.self, forKey: .localai_backup)
                ?? c.decodeIfPresent(Int.self, forKey: .kelivo_backup) ?? 0
            self.createdAt = try c.decode(Date.self, forKey: .createdAt)
            self.conversations = try c.decode([Conversation].self, forKey: .conversations)
            self.providers = try c.decode([ChatProvider].self, forKey: .providers)
            self.assistants = try c.decode([AIAssistant].self, forKey: .assistants)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(localai_backup, forKey: .localai_backup)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(conversations, forKey: .conversations)
            try c.encode(providers, forKey: .providers)
            try c.encode(assistants, forKey: .assistants)
        }
    }

    @MainActor
    static func buildPackage(chatStore: ChatStore) -> BackupPackage {
        BackupPackage(
            localai_backup: 1,
            createdAt: Date(),
            conversations: chatStore.conversations,
            providers: ProviderStore.shared.providers,
            assistants: AssistantStore.shared.assistants
        )
    }

    /// 备份文件魔数:识别 LZ4 压缩格式的备份(LZ4B + LZ4 block)
    static let backupMagic = Data("LZ4B".utf8)

    /// 生成备份文件(会话+Provider+助手 JSON)。
    /// 备份含大量文本,LZ4 压缩率可观:压缩后更小则写入「LZ4B 魔数 + LZ4 块」;
    /// 压缩后反而更大(罕见)则回退明文 JSON。两种格式 parseBackup 均能解析。
    @MainActor
    static func makeBackupFile(chatStore: ChatStore) -> URL? {
        let package = buildPackage(chatStore: chatStore)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(package) else { return nil }

        let compressed = LZ4.compress(json)
        let data = compressed.count < json.count ? backupMagic + compressed : json

        let tmp = FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = tmp.appendingPathComponent("localai-backup-\(formatter.string(from: Date())).json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// 解析备份文件;自动识别 LZ4 压缩格式(魔数 LZ4B)与明文 JSON(旧版备份)
    static func parseBackup(data: Data) throws -> BackupPackage {
        let raw: Data
        if data.count > backupMagic.count, data.prefix(backupMagic.count) == backupMagic {
            guard let d = LZ4.decompress(Data(data.dropFirst(backupMagic.count))) else {
                throw BackupError.corruptCompressed
            }
            raw = d
        } else {
            raw = data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pkg = try decoder.decode(BackupPackage.self, from: raw)
        guard pkg.localai_backup == 1 else {
            throw BackupError.notABackup
        }
        return pkg
    }

    /// 整体恢复（会话 + Provider + 助手）
    @MainActor
    static func restore(_ pkg: BackupPackage, chatStore: ChatStore) {
        chatStore.restoreFromBackup(pkg.conversations)
        // 会话是整批替换的：恢复前那些对话连同 id 一起消失，而任务清单按 id 分槽存在
        // Documents/agent_todos.json —— 不一起收拢，旧槽位就成了界面上永远看不到、
        // 也永远删不掉的孤儿（内容还是用户自己写的任务）。用恢复后的 id 做白名单即可，
        // 备份里自带的 id 会被保留，所以"同一批对话"恢复时清单跟着回来。
        TodoStore.shared.retainOnly(conversationIDs: Set(pkg.conversations.map(\.id)))
        ProviderStore.shared.providers = pkg.providers
        ProviderStore.shared.refreshSelectionAfterRestore()
        AssistantStore.shared.assistants = pkg.assistants
        if AssistantStore.shared.currentAssistantID == nil,
           let first = AssistantStore.shared.assistants.first {
            AssistantStore.shared.currentAssistantID = first.id
        }
    }

    enum BackupError: LocalizedError {
        case notABackup
        case corruptCompressed
        var errorDescription: String? {
            switch self {
            case .notABackup: return "不是有效的备份文件"
            case .corruptCompressed: return "备份压缩数据损坏，无法解析"
            }
        }
    }
}

// MARK: - 系统分享（UIActivityViewController 封装）

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 文件选择（UIDocumentPicker 封装）

struct DocumentPicker: UIViewControllerRepresentable {
    var onPicked: (Data) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .text, .plainText, .data])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first,
                  let data = try? Data(contentsOf: url)
            else { return }
            parent.onPicked(data)
        }
    }
}
