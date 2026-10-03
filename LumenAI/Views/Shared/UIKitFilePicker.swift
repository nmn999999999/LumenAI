import SwiftUI
import UniformTypeIdentifiers

/// UIKit 文件选择器（`UIDocumentPickerViewController` + `asCopy: true`）。
///
/// v0.3.74 起聊天/文件页统一用它，替换 SwiftUI 的 `.fileImporter`。原因（搜到的已知问题）：
/// 1. **iOS 26 真机**：fileImporter 选完文件后读内容报
///    "You do not have permission to view the file"，即使正确调用了
///    `startAccessingSecurityScopedResource` 也救不回来
///    （Stack Overflow 79768601，iOS 17 正常、iOS 26 挂）。
/// 2. **部分真机**：fileImporter 弹窗不关闭、回调永远不触发
///    （Apple 开发者论坛 741753），换 UIKit delegate 版本后正常。
/// 3. `asCopy: true` 让系统在**选择瞬间**就把文件拷进 App 沙盒（tmp），
///    拿到的 URL 没有安全作用域、直接可读 —— 上面 1/2 两类问题都不存在。
///    拷贝是系统完成的，不需要自己做安全作用域进出。
struct UIKitFilePicker: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let allowsMultipleSelection: Bool
    /// 选中（系统已拷贝进沙盒，URL 直接可读）
    let onPicked: ([URL]) -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: UIKitFilePicker
        init(_ parent: UIKitFilePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancelled()
        }
    }
}
