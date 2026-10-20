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
/// VS Code's notification toasts, bottom right: transfers in progress, short
/// confirmations, and errors (which stay until closed or 10 s pass).
struct TransferToast: View {
    @ObservedObject var wb: Workbench
    var body: some View {
        let t = wb.theme
        VStack(alignment: .trailing, spacing: 8) {
            if let msg = wb.alert {
                toast(t, msg, icon: .error, color: t.ui("notificationsErrorIcon.foreground", "editorError.foreground", default: "#f14c4c"),
                      close: { wb.alert = nil })
                    .task(id: msg) {
                        guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
                        if wb.alert == msg { wb.alert = nil }
                    }
            }
            if let msg = wb.transfer ?? wb.toast {
                toast(t, msg, icon: wb.transfer != nil ? nil : .check, color: t.ui("notificationsInfoIcon.foreground", default: "#3794ff"),
                      close: wb.transfer != nil ? nil : { wb.toast = nil })
                    .task(id: wb.toast) {
                        // A newer toast cancels this wait; it mustn't clear that one.
                        guard wb.toast != nil, (try? await Task.sleep(for: .seconds(3))) != nil else { return }
                        wb.toast = nil
                    }
            }
        }
        .padding(.trailing, 16).padding(.bottom, 40)
        .animation(Motion.popup, value: wb.transfer ?? wb.toast)
        .animation(Motion.popup, value: wb.alert)
    }

    /// Every notification is the same glass; its kind shows in the icon well.
    private func toast(_ t: VSTheme, _ msg: String, icon: Codicon?, color: Color, close: (() -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                if let icon {
                    CodiconView(icon: icon, size: 15).foregroundStyle(color)
                        .symbolBounceIn()
                } else {
                    ProgressView().scaleEffect(0.6).tint(color)
                }
            }
            .frame(width: 28, height: 28)
            Text(msg).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let close {
                Button(action: close) { CodiconView(icon: .close, size: 14) }
                    .buttonStyle(ToolbarButtonStyle(padding: 3)).tip("Clear Notification")
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 10)
        .frame(width: 400)
        .foregroundStyle(t.ui("notifications.foreground", "editor.foreground", default: "#cccccc"))
        .glass(t.ui("notifications.background", "editorWidget.background", default: "#252526"), radius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.widgetBorder))
        .shadow(color: .black.opacity(t.isDark ? 0.35 : 0.12), radius: 18, y: 8)
        .transition(.pop(from: .bottomTrailing))
    }
}
