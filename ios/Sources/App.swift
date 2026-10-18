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
    private let theme = VSTheme.fallback

    var body: some View {
        let t = theme
        ZStack {
            t.editorBg.ignoresSafeArea()
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
                TitleBarButton(icon: .emptyWindow, label: "New Window") { openWindow(id: "machines") }
                TitleBarButton(icon: .layoutSidebarLeft, label: "Toggle Side Bar", active: sidebar) { sidebar.toggle() }
                TitleBarButton(icon: .refresh, label: "Refresh") { Task { await account.refresh() } }
            }
            HStack(spacing: 0) {
                if sizeClass != .compact {
                    activityBar(t)
                    if sidebar {
                        explorer(t).frame(width: 300).background(t.sideBarBg)
                        Rectangle().fill(t.ui("sideBar.border", default: "#00000000")).frame(width: 1)
                    }
                }
                welcome(t).frame(maxWidth: .infinity, maxHeight: .infinity).background(t.editorBg)
            }
            homeStatusBar(t)
        }
    }

    // MARK: activity bar + REMOTE EXPLORER

    private func activityBar(_ t: VSTheme) -> some View {
        VStack(spacing: 0) {
            Button { sidebar.toggle() } label: {
                Hovering { on in
                    CodiconView(icon: .remote, size: 24)
                        .foregroundStyle(sidebar || on ? t.activityFg : t.activityInactiveFg)
                        .frame(width: 48, height: 48)
                        .overlay(alignment: .leading) {
                            if sidebar { Rectangle().fill(t.activityBorderActive).frame(width: 2) }
                        }
                }
            }
            .hoverEffectDisabled()
            Spacer()
            Menu {
                Button("Refresh") { Task { await account.refresh() } }
                Button("Sign Out", role: .destructive) { account.signOut() }
            } label: {
                Hovering { on in
                    CodiconView(icon: .account, size: 24).foregroundStyle(on ? t.activityFg : t.activityInactiveFg).frame(width: 48, height: 48)
                }
            }
            .hoverEffectDisabled()
        }
        .buttonStyle(.plain)
        .frame(width: 48)
        .background(t.activityBarBg)
    }

    private func explorer(_ t: VSTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("REMOTE EXPLORER").font(.system(size: 11))
                Spacer()
                Button { Task { await account.refresh() } } label: { CodiconView(icon: .refresh) }.tip("Refresh")
            }
            .buttonStyle(ToolbarButtonStyle()).foregroundStyle(t.sideBarTitleFg)
            .padding(.leading, 20).padding(.trailing, 10).frame(height: 35)

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
        HStack(spacing: 6) {
            CodiconView(icon: m.online ? .vmConnect : .vmOutline, size: 16)
            Text(m.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Circle().fill(m.online ? SwiftUI.Color.green : SwiftUI.Color.gray).frame(width: 7, height: 7)
        }
        .padding(.leading, 24).padding(.trailing, 12).frame(height: 26)
        .hoverBackground(m.online ? t.listHoverBg : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if m.online { open(m) } }
        .contextMenu { connectMenu(m) }
        .opacity(m.online ? 1 : 0.55)
    }

    // MARK: Welcome page

    private func welcome(_ t: VSTheme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PadCode").font(.system(size: 34, weight: .light)).foregroundStyle(t.editorFg)
                    Text("Your desktops, through VS Code Remote Tunnels")
                        .font(.system(size: 17)).foregroundStyle(t.descriptionFg)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Desktops", t)
                    if account.machines.isEmpty && !account.loading {
                        Text("No desktops found for this GitHub account yet.")
                            .font(.system(size: 13)).foregroundStyle(t.descriptionFg)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        ForEach(account.machines, id: \.id) { m in card(m, t) }
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
                        .padding(8).frame(maxWidth: 640, alignment: .leading)
                        .background(t.ui("textCodeBlock.background", "input.background", default: "#0a0a0a66"))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
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
        Text(s).font(.system(size: 19)).foregroundStyle(t.editorFg)
    }

    private func card(_ m: MachineInfo, _ t: VSTheme) -> some View {
        let recents = Array((UserDefaults.standard.stringArray(forKey: "recentFolders.\(m.id)") ?? []).prefix(3))
        let os = account.knownOS[m.id].map { $0 == "mac" ? "macOS" : $0 == "windows" ? "Windows" : "Linux" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CodiconView(icon: m.online ? .vmConnect : .vmOutline, size: 26)
                    .foregroundStyle(m.online ? t.focusBorder : t.descriptionFg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(m.online ? SwiftUI.Color.green : SwiftUI.Color.gray).frame(width: 7, height: 7)
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
                            Text("Connect").font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 5)
                                .background(on ? t.ui("button.hoverBackground", "button.background", default: "#1177bb") : t.buttonBg)
                                .foregroundStyle(t.buttonFg)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
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
        .background(t.ui("welcomePage.tileBackground", "editorWidget.background", default: "#252526"))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.ui("welcomePage.tileBorder", "widget.border", default: "#ffffff1a")))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                CodiconView(icon: .remote, size: 14)
                Text("Remote Tunnels").font(.system(size: 12))
            }
            .padding(.horizontal, 8).frame(maxHeight: .infinity)
            .background(t.remoteBg).foregroundStyle(t.remoteFg)
            Text("\(running) of \(account.machines.count) desktops running").font(.system(size: 12)).padding(.horizontal, 8)
            Spacer()
        }
        .foregroundStyle(t.statusBarFg)
        .frame(height: 22)
        .background(t.statusBarBg)
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
            CodiconView(icon: .remote, size: 64).foregroundStyle(t.focusBorder)
            Text("PadCode").font(.system(size: 28, weight: .light))
            Text("Connect to your desktops through VS Code Remote Tunnels.")
                .font(.system(size: 14)).foregroundStyle(t.descriptionFg)
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
                .padding(20).background(t.sideBarBg).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Button {
                    Task { await account.signIn() }
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.crop.circle")
                        .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(t.buttonBg)
            }
            if let err = account.error {
                Text(err).font(.system(size: 12)).foregroundStyle(t.errorFg)
            }
        }
        .foregroundStyle(t.editorFg)
        .padding(40)
    }
}

