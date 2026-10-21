import SwiftUI

@main
struct PadCodeApp: App {
    @Environment(\.scenePhase) private var phase
    init() {
        Fonts.register()
        // A code editor shouldn't default to light: the canvas follows the system until the toggle is used.
        UserDefaults.standard.register(defaults: ["homeDark": UITraitCollection.current.userInterfaceStyle == .dark])
        Task { @MainActor in WidgetBridge.publish() } // the widget's copy of the token and hosts
    }

    var body: some Scene {
        // Start window: sign in and pick a desktop.
        WindowGroup(id: "machines") {
            MachinesView()
        }
        .commands { PadCommands() }
        .onChange(of: phase) { _, p in
            LocalLinux.shared.scenePhase(p)
            if p == .active { Appearance.syncWithSystem() }
        }
        // One window per desktop; iPadOS lets several sit side by side.
        WindowGroup(id: "workbench", for: WorkbenchTarget.self) { $target in
            if let target {
                WorkbenchView(wb: Workbench(machine: target.machine, folder: target.folder), target: $target)
                    .modifier(OpensMachineLinks(current: target.machine))
            } else {
                MachinesView() // restored window whose desktop can't be read: show home
            }
        }
        // Terminals on their own (Terminal: Move Terminal into New Window).
        WindowGroup(id: "terminals", for: TerminalWindowTarget.self) { $target in
            if let target {
                TerminalWindowView(wb: Workbench(machine: target.machine, folder: target.folder, terminals: target.terminals),
                                   target: $target)
                    .modifier(OpensMachineLinks())
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

/// The home window: title bar, then one page with every machine as a card
/// (tunnel desktops, SSH hosts, Linux on this iPad), the ones you can open
/// first, each with its recent folders. Setup help lives behind the + menu.
struct MachinesView: View {
    @StateObject private var account = Account.shared
    @StateObject private var ssh = SSHHosts.shared
    @State private var addingHost = false
    @State private var editingHost: SSHHost?
    @Environment(\.openWindow) private var openWindow
    @State private var opened: WorkbenchTarget?
    @State private var tunnelHelp = false
    @AppStorage("homeDark") private var homeDark = false
    private var h: HomeStyle { HomeStyle(dark: homeDark) }
    @State private var appeared = false
    @State private var scene: UIWindowScene?
    /// The title bar's search: narrows the grid by name or address.
    @State private var filter = ""
    @State private var widgetPreview: MachinesEntry? // test mode "widget"
    private var theme: VSTheme { homeDark ? .fallback : .light } // the page follows the canvas toggle

    var body: some View {
        let t = theme
        ZStack {
            (opened == nil ? h.canvas : t.canvasBg).ignoresSafeArea()
            if let opened {
                // Single-window case: this window becomes the workbench.
                WorkbenchView(wb: Workbench(machine: opened.machine, folder: opened.folder)).transition(.blurFade)
            } else {
                home(t).transition(.blurFade)
            }
            if let e = widgetPreview { WidgetPreview(entry: e) }
        }
        .animation(Motion.layout, value: opened == nil)
        .environment(\.home, h)
        .preferredColorScheme(opened == nil ? (homeDark ? .dark : .light) : t.isDark ? .dark : .light)
        // One-row look, like desktop VS Code. iPadOS still shows the menu bar
        // (PadCode, File, Edit, Selection…) when the pointer reaches the top edge.
        .statusBarHidden()
        .modifier(OpensMachineLinks(current: opened?.machine, open: { open($0, folder: $1) }))
        // No .persistentSystemOverlays(.hidden): on iPadOS 26 it hides the window
        // controls (the traffic lights), which then often didn't come back on hover.
        .task {
            // Test mode "home": screenshots of this page and the Add SSH Host sheet.
            if Scenario.requested == "home" {
                await Scenario.shot("home-skeleton", wait: 3) // before the first listing: skeletons (the shimmer sweeps meanwhile)
                await account.refresh()
                await Scenario.shot("home-reveal", wait: 0.15) // mid hand-off
                let wasDark = homeDark
                homeDark = false
                await Scenario.shot("home")
                filter = "mac"
                await Scenario.shot("home-filter", wait: 1.5)
                filter = "zzz"
                await Scenario.shot("home-filter-none", wait: 1.5)
                filter = ""
                homeDark = true
                await Scenario.shot("home-dark")
                homeDark = wasDark
                addingHost = true
                await Scenario.shot("add-ssh-host")
                addingHost = false
                return Scenario.log("DONE failures=0")
            }
            // Test mode "widget": its data matches the app's; its links open windows.
            if Scenario.requested == "widget" {
                await account.refresh()
                widgetPreview = await Scenario.widgetEntry()
                await Scenario.shot("widget-sizes")
                widgetPreview = nil
                await Scenario.widgetLinks()
                return Scenario.log("DONE failures=\(Scenario.failures)")
            }
            // Test mode over SSH: add the host and connect to it (the scenario
            // prints PadCode's key for the Mac's test sshd).
            if Scenario.requested != nil, opened == nil, Scenario.localTarget {
                opened = WorkbenchTarget(machine: LocalLinux.machine)
                return
            }
            if Scenario.requested != nil, opened == nil, let target = Scenario.sshTarget {
                Scenario.log("SSHKEY \(SSHKey.publicKey)")
                opened = WorkbenchTarget(machine: Scenario.sshHost(target).machine)
                return
            }
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
            TitleBar(theme: t, title: "Search machines", filter: $filter) {
                EmptyView()
            } trailing: {
                TitleBarButton(symbol: "macwindow.badge.plus", label: "New Window") { openWindow(id: "machines") }
                Menu { addMenu } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium)).opacity(0.72)
                        .frame(width: 36, height: 36)
                        .hoverBackground(Color(white: 0.5, opacity: 0.2), cornerRadius: 6)
                        .contentShape(Rectangle())
                }
                .hoverEffectDisabled().tip("Add a Machine")
                TitleBarButton(symbol: homeDark ? "sun.max" : "moon", label: homeDark ? "Light Mode" : "Dark Mode") {
                    Appearance.toggle(in: scene)
                }
                TitleBarButton(symbol: "arrow.clockwise", label: "Refresh") { Task { await account.refresh() } }
            }
            page(t).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(h.canvas)
        .background(WindowProbe { scene = $0?.windowScene })
        .onAppear { appeared = true }
        .sheet(isPresented: $addingHost) { SSHHostSheet(theme: t).preferredColorScheme(homeDark ? .dark : .light) }
        .sheet(item: $editingHost) { SSHHostSheet(editing: $0, theme: t).preferredColorScheme(homeDark ? .dark : .light) }
        .sheet(isPresented: $tunnelHelp) { TunnelSetupSheet(theme: t).preferredColorScheme(homeDark ? .dark : .light) }
    }

    @ViewBuilder
    private var addMenu: some View {
        Button { addingHost = true } label: { Label("Add SSH Host…", systemImage: "terminal") }
        Button { tunnelHelp = true } label: { Label("Set Up a Tunnel…", systemImage: "point.3.connected.trianglepath.dotted") }
    }

    // MARK: The page

    private func page(_ t: VSTheme) -> some View {
        ZStack {
            DotGrid()
            scroll(t)
        }
    }

    private func scroll(_ t: VSTheme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(t).rise(appeared, 0)
                if let last = lastOpened { continueCard(last.0, last.1, t).rise(appeared, 1).transition(.blurFade) }
                if account.token == nil {
                    GitHubCard(theme: t).rise(appeared, 1)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Machines").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(h.ink)
                        Chip("\(account.machines.count + ssh.hosts.count + 1)")
                        Spacer()
                        Text(summary).font(.system(size: 12)).foregroundStyle(h.muted)
                            .contentTransition(.numericText()).animation(Motion.pop, value: summary)
                    }
                    .rise(appeared, 1)
                    grid(t).rise(appeared, 2)
                    if let err = account.error {
                        Label(err, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(h.red)
                    }
                }
            }
            .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
            .frame(maxWidth: 1080, alignment: .leading)
            .animation(Motion.layout, value: lastOpened?.0.id)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await account.refresh() }
    }

    private func header(_ t: VSTheme) -> some View {
        HStack(spacing: 16) {
            Tile(symbol: "chevron.left.forwardslash.chevron.right", dark: true, size: 56, radius: 16)
                .symbolEffect(.bounce, value: appeared)
            VStack(alignment: .leading, spacing: 2) {
                Text("PadCode").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(h.ink)
                Text("Code on your desktops, or on Linux right here.").font(.system(size: 15)).foregroundStyle(h.muted)
            }
            Spacer(minLength: 12)
            accountChip(t)
        }
    }

    /// Who's signed in to GitHub (tunnels need it), with sign-in/out.
    private func accountChip(_ t: VSTheme) -> some View {
        Menu {
            if account.token == nil {
                Button { Task { await account.signIn() } } label: { Label("Sign In with GitHub", systemImage: "person.crop.circle") }
            } else {
                Button { Task { await account.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { account.signOut() } label: { Label("Sign Out of GitHub", systemImage: "rectangle.portrait.and.arrow.right") }
            }
        } label: {
            Hovering { on in
                HStack(spacing: 7) {
                    Image(systemName: account.token == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                        .font(.system(size: 15)).foregroundStyle(account.token == nil ? h.muted : h.green)
                    Text(account.token == nil ? "Not signed in" : "GitHub").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(h.muted)
                }
                .foregroundStyle(h.ink)
                .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 8)
                .background(h.card, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? h.green : h.border))
                .shadow(color: .black.opacity((on ? 0.08 : 0.04) * h.shadow), radius: 8, y: 3)
                .animation(Motion.hover, value: on)
            }
        }
        .buttonStyle(PressDown())
        .hoverEffectDisabled()
        .tip("GitHub account")
    }

    /// "2 online · 3 tunnels · 1 SSH host"
    private var summary: String {
        let running = account.machines.filter(\.online).count
        var parts = ["\(running + 1 + ssh.hosts.count) online"] // SSH hosts and this iPad count as reachable
        if account.token != nil {
            parts.append(tunnelsLoading ? "looking for tunnels…" : "\(account.machines.count) tunnel\(account.machines.count == 1 ? "" : "s")")
        }
        if !ssh.hosts.isEmpty { parts.append("\(ssh.hosts.count) SSH host\(ssh.hosts.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: The grid: every machine the same way, the ones you can open first

    private static let grid = [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16, alignment: .top)]

    private func matches(_ words: String...) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private func grid(_ t: VSTheme) -> some View {
        let shown = account.machines.filter { matches($0.name) }
        let online = shown.filter(\.online)
        let offline = shown.filter { !$0.online }
        let hosts = ssh.hosts.filter { matches($0.name, $0.host, $0.user) }
        let local = matches("This iPad", "Linux", "iPad", "local")
        let none = !filter.isEmpty && shown.isEmpty && hosts.isEmpty && !local
        return LazyVGrid(columns: Self.grid, alignment: .leading, spacing: 16) {
            // Skeleton cards first, as many tunnels as last time: the real
            // ones come into focus in the same cells.
            if tunnelsLoading {
                ForEach(0..<account.lastCount, id: \.self) { _ in
                    LightSkeletonCard(theme: t).transition(.opacity.animation(Motion.layout))
                }
            }
            ForEach(Array(online.enumerated()), id: \.element.id) { i, m in
                tunnelCard(m, t)
                    .transition(.blurFade.animation(Motion.layout.delay(0.06 + Double(i) * 0.08)))
            }
            ForEach(hosts) { h in sshCard(h, t).transition(.pop(from: .center)) }
            if local { localCard(t).transition(.blurFade) }
            ForEach(offline, id: \.id) { m in tunnelCard(m, t).transition(.blurFade) }
            if none {
                Text("No machines match \u{201C}\(filter)\u{201D}").font(.system(size: 13)).foregroundStyle(h.muted)
                    .frame(maxWidth: .infinity, minHeight: 136).transition(.blurFade)
            }
            addCard(t)
        }
        .animation(Motion.layout, value: shown.map(\.id))
        .animation(Motion.layout, value: hosts)
        .animation(Motion.layout, value: local)
        .animation(Motion.layout, value: tunnelsLoading)
    }

    /// Signed in and the first listing hasn't come back (or is empty and still loading).
    private var tunnelsLoading: Bool {
        account.token != nil && account.machines.isEmpty && (account.loading || !account.loadedOnce)
    }

    private func tunnelCard(_ m: MachineInfo, _ t: VSTheme) -> some View {
        let os = account.knownOS[m.id].map { $0 == "mac" ? "macOS" : $0 == "windows" ? "Windows" : "Linux" }
        return machineCard(m, t, name: m.name, kind: "Tunnel", online: m.online, os: os,
                           subtitle: "VS Code tunnel", offlineHint: "Run `code tunnel` there to bring it online.") {
            if m.online { connectMenu(m) }
            Button { tunnelHelp = true } label: { Label("How Tunnels Work", systemImage: "questionmark.circle") }
        }
    }

    private func sshCard(_ h: SSHHost, _ t: VSTheme) -> some View {
        let os = account.knownOS[h.machine.id].map { $0 == "mac" ? "macOS" : "Linux" }
        return machineCard(h.machine, t, name: h.name, kind: "SSH", online: true, os: os, subtitle: h.address) { sshMenu(h) }
    }

    /// Alpine Linux running inside PadCode: works offline, slower than a real computer.
    private func localCard(_ t: VSTheme) -> some View {
        machineCard(LocalLinux.machine, t, name: "This iPad", kind: "iPad", online: true, os: "Alpine Linux",
                    subtitle: "Runs inside PadCode, works offline") { connectMenu(LocalLinux.machine) }
    }

    /// One look for every machine: icon, name, status line, kind badge, recent
    /// folders, Connect. Tapping anywhere on it connects; ⋯ has the rest.
    private func machineCard<M: View>(_ m: MachineInfo, _ t: VSTheme, name: String, kind: String, online: Bool, os: String? = nil,
                                      subtitle: String, offlineHint: String? = nil, @ViewBuilder menu: @escaping () -> M) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tags first, like a sticky note: what it is, whether it's up, its OS.
            HStack(spacing: 6) {
                Chip(kind)
                Chip(online ? "Online" : "Offline", dot: online ? h.green : h.muted.opacity(0.6))
                if let os { Chip(os) }
                Spacer(minLength: 4)
                Menu { menu() } label: {
                    CodiconView(icon: .ellipsis, size: 16).frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(h.muted).hoverEffectDisabled()
            }
            HStack(spacing: 10) {
                Tile(symbol: osSymbol(m), size: 36, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(h.muted).lineLimit(1)
                }
            }
            if online {
                actions(m, t)
            } else if let offlineHint {
                Text(.init(offlineHint)).font(.system(size: 12)).foregroundStyle(h.muted) // markdown: `code tunnel`
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(h.ink)
        .opacity(online ? 1 : 0.55) // the content, not the card: the grid stays covered
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .modifier(CardHover(theme: t, enabled: online))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .pressToOpen(enabled: online) { open(m) }
        .contextMenu { menu() }
    }

    /// Dashed tile at the end of the grid: the two ways to add a machine.
    private func addCard(_ t: VSTheme) -> some View {
        Menu { addMenu } label: {
            Hovering { on in
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                    Text("Add a Machine").font(.system(size: 13, weight: .semibold))
                    Text("SSH host or VS Code tunnel").font(.system(size: 11)).foregroundStyle(h.muted)
                }
                .foregroundStyle(h.ink)
                .frame(maxWidth: .infinity, minHeight: 136)
                .background(on ? h.card : .clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(on ? h.green : h.ink.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .contentShape(Rectangle())
                .animation(Motion.hover, value: on)
            }
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
    }

    @ViewBuilder
    private func sshMenu(_ h: SSHHost) -> some View {
        connectMenu(h.machine)
        Divider()
        Button { editingHost = h } label: { Label("Edit…", systemImage: "pencil") }
        Button { UIPasteboard.general.string = SSHKey.setupCommand } label: { Label("Copy Setup Command", systemImage: "doc.on.doc") }
        if h.fingerprint != nil {
            Button { ssh.trust(nil, for: h.machine) } label: { Label("Forget Host Key", systemImage: "key.slash") }
        }
        Button(role: .destructive) { ssh.remove(h.id) } label: { Label("Remove", systemImage: "trash") }
    }

    /// Recent folders on that machine, then Connect and New Window.
    @ViewBuilder
    private func actions(_ m: MachineInfo, _ t: VSTheme) -> some View {
        let recents = Array((UserDefaults.standard.stringArray(forKey: "recentFolders.\(m.id)") ?? []).prefix(3))
        ForEach(recents, id: \.self) { path in
            Button { open(m, folder: path) } label: {
                HStack(spacing: 6) {
                    CodiconView(icon: .history, size: 12)
                    Text(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path)
                        .font(.system(size: 13)).lineLimit(1)
                    Text(path).font(.system(size: 11)).foregroundStyle(h.muted).lineLimit(1).truncationMode(.head)
                }
            }
            .buttonStyle(LinkButtonStyle(hover: h.green))
            .foregroundStyle(h.ink)
            .contextMenu {
                Button("Open in Current Window") { opened = WorkbenchTarget(machine: m, folder: path) }
                Button("Open in New Window") { openWindow(id: "workbench", value: WorkbenchTarget(machine: m, folder: path)) }
            }
        }
        HStack {
            PrimaryButton(title: "Connect", theme: t) { open(m) }
            if UIApplication.shared.supportsMultipleScenes {
                Button { openWindow(id: "workbench", value: WorkbenchTarget(machine: m)) } label: {
                    Text("New Window").font(.system(size: 13)).foregroundStyle(h.ink)
                }
                .buttonStyle(LinkButtonStyle(hover: h.green))
            }
        }
    }

    /// The folder opened most recently, on a machine that can be opened now.
    private var lastOpened: (MachineInfo, String)? {
        guard let v = UserDefaults.standard.stringArray(forKey: "lastOpened"), v.count == 2 else { return nil }
        let all = account.machines.filter(\.online) + ssh.hosts.map(\.machine) + [LocalLinux.machine]
        guard let m = all.first(where: { $0.id == v[0] }) else { return nil }
        return (m, v[1])
    }

    /// Pick up where you left off: one tap back into the last folder.
    private func continueCard(_ m: MachineInfo, _ path: String, _ t: VSTheme) -> some View {
        let name = m.isLocal ? "This iPad" : m.name
        return HStack(spacing: 18) {
            Tile(symbol: "folder.fill", size: 64, radius: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Continue").font(.system(size: 11, weight: .bold)).foregroundStyle(h.green).textCase(.uppercase).kerning(0.6)
                    Chip(m.isLocal ? "iPad" : m.isSSH ? "SSH" : "Tunnel")
                }
                Text(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path)
                    .font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: osSymbol(m)).font(.system(size: 11))
                    Text("\(name) · \(path)").font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(h.muted)
            }
            Spacer(minLength: 12)
            PrimaryButton(title: "Open", theme: t, large: true) { open(m, folder: path) }
        }
        .foregroundStyle(h.ink)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardHover(theme: t, enabled: true, accent: true))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .pressToOpen { open(m, folder: path) }
        .contextMenu {
            Button("Open in Current Window") { opened = WorkbenchTarget(machine: m, folder: path) }
            Button("Open in New Window") { openWindow(id: "workbench", value: WorkbenchTarget(machine: m, folder: path)) }
        }
    }

    @ViewBuilder
    private func connectMenu(_ m: MachineInfo) -> some View {
        Button { opened = WorkbenchTarget(machine: m) } label: { Label("Connect in Current Window", systemImage: "arrow.right") }
        Button { openWindow(id: "workbench", value: WorkbenchTarget(machine: m)) } label: { Label("Connect in New Window", systemImage: "macwindow.badge.plus") }
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

/// How to make a desktop show up as a tunnel; was a block of text on the page.
private struct TunnelSetupSheet: View {
    @Environment(\.home) private var h
    let theme: VSTheme
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private let command = "code tunnel service install --accept-server-license-terms"

    var body: some View {
        let t = theme
        NavigationStack {
            List {
                Section {
                    step(1, "Install VS Code on the Mac, Windows PC or Linux machine.", t)
                    step(2, "There, sign in to GitHub with the same account as here.", t)
                    step(3, "Run this once in its terminal:", t)
                    HStack {
                        Text(command).font(.custom("Menlo", size: 12)).textSelection(.enabled)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            UIPasteboard.general.string = command
                            copied = true
                        }
                        .buttonStyle(PillButton()).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Set up a tunnel")
                } footer: {
                    Text("It shows up on this page as running, and stays reachable after reboots. The README has the steps for each OS.")
                }
            }
            .navigationTitle("Set Up a Tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .animation(Motion.pop, value: copied)
    }

    private func step(_ n: Int, _ text: String, _ t: VSTheme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(h.green, in: Circle())
            Text(text).font(.system(size: 15))
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

/// Tunnels need GitHub: sign in right where the tunnel desktops will appear.
private struct GitHubCard: View {
    @Environment(\.home) private var h
    let theme: VSTheme
    @ObservedObject private var account = Account.shared

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Tile(symbol: "person.crop.circle.badge.checkmark")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in with GitHub").font(.system(size: 15, weight: .semibold))
                    Text("Shows every desktop running `code tunnel` for your account.")
                        .font(.system(size: 12)).foregroundStyle(h.muted)
                }
            }
            if let login = account.pendingLogin {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this code on GitHub:").font(.system(size: 13))
                    Text(login.userCode).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Copy Code") { UIPasteboard.general.string = login.userCode }
                        Button("Open GitHub") {
                            UIPasteboard.general.string = login.userCode
                            if let u = URL(string: login.verificationUri) { UIApplication.shared.open(u) }
                        }
                        .buttonStyle(PillButton(filled: true))
                    }
                    .buttonStyle(PillButton())
                    ProgressView("Waiting for approval…").font(.system(size: 12))
                }
                .transition(.pop(from: .top))
            } else {
                PrimaryButton(title: "Sign In", theme: t) { Task { await account.signIn() } }
            }
        }
        .foregroundStyle(h.ink)
        .padding(18)
        .frame(maxWidth: 440, alignment: .leading)
        .modifier(CardHover(theme: t, enabled: true))
        .animation(Motion.popup, value: account.pendingLogin != nil)
    }
}

/// A white card with a soft shadow; under the pointer it lifts and gets the green edge.
private struct CardHover: ViewModifier {
    @Environment(\.home) private var h
    let theme: VSTheme
    let enabled: Bool
    /// The green edge always on (the page's "current" card).
    var accent = false
    @State private var on = false

    func body(content: Content) -> some View {
        let lifted = enabled && (on || Scenario.hoverAll)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content
            .background(h.card, in: shape)
            .overlay(shape.strokeBorder(lifted || accent ? h.green : h.border, lineWidth: lifted || accent ? 1.5 : 1))
            .shadow(color: .black.opacity((lifted ? 0.1 : 0.05) * h.shadow), radius: lifted ? 18 : 10, y: lifted ? 8 : 4)
            .scaleEffect(lifted ? 1.01 : 1)
            .animation(Motion.pop, value: lifted)
            .onHover { on = $0 }
    }
}

/// A rounded icon tile: light grey, or dark for the app mark.
private struct Tile: View {
    @Environment(\.home) private var h
    let symbol: String
    var dark = false
    var size: CGFloat = 44
    var radius: CGFloat = 12

    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(dark ? h.canvas : h.ink)
            .frame(width: size, height: size)
            .background(dark ? h.ink : h.chip, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(dark ? 0.25 : 0), radius: 10, y: 5)
    }
}

/// A machine card's placeholder while tunnels are listed: the same shimmer
/// wave as the workbench's loading rows, so loading looks alike everywhere.
private struct LightSkeletonCard: View {
    @Environment(\.home) private var h
    let theme: VSTheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Skeleton(width: 44, height: 44, radius: 12, theme: theme)
                VStack(alignment: .leading, spacing: 8) {
                    Skeleton(width: 150, height: 13, theme: theme)
                    Skeleton(width: 96, height: 10, theme: theme)
                }
            }
            Skeleton(width: 200, height: 10, theme: theme)
            Skeleton(width: 104, height: 30, radius: 15, theme: theme)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .background(h.card, in: shape)
        .overlay(shape.strokeBorder(h.border))
        .accessibilityLabel("Loading desktop")
    }
}

/// Online: a green dot that glows and breathes. Offline: a grey one.
struct StatusDot: View {
    let online: Bool
    @Environment(\.home) private var h
    var body: some View {
        Image(systemName: "circle.fill").font(.system(size: 7))
            .foregroundStyle(online ? h.green : h.muted.opacity(0.6))
            .shadow(color: online ? h.green.opacity(0.8) : .clear, radius: 3)
    }
}

/// Title, then icon (the "Connect →" button).
struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

/// The desktop's OS, as a symbol.
@MainActor private func osSymbol(_ m: MachineInfo) -> String {
    machineSymbol(os: Account.shared.knownOS[m.id], kind: m.isLocal ? .local : m.isSSH ? .ssh : .tunnel)
}
