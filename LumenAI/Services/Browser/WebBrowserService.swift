import Foundation
import WebKit

// MARK: - 应用内浏览器（Agent 可驱动）
//
// iOS 上唯一能「真正点击」的表面就是**应用内 WKWebView**：可用 evaluateJavaScript
// 读取页面、点元素、填输入框。Agent 的 `browser` 工具直接驱动这个可见的浏览器。
//
// 单例持有 webView：视图只是把它挂上屏幕，即使切到别的 Tab、webView 仍然存活，
// 所以 Agent 在任何时候都能操作它。

@MainActor
final class WebBrowserService: NSObject, ObservableObject {

    static let shared = WebBrowserService()

    /// 共享的 WKWebView（由单例持有，视图挂载）。
    let webView: WKWebView

    @Published private(set) var currentURL: String = ""
    @Published private(set) var pageTitle: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var loadContinuation: CheckedContinuation<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - 导航

    /// 打开 URL 并等待加载结束。
    func open(_ urlString: String) async -> String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "错误：url 为空" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let url = URL(string: s) else { return "错误：不是合法 URL（\(urlString)）" }
        lastError = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            loadContinuation = cont
            webView.load(URLRequest(url: url))
        }
        if let e = lastError { return "打开失败：\(e)" }
        return await readPage()
    }

    func back() -> String { if webView.canGoBack { webView.goBack(); return "已后退 → \(currentURL)" }; return "已到最前，无法后退" }
    func forward() -> String { if webView.canGoForward { webView.goForward(); return "已前进" }; return "已到最后，无法前进" }
    func reload() -> String { webView.reload(); return "已刷新" }

    // MARK: - 读取页面

    /// 返回给模型的页面快照：标题 / URL / 正文摘要 / 可点元素编号列表。
    func readPage() async -> String {
        let js = """
        (function(){
          var sels = 'a,button,input,textarea,select,[role=button],[onclick],[role=link],[role=textbox]';
          var els = Array.from(document.querySelectorAll(sels)).filter(function(e){
            var r=e.getBoundingClientRect(); return r.width>0 && r.height>0;
          }).slice(0, 80);
          var items = els.map(function(e,i){
            var label = (e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.name || '').replace(/\\s+/g,' ').trim().slice(0,80);
            return i + '. <' + e.tagName.toLowerCase() + (e.type?':'+e.type:'') + '> ' + label + (e.href?(' → '+e.href):'');
          });
          var body = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g,'\\n\\n').slice(0,3500);
          return JSON.stringify({url:location.href, title:document.title, text:body, items:items});
        })()
        """
        guard let raw = await evalString(js) else { return "读取失败（页面无内容或脚本被拒）" }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "读取失败：\(raw.prefix(200))"
        }
        let title = obj["title"] as? String ?? ""
        let url = obj["url"] as? String ?? currentURL
        let text = obj["text"] as? String ?? ""
        let items = obj["items"] as? [String] ?? []
        var out = "【页面】\(title)\n【URL】\(url)\n\n【正文】\n\(text)\n\n【可操作元素（click/type 用编号 index）】\n"
        out += items.isEmpty ? "（无可点元素）" : items.joined(separator: "\n")
        return out
    }

    // MARK: - 交互

    func click(index: Int) async -> String {
        let js = elementJS(index: index, action: "e.scrollIntoView({block:'center',inline:'center'}); e.click();") +
                 "return JSON.stringify({ok:true, label:(e.innerText||e.value||e.getAttribute('aria-label')||'').replace(/\\s+/g,' ').trim().slice(0,80)});})()"
        return await runDOMAction(js, onError: "点击失败")
    }

    func clickText(_ text: String) async -> String {
        let t = jsEscape(text)
        let js = """
        (function(){
          var sels = 'a,button,input,textarea,select,[role=button],[onclick],[role=link]';
          var els = Array.from(document.querySelectorAll(sels)).filter(function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;});
          var t = '\(t)';
          var e = els.find(function(x){var s=(x.innerText||x.value||x.getAttribute('aria-label')||'');return s.indexOf(t)>=0;});
          if(!e) return JSON.stringify({ok:false, err:'未找到包含该文字的元素'});
          e.scrollIntoView({block:'center',inline:'center'}); e.click();
          return JSON.stringify({ok:true, label:(e.innerText||e.value||'').replace(/\\s+/g,' ').trim().slice(0,80)});
        })()
        """
        return await runDOMAction(js, onError: "点击失败")
    }

    func type(index: Int, text: String) async -> String {
        let t = jsEscape(text)
        let js = """
        (function(){
          var sels = 'input,textarea,select,[role=textbox]';
          var els = Array.from(document.querySelectorAll(sels)).filter(function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;});
          var e = els[\(index)];
          if(!e) return JSON.stringify({ok:false, err:'编号越界'});
          e.focus();
          var setter = Object.getOwnPropertyDescriptor(e.constructor.prototype,'value');
          if(setter && setter.set){ setter.set.call(e, '\(t)'); } else { e.value='\(t)'; }
          e.dispatchEvent(new Event('input',{bubbles:true}));
          e.dispatchEvent(new Event('change',{bubbles:true}));
          return JSON.stringify({ok:true, label:(e.value||'').slice(0,80)});
        })()
        """
        return await runDOMAction(js, onError: "输入失败")
    }

    func scroll(_ direction: String) async -> String {
        let dy = direction.lowercased().contains("up") ? "-window.innerHeight*0.9" : "window.innerHeight*0.9"
        let js = "window.scrollBy(0, \(dy)); JSON.stringify({ok:true, y:window.scrollY});"
        _ = await evalString(js)
        return "已滚动（\(direction)）"
    }

    // MARK: - 辅助

    private func elementJS(index: Int, action: String) -> String {
        """
        (function(){
          var sels = 'a,button,input,textarea,select,[role=button],[onclick],[role=link],[role=textbox]';
          var els = Array.from(document.querySelectorAll(sels)).filter(function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;});
          var e = els[\(index)];
          if(!e) return JSON.stringify({ok:false, err:'编号越界'});
          \(action)
        """
    }

    private func runDOMAction(_ js: String, onError: String) async -> String {
        guard let raw = await evalString(js),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "\(onError)：脚本无返回"
        }
        if (obj["ok"] as? Bool) == true {
            let label = obj["label"] as? String ?? ""
            return "完成。\(label.isEmpty ? "" : "元素：\(label)")"
        }
        return "\(onError)：\(obj["err"] as? String ?? "未知")"
    }

    /// evaluateJavaScript → String，含小延迟让 SPA 更新（点击后常有异步渲染）。
    private func evalString(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js) { value, _ in
                if let s = value as? String { cont.resume(returning: s) }
                else if let v = value { cont.resume(returning: String(describing: v)) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: " ")
    }
}

extension WebBrowserService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let u = webView.url { currentURL = u.absoluteString }
        pageTitle = webView.title ?? ""
        loadContinuation?.resume(); loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        if let u = webView.url { currentURL = u.absoluteString }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        loadContinuation?.resume(); loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        loadContinuation?.resume(); loadContinuation = nil
    }
}
