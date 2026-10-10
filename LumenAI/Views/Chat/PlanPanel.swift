import SwiftUI

/// 面板内的少量文案。
///
/// 为什么不直接用 `L10n.t`：`Localization.swift` 的词条表是 `private static let`，
/// 新词条加不进去；而未登记的 key 在英文界面会**原样显示中文**（`englishFallback`
/// 找不到就 return key）。为一个 UI 面板去改公共本地化文件不划算，
/// 这几个词就近做双语映射。
/// `L10n.current` 读的是 `SettingsStorage.shared`（MainActor 隔离），所以这里也必须标 `@MainActor`。
@MainActor
private func planText(_ zh: String, _ en: String) -> String {
    L10n.current == "en" ? en : zh
}

// MARK: - 任务清单面板

/// 聊天页输入栏上方的「任务清单」面板：把 agent 的**目标清单与进度**直接摊给用户看。
///
/// 为什么要这块面板：agent 模式下模型会自己拆任务、逐条推进，但这些只存在于它的
/// 上下文里 —— 用户看到的只是"转圈 + 偶尔冒出来的工具 chip"，既不知道 agent 打算做几步，
/// 也不知道现在卡在哪一步、还剩几步。把清单显式渲染出来，用户才能判断
/// "它是在干活还是在瞎转"，也才有依据中途打断。
///
/// 设计取舍见各个属性/方法的注释。
struct PlanPanel: View {
    @ObservedObject var store: TodoStore

    /// 默认展开。
    ///
    /// 面板存在的唯一意义就是让用户看见 agent 的进度；默认收起等于把这块信息藏起来，
    /// 用户还得先点一下才知道 agent 停在哪儿 —— 那还不如不做。
    /// 收起态只留给"看腻了 / 想给消息列表多留几行"的用户，并且收起后仍保留一行摘要（见 `collapsedSummary`）。
    @State private var expanded = true

    /// 条目超过这个数才套 ScrollView（见 `listBody`）。
    private static let scrollThreshold = 8

    var body: some View {
        // 空态整块不渲染：没有清单时不占任何高度、不留一条空白条，
        // 输入栏位置与"没有这个功能时"完全一致。
        if store.isActive {
            VStack(alignment: .leading, spacing: 8) {
                header
                if expanded {
                    progressBar
                    listBody
                }
            }
            .padding(10)
            // 与 ToolCallChip / ThinkSection 同款材质与圆角：面板属于"气泡内的次级卡片"
            // 这一类视觉，沿用同一套参数，不另立一套。
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            // 状态变化（某条转 in_progress、某条转 completed、条目增删）都在这里统一做动画，
            // 而不是给每行各自挂一个 —— 单一动画上下文能保证整块面板的位移/变色是同步的，
            // 不会出现"图标变了但底色还在动"的割裂感。
            .animation(.snappy, value: store.todos)
            .animation(.snappy, value: expanded)
        }
    }

    // MARK: - 标题栏

    private var header: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(planText("任务", "Tasks"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)

                if !expanded, !collapsedSummary.isEmpty {
                    Text(collapsedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Text(store.progressText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    // 纯数字变化用 numericText 过渡：2/5 → 3/5 时数字滚动一下，
                    // 比原地替换更容易被余光捕捉到，成本又比整块重绘低。
                    .contentTransition(.numericText())

                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(planText("任务清单", "Task list"))
        // 收起时把摘要并进 value：`.accessibilityLabel` 会整段替换掉子树里的文本，
        // 若不合并，VoiceOver 用户就听不到"正在做的那条"—— 偏偏那是视觉上最显眼的一行。
        .accessibilityValue(expanded || collapsedSummary.isEmpty
                            ? store.progressText
                            : store.progressText + collapsedSummary)
        .accessibilityHint(expanded
                           ? planText("双击收起", "Double tap to collapse")
                           : planText("双击展开", "Double tap to expand"))
    }

    /// 收起态的一行摘要，例如「· 正在做：检查解析分支」。
    ///
    /// 为什么收起后还要显示："正在做的那条"是整块面板里信息密度最高的一行 ——
    /// 用户收起面板是想省屏幕空间，不是想失去"agent 此刻在干什么"这条信息。
    /// 连它一起藏掉，收起就等于关掉了这块功能。
    private var collapsedSummary: String {
        if let current = currentTodo {
            return planText("· 正在做：", " · Now: ") + current.content
        }
        if !store.todos.isEmpty, doneCount == store.todos.count {
            return planText("· 全部完成", " · all done")
        }
        return ""
    }

    // MARK: - 进度

    /// 3pt 细线进度条。
    ///
    /// 不用 `ProgressView(value:)` 配 `.linear`：那个样式有内置最小高度和内边距，
    /// 放在"一行标题 + 一条线"的紧凑卡片里会把面板撑高、挤占消息列表。
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        // 进度已经由标题栏的 progressText 读出来了，重复播报只会让 VoiceOver 更啰嗦。
        .accessibilityHidden(true)
    }

    /// 已完成条数。自己数而不是解析 `progressText`：那是给人看的字符串，
    /// 格式由 TodoStore 决定，UI 不该去拆它。
    private var doneCount: Int {
        store.todos.filter { $0.status == .completed }.count
    }

    private var fraction: Double {
        guard !store.todos.isEmpty else { return 0 }
        return Double(doneCount) / Double(store.todos.count)
    }

    // MARK: - 列表

    /// 条目多时才套 ScrollView。
    ///
    /// ScrollView 在滚动轴上是"贪心"的：无条件套一层，只有两条任务的清单也会占满高度上限，
    /// 消息列表被平白挤掉一截。超过阈值才滚，常见规模（3~8 条）就让它自然撑开。
    /// 上限 220pt 是为了保证消息列表和输入栏永远留在屏幕上 —— 清单再长也不能把输入栏顶出去。
    @ViewBuilder
    private var listBody: some View {
        if store.todos.count > Self.scrollThreshold {
            ScrollView { rows }
                .frame(maxHeight: 220)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.todos) { todo in
                row(todo)
            }
        }
    }

    private func row(_ todo: TodoStore.Todo) -> some View {
        // 行本身抽成 `TodoRow`：任务清单现在有**两个**展示面（聊天页的常驻面板、
        // 工具栏点开的完整清单页），两处必须长得一样 —— 状态图标/删除线/当前项底色
        // 各写一份的话，早晚会出现"面板里是灰勾、清单页里是绿勾"这种不一致。
        TodoRow(todo: todo, compact: true)
    }

    /// "当前正在做的那条"。
    ///
    /// `TodoStore` 没有提供这个便捷访问，这里自己算 —— 这是 UI 的展示需求，
    /// 不该为了它去给数据层加 API。
    ///
    /// 取值顺序：优先 `inProgress`；没有 `inProgress` 时退回第一条 `pending`。
    /// 为什么要有退路：模型有时会先把清单整批建出来、下一步才开工，中间那一瞬间
    /// 所有条目都是 pending —— 此时"还没有 in_progress 就显示不出东西"会让摘要空掉。
    private var currentTodo: TodoStore.Todo? {
        store.todos.first { $0.status == .inProgress }
            ?? store.todos.first { $0.status == .pending }
    }
}

// MARK: - 单条任务（常驻面板与完整清单页共用）

/// 一条任务。`compact` 用于聊天页的常驻面板（字号小、内边距紧）；
/// 非 compact 用于完整清单页（正常字号、更舒展）。
struct TodoRow: View {
    let todo: TodoStore.Todo
    var compact: Bool = false

    /// 此组件内的少量文案。与 `planText` 同一个理由（`L10n` 的词条表是 private，
    /// 新词条加不进去；未登记的 key 在英文界面会原样显示中文）。
    private func rowText(_ zh: String, _ en: String) -> String {
        L10n.current == "en" ? en : zh
    }

    var body: some View {
        let isCurrent = todo.status == .inProgress
        let isDone = todo.status == .completed

        return HStack(alignment: .top, spacing: compact ? 8 : 10) {
            statusIcon(todo.status)
                .font(compact ? .caption : .footnote)
                // 状态切换时图标是"换一个 symbol"（circle → checkmark.circle.fill），
                // 默认是硬切；replace 过渡让它像被"替换"而不是闪一下，
                // 配合外层 .animation(value: store.todos) 才能让人看出"这一项刚刚完成了"。
                .contentTransition(.symbolEffect(.replace))
                // 固定图标宽度：三种状态图标（circle / circle.dotted / checkmark.circle.fill）
                // 宽度并不相同，不固定就会让每行文字的左边缘各自错开 1~2pt。
                .frame(width: compact ? 16 : 18, alignment: .leading)
                .padding(.top, compact ? 2 : 3)

            Text(todo.content)
                .font(compact ? (isCurrent ? .footnote.weight(.semibold) : .footnote)
                              : (isCurrent ? .subheadline.weight(.semibold) : .subheadline))
                // 已完成的用 .secondary + 删除线，而不是 .tertiary：
                // 用户要看到**全貌**（做了哪些、还剩哪些），淡到看不见等于把已完成的进度藏了；
                // 删除线 + 次要色已经足够区分"这条翻篇了"。
                .foregroundStyle(isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .strikethrough(isDone, color: .secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 4 : 7)
        // 当前项垫一层极浅的强调色底：在一堆同字号的行里，它是第一个被眼睛抓到的。
        // 用 12% 透明度的色底而不是实心色块 —— 实心会和输入栏那几个彩色按钮抢注意力，
        // 而这块内容本身应该是"背景信息"。
        .background(
            isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color.clear),
            in: .rect(cornerRadius: compact ? 8 : 10)
        )
        // 整行合成一个无障碍元素：状态图标 + 文字一起读，不会读成"圆圈，检查解析分支"两段。
        .accessibilityElement(children: .combine)
    }

    /// 状态图标 + 无障碍标签。
    @ViewBuilder
    private func statusIcon(_ status: TodoStore.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(rowText("待办", "Pending"))

        case .inProgress:
            // 为什么选 circle.dotted 而不是 arrow.triangle.2.circlepath：
            // 前者和 pending 的 circle 是同一"形状族"，用户一眼看出这是"同一个圆圈、还没填实"；
            // 后者是旋转箭头，容易被读成"重新加载 / 重试"，语义是错的。
            // 动效用 pulse（轻微呼吸）而不是旋转：agent 任务可能跑几分钟，
            // 一个持续旋转的图标会在几秒内变成视觉噪音。
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: true)
                .accessibilityLabel(rowText("进行中", "In progress"))

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(rowText("已完成", "Completed"))
        }
    }
}


// MARK: - 完整任务清单页

/// 从聊天页工具栏点开的「任务清单」整页。
///
/// 为什么需要它（**空的时候也需要**）：常驻面板只在"已经有清单"时才渲染，于是一个
/// 从没用过这个功能的用户**永远看不到它存在** —— 他既不知道 agent 会拆任务，
/// 也没有任何入口能发现这件事。这就是"功能做了但用户看不见"。
/// 所以这里给一个无条件存在的入口：有清单时看清单；没有清单时解释它是什么、
/// 以及怎么让 AI 产生一份（含"本地模型需要手动打开 todo"这个前提）。
struct TaskListSheet: View {
    @ObservedObject var store: TodoStore
    @ObservedObject private var toolStore = ToolSettingsStore.shared

    @Environment(\.dismiss) private var dismiss
    @State private var enableFailed = false

    /// `todo` 工具是否已启用（只对本地模型有意义，云端模型始终拿全量工具）。
    ///
    /// 为什么这个页面要关心它：本地模型的工具目录只有 12 个位置（给小模型控制上下文），
    /// `todo` 刻意不在默认清单里，所以本地模型用户看不到任何清单 —— 而他们最容易
    /// 以为"这功能坏了"。与其让他自己去设置里翻，不如在这里把原因和开关一起摆出来。
    private var todoEnabled: Bool { toolStore.isEnabled("todo") }

    var body: some View {
        NavigationStack {
            Group {
                if store.todos.isEmpty { emptyState } else { list }
            }
            .navigationTitle("任务清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                if !store.todos.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("清空", role: .destructive) { store.clear() }
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.todos) { todo in
                    TodoRow(todo: todo)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            } header: {
                HStack {
                    Text("当前对话的任务")
                    Spacer()
                    Text(store.progressText).monospacedDigit()
                }
            } footer: {
                Text("这份清单只属于当前这段对话。换对话会自动切到那一段的清单；删除对话时它也会一起删掉。")
            }
        }
        .scrollContentBackground(.hidden)
        .glassScrollEdges()
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ContentUnavailableView(
                    "还没有任务清单",
                    systemImage: "checklist",
                    description: Text("AI 在跑多步任务时会自己列出步骤，并把每一步的进度写在这里。")
                )

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("怎么让它出现")
                            .font(.subheadline.weight(.semibold))

                        Label {
                            Text("用云端模型不用做任何事：让它做一件多步的事（比如「把这几个文件的内容汇总成一张表」），它会自己用 todo 工具写出计划。清单会显示在输入栏上方，也能在这个页面看到。")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "cloud").foregroundStyle(.tint)
                        }

                        Label {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("用本地模型需要手动打开 todo 工具。原因是本地模型只喂前 \(toolStore.limit) 个工具（控制小模型的上下文长度），todo 默认不在这个精简清单里，所以需要手动开启。")
                                    .fixedSize(horizontal: false, vertical: true)
                                if todoEnabled {
                                    Label("已经打开了", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else {
                                    Button {
                                        // 已达上限时 setEnabled 会拒绝并保持原状，
                                        // 所以如实把结果说出来，而不是乐观地当成已打开。
                                        if !toolStore.setEnabled("todo", true) {
                                            enableFailed = true
                                        }
                                    } label: {
                                        Text("现在打开 todo")
                                    }
                                    .font(.caption)
                                    if enableFailed {
                                        Text("没能打开：本地模型的工具名额已满（\(toolStore.limit) 个）。请到「设置 → 工具」里先关掉一个再开。")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        } icon: {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }
}
