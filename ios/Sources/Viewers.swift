import PDFKit
import SwiftUI
import UIKit
import WebKit

/// Images from the desktop, zoomable (pinch / double-tap).
struct ImageViewer: View {
    let path: String
    @EnvironmentObject var wb: Workbench

    var body: some View {
        if let data = wb.blobs[path] {
            if (path as NSString).pathExtension.lowercased() == "svg" {
                // UIImage can't decode SVG; the web view can.
                HTMLView(html: "<html><body style='margin:0;display:flex;align-items:center;justify-content:center;height:100vh;background:transparent'>\(String(decoding: data, as: UTF8.self))</body></html>", baseURL: nil)
            } else if let image = UIImage(data: data) {
                ZoomableImage(image: image)
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))  ·  \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                            .font(.system(size: 11)).foregroundStyle(wb.theme.descriptionFg)
                            .padding(6)
                    }
            } else {
                Text("This image format isn't supported.").foregroundStyle(wb.theme.descriptionFg)
            }
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 8
        scroll.minimumZoomScale = 1
        scroll.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            iv.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            iv.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        ])
        context.coordinator.imageView = iv
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(dbl)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let s = g.view as? UIScrollView else { return }
            s.setZoomScale(s.zoomScale > 1 ? 1 : 3, animated: true)
        }
    }
}

/// PDFs from the desktop.
struct PDFViewer: UIViewRepresentable {
    let path: String
    @EnvironmentObject var wb: Workbench

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = wb.theme.uiColor("editor.background", default: "#1e1e1e")
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        guard let data = wb.blobs[path], v.document?.dataRepresentation() != data else { return }
        v.document = PDFDocument(data: data)
    }
}

/// Markdown: Open Preview. Renders the editor's live text with the bundled
/// marked.js, styled from the current theme; updates as you type.
struct MarkdownPreview: View {
    let file: OpenFile
    @EnvironmentObject var wb: Workbench

    var body: some View {
        // The preview tab's `path` is the markdown file's path + a marker.
        let source = wb.file(MarkdownPreview.sourcePath(file.path))?.text ?? ""
        HTMLView(html: Self.page(markdown: source, theme: wb.theme, fontSize: wb.fontSize),
                 baseURL: nil)
    }

    static let marker = "\u{200B}#preview"
    static func previewPath(for path: String) -> String { path + marker }
    static func sourcePath(_ previewPath: String) -> String {
        previewPath.hasSuffix(marker) ? String(previewPath.dropLast(marker.count)) : previewPath
    }

    private static let markedJS: String = {
        Bundle.main.url(forResource: "marked", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }()

    static func page(markdown: String, theme t: VSTheme, fontSize: CGFloat) -> String {
        func css(_ key: String, _ fallbacks: [String] = [], _ def: String) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            t.uiColor(key, fallbacks, default: def).getRed(&r, green: &g, blue: &b, alpha: &a)
            return "rgba(\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)),\(a))"
        }
        let bg = css("editor.background", [], "#1e1e1e")
        let fg = css("editor.foreground", ["foreground"], "#d4d4d4")
        let link = css("textLink.foreground", [], "#3794ff")
        let codeBg = css("textCodeBlock.background", ["editorWidget.background"], "#0a0a0a66")
        let border = css("textSeparator.foreground", ["panel.border"], "#80808059")
        let quote = css("textBlockQuote.border", ["focusBorder"], "#007acc")
        let json = (try? JSONSerialization.data(withJSONObject: [markdown])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        body{background:\(bg);color:\(fg);font:\(Int(fontSize + 2))px -apple-system,system-ui,sans-serif;line-height:1.6;
             max-width:880px;margin:0 auto;padding:16px 26px 60px;word-wrap:break-word}
        a{color:\(link)} h1,h2{border-bottom:1px solid \(border);padding-bottom:.3em}
        code{font-family:Menlo,monospace;font-size:.9em;background:\(codeBg);padding:.15em .35em;border-radius:4px}
        pre{background:\(codeBg);padding:12px;border-radius:6px;overflow:auto} pre code{background:none;padding:0}
        blockquote{margin:0;padding:0 1em;border-left:4px solid \(quote);opacity:.85}
        table{border-collapse:collapse} th,td{border:1px solid \(border);padding:6px 12px}
        img{max-width:100%} hr{border:0;border-top:1px solid \(border)}
        </style><script>\(markedJS)</script></head><body>
        <div id="c"></div>
        <script>document.getElementById('c').innerHTML = marked.parse(\(json)[0], {gfm: true});</script>
        </body></html>
        """
    }
}

/// A WKWebView showing local HTML; no navigation away from it.
struct HTMLView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let v = WKWebView(frame: .zero, configuration: config)
        v.isOpaque = false
        v.backgroundColor = .clear
        v.navigationDelegate = context.coordinator
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.last != html else { return }
        context.coordinator.last = html
        let y = v.scrollView.contentOffset.y
        context.coordinator.restoreY = y
        v.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var last = ""
        var restoreY: CGFloat = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Keep the reading position across live updates.
            webView.scrollView.setContentOffset(CGPoint(x: 0, y: restoreY), animated: false)
        }

        // Links open in Safari, not inside the preview.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

// MARK: - Files app ⇄ desktop

struct ExportItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet: Save to Files, AirDrop, open in another app…
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Upload/download progress and results, bottom of the window.
struct TransferToast: View {
    @ObservedObject var wb: Workbench
    var body: some View {
        let t = wb.theme
        Group {
            if let msg = wb.transfer ?? wb.toast {
                HStack(spacing: 8) {
                    if wb.transfer != nil { ProgressView().scaleEffect(0.7) } else { CodiconView(icon: .check, size: 14) }
                    Text(msg).font(.system(size: 13))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(t.ui("notifications.foreground", "editor.foreground", default: "#cccccc"))
                .background(t.ui("notifications.background", "editorWidget.background", default: "#252526"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: t.widgetShadow, radius: 6)
                .padding(.bottom, 40)
                .task(id: wb.toast) {
                    guard wb.toast != nil else { return }
                    try? await Task.sleep(for: .seconds(3))
                    wb.toast = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: wb.transfer ?? wb.toast)
    }
}
