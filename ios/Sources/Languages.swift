import Runestone
import SwiftUI
import UIKit

/// IntelliSense: language servers on the desktop (rust-analyzer, clangd,
/// pyright, …) started by the Rust core, plus diagnostics, progress and the
/// completion / hover popups.
@MainActor
final class Languages: ObservableObject {
    weak var wb: Workbench?
    /// Problems by file path, as the servers last reported them.
    @Published private(set) var diagnostics: [String: [Diag]] = [:]
    /// Progress per language name ("Rust" -> "Indexing 40%").
    @Published private(set) var progress: [String: String] = [:]
    /// Languages whose server isn't installed on the desktop.
    @Published private(set) var missing: [String: Missing] = [:]
    @Published var completion: CompletionState?
    @Published var hover: HoverState?
    @Published var renameRequest: RenameRequest?
    @Published var references: [Reference]?
    @Published var codeActions: [Action]?
    var codeActionPath: String?
    @Published var signature: SignatureState?

    struct Missing {
        let name: String
        let message: String
        let install: String
    }

    struct CompletionState {
        let path: String
        let items: [CompletionItem]
        var visible: [CompletionItem]
        var selected = 0
        /// Caret rect in window coordinates.
        var anchor: CGRect
        /// UTF-16 offset where the word being completed starts.
        let wordStart: Int
    }

    struct HoverState {
        let text: String
        let anchor: CGRect
        var fromPointer = false
    }

    private var servers: [String: LspServer] = [:]
    private var starting: [String: Task<LspServer?, Never>] = [:]
    private var docServer: [String: LspServer] = [:]
    private var completionTask: Task<Void, Never>?
    private var suppressNextTrigger = false

    /// The focused editor, for keyboard commands (⌃Space, ⌘K ⌘I, F12).
    weak var activeView: TextView?
    var activePath: String?

    // MARK: servers & documents

    func languageId(for path: String) -> String? {
        guard let id = Language.id(for: path), lspLanguageName(languageId: id) != nil else { return nil }
        return id
    }

    private func server(for languageId: String) async -> LspServer? {
        if let s = servers[languageId], s.alive() { return s }
        if missing[languageId] != nil { return nil }
        if let t = starting[languageId] { return await t.value }
        guard let wb, let d = wb.desktop, !wb.root.isEmpty else { return nil }
        let root = wb.root
        let sink = Sink(owner: self, name: lspLanguageName(languageId: languageId) ?? languageId)
        let task = Task<LspServer?, Never> {
            do {
                return try await d.languageServer(languageId: languageId, root: root, sink: sink)
            } catch let PadError.NoServer(msg, install, detail) {
                let name = lspLanguageName(languageId: languageId) ?? languageId
                let why = detail.isEmpty ? msg : "\(msg).\n\n\(detail)"
                self.missing[languageId] = Missing(name: name, message: why, install: install)
                return nil
            } catch {
                let name = lspLanguageName(languageId: languageId) ?? languageId
                self.missing[languageId] = Missing(name: name, message: error.localizedDescription, install: "")
                return nil
            }
        }
        starting[languageId] = task
        let server = await task.value
        starting[languageId] = nil
        // Same server for related languages (JS/TS, C/C++).
        if let server { servers[languageId] = server }
        return server
    }

    func opened(_ path: String) {
        guard let lang = languageId(for: path) else { return }
        Task {
            guard let s = await server(for: lang),
                  let text = wb?.files.first(where: { $0.path == path })?.text else { return }
            try? s.open(path: path, languageId: lang, text: text)
            docServer[path] = s
        }
    }

    func changed(_ path: String, text: String) {
        docServer[path]?.change(path: path, text: text)
    }

    func saved(_ path: String, text: String) {
        try? docServer[path]?.save(path: path, text: text)
    }

    func closed(_ path: String) {
        try? docServer.removeValue(forKey: path)?.close(path: path)
        if activePath == path { completion = nil; hover = nil }
    }

    /// Forget all servers (connection replaced or folder changed) and reopen
    /// the open files on fresh ones.
    func restart(stopOld: Bool) async {
        if stopOld { await wb?.desktop?.stopLanguageServers() }
        servers = [:]
        starting = [:]
        docServer = [:]
        missing = [:]
        progress = [:]
        diagnostics = [:]
        completion = nil
        hover = nil
        for f in wb?.files ?? [] { opened(f.path) }
    }

    /// After installing a server: try that language again.
    func retry(_ languageId: String) {
        missing[languageId] = nil
        for f in wb?.files ?? [] where Language.id(for: f.path) == languageId { opened(f.path) }
    }

    /// Progress text for the language of `path`, if its server is busy.
    func progress(for path: String) -> String? {
        Language.id(for: path).flatMap { lspLanguageName(languageId: $0) }.flatMap { progress[$0] }
    }

    func serverName(for path: String) -> String? {
        docServer[path]?.name()
    }

    // MARK: diagnostics

    var counts: (errors: Int, warnings: Int) {
        var e = 0, w = 0
        for list in diagnostics.values {
            for d in list {
                if d.severity == 1 { e += 1 } else if d.severity == 2 { w += 1 }
            }
        }
        return (e, w)
    }

    /// Errors and warnings in a file, or anywhere under a folder.
    func problemSummary(for path: String, folder: Bool) -> (errors: Int, warnings: Int) {
        var e = 0, w = 0
        for (p, list) in diagnostics where p == path || (folder && (p.hasPrefix(path + "/") || p.hasPrefix(path + "\\"))) {
            for d in list {
                if d.severity == 1 { e += 1 } else if d.severity == 2 { w += 1 }
            }
        }
        return (e, w)
    }

    func diagnostics(onLine line: Int, path: String) -> [Diag] {
        (diagnostics[path] ?? []).filter { Int($0.range.start.line) <= line && line <= Int($0.range.end.line) && $0.severity <= 3 }
            .sorted { $0.severity < $1.severity }
    }

    /// Background tints for problems in an editor (Runestone has no squiggles).
    func highlights(for path: String, in tv: TextView, theme: VSTheme) -> [HighlightedRange] {
        let length = (tv.text as NSString).length
        return (diagnostics[path] ?? []).enumerated().compactMap { i, d in
            guard d.severity <= 3, var range = nsRange(d.range, in: tv) else { return nil }
            if range.length == 0 { // point diagnostics: tint one character
                range = range.location < length ? NSRange(location: range.location, length: 1)
                    : NSRange(location: max(range.location - 1, 0), length: min(1, length))
            }
            let key = d.severity == 1 ? "editorError.foreground" : d.severity == 2 ? "editorWarning.foreground" : "editorInfo.foreground"
            let fallback = d.severity == 1 ? "#f14c4c" : d.severity == 2 ? "#cca700" : "#3794ff"
            let color = theme.uiColor(key, default: fallback).withAlphaComponent(d.severity == 3 ? 0.18 : 0.3)
            return HighlightedRange(id: "diag-\(i)-\(range.location)-\(range.length)-\(d.severity)", range: range, color: color, cornerRadius: 2)
        }
    }

    func nsRange(_ r: LspRange, in tv: TextView) -> NSRange? {
        guard let s = offset(r.start, in: tv) else { return nil }
        let e = offset(r.end, in: tv) ?? s
        return NSRange(location: s, length: max(e - s, 0))
    }

    func offset(_ p: LspPos, in tv: TextView) -> Int? {
        tv.location(at: TextLocation(lineNumber: Int(p.line), column: Int(p.character)))
    }

    fileprivate func receive(path: String, items: [Diag]) {
        if items.isEmpty { diagnostics[path] = nil } else { diagnostics[path] = items }
    }

    fileprivate func receive(language: String, progress text: String?) {
        progress[language] = text
    }

    // MARK: completion

    /// Called after every edit in an editor.
    func typed(in tv: TextView, path: String) {
        hover = nil
        updateSignature(tv, path: path)
        if suppressNextTrigger { suppressNextTrigger = false; completion = nil; return }
        let ns = tv.text as NSString
        let caret = tv.selectedRange.location
        guard tv.selectedRange.length == 0, caret > 0, caret <= ns.length, let server = docServer[path] else {
            completion = nil
            return
        }
        let ch = ns.substring(with: NSRange(location: caret - 1, length: 1))
        let start = wordStart(ns, caret)
        if var c = completion, c.path == path, start == c.wordStart, isWordChar(ch) {
            c.visible = filter(c.items, prefix: ns.substring(with: NSRange(location: start, length: caret - start)))
            c.selected = 0
            c.anchor = caretRect(tv) ?? c.anchor
            completion = c.visible.isEmpty ? nil : c
            return
        }
        let trigger = server.triggerCharacters().contains(ch)
        if (isWordChar(ch) && AppSettings.shared.autoSuggest) || trigger {
            requestCompletion(tv, path: path, after: .milliseconds(60))
        } else {
            completion = nil
        }
    }

    /// ⌃Space / ⌘I, or after typing.
    func requestCompletion(_ tv: TextView? = nil, path: String? = nil, after delay: Duration = .zero) {
        guard let tv = tv ?? activeView, let path = path ?? activePath, let server = docServer[path] else { return }
        completionTask?.cancel()
        completionTask = Task { [weak tv] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let tv, let loc = tv.textLocation(at: tv.selectedRange.location) else { return }
            let caretAtRequest = tv.selectedRange.location
            guard let items = try? await server.completion(path: path, line: UInt32(loc.lineNumber), character: UInt32(loc.column)),
                  !Task.isCancelled, !items.isEmpty else { return }
            let ns = tv.text as NSString
            let caret = tv.selectedRange.location
            // Typing may have moved on; keep going only within the same word.
            let start = wordStart(ns, min(caretAtRequest, caret))
            guard caret >= start, wordStart(ns, caret) == start || caret == caretAtRequest else { return }
            let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
            let visible = filter(items, prefix: prefix)
            guard !visible.isEmpty, let anchor = caretRect(tv) else { completion = nil; return }
            completion = CompletionState(path: path, items: items, visible: visible, anchor: anchor, wordStart: start)
        }
    }

    func moveSelection(_ delta: Int) {
        guard var c = completion, !c.visible.isEmpty else { return }
        c.selected = (c.selected + delta + c.visible.count) % c.visible.count
        completion = c
    }

    func accept(_ item: CompletionItem? = nil, in tv: TextView? = nil) {
        guard let c = completion, let tv = tv ?? activeView,
              let item = item ?? (c.visible.indices.contains(c.selected) ? c.visible[c.selected] : nil) else { return }
        let caret = tv.selectedRange.location
        var range = NSRange(location: c.wordStart, length: max(caret - c.wordStart, 0))
        if let r = item.editRange, let s = offset(r.start, in: tv), s <= caret {
            // The server's range was for the text at request time; extend it over
            // whatever was typed since, like VS Code does.
            range = NSRange(location: s, length: max(offset(r.end, in: tv) ?? caret, caret) - s)
        }
        completion = nil
        suppressNextTrigger = true
        tv.replace(range, withText: item.insertText)
        tv.selectedRange = NSRange(location: range.location + (item.insertText as NSString).length, length: 0)
        // Make sure the model and server see the edit even if replace() doesn't
        // report it through the delegate.
        if let path = activePath {
            wb?.edited(path, text: tv.text)
            changed(path, text: tv.text)
        }
    }

    private func filter(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        let p = prefix.lowercased()
        var scored: [(item: CompletionItem, rank: Int)] = []
        for item in items {
            let key = item.filterText.lowercased()
            if p.isEmpty || key.hasPrefix(p) {
                scored.append((item, 0))
            } else if isSubsequence(p, of: key) {
                scored.append((item, 1))
            }
        }
        scored.sort { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.item.sortText != b.item.sortText ? a.item.sortText < b.item.sortText : a.item.label < b.item.label
        }
        return scored.prefix(200).map(\.item)
    }

    /// Parameter hints: open on "(" or ",", close on ")".
    private func updateSignature(_ tv: TextView, path: String) {
        let ns = tv.text as NSString
        let caret = tv.selectedRange.location
        guard caret > 0, caret <= ns.length else { signature = nil; return }
        switch ns.substring(with: NSRange(location: caret - 1, length: 1)) {
        case "(", ",": requestSignature(tv, path: path)
        case ")": signature = nil
        default: if signature != nil { requestSignature(tv, path: path) } // keep the active parameter current
        }
    }

    // MARK: formatting & symbols

    /// Format Document: applies the server's edits to the file's text.
    func format(_ path: String) async {
        guard let s = docServer[path], s.canFormat(), let wb,
              let text = wb.files.first(where: { $0.path == path })?.text else { return }
        let ts = UInt32(wb.tabSize)
        guard let edits = try? await s.format(path: path, tabSize: ts, insertSpaces: true), !edits.isEmpty else { return }
        wb.setText(path, Self.apply(edits, to: text))
    }

    /// Applies LSP edits (UTF-16 positions) to text, last edit first.
    static func apply(_ edits: [Edit], to text: String) -> String {
        let ns = NSMutableString(string: text)
        // Line start offsets (UTF-16).
        var starts = [0]
        let len = ns.length
        var i = 0
        while i < len {
            if ns.character(at: i) == 10 { starts.append(i + 1) }
            i += 1
        }
        func offset(_ p: LspPos) -> Int {
            let line = Int(p.line)
            guard line < starts.count else { return len }
            let lineEnd = line + 1 < starts.count ? starts[line + 1] - 1 : len
            return min(starts[line] + Int(p.character), lineEnd)
        }
        let sorted = edits.sorted { a, b in
            (a.range.start.line, a.range.start.character) > (b.range.start.line, b.range.start.character)
        }
        for e in sorted {
            let s = offset(e.range.start), t = max(offset(e.range.end), s)
            ns.replaceCharacters(in: NSRange(location: s, length: t - s), with: e.newText)
        }
        return ns as String
    }

    func canFormat(_ path: String) -> Bool { docServer[path]?.canFormat() ?? false }

    func server(of path: String) -> LspServer? { docServer[path] }

    /// Outline for a document, or nil if no server/symbols.
    func symbols(_ path: String) async -> [DocSymbol]? {
        guard let s = docServer[path], s.canSymbols() else { return nil }
        return try? await s.symbols(path: path)
    }

    // MARK: hover & definition

    /// ⌘K ⌘I: server hover info plus any problems at the cursor.
    func showHover() {
        guard let tv = activeView, let path = activePath, let anchor = caretRect(tv) else { return }
        Task { await showHover(at: tv.selectedRange.location, anchor: anchor, in: tv, path: path, quiet: false) }
    }

    /// Hover info for the character at `location`. Quiet (pointer hover): shows
    /// nothing when there's nothing to say, as VS Code does.
    private func showHover(at location: Int, anchor: CGRect, in tv: TextView, path: String, quiet: Bool) async {
        guard let loc = tv.textLocation(at: location) else { return }
        let problems = diagnostics(onLine: loc.lineNumber, path: path)
            .filter { !quiet || Int($0.range.start.line) < loc.lineNumber || Int($0.range.start.character) <= loc.column }
            .filter { !quiet || Int($0.range.end.line) > loc.lineNumber || loc.column <= Int($0.range.end.character) }
            .map { d in "\(d.severity == 1 ? "Error" : d.severity == 2 ? "Warning" : "Info"): \(d.message)\(d.source.map { " (\($0))" } ?? "")" }
        var parts = problems
        if let s = docServer[path],
           let text = try? await s.hover(path: path, line: UInt32(loc.lineNumber), character: UInt32(loc.column)), !text.isEmpty {
            parts.append(text)
        }
        if quiet && (parts.isEmpty || pointerHoverToken == nil) { return }
        hover = parts.isEmpty ? HoverState(text: "No information available.", anchor: anchor)
            : HoverState(text: parts.joined(separator: "\n\n"), anchor: anchor, fromPointer: quiet)
    }

    /// The pointer rests on a word for 0.5 s: hover it, like desktop VS Code.
    /// Moving to another word or out of the editor cancels or hides it.
    private var pointerHoverToken: NSRange?
    private var pointerHoverTask: Task<Void, Never>?
    func pointerMoved(_ point: CGPoint?, in tv: TextView) {
        guard let point, let path = activePath, tv === activeView,
              let pos = tv.closestPosition(to: point), let word = wordRange(at: tv.offset(from: tv.beginningOfDocument, to: pos), in: tv) else {
            pointerLeft()
            return
        }
        guard word != pointerHoverToken else { return }
        pointerHoverToken = word
        pointerHoverTask?.cancel()
        if hover?.fromPointer == true { hover = nil }
        pointerHoverTask = Task { [weak self, weak tv] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let tv, self.completion == nil,
                  let start = tv.position(from: tv.beginningOfDocument, offset: word.location),
                  let end = tv.position(from: start, offset: word.length),
                  let range = tv.textRange(from: start, to: end) else { return }
            let anchor = tv.convert(tv.firstRect(for: range), to: nil)
            await self.showHover(at: word.location, anchor: anchor, in: tv, path: path, quiet: true)
        }
    }

    func pointerLeft() {
        pointerHoverToken = nil
        pointerHoverTask?.cancel()
        // ponytail: VS Code keeps the card while the pointer moves onto it; here it
        // closes once the pointer leaves the word (cards with links can't be clicked).
        if hover?.fromPointer == true { hover = nil }
    }

    /// The identifier under `offset`, or nil over whitespace and punctuation.
    private func wordRange(at offset: Int, in tv: TextView) -> NSRange? {
        let ns = tv.text as NSString
        guard offset >= 0, offset < ns.length, isWordChar(ns.substring(with: NSRange(location: offset, length: 1))) else { return nil }
        let start = wordStart(ns, offset)
        var end = offset
        while end < ns.length, isWordChar(ns.substring(with: NSRange(location: end, length: 1))) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// F12: jump to the definition of the symbol at the cursor.
    func goToDefinition() {
        guard let tv = activeView, let path = activePath, let s = docServer[path],
              let loc = tv.textLocation(at: tv.selectedRange.location) else { return }
        Task {
            do {
                let locs = try await s.definition(path: path, line: UInt32(loc.lineNumber), character: UInt32(loc.column))
                guard let target = locs.first else {
                    wb?.alert = "No definition found."
                    return
                }
                await wb?.open(target.path, line: Int(target.range.start.line) + 1, column: Int(target.range.start.character))
            } catch {
                wb?.alert = error.localizedDescription
            }
        }
    }

    // MARK: helpers

    private func caretRect(_ tv: TextView) -> CGRect? {
        guard let end = tv.selectedTextRange?.end else { return nil }
        return tv.convert(tv.caretRect(for: end), to: nil)
    }

    private func isWordChar(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
    }

    private func wordStart(_ ns: NSString, _ caret: Int) -> Int {
        var i = caret
        while i > 0, isWordChar(ns.substring(with: NSRange(location: i - 1, length: 1))) { i -= 1 }
        return i
    }

    private func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        return q.allSatisfy { c in
            while let n = it.next() { if n == c { return true } }
            return false
        }
    }

    /// Events arrive on a Rust thread; hop to the main actor.
    private final class Sink: LspSink, @unchecked Sendable {
        weak var owner: Languages?
        let name: String
        init(owner: Languages, name: String) {
            self.owner = owner
            self.name = name
        }

        func onDiagnostics(path: String, items: [Diag]) {
            Task { @MainActor [weak owner] in owner?.receive(path: path, items: items) }
        }

        func onStatus(text: String?) {
            Task { @MainActor [weak owner, name] in owner?.receive(language: name, progress: text) }
        }

        func onApplyEdit(files: [FileEdits]) {
            Task { @MainActor [weak owner] in await owner?.applyFileEdits(files) }
        }

        func onExit(message: String) {
            Task { @MainActor [weak owner, name] in
                guard let owner else { return }
                owner.progress[name] = nil
                // Drop dead servers; the next edit or open starts a fresh one.
                owner.servers = owner.servers.filter { $0.value.alive() }
                owner.docServer = owner.docServer.filter { $0.value.alive() }
            }
        }
    }
}

// MARK: - Popups

/// VS Code's suggest widget, anchored under the caret.
struct CompletionPopup: View {
    @EnvironmentObject var languages: Languages
    @EnvironmentObject var wb: Workbench

    var body: some View {
        GeometryReader { geo in
            if let c = languages.completion, !c.visible.isEmpty {
                let t = wb.theme
                let origin = geo.frame(in: .global).origin
                let rows = min(c.visible.count, 12)
                let height = CGFloat(rows) * 24
                let below = c.anchor.maxY - origin.y + 2
                let y = below + height > geo.size.height ? c.anchor.minY - origin.y - height - 2 : below
                let x = min(max(c.anchor.minX - origin.x - 24, 4), max(geo.size.width - 444, 4))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(c.visible.enumerated()), id: \.offset) { i, item in
                                row(item, selected: i == c.selected, t)
                                    .id(i)
                                    .onTapGesture { languages.accept(item) }
                            }
                        }
                    }
                    .onChange(of: c.selected) { proxy.scrollTo(c.selected) }
                }
                .frame(width: 440, height: height)
                .background(t.ui("editorSuggestWidget.background", "editorWidget.background", default: "#252526"))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.ui("editorSuggestWidget.border", "editorWidget.border", default: "#454545")))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: t.widgetShadow, radius: 6)
                .offset(x: x, y: y)
            }
        }
    }

    private func row(_ item: CompletionItem, selected: Bool, _ t: VSTheme) -> some View {
        let (icon, colorKey) = kindIcon(item.kind)
        return HStack(spacing: 6) {
            CodiconView(icon: icon, size: 14)
                .foregroundStyle(t.ui(colorKey, default: "#75beff"))
                .frame(width: 18)
            Text(item.label).font(.custom("Menlo", size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if let d = item.detail {
                Text(d).font(.system(size: 12)).foregroundStyle(t.descriptionFg).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .foregroundStyle(selected ? t.ui("editorSuggestWidget.selectedForeground", "list.activeSelectionForeground", default: "#ffffff")
                         : t.ui("editorSuggestWidget.foreground", "editor.foreground", default: "#d4d4d4"))
        .background(selected ? t.ui("editorSuggestWidget.selectedBackground", "list.activeSelectionBackground", default: "#04395e") : .clear)
        .hoverBackground(selected ? .clear : t.ui("editorSuggestWidget.hoverBackground", "list.hoverBackground", default: "#2a2d2e"))
        .contentShape(Rectangle())
    }

    /// LSP CompletionItemKind -> codicon + VS Code's symbolIcon color key.
    private func kindIcon(_ kind: UInt8) -> (Codicon, String) {
        switch kind {
        case 2, 3, 4: (.symbolMethod, "symbolIcon.methodForeground")
        case 5: (.symbolField, "symbolIcon.fieldForeground")
        case 6: (.symbolVariable, "symbolIcon.variableForeground")
        case 7: (.symbolClass, "symbolIcon.classForeground")
        case 8: (.symbolInterface, "symbolIcon.interfaceForeground")
        case 9: (.symbolNamespace, "symbolIcon.moduleForeground")
        case 10: (.symbolProperty, "symbolIcon.propertyForeground")
        case 11: (.symbolUnit, "symbolIcon.unitForeground")
        case 12: (.symbolEnum, "symbolIcon.enumeratorForeground")
        case 13: (.symbolEnum, "symbolIcon.enumeratorForeground")
        case 14: (.symbolKeyword, "symbolIcon.keywordForeground")
        case 15: (.symbolSnippet, "symbolIcon.snippetForeground")
        case 16: (.symbolColor, "symbolIcon.colorForeground")
        case 17: (.symbolFile, "symbolIcon.fileForeground")
        case 18: (.goToFile, "symbolIcon.referenceForeground")
        case 19: (.folder, "symbolIcon.folderForeground")
        case 20: (.symbolEnumMember, "symbolIcon.enumeratorMemberForeground")
        case 21: (.symbolConstant, "symbolIcon.constantForeground")
        case 22: (.symbolStruct, "symbolIcon.structForeground")
        case 23: (.symbolEvent, "symbolIcon.eventForeground")
        case 24: (.symbolOperator, "symbolIcon.operatorForeground")
        case 25: (.symbolTypeParameter, "symbolIcon.typeParameterForeground")
        default: (.symbolText, "symbolIcon.textForeground")
        }
    }
}

/// Hover card (⌘K ⌘I): type info and docs from the server, plus problems.
struct HoverPopup: View {
    @EnvironmentObject var languages: Languages
    @EnvironmentObject var wb: Workbench

    var body: some View {
        GeometryReader { geo in
            if let h = languages.hover {
                let t = wb.theme
                let origin = geo.frame(in: .global).origin
                let width = min(560, geo.size.width - 16)
                let x = min(max(h.anchor.minX - origin.x, 8), geo.size.width - width - 8)
                let above = h.anchor.minY - origin.y > geo.size.height / 2
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(blocks(h.text).enumerated()), id: \.offset) { _, b in
                            Text(b.code ? AttributedString(b.text) : Self.markdown(b.text))
                                .font(b.code ? .custom("Menlo", size: 12) : .system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(width: width)
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(t.ui("editorHoverWidget.foreground", "editor.foreground", default: "#cccccc"))
                .background(t.ui("editorHoverWidget.background", "editorWidget.background", default: "#252526"))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.ui("editorHoverWidget.border", default: "#454545")))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: t.widgetShadow, radius: 6)
                .offset(x: x, y: above ? max(h.anchor.minY - origin.y - 290, 4) : h.anchor.maxY - origin.y + 4)
                .onTapGesture { languages.hover = nil }
            }
        }
    }

    /// Inline markdown (bold, `code`, links); headings become bold lines.
    static func markdown(_ s: String) -> AttributedString {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return String(line) }
            let title = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "" : "**\(title)**"
        }
        let joined = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(joined)
    }

    /// Splits markdown into prose and ``` code blocks (rendered monospace).
    private func blocks(_ s: String) -> [(text: String, code: Bool)] {
        var out: [(String, Bool)] = []
        var code = false
        var cur: [Substring] = []
        func flush() {
            let t = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append((t, code)) }
            cur = []
        }
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                code.toggle()
            } else if !(line == "---" && !code) {
                cur.append(line)
            }
        }
        flush()
        return out.map { (text: $0.0, code: $0.1) }
    }
}

/// VS Code's PROBLEMS panel.
struct ProblemsView: View {
    @EnvironmentObject var languages: Languages
    @EnvironmentObject var wb: Workbench

    var body: some View {
        let t = wb.theme
        let files = languages.diagnostics.keys.sorted()
        if files.isEmpty {
            Text("No problems have been detected in the workspace.")
                .font(.system(size: 13)).foregroundStyle(t.descriptionFg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files, id: \.self) { path in
                        let items = (languages.diagnostics[path] ?? []).sorted { ($0.severity, $0.range.start.line) < ($1.severity, $1.range.start.line) }
                        HStack(spacing: 6) {
                            FileIcon(name: wb.baseName(path), size: 14)
                            Text(wb.baseName(path)).font(.system(size: 13))
                            Text(wb.relative(wb.parentDir(path))).font(.system(size: 12)).foregroundStyle(t.descriptionFg).lineLimit(1)
                            Text("\(items.count)").font(.system(size: 11)).padding(.horizontal, 5)
                                .background(t.activityBadgeBg).clipShape(Capsule())
                        }
                        .padding(.horizontal, 12).frame(height: 22)
                        ForEach(Array(items.enumerated()), id: \.offset) { _, d in
                            HStack(spacing: 6) {
                                severityIcon(d.severity, t)
                                Text(d.message).font(.system(size: 13)).lineLimit(2)
                                if let src = d.source {
                                    Text(d.code.map { "\(src)(\($0))" } ?? src).font(.system(size: 12)).foregroundStyle(t.descriptionFg)
                                }
                                Text("[Ln \(d.range.start.line + 1), Col \(d.range.start.character + 1)]")
                                    .font(.system(size: 12)).foregroundStyle(t.descriptionFg)
                                Spacer()
                            }
                            .padding(.leading, 34).padding(.vertical, 3)
                            .hoverBackground(t.listHoverBg)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await wb.open(path, line: Int(d.range.start.line) + 1, column: Int(d.range.start.character)) }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(t.panelTitleActiveFg)
        }
    }
}

@ViewBuilder
func severityIcon(_ severity: UInt8, _ t: VSTheme, size: CGFloat = 14) -> some View {
    switch severity {
    case 1: CodiconView(icon: .error, size: size).foregroundStyle(t.ui("problemsErrorIcon.foreground", "editorError.foreground", default: "#f14c4c"))
    case 2: CodiconView(icon: .warning, size: size).foregroundStyle(t.ui("problemsWarningIcon.foreground", "editorWarning.foreground", default: "#cca700"))
    default: CodiconView(icon: .info, size: size).foregroundStyle(t.ui("problemsInfoIcon.foreground", "editorInfo.foreground", default: "#3794ff"))
    }
}

/// Runestone's text view plus the keys VS Code's editor widgets need. They live
/// here, not as app-wide shortcuts, so the terminal still gets Esc and ⌃Space.
/// The suggest list takes ↑ ↓ Return Tab Esc while open; Esc closes a hover;
/// ⌃Space suggests; F12 goes to definition.
final class PadTextView: TextView {
    var completionVisible: () -> Bool = { false }
    var hoverVisible: () -> Bool = { false }
    var onPopupKey: (String) -> Void = { _ in }
    var onSuggest: () -> Void = {}
    var onDefinition: () -> Void = {}
    var onGotoLine: () -> Void = {}
    var onKey: (String) -> Void = { _ in }
    /// The open file's name, for its comment syntax.
    var fileName = ""
    /// Diagnostic tints; the matching-bracket highlight is drawn on top.
    var diagnosticRanges: [HighlightedRange] = [] {
        didSet { if diagnosticRanges != oldValue { highlightedRanges = diagnosticRanges + bracketRanges } }
    }
    private var bracketRanges: [HighlightedRange] = []
    var bracketColor = UIColor.gray

    /// Highlights the bracket at the caret and its partner (looks ±20k characters).
    func updateBracketMatch() {
        var ranges: [HighlightedRange] = []
        if selectedRange.length == 0 {
            let start = max(selectedRange.location - 20_000, 0)
            let window = NSRange(location: start, length: min(40_000, (text as NSString).length - start))
            if let w = text(in: window), let (a, b) = Brackets.match(w as NSString, caret: selectedRange.location - start) {
                ranges = [a, b].map { HighlightedRange(id: "bracket-\($0 + start)", range: NSRange(location: $0 + start, length: 1), color: bracketColor, cornerRadius: 2) }
            }
        }
        guard ranges != bracketRanges else { return }
        bracketRanges = ranges
        highlightedRanges = diagnosticRanges + bracketRanges
    }
    /// Called once the view has (re)gained width, e.g. to apply highlights.
    var onSized: () -> Void = {}
    private var laidOutWidth: CGFloat = 0

    /// Runestone typesets each line only as far as the viewport is wide. Lines
    /// prepared while the view was still narrow (it starts small inside SwiftUI)
    /// stayed cut off, so re-typeset the visible lines whenever it gets wider.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > laidOutWidth + 0.5 else {
            laidOutWidth = min(laidOutWidth, bounds.width)
            return
        }
        laidOutWidth = bounds.width
        DispatchQueue.main.async { [weak self] in
            self?.redisplayVisibleLines()
            self?.onSized()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var cmds = super.keyCommands ?? []
        cmds.append(UIKeyCommand(input: UIKeyCommand.f12, modifierFlags: [], action: #selector(definitionKey)))
        let suggest = UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(suggestKey))
        suggest.wantsPriorityOverSystemBehavior = true
        cmds.append(suggest)
        let gotoLine = UIKeyCommand(input: "g", modifierFlags: .control, action: #selector(gotoLineKey))
        gotoLine.wantsPriorityOverSystemBehavior = true
        cmds.append(gotoLine)
        for (input, mods, name) in [(UIKeyCommand.f2, UIKeyModifierFlags(), "rename"), (UIKeyCommand.f12, .shift, "references"),
                                    (".", .command, "quickfix"), (" ", [.command, .shift], "signature"),
                                    (UIKeyCommand.f5, .control, "run")] {
            let c = UIKeyCommand(input: input, modifierFlags: mods, action: #selector(namedKey(_:)))
            c.wantsPriorityOverSystemBehavior = true
            c.title = name
            cmds.append(c)
        }
        for (input, mods, action): (String, UIKeyModifierFlags, Selector) in [("/", .command, #selector(toggleComment)),
                                      ("k", UIKeyModifierFlags([.command, .shift]), #selector(deleteLines)),
                                      (UIKeyCommand.inputUpArrow, .alternate, #selector(moveLinesUp)),
                                      (UIKeyCommand.inputDownArrow, .alternate, #selector(moveLinesDown)),
                                      (UIKeyCommand.inputUpArrow, UIKeyModifierFlags([.alternate, .shift]), #selector(copyLinesUp)),
                                      (UIKeyCommand.inputDownArrow, UIKeyModifierFlags([.alternate, .shift]), #selector(copyLinesDown)),
                                      ("]", .command, #selector(indentLines)), ("[", .command, #selector(outdentLines)),
                                      ("\r", .command, #selector(insertLineBelow)), ("\r", UIKeyModifierFlags([.command, .shift]), #selector(insertLineAbove))] {
            let c = UIKeyCommand(input: input, modifierFlags: mods, action: action)
            c.wantsPriorityOverSystemBehavior = true
            cmds.append(c)
        }
        let keys = completionVisible()
            ? [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape, "\r", "\t"]
            : hoverVisible() ? [UIKeyCommand.inputEscape] : []
        for key in keys {
            let c = UIKeyCommand(input: key, modifierFlags: [], action: #selector(popupKey(_:)))
            c.wantsPriorityOverSystemBehavior = true
            cmds.append(c)
        }
        return cmds
    }

    @objc private func popupKey(_ c: UIKeyCommand) { onPopupKey(c.input ?? "") }
    @objc private func suggestKey() { onSuggest() }
    @objc private func definitionKey() { onDefinition() }
    @objc private func gotoLineKey() { onGotoLine() }
    @objc private func namedKey(_ c: UIKeyCommand) { onKey(c.title) }

    // Line commands; also sent down the responder chain by the menu bar.
    @objc func toggleComment() { perform(.toggleComment) }
    @objc func deleteLines() { perform(.deleteLines) }
    @objc func copyLinesUp() { perform(.copyLines(down: false)) }
    @objc func copyLinesDown() { perform(.copyLines(down: true)) }
    @objc func insertLineBelow() { perform(.insertLine(below: true)) }
    @objc func insertLineAbove() { perform(.insertLine(below: false)) }
    @objc func moveLinesUp() { moveSelectedLinesUp() }
    @objc func moveLinesDown() { moveSelectedLinesDown() }
    @objc func indentLines() { shiftRight() }
    @objc func outdentLines() { shiftLeft() }

    /// Applies a line command as one undoable edit.
    func perform(_ edit: LineEdit) {
        guard let r = edit.apply(to: text as NSString, selection: selectedRange, fileName: fileName) else { return }
        replace(r.range, withText: r.text)
        selectedRange = r.selection
        scrollRangeToVisible(r.selection)
    }
}
