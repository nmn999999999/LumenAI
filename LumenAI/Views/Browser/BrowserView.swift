import SwiftUI
import WebKit

/// 应用内浏览器界面：承载 Agent 可驱动的共享 WKWebView。
/// Agent 的 `browser` 工具与用户看到的是**同一个** webView。
struct BrowserView: View {

    @ObservedObject private var browser = WebBrowserService.shared
    @State private var address: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField(t("输入网址"), text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                        .onSubmit { go() }
                    Button { go() } label: { Image(systemName: "arrow.right.circle.fill") }
                        .font(.title2)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                Divider()

                ZStack(alignment: .top) {
                    WebViewContainer(webView: browser.webView)
                    if browser.isLoading {
                        ProgressView().padding(6)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.top, 6)
                    }
                }

                Divider()

                HStack(spacing: 26) {
                    Button { _ = browser.back() } label: { Image(systemName: "chevron.left") }
                    Button { _ = browser.forward() } label: { Image(systemName: "chevron.right") }
                    Button { _ = browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Spacer()
                    Text(browser.pageTitle.isEmpty ? browser.currentURL : browser.pageTitle)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .navigationTitle(t("浏览器"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { if address.isEmpty { address = browser.currentURL } }
        .onChange(of: browser.currentURL) { _, u in if !u.isEmpty { address = u } }
    }

    private func go() {
        let s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        Task { _ = await browser.open(s) }
    }
}

/// 把共享的 WKWebView 挂到 SwiftUI 视图树上（视图只是展示，所有权在单例）。
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
