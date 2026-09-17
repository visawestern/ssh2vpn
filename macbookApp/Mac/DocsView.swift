import SwiftUI
import WebKit

/// MAC-fork Iphone/App/DocsView.swift: NSViewRepresentable вместо
/// UIViewRepresentable. Логика та же: bundled HTML-книги (17 языков,
/// свой языковой свитчер), стартовый язык инжектится через window.APP_LANG.
enum DocsPage {
    case book
    case privacy
    case terms

    var resource: String {
        switch self {
        case .book: return "index"
        case .privacy: return "privacy"
        case .terms: return "terms"
        }
    }
}

struct DocsView: NSViewRepresentable {
    var page: DocsPage = .book
    var language: String? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userScript = WKUserScript(
            source: "window.APP_LANG = \(language.map { "\"\($0)\"" } ?? "null");",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        if let url = Bundle.main.url(forResource: page.resource, withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
