import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @Environment(\.dismiss) private var dismiss

    /// 待确认删除的对话。滑动删除原来是一碰就删掉整段历史（可能几十条消息）、
    /// 没有确认也没有撤销 —— 而同一 App 里删「全部」对话反倒是有确认框的，
    /// 危险程度不一致会让用户误以为这里的删除都是安全的。
    @State private var pendingDelete: Conversation?

    var body: some View {
        NavigationStack {
            List {
                ForEach(chatStore.conversations) { conv in
                    Button {
                        chatStore.currentConversationID = conv.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conv.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let model = conv.modelName {
                                    ModelBadge(text: model)
                                }
                                Text("\(conv.messages.count) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(conv.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { indexSet in
                    // 一次滑动只可能是连续的一段；只对第一项弹确认，
                    // 避免多选删除时连弹多个对话框。
                    guard let first = indexSet.map({ chatStore.conversations[$0] }).first else { return }
                    pendingDelete = first
                }
            }
            .overlay {
                if chatStore.conversations.isEmpty {
                    ContentUnavailableView(
                        "暂无对话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("点击右上角新建对话")
                    )
                }
            }
            .navigationTitle("历史对话")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "删除这段对话？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { conv in
                Button("删除", role: .destructive) {
                    // 先按 id 清掉这段对话的任务清单，再删对话本身。
                    // 顺序不能反：`chatStore.delete` 之后这条对话就不在任何列表里了，
                    // 只剩 `conv.id` 这个值还握在手里；一旦在这中间崩掉，
                    // 「对话没了、清单还在」的状态就被持久化了，那份清单再也没人认领 ——
                    // 用户在界面上既看不到也删不掉。
                    TodoStore.shared.delete(conversationID: conv.id)
                    chatStore.delete(conv)
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { conv in
                // 把「任务清单也会一起删」写出来：用户看不到清单文件，确认框是他唯一
                // 能得知这件事的地方；不写就变成"悄悄多删了一样东西"。
                Text("「\(conv.title)」的 \(conv.messages.count) 条消息及其任务清单将被永久删除，无法撤销。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        chatStore.createNew()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel(t("新建对话"))
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
