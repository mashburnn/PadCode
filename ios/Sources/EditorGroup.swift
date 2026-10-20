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
    @Namespace private var tabs

    var body: some View {
        let t = wb.theme
        let group = wb.groups.indices.contains(index) ? wb.groups[index] : EditorGroupState()
        let focused = wb.focusedGroup == index
        let file = wb.file(group.active)
        VStack(spacing: 0) {
            if !group.tabs.isEmpty {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(group.tabs, id: \.self) { path in
                                    if let f = wb.file(path) {
                                        EditorTab(file: f, group: index, tabs: tabs).id(path)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                            .animation(Workbench.layoutAnimation, value: group.tabs)
                            .animation(Workbench.layoutAnimation, value: group.active)
                        }
                        // Keep the active tab in view, as VS Code does.
                        .onChange(of: group.active) { _, p in
                            if let p { withAnimation(Workbench.layoutAnimation) { proxy.scrollTo(p) } }
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
            .simultaneousGesture(TapGesture().onEnded { if wb.focusedGroup != index { wb.focusedGroup = index } })
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
    let tabs: Namespace.ID
    @EnvironmentObject var wb: Workbench
    @State private var hover = false

    var body: some View {
        let t = wb.theme
        let active = wb.groups.indices.contains(group) && wb.groups[group].active == file.path
        let title = file.viewer == .markdownPreview ? "Preview \(file.name)"
            : file.viewer == .browser ? "Port \(file.path.replacingOccurrences(of: "port:", with: ""))" : file.name
        let twin = wb.groups.indices.contains(group) && wb.groups[group].tabs.contains { $0 != file.path && wb.baseName($0) == file.name }
        HStack(spacing: 6) {
            if file.viewer == .markdownPreview || file.viewer == .browser {
                CodiconView(icon: file.viewer == .browser ? .globe : .openPreview, size: 14).foregroundStyle(t.highlightFg)
            } else {
                FileIcon(name: file.name, size: 14)
            }
            Text(title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(active ? t.tabActiveFg : hover ? t.tabHoverFg : t.tabInactiveFg)
            if twin, file.viewer == .text {
                Text(wb.baseName(wb.parentDir(file.path))).font(.system(size: 12)).lineLimit(1).foregroundStyle(t.descriptionFg)
            }
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
        .overlay(alignment: .top) {
            if active && wb.focusedGroup == group {
                Rectangle().fill(t.tabActiveBorderTop).frame(height: 1).matchedGeometryEffect(id: "top", in: tabs)
            }
        }
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

/// Path, then the symbols around the caret (VS Code's breadcrumbs). Each
/// symbol opens a menu of its siblings to jump to.
private struct Breadcrumbs: View {
    let file: OpenFile
    @EnvironmentObject var wb: Workbench
    @EnvironmentObject var status: EditorStatus
    @StateObject private var outline = OutlineModel()

    var body: some View {
        let t = wb.theme
        let parts = wb.relative(file.path).split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        let chain = wb.active == file.path ? Self.chain(outline.symbols, line: status.line - 1) : []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    if i > 0 { CodiconView(icon: .chevronRight, size: 12) }
                    if i == parts.count - 1 { FileIcon(name: p, size: 12) }
                    Text(p).font(.system(size: 12)).lineLimit(1)
                }
                ForEach(chain, id: \.self) { i in
                    CodiconView(icon: .chevronRight, size: 12)
                    symbolMenu(i, t)
                }
            }
            .padding(.horizontal, 12)
            .animation(.snappy(duration: 0.15), value: chain)
        }
        .foregroundStyle(t.breadcrumbFg)
        .frame(height: 22)
        .background(t.editorBg)
        .task(id: "\(file.path)#\(file.revision)#\(status.edits)#\(wb.active == file.path)") {
            guard wb.active == file.path else { return }
            // Cancelled by the next keystroke: only ask once typing pauses.
            guard (try? await Task.sleep(for: .milliseconds(outline.symbols.isEmpty ? 0 : 700))) != nil else { return }
            await outline.load(wb)
        }
    }

    private func symbolMenu(_ i: Int, _ t: VSTheme) -> some View {
        let s = outline.symbols[i]
        let (icon, color) = symbolIcon(s.kind)
        return Menu {
            ForEach(Self.siblings(outline.symbols, of: i), id: \.self) { j in
                let o = outline.symbols[j]
                Button { reveal(o) } label: { if j == i { Label(o.name, systemImage: "checkmark") } else { Text(o.name) } }
            }
        } label: {
            HStack(spacing: 3) {
                CodiconView(icon: icon, size: 12).foregroundStyle(t.ui(color, default: "#cccccc"))
                Text(s.name).font(.system(size: 12)).lineLimit(1)
            }
            .padding(.horizontal, 3).frame(height: 20)
            .hoverBackground(t.listHoverBg, cornerRadius: 3)
        }
        .menuStyle(.button).buttonStyle(.plain).hoverEffectDisabled()
        .transition(.opacity)
    }

    private func reveal(_ s: DocSymbol) {
        Task { await wb.open(file.path, line: Int(s.selection.start.line) + 1, column: Int(s.selection.start.character)) }
    }

    /// Indexes of the symbols containing `line`, outermost first. `symbols` is
    /// the outline's pre-order list, so containers come before their children.
    static func chain(_ symbols: [DocSymbol], line: Int) -> [Int] {
        var out: [Int] = []
        for (i, s) in symbols.enumerated() where Int(s.range.start.line) <= line && line <= Int(s.range.end.line) {
            if let last = out.last, symbols[last].depth >= s.depth { continue }
            out.append(i)
        }
        return out
    }

    /// `i` and the other symbols with the same parent, in order.
    static func siblings(_ symbols: [DocSymbol], of i: Int) -> [Int] {
        let d = symbols[i].depth
        var start = i
        while start > 0, symbols[start - 1].depth >= d { start -= 1 }
        var out: [Int] = []
        var j = start
        while j < symbols.count, symbols[j].depth >= d {
            if symbols[j].depth == d { out.append(j) }
            j += 1
        }
        return out
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
            KeyChips(keys: keys.replacingOccurrences(of: " ", with: ""), theme: wb.theme)
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
        let container = EditorContainer()
        container.clipsToBounds = true // a pushed sticky-scroll row slides out the top
        container.onLayout = { [weak c] box in c?.layoutChrome(in: box) }
        let tv = c.tv ?? makeTextView(context: context)
        c.tv = tv
        tv.removeFromSuperview()
        tv.frame = container.bounds
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(tv)
        c.minimap.attach(to: container)
        c.sticky.attach(to: container)
        c.ruler.attach(to: container)
        languages.activeView = tv
        languages.activePath = file.path
        // ponytail: focusing after the first frame instead (tried 2026-10-18) made
        // the keyboard rebuild twice per switch and wasn't faster in the Simulator.
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
        let sticky = context.coordinator.sticky
        sticky.tv = tv
        let minimap = context.coordinator.minimap
        minimap.tv = tv
        tv.onScroll = { [weak sticky, weak minimap] in sticky?.refresh(); minimap?.refresh() }
        let ruler = context.coordinator.ruler
        ruler.tv = tv
        tv.onHighlights = { [weak ruler] in ruler?.setNeedsDisplay() }
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
        tv.gutterLeadingPadding = 14
        tv.gutterTrailingPadding = 14
        tv.characterPairs = [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("`", "`")]
            .map { Pair(leading: $0.0, trailing: $0.1) }
        load(tv, context: context, colorsLater: true)
        return tv
    }

    func updateUIView(_ container: UIView, context: Context) {
        let c = context.coordinator
        guard let tv = c.tv else { return }
        // SwiftUI can make the new container before it's done with the old one;
        // whichever is on screen holds the editor.
        if tv.superview !== container, container.window != nil || tv.window == nil {
            tv.removeFromSuperview()
            tv.frame = container.bounds
            container.addSubview(tv)
            c.minimap.attach(to: container)
            c.sticky.attach(to: container)
            c.ruler.attach(to: container)
        }
        c.layoutChrome(in: container) // the Minimap setting may have changed
        c.sticky.update(symbols: languages.outlines[file.path] ?? [], theme: wb.theme)
        if c.themeName != wb.theme.name || c.fontSize != wb.fontSize || c.revision != file.revision {
            load(tv, context: context) // new theme, or text changed outside this editor
            c.minimap.redraw(text: tv.text, fileName: file.name, theme: wb.theme, tabSize: wb.tabSize)
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

    /// `colorsLater`: show the text at once and add syntax colors when the
    /// background parse is done (opening a file), instead of parsing first.
    private func load(_ tv: TextView, context: Context, colorsLater: Bool = false) {
        let theme = EditorTheme(wb.theme, fontSize: wb.fontSize)
        let text = wb.files.first { $0.path == file.path }?.text ?? file.text
        let selection = tv.selectedRange
        // Plain text past 2 MB or with a line over 20k characters (minified code):
        // tree-sitter reparses and requeries the whole line on every keystroke.
        // Same cut-off as VS Code's editor.maxTokenizationLineLength.
        let language = text.utf16.count > 2_000_000 || Self.hasHugeLine(text) ? nil : Language.treeSitter(for: file.name)
        if colorsLater, let language {
            tv.setState(TextViewState(text: text, theme: theme))
            let coordinator = context.coordinator, revision = file.revision
            Task.detached(priority: .userInitiated) {
                // Runestone: "create an instance of TextViewState on a background queue".
                let colored = TextViewState(text: text, theme: theme, language: language)
                await MainActor.run {
                    // Typed meanwhile, or the file changed: keep what's there.
                    // ponytail: that file then stays uncolored until it's reloaded (theme, reopen).
                    guard tv.text == text, coordinator.revision == revision else { return }
                    let (sel, offset, marks) = (tv.selectedRange, tv.contentOffset, tv.highlightedRanges)
                    tv.setState(colored)
                    tv.selectedRange = sel
                    tv.contentOffset = offset
                    tv.highlightedRanges = marks
                    coordinator.colored = true
                }
            }
        } else {
            let state = language.map { TextViewState(text: text, theme: theme, language: $0) }
                ?? TextViewState(text: text, theme: theme)
            tv.setState(state)
            context.coordinator.colored = true
        }
        tv.backgroundColor = wb.theme.uiColor("editor.background", default: "#1e1e1e")
        tv.insertionPointColor = wb.theme.uiColor("editorCursor.foreground", default: "#aeafad")
        tv.selectionBarColor = tv.insertionPointColor
        tv.selectionHighlightColor = wb.theme.uiColor("editor.selectionBackground", default: "#264f78")
        (tv as? PadTextView)?.bracketColor = wb.theme.uiColor("editorBracketMatch.background", default: "#0064001a").withAlphaComponent(0.45)
        (tv as? PadTextView)?.occurrenceColor = wb.theme.uiColor("editor.wordHighlightBackground", default: "#575757b8")
        (tv as? PadTextView)?.selectionMatchColor = wb.theme.uiColor("editor.selectionHighlightBackground", default: "#add6ff26")
        (tv as? PadTextView)?.linkColor = wb.theme.uiColor("editorLink.activeForeground", ["textLink.foreground"], default: "#4e94ce")
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
        /// Syntax colors are applied (tests).
        var colored = false
        let sticky = StickyScroll()
        let ruler = OverviewRuler()
        let minimap = Minimap()

        /// Shows the minimap when it's on and the editor is wide enough, and
        /// keeps the text clear of it (long lines scroll under, as in VS Code).
        /// Runs on every layout, so sidebar toggles and window resizes count.
        func layoutChrome(in container: UIView) {
            guard let tv, container.bounds.width > 0 else { return }
            let on = AppSettings.shared.minimap && container.bounds.width > 600
            let right = (on ? Minimap.width : 0) + OverviewRuler.width + 4
            if tv.textContainerInset.right != right {
                var inset = tv.textContainerInset
                inset.right = right
                tv.textContainerInset = inset
            }
            sticky.reservedRight = on ? Minimap.width + OverviewRuler.width : OverviewRuler.width
            guard minimap.isHidden == on else { return }
            minimap.isHidden = !on
            if on, let f = wb.file(path) { minimap.update(text: f.text, fileName: f.name, theme: wb.theme, tabSize: wb.tabSize) }
        }
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
                guard let tv = g.view as? PadTextView else { return }
                switch g.state {
                case .began, .changed:
                    // In text-view coordinates, which closestPosition expects.
                    let p = g.location(in: tv)
                    wb.languages.pointerMoved(p, in: tv)
                    // ⌘ held: the symbol under the pointer is a link to its definition, as on the desktop.
                    var link: NSRange?
                    if g.modifierFlags.contains(.command), wb.languages.serverName(for: path) != nil, let pos = tv.closestPosition(to: p) {
                        link = wb.languages.wordRange(at: tv.offset(from: tv.beginningOfDocument, to: pos), in: tv)
                    }
                    tv.linkRange = link
                default:
                    wb.languages.pointerLeft()
                    tv.linkRange = nil
                }
            }
        }

        func textViewDidChange(_ textView: TextView) {
            let t0 = CACurrentMediaTime()
            let text = textView.text
            MainActor.assumeIsolated {
                wb.edited(path, text: text)
                // redraw, not update: skips comparing the whole file's text each keystroke.
                minimap.redraw(text: text, fileName: wb.baseName(path), theme: wb.theme, tabSize: wb.tabSize)
                wb.languages.changed(path, text: text)
                wb.languages.typed(in: textView, path: path)
                Scenario.handlerTime += CACurrentMediaTime() - t0
            }
        }

        func textViewDidBeginEditing(_ textView: TextView) {
            MainActor.assumeIsolated {
                wb.languages.activeView = textView
                wb.languages.activePath = path
                // Only on a real change: this runs inside becomeFirstResponder, often in
                // a SwiftUI update, and publishing an unchanged value still redraws
                // the window (and SwiftUI logs a fault with a backtrace for it).
                if wb.groups.indices.contains(group), wb.focusedGroup != group { wb.focusedGroup = group }
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
            ruler.setNeedsDisplay()
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

/// VS Code's sticky scroll: the header lines of the scopes the top of the
/// editor is inside stay pinned there (at most 5). The innermost one is pushed
/// up as its scope scrolls out. Clicking a header jumps to it.
final class StickyScroll: UIView {
    weak var tv: PadTextView?
    /// Width kept free on the right (minimap, overview ruler).
    var reservedRight: CGFloat = 0 { didSet { if reservedRight != oldValue { shown = []; refresh() } } }
    private var symbols: [DocSymbol] = []
    private var theme: VSTheme?
    private var rows: [UIView] = []
    private var shown: [Int] = []
    private var shownShift: CGFloat = 0
    private var hovered: Int?

    init() {
        super.init(frame: .zero)
        isHidden = true
        clipsToBounds = false
        layer.shadowOpacity = 1
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover)))
    }
    required init?(coder: NSCoder) { fatalError() }

    func attach(to container: UIView) {
        if superview !== container { removeFromSuperview(); container.addSubview(self) }
        container.bringSubviewToFront(self)
        refresh()
    }

    func update(symbols: [DocSymbol], theme: VSTheme) {
        guard symbols != self.symbols || theme !== self.theme else { return }
        self.symbols = symbols
        self.theme = theme
        shown = []
        refresh()
    }

    private var lineHeight: CGFloat { guard let tv else { return 18 }; return tv.theme.font.lineHeight * tv.lineHeightMultiplier }

    private func line(atY y: CGFloat) -> Int? {
        guard let tv, let p = tv.closestPosition(to: CGPoint(x: tv.gutterWidth + 8, y: y)) else { return nil }
        return tv.textLocation(at: tv.offset(from: tv.beginningOfDocument, to: p))?.lineNumber
    }

    private func y(ofLine line: Int) -> CGFloat? {
        guard let tv, let loc = tv.location(at: TextLocation(lineNumber: line, column: 0)),
              let p = tv.position(from: tv.beginningOfDocument, offset: loc) else { return nil }
        return tv.caretRect(for: p).minY
    }

    /// Symbols (outermost first) whose scope holds `line` but whose header is above it.
    private func scopes(holding line: Int) -> [DocSymbol] {
        var out: [DocSymbol] = []
        for s in symbols where Int(s.selection.start.line) < line && line <= Int(s.range.end.line) {
            if let last = out.last, last.depth >= s.depth || Int(last.selection.start.line) == Int(s.selection.start.line) { continue }
            out.append(s)
        }
        return Array(out.prefix(5))
    }

    func refresh() {
        guard let tv, theme != nil, tv.contentOffset.y > 0 else { show([], 0); return }
        guard !symbols.isEmpty else { show([], 0); return }
        let h = lineHeight
        let top = tv.contentOffset.y + tv.textContainerInset.top
        // The rows cover lines too, so look again below them.
        var chain: [DocSymbol] = []
        for _ in 0..<3 {
            guard let l = line(atY: top + CGFloat(chain.count) * h + 1) else { break }
            let next = scopes(holding: l)
            if next.count == chain.count { break }
            chain = next
        }
        // Push the innermost header up as the line after its scope comes under it.
        var shift: CGFloat = 0
        if let last = chain.last, let endY = y(ofLine: Int(last.range.end.line) + 1) {
            shift = min(0, endY - tv.contentOffset.y - CGFloat(chain.count) * h)
        }
        show(chain.map { Int($0.selection.start.line) }, shift.rounded())
    }

    private func show(_ lines: [Int], _ shift: CGFloat) {
        let scrolled = (tv?.contentOffset.y ?? 0) > 0
        guard lines != shown || shift != shownShift || (lines.isEmpty && scrolled != !isHidden) else { return }
        shown = lines
        shownShift = shift
        // Scrolled with nothing pinned: just VS Code's shadow under the tabs.
        isHidden = lines.isEmpty && !scrolled
        if lines.isEmpty, scrolled, let superview, let theme {
            rows.forEach { $0.isHidden = true }
            frame = CGRect(x: 0, y: -1, width: superview.bounds.width - reservedRight, height: 1)
            backgroundColor = .clear
            layer.shadowColor = theme.uiColor("scrollbar.shadow", default: "#000000").cgColor
            layer.shadowPath = UIBezierPath(rect: bounds).cgPath
            return
        }
        guard let tv, let theme, let superview, !lines.isEmpty else { return }
        let h = lineHeight
        while rows.count < lines.count { let r = UIView(); addSubview(r); rows.append(r) }
        let bg = theme.uiColor("editorStickyScroll.background", ["editor.background"], default: "#1e1e1e")
        let shadow = theme.uiColor("editorStickyScroll.shadow", ["scrollbar.shadow"], default: "#000000")
        for (i, r) in rows.enumerated() {
            r.isHidden = i >= lines.count
            guard i < lines.count else { continue }
            let y = CGFloat(i) * h + (i == lines.count - 1 ? shift : 0)
            r.frame = CGRect(x: 0, y: y, width: superview.bounds.width - reservedRight, height: h)
            r.backgroundColor = i == hovered
                ? theme.uiColor("editorStickyScrollHover.background", default: "#2a2d2e") : bg
            render(row: r, line: lines[i], tv: tv, theme: theme)
        }
        // The last row slides under the ones above it as it's pushed.
        if lines.count > 1 { for r in rows.prefix(lines.count - 1) { bringSubviewToFront(r) } }
        frame = CGRect(x: 0, y: 0, width: superview.bounds.width - reservedRight, height: CGFloat(lines.count) * h + min(shift, 0))
        backgroundColor = bg
        layer.shadowColor = shadow.cgColor
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    private func render(row r: UIView, line: Int, tv: PadTextView, theme: VSTheme) {
        let number = (r.viewWithTag(1) as? UILabel) ?? { let l = UILabel(); l.tag = 1; l.textAlignment = .right; r.addSubview(l); return l }()
        let text = (r.viewWithTag(2) as? UILabel) ?? { let l = UILabel(); l.tag = 2; r.addSubview(l); return l }()
        let font = tv.theme.font
        number.font = font
        number.text = "\(line + 1)"
        number.textColor = tv.theme.lineNumberColor
        number.frame = CGRect(x: 0, y: 0, width: tv.gutterWidth - tv.gutterTrailingPadding, height: r.bounds.height)
        let x = tv.gutterWidth + tv.textContainerInset.left
        text.frame = CGRect(x: x, y: 0, width: r.bounds.width - x, height: r.bounds.height)
        guard let start = tv.location(at: TextLocation(lineNumber: line, column: 0)) else { return }
        let end = tv.location(at: TextLocation(lineNumber: line + 1, column: 0)) ?? (tv.text as NSString).length
        let raw = tv.text(in: NSRange(location: start, length: max(end - start, 0))) ?? ""
        let s = raw.trimmingCharacters(in: .newlines)
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: tv.theme.textColor])
        // The symbol's name in its token color, the way the editor shows it.
        if let sym = symbols.first(where: { Int($0.selection.start.line) == line }) {
            let col = Int(sym.selection.start.character)
            let len = Int(sym.selection.end.line) == line ? Int(sym.selection.end.character) - col : sym.name.utf16.count
            let capture = [5, 10, 11, 23].contains(sym.kind) ? "type" : [6, 9, 12].contains(sym.kind) ? "function" : "variable"
            if col >= 0, len > 0, col + len <= (s as NSString).length, let c = theme.token(for: capture).color {
                a.addAttribute(.foregroundColor, value: c, range: NSRange(location: col, length: len))
            }
        }
        text.attributedText = a
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let i = Int(g.location(in: self).y / lineHeight)
        guard let tv, shown.indices.contains(i), let loc = tv.location(at: TextLocation(lineNumber: shown[i], column: 0)),
              let lineY = y(ofLine: shown[i]) else { return }
        tv.selectedRange = NSRange(location: loc, length: 0)
        // Leave the header just below the scopes still pinned above it.
        tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: max(lineY - CGFloat(i) * lineHeight - tv.textContainerInset.top, 0)), animated: true)
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        let i = g.state == .ended || g.state == .cancelled ? nil : Int(g.location(in: self).y / lineHeight)
        guard i != hovered else { return }
        hovered = i
        let lines = shown
        shown = []
        show(lines, shownShift)
    }
}

/// VS Code's overview ruler: a strip down the editor's right edge with a mark
/// for each problem, each occurrence of the word under the caret, and the
/// caret's line, placed by line over the whole file. Clicking jumps there.
final class OverviewRuler: UIView {
    weak var tv: PadTextView?
    static let width: CGFloat = 12

    init() {
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError() }

    func attach(to container: UIView) {
        if superview !== container { removeFromSuperview(); container.addSubview(self) }
        container.bringSubviewToFront(self)
        frame = CGRect(x: container.bounds.width - Self.width, y: 0, width: Self.width, height: container.bounds.height)
        autoresizingMask = [.flexibleLeftMargin, .flexibleHeight]
        setNeedsDisplay()
    }

    private var lineCount: Int {
        guard let tv else { return 1 }
        return max((tv.textLocation(at: (tv.text as NSString).length)?.lineNumber ?? 0) + 1, 1)
    }

    override func draw(_ rect: CGRect) {
        guard let tv, let ctx = UIGraphicsGetCurrentContext() else { return }
        let n = CGFloat(lineCount)
        let h = bounds.height
        func y(_ location: Int) -> CGFloat? {
            tv.textLocation(at: location).map { (CGFloat($0.lineNumber) + 0.5) / n * h }
        }
        // ponytail: one mark per range; a 100k-match file would want binning by pixel.
        for r in tv.highlightedRanges.prefix(2000) {
            guard let y = y(r.range.location) else { continue }
            if r.id.hasPrefix("diag") {
                ctx.setFillColor(r.color.cgColor)
                ctx.fill(CGRect(x: bounds.width / 2, y: y - 1.5, width: bounds.width / 2, height: 3))
            } else if r.id.hasPrefix("word") {
                ctx.setFillColor(r.color.withAlphaComponent(0.8).cgColor)
                ctx.fill(CGRect(x: 2, y: y - 1, width: bounds.width / 2 - 2, height: 2))
            }
        }
        if let y = y(tv.selectedRange.location) {
            ctx.setFillColor(tv.theme.selectedLinesLineNumberColor.withAlphaComponent(0.7).cgColor)
            ctx.fill(CGRect(x: 0, y: y - 1, width: bounds.width, height: 2))
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let tv else { return }
        let line = Int(g.location(in: self).y / bounds.height * CGFloat(lineCount))
        _ = tv.goToLine(min(max(line, 0), lineCount - 1))
    }
}

/// VS Code's minimap: the whole file in miniature, one block per run of
/// characters in its syntax color, with a slider over the part on screen.
/// Drag the slider (or click) to scroll. Drawn off the main thread, 0.4 s
/// after typing stops.
final class Minimap: UIView, UIGestureRecognizerDelegate {
    static let width: CGFloat = 84
    weak var tv: PadTextView?
    private let content = CALayer()
    private let slider = CALayer()
    private var lines = 1
    /// Points per line in the minimap (2, less for very long files).
    private var lineHeight: CGFloat = 2
    private var drawnText: String?
    private var generation = 0
    private var hovering = false
    private var dragging = false
    private var sliderColors: (normal: CGColor, hover: CGColor, active: CGColor) = (UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor)

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        layer.addSublayer(content)
        layer.addSublayer(slider)
        content.contentsGravity = .topLeft
        content.contentsScale = UIScreen.main.scale
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }
    required init?(coder: NSCoder) { fatalError() }

    func attach(to container: UIView) {
        if superview !== container { removeFromSuperview(); container.addSubview(self) }
        container.bringSubviewToFront(self)
        frame = CGRect(x: container.bounds.width - Self.width - OverviewRuler.width, y: 0, width: Self.width, height: container.bounds.height)
        autoresizingMask = [.flexibleLeftMargin, .flexibleHeight]
        refresh()
    }

    /// Draws again even if the text is the same (new theme).
    func redraw(text: String, fileName: String, theme: VSTheme, tabSize: Int) {
        drawnText = nil
        guard !isHidden else { return }
        update(text: text, fileName: fileName, theme: theme, tabSize: tabSize)
    }

    func update(text: String, fileName: String, theme: VSTheme, tabSize: Int) {
        guard text != drawnText else { return }
        drawnText = text
        generation += 1
        let gen = generation
        let editorTheme = EditorTheme(theme, fontSize: 12)
        backgroundColor = theme.uiColor("minimap.background", ["editor.background"], default: "#1e1e1e")
        sliderColors = (theme.uiColor("minimapSlider.background", default: "#79797933").cgColor,
                        theme.uiColor("minimapSlider.hoverBackground", default: "#64646459").cgColor,
                        theme.uiColor("minimapSlider.activeBackground", default: "#bfbfbf33").cgColor)
        let language = text.utf16.count > 1_000_000 ? nil : Language.treeSitter(for: fileName)
        let scale = UIScreen.main.scale
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard await self?.generation == gen else { return }
            let (image, lines, lh) = Self.render(text, language: language, theme: editorTheme, tabSize: tabSize, scale: scale)
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.content.contents = image
                self.lines = lines
                self.lineHeight = lh
                self.layoutContent()
                CATransaction.commit()
            }
        }
    }

    /// One rect per run of non-blank characters of the same color, 2 pt per
    /// line and 120 columns across, like VS Code's minimap at its defaults.
    nonisolated static func render(_ text: String, language: TreeSitterLanguage?, theme: EditorTheme, tabSize: Int, scale: CGFloat) -> (CGImage?, Int, CGFloat) {
        let attr: NSAttributedString = language.map { StringSyntaxHighlighter(theme: theme, language: $0).syntaxHighlight(text) }
            ?? NSAttributedString(string: text, attributes: [.foregroundColor: theme.textColor])
        let ns = attr.string as NSString
        var lineCount = 1
        for i in 0 ..< ns.length where ns.character(at: i) == 10 { lineCount += 1 }
        // Long files get thinner lines, so the picture stays a sane size.
        let lh = min(2, 8000 / CGFloat(lineCount))
        let cw = width / 120
        let size = CGSize(width: width, height: max(CGFloat(lineCount) * lh, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            var line = 0, col = 0
            attr.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
                cg.setFillColor(((value as? UIColor) ?? theme.textColor).withAlphaComponent(0.75).cgColor)
                var runStart = -1
                func flush() {
                    if runStart >= 0, runStart < 120 {
                        cg.fill(CGRect(x: CGFloat(runStart) * cw, y: CGFloat(line) * lh, width: CGFloat(min(col, 120) - runStart) * cw, height: max(lh * 0.8, 0.5)))
                    }
                    runStart = -1
                }
                for i in range.location ..< range.location + range.length {
                    switch ns.character(at: i) {
                    case 10: flush(); line += 1; col = 0
                    case 13: break
                    case 32: flush(); col += 1
                    case 9: flush(); col += tabSize - col % tabSize
                    default: if runStart < 0 { runStart = col }; col += 1
                    }
                }
                flush()
            }
        }
        return (image.cgImage, lineCount, lh)
    }

    private var docHeight: CGFloat { CGFloat(lines) * lineHeight }

    /// Where the minimap's own scroll is: it moves with the editor when the file is taller than it.
    private var offset: CGFloat {
        guard let tv else { return 0 }
        let range = tv.contentSize.height - tv.bounds.height
        guard docHeight > bounds.height, range > 0 else { return 0 }
        return min(max(tv.contentOffset.y / range, 0), 1) * (docHeight - bounds.height)
    }

    private func layoutContent() {
        content.frame = CGRect(x: 0, y: -offset, width: Self.width, height: docHeight)
        layoutSlider()
    }

    private func layoutSlider() {
        guard let tv, tv.contentSize.height > 0 else { return }
        let perPoint = docHeight / tv.contentSize.height
        slider.frame = CGRect(x: 0, y: tv.contentOffset.y * perPoint - offset, width: Self.width, height: max(tv.bounds.height * perPoint, 8))
        slider.backgroundColor = dragging ? sliderColors.active : hovering ? sliderColors.hover : sliderColors.normal
    }

    func refresh() {
        guard !isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutContent()
        CATransaction.commit()
    }

    /// Scrolls the editor so its top is at minimap point `y` (in this view).
    private func scroll(toMinimapY y: CGFloat) {
        guard let tv, docHeight > 0 else { return }
        let top = (y + offset) / docHeight * tv.contentSize.height
        let maxY = max(tv.contentSize.height - tv.bounds.height, 0)
        tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: min(max(top, 0), maxY)), animated: false)
    }

    private var grab: CGFloat = 0
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let y = g.location(in: self).y
        switch g.state {
        case .began:
            dragging = true
            // Grabbed inside the slider: keep that spot under the finger; outside: center it.
            grab = slider.frame.contains(CGPoint(x: 1, y: y)) ? y - slider.frame.minY : slider.frame.height / 2
            scroll(toMinimapY: y - grab)
        case .changed: scroll(toMinimapY: y - grab)
        default: dragging = false; refresh()
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let tv else { return }
        let y = g.location(in: self).y
        let top = (y + offset) / max(docHeight, 1) * tv.contentSize.height - tv.bounds.height / 2
        let maxY = max(tv.contentSize.height - tv.bounds.height, 0)
        tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: min(max(top, 0), maxY)), animated: true)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        hovering = g.state == .began || g.state == .changed
        refresh()
    }
}

/// The editor's container; tells the coordinator when its size settles.
final class EditorContainer: UIView {
    var onLayout: ((UIView) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}
