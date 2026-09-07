import SwiftUI
import WebKit

/// In-app viewer for the standalone documentation book (Docs/index.html).
/// The book is bilingual on every screen (17 languages, fixed left TOC) and
/// ships as a single self-contained HTML file bundled into the app.
struct DocsView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}