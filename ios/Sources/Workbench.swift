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
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 280
    @AppStorage("panelHeight") private var panelHeight: Double = 260
    /// Space between panels, and around them.
    static let gap: CGFloat = 8 // one spacing unit: between panels, around them, under the title bar
    @AppStorage("homeDark") private var homeDark = false
    private var h: HomeStyle { HomeStyle(dark: homeDark) }

    var body: some View {
        let t = wb.theme
        VStack(spacing: 0) {
            TitleBar(theme: t, title: commandCenterTitle, onCommandCenter: {
                if wb.root.isEmpty { wb.picker = true } else { wb.palette = false; wb.quickOpen = true }
            }) {
                EmptyView()
            } trailing: {
                TitleBarMenu(symbol: "macwindow.on.rectangle", label: "New Window") {
                    Button { wb.newWindow() } label: { Label("New Window  ⇧⌘N", systemImage: "macwindow.badge.plus") }
                    Button { wb.openInNewWindow(nil) } label: { Label("New Window on \(wb.machine.name)", systemImage: "desktopcomputer") }
                    if !wb.root.isEmpty {
                        Button { wb.openInNewWindow(wb.root) } label: {
                            Label("Open \(wb.baseName(wb.root)) in New Window", systemImage: "folder")
                        }
                    }
                }
                TitleBarButton(symbol: wb.zen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: wb.zen ? "Leave Zen Mode" : "Zen Mode", active: wb.zen) {
                    wb.toggleZen()
                }
                TitleBarButton(symbol: wb.side != nil ? "rectangle.leadingthird.inset.filled" : "rectangle",
                               label: "Toggle Primary Side Bar", active: wb.side != nil) {
                    wb.toggleSidebar()
                }
                TitleBarButton(symbol: wb.panelOpen ? "rectangle.bottomthird.inset.filled" : "rectangle",
                               label: "Toggle Panel", active: wb.panelOpen) {
                    wb.togglePanel()
                }
                TitleBarButton(symbol: homeDark ? "sun.max" : "moon", label: homeDark ? "Light Canvas" : "Dark Canvas") {
                    Appearance.toggle(in: wb.scene)
                }
            }
            // Panels float on the canvas; the gaps between them are the resize handles.
            HStack(spacing: 0) {
                if !wb.zen {
                    ActivityBar().zIndex(1) // the side bar slides out from under it
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if let side = wb.side {
                    Group {
                        switch side {
                        case .explorer: ExplorerView()
                        case .search: SearchView()
                        case .outline: OutlineView()
                        }
                    }
                    .transition(.blurFade) // swapping views inside the card
                    .frame(width: sidebarWidth)
                    .card(t, fill: t.sideBarBg)
                    .overlay { loadingEdges(t) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    Sash(axis: .vertical, value: $sidebarWidth, range: 170...600, reset: 280) { wb.toggleSidebar() }
                }
                VStack(spacing: 0) {
                    let maximized = wb.panelOpen && wb.panelMaximized
                    if !maximized {
                        // Zen mode: a centered column, like a page.
                        EditorArea()
                            .overlay { loadingEdges(t) }
                            .frame(maxWidth: wb.zen ? 1040 : .infinity)
                            .frame(maxWidth: .infinity)
                    }
                    if wb.panelOpen {
                        if !maximized { Sash(axis: .horizontal, value: $panelHeight, range: 80...900, sign: -1, reset: 260) { wb.hidePanel() } }
                        // Slides at its full height: the terminal isn't resized frame by frame.
                        // No fade: fading the terminal (a UIKit view) renders it offscreen every frame.
                        TerminalPanel()
                            .frame(height: maximized ? nil : panelHeight)
                            .frame(maxHeight: maximized ? .infinity : nil)
                            .card(t, fill: t.panelBg)
                            .overlay { loadingEdges(t) }
                            .transition(.move(edge: .bottom))
                    }
                }
            }
            .padding(.leading, wb.zen ? Self.gap : 0)
            .padding(.trailing, Self.gap) // flush with the title pill
            .padding(.bottom, wb.zen ? Self.gap : 0)
            // Every way of showing a view or the panel (menus, commands, a new terminal) slides it in.
            .animation(Motion.layout, value: wb.side)
            .animation(Motion.layout, value: wb.panelOpen)
            if !wb.zen {
                StatusBar().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .avoidKeyboard()
        .background(DotCanvas())
        .environment(\.home, h)
        .onChange(of: homeDark, initial: true) { wb.lightCanvas = !homeDark } // every window follows the toggle
        .overlay(alignment: .top) {
            // Pickers drop in under the title bar over a light scrim.
            let open = [wb.quickOpen, wb.palette, wb.symbolPicker, wb.workspaceSymbolPicker, wb.taskPicker, wb.gotoLine,
                        wb.picker && wb.desktop != nil]
            ZStack(alignment: .top) {
                if open.contains(true) {
                    Color.black.opacity(t.isDark ? 0.2 : 0.12).ignoresSafeArea().allowsHitTesting(false)
                        .transition(.opacity)
                }
                Group {
                    if wb.quickOpen { QuickOpen() }
                    if wb.palette { CommandPalette() }
                    if wb.symbolPicker { SymbolPicker() }
                    if wb.workspaceSymbolPicker { WorkspaceSymbolPicker() }
                    if wb.taskPicker { TaskPicker() }
                    if wb.gotoLine { GotoLinePicker() }
                    if wb.picker && wb.desktop != nil { FolderPicker() }
                }
                .transition(.pop())
            }
            .animation(Motion.popup, value: open)
            LanguageOverlays()
        }
        .overlay {
            ZStack {
                if wb.desktop == nil {
                    h.canvas.opacity(0.55).ignoresSafeArea().transition(.opacity)
                    ConnectingOverlay()
                }
            }
            .animation(Motion.popup, value: wb.desktop == nil)
        }
        .overlay(alignment: .bottomTrailing) { TransferToast(wb: wb) }
        .environmentObject(wb)
        .environmentObject(wb.languages)
        .environmentObject(wb.editorStatus)
        .focusedSceneObject(wb) // the menu bar acts on this window
        .preferredColorScheme(t.isDark ? .dark : .light)
        .statusBarHidden() // see App.swift
        .task {
            if Scenario.requested == "skeletons", wb.desktop == nil { await Scenario.shot("connecting", wait: 0.5) }
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
    /// While the desktop connects, the panels' outlines catch the skeleton shimmer.
    @ViewBuilder
    func loadingEdges(_ t: VSTheme) -> some View {
        if wb.desktop == nil && wb.connectError == nil && wb.trustPrompt == nil {
            SkeletonOutline(radius: 16, theme: t).transition(.opacity)
        }
    }

    /// Like VS Code: "folder [Tunnel: machine]", or just the machine when no folder is open.
    var commandCenterTitle: String {
        let via = wb.machine.isLocal ? "iPad" : wb.machine.isSSH ? "SSH" : "Tunnel"
        return wb.root.isEmpty ? "\(wb.machine.name) [\(via)]" : "\(wb.baseName(wb.root)) [\(via): \(wb.machine.name)]"
    }
}

/// The gap between two panels, which resizes them: a small grabber that
/// grows and lights up under the pointer, with a wider UIKit grab area on top
/// for the iPad resize pointer.
private struct Sash: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    @Binding var value: Double
    let range: ClosedRange<CGFloat>
    var sign: CGFloat = 1
    /// Double-tap puts the size back to this.
    let reset: CGFloat
    /// Dragging well past the minimum hides the panel instead of pinning it there.
    let collapse: () -> Void
    @EnvironmentObject var wb: Workbench
    @State private var start: CGFloat = 0
    @State private var active = false

    var body: some View {
        let vertical = axis == .vertical
        let t = wb.theme
        Color.clear
            .frame(width: vertical ? WorkbenchView.gap : nil, height: vertical ? nil : WorkbenchView.gap)
            .overlay {
                Capsule().fill(active ? t.sashHover : t.cardBorder.opacity(1.6))
                    .frame(width: vertical ? 3 : (active ? 64 : 28), height: vertical ? (active ? 64 : 28) : 3)
                    .animation(Motion.pop, value: active)
                    .allowsHitTesting(false)
            }
            .overlay {
                SashHandle(vertical: vertical, active: $active, began: { start = value }, moved: { t in
                    let want = start + sign * t
                    if want < range.lowerBound - 60 { collapse(); return }
                    value = min(max(want, range.lowerBound), range.upperBound)
                }, reset: { withAnimation(Motion.layout) { value = reset } })
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
    let reset: () -> Void

    func makeUIView(context: Context) -> SashView { SashView() }
    func updateUIView(_ v: SashView, context: Context) {
        v.vertical = vertical
        v.began = began
        v.moved = moved
        v.reset = reset
        v.activeChanged = { active = $0 }
    }
}

final class SashView: UIView, UIPointerInteractionDelegate {
    var vertical = true
    var began: () -> Void = {}
    var moved: (CGFloat) -> Void = { _ in }
    var reset: () -> Void = {}
    var activeChanged: (Bool) -> Void = { _ in }
    private var hovering = false { didSet { activeChanged(hovering || dragging) } }
    private var dragging = false { didSet { activeChanged(hovering || dragging) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
        let twice = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
        twice.numberOfTapsRequired = 2
        addGestureRecognizer(twice)
        addInteraction(UIPointerInteraction(delegate: self))
    }
    @objc private func doubleTap() { reset() }
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

/// The views down the left, on the canvas. The selected one sits on a pill
/// that slides between them; its symbol bounces when picked.
private struct ActivityBar: View {
    @EnvironmentObject var wb: Workbench
    @Environment(\.home) private var h
    @Namespace private var indicator
    var body: some View {
        let t = wb.theme
        VStack(spacing: 4) {
            ActivityItem(symbol: "doc.on.doc", view: .explorer, indicator: indicator).tip("Explorer (⇧⌘E)")
            ActivityItem(symbol: "magnifyingglass", view: .search, indicator: indicator).tip("Search (⇧⌘F)")
            ActivityItem(symbol: "list.bullet.indent", view: .outline, indicator: indicator).tip("Outline")
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
                    Image(systemName: "gearshape").font(.system(size: 18))
                        .foregroundStyle(h.muted.opacity(on ? 1 : 0.8))
                        .rotationEffect(.degrees(on ? 45 : 0))
                        .animation(Motion.pop, value: on)
                        .frame(width: 40, height: 40)
                }
            }
            .hoverEffectDisabled()
            .tip("Manage")
        }
        .padding(.vertical, 4)
        .frame(width: 52)
    }
}

private struct ActivityItem: View {
    let symbol: String
    let view: SideView
    let indicator: Namespace.ID
    @EnvironmentObject var wb: Workbench
    @Environment(\.home) private var h
    @State private var bounce = 0

    var body: some View {
        let active = wb.side == view
        Button {
            bounce += 1
            if active || wb.side == nil { wb.toggleSidebar(view) } else { withAnimation(Motion.pop) { wb.side = view } }
        } label: {
            Hovering { on in
                Image(systemName: symbol).font(.system(size: 18, weight: active ? .semibold : .regular))
                    .symbolEffect(.bounce.down, value: bounce)
                    .foregroundStyle(active ? h.ink : h.muted.opacity(on ? 1 : 0.8))
                    .frame(width: 40, height: 40)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(h.card)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(h.border))
                                .shadow(color: .black.opacity(0.05 * h.shadow), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "active", in: indicator)
                        } else if on {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(h.chip)
                        }
                    }
                    .animation(Motion.hover, value: on)
            }
        }
        .buttonStyle(PressDown(scale: 0.9))
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
            .frame(height: 20)
            .hoverBackground(wb.theme.hoverFill, cornerRadius: 10)
            .contentTransition(.numericText())
            .animation(Motion.pop, value: c.errors + c.warnings)
        }
        .buttonStyle(PressDown())
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
                Spinner()
                Text(busy).lineLimit(1).frame(maxWidth: 220)
            } else if let name = languages.serverName(for: file.path) {
                Text("{ } \(name)")
            }
            Text(Language.displayName(for: file.name))
        }
    }
}

/// The language server working: a turning symbol.
private struct Spinner: View {
    var body: some View {
        if #available(iOS 18.0, *) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                .symbolEffect(.rotate, isActive: true)
        } else {
            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject var wb: Workbench
    @Environment(\.home) private var h
    var body: some View {
        let t = wb.theme
        HStack(spacing: 0) {
            Menu {
                Button("Reconnect") { Task { await wb.reconnect() } }
                Button("Close Remote Connection") { closeWindow() }
            } label: {
                Hovering { on in
                    HStack(spacing: 5) {
                        StatusDot(online: wb.desktop != nil)
                        Text(wb.machine.name).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 9).frame(height: 20)
                    // On the canvas, so the canvas's own chip colours (not the editor theme's).
                    .background(on ? h.card : h.chip, in: Capsule())
                    .overlay(Capsule().strokeBorder(h.border))
                    .animation(Motion.hover, value: on)
                }
            }
            .buttonStyle(PressDown())
            .hoverEffectDisabled()
            .padding(.leading, 52 + 2) // lines up with the panels, past the activity bar
            .help("\(wb.machine.isLocal ? "Linux on this iPad" : wb.machine.isSSH ? "SSH" : "Remote Tunnel"): \(wb.machine.name)")
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
                    .buttonStyle(PressDown()).hoverEffectDisabled().padding(.horizontal, -6)
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
        .foregroundStyle(h.ink.opacity(0.65))
        .frame(height: 26)
        .padding(.trailing, WorkbenchView.gap)
    }

    private func closeWindow() {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
        }
    }
}

struct ConnectingOverlay: View {
    @EnvironmentObject var wb: Workbench
    @Environment(\.home) private var h
    var body: some View {
        let t = wb.theme
        VStack(spacing: 14) {
            if let fp = wb.trustPrompt {
                // First SSH connection: the user vouches for the host key once.
                Chip("First connection", dot: h.green)
                Image(systemName: "lock.shield").font(.system(size: 38, weight: .light))
                    .foregroundStyle(h.ink)
                    .symbolEffect(.bounce, value: fp)
                Text(wb.machine.name).font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Check that this is the machine's host key, then trust it. PadCode refuses to connect if it ever changes.")
                    .font(.system(size: 13)).foregroundStyle(h.muted).multilineTextAlignment(.center)
                Text(fp).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(h.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("On the machine: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(h.muted).textSelection(.enabled)
                HStack(spacing: 14) {
                    Button("Cancel") {
                        wb.trustPrompt = nil
                        wb.connectError = "Not connected: the host key wasn't trusted."
                    }
                    .buttonStyle(LinkButtonStyle(hover: h.green)).foregroundStyle(h.muted)
                    PrimaryButton(title: "Trust and Connect", theme: t) { wb.trustHostKey() }
                }
            } else if let err = wb.connectError {
                Chip("Not connected", dot: h.red)
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 38, weight: .light))
                    .foregroundStyle(h.ink)
                    .symbolEffect(.bounce, value: err)
                Text(wb.machine.name).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(err).font(.system(size: 13)).foregroundStyle(h.muted).multilineTextAlignment(.center)
                PrimaryButton(title: "Retry", theme: t) { Task { await wb.connect() } }
            } else {
                // Waves going out while the tunnel comes up.
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 38, weight: .light))
                    .foregroundStyle(h.ink)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                Text(wb.machine.name).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(wb.status).font(.system(size: 13, weight: .medium)).foregroundStyle(h.muted)
                    .contentTransition(.opacity)
                    .animation(Motion.quick, value: wb.status)
            }
        }
        .padding(32).frame(maxWidth: 420)
        .background(h.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)) // the panels' radius
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(h.border))
        .shadow(color: .black.opacity(h.dark ? 0.4 : 0.15), radius: 28, y: 12) // as high as the pickers
        .foregroundStyle(h.ink)
        .transition(.pop(from: .center))
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
    @Namespace private var pill
    private static var rowHeight: CGFloat { 28 }

    var body: some View {
        let t = wb.theme
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(t.accent)
                TextField("", text: $query, prompt: t.prompt(placeholder))
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .foregroundStyle(t.inputFg)
                    .focused($focused)
                    .onSubmit { if let i = items.indices.contains(selection) ? items[selection] : items.first { pick(i) } }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onChange(of: query) { selection = 0 }
            }
            .padding(.horizontal, 14).frame(height: 46)
            if !items.isEmpty { Rectangle().fill(t.cardBorder).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.prefix(200).enumerated()), id: \.element.id) { i, item in
                            row(item)
                                .padding(.horizontal, 10).frame(height: Self.rowHeight).frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    // The selection is one pill that glides between rows.
                                    if i == selection {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.accent.opacity(0.22))
                                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.accent.opacity(0.35)))
                                            .matchedGeometryEffect(id: "selection", in: pill)
                                    }
                                }
                                .hoverBackground(i == selection ? .clear : t.hoverFill, cornerRadius: 8)
                                .foregroundStyle(i == selection ? t.listActiveFg : t.quickInputFg)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(item) }
                                .id(i)
                        }
                    }
                    .padding(6)
                    .animation(Motion.pop, value: selection)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            .frame(height: min(CGFloat(min(items.count, 200)) * Self.rowHeight + (items.isEmpty ? 0 : 12), 440)) // fits its rows
            .animation(Motion.layout, value: min(items.count, 16))
        }
        .frame(width: 640)
        .floating(t, t.quickInputBg, radius: 16, lifted: true)
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
        Command(title: "Terminal: Run Selected Text in Active Terminal", keys: "") { $0.runSelectionInTerminal() },
        Command(title: "Terminal: Clear", keys: "⌘K") { wb in
            (wb.terminals.first { $0.id == wb.activeTerminal }?.view as? PadTerminalView)?.clearTerminal()
        },
        Command(title: "Terminal: Find", keys: "⌘F") { wb in
            wb.panelOpen = true
            wb.panelTab = .terminal
            wb.terminals.first { $0.id == wb.activeTerminal }?.finding = true
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
        Command(title: "View: Toggle Zen Mode", keys: "") { $0.toggleZen() },
        Command(title: "View: Toggle Maximized Panel", keys: "") { wb in
            wb.panelMaximized.toggle()
            if !wb.panelOpen { withAnimation(Workbench.layoutAnimation) { wb.panelOpen = true } }
        },
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
        Command(title: "Go to Symbol in Workspace…", keys: "") { $0.workspaceSymbolPicker = true },
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
        Command(title: "Go to Next Problem (Error, Warning, Info)", keys: "F8") { $0.languages.goToProblem(forward: true) },
        Command(title: "Go to Previous Problem (Error, Warning, Info)", keys: "⇧F8") { $0.languages.goToProblem(forward: false) },
        Command(title: "View: Toggle Problems", keys: "⇧⌘M") { wb in
            wb.panelOpen = !(wb.panelOpen && wb.panelTab == .problems)
            wb.panelTab = .problems
        },
        Command(title: "Developer: Restart Language Servers", keys: "") { wb in Task { await wb.languages.restart(stopOld: true) } },
        Command(title: "Preferences: Color Theme: GitHub Dark Dimmed", keys: "") { $0.chosenTheme = .bundled("github-dark-dimmed") },
        Command(title: "Preferences: Color Theme: Dark Modern", keys: "") { $0.chosenTheme = .bundled("dark-modern") },
        Command(title: "View: Toggle Dark Canvas", keys: "⌃⌘L") { wb in
            // After the palette has gone, so the reveal doesn't carry it.
            Task { try? await Task.sleep(for: .milliseconds(300)); Appearance.toggle(in: wb.scene) }
        },
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
