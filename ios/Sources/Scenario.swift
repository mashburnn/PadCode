import Foundation
import Runestone
import UIKit

/// Hands-off end-to-end test, driven from the Mac:
///   xcrun devicectl device process launch --console --terminate-existing \
///     -e '{"PADCODE_SCENARIO":"all"}' --device <udid> com.mashburnkansana.padcode
/// It drives the real UI on a real desktop, prints `PASS`/`FAIL` lines, and
/// prints `SHOT <name>` before pausing so the Mac can take a screenshot.
/// Inert unless the variable is set.
// ponytail: lives in release builds (two env lookups when off); compile it out if that ever matters.
@MainActor
enum Scenario {
    private static let raw = ProcessInfo.processInfo.environment["PADCODE_SCENARIO"] ?? simulatorRequest()
    /// `ssh=user@host:port;steps` runs the steps over SSH instead of a tunnel.
    static let sshTarget: String? = raw.flatMap { $0.hasPrefix("ssh=") ? String($0.dropFirst(4).prefix { $0 != ";" }) : nil }
    /// `local;steps` runs them on Linux inside PadCode.
    static let localTarget = raw?.hasPrefix("local;") ?? false
    static let requested: String? = raw.map {
        sshTarget == nil && !localTarget ? $0 : String($0.split(separator: ";", maxSplits: 1).dropFirst().first ?? "")
    }

    /// The saved host for `user@host:port`, added on first use.
    static func sshHost(_ target: String) -> SSHHost {
        let (user, rest) = target.split(separator: "@", maxSplits: 1).map(String.init).splat
        let (host, port) = rest.split(separator: ":", maxSplits: 1).map(String.init).splat
        if let h = SSHHosts.shared.hosts.first(where: { $0.user == user && $0.host == host && $0.port == UInt16(port) ?? 22 }) { return h }
        let h = SSHHost(name: host == "127.0.0.1" ? "Test sshd" : host, host: host, port: UInt16(port) ?? 22, user: user)
        SSHHosts.shared.save(h)
        return h
    }

    /// The Simulator sometimes stops passing SIMCTL_CHILD_ variables to the app,
    /// so run-scenario.sh also leaves the steps in a one-shot file in the container.
    private static func simulatorRequest() -> String? {
        #if targetEnvironment(simulator)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("padcode-scenario")
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }
    static var started = false
    static var failures = 0
    /// Keeps auto-save from writing a test's deliberately unsaved edit (this process only).
    static var holdAutoSave = false
    /// Time spent in PadCode's own keystroke handler (perf test).
    static var handlerTime: Double = 0

    static var folder: String? { ProcessInfo.processInfo.environment["PADCODE_FOLDER"] }
    static var machineName: String? { ProcessInfo.processInfo.environment["PADCODE_MACHINE"] }

    static func log(_ s: String) {
        print("[scenario] \(s)")
        fflush(stdout)
        #if targetEnvironment(simulator)
        // simctl doesn't always forward stdout either; run-scenario.sh tails this.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("padcode-scenario.log")
        let line = Data("[scenario] \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
        #endif
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    static func shot(_ name: String, wait: Double = 3) async {
        #if targetEnvironment(simulator)
        // The iPadOS 27 Simulator's backboardd can crash (Metal assert) if it's
        // captured mid-animation, e.g. while a new window opens.
        try? await Task.sleep(for: .seconds(1.5))
        #endif
        log("SHOT \(name)")
        try? await Task.sleep(for: .seconds(wait))
    }

    /// Polls until `cond` holds or `timeout` passes. Checks every 200 ms; pass
    /// `every` for timing measurements, which a 200 ms poll would round up.
    static func until(_ timeout: Double, every: Duration = .milliseconds(200), _ cond: () -> Bool) async -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if cond() { return true }
            try? await Task.sleep(for: every)
        }
        return cond()
    }

    /// Milliseconds until `cond` holds (polled every millisecond), or nil.
    static func timed(_ timeout: Double = 3, _ cond: () -> Bool) async -> Double? {
        let t0 = CACurrentMediaTime()
        return await until(timeout, every: .milliseconds(1), cond) ? (CACurrentMediaTime() - t0) * 1000 : nil
    }

    /// Mode "widget": the widget's own checks agree with the app's listing.
    static func widgetEntry() async -> MachinesEntry {
        let e = await MachineStatus.load()
        check("widget.shared-data", WidgetData.read()?.token == Account.shared.token, "token in the shared keychain group")
        let tunnels = Set(e.machines.filter { $0.kind == .tunnel }.map { "\($0.id) \($0.online)" })
        check("widget.tunnels", tunnels == Set(Account.shared.machines.map { "\($0.id) \($0.online)" }),
              "\(tunnels.count) tunnels, \(e.machines.filter { $0.kind == .tunnel && $0.online }.count) online")
        check("widget.ssh", Set(e.machines.filter { $0.kind == .ssh }.map(\.id)) == Set(SSHHosts.shared.hosts.map(\.machine.id)),
              e.machines.filter { $0.kind == .ssh }.map { "\($0.name) \($0.online ? "up" : "down")" }.joined(separator: ", "))
        check("widget.local", e.machines.contains { $0.kind == .local })
        return e
    }

    /// Mode "widget": a row's link opens that machine; again brings the same
    /// window back; an unknown id opens nothing.
    static func widgetLinks() async {
        func windows(_ id: String? = nil) -> Int {
            Set(Workbench.live.compactMap(\.wb).filter { $0.scene != nil && (id == nil || $0.machine.id == id) }.map(ObjectIdentifier.init)).count
        }
        guard let m = Account.shared.machines.first(where: \.online) ?? SSHHosts.shared.hosts.first?.machine else {
            return check("widget.open-url", false, "no machine to open")
        }
        await UIApplication.shared.open(WidgetMachine.url(for: m.id))
        check("widget.open-url", await until(10) { windows(m.id) == 1 }, m.name)
        await shot("widget-opened")
        await UIApplication.shared.open(WidgetMachine.url(for: m.id))
        try? await Task.sleep(for: .seconds(3))
        check("widget.same-window", windows(m.id) == 1, "\(windows(m.id)) windows for \(m.name)")
        let total = windows()
        await UIApplication.shared.open(URL(string: "padcode://open?machine=nope")!)
        try? await Task.sleep(for: .seconds(2))
        check("widget.ignores-unknown", windows() == total)
    }

    static func wants(_ step: String) -> Bool {
        guard let r = requested else { return false }
        if r == "all" { return step != "switchloop" } // a profiling loop, only on request
        return r.split(separator: ",").contains(Substring(step))
    }

    private static var openedSSHWindow = false

    static func run(_ wb: Workbench) async {
        guard requested != nil, !started else { return }
        if requested == "home" || requested == "widget" {
            // Home-page modes: they run in a home window. Only restored
            // workbench windows came up, so open one.
            guard !openedSSHWindow else { return }
            openedSSHWindow = true
            _ = await until(5) { wb.openWindowAction != nil }
            return wb.openWindowAction?(id: "machines") ?? ()
        }
        if let target = localTarget ? LocalLinux.machine : sshTarget.map({ sshHost($0).machine }) {
            guard wb.machine.id == target.id else {
                // A window restored on another desktop (the user's): never test there.
                // Open the SSH host's own window instead; its run does the test.
                guard !openedSSHWindow else { return }
                openedSSHWindow = true
                log("SSHKEY \(SSHKey.publicKey)")
                _ = await until(5) { wb.openWindowAction != nil }
                wb.openWindowAction?(id: "workbench", value: WorkbenchTarget(machine: target))
                return
            }
        }
        started = true
        setvbuf(stdout, nil, _IOLBF, 0)
        log("START \(requested!) on \(wb.machine.name)")
        if wb.machine.isSSH, await until(20, { wb.trustPrompt != nil || wb.desktop != nil || wb.connectError != nil }),
           let fp = wb.trustPrompt {
            // First connection: accept the host key the way the button does.
            check("ssh.trust-prompt", fp.hasPrefix("SHA256:"), fp)
            await shot("ssh-trust")
            wb.trustHostKey()
            check("ssh.trust-saved", SSHHosts.shared.host(for: wb.machine)?.fingerprint == fp)
        }
        guard await until(30, { wb.desktop != nil }), let d = wb.desktop, let env = wb.env else {
            check("connect", false, wb.connectError ?? "timeout")
            return log("DONE failures=\(failures + 1)")
        }
        check("connect", true, "\(env.os) \(env.cliVersion)")
        let root = folder ?? d.join(base: d.join(base: env.home, name: "Desktop"), name: "padcode-test")
        // Known file contents every run: earlier runs (or auto-save) may have changed them.
        holdAutoSave = true
        try? await d.mkdirp(path: d.join(base: root, name: "src")) // a fresh machine (Linux on the iPad)
        for (name, text) in fixtures where !wants("session-check") {
            try? await d.writeFile(path: d.join(base: root, name: name), data: Data(text.utf8))
        }
        // Files the Mac's test folder has by hand; a fresh machine gets them once.
        let seeds = ["hello.py": "def greet(who):\n    # TODO: find me with search\n    return f\"hi {who}\"\n\nprint(greet(\"ipad\"))\n",
                     "crlf.txt": "line one\r\nline two\r\nTODO: windows line endings\r\n",
                     "Cargo.toml": "[package]\nname = \"padcode-test\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n"]
        for (name, text) in seeds where (try? await d.stat(path: d.join(base: root, name: name)))?.exists != true {
            try? await d.writeFile(path: d.join(base: root, name: name), data: Data(text.utf8))
        }
        if (try? await d.stat(path: d.join(base: root, name: "big.log")))?.exists != true {
            let lines = (1...3000).map { "\($0) INFO request handled in \($0 % 97) ms path=/api/items/\($0)" }
            try? await d.writeFile(path: d.join(base: root, name: "big.log"), data: Data(lines.joined(separator: "\n").utf8))
        }
        wb.openFolder(root)
        _ = await until(10) { wb.restoredSession }
        if !wants("session-check") { reset(wb) } // start clean, not from a saved session
        await shot("folder")
        func p(_ name: String) -> String { d.join(base: root, name: name) }

        if wants("perf") { await perf(wb, p("big.log")) }
        if wants("render") { await render(wb, p("messy.c"), p("point.c")) }
        if wants("lsp") { await lsp(wb, p("point.c")) }
        if wants("rust") { await rust(wb, p("src/main.rs")) }
        if wants("python") { await python(wb, p("hello.py")) }
        if wants("format") { await format(wb, p("messy.c")) }
        if wants("nav") { await navigation(wb, p("point.c")) }
        if wants("split") { await split(wb, p("README.md"), p("point.c")) }
        if wants("viewers") { await viewers(wb, p("logo.jpg"), p("doc.pdf")) }
        if wants("search") { await search(wb, d, root) }
        if wants("files") { await files(wb, d, root, p("point.c")) }
        if wants("settings") { await settings(wb) }
        if wants("panel") { await panel(wb) }
        if wants("run") { await runTasks(wb, p("hello.py")) }
        if wants("ports") { await ports(wb, d) }
        if wants("lsp2") { await lsp2(wb, p("point.c")) }
        if wants("lines") { await lines(wb, p("point.c")) }
        if wants("bigline") { await bigLine(wb, d, root) }
        if wants("history") { await history(wb, p("point.c"), p("messy.c")) }
        if wants("autosave") { await autosave(wb, d, root) }
        if wants("terminal-persist") { await terminalPersist(wb, d, root) }
        if wants("resume") { await resume(wb, d, root) }
        if wants("lease") { await lease(wb, p("point.c")) }
        if wants("resize") { await resize(wb, p("big.log")) }
        if wants("hover") { await hover(wb, p("point.c"), p("README.md")) }
        if wants("terminal-select") { await terminalSelect(wb) }
        if wants("pointer") { await pointer(wb, p("point.c")) }
        if wants("wheel") { await wheel(wb, d, root) }
        if wants("reattach-modes") { await reattachModes(wb, d, root) }
        if wants("focus") { await focus(wb, d, root, p("point.c")) }
        if wants("appearance") { // the light/dark reveal, caught mid-way
            _ = await open(wb, p("point.c"))
            let dark = UserDefaults.standard.bool(forKey: "homeDark")
            Appearance.duration = 6
            Appearance.flip(in: wb.scene) { UserDefaults.standard.set(!dark, forKey: "homeDark") }
            await shot("flip-mid", wait: 1.5)
            await shot("flip-end", wait: 6)
            Appearance.flip(in: wb.scene) { UserDefaults.standard.set(dark, forKey: "homeDark") }
            await shot("flip-back-mid", wait: 1.5)
            await shot("flip-back-end", wait: 6)
            Appearance.duration = 0.5
        }
        if wants("terminal-window") { await terminalWindow(wb, d, root) }
        if wants("anim") { await animations(wb, p("big.log")) }
        if wants("visuals") { await visuals(wb, d, root) }
        if wants("layout") { await layoutModes(wb, p("point.c"), p("hello.py"), p("README.md")) }
        if wants("security") { security(wb) }
        if wants("switchloop") {
            // For a profiler: 40 s of tab switches.
            let fs = ["big.log", "point.c", "messy.c", "src/main.rs", "README.md"].map(p)
            for f in fs { await wb.open(f) }
            try? await Task.sleep(for: .seconds(3))
            log("switchloop: go")
            let end = Date.now.addingTimeInterval(40)
            while Date.now < end {
                for f in fs { wb.focus(f, in: wb.focusedGroup); try? await Task.sleep(for: .milliseconds(150)) }
            }
            log("switchloop: done")
        }
        if wants("termperf") { await termPerf(wb, d, root) }
        if wants("snappy") { await snappy(wb, d, root, ["big.log", "point.c", "messy.c", "src/main.rs", "README.md"].map(p)) }
        if wants("session-setup") { await sessionSetup(wb, d, p("point.c"), p("session-test.txt")) }
        if wants("session-check") { await sessionCheck(wb, d, p("point.c"), p("session-test.txt")) }

        if wants("session-setup") { return log("DONE failures=\(failures)") } // keep the tabs for the next launch
        reset(wb)
        await shot("end", wait: 1)
        log("DONE failures=\(failures)")
    }

    static func reset(_ wb: Workbench) {
        for t in wb.terminals.dropFirst() { wb.killTerminal(t.id) } // test shells are persistent now
        for f in wb.files.map(\.path) { wb.closeEverywhere(f) }
        while wb.groups.count > 1 { wb.closeGroup(wb.groups.count - 1) }
        wb.side = .explorer
        wb.panelTab = .terminal
        wb.symbolPicker = false
        wb.gotoLine = false
        wb.settingsOpen = false
        wb.languages.completion = nil
        wb.languages.hover = nil
    }

    // MARK: steps

    /// Opens a file and waits for its editor view.
    static func open(_ wb: Workbench, _ path: String) async -> TextView? {
        await wb.open(path)
        guard await until(10, { wb.languages.activePath == path && wb.languages.activeView != nil }) else { return nil }
        return wb.languages.activeView
    }

    static func caret(_ tv: TextView, after needle: String, plus: Int = 0) {
        let r = (tv.text as NSString).range(of: needle)
        guard r.location != NSNotFound else { return }
        tv.selectedRange = NSRange(location: r.location + plus, length: 0)
    }

    static func lsp(_ wb: Workbench, _ path: String) async {
        guard let tv = await open(wb, path) else { return check("lsp.open", false) }
        let diag = await until(30) { !(wb.languages.diagnostics[path] ?? []).isEmpty }
        check("lsp.diagnostics", diag, (wb.languages.diagnostics[path] ?? []).first?.message ?? "none")
        await shot("diagnostics")

        caret(tv, after: "p.x", plus: 2)
        wb.languages.requestCompletion(tv, path: path)
        let comp = await until(15) { wb.languages.completion != nil }
        let labels = wb.languages.completion?.visible.map(\.filterText) ?? []
        check("lsp.completion", comp && labels.contains("x") && labels.contains("y"), labels.prefix(5).joined(separator: ","))
        await shot("completion")
        wb.languages.completion = nil

        caret(tv, after: "p.x")
        wb.languages.showHover()
        let hov = await until(10) { wb.languages.hover != nil }
        check("lsp.hover", hov && (wb.languages.hover?.text.contains("point") ?? false), String((wb.languages.hover?.text ?? "").prefix(60)))
        await shot("hover")
        wb.languages.hover = nil

        caret(tv, after: "p.x")
        wb.languages.goToDefinition()
        let def = await until(10) { wb.activeFile?.cursor.line == 6 }
        check("lsp.definition", def, "cursor line \(wb.activeFile?.cursor.line ?? -1)")
        wb.panelTab = .problems
        wb.panelOpen = true
        await shot("problems")
        wb.panelTab = .terminal
    }

    /// Reopening a file while the sidebar switches used to leave stale,
    /// half-drawn lines. Screenshots over time show whether it settles.
    static func render(_ wb: Workbench, _ a: String, _ b: String) async {
        await wb.open(b)
        await wb.open(a)
        wb.closeEverywhere(a)
        wb.side = .outline
        _ = await open(wb, b)
        await shot("render-1s", wait: 0)
        try? await Task.sleep(for: .seconds(1))
        await shot("render-2s", wait: 3)
        await shot("render-5s", wait: 0)
        let tv = wb.languages.activeView
        check("render.text", tv?.text == wb.file(b)?.text, "\(tv?.text.count ?? -1) chars, bounds \(Int(tv?.bounds.width ?? 0))")
        wb.side = .explorer
    }

    static func rust(_ wb: Workbench, _ path: String) async {
        guard await open(wb, path) != nil else { return check("rust.open", false) }
        let ok = await until(90) { (wb.languages.diagnostics[path] ?? []).contains { $0.severity == 1 } }
        check("rust.diagnostics", ok, (wb.languages.diagnostics[path] ?? []).first?.message ?? wb.languages.progress(for: path) ?? "none")
        await shot("rust")
    }

    static func python(_ wb: Workbench, _ path: String) async {
        guard await open(wb, path) != nil else { return check("python.open", false) }
        let ok = await until(30) { wb.languages.missing["python"] != nil || wb.languages.serverName(for: path) != nil }
        check("python.server-or-missing", ok, wb.languages.serverName(for: path) ?? wb.languages.missing["python"]?.install ?? "")
        await shot("python")
    }

    static func format(_ wb: Workbench, _ path: String) async {
        guard await open(wb, path) != nil else { return check("format.open", false) }
        _ = await until(15) { wb.languages.canFormat(path) }
        let before = wb.file(path)?.text ?? ""
        await wb.languages.format(path)
        let after = wb.file(path)?.text ?? ""
        check("format.document", after != before && after.contains("struct point {"), "\(before.count) -> \(after.count) chars")
        await shot("formatted")
        wb.closeEverywhere(path) // discard, keep the test file messy
    }

    static func navigation(_ wb: Workbench, _ path: String) async {
        guard await open(wb, path) != nil else { return check("nav.open", false) }
        wb.side = .outline
        let syms = await until(20) { (wb.languages.serverName(for: path) != nil) }
        let list = await wb.languages.symbols(path) ?? []
        check("nav.outline", syms && list.contains { $0.name == "main" }, list.map(\.name).joined(separator: ","))
        await shot("outline")
        wb.symbolPicker = true
        await shot("symbol-picker")
        wb.symbolPicker = false
        // Workspace symbols: clangd knows `point` (point.c is open) without opening anything else.
        var found: [WorkspaceSymbol] = []
        for _ in 0..<20 where !found.contains(where: { $0.name == "point" }) { // clangd indexes in the background
            found = await wb.languages.workspaceSymbols("point")
            if !found.contains(where: { $0.name == "point" }) { try? await Task.sleep(for: .seconds(1)) }
        }
        check("nav.workspace-symbols", found.first?.name == "point", found.prefix(5).map { "\($0.name)@\(wb.relative($0.path)):\($0.selection.start.line + 1)" }.joined(separator: ","))
        wb.workspaceSymbolPicker = true
        await shot("workspace-symbols")
        wb.workspaceSymbolPicker = false
        wb.gotoLine = true
        await shot("goto-line")
        wb.gotoLine = false
        await wb.open(path, line: 8)
        let moved = await until(5) { wb.activeFile?.cursor.line == 8 }
        check("nav.goto-line", moved, "line \(wb.activeFile?.cursor.line ?? -1)")
        wb.side = .explorer
    }

    static func split(_ wb: Workbench, _ md: String, _ other: String) async {
        await wb.open(other)
        await wb.open(md)
        wb.splitRight()
        check("split.groups", wb.groups.count == 2 && wb.groups[1].active == md, "\(wb.groups.map(\.tabs))")
        await wb.openToSide(other)
        await shot("split")
        wb.focus(md, in: 0)
        wb.openMarkdownPreview(md)
        let pv = MarkdownPreview.previewPath(for: md)
        check("markdown.preview", wb.groups.contains { $0.active == pv })
        check("markdown.preview-name", wb.file(pv)?.name == "README.md", wb.file(pv)?.name ?? "nil")
        await shot("markdown-preview", wait: 4)
        // Edits flow into the preview.
        if let text = wb.file(md)?.text { wb.setText(md, text + "\n## Live edit\n") }
        await shot("markdown-live")
        wb.closeEverywhere(md)
        check("markdown.preview-closes-with-source", !wb.files.contains { $0.path == pv })
        while wb.groups.count > 1 { wb.closeGroup(1) }
    }

    static func viewers(_ wb: Workbench, _ image: String, _ pdf: String) async {
        await wb.open(image)
        check("viewer.image", wb.activeFile?.viewer == .image && (wb.blobs[image]?.count ?? 0) > 0)
        await shot("image")
        await wb.open(pdf)
        check("viewer.pdf", wb.activeFile?.viewer == .pdf)
        await shot("pdf")
    }

    static func search(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        wb.side = .search
        let plain = (try? await d.search(root: root, query: "TODO", max: 100, matchCase: false, wholeWord: false, regex: false)) ?? []
        check("search.plain", Set(plain.map(\.path)).isSuperset(of: ["hello.py", "crlf.txt"]), plain.map(\.path).joined(separator: ","))
        let rx = (try? await d.search(root: root, query: "miss[a-z_]+value", max: 100, matchCase: true, wholeWord: false, regex: true)) ?? []
        check("search.regex", rx.contains { $0.path == "point.c" }, "\(rx.count) hits")
        let cs = (try? await d.search(root: root, query: "todo", max: 100, matchCase: true, wholeWord: false, regex: false)) ?? []
        check("search.match-case", cs.isEmpty, "\(cs.count) hits")
        let ww = (try? await d.search(root: root, query: "poin", max: 100, matchCase: false, wholeWord: true, regex: false)) ?? []
        check("search.whole-word", ww.isEmpty, "\(ww.count) hits")
        let re = try! NSRegularExpression(pattern: "\\bfoo\\b", options: [.caseInsensitive])
        let (out, n) = SearchReplace.apply("foo food\nFOO\nfoo", lines: [1, 2], pattern: re, template: "bar")
        check("replace.logic", out == "bar food\nbar\nfoo" && n == 2, out.replacingOccurrences(of: "\n", with: "⏎"))
        wb.replaceMode = true
        await shot("search")
        wb.replaceMode = false
        wb.side = .explorer
    }

    static func files(_ wb: Workbench, _ d: Desktop, _ root: String, _ some: String) async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("padcode-upload-test.txt")
        try? "uploaded from the iPad\n".write(to: tmp, atomically: true, encoding: .utf8)
        await wb.upload([tmp], to: root)
        let target = d.join(base: root, name: "padcode-upload-test.txt")
        let exists = (try? await d.stat(path: target).exists) ?? false
        check("files.upload", exists)
        await shot("uploaded", wait: 2)
        do {
            try await d.remove(path: target)
            check("files.delete-file", !((try? await d.stat(path: target).exists) ?? true))
        } catch {
            check("files.delete-file", false, error.userMessage)
        }
        let dir = d.join(base: root, name: "padcode-delete-dir-test")
        try? await d.mkdirp(path: d.join(base: dir, name: "inner"))
        try? await d.remove(path: dir)
        check("files.delete-folder", !((try? await d.stat(path: dir).exists) ?? true))
        let leftovers = ((try? await d.listDir(path: root)) ?? []).filter { $0.name.hasPrefix(".padcode-delete-") }
        check("files.delete-no-leftovers", leftovers.isEmpty)
        wb.explorerGeneration += 1

        let t0 = Date.now
        let missing = try? await d.readFile(path: d.join(base: root, name: "does-not-exist.txt"))
        check("files.read-missing-fails-fast", missing == nil && Date.now.timeIntervalSince(t0) < 3,
              String(format: "%.2fs", Date.now.timeIntervalSince(t0)))

        // New File never overwrites; nested names create their folders.
        let keep = d.join(base: root, name: "keep.txt")
        try? await d.writeFile(path: keep, data: Data("precious".utf8))
        await wb.createItem("keep.txt", in: root, isDir: false, desktop: d)
        let kept = (try? await d.readFile(path: keep)).map { String(decoding: $0, as: UTF8.self) }
        wb.alert = nil
        await wb.createItem("nest/deep/new.txt", in: root, isDir: false, desktop: d)
        let nested = (try? await d.stat(path: d.join(base: root, name: "nest/deep/new.txt")))?.exists == true
        check("files.new-file", kept == "precious" && nested, "kept=\(kept ?? "nil") nested=\(nested)")
        wb.closeEverywhere(d.join(base: d.join(base: d.join(base: root, name: "nest"), name: "deep"), name: "new.txt"))
        try? await d.remove(path: keep)
        try? await d.remove(path: d.join(base: root, name: "nest"))

        // A binary that happens to be valid UTF-8 (NUL bytes) isn't opened as text.
        let bin = d.join(base: root, name: "nul.bin")
        try? await d.writeFile(path: bin, data: Data([0x7f, 0x45, 0x4c, 0x46, 0, 0, 1, 0]))
        let opened = await wb.load(bin, quiet: true)
        check("files.binary-refused", !opened && wb.file(bin) == nil)
        try? await d.remove(path: bin)

        wb.download(some)
        let dl = await until(10) { wb.exportURL != nil }
        check("files.download", dl && (try? Data(contentsOf: wb.exportURL!))?.isEmpty == false)
        await shot("share-sheet", wait: 3)
        wb.exportURL = nil
    }

    static func settings(_ wb: Workbench) async {
        wb.settingsOpen = true
        await shot("settings", wait: 4)
        wb.settingsOpen = false
        let s = AppSettings.shared
        let wrap = s.wordWrap
        s.wordWrap = true
        check("settings.persist", UserDefaults.standard.bool(forKey: "wordWrap"))
        s.wordWrap = wrap
        check("settings.cleanup", s.cleanUpForTest("a  \nb\t\nc") == "a\nb\nc\n")
    }

    static func panel(_ wb: Workbench) async {
        wb.newTerminal(input: "echo padcode-scenario-ok\r")
        await shot("terminal", wait: 3)
    }

    static let fixtures: [String: String] = [
        "point.c": "#include <stdio.h>\n\nstruct point { int x; int y; };\n\nint main(void) {\n    struct point p = {1, 2};\n    printf(\"%d\\n\", p.x + p.y);\n    return missing_value;\n}\n",
        "messy.c": "#include <stdio.h>\nstruct   point{int x;int y;};\nint add(int a,int b){return a+b;}\nint main(void){struct point p={1,2};printf(\"%d\\n\",add(p.x,p.y));return 0;}\n",
        "src/main.rs": "fn main() {\n    let name = \"PadCode\";\n    let words: Vec<&str> = name.split(\"C\").collect();\n    println!(\"hello from {name} {}\", words.len());\n    let oops: i32 = \"not a number\";\n}\n",
        "README.md": "# PadCode test\n\nEdit me, save with **Cmd+S**, then `cat README.md` in the terminal.\n\n## Preview\n\n- Open the preview with the icon at the top right of the tab bar\n- It updates as you type\n\n| Feature | Shortcut |\n| ------- | -------- |\n| Split editor | ⌘\\\\ |\n| Go to line | ⌃G |\n| Go to symbol | ⇧⌘O |\n\n```rust\nfn main() { println!(\"hello\"); }\n```\n",
    ]

    /// Typing cost: 200 keystrokes into a 3,000-line file, letting SwiftUI
    /// render between each (the sleep is subtracted).
    static func perf(_ wb: Workbench, _ path: String) async {
        guard let tv = await open(wb, path) else { return check("perf.open", false) }
        tv.selectedRange = NSRange(location: (tv.text as NSString).length / 2, length: 0)
        let n = 200
        let pause = 0.004
        // Baseline: the same loop without typing, so Task.sleep's own overshoot isn't counted.
        let b0 = Date.now
        for _ in 0..<n { try? await Task.sleep(for: .seconds(pause)) }
        let idle = Date.now.timeIntervalSince(b0)
        handlerTime = 0
        let t0 = Date.now
        // Type the way the hardware keyboard does: UIKit calls insertText on the
        // first responder (Runestone's inner text-input view). TextView.insertText
        // adds selectionDidChange round trips through UIKit's keyboard machinery.
        guard let input = tv.subviews.lazy.compactMap({ $0 as? UIKeyInput }).first else {
            return check("perf.typing", false, "no text input view")
        }
        var insert = 0.0
        for _ in 0..<n {
            let i0 = CACurrentMediaTime()
            input.insertText("x")
            insert += CACurrentMediaTime() - i0
            try? await Task.sleep(for: .seconds(pause))
        }
        let per = (Date.now.timeIntervalSince(t0) - idle) / Double(n) * 1000
        let ours = handlerTime / Double(n) * 1000
        let editor = insert / Double(n) * 1000
        // One 120 Hz frame on the iPad. The Simulator measures ~2 ms; ~11 meant
        // UIKit's keyboard bookkeeping was running on every layout pass again
        // (vendor/Runestone/PADCODE.md).
        #if targetEnvironment(simulator)
        let budget = 5.0
        #else
        let budget = 8.0
        #endif
        check("perf.typing", per < budget, String(format: "%.2f ms/keystroke: %.2f in the editor's insert, the rest layout/render (budget %.0f ms)", per, editor, budget))
        check("perf.handler", ours < 1, String(format: "%.2f ms/keystroke in PadCode's own handler (budget 1 ms)", ours))
        wb.closeEverywhere(path)
    }

    static func lines(_ wb: Workbench, _ path: String) async {
        func run(_ e: LineEdit, _ text: String, _ loc: Int, _ len: Int = 0, _ name: String = "a.c") -> String {
            let s = text as NSString
            guard let r = e.apply(to: s, selection: NSRange(location: loc, length: len), fileName: name) else { return text }
            return s.replacingCharacters(in: r.range, with: r.text) + "@\(r.selection.location),\(r.selection.length)"
        }
        let cases: [(String, String, String)] = [
            ("comment", run(.toggleComment, "int x;\n  y();\n", 2), "// int x;\n  y();\n@5,0"),
            ("uncomment", run(.toggleComment, "// int x;\n", 5), "int x;\n@2,0"),
            ("comment-block", run(.toggleComment, "  a\n    b\n\nc", 0, 9), "  // a\n  //   b\n\nc@0,15"),
            ("python", run(.toggleComment, "x = 1", 0, 0, "a.py"), "# x = 1@2,0"),
            ("html", run(.toggleComment, "  <b>hi</b>", 4, 0, "a.html"), "  <!-- <b>hi</b> -->@4,0"),
            ("delete-last", run(.deleteLines, "a\nb\nc", 4), "a\nb@3,0"),
            ("copy-down", run(.copyLines(down: true), "ab\ncd\n", 1, 3), "ab\ncd\nab\ncd\n@7,3"),
            ("insert-below", run(.insertLine(below: true), "  ab\ncd", 2), "  ab\n  \ncd@7,0"),
        ]
        let bad = cases.filter { $0.1 != $0.2 }.map(\.0)
        check("lines.transforms", bad.isEmpty, bad.isEmpty ? "\(cases.count) cases" : bad.joined(separator: ","))
        let links = [("src/main.rs:12:5", "src/main.rs 12 5"), ("/a/b.py:3", "/a/b.py 3 -"), ("./x.c:", "./x.c - -"),
                     ("file:///a/b%20c.txt", "/a/b c.txt - -"), ("https://x.dev/a:1", "nil"), ("mailto:a@b", "nil")]
            .filter { link, want in
                let got = TerminalSession.fileLink(link).map { "\($0.path) \($0.line.map(String.init) ?? "-") \($0.column.map(String.init) ?? "-")" } ?? "nil"
                return got != want
            }
        check("terminal.file-links", links.isEmpty, links.map(\.0).joined(separator: ","))
        let t = TerminalSession(title: "links", cwd: wb.root)
        t.workbench = wb
        t.openLink("./point.c:6:3")
        let opened = await until(3) { wb.active == path && wb.file(path)?.cursor.line == 6 }
        check("terminal.file-link-opens", opened, "\(wb.active ?? "nil") line \(wb.file(path)?.cursor.line ?? 0)")

        // In the editor: ⌘/ is one undoable edit that marks the file dirty.
        guard let tv = await open(wb, path) as? PadTextView else { return check("lines.editor", false, "no editor") }
        let before = tv.text
        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.toggleComment()
        let commented = tv.text.hasPrefix("// ") && wb.file(path)?.text == tv.text
        tv.undoManager?.undo()
        check("lines.editor", commented && tv.text == before, String(tv.text.prefix(20)).replacingOccurrences(of: "\n", with: "⏎"))

        // Caret after "{" of the struct: it and its "}" are highlighted.
        let open = (tv.text as NSString).range(of: "point {").location + 7
        tv.selectedRange = NSRange(location: open, length: 0)
        let close = (tv.text as NSString).range(of: "};").location
        var marks: Set<Int> = []
        _ = await until(2) { // Runestone reports selection changes on its next layout
            marks = Set(tv.highlightedRanges.filter { $0.id.hasPrefix("bracket") }.map(\.range.location))
            return marks == [open - 1, close]
        }
        check("lines.bracket-match", marks == [open - 1, close], "\(marks.sorted()) want \([open - 1, close])")
        // Caret in `point` (the struct name): its other use is highlighted too.
        tv.selectedRange = NSRange(location: (tv.text as NSString).range(of: "point").location + 2, length: 0)
        var words = 0
        _ = await until(2) { words = tv.highlightedRanges.filter { $0.id.hasPrefix("word") }.count; return words == 2 }
        check("lines.occurrences", words == 2, "\(words) highlighted, want 2 (struct point, struct point p)")
        wb.closeEverywhere(path)
    }

    /// A minified file (one 1.5 MB line) opens, scrolls and types without a hang.
    static func bigLine(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        let path = d.join(base: root, name: "minified.js")
        let line = (0..<40_000).map { "var v\($0)={a:[1,2,3],b:'x'};" }.joined()
        try? await d.writeFile(path: path, data: Data((line + "\n").utf8))
        let t0 = Date.now
        guard let tv = await open(wb, path) else { return check("bigline.open", false) }
        let opened = Date.now.timeIntervalSince(t0)
        let t1 = CACurrentMediaTime()
        tv.selectedRange = NSRange(location: 10, length: 0)
        tv.subviews.lazy.compactMap { $0 as? UIKeyInput }.first?.insertText("x")
        tv.layoutIfNeeded()
        let typed = CACurrentMediaTime() - t1
        await shot("bigline", wait: 1)
        check("bigline.open", opened < 5, String(format: "%.2fs to open %d KB on one line", opened, line.utf8.count / 1000))
        check("bigline.type", typed < 0.5, String(format: "%.0f ms for a keystroke", typed * 1000))
        wb.closeEverywhere(path)
        try? await d.remove(path: path)
    }

    static func history(_ wb: Workbench, _ a: String, _ b: String) async {
        await wb.open(a)
        await wb.open(b, line: 3)
        wb.goBack()
        let back = await until(3) { wb.active == a }
        wb.goForward()
        let forward = await until(3) { wb.active == b }
        check("history.back-forward", back && forward, "\(back) \(forward)")
        wb.close(b)
        wb.reopenClosed()
        check("history.reopen-closed", await until(3) { wb.active == b })
        wb.closeEverywhere(a)
        wb.closeEverywhere(b)
    }

    /// Everything PadCode spawns dies with the connection's lease (the VS Code
    /// CLI never kills spawned processes itself).
    static func lease(_ wb: Workbench, _ path: String) async {
        guard wb.env?.os != .windows, let d = wb.desktop else { return check("lease.cleanup", true, "skipped on Windows") }
        await wb.open(path)
        _ = await until(20) { wb.languages.serverName(for: path) != nil }
        func sh(_ c: String) async -> String {
            let out = (try? await d.run(command: "/bin/sh", args: ["-c", c], cwd: nil))?.stdout ?? ""
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lease = await sh("pgrep -n -f padcode-lease")
        // "[&]&" so the pgrep's own shell doesn't match.
        let count = "pgrep -f 'kill -0 \(lease) [&]&' | wc -l"
        let leashed = Int(await sh(count)) ?? 0
        _ = await sh("kill \(lease)")
        var left = leashed
        for _ in 0..<25 where left > 0 {
            try? await Task.sleep(for: .seconds(1))
            left = Int(await sh(count)) ?? -1
        }
        check("lease.cleanup", !lease.isEmpty && leashed >= 2 && left == 0, "lease \(lease): \(leashed) leashed processes, \(left) left")
        wb.closeEverywhere(path)
        await wb.reconnect()
        _ = await until(15) { wb.desktop != nil }
    }

    static func autosave(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        holdAutoSave = false
        defer { holdAutoSave = true }
        let path = d.join(base: root, name: "autosave-test.txt")
        try? await d.writeFile(path: path, data: Data("one\n".utf8))
        await wb.open(path)
        wb.edited(path, text: "one\ntwo\n")
        let saved = await until(6) { wb.file(path)?.dirty == false }
        let disk = (try? await d.readFile(path: path)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("autosave.after-delay", saved && disk == "one\ntwo\n", disk.replacingOccurrences(of: "\n", with: "⏎"))
        // Changed on the desktop while open and unmodified: the editor follows.
        try? await d.writeFile(path: path, data: Data("changed outside\n".utf8))
        let reloaded = await until(8) { wb.file(path)?.text == "changed outside\n" }
        check("reload.external-change", reloaded, wb.file(path)?.text ?? "")
        await shot("reloaded", wait: 1)
        wb.closeEverywhere(path)
        try? await d.remove(path: path)
        // New file on the desktop appears in the Explorer by itself.
        let probe = d.join(base: root, name: "appears-by-itself.txt")
        try? await d.writeFile(path: probe, data: Data())
        await shot("explorer-autorefresh", wait: 5)
        try? await d.remove(path: probe)
    }

    /// A shell must survive the connection dropping: same process before and after.
    static func terminalPersist(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        guard wb.env?.os != .windows else { return check("terminal.persist", true, "skipped on Windows") }
        wb.newTerminal(title: "persist-test")
        guard let t = wb.terminals.last else { return check("terminal.persist", false, "no terminal") }
        let sock = d.join(base: d.join(base: wb.env!.home, name: ".padcode/term"), name: "\(t.persistentID).sock")
        // Not fs_stat: the VS Code CLI panics on sockets (see Rpc::call).
        func sockExists(_ d: Desktop?) async -> Bool {
            ((try? await d?.run(command: "/bin/sh", args: ["-c", "test -S \"$1\"", "sh", sock], cwd: nil))??.code) == 0
        }
        var alive = false
        for _ in 0..<20 where !alive {
            try? await Task.sleep(for: .milliseconds(300))
            alive = await sockExists(d)
        }
        check("terminal.session-daemon", alive, sock)
        let before = d.join(base: root, name: ".pid-before"), after = d.join(base: root, name: ".pid-after")
        t.send("echo $$ > '\(before)'\r")
        try? await Task.sleep(for: .seconds(1))
        await wb.reconnect() // drops the tunnel connection like the iPad sleeping would
        _ = await until(15) { wb.desktop != nil }
        try? await Task.sleep(for: .seconds(2))
        t.send("echo $$ > '\(after)'\r")
        try? await Task.sleep(for: .seconds(1.5))
        let a = (try? await d.readFile(path: before)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        let b = (try? await wb.desktop?.readFile(path: after)).map { String(decoding: $0, as: UTF8.self) } ?? "!"
        check("terminal.persist", a == b && !a.isEmpty, "pid \(a.trimmingCharacters(in: .newlines)) -> \(b.trimmingCharacters(in: .newlines))")
        await shot("terminal-persist", wait: 2)
        try? await wb.desktop?.remove(path: before)
        try? await wb.desktop?.remove(path: after)
        if let id = wb.terminals.last?.id { wb.killTerminal(id) }
        try? await Task.sleep(for: .seconds(1))
        let gone = await !sockExists(wb.desktop)
        check("terminal.kill-ends-session", gone)
    }

    /// Someone else backgrounds PadCode (run-scenario's caller opens another
    /// app on "BACKGROUND-ME", then reopens PadCode): the same shell and files
    /// must work again. A 1 s ticker shows whether iOS really suspended us.
    static func resume(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        wb.newTerminal(title: "resume-test")
        guard let t = wb.terminals.last else { return check("resume", false, "no terminal") }
        let before = d.join(base: root, name: ".pid-before"), after = d.join(base: root, name: ".pid-after")
        try? await Task.sleep(for: .seconds(2))
        t.send("echo $$ > '\(before)'\r")
        try? await Task.sleep(for: .seconds(1))
        func read(_ path: String) async -> String {
            do { return try await String(decoding: wb.desktop!.readFile(path: path), as: UTF8.self).trimmingCharacters(in: .newlines) }
            catch { return "error: \(error)" }
        }
        let pid = await read(before)
        check("resume.read-before", Int(pid) != nil, pid)
        var last = Date.now, gap = 0.0
        let ticker = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); gap = max(gap, -last.timeIntervalSinceNow); last = .now } }
        log("BACKGROUND-ME")
        guard await until(120, { UIApplication.shared.applicationState == .background }) else { ticker.cancel(); return check("resume.backgrounded", false) }
        let left = Date.now
        _ = await until(900) { UIApplication.shared.applicationState == .active }
        ticker.cancel()
        let away = -left.timeIntervalSinceNow
        check("resume.backgrounded", true, String(format: "away %.0f s, longest pause %.0f s (suspended if close to away)", away, gap))
        let back = Date.now
        var ok = false
        for _ in 0..<60 where !ok {
            if let d = wb.desktop, (try? await d.ping()) != nil { ok = true } else { try? await Task.sleep(for: .milliseconds(500)) }
        }
        check("resume.reconnect", ok, String(format: "%.1f s", -back.timeIntervalSinceNow))
        t.send("echo $$ > '\(after)'\r")
        try? await Task.sleep(for: .seconds(1.5))
        let b = await read(after)
        check("resume.same-shell", b == pid, "pid \(pid) -> \(b)")
        await shot("resume", wait: 2)
        try? await wb.desktop?.remove(path: before)
        try? await wb.desktop?.remove(path: after)
        wb.killTerminal(t.id)
    }

    static func sessionSetup(_ wb: Workbench, _ d: Desktop, _ a: String, _ b: String) async {
        holdAutoSave = true // the edit below must stay unsaved
        try? await d.writeFile(path: b, data: Data("start\n".utf8))
        await wb.open(a, line: 7)
        await wb.open(b)
        wb.splitRight()
        wb.focus(a, in: 1)
        wb.focusedGroup = 0
        wb.setText(b, "start\nunsaved-hot-exit-line\n")
        wb.saveSession()
        check("session.saved", wb.restoredSession, "\(wb.groups.map(\.tabs.count))")
        await shot("session-before", wait: 2)
        log("leaving tabs open for session-check")
    }

    static func sessionCheck(_ wb: Workbench, _ d: Desktop, _ a: String, _ b: String) async {
        let ok = await until(10) { wb.groups.count == 2 }
        check("session.groups", ok, "\(wb.groups.map { $0.tabs.map { ($0 as NSString).lastPathComponent } })")
        check("session.hot-exit", wb.file(b)?.text.contains("unsaved-hot-exit-line") == true && wb.file(b)?.dirty == true)
        await shot("session-restored", wait: 3)
        let disk = (try? await d.readFile(path: b)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("session.edit-was-not-saved", disk == "start\n", disk)
        wb.closeEverywhere(b)
        try? await d.remove(path: b)
    }

    static func runTasks(_ wb: Workbench, _ path: String) async {
        let t0 = Date.now
        let tasks = await wb.detectTasks()
        check("tasks.fast", Date.now.timeIntervalSince(t0) < 1.5, String(format: "%.2fs", Date.now.timeIntervalSince(t0)))
        check("tasks.detect", tasks.contains { $0.command == "cargo build" }, tasks.map(\.label).prefix(6).joined(separator: ", "))
        guard await open(wb, path) != nil else { return check("run.open", false) }
        let before = wb.terminals.count
        wb.runActiveFile()
        let ran = await until(10) { wb.terminals.count == before + 1 && wb.terminals.last?.title.hasPrefix("Run") == true }
        check("run.file", ran, wb.terminals.last?.title ?? "")
        await shot("run-file", wait: 4)
        wb.taskPicker = true
        await shot("task-picker", wait: 3)
        wb.taskPicker = false
    }

    static func ports(_ wb: Workbench, _ d: Desktop) async {
        let port: UInt16 = 8765
        wb.newTerminal(input: "python3 -m http.server \(port) --bind 127.0.0.1\r", title: "http.server")
        var seen = false
        for _ in 0..<30 {
            if ((try? await d.listeningPorts()) ?? []).contains(where: { $0.port == port }) { seen = true; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("ports.detect", seen)
        wb.panelOpen = true
        wb.panelTab = .ports
        await shot("ports-panel", wait: 5)
        let local = try? await d.forwardPort(port: port)
        var body = ""
        if let local, let url = URL(string: "http://127.0.0.1:\(local)/README.md"),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            body = String(decoding: data, as: UTF8.self)
        }
        check("ports.forward", body.contains("PadCode test"), "\(body.count) bytes via 127.0.0.1:\(local ?? 0)")
        if local != nil { d.stopForward(port: port) }
        wb.preview(port: port)
        let tab = await until(10) { wb.activeFile?.viewer == .browser }
        check("ports.preview-tab", tab)
        await shot("browser", wait: 4)
        if let id = wb.terminals.last?.id { wb.killTerminal(id) } // stops the server
        wb.panelTab = .terminal
    }

    static func lsp2(_ wb: Workbench, _ path: String) async {
        guard let tv = await open(wb, path) else { return check("lsp2.open", false) }
        _ = await until(20) { wb.languages.server(of: path) != nil }
        caret(tv, after: "p.x")
        wb.languages.findReferences()
        let refs = await until(10) { wb.languages.references != nil }
        check("lsp2.references", refs && (wb.languages.references?.count ?? 0) >= 3, "\(wb.languages.references?.count ?? 0) refs")
        await shot("references") // the picker must be visible here
        wb.languages.references = nil
        // Rename p -> pt, then back, without saving.
        caret(tv, after: "p.x")
        wb.languages.beginRename()
        check("lsp2.rename-prompt", wb.languages.renameRequest?.current == "p", wb.languages.renameRequest?.current ?? "nil")
        await shot("rename", wait: 2)
        wb.languages.commitRename("pt")
        let renamed = await until(10) { wb.file(path)?.text.contains("pt.x + pt.y") == true }
        check("lsp2.rename", renamed)
        // Signature help in a call to printf.
        caret(tv, after: "printf(", plus: 7)
        wb.languages.requestSignature(tv, path: path)
        let sig = await until(10) { wb.languages.signature != nil }
        check("lsp2.signature", sig, wb.languages.signature?.sig.label ?? "")
        await shot("signature")
        wb.languages.signature = nil
        // Quick fix on the undeclared identifier line.
        caret(tv, after: "missing_value")
        wb.languages.showCodeActions()
        _ = await until(10) { wb.languages.codeActions != nil }
        check("lsp2.code-actions-roundtrip", true, "\(wb.languages.codeActions?.count ?? 0) actions: \((wb.languages.codeActions ?? []).map(\.title).prefix(3).joined(separator: "; "))")
        await shot("quickfix")
        wb.languages.codeActions = nil
        wb.closeEverywhere(path) // discard the rename

        // A quick fix that really edits: rust-analyzer's "Add explicit type".
        let rs = path.replacingOccurrences(of: "point.c", with: "src/main.rs")
        guard let rtv = await open(wb, rs) else { return check("lsp2.rust-open", false) }
        _ = await until(60) { wb.languages.server(of: rs) != nil && wb.languages.progress(for: rs) == nil }
        caret(rtv, after: "let name", plus: 5)
        var actions: [Action] = []
        for _ in 0..<10 { // the server may still be loading the crate
            wb.languages.showCodeActions()
            if await until(5, { wb.languages.codeActions != nil }) { actions = wb.languages.codeActions ?? []; break }
            try? await Task.sleep(for: .seconds(2))
        }
        await shot("quickfix-rust")
        if let a = actions.first(where: { $0.title.lowercased().contains("explicit type") }) {
            wb.languages.runCodeAction(a)
            let applied = await until(10) { wb.file(rs)?.text.contains("let name: &") == true }
            check("lsp2.quickfix-applies", applied, a.title)
        } else {
            check("lsp2.quickfix-applies", false, "offered: \(actions.map(\.title).joined(separator: "; "))")
        }
        wb.languages.codeActions = nil
        wb.closeEverywhere(rs)
    }

    /// Editor pointer features: hover card after resting on a symbol, the
    /// right-click menu's VS Code items, and terminal scrollback by scrolling.
    static func pointer(_ wb: Workbench, _ path: String) async {
        guard let tv = await open(wb, path) else { return check("pointer.open", false) }
        _ = await until(20) { wb.languages.serverName(for: path) != nil }
        // Rest on "missing_value" (a diagnostic) and wait for the card.
        let ns = tv.text as NSString
        let at = ns.range(of: "missing_value").location + 3
        tv.layoutIfNeeded()
        guard let pos = tv.position(from: tv.beginningOfDocument, offset: at),
              let range = tv.textRange(from: pos, to: tv.position(from: pos, offset: 1) ?? pos) else { return check("pointer.pos", false) }
        let r = tv.firstRect(for: range)
        wb.languages.pointerMoved(CGPoint(x: r.midX, y: r.midY), in: tv)
        let shown = await until(5) { wb.languages.hover?.fromPointer == true }
        check("pointer.hover-card", shown, String((wb.languages.hover?.text ?? "").prefix(60)))
        await shot("pointer-hover")
        wb.languages.pointerMoved(CGPoint(x: 2000, y: r.midY), in: tv) // off the end of the line: whitespace
        check("pointer.hover-hides", wb.languages.hover == nil)
        let items = (tv.extraEditMenuItems?() ?? []).flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { ($0 as? UIAction)?.title }
        check("pointer.context-menu", items.contains("Go to Definition") && items.contains("Rename Symbol"), items.joined(separator: ", "))
        wb.closeEverywhere(path)

        // Terminal: lots of output, then scroll back the way a two-finger scroll does.
        wb.panelOpen = true
        wb.newTerminal(input: "for i in $(seq 1 300); do echo line-$i; done\r")
        guard let s = wb.terminals.last else { return check("pointer.terminal", false) }
        _ = await until(10) { s.view.contentSize.height > s.view.bounds.height * 3 }
        // Until the output stops: more lines arriving would scroll it back down.
        var last = -1.0
        _ = await until(5, every: .milliseconds(300)) {
            defer { last = s.view.contentSize.height }
            return s.view.contentSize.height == last
        }
        let v = s.view
        let bottom = v.contentOffset.y
        let pan = v.panGestureRecognizer
        let ok = v.isScrollEnabled && v.gestureRecognizerShouldBegin(pan) && bottom > 0
        v.setContentOffset(CGPoint(x: 0, y: max(0, bottom - v.bounds.height * 2)), animated: false)
        try? await Task.sleep(for: .milliseconds(300))
        check("pointer.terminal-scrollback", ok && v.contentOffset.y < bottom, String(format: "%.0f -> %.0f", bottom, v.contentOffset.y))
        await shot("terminal-scrolled")
        wb.killTerminal(s.id)
    }

    /// A full-screen program that tracks the mouse (like Claude Code) gets the
    /// trackpad's scrolling as wheel reports, not the empty scrollback.
    static func wheel(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        let script = d.join(base: root, name: "wheel.py"), out = d.join(base: root, name: "wheel.out")
        let py = """
        import os, select, sys, time, tty
        tty.setraw(0)
        os.write(1, b"\\x1b[?1049h\\x1b[?1000h\\x1b[?1006hmouse-app")
        data, end = b"", time.time() + 15
        while time.time() < end:
            if select.select([0], [], [], 0.2)[0]:
                if not data: end = time.time() + 3  # collect 3 s from the first report
                data += os.read(0, 4096)
        os.write(1, b"\\x1b[?1006l\\x1b[?1000l\\x1b[?1049l")
        open(sys.argv[1], "wb").write(data)
        """
        try? await d.writeFile(path: script, data: Data(py.utf8))
        try? await d.writeFile(path: out, data: Data())
        wb.panelOpen = true
        wb.newTerminal(input: "python3 \(script) \(out)\r")
        guard let s = wb.terminals.last, let v = s.view as? PadTerminalView else { return check("wheel.open", false) }
        guard await until(10, { v.wheel != nil }) else { return check("wheel.mouse-mode", false) }
        check("wheel.takes-trackpad-scroll", v.gestureRecognizerShouldBegin(v.scrollPan) && !v.gestureRecognizerShouldBegin(v.panGestureRecognizer))
        // A two-finger scroll up: 60 pt of travel, then the fingers lift moving fast.
        let at = CGPoint(x: 40, y: 40)
        v.wheelScroll(.began, travel: 0, at: at)
        v.wheelScroll(.changed, travel: 60, at: at)
        v.wheelScroll(.ended, travel: 0, velocity: 1500, at: at)
        // The program writes what it got 3 s after the first report.
        var got = ""
        for _ in 0..<40 where got.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
            got = (try? await d.readFile(path: out)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let reports = got.components(separatedBy: "\u{1b}[<64;").count - 1
        // 60 pt is ~1 report at 3 rows each; momentum from 1500 pt/s coasts ~750 pt more.
        check("wheel.reaches-program", reports >= 1, "\(reports) wheel-up reports")
        check("wheel.momentum", reports >= 8, "\(reports) reports, most after the fingers lifted")
        wb.killTerminal(s.id)
        try? await d.remove(path: script)
        try? await d.remove(path: out)
    }

    /// What you wait for, timed to the millisecond: terminal echo, opening a
    /// file, switching tabs.
    static func snappy(_ wb: Workbench, _ d: Desktop, _ root: String, _ files: [String]) async {
        func report(_ name: String, _ ms: [Double], budget: Double) {
            let s = ms.sorted()
            guard !s.isEmpty else { return check("snappy.\(name)", false, "no samples") }
            check("snappy.\(name)", s[s.count / 2] < budget, String(format: "median %.0f ms, worst %.0f ms (budget %.0f)", s[s.count / 2], s.last!, budget))
        }
        var pings: [Double] = []
        for _ in 0..<8 { let t0 = CACurrentMediaTime(); try? await d.ping(); pings.append((CACurrentMediaTime() - t0) * 1000) }
        report("tunnel-round-trip", pings, budget: 120)
        var reads: [Double] = []
        for _ in 0..<8 {
            let t0 = CACurrentMediaTime()
            _ = try? await d.readFile(path: files[1])
            reads.append((CACurrentMediaTime() - t0) * 1000)
        }
        report("read-file", reads, budget: pings.sorted()[4] + 25)
        // Typing in the terminal: key to echo on screen data.
        wb.panelOpen = true
        wb.newTerminal()
        guard let s = wb.terminals.last else { return check("snappy.terminal", false) }
        try? await Task.sleep(for: .seconds(2.5))
        var echo: [Double] = []
        for _ in 0..<12 {
            let before = s.received.value
            s.send("x")
            if let ms = await timed(2, { s.received.value > before }) { echo.append(ms) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        report("terminal-echo", echo, budget: (pings.sorted()[4]) + 25)
        wb.killTerminal(s.id)
        // Opening files (not open yet) from the Explorer: click to text in the editor.
        for f in files { wb.closeEverywhere(f) }
        wb.learnSizes(in: root, files.filter { !$0.contains("/src/") }.map { Entry(name: ($0 as NSString).lastPathComponent, kind: .file) })
        try? await Task.sleep(for: .seconds(1))
        var opens: [Double] = [], colors: [Double] = []
        for f in files {
            let t0 = CACurrentMediaTime()
            await wb.open(f)
            if await until(5, every: .milliseconds(1), { wb.languages.activePath == f && wb.languages.activeView?.text.isEmpty == false }) {
                opens.append((CACurrentMediaTime() - t0) * 1000)
            }
            if await until(5, every: .milliseconds(1), { wb.editors["\(wb.focusedGroup):\(f)"]?.colored == true }) {
                colors.append((CACurrentMediaTime() - t0) * 1000)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        report("open-file", opens, budget: pings.sorted()[4] * 2 + 60)
        report("open-file-colors", colors, budget: pings.sorted()[4] * 2 + 200)
        // Switching between open tabs: until the first frame after the new tab
        // is in the window, so work done before that frame's commit counts.
        var switches: [Double] = []
        let clock = FrameClock()
        defer { clock.stop() }
        for _ in 0..<2 {
            for f in files {
                let t0 = CACurrentMediaTime()
                wb.focus(f, in: wb.focusedGroup)
                if await until(3, every: .milliseconds(1), { wb.languages.activePath == f && wb.languages.activeView?.window != nil }) {
                    wb.languages.activeView?.layoutIfNeeded()
                    _ = await clock.next()
                    switches.append((CACurrentMediaTime() - t0) * 1000)
                }
                try? await Task.sleep(for: .milliseconds(150)) // a person's pace; the keyboard's follow-up work lands here
            }
        }
        report("switch-tab", switches, budget: 50)
        for f in files { wb.closeEverywhere(f) }
    }

    /// Terminal rendering under a Claude Code-like load (full-screen redraws in
    /// synchronized-output frames, 100 a second), counting missed display frames.
    static func termPerf(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        let script = d.join(base: root, name: "redraw.py")
        try? await d.writeFile(path: script, data: Data("""
        import os, sys, time, tty
        tty.setraw(0)
        rows, cols = os.get_terminal_size(0).lines, os.get_terminal_size(0).columns
        os.read(0, 1)  # go
        os.write(1, b"\\x1b[?1049h")
        for f in range(300):
            out = [b"\\x1b[?2026h\\x1b[H"]
            for r in range(rows - 1):
                c = 31 + (r + f) % 7
                out.append(b"\\x1b[%dm%s\\x1b[0m\\x1b[K\\r\\n" % (c, (b"frame %d row %d " % (f, r)) * (cols // 18)))
            out.append(b"\\x1b[?2026l")
            os.write(1, b"".join(out))
            time.sleep(0.01)
        os.write(1, b"\\x1b[?1049l")
        time.sleep(30)
        """.utf8))
        wb.side = .explorer
        wb.panelOpen = true
        do {
            wb.newTerminal()
            guard let s = wb.terminals.last else { return check("termperf.open", false) }
            try? await Task.sleep(for: .seconds(2.5))
            s.send("python3 \(script)\r")
            try? await Task.sleep(for: .seconds(1.5))
            let clock = FrameClock()
            var last = await clock.next()
            let start = last
            s.send("g")
            var dropped = 0, worst = 0.0, frames = 0
            while last - start < 3.5 {
                let now = await clock.next()
                worst = max(worst, now - last)
                dropped += max(0, Int(((now - last) / clock.period).rounded()) - 1)
                frames += 1
                last = now
            }
            clock.stop()
            // (SwiftTerm's Metal renderer measured the same here, so it stays off.)
            check("termperf.redraw", dropped <= frames / 10,
                  String(format: "%d of %d frames missed, worst %.1f ms", dropped, frames + dropped, worst * 1000))
            await shot("termperf", wait: 0.5)
            wb.killTerminal(s.id)
        }
        try? await d.remove(path: script)
    }

    /// The sidebar and panel slide in and out without dropping frames, and the
    /// terminal isn't resized frame by frame while the panel slides.
    /// Editor visuals: bracket pair colors, indent guides, squiggles, sticky
    /// scroll, overview ruler, breadcrumb symbols, palette chips, error toast.
    static func visuals(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        let path = d.join(base: root, name: "visuals.c")
        var src = "#include <stdio.h>\n\nstruct shape { int sides; int (*area)(int); };\n\n"
        src += "static int square(int s) {\n    return s * s;\n}\n\n"
        src += "int main(void) {\n    struct shape shapes[] = {{4, square}, {3, square}};\n"
        src += "    for (int i = 0; i < 2; i++) {\n        if (shapes[i].sides > 3) {\n"
        for i in 0..<40 { src += "            printf(\"%d (%s)\\n\", shapes[i].area(\(i)), \"[{}]\");\n" }
        src += "        }\n    }\n    return undefined_name;\n}\n"
        try? await d.writeFile(path: path, data: Data(src.utf8))
        guard let tv = await open(wb, path) as? PadTextView else { return check("visuals.open", false) }
        let c = wb.editors["\(wb.focusedGroup):\(path)"]
        _ = await until(5) { c?.colored == true }
        // Bracket colors: "((" at depth 0 and 1 differ; a bracket inside a string keeps the string color.
        let ns = tv.text as NSString
        let theme = EditorTheme(wb.theme, fontSize: wb.fontSize)
        check("visuals.bracket-colors", theme.bracketPairColors.count >= 3, "\(theme.bracketPairColors.count) colors")
        // Sticky scroll: scroll into the loop body, the headers pin.
        _ = await until(30) { !(wb.languages.outlines[path] ?? []).isEmpty }
        let sym = wb.languages.outlines[path] ?? []
        check("visuals.outline", !sym.isEmpty, sym.map(\.name).joined(separator: ","))
        if let loc = tv.location(at: TextLocation(lineNumber: 30, column: 0)),
           let pos = tv.position(from: tv.beginningOfDocument, offset: loc) {
            tv.setContentOffset(CGPoint(x: 0, y: tv.caretRect(for: pos).minY - 40), animated: false)
        }
        _ = await until(2) { c?.sticky.isHidden == false }
        check("visuals.sticky-scroll", c?.sticky.isHidden == false, "\(Int(c?.sticky.bounds.height ?? 0)) pt tall")
        // Caret inside the if-block: breadcrumbs show main, the ruler and guides follow.
        tv.selectedRange = NSRange(location: ns.range(of: "area(20)").location, length: 0)
        _ = await until(30) { !(wb.languages.diagnostics[path] ?? []).isEmpty }
        check("visuals.squiggle", tv.highlightedRanges.contains { $0.id.hasPrefix("diag") && $0.cornerRadius < 0 })
        // F8 from the top lands on the error (`undefined_name`), with its hover.
        tv.selectedRange = NSRange(location: 0, length: 0)
        wb.languages.goToProblem(forward: true)
        let atError = ns.substring(with: NSRange(location: tv.selectedRange.location, length: 14)) == "undefined_name"
        _ = await until(5) { wb.languages.hover != nil }
        check("visuals.next-problem", atError && wb.languages.hover?.text.contains("undefined") == true, wb.languages.hover?.text.prefix(60).description ?? "no hover")
        await shot("visuals-next-problem")
        wb.languages.hover = nil
        tv.selectedRange = NSRange(location: ns.range(of: "area(20)").location, length: 0)
        await shot("visuals-editor")
        wb.palette = true
        try? await Task.sleep(for: .milliseconds(500))
        await shot("visuals-palette")
        wb.palette = false
        wb.alert = "Example error: couldn't reach the desktop."
        await shot("visuals-toast", wait: 1)
        wb.alert = nil
        wb.closeEverywhere(path)
        try? await d.remove(path: path)
    }

    /// Untrusted file content can't run code in PadCode's web views.
    static func security(_ wb: Workbench) {
        let evil = "# hi\n</script><script>window.pwned=1</script>\n<img src=x onerror=\"window.pwned=2\">"
        let page = MarkdownPreview.page(markdown: evil, theme: wb.theme, fontSize: 13)
        check("security.markdown-no-breakout", !page.contains("</script><script>window.pwned"), "raw </script> in the page")
        let scripts = page.components(separatedBy: "<script").count - 1
        let nonced = page.components(separatedBy: "<script nonce=").count - 1
        check("security.markdown-csp", page.contains("script-src 'nonce-") && scripts == 2 && nonced == 2, "\(scripts) scripts, \(nonced) with the nonce")
        check("security.link-schemes", HTMLView.Coordinator.external == ["http", "https", "mailto"])
    }

    /// Zen mode, the maximized panel, and reordering tabs by dragging.
    static func layoutModes(_ wb: Workbench, _ a: String, _ b: String, _ c: String) async {
        for p in [a, b, c] { _ = await open(wb, p) }
        let g = wb.focusedGroup
        wb.side = .explorer
        wb.panelOpen = true
        wb.toggleZen()
        try? await Task.sleep(for: .milliseconds(600))
        await shot("zen")
        check("layout.zen", wb.zen && wb.side == nil && !wb.panelOpen)
        wb.toggleZen()
        try? await Task.sleep(for: .milliseconds(600))
        check("layout.zen-restores", !wb.zen && wb.side == .explorer && wb.panelOpen)
        wb.panelMaximized = true
        try? await Task.sleep(for: .milliseconds(500))
        await shot("panel-maximized")
        let editorGone = wb.editors["\(g):\(c)"]?.tv?.window == nil
        wb.panelMaximized = false
        try? await Task.sleep(for: .milliseconds(500))
        check("layout.panel-maximized", editorGone && wb.editors["\(g):\(c)"]?.tv?.window != nil)
        // Drag c over a: c takes a's place; then a back over c.
        let before = wb.groups[g].tabs
        wb.moveTab(c, onto: a, in: g)
        let moved = wb.groups[g].tabs
        wb.moveTab(a, onto: c, in: g)
        // Each dragged tab takes its target's place (whichever side it came from).
        check("layout.tab-reorder", moved.firstIndex(of: c) == before.firstIndex(of: a) && wb.groups[g].tabs.firstIndex(of: a) == moved.firstIndex(of: c),
              "\(moved.map { wb.baseName($0) }) then \(wb.groups[g].tabs.map { wb.baseName($0) })")
        // A hidden terminal keeps its old, wider size; that mustn't widen the panel
        // (it pushed the window sideways: Explorer cut off, panel past the edge).
        wb.panelTab = .terminal
        if wb.terminals.isEmpty { wb.newTerminal() }
        wb.side = nil
        try? await Task.sleep(for: .seconds(1))
        wb.panelTab = .ports
        wb.side = .explorer
        try? await Task.sleep(for: .seconds(1))
        await shot("ports-after-sidebar")
        if let term = wb.terminals.last?.view.superview, let tv = wb.editors["\(g):\(c)"]?.tv {
            let panelX = term.convert(term.bounds, to: nil).minX, editorX = tv.convert(tv.bounds, to: nil).minX
            check("layout.hidden-terminal-width", abs(panelX - editorX) < 20, "panel at \(Int(panelX)), editor at \(Int(editorX))")
        } else { check("layout.hidden-terminal-width", false, "no views") }
        wb.panelTab = .terminal
        // A dragged tab dropped on an Explorer folder must not move the file.
        check("layout.tab-drag-marked", (TabDrag.mark + a).hasPrefix(TabDrag.mark) && !wb.isWithin(TabDrag.mark + a, wb.root))
        for p in [a, b, c] { wb.closeEverywhere(p) }
    }

    static func animations(_ wb: Workbench, _ path: String) async {
        _ = await open(wb, path)
        if wb.terminals.isEmpty { wb.newTerminal() }
        wb.panelOpen = true
        wb.side = .explorer
        try? await Task.sleep(for: .seconds(2))
        guard let s = wb.terminals.last else { return check("anim.terminal", false) }
        let clock = FrameClock()
        for (name, toggle) in [("sidebar", { wb.toggleSidebar() }), ("panel", { wb.togglePanel() })] as [(String, () -> Void)] {
            var dropped = 0, frames = 0, worst = 0.0
            var each: [String] = [] // per toggle: missed frames @ frame index of the worst gap
            let resizesBefore = s.resizeCount
            for _ in 0..<6 {
                toggle()
                var last = await clock.next()
                let start = last
                var mine = 0, worstHere = 0.0, worstAt = 0, n = 0
                while last - start < 0.3 {
                    let now = await clock.next()
                    n += 1
                    if now - last > worstHere { worstHere = now - last; worstAt = n }
                    mine += max(0, Int(((now - last) / clock.period).rounded()) - 1)
                    last = now
                }
                worst = max(worst, worstHere)
                dropped += mine
                frames += n
                each.append("\(mine)@\(worstAt)")
            }
            check("anim.\(name)", dropped <= frames / 10, String(format: "%d of %d frames missed, worst %.1f ms [%@]", dropped, frames + dropped, worst * 1000, each.joined(separator: " ")))
            if name == "panel" { check("anim.panel-no-resize-storm", s.resizeCount - resizesBefore <= 2, "\(s.resizeCount - resizesBefore) resizes sent") }
        }
        clock.stop()
        wb.panelOpen = true
        wb.side = .explorer
        wb.closeEverywhere(path)
    }

    /// Terminal: Move Terminal into New Window, and New Terminal Window. The shell
    /// must survive the move and the new window must reattach the same one.
    static func terminalWindow(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        guard wb.env?.os != .windows else { return check("termwindow", true, "skipped on Windows") }
        wb.panelOpen = true
        wb.newTerminal(title: "move-me")
        guard let t = wb.terminals.last else { return check("termwindow.open", false) }
        let pidFile = d.join(base: root, name: ".pid-move")
        try? await Task.sleep(for: .seconds(2.5))
        t.send("echo $$ > '\(pidFile)'\r")
        try? await Task.sleep(for: .seconds(1))
        let before = (try? await d.readFile(path: pidFile)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        let id = t.persistentID
        let scenes = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        let bytes = t.received.value
        let t0 = CACurrentMediaTime()
        wb.moveTerminalToNewWindow(t.id)
        check("termwindow.left-main", !wb.terminals.contains { $0.persistentID == id })
        // The new window's workbench: a terminals-only one holding this shell.
        let other = await until(15, every: .milliseconds(5)) {
            Workbench.live.contains { $0.wb?.terminalsOnly != nil && $0.wb?.terminals.first?.view.window != nil && $0.wb?.terminals.first?.persistentID == id }
        }
        let ms = (CACurrentMediaTime() - t0) * 1000
        guard other, let tw = Workbench.live.compactMap(\.wb).first(where: { $0.terminals.first?.persistentID == id && $0.terminalsOnly != nil }),
              let moved = tw.terminals.first else { return check("termwindow.opened", false) }
        check("termwindow.opened", true, String(format: "%d new window, terminal on screen in %.0f ms", UIApplication.shared.openSessions.count - scenes.count, ms))
        check("termwindow.instant-handoff", moved === t && tw.desktop === wb.desktop && moved.received.value == bytes,
              "same view \(moved === t), shared connection \(tw.desktop === wb.desktop), replayed \(moved.received.value - bytes) bytes")
        _ = await until(10) { moved.received.value > 0 }
        moved.send("echo $$ > '\(pidFile)'\r")
        try? await Task.sleep(for: .seconds(1.5))
        let after = (try? await d.readFile(path: pidFile)).map { String(decoding: $0, as: UTF8.self) } ?? "!"
        check("termwindow.same-shell", before == after && !before.isEmpty, "pid \(before.trimmingCharacters(in: .newlines)) -> \(after.trimmingCharacters(in: .newlines))")
        await shot("terminal-window", wait: 2)
        // Back into the editor window: same shell again, in the main panel; the
        // emptied terminal window closes.
        check("termwindow.editor-window-found", tw.editorWindow === wb)
        let beforeBack = UIApplication.shared.openSessions.count
        tw.moveTerminalToEditorWindow(moved.id)
        let back = await until(10) { wb.terminals.contains { $0.persistentID == id && $0.received.value > 0 } }
        if back, let s = wb.terminals.first(where: { $0.persistentID == id }) {
            s.send("echo $$ > '\(pidFile)'\r")
            try? await Task.sleep(for: .seconds(1.5))
        }
        let again = (try? await d.readFile(path: pidFile)).map { String(decoding: $0, as: UTF8.self) } ?? "!"
        check("termwindow.moved-back", back && again == before, "pid \(again.trimmingCharacters(in: .newlines))")
        let closed = await until(5) { UIApplication.shared.openSessions.count < beforeBack }
        check("termwindow.empty-window-closed", closed)
        if let s = wb.terminals.first(where: { $0.persistentID == id }) { wb.killTerminal(s.id) }
        // New Terminal Window: a second window with one fresh shell of its own.
        let existing = Set(Workbench.live.compactMap(\.wb).map(ObjectIdentifier.init))
        wb.openTerminalWindow()
        let fresh = await until(20) {
            Workbench.live.compactMap(\.wb).contains {
                !existing.contains(ObjectIdentifier($0)) && $0.terminalsOnly == [] && $0.desktop != nil
                    && $0.terminals.count == 1 && $0.terminals[0].received.value > 0
            }
        }
        check("termwindow.new-window", fresh)
        await shot("terminal-windows", wait: 2)
        // Close what this step opened: killing a window's last terminal closes it.
        for w in Workbench.live.compactMap(\.wb) where w.terminalsOnly != nil {
            for s in w.terminals { w.killTerminal(s.id) }
        }
        for _ in 0..<10 where UIApplication.shared.openSessions.count > scenes.count {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let left = UIApplication.shared.openSessions.filter { !scenes.contains($0.persistentIdentifier) }
        check("termwindow.closes-when-empty", left.isEmpty, "\(left.count) left open")
        let front = await until(5) { wb.scene?.activationState == .foregroundActive }
        check("termwindow.back-to-editor", front, "editor window \(String(describing: wb.scene?.activationState.rawValue))")
        for s in left { UIApplication.shared.requestSceneSessionDestruction(s, options: nil) }
        try? await d.remove(path: pidFile)
    }

    /// Editor ↔ terminal keyboard focus, as on the desktop: one press in the
    /// terminal, ⌃` both ways, new terminals.
    static func focus(_ wb: Workbench, _ d: Desktop, _ root: String, _ path: String) async {
        guard let tv = await open(wb, path) else { return check("focus.open", false) }
        // Runestone hands the keyboard to an inner view; isEditing says the editor has it.
        wb.panelOpen = true
        wb.newTerminal()
        guard let s = wb.terminals.last, let v = s.view as? PadTerminalView else { return check("focus.terminal", false) }
        _ = await until(5) { v.isFirstResponder }
        check("focus.new-terminal", v.isFirstResponder)
        _ = tv.becomeFirstResponder()
        v.simulatePress()
        check("focus.one-press", v.isFirstResponder && !tv.isEditing)
        wb.toggleTerminal() // from the terminal: hide it, back to the editor
        check("focus.toggle-to-editor", !wb.panelOpen && tv.isEditing)
        wb.toggleTerminal() // from the editor: show it and type there
        let ms = await timed(2) { v.isFirstResponder }
        check("focus.toggle-to-terminal", ms != nil && wb.panelOpen, String(format: "%.0f ms", ms ?? -1))
        // A program that tracks the mouse used to get the first click without the terminal taking the keyboard.
        let script = d.join(base: root, name: "mouse.py")
        try? await d.writeFile(path: script, data: Data("""
        import os, time, tty
        tty.setraw(0)
        os.write(1, b"\\x1b[?1049h\\x1b[?1000;1006hmouse-app")
        time.sleep(20)
        """.utf8))
        s.send("python3 \(script)\r")
        _ = await until(10) { v.wheel != nil }
        _ = tv.becomeFirstResponder()
        v.simulatePress()
        check("focus.one-press-mouse-app", v.isFirstResponder)
        wb.killTerminal(s.id)
        check("focus.kill-returns", tv.isEditing || wb.terminals.last?.view.isFirstResponder == true)
        try? await d.remove(path: script)
        wb.closeEverywhere(path)
    }

    /// A full-screen mouse app whose mode switches scrolled out of the session's
    /// replay ring (Claude Code after a while) still comes back full-screen
    /// with the mouse on when the app relaunches and reattaches.
    static func reattachModes(_ wb: Workbench, _ d: Desktop, _ root: String) async {
        guard wb.env?.os != .windows else { return check("reattach.modes", true, "skipped on Windows") }
        let script = d.join(base: root, name: "fullscreen.py")
        let py = """
        import os, time, tty
        tty.setraw(0)
        os.write(1, b"\\x1b[?1049h\\x1b[?1000;1006h")
        frame = b"\\x1b[H" + (b"x" * 70 + b"\\r\\n") * 20
        for _ in range(500): os.write(1, frame)  # ~720 KB: the mode switches leave the 512 KB ring
        os.write(1, b"\\x1b[Hready")
        time.sleep(60)
        """
        try? await d.writeFile(path: script, data: Data(py.utf8))
        wb.panelOpen = true
        wb.newTerminal(input: "python3 \(script)\r", title: "fullscreen")
        guard let t = wb.terminals.last else { return check("reattach.modes", false) }
        try? await Task.sleep(for: .seconds(6))
        // Drop the session object like an app relaunch does; the shell keeps running.
        let id = t.persistentID
        wb.terminals.removeAll { $0 === t }
        try? await Task.sleep(for: .seconds(1))
        wb.newTerminal(title: "reattached", persistentID: id)
        guard let fresh = wb.terminals.last, let v = fresh.view as? PadTerminalView else { return check("reattach.modes", false) }
        let mouse = await until(10) { v.wheel != nil }
        check("reattach.modes", mouse, mouse ? "mouse tracking restored" : "came back without the app's modes")
        await shot("reattached")
        wb.killTerminal(fresh.id)
        try? await d.remove(path: script)
    }

    /// Trackpad drag-select in the terminal, and closing terminal tabs.
    static func terminalSelect(_ wb: Workbench) async {
        wb.panelOpen = true
        wb.panelTab = .terminal
        wb.newTerminal(input: "clear; echo PADSEL-abcdef\r")
        guard let s = wb.terminals.last, let pointer = s.pointer else { return check("termselect.open", false) }
        try? await Task.sleep(for: .seconds(4))
        let v = s.view
        guard let cell = pointer.cell else { return check("termselect.cell", false) }
        let (w, h) = (cell.width, cell.height)
        // After `clear` the echo is on the top visible row.
        let y = v.contentOffset.y + h / 2
        pointer.begin(at: CGPoint(x: w * 0.2, y: y))
        pointer.extend(to: CGPoint(x: w * 13, y: y))
        let got = v.getSelection() ?? ""
        check("termselect.drag", got == "PADSEL-abcdef", "\"\(got)\"")
        // Two-finger scrolling: the scroll view still takes trackpad input, and
        // isn't waiting on the selection drag (which never sees scroll events).
        let pan = v.panGestureRecognizer
        let takesTrackpad = pan.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue))
        let blocked = pointer.gestureRecognizer(UIPanGestureRecognizer(), shouldBeRequiredToFailBy: pan)
        check("termselect.two-finger-scroll", takesTrackpad && !blocked && v.gestureRecognizerShouldBegin(pan))
        await shot("terminal-select")
        v.clearSelection()
        // ⌘F finds in the scrollback; ⌘K clears it and the prompt comes back.
        s.finding = true
        let found = v.findNext("PADSEL-abc")
        let summary = v.searchMatchSummary("PADSEL-abc")
        try? await Task.sleep(for: .milliseconds(400))
        await shot("terminal-find")
        check("terminal.find", found && summary.total >= 1, "\(summary.index) of \(summary.total)")
        v.clearSearch()
        s.finding = false
        s.send("seq 1 200\r")
        try? await Task.sleep(for: .seconds(1))
        let tall = v.contentSize.height
        (v as? PadTerminalView)?.clearTerminal()
        _ = await until(3) { v.contentSize.height < tall }
        check("terminal.clear", v.contentSize.height < tall, "\(Int(tall)) -> \(Int(v.contentSize.height)) pt")
        // Run Selected Text: the caret's line goes to this (active) terminal.
        let script = wb.root + "/run-selection.sh"
        try? await wb.desktop?.writeFile(path: script, data: Data("echo PADRUN-$((6*7))\n".utf8))
        if let tv = await open(wb, script) as? PadTextView {
            tv.selectedRange = NSRange(location: 2, length: 0)
            wb.runSelectionInTerminal()
            let ran = await until(5) { v.searchMatchSummary("PADRUN-42").total > 0 } // the output, not the echoed command
            check("terminal.run-selection", ran && wb.activeTerminal == s.id)
            wb.closeEverywhere(script)
        } else { check("terminal.run-selection", false, "no editor") }
        try? await wb.desktop?.remove(path: script)
        // Closing tabs: the neighbor takes over; the last one closes the panel.
        wb.newTerminal(title: "second")
        wb.newTerminal(title: "third")
        wb.newTerminal(title: "fourth")
        await shot("terminal-tabs")
        wb.side = nil // wider panel: room for the tabs
        await shot("terminal-tabs-wide")
        wb.side = .explorer
        let ids = wb.terminals.map(\.id)
        wb.activeTerminal = ids[ids.count - 2]
        wb.killTerminal(ids[ids.count - 2])
        check("termselect.kill-neighbor", wb.activeTerminal == ids.last)
        for t in wb.terminals { wb.killTerminal(t.id) }
        check("termselect.kill-all-closes-panel", wb.terminals.isEmpty && !wb.panelOpen)
    }

    /// Every hover state drawn at once, for a screenshot (there's no pointer to
    /// move in a test). Only the "hover" step turns it on.
    static let hoverAll = requested == "hover"

    static func hover(_ wb: Workbench, _ a: String, _ b: String) async {
        _ = await open(wb, b)
        _ = await open(wb, a)
        wb.side = .explorer
        wb.panelOpen = true
        if wb.terminals.isEmpty { wb.newTerminal() }
        await shot("hover-workbench")
        wb.side = .outline
        await shot("hover-outline")
        wb.side = .explorer
        wb.quickOpen = true
        await shot("hover-quick-open")
        wb.quickOpen = false
    }

    /// Dragging each sash back and forth one step per frame, with a file open
    /// and a terminal running, counting the display frames that were missed.
    static func resize(_ wb: Workbench, _ path: String) async {
        guard let tv = await open(wb, path), let window = tv.window else { return check("resize.open", false) }
        wb.side = .explorer
        wb.panelOpen = true
        // Several terminals with output, as after a working session; only one shows.
        while wb.terminals.count < 5 { wb.newTerminal(input: "ls -la /usr/bin\r") }
        try? await Task.sleep(for: .seconds(4))
        func sashes(_ v: UIView) -> [SashView] { (v as? SashView).map { [$0] } ?? v.subviews.flatMap(sashes) }
        let clock = FrameClock()
        for sash in sashes(window) {
            let frames = 240
            var dropped = 0, worst = 0.0, work = 0.0, worstWork = 0.0
            sash.drag(.began, 0)
            var last = await clock.next()
            for i in 1...frames {
                // The frame's main-thread work: SwiftUI and UIKit layout of every part.
                let w0 = CACurrentMediaTime()
                sash.drag(.changed, 150 * sin(Double(i) / 15))
                window.layoutIfNeeded()
                let w = CACurrentMediaTime() - w0
                work += w
                worstWork = max(worstWork, w)
                let now = await clock.next()
                worst = max(worst, now - last)
                dropped += max(0, Int(((now - last) / clock.period).rounded()) - 1)
                last = now
            }
            sash.drag(.ended, 0)
            // The grab area reaches past the 1 pt line on both sides.
            let mid = sash.convert(CGPoint(x: sash.bounds.midX, y: sash.bounds.midY), to: window)
            let off: [CGPoint] = sash.vertical ? [CGPoint(x: -4, y: 0), CGPoint(x: 4, y: 0)] : [CGPoint(x: 0, y: -4), CGPoint(x: 0, y: 4)]
            let grabbed = off.allSatisfy { window.hitTest(CGPoint(x: mid.x + $0.x, y: mid.y + $0.y), with: nil) === sash }
            check("resize.\(sash.vertical ? "sidebar" : "panel")-grab", grabbed)
            check("resize.\(sash.vertical ? "sidebar" : "panel")", dropped <= frames / 20,
                  String(format: "%d frames missed in %d, worst %.1f ms (frame %.1f ms); layout %.2f ms avg, %.1f worst",
                         dropped, frames, worst * 1000, clock.period * 1000, work / Double(frames) * 1000, worstWork * 1000))
        }
        clock.stop()
        // A terminal hidden during the drags fits the panel once shown.
        if let shown = wb.terminals.last, let hidden = wb.terminals.first, shown !== hidden {
            let width = shown.view.bounds.width
            wb.activeTerminal = hidden.id
            let fits = await until(3) { abs(hidden.view.bounds.width - width) < 1 }
            check("resize.hidden-terminal-refits", fits, String(format: "%.0f vs %.0f", hidden.view.bounds.width, width))
            wb.activeTerminal = shown.id
        }
        for t in wb.terminals.dropFirst() { wb.killTerminal(t.id) }
        wb.closeEverywhere(path)
    }
}

/// Awaits display frames.
@MainActor private final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var waiting: CheckedContinuation<CFTimeInterval, Never>?
    let period = 1 / Double(UIScreen.main.maximumFramesPerSecond)

    /// The next frame's time, or after 1 s without frames (window not on
    /// screen) the current time, so a test fails instead of hanging.
    func next() async -> CFTimeInterval {
        await withCheckedContinuation { c in
            waiting = c
            ticket &+= 1
            let n = ticket
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.ticket == n, let w = self.waiting else { return }
                self.waiting = nil
                w.resume(returning: CACurrentMediaTime())
            }
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            let fps = Float(UIScreen.main.maximumFramesPerSecond)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
            l.add(to: .main, forMode: .common)
            link = l
        }
    }
    private var ticket = 0
    @objc private func tick(_ l: CADisplayLink) {
        let w = waiting
        waiting = nil
        w?.resume(returning: l.timestamp)
    }
    func stop() { link?.invalidate() }
}

extension AppSettings {
    /// cleanUp with trim + final newline forced on, for the scenario.
    func cleanUpForTest(_ text: String) -> String {
        let (t, n) = (trimTrailingWhitespace, insertFinalNewline)
        trimTrailingWhitespace = true
        insertFinalNewline = true
        defer { trimTrailingWhitespace = t; insertFinalNewline = n }
        return cleanUp(text)
    }
}

private extension Array where Element == String {
    /// ["a", "b"] → ("a", "b"); a missing second part is "".
    var splat: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
