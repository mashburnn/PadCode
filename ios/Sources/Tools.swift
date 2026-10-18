import SwiftUI
import WebKit

// MARK: - Run & tasks

/// Something to run in a terminal on the desktop.
struct RunTask: Identifiable, Hashable {
    let label: String
    let command: String
    var detail = ""
    var cwd: String?
    var id: String { label + command }

    /// "Run File": the usual way to run a file of this language.
    static func runFile(_ path: String, os: HostOs, cargoRoot: String?) -> RunTask? {
        let q = os == .windows ? "\"\(path)\"" : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let exe = os == .windows ? "$env:TEMP\\padcode-run.exe" : "/tmp/padcode-run"
        let cmd: String?
        switch Language.id(for: path) {
        case "python": cmd = (os == .windows ? "python " : "python3 ") + q
        case "javascript": cmd = "node " + q
        case "typescript": cmd = "npx --yes tsx " + q
        case "go": cmd = "go run " + q
        case "rust": cmd = cargoRoot != nil ? "cargo run" : "rustc \(q) -o \(exe) && \(exe)"
        case "c": cmd = os == .windows ? "gcc \(q) -o \(exe); if ($?) { & \(exe) }" : "cc \(q) -o \(exe) && \(exe)"
        case "cpp": cmd = os == .windows ? "g++ \(q) -o \(exe); if ($?) { & \(exe) }" : "c++ \(q) -o \(exe) && \(exe)"
        case "swift": cmd = "swift " + q
        case "shellscript": cmd = os == .windows ? "bash " + q : "sh " + q
        case "powershell": cmd = (os == .windows ? "powershell -File " : "pwsh -File ") + q
        case "ruby": cmd = "ruby " + q
        case "lua": cmd = "lua " + q
        case "php": cmd = "php " + q
        case "java": cmd = "java " + q
        default: cmd = nil
        }
        return cmd.map { RunTask(label: "Run \((path as NSString).lastPathComponent)", command: $0, cwd: cargoRoot) }
    }
}

extension Workbench {
    /// ⌃F5 / ▶: save, then run the active file in a terminal.
    func runActiveFile() {
        guard let f = activeFile, f.viewer == .text, let env else { return }
        Task {
            if f.dirty { await save(f.path) }
            let cargo = Language.id(for: f.path) == "rust" ? await cargoRoot(for: f.path) : nil
            guard let task = RunTask.runFile(f.path, os: env.os, cargoRoot: cargo) else {
                toast = "Don't know how to run \(f.name)"
                return
            }
            run(task, cwd: task.cwd ?? parentDir(f.path))
        }
    }

    func run(_ task: RunTask, cwd: String? = nil) {
        newTerminal(cwd: cwd ?? task.cwd ?? (root.isEmpty ? nil : root), input: task.command + "\r", title: task.label)
    }

    /// Nearest folder up from `path` (within the open folder) with a Cargo.toml.
    private func cargoRoot(for path: String) async -> String? {
        guard let d = desktop else { return nil }
        var dir = parentDir(path)
        while isWithin(dir, root) || dir == root {
            if (try? await d.stat(path: d.join(base: dir, name: "Cargo.toml")).exists) == true { return dir }
            let up = parentDir(dir)
            if up == dir { break }
            dir = up
        }
        return nil
    }

    /// Tasks found in the open folder, like VS Code's auto-detected tasks.
    func detectTasks() async -> [RunTask] {
        guard let d = desktop, !root.isEmpty else { return [] }
        // One listing instead of probing each candidate file over the tunnel.
        var present = Set(((try? await d.listDir(path: root)) ?? []).map(\.name))
        if present.contains(".vscode"), (try? await d.stat(path: d.join(base: root, name: ".vscode/tasks.json")).exists) == true {
            present.insert(".vscode/tasks.json")
        }
        func read(_ name: String) async -> String? {
            guard present.contains(name) else { return nil }
            return (try? await d.readFile(path: d.join(base: root, name: name))).flatMap { String(data: $0, encoding: .utf8) }
        }
        var tasks: [RunTask] = []
        if let s = await read(".vscode/tasks.json"), let json = parseJSONC(Data(s.utf8)),
           let list = json["tasks"] as? [[String: Any]] {
            for t in list {
                guard let cmd = t["command"] as? String else { continue }
                let args = (t["args"] as? [Any])?.map { "\($0)" }.joined(separator: " ") ?? ""
                tasks.append(RunTask(label: t["label"] as? String ?? cmd, command: args.isEmpty ? cmd : "\(cmd) \(args)", detail: "tasks.json"))
            }
        }
        if let s = await read("package.json"), let json = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
           let scripts = json["scripts"] as? [String: String] {
            let pm = present.contains("pnpm-lock.yaml") ? "pnpm" : present.contains("yarn.lock") ? "yarn" : "npm"
            for (k, v) in scripts.sorted(by: { $0.key < $1.key }) {
                tasks.append(RunTask(label: "\(pm) run \(k)", command: "\(pm) run \(k)", detail: v))
            }
        }
        if present.contains("Cargo.toml") {
            for c in ["build", "run", "test", "check", "clippy"] {
                tasks.append(RunTask(label: "cargo \(c)", command: "cargo \(c)", detail: "Cargo.toml"))
            }
        }
        if present.contains("go.mod") {
            tasks += [RunTask(label: "go build", command: "go build ./...", detail: "go.mod"),
                      RunTask(label: "go test", command: "go test ./...", detail: "go.mod"),
                      RunTask(label: "go run", command: "go run .", detail: "go.mod")]
        }
        if present.contains("Package.swift") {
            for c in ["build", "test", "run"] { tasks.append(RunTask(label: "swift \(c)", command: "swift \(c)", detail: "Package.swift")) }
        }
        var makefile = await read("Makefile")
        if makefile == nil { makefile = await read("makefile") }
        if let make = makefile {
            let targets = make.split(separator: "\n").compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix("."), !line.hasPrefix("#") else { return nil }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" "), !name.contains("$"), !name.contains("="),
                      line.dropFirst(name.count + 1).first != "=" else { return nil }
                return name
            }
            for t in Array(NSOrderedSet(array: targets)) as! [String] {
                tasks.append(RunTask(label: "make \(t)", command: "make \(t)", detail: "Makefile"))
            }
        }
        return tasks
    }
}

struct TaskPicker: View {
    @EnvironmentObject var wb: Workbench
    @State private var query = ""
    @State private var tasks: [RunTask] = []
    @State private var loading = true

    var body: some View {
        var items = tasks
        if let f = wb.activeFile, let env = wb.env, f.viewer == .text, let rf = RunTask.runFile(f.path, os: env.os, cargoRoot: nil) {
            items.insert(RunTask(label: rf.label, command: "", detail: "Run the active file"), at: 0)
        }
        let q = query.lowercased()
        return QuickPickList(
            placeholder: loading ? "Detecting tasks…" : (items.isEmpty ? "No tasks found in \(wb.baseName(wb.root))" : "Select the task to run"),
            query: $query,
            items: items.filter { q.isEmpty || $0.label.lowercased().contains(q) },
            row: { t in
                AnyView(HStack(spacing: 6) {
                    CodiconView(icon: t.command.isEmpty ? .play : .tools, size: 14)
                    Text(t.label).font(.system(size: 13))
                    Text(t.detail).font(.system(size: 12)).foregroundStyle(wb.theme.descriptionFg).lineLimit(1)
                })
            },
            pick: { t in
                wb.taskPicker = false
                if t.command.isEmpty { wb.runActiveFile() } else { wb.run(t) }
            },
            dismiss: { wb.taskPicker = false })
        .task {
            tasks = await wb.detectTasks()
            loading = false
        }
    }
}

// MARK: - Ports & preview

extension Workbench {
    /// Forwards the desktop port through the tunnel and opens it in a browser tab.
    func preview(port: UInt16, path: String = "/") {
        guard let d = desktop else { return }
        Task {
            do {
                let local: UInt16
                if let existing = forwards[port] { local = existing } else {
                    local = try await d.forwardPort(port: port)
                    forwards[port] = local
                }
                let tab = "port:\(port)"
                let url = "http://127.0.0.1:\(local)\(path)"
                if let i = files.firstIndex(where: { $0.path == tab }) {
                    files[i].text = url
                    files[i].revision += 1
                } else {
                    files.append(OpenFile(path: tab, original: Data(), text: url, crlf: false, viewer: .browser))
                }
                active = tab
            } catch {
                alert = "Couldn't forward port \(port): \(error.localizedDescription)"
            }
        }
    }
}

/// VS Code's PORTS view: what's listening on the desktop, one tap to preview.
struct PortsView: View {
    @EnvironmentObject var wb: Workbench
    @State private var ports: [PortInfo] = []
    @State private var loaded = false
    @State private var manual = ""

    var body: some View {
        let t = wb.theme
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Forward a port:").font(.system(size: 12)).foregroundStyle(t.descriptionFg)
                TextField("3000", text: $manual)
                    .textFieldStyle(.plain).font(.system(size: 12)).keyboardType(.numberPad)
                    .padding(4).frame(width: 70).background(t.inputBg)
                    .onSubmit { if let p = UInt16(manual) { wb.preview(port: p) } }
                Button("Preview") { if let p = UInt16(manual) { wb.preview(port: p) } }
                    .font(.system(size: 12)).disabled(UInt16(manual) == nil)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if loaded && ports.isEmpty {
                Text("Nothing is listening on \(wb.machine.name). Start a dev server (npm run dev, python3 -m http.server…) and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(t.descriptionFg).padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ports, id: \.port) { p in
                        HStack(spacing: 10) {
                            Circle().fill(wb.forwards[p.port] != nil ? SwiftUI.Color.green : SwiftUI.Color.gray).frame(width: 7, height: 7)
                            Text(verbatim: "\(p.port)").font(.custom("Menlo", size: 13)).frame(width: 60, alignment: .leading)
                            Text(p.process.isEmpty ? "—" : p.process).font(.system(size: 13)).foregroundStyle(t.descriptionFg)
                            Spacer()
                            Button { wb.preview(port: p.port) } label: {
                                HStack(spacing: 3) { CodiconView(icon: .openPreview, size: 13); Text("Preview").font(.system(size: 12)) }
                            }
                            .buttonStyle(LinkButtonStyle(hover: t.linkHoverFg)).foregroundStyle(t.highlightFg)
                        }
                        .padding(.horizontal, 12).frame(height: 26)
                        .hoverBackground(t.listHoverBg)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { wb.preview(port: p.port) }
                    }
                }
            }
        }
        .foregroundStyle(t.panelTitleActiveFg)
        .task {
            while !Task.isCancelled {
                if let d = wb.desktop { ports = (try? await d.listeningPorts()) ?? ports }
                loaded = true
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

/// VS Code's Simple Browser, for previewing desktop ports.
struct BrowserView: View {
    let file: OpenFile
    @EnvironmentObject var wb: Workbench
    @StateObject private var model = BrowserModel()
    @State private var address = ""

    var body: some View {
        let t = wb.theme
        let port = file.path.replacingOccurrences(of: "port:", with: "")
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.web.goBack() } label: { CodiconView(icon: .arrowLeft, size: 15) }.disabled(!model.canGoBack)
                Button { model.web.goForward() } label: { CodiconView(icon: .arrowRight, size: 15) }.disabled(!model.canGoForward)
                Button { model.web.reload() } label: { CodiconView(icon: .refresh, size: 15) }
                HStack(spacing: 4) {
                    Text(verbatim: "localhost:\(port)").font(.system(size: 12)).foregroundStyle(t.descriptionFg)
                    TextField("/", text: $address)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { wb.preview(port: UInt16(port) ?? 0, path: address.hasPrefix("/") ? address : "/" + address) }
                }
                .padding(.horizontal, 6).frame(height: 24).background(t.inputBg).clipShape(RoundedRectangle(cornerRadius: 4))
                if model.loading { ProgressView().scaleEffect(0.6) }
            }
            .buttonStyle(.plain).foregroundStyle(t.tabActiveFg)
            .padding(.horizontal, 10).frame(height: 32)
            .background(t.ui("editorWidget.background", default: "#252526"))
            WebHost(web: model.web)
        }
        .onAppear { model.load(file.text) }
        .onChange(of: file.revision) { model.load(file.text) }
        .onChange(of: model.path) { _, p in address = p }
    }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let web = WKWebView()
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var path = ""
    private var lastURL = ""

    override init() {
        super.init()
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
    }

    func load(_ s: String) {
        guard s != lastURL, let url = URL(string: s) else { return }
        lastURL = s
        web.load(URLRequest(url: url))
    }

    private func update() {
        canGoBack = web.canGoBack
        canGoForward = web.canGoForward
        loading = web.isLoading
        if let u = web.url { path = u.path + (u.query.map { "?" + $0 } ?? "") }
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { update() }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { update() }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { update() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        update()
        w.loadHTMLString("<body style='font:15px -apple-system;color:#999;background:#1e1e1e;padding:40px'>Couldn't load the page: \(e.localizedDescription).<br>Is the server still running on the desktop?</body>", baseURL: nil)
    }
}

private struct WebHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
