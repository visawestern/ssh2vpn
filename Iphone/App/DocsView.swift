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
/// (17 languages, own language switcher) and ships inside the app bundle.
struct DocsView: UIViewRepresentable {
    var page: DocsPage = .book

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        if let url = Bundle.main.url(forResource: page.resource, withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
