import WidgetKit
import SwiftUI

/// Widget 扩展的入口。
///
/// 一个扩展里可以有多个 widget，这里只放一个 Live Activity。
/// 用 `WidgetBundle` 而不是直接在某个 Widget 上标 `@main`：
/// 将来要加桌面小组件时不必改结构（`@main` 只能有一个，加第二个就得重构）。
@main
struct LumenAIWidgetBundle: WidgetBundle {
    var body: some Widget {
        LumenAILiveActivity()
    }
}
