import Runestone
import SwiftUI
import UIKit

/// VS Code's editor area: one or two editor groups side by side.
struct EditorArea: View {
    @EnvironmentObject var wb: Workbench

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(wb.groups.enumerated()), id: \.element.id) { i, _ in
                if i > 0 { Rectangle().fill(wb.theme.ui("editorGroup.border", default: "#444444")).frame(width: 1) }
                EditorGroup(index: i)
            }
        }
        .overlay { HoverPopup() }
        .overlay { SignaturePopup() }
        .overlay { CompletionPopup() }
        .background { RenameField() }
    }
}

/// One editor group: tab strip, breadcrumbs, and the active document.
struct EditorGroup: View {
    let index: Int
    @EnvironmentObject var wb: Workbench

    var body: some View {
        let t = wb.theme
        let group = wb.groups.indices.contains(index) ? wb.groups[index] : EditorGroupState()
        let focused = wb.focusedGroup == index
        let file = wb.file(group.active)
        VStack(spacing: 0) {
            if !group.tabs.isEmpty {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(group.tabs, id: \.self) { path in
                                if let f = wb.file(path) { EditorTab(file: f, group: index) }
                            }
                        }
                    }
                    GroupActions(index: index, file: file)
                }
                .frame(height: 35)
                .background(t.tabsBg)
                .opacity(focused || wb.groups.count == 1 ? 1 : 0.85)
                if let file, file.viewer == .text || file.viewer == .markdownPreview { Breadcrumbs(file: file) }
            }
            ZStack {
                t.editorBg
                if let file {
                    switch file.viewer {
                    case .text:
                        CodeEditor(file: file, group: index).id("\(index):\(file.path)")
                            .overlay(alignment: .bottom) { ProblemPeek(file: file) }
                    case .image: ImageViewer(path: file.path)
                    case .pdf: PDFViewer(path: file.path)
                    case .markdownPreview: MarkdownPreview(file: file)
                    case .browser: BrowserView(file: file)
                    }
                } else {
                    Watermark()
                }
            }
            .simultaneousGesture(TapGesture().onEnded { wb.focusedGroup = index })
        }
    }
}

/// Right end of a group's tab strip: preview, split, close group.
private struct GroupActions: View {
    let index: Int
    let file: OpenFile?
    @EnvironmentObject var wb: Workbench

    var body: some View {
        HStack(spacing: 2) {
            if let file, file.viewer == .text, let env = wb.env, RunTask.runFile(file.path, os: env.os, cargoRoot: nil) != nil {
                Button { wb.runActiveFile() } label: { CodiconView(icon: .play, size: 16) }
                    .tip("Run File")
            }
            if let file, Language.id(for: file.name) == "markdown" {
                Button { wb.openMarkdownPreview(file.path) } label: { CodiconView(icon: .openPreview, size: 16) }
                    .tip("Open Preview to the Side")
            }
            if wb.groups.count == 1 {
                Button { wb.splitRight() } label: { CodiconView(icon: .splitHorizontal, size: 16) }
                    .tip("Split Editor Right")
            } else {
                Button { wb.closeGroup(index) } label: { CodiconView(icon: .close, size: 16) }
                    .tip("Close Group")
            }
        }
        .buttonStyle(ToolbarButtonStyle())
        .foregroundStyle(wb.theme.tabInactiveFg)
        .padding(.horizontal, 6)
    }
}

private struct EditorTab: View {
    let file: OpenFile
    let group: Int
    @EnvironmentObject var wb: Workbench
    @State private var hover = false

    var body: some View {
        let t = wb.theme
        let active = wb.groups.indices.contains(group) && wb.groups[group].active == file.path
        let title = file.viewer == .markdownPreview ? "Preview \(file.name)"
            : file.viewer == .browser ? "Port \(file.path.replacingOccurrences(of: "port:", with: ""))" : file.name
        HStack(spacing: 6) {
            if file.viewer == .markdownPreview || file.viewer == .browser {
                CodiconView(icon: file.viewer == .browser ? .globe : .openPreview, size: 14).foregroundStyle(t.highlightFg)
            } else {
                FileIcon(name: file.name, size: 14)
            }
            Text(title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(active ? t.tabActiveFg : hover ? t.tabHoverFg : t.tabInactiveFg)
            Button { wb.close(file.path, in: group) } label: {
                if file.dirty && !hover {
                    CodiconView(icon: .circleFilled, size: 10).foregroundStyle(t.modifiedDot)
                } else {
                    CodiconView(icon: .close, size: 14)
                        .foregroundStyle(active ? t.tabActiveFg : t.tabInactiveFg)
                        .opacity(active || hover ? 1 : 0)
                }
            }
            .buttonStyle(ToolbarButtonStyle(padding: 2))
            .frame(width: 20)
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 35)
        .background(active ? t.tabActiveBg : hover ? t.tabHoverBg : t.tabInactiveBg)
        .overlay(alignment: .top) { if active && wb.focusedGroup == group { Rectangle().fill(t.tabActiveBorderTop).frame(height: 1) } }
        .overlay(alignment: .trailing) { Rectangle().fill(t.tabBorder).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { wb.focus(file.path, in: group) }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Close") { wb.close(file.path, in: group) }
            Button("Close Others") {
                for p in wb.groups[group].tabs where p != file.path { wb.close(p, in: group) }
            }
            if wb.groups.count == 1 {
                Button("Split Right") { wb.focus(file.path, in: group); wb.splitRight() }
            } else {
                Button("Move to Other Group") { wb.moveToOtherGroup(file.path, from: group) }
            }
            if file.viewer == .text {
                Button("Download to iPad…") { wb.download(file.path) }
            }
            Button("Copy Path") { UIPasteboard.general.string = file.path }
            Button("Copy Relative Path") { UIPasteboard.general.string = wb.relative(file.path) }
        }
    }
}

private struct Breadcrumbs: View {
    let file: OpenFile
    @EnvironmentObject var wb: Workbench
    var body: some View {
        let parts = wb.relative(file.path).split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        HStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i > 0 { CodiconView(icon: .chevronRight, size: 12) }
                if i == parts.count - 1 { FileIcon(name: p, size: 12) }
                Text(p).font(.system(size: 12)).lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(wb.theme.breadcrumbFg)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(wb.theme.editorBg)
    }
}

private struct Watermark: View {
    @EnvironmentObject var wb: Workbench
    var body: some View {
        VStack(spacing: 10) {
            CodiconView(icon: .remote, size: 96).opacity(0.08)
            if wb.root.isEmpty { start }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Show All Commands", "⇧ ⌘ P")
                row("Go to File", "⌘ P")
                row("Find in Files", "⇧ ⌘ F")
                row("Toggle Terminal", "⌃ `")
                row("Toggle Sidebar", "⌘ B")
            }
            .font(.system(size: 13))
            .foregroundStyle(wb.theme.descriptionFg)
        }
    }

    /// VS Code's Welcome "Start" and "Recent" lists, shown until a folder is open.
    private var start: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start").font(.system(size: 15)).foregroundStyle(wb.theme.editorFg)
            Button { wb.picker = true } label: {
                Label { Text("Open Folder or File…") } icon: { CodiconView(icon: .folderOpened, size: 14) }
            }
            Button { wb.newTerminal(); wb.panelOpen = true } label: {
                Label { Text("New Terminal") } icon: { CodiconView(icon: .terminal, size: 14) }
            }
            if !wb.recentFolders.isEmpty {
                Text("Recent").font(.system(size: 15)).foregroundStyle(wb.theme.editorFg).padding(.top, 10)
                ForEach(wb.recentFolders.prefix(6), id: \.self) { path in
                    Button { wb.openFolder(path) } label: {
                        HStack(spacing: 8) {
                            Text(wb.baseName(path))
                            Text(path).foregroundStyle(wb.theme.descriptionFg).lineLimit(1)
                        }
                    }
                }
            }
        }
        .buttonStyle(LinkButtonStyle(hover: wb.theme.linkHoverFg))
        .font(.system(size: 13))
        .foregroundStyle(wb.theme.highlightFg)
        .frame(width: 420, alignment: .leading)
        .padding(.bottom, 24)
    }

    private func row(_ label: String, _ keys: String) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            Text(keys).padding(.horizontal, 5).padding(.vertical, 1)
                .background(wb.theme.inputBg).clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

/// Runestone text view bound to one open file.
struct CodeEditor: UIViewRepresentable {
    let file: OpenFile
    var group = 0
    @EnvironmentObject var wb: Workbench
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var languages: Languages

    /// Each tab's editor lives on while the tab is open, as in VS Code:
    /// switching back reattaches it instead of re-reading and re-parsing the file.
    func makeCoordinator() -> Coordinator {
        let key = "\(group):\(file.path)"
        // Drop editors whose tab has closed; keep at most a dozen.
        wb.editors = wb.editors.filter { k, c in k == key || (wb.groups.indices.contains(c.group) && wb.groups[c.group].tabs.contains(c.path)) }
        if let c = wb.editors[key] { return c }
        let c = Coordinator(wb: wb, path: file.path, group: group)
        if wb.editors.count >= 12, let old = wb.editors.min(by: { $0.value.used < $1.value.used })?.key { wb.editors[old] = nil }
        wb.editors[key] = c
        return c
    }

    func makeUIView(context: Context) -> UIView {
        let c = context.coordinator
        c.used = CACurrentMediaTime()
        let container = UIView()
        let tv = c.tv ?? makeTextView(context: context)
        c.tv = tv
        tv.removeFromSuperview()
        tv.frame = container.bounds
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(tv)
        languages.activeView = tv
        languages.activePath = file.path
        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return container
    }

    private func makeTextView(context: Context) -> PadTextView {
        let tv = PadTextView()
        tv.editorDelegate = context.coordinator
        let langs = languages
        tv.completionVisible = { [weak langs] in langs?.completion != nil }
        tv.hoverVisible = { [weak langs] in langs?.hover != nil || langs?.signature != nil }
        tv.onKey = { [weak langs, weak tv] name in
            guard let langs, let tv else { return }
            switch name {
            case "rename": langs.beginRename()
            case "references": langs.findReferences()
            case "quickfix": langs.showCodeActions()
            case "run": langs.wb?.runActiveFile()
            default: langs.requestSignature(tv, path: langs.activePath ?? "")
            }
        }
        tv.onPopupKey = { [weak langs, weak tv] key in
            guard let langs else { return }
            switch key {
            case UIKeyCommand.inputUpArrow: langs.moveSelection(-1)
            case UIKeyCommand.inputDownArrow: langs.moveSelection(1)
            case UIKeyCommand.inputEscape: langs.completion = nil; langs.hover = nil; langs.signature = nil
            default: langs.accept(in: tv)
            }
        }
        tv.onSuggest = { [weak langs, weak tv] in langs?.requestCompletion(tv) }
        let wbRef = wb
        tv.onGotoLine = { [weak wbRef] in wbRef?.gotoLine = true }
        let path = file.path
        tv.onSized = { [weak tv, weak langs, weak wbRef] in
            guard let tv, let langs, let wbRef else { return }
            tv.diagnosticRanges = langs.highlights(for: path, in: tv, theme: wbRef.theme)
        }
        tv.onDefinition = { [weak langs] in langs?.goToDefinition() }
        tv.addGestureRecognizer(context.coordinator.pointerHover)
        tv.addGestureRecognizer(context.coordinator.commandClick)
        // VS Code's editor context menu, ahead of Cut / Copy / Paste.
        tv.extraEditMenuItems = { [weak langs, weak tv] in
            guard let langs, let tv else { return [] }
            let hasServer = langs.serverName(for: path) != nil
            func item(_ title: String, _ image: String, _ on: Bool = true, _ run: @escaping () -> Void) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: image), attributes: on ? [] : .disabled) { _ in run() }
            }
            let code = UIMenu(options: .displayInline, children: [
                item("Go to Definition", "arrow.right.circle", hasServer) { langs.goToDefinition() },
                item("Find All References", "list.bullet.indent", hasServer) { langs.findReferences() },
                item("Rename Symbol", "pencil", hasServer) { langs.beginRename() },
                item("Quick Fix…", "lightbulb", hasServer) { langs.showCodeActions() },
                item("Show Hover", "info.circle", hasServer) { langs.showHover() },
            ])
            let edit = UIMenu(options: .displayInline, children: [
                item("Format Document", "text.alignleft", hasServer) { Task { await langs.format(path) } },
                item("Toggle Line Comment", "number") { tv.toggleComment() },
            ])
            return [code, edit]
        }
        tv.fileName = file.name
        tv.showLineNumbers = true
        tv.lineSelectionDisplayType = .line
        tv.isLineWrappingEnabled = false
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.isFindInteractionEnabled = true
        tv.alwaysBounceVertical = true
        tv.contentInsetAdjustmentBehavior = .never
        tv.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 120, right: 16)
        tv.characterPairs = [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("`", "`")]
            .map { Pair(leading: $0.0, trailing: $0.1) }
        load(tv, context: context)
        return tv
    }

    func updateUIView(_ container: UIView, context: Context) {
        let c = context.coordinator
        guard let tv = c.tv else { return }
        if c.themeName != wb.theme.name || c.fontSize != wb.fontSize || c.revision != file.revision {
            load(tv, context: context) // new theme, or text changed outside this editor
        }
        tv.indentStrategy = .space(length: wb.tabSize)
        tv.isLineWrappingEnabled = settings.wordWrap
        tv.showTabs = settings.showInvisibles
        tv.showSpaces = settings.showInvisibles
        tv.showLineBreaks = settings.showInvisibles
        // The other group's editor on the same file follows its edits.
        if !tv.isFirstResponder, tv.text != file.text, c.revision == file.revision {
            load(tv, context: context)
        }
        // Applying highlights forces a layout; doing it before the view has its
        // real size typesets lines at the wrong width.
        if tv.bounds.width > 0 {
            tv.diagnosticRanges = languages.highlights(for: file.path, in: tv, theme: wb.theme)
        }
        if let line = file.pendingLine {
            let column = file.pendingColumn
            DispatchQueue.main.async {
                if let column, let loc = tv.location(at: TextLocation(lineNumber: max(line - 1, 0), column: column)) {
                    tv.selectedRange = NSRange(location: loc, length: 0)
                    tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
                } else {
                    _ = tv.goToLine(max(line - 1, 0), select: .line)
                }
                if let i = wb.files.firstIndex(where: { $0.path == file.path }) {
                    wb.files[i].pendingLine = nil
                    wb.files[i].pendingColumn = nil
                }
            }
        }
    }

    static func hasHugeLine(_ text: String, limit: Int = 20_000) -> Bool {
        var run = 0
        for u in text.utf8 {
            if u == 10 { run = 0 } else { run += 1; if run > limit { return true } }
        }
        return false
    }

    private func load(_ tv: TextView, context: Context) {
        let theme = EditorTheme(wb.theme, fontSize: wb.fontSize)
        let text = wb.files.first { $0.path == file.path }?.text ?? file.text
        let selection = tv.selectedRange
        // Plain text past 2 MB or with a line over 20k characters (minified code):
        // tree-sitter reparses and requeries the whole line on every keystroke.
        // Same cut-off as VS Code's editor.maxTokenizationLineLength.
        let language = text.utf16.count > 2_000_000 || Self.hasHugeLine(text) ? nil : Language.treeSitter(for: file.name)
        let state = language.map { TextViewState(text: text, theme: theme, language: $0) }
            ?? TextViewState(text: text, theme: theme)
        tv.setState(state)
        tv.backgroundColor = wb.theme.uiColor("editor.background", default: "#1e1e1e")
        tv.insertionPointColor = wb.theme.uiColor("editorCursor.foreground", default: "#aeafad")
        tv.selectionBarColor = tv.insertionPointColor
        tv.selectionHighlightColor = wb.theme.uiColor("editor.selectionBackground", default: "#264f78")
        (tv as? PadTextView)?.bracketColor = wb.theme.uiColor("editorBracketMatch.background", default: "#0064001a").withAlphaComponent(0.45)
        tv.keyboardAppearance = wb.theme.isDark ? .dark : .light
        if selection.location <= (text as NSString).length { tv.selectedRange = selection }
        context.coordinator.themeName = wb.theme.name
        context.coordinator.fontSize = wb.fontSize
        context.coordinator.revision = file.revision
    }

    final class Coordinator: NSObject, TextViewDelegate, UIGestureRecognizerDelegate {
        let wb: Workbench
        let path: String
        let group: Int
        var themeName = ""
        var fontSize: CGFloat = 0
        var revision = -1
        /// The editor, kept while its tab is open.
        var tv: PadTextView?
        var used: CFTimeInterval = 0
        init(wb: Workbench, path: String, group: Int) {
            self.wb = wb
            self.path = path
            self.group = group
        }

        /// ⌘-click: Go to Definition, as on the desktop.
        lazy var commandClick: UITapGestureRecognizer = {
            let g = UITapGestureRecognizer(target: self, action: #selector(commandClicked))
            g.delegate = self
            return g
        }()
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            g !== commandClick || event.modifierFlags.contains(.command)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        @objc private func commandClicked(_ g: UITapGestureRecognizer) {
            MainActor.assumeIsolated {
                guard let tv = g.view as? TextView, let pos = tv.closestPosition(to: g.location(in: tv)) else { return }
                tv.selectedRange = NSRange(location: tv.offset(from: tv.beginningOfDocument, to: pos), length: 0)
                wb.languages.pointerLeft()
                wb.languages.goToDefinition()
            }
        }

        lazy var pointerHover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))
        @objc private func hovered(_ g: UIHoverGestureRecognizer) {
            MainActor.assumeIsolated {
                guard let tv = g.view as? TextView else { return }
                switch g.state {
                case .began, .changed:
                    // In text-view coordinates, which closestPosition expects.
                    wb.languages.pointerMoved(g.location(in: tv), in: tv)
                default:
                    wb.languages.pointerLeft()
                }
            }
        }

        func textViewDidChange(_ textView: TextView) {
            let t0 = CACurrentMediaTime()
            let text = textView.text
            MainActor.assumeIsolated {
                wb.edited(path, text: text)
                wb.languages.changed(path, text: text)
                wb.languages.typed(in: textView, path: path)
                Scenario.handlerTime += CACurrentMediaTime() - t0
            }
        }

        func textViewDidBeginEditing(_ textView: TextView) {
            MainActor.assumeIsolated {
                wb.languages.activeView = textView
                wb.languages.activePath = path
                if wb.groups.indices.contains(group) { wb.focusedGroup = group }
            }
        }

        /// Return/Tab accept the open suggestion (backup for the key commands).
        func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            MainActor.assumeIsolated {
                guard wb.languages.completion != nil, text.hasPrefix("\n") || text == "\t" else { return true }
                wb.languages.accept(in: textView)
                return false
            }
        }

        func textViewDidChangeSelection(_ textView: TextView) {
            (textView as? PadTextView)?.updateBracketMatch()
            guard let loc = textView.textLocation(at: textView.selectedRange.location) else { return }
            MainActor.assumeIsolated {
                if let i = wb.files.firstIndex(where: { $0.path == path }) {
                    wb.files[i].cursor = (loc.lineNumber + 1, loc.column + 1)
                }
                wb.editorStatus.line = loc.lineNumber + 1
                wb.editorStatus.column = loc.column + 1
                // Moving the caret off the word closes the suggest list, like VS Code.
                if let c = wb.languages.completion, textView.selectedRange.location < c.wordStart {
                    wb.languages.completion = nil
                }
            }
        }
    }
}

/// Auto-closing bracket/quote pair for Runestone.
private struct Pair: CharacterPair {
    let leading: String
    let trailing: String
}

/// The problem on the caret's line, shown under the editor (there's no mouse
/// hover on a touch screen).
private struct ProblemPeek: View {
    let file: OpenFile
    @EnvironmentObject var wb: Workbench
    @EnvironmentObject var languages: Languages
    @EnvironmentObject var status: EditorStatus

    var body: some View {
        let t = wb.theme
        if let d = languages.diagnostics(onLine: status.line - 1, path: file.path).first {
            HStack(alignment: .top, spacing: 6) {
                severityIcon(d.severity, t, size: 13)
                Text(d.message).font(.system(size: 12)).lineLimit(3)
                if let src = d.source { Text(src).font(.system(size: 11)).foregroundStyle(t.descriptionFg) }
                Spacer(minLength: 0)
                Button { languages.showCodeActions() } label: {
                    HStack(spacing: 3) {
                        CodiconView(icon: .lightbulb, size: 13).foregroundStyle(t.ui("editorLightBulb.foreground", default: "#ffcc00"))
                        Text("Quick Fix…").font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(t.ui("editorHoverWidget.foreground", "editor.foreground", default: "#cccccc"))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(t.ui("editorHoverWidget.background", "editorWidget.background", default: "#252526"))
            .overlay(alignment: .top) { Rectangle().fill(t.ui("editorHoverWidget.border", default: "#454545")).frame(height: 1) }
            .onTapGesture { languages.showHover() }
        }
    }
}
