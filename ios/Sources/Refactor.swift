import Runestone
import SwiftUI

/// IntelliSense part 2: rename (F2), references (⇧F12), quick fixes (⌘.),
/// and parameter hints while typing a call.
extension Languages {
    struct RenameRequest {
        let path: String
        let line: UInt32
        let character: UInt32
        let current: String
    }

    struct Reference: Identifiable {
        let id: Int
        let path: String
        let line: Int
        let column: Int
        let preview: String
    }

    struct SignatureState {
        let sig: Signature
        let anchor: CGRect
    }

    private func caretPosition() -> (tv: TextView, path: String, line: UInt32, character: UInt32)? {
        guard let tv = activeView, let path = activePath, let loc = tv.textLocation(at: tv.selectedRange.location) else { return nil }
        return (tv, path, UInt32(loc.lineNumber), UInt32(loc.column))
    }

    // MARK: rename

    func beginRename() {
        guard let (tv, path, line, ch) = caretPosition(), server(of: path) != nil else { return }
        let ns = tv.text as NSString
        var s = tv.selectedRange.location, e = s
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        func isWord(_ i: Int) -> Bool { i >= 0 && i < ns.length && ns.substring(with: NSRange(location: i, length: 1)).unicodeScalars.allSatisfy(word.contains) }
        while isWord(s - 1) { s -= 1 }
        while isWord(e) { e += 1 }
        guard e > s else { return }
        renameRequest = RenameRequest(path: path, line: line, character: ch, current: ns.substring(with: NSRange(location: s, length: e - s)))
    }

    func commitRename(_ newName: String) {
        guard let r = renameRequest, let s = server(of: r.path), !newName.isEmpty, newName != r.current else { renameRequest = nil; return }
        renameRequest = nil
        Task {
            do {
                let files = try await s.rename(path: r.path, line: r.line, character: r.character, newName: newName)
                let n = await applyFileEdits(files)
                wb?.toast = "Renamed to '\(newName)' in \(n) file\(n == 1 ? "" : "s")"
            } catch {
                wb?.alert = "Rename failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: references

    func findReferences() {
        guard let (_, path, line, ch) = caretPosition(), let s = server(of: path) else { return }
        Task {
            guard let locs = try? await s.references(path: path, line: line, character: ch), !locs.isEmpty else {
                wb?.toast = "No references found"
                return
            }
            var lines: [String: [Substring]] = [:]
            for p in Set(locs.map(\.path)) {
                if let open = wb?.file(p), open.viewer == .text {
                    lines[p] = open.text.split(separator: "\n", omittingEmptySubsequences: false)
                } else if let data = try? await wb?.desktop?.readFile(path: p), let t = String(data: data, encoding: .utf8) {
                    lines[p] = t.split(separator: "\n", omittingEmptySubsequences: false)
                }
            }
            references = locs.enumerated().map { i, l in
                let ln = Int(l.range.start.line)
                let text = lines[l.path].flatMap { $0.indices.contains(ln) ? String($0[ln]) : nil } ?? ""
                return Reference(id: i, path: l.path, line: ln + 1, column: Int(l.range.start.character),
                                 preview: text.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: quick fixes

    func showCodeActions() {
        guard let (tv, path, line, ch) = caretPosition(), let s = server(of: path) else { return }
        let here = diagnostics(onLine: Int(line), path: path)
        // Like VS Code: the selection (or the caret) is the range; problems on
        // the line ride along as context so their quick fixes are offered.
        var range = LspRange(start: LspPos(line: line, character: ch), end: LspPos(line: line, character: ch))
        let sel = tv.selectedRange
        if sel.length > 0, let e = tv.textLocation(at: sel.location + sel.length) {
            range.end = LspPos(line: UInt32(e.lineNumber), character: UInt32(e.column))
        }
        Task {
            let acts = (try? await s.codeActions(path: path, range: range, diagnostics: here)) ?? []
            if acts.isEmpty { wb?.toast = "No code actions available"; return }
            codeActions = acts.sorted { $0.preferred && !$1.preferred }
            codeActionPath = path
        }
    }

    func runCodeAction(_ a: Action) {
        codeActions = nil
        guard let path = codeActionPath, let s = server(of: path) else { return }
        Task {
            do {
                _ = await applyFileEdits(try await s.runCodeAction(raw: a.raw))
            } catch {
                wb?.alert = "\(a.title) failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: parameter hints

    func requestSignature(_ tv: TextView, path: String) {
        guard let s = server(of: path), let loc = tv.textLocation(at: tv.selectedRange.location),
              let end = tv.selectedTextRange?.end else { return }
        let anchor = tv.convert(tv.caretRect(for: end), to: nil)
        Task {
            let sig = try? await s.signatureHelp(path: path, line: UInt32(loc.lineNumber), character: UInt32(loc.column))
            signature = sig.flatMap { $0 }.map { SignatureState(sig: $0, anchor: anchor) }
        }
    }

    // MARK: applying edits

    /// Applies server edits: open files change in the editor (and show as
    /// modified); others are rewritten on the desktop. Returns files changed.
    @discardableResult
    func applyFileEdits(_ files: [FileEdits]) async -> Int {
        guard let wb, let d = wb.desktop else { return 0 }
        var changed = 0
        for f in files where !f.edits.isEmpty {
            if let open = wb.file(f.path), open.viewer == .text {
                wb.setText(f.path, Self.apply(f.edits, to: open.text))
                changed += 1
            } else if let data = try? await d.readFile(path: f.path), let text = String(data: data, encoding: .utf8) {
                let crlf = text.contains("\r\n")
                var out = Self.apply(f.edits, to: crlf ? text.replacingOccurrences(of: "\r\n", with: "\n") : text)
                if crlf { out = out.replacingOccurrences(of: "\n", with: "\r\n") }
                if (try? await d.writeFile(path: f.path, data: Data(out.utf8))) != nil { changed += 1 }
            }
        }
        if changed > 0 { wb.explorerGeneration += 1 }
        return changed
    }
}

// MARK: - Views

/// Pickers driven by `Languages` state; this view observes it (the
/// workbench view only observes the workbench, so it wouldn't redraw).
struct LanguageOverlays: View {
    @EnvironmentObject var languages: Languages
    var body: some View {
        if languages.references != nil { ReferencesPicker() }
        if languages.codeActions != nil { CodeActionPicker() }
    }
}

struct RenameField: View {
    @EnvironmentObject var languages: Languages
    @State private var name = ""

    var body: some View {
        Color.clear
            .alert("Rename Symbol", isPresented: Binding(get: { languages.renameRequest != nil }, set: { if !$0 { languages.renameRequest = nil } })) {
                TextField("new name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Rename") { languages.commitRename(name) }
                Button("Cancel", role: .cancel) { languages.renameRequest = nil }
            } message: {
                Text("Rename '\(languages.renameRequest?.current ?? "")' everywhere it's used.")
            }
            .onChange(of: languages.renameRequest?.current) { _, v in name = v ?? "" }
    }
}

struct ReferencesPicker: View {
    @EnvironmentObject var languages: Languages
    @EnvironmentObject var wb: Workbench
    @State private var query = ""

    var body: some View {
        let all = languages.references ?? []
        let q = query.lowercased()
        QuickPickList(
            placeholder: "\(all.count) reference\(all.count == 1 ? "" : "s") — filter by file or text",
            query: $query,
            items: all.filter { q.isEmpty || $0.preview.lowercased().contains(q) || $0.path.lowercased().contains(q) },
            row: { r in
                AnyView(HStack(spacing: 6) {
                    FileIcon(name: wb.baseName(r.path), size: 14)
                    Text("\(wb.baseName(r.path)):\(r.line)").font(.system(size: 13))
                    Text(r.preview).font(.custom("Menlo", size: 12)).foregroundStyle(wb.theme.descriptionFg).lineLimit(1)
                })
            },
            pick: { r in
                languages.references = nil
                Task { await wb.open(r.path, line: r.line, column: r.column) }
            },
            dismiss: { languages.references = nil })
    }
}

struct CodeActionPicker: View {
    @EnvironmentObject var languages: Languages
    @EnvironmentObject var wb: Workbench
    @State private var query = ""

    struct Item: Identifiable {
        let id: Int
        let action: Action
    }

    var body: some View {
        let items = (languages.codeActions ?? []).enumerated()
            .filter { query.isEmpty || $0.element.title.lowercased().contains(query.lowercased()) }
            .map { Item(id: $0.offset, action: $0.element) }
        QuickPickList(
            placeholder: "Quick Fix…",
            query: $query,
            items: items,
            row: { it in
                AnyView(HStack(spacing: 6) {
                    CodiconView(icon: it.action.kind?.hasPrefix("quickfix") == true ? .lightbulb : .symbolMisc, size: 14)
                        .foregroundStyle(wb.theme.ui("editorLightBulb.foreground", default: "#ffcc00"))
                    Text(it.action.title).font(.system(size: 13))
                    if it.action.preferred { Text("preferred").font(.system(size: 11)).foregroundStyle(wb.theme.descriptionFg) }
                })
            },
            pick: { languages.runCodeAction($0.action) },
            dismiss: { languages.codeActions = nil })
    }
}

/// Parameter hints above the caret: the active parameter is bold.
struct SignaturePopup: View {
    @EnvironmentObject var languages: Languages
    @EnvironmentObject var wb: Workbench

    var body: some View {
        GeometryReader { geo in
            if let s = languages.signature {
                let t = wb.theme
                let origin = geo.frame(in: .global).origin
                VStack(alignment: .leading, spacing: 4) {
                    label(s.sig).font(.custom("Menlo", size: 12))
                    if let doc = s.sig.doc, !doc.isEmpty {
                        Text(doc).font(.system(size: 12)).foregroundStyle(t.descriptionFg).lineLimit(3)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: 560, alignment: .leading)
                .fixedSize()
                .foregroundStyle(t.ui("editorHoverWidget.foreground", "editor.foreground", default: "#cccccc"))
                .background(t.ui("editorHoverWidget.background", "editorWidget.background", default: "#252526"))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.widgetBorder))
                .shadow(color: .black.opacity(t.isDark ? 0.3 : 0.1), radius: 8, y: 3)
                .offset(x: max(s.anchor.minX - origin.x - 12, 4), y: max(s.anchor.minY - origin.y - 34 - (s.sig.doc == nil ? 0 : 20), 2))
                .onTapGesture { languages.signature = nil }
            }
        }
    }

    private func label(_ s: Signature) -> Text {
        let utf16 = Array(s.label.utf16)
        guard let a = s.activeStart, let b = s.activeEnd, a <= b, Int(b) <= utf16.count else { return Text(s.label) }
        func part(_ r: Range<Int>) -> String { String(decoding: utf16[r], as: UTF16.self) }
        return Text(part(0..<Int(a))) + Text(part(Int(a)..<Int(b))).bold().underline() + Text(part(Int(b)..<utf16.count))
    }
}
