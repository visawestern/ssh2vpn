import SwiftUI
import WebKit

/// Which bundled HTML book to show.
enum DocsPage {
    /// The standalone user guide (Docs/index.html).
    case book
    /// App Store-required privacy policy (Docs/privacy.html).
    case privacy
    /// App Store-required terms of use (Docs/terms.html).
    case terms

    var resource: String {
        switch self {
        case .book: return "index"
        case .privacy: return "privacy"
        case .terms: return "terms"
        }
    }
}

/// In-app viewer for the bundled HTML books. Each page is self-contained
/// (17 languages, own language switcher with a flag) and ships inside the
/// app bundle. The page initially opens in the app's selected language
/// (injected via window.APP_LANG before the page script runs), then the
/// user can switch freely.
struct DocsView: UIViewRepresentable {
    var page: DocsPage = .book
    /// The app's currently selected language (raw AppLanguage value, e.g.
    /// "en", "pt-BR"). Nil falls back to the page's own system-language
    /// detection.
    var language: String? = nil

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userScript = WKUserScript(
            source: "window.APP_LANG = \(language.map { "\"\($0)\"" } ?? "null");",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: page.resource, withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Resource missing from the bundle: say so instead of a
            // blank white view (a missing bundled page is a build bug,
            // and silence would look like one to a reviewer too).
            context.coordinator.showMissing(in: webView, page: page.resource)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Shows a plain-text fallback inside the web view when the bundled
    /// page is missing or fails to load. No new strings to localize:
    /// resource names are stable identifiers, not user copy.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func showMissing(in webView: WKWebView, page: String) {
            webView.loadHTMLString(
                "<html><body style='font-family:-apple-system;color:#888;"
                + "padding:40px;text-align:center'>Page unavailable (\(page).html missing from bundle)</body></html>",
                baseURL: nil)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let name = webView.url?.deletingPathExtension().lastPathComponent ?? "page"
            showMissing(in: webView, page: name)
        }
    }
}
