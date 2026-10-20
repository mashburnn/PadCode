import SwiftUI

/// The VS Code window layout for one desktop.
struct WorkbenchView: View {
    @StateObject var wb: Workbench
    /// This window's restorable value; kept on the open folder so iPadOS
    /// reopens it after a relaunch.
    var target: Binding<WorkbenchTarget?>?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sidebarWidth: CGFloat = 280
    @State private var panelHeight: CGFloat = 260

    var body: some View {
        let t = wb.theme
        VStack(spacing: 0) {
            TitleBar(theme: t, title: commandCenterTitle, onCommandCenter: {
                if wb.root.isEmpty { wb.picker = true } else { wb.palette = false; wb.quickOpen = true }
            }) {
                EmptyView()
            } trailing: {
                TitleBarMenu(icon: .multipleWindows, label: "New Window") {
                    Button { wb.newWindow() } label: { Label("New Window  ⇧⌘N", systemImage: "macwindow.badge.plus") }
                    Button { wb.openInNewWindow(nil) } label: { Label("New Window on \(wb.machine.name)", systemImage: "desktopcomputer") }
                    if !wb.root.isEmpty {
                        Button { wb.openInNewWindow(wb.root) } label: {
                            Label("Open \(wb.baseName(wb.root)) in New Window", systemImage: "folder")
                        }
                    }
                }
                TitleBarButton(icon: .layoutSidebarLeft, label: "Toggle Primary Side Bar", active: wb.side != nil) {
                    wb.toggleSidebar()
                }
                TitleBarButton(icon: .layoutPanel, label: "Toggle Panel", active: wb.panelOpen) {
                    wb.togglePanel()
                }
            }
            HStack(spacing: 0) {
                ActivityBar()
                if let side = wb.side {
                    Group {
                        switch side {
                        case .explorer: ExplorerView()
                        case .search: SearchView()
                        case .outline: OutlineView()
                        }
                    }
                    .frame(width: sidebarWidth)
                    .background(t.sideBarBg)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    Sash(axis: .vertical, value: $sidebarWidth, range: 170...600)
                }
                VStack(spacing: 0) {
                    EditorArea()
                    if wb.panelOpen {
                        Sash(axis: .horizontal, value: $panelHeight, range: 80...900, sign: -1)
                        // Slides at its full height: the terminal isn't resized frame by frame.
                        TerminalPanel().frame(height: panelHeight)
                            .transition(.move(edge: .bottom))
                    }
                }
            }
            StatusBar()
        }
        .avoidKeyboard()
        .background(t.editorBg)
        .overlay(alignment: .top) {
            Group {
                if wb.quickOpen { QuickOpen() }
                if wb.palette { CommandPalette() }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            .animation(.snappy(duration: 0.16), value: wb.quickOpen)
            .animation(.snappy(duration: 0.16), value: wb.palette)
            if wb.picker && wb.desktop != nil { FolderPicker() }
            if wb.symbolPicker { SymbolPicker() }
            if wb.taskPicker { TaskPicker() }
            LanguageOverlays()
            if wb.gotoLine { GotoLinePicker() }
        }
        .overlay {
            if wb.desktop == nil { ConnectingOverlay() }
        }
        .overlay(alignment: .bottomTrailing) { TransferToast(wb: wb) }
        .environmentObject(wb)
        .environmentObject(wb.languages)
        .environmentObject(wb.editorStatus)
        .focusedSceneObject(wb) // the menu bar acts on this window
        .preferredColorScheme(t.isDark ? .dark : .light)
        .statusBarHidden() // see App.swift
        .persistentSystemOverlays(.hidden)
        .task {
            if wb.desktop == nil { await wb.connect() }
            if Scenario.requested != nil { await Scenario.run(wb) }
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await wb.reconnectIfNeeded() } }
            if p == .background || p == .inactive {
                // iPadOS may close the app from here: keep edits and tabs.
                Task { await wb.saveAllDirty() }
                wb.saveSession()
            }
        }
        // Pick up changes made on the desktop to the file you're looking at.
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await wb.checkActiveFileOnDisk()
            }
        }
        // Health check while visible: notices a dead tunnel within ~15 s instead
        // of when the next action fails, and retries a failed reconnect.
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await wb.reconnectIfNeeded()
            }
        }
        .onAppear {
            wb.openWindowAction = openWindow
            if sizeClass == .compact { wb.side = nil }
        }
        .background(WindowProbe { wb.scene = $0?.windowScene })
        .onChange(of: wb.root) { _, root in
            if !root.isEmpty { target?.wrappedValue?.folder = root }
        }
        .alert("The file has been changed on disk", isPresented: Binding(get: { wb.conflict != nil }, set: { if !$0 { wb.conflict = nil } })) {
            Button("Overwrite") { if let p = wb.conflict { Task { await wb.save(p, force: true) } } }
            Button("Revert") { if let p = wb.conflict { Task { await wb.revert(p) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Another program changed this file since you opened it. Overwrite it with your version, or revert to the version on disk?")
        }
        .background(KeyCommands(wb: wb))
        .sheet(isPresented: $wb.settingsOpen) { SettingsView().environmentObject(wb) }
        .fileImporter(isPresented: Binding(get: { wb.uploadTarget != nil }, set: { if !$0 { wb.uploadTarget = nil } }),
                      allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let dir = wb.uploadTarget ?? wb.root
            wb.uploadTarget = nil
            if case .success(let urls) = result { Task { await wb.upload(urls, to: dir) } }
        }
        .sheet(item: Binding(get: { wb.exportURL.map(ExportItem.init) }, set: { if $0 == nil { wb.exportURL = nil } })) { item in
            ShareSheet(url: item.url)
        }
        // Files dropped anywhere else (editor, panel…) go to the open folder.
        .onDrop(of: [.item], isTargeted: nil) { handleDrop($0, into: wb.root, wb: wb) }
        .navigationTitle("\(wb.machine.name)")
    }
}

extension WorkbenchView {
    /// Like VS Code: "folder [Tunnel: machine]", or just the machine when no folder is open.
    var commandCenterTitle: String {
        wb.root.isEmpty ? "\(wb.machine.name) [Tunnel]" : "\(wb.baseName(wb.root)) [Tunnel: \(wb.machine.name)]"
    }
}

/// Draggable divider between workbench parts: a 1 pt line with a wider UIKit
/// grab area on top, which shows the iPad resize pointer and VS Code's hover
/// highlight.
private struct Sash: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var sign: CGFloat = 1
    @EnvironmentObject var wb: Workbench
    @State private var start: CGFloat = 0
    @State private var active = false

    var body: some View {
        let vertical = axis == .vertical
        Rectangle()
            .fill(vertical ? wb.theme.ui("sideBar.border", default: "#00000000") : .clear)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay {
                Rectangle().fill(wb.theme.sashHover).opacity(active ? 1 : 0)
                    .frame(width: vertical ? 4 : nil, height: vertical ? nil : 4)
                    .allowsHitTesting(false)
            }
            .overlay {
                SashHandle(vertical: vertical, active: $active, began: { start = value }) { t in
                    value = min(max(start + sign * t, range.lowerBound), range.upperBound)
                }
                .frame(width: vertical ? 12 : nil, height: vertical ? nil : 12)
            }
            .zIndex(1)
    }
}

private struct SashHandle: UIViewRepresentable {
    let vertical: Bool
    @Binding var active: Bool
    let began: () -> Void
    /// Distance moved since the drag began.
    let moved: (CGFloat) -> Void

    func makeUIView(context: Context) -> SashView { SashView() }
    func updateUIView(_ v: SashView, context: Context) {
        v.vertical = vertical
        v.began = began
        v.moved = moved
        v.activeChanged = { active = $0 }
    }
}

final class SashView: UIView, UIPointerInteractionDelegate {
    var vertical = true
    var began: () -> Void = {}
    var moved: (CGFloat) -> Void = { _ in }
    var activeChanged: (Bool) -> Void = { _ in }
    private var hovering = false { didSet { activeChanged(hovering || dragging) } }
    private var dragging = false { didSet { activeChanged(hovering || dragging) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
        addInteraction(UIPointerInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    // Window space: the sash moves with the finger, so its own coordinates
    // would feed the movement back on itself.
    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: nil)
        drag(g.state, vertical ? t.x : t.y)
    }

    /// Also driven by the test scenario.
    func drag(_ state: UIGestureRecognizer.State, _ distance: CGFloat) {
        switch state {
        case .began: dragging = true; began(); moved(distance)
        case .changed: moved(distance)
        default: dragging = false
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let style = UIPointerStyle.system()
        style.accessories = vertical ? [.arrow(.left), .arrow(.right)] : [.arrow(.top), .arrow(.bottom)]
        return style
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, willEnter region: UIPointerRegion, animator: any UIPointerInteractionAnimating) {
        hovering = true
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, willExit region: UIPointerRegion, animator: any UIPointerInteractionAnimating) {
        hovering = false
    }
}

private struct ActivityBar: View {
    @EnvironmentObject var wb: Workbench
    @Namespace private var indicator
    var body: some View {
        let t = wb.theme
        VStack(spacing: 0) {
            item(.files, .explorer).tip("Explorer (⇧⌘E)")
            item(.search, .search).tip("Search (⇧⌘F)")
            item(.listTree, .outline).tip("Outline")
            Spacer()
            Menu {
                Button("Settings  ⌘,") { wb.settingsOpen = true }
                Button("Command Palette…") { wb.palette = true }
                Button("New Window") { wb.newWindow() }
                Button("New Window on \(wb.machine.name)") { wb.openInNewWindow(nil) }
                Button("Reload Theme & Settings from \(wb.machine.name)") { Task { await wb.syncSettings() } }
                Button("Sign Out", role: .destructive) { Account.shared.signOut() }
            } label: {
                Hovering { on in
                    CodiconView(icon: .settingsGear, size: 24).foregroundStyle(on ? t.activityFg : t.activityInactiveFg).frame(width: 48, height: 48)
                }
            }
            .hoverEffectDisabled()
            .tip("Manage")
        }
        .frame(width: 48)
        .background(t.activityBarBg)
    }

    private func item(_ icon: Codicon, _ view: SideView) -> some View {
        let active = wb.side == view
        return Button {
            if active || wb.side == nil { wb.toggleSidebar(view) } else { wb.side = view }
        } label: {
            Hovering { on in
                CodiconView(icon: icon, size: 24)
                    .foregroundStyle(active || on ? wb.theme.activityFg : wb.theme.activityInactiveFg)
                    .frame(width: 48, height: 48)
                    .overlay(alignment: .leading) {
                        if active {
                            Rectangle().fill(wb.theme.activityBorderActive).frame(width: 2)
                                .matchedGeometryEffect(id: "active", in: indicator)
                        }
                    }
                    .animation(Workbench.layoutAnimation, value: wb.side)
            }
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
    }
}

/// "Ln 12, Col 4": follows the caret without re-rendering the window.
private struct CursorPosition: View {
    @EnvironmentObject var status: EditorStatus
    var body: some View { Text("Ln \(status.line), Col \(status.column)") }
}

/// ⓧ errors ⚠ warnings; opens the Problems panel.
private struct ProblemCounts: View {
    @EnvironmentObject var wb: Workbench
    @EnvironmentObject var languages: Languages
    var body: some View {
        let c = languages.counts
        Button {
            wb.panelOpen = true
            wb.panelTab = .problems
        } label: {
            HStack(spacing: 3) {
                CodiconView(icon: .error, size: 13)
                Text("\(c.errors)")
                CodiconView(icon: .warning, size: 13).padding(.leading, 4)
                Text("\(c.warnings)")
            }
            .font(.system(size: 12)).padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .hoverBackground(wb.theme.statusItemHoverBg)
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
    }
}

/// Language mode plus its server: busy (progress), ready, or missing (tap to install).
private struct LanguageStatus: View {
    let file: OpenFile
    @EnvironmentObject var wb: Workbench
    @EnvironmentObject var languages: Languages
    @State private var showMissing = false

    var body: some View {
        let lang = Language.id(for: file.name) ?? ""
        let missing = languages.missing[lang]
        HStack(spacing: 4) {
            if let missing {
                Button { showMissing = true } label: {
                    HStack(spacing: 3) {
                        CodiconView(icon: .warning, size: 12)
                        Text("No \(missing.name) server")
                    }
                }
                .buttonStyle(.plain)
                .alert("No \(missing.name) language server on \(wb.machine.name)", isPresented: $showMissing) {
                    if !missing.install.isEmpty {
                        Button("Install in Terminal") { wb.newTerminal(input: missing.install) }
                        Button("Copy Command") { UIPasteboard.general.string = missing.install }
                    }
                    Button("Retry") { languages.retry(lang) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(missing.install.isEmpty ? missing.message
                         : "Install one on the desktop to get errors, completions and go to definition:\n\n\(missing.install)\n\nThen tap Retry.")
                }
            } else if let busy = languages.progress(for: file.path) {
                CodiconView(icon: .sync, size: 12)
                Text(busy).lineLimit(1).frame(maxWidth: 220)
            } else if let name = languages.serverName(for: file.path) {
                Text("{ } \(name)").foregroundStyle(wb.theme.statusBarFg.opacity(0.85))
            }
            Text(Language.displayName(for: file.name))
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject var wb: Workbench
    var body: some View {
        let t = wb.theme
        HStack(spacing: 0) {
            Menu {
                Button("Reconnect") { Task { await wb.reconnect() } }
                Button("Close Remote Connection") { closeWindow() }
            } label: {
                HStack(spacing: 4) {
                    CodiconView(icon: .remote, size: 14)
                    Text("Tunnel: \(wb.machine.name)").font(.system(size: 12))
                }
                .padding(.horizontal, 8).frame(maxHeight: .infinity)
                .hoverBackground(t.remoteHoverBg)
                .background(t.remoteBg).foregroundStyle(t.remoteFg)
            }
            .hoverEffectDisabled()
            .help("Remote Tunnel: \(wb.machine.name)")
            if !wb.osLabel.isEmpty {
                Text(wb.osLabel).font(.system(size: 12)).padding(.horizontal, 8)
            }
            ProblemCounts().help("Problems (⇧⌘M)")
            Spacer()
            if let f = wb.activeFile, f.viewer == .text {
                Group {
                    Button { wb.gotoLine = true } label: {
                        CursorPosition().padding(.horizontal, 6).frame(maxHeight: .infinity)
                            .hoverBackground(t.statusItemHoverBg)
                    }
                    .buttonStyle(.plain).hoverEffectDisabled().padding(.horizontal, -6)
                    .help("Go to Line/Column (⌃G)")
                    Text("Spaces: \(wb.tabSize)")
                    Text("UTF-8")
                    Text(f.crlf ? "CRLF" : "LF")
                    LanguageStatus(file: f)
                }
                .font(.system(size: 12)).padding(.horizontal, 6)
            }
            CodiconView(icon: .bell, size: 14).padding(.horizontal, 8)
        }
        .foregroundStyle(t.statusBarFg)
        .frame(height: 22)
        .background(t.statusBarBg)
        .overlay(alignment: .top) { Rectangle().fill(t.statusBarBorder).frame(height: 1) }
    }

    private func closeWindow() {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
        }
    }
}

struct ConnectingOverlay: View {
    @EnvironmentObject var wb: Workbench
    var body: some View {
        let t = wb.theme
        VStack(spacing: 14) {
            if let err = wb.connectError {
                CodiconView(icon: .debugDisconnect, size: 40).foregroundStyle(t.errorFg)
                Text("Could not connect to \(wb.machine.name)").font(.headline)
                Text(err).font(.system(size: 13)).foregroundStyle(t.descriptionFg).multilineTextAlignment(.center)
                Button("Retry") { Task { await wb.connect() } }
                    .buttonStyle(.borderedProminent).tint(t.buttonBg)
            } else {
                ProgressView()
                Text(wb.status).font(.system(size: 13)).foregroundStyle(t.descriptionFg)
            }
        }
        .padding(30).frame(maxWidth: 420)
        .background(t.quickInputBg).clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: t.widgetShadow, radius: 12)
        .foregroundStyle(t.quickInputFg)
    }
}

// MARK: Quick Open & Command Palette

struct QuickPickList<Item: Identifiable>: View {
    let placeholder: String
    @Binding var query: String
    let items: [Item]
    let row: (Item) -> AnyView
    let pick: (Item) -> Void
    let dismiss: () -> Void
    @EnvironmentObject var wb: Workbench
    @FocusState private var focused: Bool
    @State private var selection = 0

    var body: some View {
        let t = wb.theme
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(6).background(t.inputBg, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(t.inputFg)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.focusBorder))
                .padding(6)
                .focused($focused)
                .onSubmit { if let i = items.indices.contains(selection) ? items[selection] : items.first { pick(i) } }
                .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onChange(of: query) { selection = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.prefix(200).enumerated()), id: \.element.id) { i, item in
                            row(item)
                                .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
                                .background { if i == selection { RoundedRectangle(cornerRadius: 4).fill(t.listActiveBg) } }
                                .hoverBackground(i == selection ? .clear : t.listHoverBg, cornerRadius: 4)
                                .foregroundStyle(i == selection ? t.listActiveFg : t.quickInputFg)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(item) }
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, items.isEmpty ? 0 : 6)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            .frame(height: min(CGFloat(min(items.count, 200)) * 24 + (items.isEmpty ? 0 : 6), 420)) // fits its rows, like VS Code
        }
        .frame(width: 600)
        .floatingSurface(t.quickInputBg, cornerRadius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.widgetBorder))
        .shadow(color: t.widgetShadow, radius: 16, y: 6)
        // Centered in the window, just under the title bar, like VS Code;
        // tapping anywhere else dismisses.
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.001).onTapGesture(perform: dismiss))
        .onAppear { focused = true }
    }
}

private struct PathItem: Identifiable {
    let path: String
    var id: String { path }
}

private struct QuickOpen: View {
    @EnvironmentObject var wb: Workbench
    @State private var query = ""
    @State private var all: [String] = []
    @State private var loading = true

    var body: some View {
        QuickPickList(placeholder: loading ? "Indexing \(wb.machine.name)…" : "Search files by name",
                  query: $query, items: matches, row: { item in
            let name = (item.path as NSString).lastPathComponent
            return AnyView(HStack(spacing: 6) {
                FileIcon(name: name, size: 14)
                Text(Self.marked(name, query, wb.theme)).font(.system(size: 13))
                Text((item.path as NSString).deletingLastPathComponent).font(.system(size: 12))
                    .foregroundStyle(wb.theme.descriptionFg).lineLimit(1)
            })
        }, pick: { item in
            wb.quickOpen = false
            Task { await wb.open(wb.absolute(item.path)) }
        }, dismiss: { wb.quickOpen = false })
        .task {
            guard let d = wb.desktop, !wb.root.isEmpty else { loading = false; return }
            all = (try? await d.walk(root: wb.root, limit: 50_000)) ?? []
            loading = false
        }
    }

    /// Subsequence match ranked like VS Code: name hits before path hits.
    private var matches: [PathItem] {
        if query.isEmpty {
            return wb.files.map { PathItem(path: wb.relative($0.path)) } + all.prefix(100).map(PathItem.init)
        }
        let q = query.lowercased().replacingOccurrences(of: " ", with: "")
        func score(_ p: String) -> Int? {
            let lower = p.lowercased()
            let name = (lower as NSString).lastPathComponent
            if name.hasPrefix(q) { return 0 }
            if name.contains(q) { return 1 }
            if isSubsequence(q, of: name) { return 2 }
            if lower.contains(q) { return 3 }
            if isSubsequence(q, of: lower) { return 4 }
            return nil
        }
        var scored: [(path: String, rank: Int)] = []
        for p in all {
            if let r = score(p) { scored.append((p, r)) }
        }
        scored.sort { a, b in a.rank != b.rank ? a.rank < b.rank : a.path.count < b.path.count }
        return scored.prefix(200).map { PathItem(path: $0.path) }
    }

    /// `name` with the query's letters bold in list.highlightForeground: the
    /// contiguous match if there is one, else the first subsequence.
    static func marked(_ name: String, _ query: String, _ t: VSTheme) -> AttributedString {
        var a = AttributedString(name)
        let q = Array(query.lowercased().replacingOccurrences(of: " ", with: ""))
        guard !q.isEmpty else { return a }
        let chars = Array(name.lowercased())
        guard chars.count == name.count else { return a } // case folding changed the length
        var hits: [Int] = []
        if let r = name.lowercased().range(of: String(q)) {
            let s = name.lowercased().distance(from: name.lowercased().startIndex, to: r.lowerBound)
            hits = Array(s ..< s + q.count)
        } else {
            var j = 0
            for (i, c) in chars.enumerated() where j < q.count && c == q[j] { hits.append(i); j += 1 }
            if j < q.count { return a }
        }
        for i in hits {
            let lo = a.index(a.startIndex, offsetByCharacters: i)
            let hi = a.index(lo, offsetByCharacters: 1)
            a[lo..<hi].foregroundColor = t.highlightFg
            a[lo..<hi].font = .system(size: 13, weight: .semibold)
        }
        return a
    }

    private func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        return q.allSatisfy { c in
            while let n = it.next() { if n == c { return true } }
            return false
        }
    }
}

struct Command: Identifiable {
    let title: String
    let keys: String
    let run: @MainActor (Workbench) -> Void
    var id: String { title }

    static let all: [Command] = [
        Command(title: "File: Save", keys: "⌘S") { wb in Task { await wb.save() } },
        Command(title: "Go to File…", keys: "⌘P") { $0.quickOpen = true },
        Command(title: "View: Toggle Primary Side Bar Visibility", keys: "⌘B") { $0.toggleSidebar() },
        Command(title: "View: Toggle Panel Visibility", keys: "⌘J") { $0.togglePanel() },
        Command(title: "View: Show Explorer", keys: "⇧⌘E") { $0.side = .explorer },
        Command(title: "Search: Find in Files", keys: "⇧⌘F") { $0.side = .search },
        Command(title: "Terminal: Create New Terminal", keys: "⌃⇧`") { $0.newTerminal() },
        Command(title: "Terminal: Toggle Terminal", keys: "⌃`") { $0.toggleTerminal() },
        Command(title: "Terminal: Create New Terminal Window", keys: "") { $0.openTerminalWindow() },
        Command(title: "Terminal: Move Terminal into New Window", keys: "") { wb in
            if let id = wb.activeTerminal { wb.moveTerminalToNewWindow(id) }
        },
        Command(title: "Terminal: Focus Terminal", keys: "") { wb in
            wb.panelOpen = true
            wb.panelTab = .terminal
            wb.terminals.isEmpty ? wb.newTerminal() : wb.focusTerminal()
        },
        Command(title: "View: Close Editor", keys: "⌘W") { wb in if let a = wb.active { wb.close(a) } },
        Command(title: "File: Revert File", keys: "") { wb in if let a = wb.active { Task { await wb.revert(a) } } },
        Command(title: "File: Open Folder…", keys: "⌘O") { $0.picker = true },
        Command(title: "File: Close Folder", keys: "") { $0.closeFolder() },
        Command(title: "File: New Window", keys: "⇧⌘N") { $0.newWindow() },
        Command(title: "View: Split Editor Right", keys: "⌘\\") { $0.splitRight() },
        Command(title: "Run File", keys: "⌃F5") { $0.runActiveFile() },
        Command(title: "Tasks: Run Task…", keys: "⇧⌘B") { $0.taskPicker = true },
        Command(title: "Ports: Focus on Ports View", keys: "") { wb in wb.panelOpen = true; wb.panelTab = .ports },
        Command(title: "Rename Symbol", keys: "F2") { $0.languages.beginRename() },
        Command(title: "Find All References", keys: "⇧F12") { $0.languages.findReferences() },
        Command(title: "Quick Fix…", keys: "⌘.") { $0.languages.showCodeActions() },
        Command(title: "Trigger Parameter Hints", keys: "⇧⌘Space") { wb in
            if let tv = wb.languages.activeView, let p = wb.languages.activePath { wb.languages.requestSignature(tv, path: p) }
        },
        Command(title: "View: Close Editor Group", keys: "") { $0.closeGroup($0.focusedGroup) },
        Command(title: "View: Focus Other Editor Group", keys: "⌘K ⌘←/→") { wb in
            if wb.groups.count > 1 { wb.focusedGroup = wb.focusedGroup == 0 ? 1 : 0 }
        },
        Command(title: "Go to Line/Column…", keys: "⌃G") { wb in if wb.activeFile?.viewer == .text { wb.gotoLine = true } },
        Command(title: "Go to Symbol in Editor…", keys: "⇧⌘O") { wb in if wb.activeFile?.viewer == .text { wb.symbolPicker = true } },
        Command(title: "View: Show Outline", keys: "") { $0.side = .outline },
        Command(title: "Format Document", keys: "⇧⌥F") { wb in if let p = wb.active { Task { await wb.languages.format(p) } } },
        Command(title: "Markdown: Open Preview to the Side", keys: "⌘K V") { wb in if let p = wb.active { wb.openMarkdownPreview(p) } },
        Command(title: "Search: Replace in Files", keys: "⇧⌘H") { wb in wb.side = .search; wb.replaceMode = true },
        Command(title: "File: Upload from iPad…", keys: "") { wb in wb.uploadTarget = wb.root.isEmpty ? nil : wb.root },
        Command(title: "File: Download to iPad…", keys: "") { wb in if let p = wb.active { wb.download(p) } },
        Command(title: "Preferences: Open Settings", keys: "⌘,") { $0.settingsOpen = true },
        Command(title: "View: Toggle Word Wrap", keys: "⌥Z") { _ in AppSettings.shared.wordWrap.toggle() },
        Command(title: "File: New Window on This Desktop", keys: "") { $0.openInNewWindow(nil) },
        Command(title: "File: Duplicate Workspace in New Window", keys: "") { wb in
            wb.openInNewWindow(wb.root.isEmpty ? nil : wb.root)
        },
        Command(title: "Preferences: Reload Settings from Desktop", keys: "") { wb in Task { await wb.syncSettings() } },
        Command(title: "Remote: Reconnect", keys: "") { wb in Task { await wb.reconnect() } },
        Command(title: "Trigger Suggest", keys: "⌃Space") { $0.languages.requestCompletion() },
        Command(title: "Show or Focus Hover", keys: "⌘K ⌘I") { $0.languages.showHover() },
        Command(title: "Go to Definition", keys: "F12") { $0.languages.goToDefinition() },
        Command(title: "View: Toggle Problems", keys: "⇧⌘M") { wb in
            wb.panelOpen = !(wb.panelOpen && wb.panelTab == .problems)
            wb.panelTab = .problems
        },
        Command(title: "Developer: Restart Language Servers", keys: "") { wb in Task { await wb.languages.restart(stopOld: true) } },
        Command(title: "Preferences: Color Theme: GitHub Dark Dimmed", keys: "") { $0.theme = .bundled("github-dark-dimmed") },
        Command(title: "Preferences: Color Theme: Dark Modern", keys: "") { $0.theme = .bundled("dark-modern") },
        Command(title: "View: Increase Font Size", keys: "⌘=") { $0.fontSize = min($0.fontSize + 1, 32) },
        Command(title: "View: Decrease Font Size", keys: "⌘-") { $0.fontSize = max($0.fontSize - 1, 8) },
    ]
}

private struct CommandPalette: View {
    @EnvironmentObject var wb: Workbench
    @State private var query = ""
    var body: some View {
        let recent = Self.recent
        QuickPickList(placeholder: "Type the name of a command to run.", query: $query, items: matches, row: { c in
            AnyView(HStack(spacing: 8) {
                Text(highlighted(c.title)).font(.system(size: 13)).lineLimit(1)
                Spacer()
                if query.isEmpty, c.title == recent.first {
                    Text("recently used").font(.system(size: 12)).foregroundStyle(wb.theme.descriptionFg)
                }
                KeyChips(keys: c.keys, theme: wb.theme)
            })
        }, pick: { c in
            wb.palette = false
            Self.recent = [c.title] + recent.filter { $0 != c.title }.prefix(4)
            c.run(wb)
        }, dismiss: { wb.palette = false })
    }

    /// Titles of the last commands run, newest first (VS Code's "recently used").
    static var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "palette.recent") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "palette.recent") }
    }

    private var words: [Substring] {
        query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "> ")).split(separator: " ")
    }

    private var matches: [Command] {
        guard !words.isEmpty else {
            let recent = Self.recent
            let first = recent.compactMap { r in Command.all.first { $0.title == r } }
            return first + Command.all.filter { !recent.contains($0.title) }
        }
        return Command.all.filter { c in words.allSatisfy { c.title.lowercased().contains($0) } }
    }

    /// The query's words in the title in list.highlightForeground, bold.
    private func highlighted(_ title: String) -> AttributedString {
        var a = AttributedString(title)
        let lower = title.lowercased()
        for w in words {
            var from = lower.startIndex
            while let r = lower.range(of: w, range: from..<lower.endIndex) {
                if let ar = Range(NSRange(r, in: lower), in: a) {
                    a[ar].foregroundColor = wb.theme.highlightFg
                    a[ar].font = .system(size: 13, weight: .semibold)
                }
                from = r.upperBound
            }
        }
        return a
    }
}

// MARK: Hardware keyboard shortcuts (VS Code's defaults)

private struct KeyCommands: View {
    let wb: Workbench
    /// ⌘K starts a two-key chord (VS Code's ⌘K ⌘I).
    @State private var chord = Date.distantPast

    var body: some View {
        Group {
            key("k", .command, "Chord ⌘K…") { chord = .now }
            key("i", .command, "Trigger Suggest / Show Hover") {
                if Date.now.timeIntervalSince(chord) < 2 { chord = .distantPast; wb.languages.showHover() }
                else { wb.languages.requestCompletion() }
            }
            key("f", [.option, .shift], "Format Document") { if let p = wb.active { Task { await wb.languages.format(p) } } }
            // Everything else lives in the menu bar (Menus.swift).
        }
        .opacity(0).allowsHitTesting(false)
    }

    private func key(_ k: Character, _ mods: EventModifiers, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).keyboardShortcut(KeyEquivalent(k), modifiers: mods)
    }

}

/// Keyboard shortcut as VS Code draws it: one chip per key ("⇧⌘P" → ⇧ ⌘ P),
/// chords separated by a space.
struct KeyChips: View {
    let keys: String
    let theme: VSTheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.split(separator: " ").enumerated()), id: \.offset) { _, chord in
                HStack(spacing: 2) {
                    ForEach(Array(Self.split(chord).enumerated()), id: \.offset) { _, k in
                        Text(k).font(.system(size: 11))
                            .padding(.horizontal, 4).frame(minWidth: 18, minHeight: 17)
                            .foregroundStyle(theme.ui("keybindingLabel.foreground", "foreground", default: "#cccccc"))
                            .background(theme.ui("keybindingLabel.background", default: "#8080802b"), in: RoundedRectangle(cornerRadius: 3))
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).stroke(theme.ui("keybindingLabel.bottomBorder", "keybindingLabel.border", default: "#44444499"))
                            }
                    }
                }
            }
        }
    }

    /// "⇧⌘F12" → ["⇧", "⌘", "F12"]: each modifier glyph, then the key.
    static func split(_ chord: Substring) -> [String] {
        var out: [String] = []
        var rest = Substring(chord)
        while let c = rest.first, "⌘⇧⌥⌃".contains(c) { out.append(String(c)); rest = rest.dropFirst() }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}
