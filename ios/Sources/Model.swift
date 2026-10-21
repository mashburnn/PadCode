import Combine
import Foundation
import Security
import SwiftUI

/// GitHub token in the Keychain; one sign-in covers every desktop.
enum TokenStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "padcode.github",
        kSecAttrAccount as String: "token",
    ]

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

/// Sign-in state and the list of desktops, shared by all windows.
@MainActor
final class Account: ObservableObject {
    static let shared = Account()

    @Published var token: String? = TokenStore.load() ?? Account.simulatorToken

    /// Testing aid: `SIMCTL_CHILD_PADCODE_TOKEN=… xcrun simctl launch …` skips
    /// sign-in. Compiled out of device builds.
    private static var simulatorToken: String? {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["PADCODE_TOKEN"]
        #else
        nil
        #endif
    }
    @Published var machines: [MachineInfo] = []
    @Published var loading = false
    /// The first listing came back (until then the home page shows skeletons).
    @Published var loadedOnce = false
    /// How many tunnel desktops the last listing had: that many skeleton cards,
    /// so the page doesn't change shape when the real ones arrive.
    var lastCount: Int { max(UserDefaults.standard.object(forKey: "tunnelCount") as? Int ?? 2, 1) }
    @Published var error: String?
    @Published var pendingLogin: DeviceLogin?
    /// Last seen OS per tunnel id, for icons in the machine list.
    @Published var knownOS: [String: String] = UserDefaults.standard.dictionary(forKey: "knownOS") as? [String: String] ?? [:]

    func signIn() async {
        error = nil
        do {
            let login = try await startLogin()
            pendingLogin = login.info()
            if Scenario.requested != nil { Scenario.log("LOGIN \(login.info().userCode) \(login.info().verificationUri)") }
            let t = try await login.wait()
            TokenStore.save(t)
            token = t
            pendingLogin = nil
            await refresh()
        } catch {
            pendingLogin = nil
            self.error = error.userMessage
        }
    }

    func signOut() {
        TokenStore.clear()
        token = nil
        machines = []
        WidgetBridge.publish()
    }

    func refresh() async {
        guard let token else { return }
        loading = true
        defer {
            loading = false
            loadedOnce = true
            WidgetBridge.publish()
        }
        do {
            machines = try await listMachines(token: token)
            UserDefaults.standard.set(machines.count, forKey: "tunnelCount")
            error = nil
        } catch PadError.AuthExpired {
            signOut()
            error = "GitHub sign-in expired. Sign in again."
        } catch {
            self.error = error.userMessage
        }
    }

    func remember(os: HostOs, for id: String) {
        knownOS[id] = "\(os)"
        UserDefaults.standard.set(knownOS, forKey: "knownOS")
        WidgetBridge.publish()
    }
}

/// Per-keystroke editor state. Held by reference so typing doesn't mutate the
/// published `files` array (which would re-render the whole window each key).
final class LiveBuffer {
    var text: String
    var cursor = (line: 1, column: 1)
    init(_ text: String) { self.text = text }
}

/// Line/column and an edit counter, for the few views that follow typing.
@MainActor
final class EditorStatus: ObservableObject {
    @Published var line = 1
    @Published var column = 1
    @Published var edits = 0
}

struct OpenFile: Identifiable, Equatable {
    private(set) var path: String
    /// A Markdown preview is named after its source (its path carries a marker).
    var name: String {
        let p = MarkdownPreview.sourcePath(path)
        return p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? p
    }
    var id: String { path }
    /// Bytes as loaded/last saved, for conflict detection.
    var original: Data
    private let live: LiveBuffer
    /// The editor's current text. Writes don't publish (see LiveBuffer);
    /// snapshot it (`let t = f.text`) before an await if you compare later.
    var text: String {
        get { live.text }
        nonmutating set { live.text = newValue }
    }
    var dirty = false
    var crlf: Bool
    var cursor: (line: Int, column: Int) {
        get { live.cursor }
        nonmutating set { live.cursor = newValue }
    }
    /// Images and PDFs open in a viewer; `text` is empty for those.
    var viewer: Viewer = .text
    var pendingLine: Int?
    /// 0-based UTF-16 column to place the caret at with pendingLine.
    var pendingColumn: Int?
    /// Bumped when the text changes outside the editor, so editors reload.
    var revision = 0

    init(path: String, original: Data, text: String, crlf: Bool, viewer: Viewer = .text) {
        self.path = path
        self.original = original
        self.live = LiveBuffer(text)
        self.crlf = crlf
        self.viewer = viewer
    }

    func moved(to newPath: String) -> OpenFile {
        var f = self
        f.path = newPath
        return f
    }

    static func == (a: OpenFile, b: OpenFile) -> Bool {
        a.path == b.path && a.dirty == b.dirty && a.live === b.live && a.pendingLine == b.pendingLine
            && a.revision == b.revision && a.viewer == b.viewer
            && a.pendingColumn == b.pendingColumn
    }
}

enum SideView { case explorer, search, outline }

enum Viewer: Equatable {
    case text, image, pdf, markdownPreview, browser

    /// Files shown by a viewer instead of the text editor.
    static func binary(for path: String) -> Viewer? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "ico", "svg": .image
        case "pdf": .pdf
        default: nil
        }
    }
}

/// One editor column. Split editor = two groups side by side.
struct EditorGroupState: Identifiable, Equatable {
    let id = UUID()
    var tabs: [String] = []
    var active: String?
}

enum PanelTab { case problems, terminal, ports }

/// One window's connection to one desktop: open folder, editors, terminals.
@MainActor
final class Workbench: ObservableObject {
    let machine: MachineInfo
    @Published var desktop: Desktop?
    @Published var env: HostEnv?
    @Published var status: String = "Connecting…"
    @Published var connectError: String?
    /// SSH: the host key to confirm before the first connection ("SHA256:…").
    @Published var trustPrompt: String?
    @Published var root: String = ""
    /// Every open document, shared by all groups (one buffer per path).
    @Published var files: [OpenFile] = []
    @Published var groups: [EditorGroupState] = [EditorGroupState()]
    @Published var focusedGroup = 0
    /// Bytes of open images/PDFs, keyed by path.
    @Published var blobs: [String: Data] = [:]
    @Published var gotoLine = false
    @Published var symbolPicker = false
    @Published var workspaceSymbolPicker = false
    @Published var taskPicker = false
    /// Desktop port -> iPad port it's served on (for previews).
    @Published var forwards: [UInt16: UInt16] = [:]
    /// Search view shows the Replace field.
    @Published var replaceMode = false
    @Published var settingsOpen = false
    @Published var transfer: String?
    /// Explorer folder that receives an upload from the Files app.
    @Published var uploadTarget: String?
    /// ⌘N: the Explorer asks for a name.
    @Published var newFileRequest = false
    let settings = AppSettings.shared
    @Published var side: SideView? = .explorer
    @Published var panelOpen = true
    /// The panel fills the editor's space (the editor steps aside).
    @Published var panelMaximized = false
    /// Zen mode: only the editor, centered.
    @Published var zen = false
    private var beforeZen: (side: SideView?, panel: Bool)?
    /// The tab being dragged within this window, for reordering.
    var draggingTab: String?
    @Published var quickOpen = false
    @Published var palette = false
    /// What the panels show: the light theme on a light canvas, else the chosen one.
    @Published private(set) var theme: VSTheme = UserDefaults.standard.bool(forKey: "homeDark") ? .fallback : .light
    /// The theme from Settings (or the desktop's VS Code), used on a dark canvas.
    var chosenTheme: VSTheme = .fallback { didSet { refreshTheme() } }
    var lightCanvas = !UserDefaults.standard.bool(forKey: "homeDark") { didSet { refreshTheme() } }
    private func refreshTheme() { theme = lightCanvas ? .light : chosenTheme }
    @Published var fontSize: CGFloat = 12
    @Published var tabSize = 4
    @Published var terminals: [TerminalSession] = []
    /// Live editors by "group:path" (see CodeEditor.makeCoordinator).
    var editors: [String: CodeEditor.Coordinator] = [:]
    @Published var activeTerminal: UUID?
    @Published var alert: String?
    @Published var conflict: String?
    /// Bumped to make the Explorer re-read folders.
    @Published var explorerGeneration = 0
    /// The "Open Folder or File" picker (shown after connecting, like VS Code's
    /// empty window, and from File: Open Folder…).
    @Published var picker = false
    /// Pending drag-and-drop move awaiting confirmation.
    @Published var pendingMove: (from: String, toDir: String)?

    let languages = Languages()
    let editorStatus = EditorStatus()
    @Published var panelTab: PanelTab = .terminal
    /// Set once connected, so a later failure means "reconnecting", not "first connect".
    private var everConnected = false

    /// Folder to open right after connecting (from a Recent entry on the home screen).
    private let initialFolder: String?
    /// Set by the window's view, so commands can open other windows.
    var openWindowAction: OpenWindowAction?

    /// File: New Window: a home window to pick any desktop.
    func newWindow() {
        openWindowAction?(id: "machines")
    }

    /// Another window on this desktop, optionally opening `folder`.
    func openInNewWindow(_ folder: String?) {
        openWindowAction?(id: "workbench", value: WorkbenchTarget(machine: machine, folder: folder))
    }

    static let maxOpenBytes: UInt64 = 50_000_000
    private var backStack: [Spot] = []
    private var forwardStack: [Spot] = []
    private var closedStack: [String] = []

    /// A terminal window: only these desktop shells (persistent session IDs;
    /// empty starts one), no editor, Explorer or language servers.
    let terminalsOnly: [String]?
    /// A terminal window's scene and SwiftUI's dismiss for it, so it closes
    /// once its last terminal goes.
    weak var scene: UIWindowScene?
    var dismissWindow: (() -> Void)?

    /// Closing a terminal window's last terminal closes the window. On screen,
    /// SwiftUI's dismiss (requestSceneSessionDestruction's close animation made
    /// the iPadOS 27 Simulator's backboardd crash); in the background, where
    /// SwiftUI doesn't act, the scene session is destroyed directly.
    private func closeIfEmptyTerminalWindow() {
        guard terminalsOnly != nil, terminals.isEmpty else { return }
        // Land back in the editor, not on the home screen: once this window's
        // close is under way (a window that's no longer in front doesn't close).
        let editor = editorWindow
        defer {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                editor?.bringToFront()
            }
        }
        if let scene, scene.activationState == .background || scene.activationState == .unattached {
            let quiet = UIWindowSceneDestructionRequestOptions()
            quiet.windowDismissalAnimation = .decline // nothing on screen to animate
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: quiet)
        } else {
            dismissWindow?()
        }
    }
    /// Every live workbench, for finding a new window's (tests).
    static var live: [WeakWorkbench] = []

    init(machine: MachineInfo, folder: String? = nil, terminals: [String]? = nil) {
        self.machine = machine
        initialFolder = folder
        terminalsOnly = terminals
        languages.wb = self
        Self.live = Self.live.filter { $0.wb != nil } + [WeakWorkbench(wb: self)]
        if terminals != nil { adoptFromOpenWindow() }
    }

    /// Live terminals moving between this app's windows, by session ID: the
    /// new window takes the running view and stream as they are (no reconnect,
    /// no replay, no reflow), so the move is instant.
    static var handoff: [String: TerminalSession] = [:]

    /// A terminal window opened from another window on the same desktop shares
    /// its connection and look, so it's ready at once instead of connecting.
    private func adoptFromOpenWindow() {
        guard let ids = terminalsOnly,
              let source = Self.live.compactMap(\.wb).first(where: { $0 !== self && $0.machine.id == machine.id && $0.desktop != nil })
        else { return } // e.g. restored after a relaunch: connect() reattaches by ID
        desktop = source.desktop
        env = source.env
        chosenTheme = source.chosenTheme
        fontSize = source.fontSize
        tabSize = source.tabSize
        status = machine.name
        everConnected = true
        root = initialFolder ?? ""
        panelOpen = true
        panelTab = .terminal
        if ids.isEmpty { newTerminal() }
        for id in ids {
            if let live = Self.handoff.removeValue(forKey: id) { adopt(live, focus: id == ids.last) }
            else { newTerminal(persistentID: id, focus: id == ids.last) }
        }
    }

    /// The next or previous terminal tab, wrapping around.
    func cycleTerminal(_ step: Int) {
        guard !terminals.isEmpty else { return }
        let i = terminals.firstIndex { $0.id == activeTerminal } ?? 0
        focusTerminal(terminals[(i + step + terminals.count) % terminals.count].id)
    }

    /// Takes a running terminal from another window of this app.
    func adopt(_ t: TerminalSession, focus: Bool) {
        panelTab = .terminal
        terminals.append(t)
        activeTerminal = t.id
        panelOpen = true
        t.workbench = self
        if focus { focusTerminal() }
    }

    /// Removes a terminal from this window without stopping it (it's moving).
    private func release(terminal id: UUID) -> TerminalSession? {
        guard let i = terminals.firstIndex(where: { $0.id == id }) else { return nil }
        let t = terminals.remove(at: i)
        if activeTerminal == id { activeTerminal = (terminals.indices.contains(i) ? terminals[i] : terminals.last)?.id }
        return t
    }

    /// Terminal: Move Terminal into New Window. The shell keeps running on the
    /// desktop; the new window reattaches it by session ID.
    func moveTerminalToNewWindow(_ id: UUID) {
        // The live session moves, so this works on Windows desktops too.
        guard let t = release(terminal: id) else { return }
        Self.handoff[t.persistentID] = t
        if terminals.isEmpty && panelTab == .terminal && terminalsOnly == nil { panelOpen = false }
        openWindowAction?(id: "terminals", value: TerminalWindowTarget(machine: machine, folder: root.isEmpty ? nil : root, terminals: [t.persistentID]))
        closeIfEmptyTerminalWindow()
    }

    /// The editor window on the same desktop, if one is open (for moving back).
    var editorWindow: Workbench? {
        Workbench.live.compactMap(\.wb).first { $0 !== self && $0.terminalsOnly == nil && $0.machine.id == machine.id && $0.desktop != nil }
    }

    /// Hands a terminal back to the editor window's panel; the shell keeps running.
    func moveTerminalToEditorWindow(_ id: UUID) {
        guard let target = editorWindow, let t = release(terminal: id) else { return }
        target.adopt(t, focus: true)
        closeIfEmptyTerminalWindow() // and if this window stays, show the editor anyway
        if !terminals.isEmpty { target.bringToFront() }
    }

    /// Asks iPadOS to show this window (e.g. after a terminal moved into it).
    func bringToFront() {
        guard let session = scene?.session, scene?.activationState != .foregroundActive else { return }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
    }

    /// Terminal: Create New Terminal Window.
    func openTerminalWindow() {
        openWindowAction?(id: "terminals", value: TerminalWindowTarget(machine: machine, folder: root.isEmpty ? nil : root))
    }

    /// The focused group's visible document.
    var active: String? {
        get { groups.indices.contains(focusedGroup) ? groups[focusedGroup].active : nil }
        set { focus(newValue, in: focusedGroup) }
    }

    var activeFile: OpenFile? { files.first { $0.path == active } }

    func file(_ path: String?) -> OpenFile? { path.flatMap { p in files.first { $0.path == p } } }

    /// Shows `path` in group `g`, adding a tab if needed.
    func focus(_ path: String?, in g: Int) {
        guard groups.indices.contains(g) else { return }
        if let f = file(path) {
            if editorStatus.line != f.cursor.line { editorStatus.line = f.cursor.line }
            if editorStatus.column != f.cursor.column { editorStatus.column = f.cursor.column }
        }
        // Setting a @Published value redraws its watchers even when unchanged.
        if let path, !groups[g].tabs.contains(path) { groups[g].tabs.append(path) }
        if groups[g].active != path { groups[g].active = path }
        if focusedGroup != g { focusedGroup = g }
    }

    // MARK: Split editor

    /// View: Split Editor Right: the current file in a new group to the right.
    func splitRight() {
        let path = active
        if groups.count >= 2 {
            focus(path, in: 1)
            return
        }
        var g = EditorGroupState()
        if let path { g.tabs = [path]; g.active = path }
        groups.append(g)
        focusedGroup = groups.count - 1
    }

    func closeGroup(_ g: Int) {
        guard groups.count > 1, groups.indices.contains(g) else { return }
        let gone = groups.remove(at: g).tabs
        focusedGroup = min(focusedGroup, groups.count - 1)
        for p in gone where !groups.contains(where: { $0.tabs.contains(p) }) { release(p) }
    }

    /// Drops the buffer once no group shows the file.
    private func release(_ path: String) {
        files.removeAll { $0.path == path }
        blobs[path] = nil
        languages.closed(path)
        // A preview without its source has nothing to show.
        let preview = MarkdownPreview.previewPath(for: path)
        if files.contains(where: { $0.path == preview }) { closeEverywhere(preview) }
    }

    /// Opens a file in the other group (creating it), like Explorer → Open to the Side.
    func openToSide(_ path: String) async {
        let target = groups.count == 1 ? 1 : (focusedGroup == 0 ? 1 : 0)
        if groups.count == 1 { groups.append(EditorGroupState()) }
        focusedGroup = target
        await open(path)
    }

    /// Zen mode: everything but the editor slides away; leaving puts it back.
    func toggleZen() {
        withAnimation(Self.layoutAnimation) {
            if zen, let b = beforeZen {
                side = b.side
                panelOpen = b.panel
            } else {
                beforeZen = (side, panelOpen)
                side = nil
                panelOpen = false
            }
            zen.toggle()
        }
    }

    /// Drag a tab onto another: it takes that tab's place. From the other
    /// group, it moves over (to the end).
    /// ponytail: across groups it lands at the end, not at the drop spot.
    func moveTab(_ path: String, onto target: String, in g: Int) {
        guard groups.indices.contains(g), path != target, let j = groups[g].tabs.firstIndex(of: target) else { return }
        if let i = groups[g].tabs.firstIndex(of: path) {
            withAnimation(Self.layoutAnimation) {
                groups[g].tabs.move(fromOffsets: IndexSet(integer: i), toOffset: j > i ? j + 1 : j)
            }
        } else if let from = groups.firstIndex(where: { $0.tabs.contains(path) }) {
            withAnimation(Self.layoutAnimation) { moveToOtherGroup(path, from: from) }
        }
    }

    func moveToOtherGroup(_ path: String, from g: Int) {
        guard groups.count > 1 else { return }
        let other = g == 0 ? 1 : 0
        focus(path, in: other)
        if groups.indices.contains(g), let t = groups[g].tabs.firstIndex(of: path) {
            groups[g].tabs.remove(at: t)
            if groups[g].active == path { groups[g].active = groups[g].tabs.last }
            if groups[g].tabs.isEmpty { closeGroup(g) }
        }
    }

    /// Markdown: Open Preview to the Side (live, follows edits).
    func openMarkdownPreview(_ path: String) {
        let preview = MarkdownPreview.previewPath(for: path)
        if !files.contains(where: { $0.path == preview }) {
            files.append(OpenFile(path: preview, original: Data(), text: "", crlf: false, viewer: .markdownPreview))
        }
        if groups.count == 1 { groups.append(EditorGroupState()) }
        let other = groups.firstIndex(where: { $0.active != path }) ?? 1
        focus(preview, in: other)
    }

    func connect() async {
        connectError = nil
        trustPrompt = nil
        status = "Connecting to \(machine.name)…"
        do {
            let d: Desktop
            if machine.isSSH {
                guard let h = SSHHosts.shared.host(for: machine) else { connectError = "This SSH host was removed from PadCode."; return }
                guard SSHKey.privateKey != nil || !SSHKey.publicKey.isEmpty, let key = SSHKey.privateKey else {
                    connectError = "PadCode couldn't create its SSH key."
                    return
                }
                d = try await connectSsh(host: h.host, port: h.port, user: h.user, privatePem: key, fingerprint: h.fingerprint)
            } else if machine.isLocal {
                // Linux inside PadCode: boot it, then talk to it in-process.
                try await LocalLinux.shared.start { [weak self] in self?.status = $0 }
                d = try await connectLocal()
            } else {
                guard let token = Account.shared.token else { return }
                d = try await padcoreConnect(token: token, machine: machine)
            }
            let e = d.env()
            desktop = d
            env = e
            Account.shared.remember(os: e.os, for: machine.id)
            status = machine.name
            let first = !everConnected
            everConnected = true
            if let ids = terminalsOnly {
                // No folder session or language servers here: just the shells.
                if first {
                    root = initialFolder ?? ""
                    panelOpen = true
                    panelTab = .terminal
                    if ids.isEmpty { newTerminal() } else { for id in ids { newTerminal(persistentID: id, focus: id == ids.last) } }
                }
            } else if root.isEmpty {
                if let f = initialFolder { openFolder(f) } else { picker = true }
            }
            await syncSettings()
        } catch PadError.AuthExpired {
            Account.shared.signOut()
        } catch let PadError.HostKeyUnknown(_, fingerprint) {
            trustPrompt = fingerprint // ConnectingOverlay asks; trusting it reconnects
        } catch {
            connectError = error.userMessage
        }
    }

    /// Reconnects after the tunnel dropped (iPad sleep, network change).
    /// Called when the app comes to the foreground and every few seconds while
    /// it's open: a dead tunnel (iPad slept, Wi-Fi changed, Mac rebooted) gets
    /// replaced, and terminals and language servers come back on the new one.
    func reconnectIfNeeded() async {
        guard reconnectTask == nil else { return }
        if let d = desktop {
            guard (try? await d.ping()) == nil else { return }
        } else if !everConnected || connectError == nil {
            return // first connect in progress or not attempted
        }
        await reconnect()
    }

    private var reconnectTask: Task<Void, Never>?

    /// SSH: the user accepted the host key shown; remember it and connect.
    func trustHostKey() {
        guard let fp = trustPrompt else { return }
        SSHHosts.shared.trust(fp, for: machine)
        trustPrompt = nil
        Task { await connect() }
    }

    /// Replaces the connection. Concurrent callers (health check, app resume,
    /// terminals noticing the drop) all wait on the same attempt.
    func reconnect() async {
        if let running = reconnectTask { return await running.value }
        let task = Task {
            desktop = nil
            forwards = [:] // they lived on the old connection
            status = "Reconnecting to \(machine.name)…"
            await connect()
            guard desktop != nil else { return }
            for t in terminals { t.reattach(self) }
            explorerGeneration += 1
            await languages.restart(stopOld: false)
        }
        reconnectTask = task
        await task.value
        reconnectTask = nil
    }

    // MARK: Settings & theme from the desktop's VS Code

    /// The desktop VS Code's settings.json, as last read.
    private var desktopSettings: [String: Any] = [:]

    /// Effective editor settings: PadCode's own choices, else the desktop's.
    func applySettings() {
        let s = desktopSettings
        fontSize = settings.fontSize.map { CGFloat($0) } ?? (s["editor.fontSize"] as? Double).map { CGFloat($0) } ?? 12
        tabSize = settings.tabSize ?? (s["editor.tabSize"] as? Int) ?? 4
        if settings.themeChoice != AppSettings.desktopTheme {
            chosenTheme = VSTheme.bundled(settings.themeChoice)
        }
    }

    /// Theme names available from the desktop's installed VS Code extensions.
    func desktopThemes() async -> [String] {
        guard let d = desktop, let e = env else { return [] }
        let extDir = d.join(base: e.home, name: ".vscode/extensions")
        var names: [String] = []
        for ext in (try? await d.listDir(path: extDir)) ?? [] where ext.kind == .dir {
            guard let pkg = try? await d.readFile(path: d.join(base: d.join(base: extDir, name: ext.name), name: "package.json")),
                  let json = try? JSONSerialization.jsonObject(with: pkg) as? [String: Any],
                  let themes = (json["contributes"] as? [String: Any])?["themes"] as? [[String: Any]] else { continue }
            names += themes.compactMap { ($0["id"] as? String) ?? ($0["label"] as? String) }
        }
        return Array(Set(names)).sorted()
    }

    /// Loads a theme by its VS Code name from the desktop's extensions.
    func useDesktopTheme(named name: String) async {
        guard let d = desktop, let e = env, let t = await findTheme(named: name, d, e) else { return }
        chosenTheme = t
    }

    private func settingsPath(_ e: HostEnv) -> String {
        switch e.os {
        case .mac: return "\(e.home)/Library/Application Support/Code/User/settings.json"
        case .linux: return "\(e.home)/.config/Code/User/settings.json"
        case .windows: return "\(e.appdata ?? e.home + "\\AppData\\Roaming")\\Code\\User\\settings.json"
        }
    }

    func syncSettings() async {
        guard let d = desktop, let e = env,
              let data = try? await d.readFile(path: settingsPath(e)),
              let s = parseJSONC(data) else { return }
        desktopSettings = s
        applySettings()
        let name = settings.desktopThemeName ?? (s["workbench.colorTheme"] as? String)
        if settings.themeChoice == AppSettings.desktopTheme, let name, let t = await findTheme(named: name, d, e) {
            chosenTheme = t
        }
    }

    /// Looks for the theme in built-in bundles, then the desktop's extensions.
    private func findTheme(named name: String, _ d: Desktop, _ e: HostEnv) async -> VSTheme? {
        let builtIn = ["GitHub Dark Dimmed": "github-dark-dimmed", "Dark Modern": "dark-modern", "Dark+": "dark_plus",
                       "Default Dark Modern": "dark-modern", "Default Dark+": "dark_plus", "Visual Studio Dark": "dark_vs"]
        let extDir = d.join(base: e.home, name: ".vscode/extensions")
        if let entries = try? await d.listDir(path: extDir) {
            for ext in entries where ext.kind == .dir {
                let dir = d.join(base: extDir, name: ext.name)
                guard let pkg = try? await d.readFile(path: d.join(base: dir, name: "package.json")),
                      let json = try? JSONSerialization.jsonObject(with: pkg) as? [String: Any],
                      let themes = (json["contributes"] as? [String: Any])?["themes"] as? [[String: Any]],
                      let hit = themes.first(where: { ($0["id"] as? String ?? $0["label"] as? String) == name || $0["label"] as? String == name }),
                      let rel = hit["path"] as? String else { continue }
                let themePath = d.join(base: dir, name: rel)
                guard let data = try? await d.readFile(path: themePath) else { continue }
                let themeDir = (themePath as NSString).deletingLastPathComponent
                var included: [String: Data] = [:]
                var next = parseJSONC(data)?["include"] as? String
                while let inc = next, included[inc] == nil,
                      let incData = try? await d.readFile(path: d.join(base: themeDir, name: inc)) {
                    included[inc] = incData
                    next = parseJSONC(incData)?["include"] as? String
                }
                if let t = VSTheme.load(data: data, name: name, resolve: { included[$0] }) { return t }
            }
        }
        return builtIn[name].map(VSTheme.bundled)
    }

    // MARK: Files

    /// Opens (or focuses) a file; `line` is 1-based, `column` 0-based UTF-16.
    /// Jumps elsewhere are recorded for Go Back unless `recording` is false.
    func open(_ path: String, line: Int? = nil, column: Int? = nil, recording: Bool = true) async {
        let from = here
        guard await load(path) else { return }
        if let i = files.firstIndex(where: { $0.path == path }) {
            files[i].pendingLine = line
            files[i].pendingColumn = column
        }
        active = path
        if recording, let from, from.path != path || (line != nil && line != from.line) {
            backStack.append(from)
            if backStack.count > 50 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
    }

    /// A caret position for navigation history (line 1-based, column 0-based).
    struct Spot: Equatable { var path: String; var line: Int; var column: Int }

    private var here: Spot? {
        file(active).map { Spot(path: $0.path, line: $0.cursor.line, column: max($0.cursor.column - 1, 0)) }
    }

    /// New File/Folder from the Explorer. "a/b.txt" creates the folders too.
    /// Never overwrites: an existing name is an error, like VS Code.
    func createItem(_ name: String, in parent: String, isDir: Bool, desktop d: Desktop) async {
        let parts = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return }
        let path = parts.reduce(parent) { d.join(base: $0, name: $1) }
        do {
            if (try? await d.stat(path: path))?.exists == true {
                alert = "A file or folder \(name) already exists at this location. Please choose a different name."
                return
            }
            if isDir {
                try await d.mkdirp(path: path)
            } else {
                if parts.count > 1 { try await d.mkdirp(path: parts.dropLast().reduce(parent) { d.join(base: $0, name: $1) }) }
                try await d.writeFile(path: path, data: Data())
                await open(path)
            }
            explorerGeneration += 1
        } catch { alert = error.userMessage }
    }

    /// Go Back (⌃-) / Go Forward (⌃⇧-), like VS Code.
    func goBack() { step(from: &backStack, to: &forwardStack) }
    func goForward() { step(from: &forwardStack, to: &backStack) }

    private func step(from: inout [Spot], to: inout [Spot]) {
        guard let s = from.popLast() else { return }
        if let h = here { to.append(h) }
        Task { await open(s.path, line: s.line, column: s.column, recording: false) }
    }

    /// Reopen Closed Editor (⇧⌘T).
    func reopenClosed() {
        guard let p = closedStack.popLast() else { return }
        Task { await open(p) }
    }

    /// File sizes from a background stat of each listed folder, so opening a
    /// file from the Explorer is one round trip (the read), not two.
    private var knownSizes: [String: UInt64] = [:]

    func learnSizes(in folder: String, _ entries: [Entry]) {
        guard let d = desktop else { return }
        // ponytail: the first 200 files per folder; a size can be stale if the
        // file grows past the limit afterwards (then it's read anyway, once).
        let files = entries.filter { $0.kind == .file }.prefix(200).map { d.join(base: folder, name: $0.name) }
        Task {
            await withTaskGroup(of: (String, UInt64?).self) { g in
                for f in files { g.addTask { (f, (try? await d.stat(path: f))?.size) } }
                for await (f, size) in g { if let size { knownSizes[f] = size } }
            }
        }
    }

    /// Reads a file into a buffer (no tab); true if it's open afterwards.
    @discardableResult
    func load(_ path: String, quiet: Bool = false) async -> Bool {
        if files.contains(where: { $0.path == path }) { return true }
        guard let d = desktop else { return false }
        do {
            // Don't pull a huge file through the tunnel into memory.
            var size = knownSizes[path]
            if size == nil { size = (try? await d.stat(path: path))?.size }
            if let size, size > Self.maxOpenBytes {
                if !quiet { alert = "\((path as NSString).lastPathComponent) is too large to open here (\(size / 1_000_000) MB). Use the terminal (less, tail) instead." }
                return false
            }
            let data = try await d.readFile(path: path)
            if files.contains(where: { $0.path == path }) { return true } // raced
            if let viewer = Viewer.binary(for: path) {
                blobs[path] = data
                files.append(OpenFile(path: path, original: data, text: "", crlf: false, viewer: viewer))
                return true
            }
            // NUL bytes mean binary even when they decode as UTF-8 (like git's check).
            guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else {
                if !quiet { alert = "\((path as NSString).lastPathComponent) is binary or not UTF-8." }
                return false
            }
            let crlf = text.contains("\r\n")
            files.append(OpenFile(path: path, original: data,
                                  text: crlf ? text.replacingOccurrences(of: "\r\n", with: "\n") : text, crlf: crlf))
            languages.opened(path)
            return true
        } catch {
            if !quiet { alert = error.userMessage }
            return false
        }
    }

    func edited(_ path: String, text: String) {
        guard let i = files.firstIndex(where: { $0.path == path }), files[i].text != text else { return }
        files[i].text = text // no window-wide re-render
        if !files[i].dirty {
            files[i].dirty = true // one publish, for the tab's ● dot
        } else if files.contains(where: { $0.path == MarkdownPreview.previewPath(for: path) })
                    || groups.filter({ $0.active == path }).count > 1 {
            objectWillChange.send() // a live preview or the other split follows the edit
        }
        editorStatus.edits += 1
        scheduleAutoSave(path)
    }

    /// Replaces a document's text from outside its editor (replace-all,
    /// formatting, cleanup); the editors reload it.
    func setText(_ path: String, _ text: String, autoSave: Bool = true) {
        guard let i = files.firstIndex(where: { $0.path == path }), files[i].text != text else { return }
        files[i].text = text
        files[i].dirty = true
        files[i].revision += 1
        languages.changed(path, text: text)
        if autoSave { scheduleAutoSave(path) }
    }

    // MARK: Auto save, external changes

    private static var autoSaves: [ObjectIdentifier: [String: Task<Void, Never>]] = [:]

    /// files.autoSave = afterDelay: saves a second after the last edit.
    /// (Formatting and whitespace cleanup only run on an explicit ⌘S.)
    private func scheduleAutoSave(_ path: String) {
        guard settings.autoSave, !Scenario.holdAutoSave else { return }
        let key = ObjectIdentifier(self)
        Self.autoSaves[key, default: [:]][path]?.cancel()
        Self.autoSaves[key, default: [:]][path] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.settings.autoSave, !Scenario.holdAutoSave, self.conflict != path,
                  self.files.first(where: { $0.path == path })?.dirty == true else { return }
            await self.save(path, auto: true)
        }
    }

    /// Saves every modified file (app going to the background).
    func saveAllDirty() async {
        guard settings.autoSave, !Scenario.holdAutoSave else { return }
        for f in files where f.dirty && f.viewer == .text && conflict != f.path { await save(f.path, auto: true) }
    }

    /// Reloads the active file if it changed on the desktop and has no unsaved
    /// edits (VS Code does the same). Called every few seconds.
    func checkActiveFileOnDisk() async {
        guard let f = activeFile, f.viewer == .text, !f.dirty, f.original.count < 2_000_000, let d = desktop,
              let data = try? await d.readFile(path: f.path), data != f.original,
              let i = files.firstIndex(where: { $0.path == f.path }), !files[i].dirty,
              let text = String(data: data, encoding: .utf8) else { return }
        files[i].original = data
        files[i].crlf = text.contains("\r\n")
        files[i].text = files[i].crlf ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        files[i].revision += 1
        languages.changed(f.path, text: files[i].text)
    }

    // MARK: Session (open tabs survive the app being closed)

    struct SavedSession: Codable {
        struct Group: Codable {
            var tabs: [String]
            var active: String?
        }
        var groups: [Group]
        var focused: Int
        var cursors: [String: [Int]]
        /// Unsaved edits ("hot exit"), restored as modified buffers.
        var dirty: [String: String]
        /// Hash of the file on disk those edits were based on.
        var dirtyBase: [String: String]?
        var panelOpen: Bool
        var terminals: [String]
    }

    private var sessionURL: URL? {
        guard !root.isEmpty else { return nil }
        let key = "\(machine.id)|\(root)".utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String(format: "%016llx.json", key))
    }

    static func digest(_ d: Data) -> String {
        String(format: "%016llx", d.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 })
    }

    func saveSession() {
        guard terminalsOnly == nil else { return } // the folder's session belongs to its main window
        guard let url = sessionURL, restoredSession else { return }
        let real = { (p: String) in self.file(p).map { $0.viewer != .markdownPreview && $0.viewer != .browser } ?? false }
        let s = SavedSession(
            groups: groups.map { .init(tabs: $0.tabs.filter(real), active: $0.active.flatMap { real($0) ? $0 : nil }) },
            focused: focusedGroup,
            cursors: Dictionary(uniqueKeysWithValues: files.filter { real($0.path) }.map { ($0.path, [$0.cursor.line, $0.cursor.column]) }),
            dirty: Dictionary(uniqueKeysWithValues: files.filter { $0.dirty && $0.viewer == .text }.map { ($0.path, $0.text) }),
            dirtyBase: Dictionary(uniqueKeysWithValues: files.filter { $0.dirty && $0.viewer == .text }.map { ($0.path, Self.digest($0.original)) }),
            panelOpen: panelOpen,
            terminals: terminals.map(\.persistentID))
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    /// Set once this folder's saved session has been applied (or there was none),
    /// so an empty startup state never overwrites it.
    private(set) var restoredSession = false
    private var sessionSaver: AnyCancellable?

    private func restoreSession() async {
        defer {
            // Only now: a terminal created earlier would add one more each launch.
            if terminals.isEmpty { newTerminal() }
            restoredSession = true
            sessionSaver = objectWillChange
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .sink { [weak self] in self?.saveSession() }
        }
        guard let url = sessionURL, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        var loaded = Set<String>()
        for path in Set(s.groups.flatMap(\.tabs)) where await load(path, quiet: true) { loaded.insert(path) }
        for (path, text) in s.dirty where loaded.contains(path) {
            // Back as an unsaved edit, but not auto-saved: the user decides.
            setText(path, text, autoSave: false)
            // If the file changed on the desktop while PadCode was closed, saving
            // must ask instead of silently overwriting those changes.
            if let base = s.dirtyBase?[path], let i = files.firstIndex(where: { $0.path == path }),
               Self.digest(files[i].original) != base {
                files[i].original = Data("\u{0}padcode: changed while closed".utf8)
            }
        }
        for (path, c) in s.cursors where loaded.contains(path) && c.count == 2 {
            if let i = files.firstIndex(where: { $0.path == path }) {
                files[i].pendingLine = c[0]
                files[i].pendingColumn = max(c[1] - 1, 0)
            }
        }
        let gs = s.groups.map { g -> EditorGroupState in
            var e = EditorGroupState()
            e.tabs = g.tabs.filter(loaded.contains)
            e.active = g.active.flatMap { loaded.contains($0) ? $0 : nil } ?? e.tabs.last
            return e
        }.filter { !$0.tabs.isEmpty }
        if !gs.isEmpty { groups = gs }
        focusedGroup = min(max(s.focused, 0), groups.count - 1)
        panelOpen = s.panelOpen
        for id in s.terminals { newTerminal(persistentID: id) }
    }

    func save(_ path: String? = nil, force: Bool = false, auto: Bool = false) async {
        guard let path = path ?? active, files.contains(where: { $0.path == path && $0.viewer == .text }), let d = desktop else { return }
        if settings.formatOnSave && !auto { await languages.format(path) }
        if !auto, settings.trimTrailingWhitespace || settings.insertFinalNewline, let i = files.firstIndex(where: { $0.path == path }) {
            let cleaned = settings.cleanUp(files[i].text)
            if cleaned != files[i].text {
                files[i].text = cleaned
                files[i].dirty = true
                files[i].revision += 1
                languages.changed(path, text: cleaned)
            }
        }
        guard let i = files.firstIndex(where: { $0.path == path }) else { return }
        let f = files[i]
        let savedText = f.text // snapshot: f.text is live and may change while we await
        let out = Data((f.crlf ? savedText.replacingOccurrences(of: "\n", with: "\r\n") : savedText).utf8)
        do {
            if force {
                try await d.writeFile(path: path, data: out)
            } else {
                try await d.saveFile(path: path, data: out, original: f.original)
            }
            if let j = files.firstIndex(where: { $0.path == path }) {
                files[j].original = out
                files[j].dirty = files[j].text != savedText
            }
            languages.saved(path, text: savedText)
        } catch PadError.Conflict {
            conflict = path
        } catch {
            // Auto-save retries on the next edit; don't interrupt typing with alerts.
            if auto { toast = "Couldn't save \(baseName(path)): \(error.userMessage)" }
            else { alert = "Save failed: \(error.userMessage)" }
        }
    }

    func revert(_ path: String) async {
        let g = focusedGroup
        closeEverywhere(path)
        focusedGroup = min(g, groups.count - 1)
        await open(path)
    }

    /// Closes a tab in group `g` (default: focused). The buffer goes once no
    /// group shows it; an empty secondary group collapses, like VS Code.
    func close(_ path: String, in g: Int? = nil, force: Bool = false) {
        let g = g ?? focusedGroup
        guard groups.indices.contains(g), let t = groups[g].tabs.firstIndex(of: path) else { return }
        let lastView = groups.filter { $0.tabs.contains(path) }.count == 1
        if lastView, !force, let i = files.firstIndex(where: { $0.path == path }), files[i].dirty {
            alert = "\(files[i].name) has unsaved changes. Save (⌘S) or close again to discard."
            files[i].dirty = false // second close discards, like VS Code's "Don't Save"
            return
        }
        groups[g].tabs.remove(at: t)
        editors["\(g):\(path)"] = nil // reopening starts a fresh editor (no stale undo)
        if groups[g].active == path {
            groups[g].active = groups[g].tabs.indices.contains(t) ? groups[g].tabs[t] : groups[g].tabs.last
        }
        if lastView {
            release(path)
            if !force { closedStack.removeAll { $0 == path }; closedStack.append(path) }
        }
        if groups[g].tabs.isEmpty && groups.count > 1 { closeGroup(g) }
    }

    /// Closes the file everywhere (deleted, reverted).
    func closeEverywhere(_ path: String) {
        for g in groups.indices.reversed() where groups[g].tabs.contains(path) { close(path, in: g, force: true) }
    }

    // MARK: Files app ⇄ desktop

    /// How far an upload has got (0…1), for the notification's bar; nil when
    /// there's nothing to count (a download is one file).
    @Published var transferProgress: Double?
    private var uploadedFiles = 0
    private var uploadTotal = 0

    private func uploading(_ name: String) {
        transfer = uploadTotal > 1 ? "Uploading \(name)… (\(uploadedFiles + 1) of \(uploadTotal))" : "Uploading \(name)…"
    }

    private func uploadedOne() {
        uploadedFiles += 1
        transferProgress = Double(uploadedFiles) / Double(max(uploadTotal, 1))
    }

    /// Files under `url` (1 for a file).
    private static func fileCount(_ url: URL) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return 1 }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        return (e?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }.count
    }

    /// Copies files picked in the iPad's Files app into a desktop folder.
    func upload(_ urls: [URL], to dir: String) async {
        guard let d = desktop else { return }
        var done = 0
        uploadedFiles = 0
        uploadTotal = urls.reduce(0) { n, url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return n + Self.fileCount(url)
        }
        transferProgress = 0
        defer { transferProgress = nil }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            uploading(url.lastPathComponent)
            do {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    var target = d.join(base: dir, name: url.lastPathComponent)
                    var n = 2
                    while try await d.stat(path: target).exists {
                        target = d.join(base: dir, name: "\(url.lastPathComponent) \(n)")
                        n += 1
                    }
                    done += try await uploadFolder(url, to: target, d)
                    continue
                }
                let data = try Data(contentsOf: url)
                var target = d.join(base: dir, name: url.lastPathComponent)
                var n = 2
                while try await d.stat(path: target).exists { // never overwrite
                    let base = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
                    target = d.join(base: dir, name: "\(base) \(n)\(ext)")
                    n += 1
                }
                try await d.writeFile(path: target, data: data)
                done += 1
                uploadedOne()
            } catch {
                alert = "Upload of \(url.lastPathComponent) failed: \(error.userMessage)"
            }
        }
        transfer = nil
        explorerGeneration += 1
        if done > 0 { toast = "Uploaded \(done) file\(done == 1 ? "" : "s") to \(baseName(dir))" }
    }

    /// Recreates a local folder tree on the desktop; returns the file count.
    private func uploadFolder(_ local: URL, to remote: String, _ d: Desktop) async throws -> Int {
        try await d.mkdirp(path: remote)
        var count = 0
        let items = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items {
            let target = d.join(base: remote, name: item.lastPathComponent)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                count += try await uploadFolder(item, to: target, d)
            } else {
                uploading(item.lastPathComponent)
                try await d.writeFile(path: target, data: Data(contentsOf: item))
                count += 1
                uploadedOne()
            }
        }
        return count
    }

    /// File waiting for the share/save sheet after download.
    @Published var exportURL: URL?
    @Published var toast: String?

    /// Copies a desktop file (or the open document) to the iPad, then offers
    /// the share sheet: Save to Files, AirDrop, open in another app…
    func download(_ path: String) {
        Task {
            guard let d = desktop else { return }
            transfer = "Downloading \(baseName(path))…"
            defer { transfer = nil }
            do {
                let data = try await d.readFile(path: path)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(baseName(path))
                try data.write(to: url, options: .atomic)
                exportURL = url
            } catch {
                alert = "Download failed: \(error.userMessage)"
            }
        }
    }

    // MARK: Folders

    private var recentsKey: String { "recentFolders.\(machine.id)" }

    /// Most recently opened folders on this desktop, newest first.
    var recentFolders: [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    func openFolder(_ path: String) {
        let changed = root != path
        if changed { saveSession() } // keep the old folder's tabs
        root = path
        if changed {
            restoredSession = false
            sessionSaver = nil
            Task {
                await languages.restart(stopOld: true)
                await restoreSession()
            }
        }
        picker = false
        explorerGeneration += 1
        side = side ?? .explorer
        var r = recentFolders.filter { $0 != path }
        r.insert(path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(10)), forKey: recentsKey)
        UserDefaults.standard.set([machine.id, path], forKey: "lastOpened") // the home page's Continue card
        if !changed && terminals.isEmpty { newTerminal() } // same folder: no restore pending
    }

    /// Opening a lone file opens its folder too, so the Explorer and terminal have context.
    func openFileFromPicker(_ path: String) async {
        let sep: Character = env?.os == .windows ? "\\" : "/"
        if let cut = path.lastIndex(where: { $0 == sep || $0 == "/" }) {
            let dir = String(path[..<cut])
            openFolder(dir.isEmpty || dir.hasSuffix(":") ? dir + String(sep) : dir)
        }
        await open(path)
    }

    func closeFolder() {
        root = ""
        Task { await languages.restart(stopOld: true) }
        picker = true
    }

    // MARK: Moving files (Explorer drag and drop)

    func parentDir(_ path: String) -> String {
        guard let cut = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        let dir = String(path[..<cut])
        return dir.isEmpty ? "/" : dir
    }

    func baseName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// Whether `path` is `dir` itself or inside it.
    func isWithin(_ path: String, _ dir: String) -> Bool {
        path == dir || path.hasPrefix(dir + "/") || path.hasPrefix(dir + "\\")
    }

    /// Asks before moving, like VS Code's explorer.confirmDragAndDrop.
    func requestMove(_ from: String, toDir: String) {
        guard !isWithin(toDir, from), parentDir(from) != toDir else { return }
        pendingMove = (from, toDir)
    }

    func move(_ from: String, toDir: String) async {
        guard let d = desktop else { return }
        await relocate(from, to: d.join(base: toDir, name: baseName(from)), verb: "Move")
    }

    /// Renames/moves on the desktop without overwriting, and keeps open
    /// editors pointing at the moved file(s).
    func relocate(_ from: String, to: String, verb: String = "Rename") async {
        guard let d = desktop, from != to else { return }
        do {
            if try await d.stat(path: to).exists {
                alert = "A file or folder named '\(baseName(to))' already exists in \(baseName(parentDir(to)))."
                return
            }
            try await d.rename(from: from, to: to)
            for i in files.indices where isWithin(files[i].path, from) {
                let old = files[i].path
                let moved = to + old.dropFirst(from.count)
                for g in groups.indices {
                    groups[g].tabs = groups[g].tabs.map { $0 == old ? moved : $0 }
                    if groups[g].active == old { groups[g].active = moved }
                }
                if let b = blobs.removeValue(forKey: old) { blobs[moved] = b }
                files[i] = files[i].moved(to: moved)
                languages.closed(old)
                languages.opened(moved)
            }
            explorerGeneration += 1
        } catch {
            alert = "\(verb) failed: \(error.userMessage)"
        }
    }

    func relative(_ path: String) -> String {
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    }

    func absolute(_ rel: String) -> String {
        desktop?.join(base: root, name: rel) ?? rel
    }

    // MARK: Terminals

    /// A new shell. One you asked for gets the keyboard; one started for a
    /// command (Run, tasks, installs) doesn't, as in VS Code.
    func newTerminal(cwd: String? = nil, input: String? = nil, title: String? = nil, persistentID: String? = nil, focus: Bool? = nil) {
        let dir = cwd ?? (root.isEmpty ? nil : root)
        let t = TerminalSession(title: title ?? shellName, cwd: dir, persistentID: persistentID)
        t.initialInput = input
        panelTab = .terminal
        terminals.append(t)
        activeTerminal = t.id
        panelOpen = true
        if focus ?? (input == nil && persistentID == nil) { focusTerminal() }
    }

    func killTerminal(_ id: UUID) {
        guard let i = terminals.firstIndex(where: { $0.id == id }) else { return }
        let hadFocus = terminals[i].view.isFirstResponder
        terminals[i].kill()
        terminals.remove(at: i)
        // The neighbor takes over, as in VS Code; the last one closes the panel.
        if activeTerminal == id { activeTerminal = (terminals.indices.contains(i) ? terminals[i] : terminals.last)?.id }
        if terminals.isEmpty && panelTab == .terminal { panelOpen = false }
        if hadFocus { terminals.isEmpty ? focusEditor() : focusTerminal() }
        closeIfEmptyTerminalWindow()
    }

    // MARK: keyboard focus between editor and terminal

    /// The shown terminal has the keyboard.
    var terminalFocused: Bool { terminals.first { $0.id == activeTerminal }?.view.isFirstResponder ?? false }

    /// Showing and hiding parts of the window slides them, briefly.
    static var layoutAnimation: Animation { Motion.layout }

    /// ⌘B: the sidebar slides in and out.
    func toggleSidebar(_ view: SideView = .explorer) {
        withAnimation(Self.layoutAnimation) { side = side == nil ? view : nil }
    }

    /// ⌃`: show the terminal and type into it; from the terminal, hide it and
    /// go back to the editor.
    func toggleTerminal() {
        if panelOpen && panelTab == .terminal && terminalFocused { return hidePanel() }
        withAnimation(Self.layoutAnimation) { panelOpen = true }
        panelTab = .terminal
        if terminals.isEmpty { newTerminal() } else { focusTerminal() }
    }

    /// ⌘J, as in VS Code: opening the panel puts the keyboard in it.
    func togglePanel() {
        if panelOpen { return hidePanel() }
        withAnimation(Self.layoutAnimation) { panelOpen = true }
        if panelTab == .terminal { terminals.isEmpty ? newTerminal() : focusTerminal() }
    }

    func hidePanel() {
        let hadFocus = terminalFocused
        withAnimation(Self.layoutAnimation) { panelOpen = false }
        if hadFocus { focusEditor() }
    }

    func focusTerminal(_ id: UUID? = nil) {
        if let id { activeTerminal = id }
        terminals.first { $0.id == activeTerminal }?.unread = false
        guard let v = terminals.first(where: { $0.id == activeTerminal })?.view else { return }
        if v.window != nil { _ = v.becomeFirstResponder(); return }
        // Just opened: its view joins the window on the next layout pass.
        (v as? PadTerminalView)?.focusOnAttach = true
    }

    func focusEditor() { _ = languages.activeView?.becomeFirstResponder() }

    var shellName: String {
        switch env?.os {
        case .windows: "pwsh"
        case .mac: "zsh"
        default: "bash"
        }
    }

    var osLabel: String {
        switch env?.os {
        case .mac: "macOS"
        case .linux: "Linux"
        case .windows: "Windows"
        case nil: ""
        }
    }
}

/// UniFFI exports `connect`, which collides with SwiftUI names in some scopes.
func padcoreConnect(token: String, machine: MachineInfo) async throws -> Desktop {
    try await connect(token: token, machine: machine)
}

struct WeakWorkbench { weak var wb: Workbench? }
