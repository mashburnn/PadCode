import SwiftUI

@main
struct PadCodeApp: App {
    init() { Fonts.register() }

    var body: some Scene {
        // Start window: sign in and pick a desktop.
        WindowGroup(id: "machines") {
            MachinesView()
        }
        .commands { PadCommands() }
        // One window per desktop; iPadOS lets several sit side by side.
        WindowGroup(id: "workbench", for: WorkbenchTarget.self) { $target in
            if let target {
                WorkbenchView(wb: Workbench(machine: target.machine, folder: target.folder), target: $target)
            } else {
                MachinesView() // restored window whose desktop can't be read: show home
            }
        }
        // Terminals on their own (Terminal: Move Terminal into New Window).
        WindowGroup(id: "terminals", for: TerminalWindowTarget.self) { $target in
            if let target {
                TerminalWindowView(wb: Workbench(machine: target.machine, folder: target.folder, terminals: target.terminals),
                                   target: $target)
            } else {
                MachinesView()
            }
        }
        // With Windowed Apps on, a terminal opens as a terminal-sized window
        // (about 110 × 34) rather than filling the screen.
        .defaultSize(width: 900, height: 620)
    }
}

extension MachineInfo: Codable {
    enum CodingKeys: String, CodingKey { case name, id, cluster, online, proto }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), id: try c.decode(String.self, forKey: .id),
                  cluster: try c.decode(String.self, forKey: .cluster), online: try c.decode(Bool.self, forKey: .online),
                  protocol: try c.decodeIfPresent(UInt32.self, forKey: .proto))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(id, forKey: .id)
        try c.encode(cluster, forKey: .cluster)
        try c.encode(online, forKey: .online)
        try c.encodeIfPresent(self.protocol, forKey: .proto)
    }
}

/// The home window, laid out like VS Code with nothing open: title bar,
/// activity bar, a REMOTE EXPLORER sidebar listing every desktop running
/// `code tunnel`, and a Welcome page with a card per desktop and recent folders.
struct MachinesView: View {
    @StateObject private var account = Account.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var opened: WorkbenchTarget?
    @State private var sidebar = true
    @State private var appeared = false
    private let theme = VSTheme.fallback

    var body: some View {
        let t = theme
        ZStack {
            t.canvasBg.ignoresSafeArea()
            if let opened {
                // Single-window case: this window becomes the workbench.
                WorkbenchView(wb: Workbench(machine: opened.machine, folder: opened.folder))
            } else if account.token == nil {
                VStack(spacing: 0) {
                    TitleBar(theme: t, title: "PadCode") { EmptyView() } trailing: { EmptyView() }
                    SignInView(theme: t).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                home(t)
            }
        }
        .preferredColorScheme(t.isDark ? .dark : .light)
        // One-row look, like desktop VS Code. iPadOS still shows the menu bar
        // (PadCode, File, Edit, Selection…) when the pointer reaches the top edge.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            // Test mode with no sign-in yet (fresh Simulator): start it; the
            // code is printed to the console for the person at the Mac.
            if Scenario.requested != nil, account.token == nil, account.pendingLogin == nil { await account.signIn() }
            await account.refresh()
            // Test mode from the Mac: connect this window to the target desktop.
            if Scenario.requested != nil, opened == nil,
               let m = account.machines.first(where: { $0.online && (Scenario.machineName == nil || $0.name == Scenario.machineName) }) {
                opened = WorkbenchTarget(machine: m)
            }
        }
    }

    private func home(_ t: VSTheme) -> some View {
        VStack(spacing: 0) {
            TitleBar(theme: t, title: "PadCode — Remote Tunnels", onCommandCenter: { Task { await account.refresh() } }) {
                EmptyView()
            } trailing: {
                TitleBarButton(symbol: "macwindow.badge.plus", label: "New Window") { openWindow(id: "machines") }
                TitleBarButton(symbol: sidebar ? "rectangle.leadingthird.inset.filled" : "rectangle", label: "Toggle Side Bar", active: sidebar) {
                    withAnimation(Motion.layout) { sidebar.toggle() }
                }
                TitleBarButton(symbol: "arrow.clockwise", label: "Refresh") { Task { await account.refresh() } }
            }
            HStack(spacing: WorkbenchView.gap) {
                if sizeClass != .compact {
                    activityBar(t)
                    if sidebar {
                        explorer(t).frame(width: 300).card(t, fill: t.sideBarBg)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                welcome(t).frame(maxWidth: .infinity, maxHeight: .infinity).card(t, fill: t.editorBg)
            }
            .padding(.trailing, WorkbenchView.gap)
            homeStatusBar(t)
        }
        .onAppear { appeared = true }
    }

    // MARK: activity bar + REMOTE EXPLORER

    private func activityBar(_ t: VSTheme) -> some View {
        VStack(spacing: 4) {
            Button { withAnimation(Motion.layout) { sidebar.toggle() } } label: {
                Hovering { on in
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 18, weight: sidebar ? .semibold : .regular))
                        .foregroundStyle(sidebar ? t.accent : t.titleBarFg.opacity(on ? 0.95 : 0.55))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(sidebar ? t.accent.opacity(0.16) : on ? t.hoverFill : .clear))
                        .animation(Motion.pop, value: sidebar)
                }
            }
            .buttonStyle(PressDown(scale: 0.9))
            .hoverEffectDisabled()
            .tip("Remote Explorer")
            Spacer()
            Menu {
                Button("Refresh") { Task { await account.refresh() } }
                Button("Sign Out", role: .destructive) { account.signOut() }
            } label: {
                Hovering { on in
                    Image(systemName: "person.crop.circle").font(.system(size: 20))
                        .foregroundStyle(t.titleBarFg.opacity(on ? 0.95 : 0.55)).frame(width: 40, height: 40)
                }
            }
            .hoverEffectDisabled()
            .tip("Accounts")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .frame(width: 52 - WorkbenchView.gap) // the HStack's gap makes up the rest
    }

    private func explorer(_ t: VSTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Remote Explorer").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await account.refresh() } } label: { CodiconView(icon: .refresh) }.tip("Refresh")
            }
            .buttonStyle(ToolbarButtonStyle()).foregroundStyle(t.sideBarTitleFg)
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 40)

            HStack(spacing: 4) {
                CodiconView(icon: .chevronDown, size: 14)
                Text("TUNNELS").font(.system(size: 11, weight: .bold))
                if account.loading { ProgressView().scaleEffect(0.5) }
            }
            .foregroundStyle(t.sideBarTitleFg).padding(.horizontal, 8).frame(height: 22)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(account.machines, id: \.id) { m in treeRow(m, t) }
                }
            }
            .refreshable { await account.refresh() }
        }
        .foregroundStyle(t.sideBarFg)
    }

    private func treeRow(_ m: MachineInfo, _ t: VSTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: osSymbol(m)).font(.system(size: 14)).frame(width: 18)
            Text(m.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            StatusDot(online: m.online)
        }
        .padding(.leading, 20).padding(.trailing, 16).frame(height: 30)
        .hoverBackground(m.online ? t.hoverFill : .clear, cornerRadius: 7, inset: 6)
        .contentShape(Rectangle())
        .onTapGesture { if m.online { open(m) } }
        .contextMenu { connectMenu(m) }
        .opacity(m.online ? 1 : 0.55)
    }

    // MARK: Welcome page

    private func welcome(_ t: VSTheme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(LinearGradient(colors: [t.accent, t.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: t.accent.opacity(0.45), radius: 14, y: 6)
                        .symbolEffect(.bounce, value: appeared)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PadCode").font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(t.editorFg)
                        Text("Your desktops, through VS Code Remote Tunnels")
                            .font(.system(size: 15)).foregroundStyle(t.descriptionFg)
                    }
                }
                .rise(appeared, 0)

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Desktops", t).rise(appeared, 1)
                    if account.machines.isEmpty && !account.loading {
                        Text("No desktops found for this GitHub account yet.")
                            .font(.system(size: 13)).foregroundStyle(t.descriptionFg)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        ForEach(Array(account.machines.enumerated()), id: \.element.id) { i, m in card(m, t).rise(appeared, 2 + i) }
                    }
                }

                if let err = account.error {
                    Text(err).font(.system(size: 12)).foregroundStyle(t.errorFg)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Add a desktop", t)
                    Text("On each Mac, Windows or Linux machine, signed in to GitHub with this account, run:")
                        .font(.system(size: 13)).foregroundStyle(t.descriptionFg)
                    Text("code tunnel service install --accept-server-license-terms")
                        .font(.custom("Menlo", size: 12)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: 640, alignment: .leading)
                        .background(t.ui("textCodeBlock.background", "input.background", default: "#0a0a0a66"))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("It shows up here as running. The README has the steps for each OS.")
                        .font(.system(size: 12)).foregroundStyle(t.descriptionFg)
                }
            }
            .padding(.horizontal, 48).padding(.vertical, 36)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await account.refresh() }
    }

    private func sectionTitle(_ s: String, _ t: VSTheme) -> some View {
        Text(s).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(t.editorFg)
    }

    private func card(_ m: MachineInfo, _ t: VSTheme) -> some View {
        let recents = Array((UserDefaults.standard.stringArray(forKey: "recentFolders.\(m.id)") ?? []).prefix(3))
        let os = account.knownOS[m.id].map { $0 == "mac" ? "macOS" : $0 == "windows" ? "Windows" : "Linux" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: osSymbol(m)).font(.system(size: 20))
                    .foregroundStyle(m.online ? t.accent : t.descriptionFg)
                    .frame(width: 42, height: 42)
                    .background((m.online ? t.accent : t.descriptionFg).opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        StatusDot(online: m.online)
                        Text([m.online ? "Running" : "Offline", os].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(t.descriptionFg)
                    }
                }
                Spacer(minLength: 0)
            }
            if m.online {
                ForEach(recents, id: \.self) { path in
                    Button { open(m, folder: path) } label: {
                        HStack(spacing: 6) {
                            CodiconView(icon: .history, size: 12)
                            Text(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path)
                                .font(.system(size: 13)).lineLimit(1)
                            Text(path).font(.system(size: 11)).foregroundStyle(t.descriptionFg).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .buttonStyle(LinkButtonStyle(hover: t.linkHoverFg))
                    .foregroundStyle(t.highlightFg)
                    .contextMenu {
                        Button("Open in Current Window") { opened = WorkbenchTarget(machine: m, folder: path) }
                        Button("Open in New Window") { openWindow(id: "workbench", value: WorkbenchTarget(machine: m, folder: path)) }
                    }
                }
                HStack {
                    Button { open(m) } label: {
                        Hovering { on in
                            Label("Connect", systemImage: "arrow.right").labelStyle(TrailingIcon())
                                .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 7)
                                .background(on ? t.ui("button.hoverBackground", "button.background", default: "#1177bb") : t.buttonBg, in: Capsule())
                                .foregroundStyle(t.buttonFg)
                                .shadow(color: t.buttonBg.opacity(on ? 0.5 : 0), radius: 8, y: 3)
                                .animation(.easeOut(duration: 0.15), value: on)
                        }
                    }
                    .buttonStyle(PressDown())
                    .hoverEffectDisabled()
                    if UIApplication.shared.supportsMultipleScenes {
                        Button { openWindow(id: "workbench", value: WorkbenchTarget(machine: m)) } label: {
                            Text("New Window").font(.system(size: 13)).foregroundStyle(t.highlightFg)
                        }
                        .buttonStyle(LinkButtonStyle(hover: t.linkHoverFg))
                    }
                }
            } else {
                Text("Start `code tunnel` on this machine to connect.")
                    .font(.system(size: 12)).foregroundStyle(t.descriptionFg)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(t.editorFg)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .modifier(CardHover(theme: t, enabled: m.online))
        .opacity(m.online ? 1 : 0.65)
        .contextMenu { if m.online { connectMenu(m) } }
    }

    @ViewBuilder
    private func connectMenu(_ m: MachineInfo) -> some View {
        Button("Connect in Current Window") { opened = WorkbenchTarget(machine: m) }
        Button("Connect in New Window") { openWindow(id: "workbench", value: WorkbenchTarget(machine: m)) }
    }

    private func homeStatusBar(_ t: VSTheme) -> some View {
        let running = account.machines.filter(\.online).count
        return HStack(spacing: 8) {
            StatusDot(online: running > 0)
            Text("\(running) of \(account.machines.count) desktops running").font(.system(size: 12))
                .contentTransition(.numericText())
                .animation(Motion.pop, value: running)
            Spacer()
        }
        .padding(.leading, 60)
        .foregroundStyle(t.titleBarFg.opacity(0.7))
        .frame(height: 26)
        .background(t.canvasBg)
    }

    /// Connect here: in this window when it's the only one, else a new window.
    private func open(_ m: MachineInfo, folder: String? = nil) {
        let target = WorkbenchTarget(machine: m, folder: folder)
        if UIApplication.shared.supportsMultipleScenes {
            openWindow(id: "workbench", value: target)
        } else {
            opened = target
        }
    }
}

/// A terminal window: the desktop's persistent shells it shows, by session ID.
struct TerminalWindowTarget: Codable, Hashable {
    let machine: MachineInfo
    var folder: String?
    var terminals: [String] = []
    var nonce = UUID() // every request opens a new window (see WorkbenchTarget)
}

/// What a workbench window opens: a desktop and, optionally, a folder on it.
struct WorkbenchTarget: Codable, Hashable {
    let machine: MachineInfo
    var folder: String?
    /// Makes every request a new window. Without it, iPadOS would bring an
    /// existing window with the same desktop and folder to the front instead.
    var nonce = UUID()

    init(machine: MachineInfo, folder: String? = nil) {
        self.machine = machine
        self.folder = folder
    }

    enum CodingKeys: CodingKey { case machine, folder, nonce }

    // Windows saved by older builds have no nonce.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(MachineInfo.self, forKey: .machine)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        nonce = try c.decodeIfPresent(UUID.self, forKey: .nonce) ?? UUID()
    }
}

private struct SignInView: View {
    let theme: VSTheme
    @ObservedObject private var account = Account.shared
    @State private var started = false

    var body: some View {
        let t = theme
        VStack(spacing: 18) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(LinearGradient(colors: [t.accent, t.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: t.accent.opacity(0.45), radius: 18, y: 8)
                .symbolEffect(.bounce, value: started)
                .rise(started, 0)
            Text("PadCode").font(.system(size: 30, weight: .bold, design: .rounded)).rise(started, 1)
            Text("Connect to your desktops through VS Code Remote Tunnels.")
                .font(.system(size: 14)).foregroundStyle(t.descriptionFg).rise(started, 2)
            if let login = account.pendingLogin {
                VStack(spacing: 10) {
                    Text("Enter this code on GitHub:").font(.system(size: 13))
                    Text(login.userCode).font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Copy Code") { UIPasteboard.general.string = login.userCode }
                        Button("Open GitHub") {
                            UIPasteboard.general.string = login.userCode
                            if let u = URL(string: login.verificationUri) { UIApplication.shared.open(u) }
                        }
                        .buttonStyle(.borderedProminent).tint(t.buttonBg)
                    }
                    ProgressView("Waiting for approval…").font(.system(size: 12))
                }
                .padding(20).background(t.sideBarBg).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.pop(from: .top))
            } else {
                Button {
                    Task { await account.signIn() }
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.crop.circle")
                        .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(t.buttonBg).buttonBorderShape(.capsule)
                .rise(started, 3)
            }
            if let err = account.error {
                Text(err).font(.system(size: 12)).foregroundStyle(t.errorFg)
            }
        }
        .foregroundStyle(t.editorFg)
        .padding(40)
        .animation(Motion.popup, value: account.pendingLogin != nil)
        .onAppear { started = true }
    }
}


/// A welcome-page tile that lifts under the pointer: brighter border and background, a shadow.
private struct CardHover: ViewModifier {
    let theme: VSTheme
    let enabled: Bool
    @State private var on = false

    func body(content: Content) -> some View {
        let t = theme
        let lifted = enabled && (on || Scenario.hoverAll)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .background(lifted ? t.raised : t.hoverFill, in: shape)
            .overlay(shape.strokeBorder(lifted ? t.accent.opacity(0.5) : t.cardBorder))
            .shadow(color: .black.opacity(lifted ? (t.isDark ? 0.35 : 0.12) : 0), radius: 16, y: 8)
            .scaleEffect(lifted ? 1.012 : 1)
            .offset(y: lifted ? -3 : 0)
            .animation(Motion.pop, value: lifted)
            .onHover { on = $0 }
    }
}

/// Online: a green dot that glows and breathes. Offline: a grey one.
struct StatusDot: View {
    let online: Bool
    private static let green = Color(red: 0.35, green: 0.86, blue: 0.56)
    var body: some View {
        Image(systemName: "circle.fill").font(.system(size: 7))
            .foregroundStyle(online ? Self.green : Color.gray.opacity(0.7))
            .shadow(color: online ? Self.green.opacity(0.8) : .clear, radius: 3)
            .symbolEffect(.pulse, isActive: online)
    }
}

/// Title, then icon (the "Connect →" button).
private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

/// The desktop's OS, as a symbol.
@MainActor private func osSymbol(_ m: MachineInfo) -> String {
    switch Account.shared.knownOS[m.id] {
    case "mac": "laptopcomputer"
    case "windows": "pc"
    case "linux": "server.rack"
    default: "desktopcomputer"
    }
}
