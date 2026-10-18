import SwiftUI

/// VS Code's Explorer view: a lazily loaded tree of the open folder, with
/// drag and drop to move files and folders.
struct ExplorerView: View {
    @EnvironmentObject var wb: Workbench
    @State private var newItem: (parent: String, isDir: Bool)?
    @State private var newName = ""
    @State private var rootTargeted = false

    var body: some View {
        let t = wb.theme
        VStack(alignment: .leading, spacing: 0) {
            SideHeader(title: "EXPLORER") {
                if !wb.root.isEmpty {
                    Button { wb.uploadTarget = wb.root } label: { CodiconView(icon: .cloudUpload) }
                        .tip("Upload from iPad")
                    Button { newItem = (wb.root, false) } label: { CodiconView(icon: .newFile) }.tip("New File…")
                    Button { newItem = (wb.root, true) } label: { CodiconView(icon: .newFolder) }.tip("New Folder…")
                    Button { wb.explorerGeneration += 1 } label: { CodiconView(icon: .refresh) }.tip("Refresh Explorer")
                }
                Button { wb.picker = true } label: { CodiconView(icon: .folderOpened) }.tip("Open Folder…")
            }
            if wb.root.isEmpty {
                noFolder(t)
            } else {
                HStack(spacing: 4) {
                    CodiconView(icon: .chevronDown, size: 14)
                    Text(wb.baseName(wb.root).uppercased()).font(.system(size: 11, weight: .bold)).lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(t.sideBarTitleFg)
                .padding(.horizontal, 4).frame(height: 22)
                .background(rootTargeted ? t.dropBg : t.sectionHeaderBg)
                .onDrop(of: [.item], isTargeted: $rootTargeted) { handleDrop($0, into: wb.root, wb: wb) }

                if wb.desktop != nil {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            FolderChildren(path: wb.root, depth: 0, newItem: $newItem)
                        }
                        .id(wb.root)
                        // Empty space below the tree also drops into the root folder.
                        Color.clear.frame(height: 120).contentShape(Rectangle())
                            .onDrop(of: [.item], isTargeted: nil) { handleDrop($0, into: wb.root, wb: wb) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .alert(newItem?.isDir == true ? "New Folder" : "New File", isPresented: Binding(get: { newItem != nil }, set: { if !$0 { newItem = nil } })) {
            TextField("name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .onChange(of: wb.newFileRequest, initial: true) {
            guard wb.newFileRequest, !wb.root.isEmpty else { return }
            wb.newFileRequest = false
            // Next to the active file when it's inside the folder, like VS Code.
            let dir = wb.active.map { ($0 as NSString).deletingLastPathComponent } ?? wb.root
            newItem = (dir.hasPrefix(wb.root) ? dir : wb.root, false)
        }
        .alert(moveTitle, isPresented: Binding(get: { wb.pendingMove != nil }, set: { if !$0 { wb.pendingMove = nil } })) {
            Button("Move") {
                if let m = wb.pendingMove { Task { await wb.move(m.from, toDir: m.toDir) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var moveTitle: String {
        guard let m = wb.pendingMove else { return "" }
        return "Are you sure you want to move '\(wb.baseName(m.from))' into '\(wb.baseName(m.toDir))'?"
    }

    private func noFolder(_ t: VSTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You have not yet opened a folder.").font(.system(size: 13))
            Button { wb.picker = true } label: {
                Text("Open Folder").font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(t.buttonBg)
            ForEach(wb.recentFolders.prefix(5), id: \.self) { path in
                Button { wb.openFolder(path) } label: {
                    HStack(spacing: 6) {
                        CodiconView(icon: .history, size: 13)
                        Text(wb.baseName(path)).font(.system(size: 13)).lineLimit(1)
                    }
                }
                .buttonStyle(LinkButtonStyle(hover: t.linkHoverFg)).foregroundStyle(t.highlightFg)
            }
        }
        .foregroundStyle(t.sideBarFg)
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private func create() {
        guard let item = newItem, let d = wb.desktop else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        Task { await wb.createItem(name, in: item.parent, isDir: item.isDir, desktop: d) }
    }
}

private struct FolderChildren: View {
    let path: String
    let depth: Int
    @Binding var newItem: (parent: String, isDir: Bool)?
    @EnvironmentObject var wb: Workbench
    @State private var entries: [Entry]?
    @State private var error: String?

    var body: some View {
        Group {
            if let entries {
                ForEach(entries, id: \.name) { e in
                    TreeRow(entry: e, parent: path, depth: depth, newItem: $newItem)
                }
            } else if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(wb.theme.errorFg)
                    .padding(.leading, CGFloat(depth) * 8 + 24).frame(height: 22)
            } else {
                ProgressView().scaleEffect(0.6).padding(.leading, CGFloat(depth) * 8 + 20).frame(height: 22)
            }
        }
        // Re-lists on refresh/move while keeping which folders are expanded,
        // then polls so files created or deleted on the desktop show up.
        // ponytail: one listing per expanded folder every 3 s; the CLI has no watch API.
        .task(id: wb.explorerGeneration) {
            guard let d = wb.desktop else { return }
            do {
                entries = try await d.listDir(path: path)
                error = nil
                wb.learnSizes(in: path, entries ?? [])
            } catch { self.error = error.localizedDescription }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let d = wb.desktop, let fresh = try? await d.listDir(path: path) else { continue }
                if fresh != entries { entries = fresh }
            }
        }
    }
}

private struct TreeRow: View {
    let entry: Entry
    let parent: String
    let depth: Int
    @Binding var newItem: (parent: String, isDir: Bool)?
    @EnvironmentObject var wb: Workbench
    @EnvironmentObject var languages: Languages
    @State private var expanded = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var targeted = false

    var body: some View {
        let t = wb.theme
        let path = wb.desktop?.join(base: parent, name: entry.name) ?? entry.name
        let isDir = entry.kind == .dir
        let selected = wb.active == path
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if isDir {
                    CodiconView(icon: expanded ? .chevronDown : .chevronRight, size: 16).frame(width: 16)
                } else {
                    Color.clear.frame(width: 16)
                    FileIcon(name: entry.name, size: 16)
                }
                let problems = languages.problemSummary(for: path, folder: isDir)
                Text(entry.name).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(problems.errors > 0 ? t.ui("list.errorForeground", default: "#f88070")
                                     : problems.warnings > 0 ? t.ui("list.warningForeground", default: "#cca700")
                                     : selected ? t.listActiveFg : t.sideBarFg)
                Spacer()
                // VS Code's problem decoration: a count on files, a dot on folders.
                if problems.errors + problems.warnings > 0 {
                    Text(isDir ? "●" : "\(problems.errors + problems.warnings)")
                        .font(.system(size: isDir ? 8 : 11))
                        .foregroundStyle(problems.errors > 0 ? t.ui("list.errorForeground", default: "#f88070")
                                         : t.ui("list.warningForeground", default: "#cca700"))
                        .padding(.trailing, 10)
                }
            }
            .foregroundStyle(selected ? t.listActiveFg : t.sideBarFg)
            .padding(.leading, CGFloat(depth) * 8 + 4)
            .frame(height: 22)
            .background(targeted ? t.dropBg : selected ? t.listActiveBg : .clear)
            .hoverBackground(selected || targeted ? .clear : t.listHoverBg)
            .contentShape(Rectangle())
            .onTapGesture {
                if isDir { expanded.toggle() } else { Task { await wb.open(path) } }
            }
            // Long-press and drag a row; drop on a folder (or on a file, meaning
            // its folder) to move it there, like the desktop Explorer.
            .draggable(path) {
                HStack(spacing: 4) {
                    if isDir { CodiconView(icon: .folder, size: 14) } else { FileIcon(name: entry.name, size: 14) }
                    Text(entry.name).font(.system(size: 13))
                }
                .padding(6).background(t.listActiveBg).foregroundStyle(t.listActiveFg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .onDrop(of: [.item], isTargeted: $targeted) { handleDrop($0, into: isDir ? path : parent, wb: wb) }
            .contextMenu {
                if isDir {
                    Button("New File…") { newItem = (path, false) }
                    Button("New Folder…") { newItem = (path, true) }
                    Button("Upload from iPad…") { wb.uploadTarget = path }
                    Button("Open in Integrated Terminal") { wb.newTerminal(cwd: path) }
                    Button("Open as Folder") { wb.openFolder(path) }
                    Button("Open in New Window") { wb.openInNewWindow(path) }
                }
                Button("Rename…") { newName = entry.name; renaming = true }
                if !isDir {
                    Button("Download to iPad…") { wb.download(path) }
                    if wb.groups.count > 1 || wb.active != nil {
                        Button("Open to the Side") { Task { await wb.openToSide(path) } }
                    }
                }
                Button("Copy Path") { UIPasteboard.general.string = path }
                Button("Copy Relative Path") { UIPasteboard.general.string = wb.relative(path) }
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await wb.desktop?.remove(path: path)
                            for f in wb.files where wb.isWithin(f.path, path) { wb.closeEverywhere(f.path) }
                            wb.explorerGeneration += 1
                        } catch { wb.alert = error.localizedDescription }
                    }
                }
            }
            if isDir && expanded {
                FolderChildren(path: path, depth: depth + 1, newItem: $newItem)
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") {
                guard let d = wb.desktop, !newName.isEmpty else { return }
                let to = d.join(base: parent, name: newName)
                Task { await wb.relocate(path, to: to) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

enum SearchReplace {
    /// Replaces matches only on the given 1-based lines; returns text and count.
    static func apply(_ text: String, lines: Set<Int>, pattern re: NSRegularExpression, template: String) -> (String, Int) {
        var count = 0
        let out = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { i, line -> String in
            let l = String(line)
            guard lines.contains(i + 1) else { return l }
            let range = NSRange(location: 0, length: (l as NSString).length)
            let n = re.numberOfMatches(in: l, range: range)
            guard n > 0 else { return l }
            count += n
            return re.stringByReplacingMatches(in: l, range: range, withTemplate: template)
        }.joined(separator: "\n")
        return (out, count)
    }
}

/// VS Code's Search view: find (and replace) across the open folder, with
/// Match Case / Whole Word / Regex toggles.
struct SearchView: View {
    @EnvironmentObject var wb: Workbench
    @State private var query = ""
    @State private var replacement = ""
    @State private var hits: [Hit] = []
    @State private var searching = false
    @State private var message: String?
    @State private var matchCase = false
    @State private var wholeWord = false
    @State private var regex = false
    @State private var confirmAll = false
    @State private var dismissed: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        let t = wb.theme
        VStack(alignment: .leading, spacing: 6) {
            SideHeader(title: "SEARCH") {
                Button { run() } label: { CodiconView(icon: .refresh) }.tip("Refresh")
                Button { hits = []; query = ""; replacement = ""; message = nil; dismissed = [] } label: { CodiconView(icon: .clearAll) }.tip("Clear Search Results")
            }
            HStack(alignment: .top, spacing: 2) {
                Button { wb.replaceMode.toggle() } label: {
                    CodiconView(icon: wb.replaceMode ? .chevronDown : .chevronRight, size: 14).frame(width: 18, height: 26)
                }
                .buttonStyle(ToolbarButtonStyle(padding: 0)).foregroundStyle(t.sideBarFg)
                VStack(spacing: 4) {
                    field("Search", text: $query) {
                        toggle(.caseSensitive, "Match Case", $matchCase)
                        toggle(.wholeWord, "Match Whole Word", $wholeWord)
                        toggle(.regex, "Use Regular Expression", $regex)
                    }
                    .focused($focused)
                    .onSubmit(run)
                    if wb.replaceMode {
                        HStack(spacing: 4) {
                            field("Replace", text: $replacement) { EmptyView() }
                            Button { confirmAll = true } label: { CodiconView(icon: .replaceAll, size: 16) }
                                .buttonStyle(ToolbarButtonStyle()).foregroundStyle(t.sideBarFg)
                                .disabled(visibleHits.isEmpty)
                                .tip("Replace All")
                        }
                    }
                }
            }
            .padding(.leading, 6).padding(.trailing, 12)
            if searching { ProgressView().padding(.horizontal, 12) }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(t.descriptionFg).padding(.horizontal, 12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.0) { file, fileHits in
                        HStack(spacing: 4) {
                            FileIcon(name: file, size: 14)
                            Text((file as NSString).lastPathComponent).font(.system(size: 13))
                            Text((file as NSString).deletingLastPathComponent).font(.system(size: 12))
                                .foregroundStyle(t.descriptionFg).lineLimit(1)
                            Spacer()
                            if wb.replaceMode {
                                Button { Task { await replace(in: [file]) } } label: { CodiconView(icon: .replaceAll, size: 13) }
                                    .buttonStyle(ToolbarButtonStyle(padding: 2)).tip("Replace All in File")
                            }
                            Text("\(fileHits.count)").font(.system(size: 11)).padding(.horizontal, 5)
                                .background(t.activityBadgeBg).clipShape(Capsule())
                        }
                        .padding(.horizontal, 12).frame(height: 22)
                        ForEach(Array(fileHits.enumerated()), id: \.offset) { _, h in
                            hitRow(h, t)
                        }
                    }
                }
            }
            .foregroundStyle(t.sideBarFg)
        }
        .onAppear { focused = true }
        .onChange(of: matchCase) { if !query.isEmpty { run() } }
        .onChange(of: wholeWord) { if !query.isEmpty { run() } }
        .onChange(of: regex) { if !query.isEmpty { run() } }
        .alert("Replace All", isPresented: $confirmAll) {
            Button("Replace") { Task { await replace(in: Set(visibleHits.map(\.path)).sorted()) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replace \(visibleHits.count) occurrence\(visibleHits.count == 1 ? "" : "s") across \(Set(visibleHits.map(\.path)).count) file\(Set(visibleHits.map(\.path)).count == 1 ? "" : "s") with '\(replacement)'?")
        }
    }

    // MARK: rows & fields

    private func hitRow(_ h: Hit, _ t: VSTheme) -> some View {
        let text = h.text.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 4) {
            if wb.replaceMode, !replacement.isEmpty || !query.isEmpty, let preview = replacedLine(text) {
                (Text(text).strikethrough().foregroundColor(t.descriptionFg) + Text("  →  ") + Text(preview).foregroundColor(t.highlightFg))
                    .font(.system(size: 13)).lineLimit(1)
            } else {
                Text(text).font(.system(size: 13)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { dismissed.insert(key(h)) } label: { CodiconView(icon: .close, size: 12) }
                .buttonStyle(ToolbarButtonStyle(padding: 2)).foregroundStyle(t.descriptionFg).tip("Dismiss")
        }
        .padding(.leading, 32).padding(.trailing, 10).frame(height: 22, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverBackground(t.listHoverBg)
        .contentShape(Rectangle())
        .onTapGesture { Task { await wb.open(wb.absolute(h.path), line: Int(h.line)) } }
    }

    private func field<Trailing: View>(_ prompt: String, text: Binding<String>, @ViewBuilder trailing: () -> Trailing) -> some View {
        let t = wb.theme
        return HStack(spacing: 2) {
            TextField(prompt, text: text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            trailing()
        }
        .padding(.horizontal, 6).frame(height: 26)
        .background(t.inputBg).foregroundStyle(t.inputFg)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(t.inputBorder))
    }

    private func toggle(_ icon: Codicon, _ label: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            CodiconView(icon: icon, size: 15)
                .frame(width: 22, height: 20)
                .background(on.wrappedValue ? wb.theme.ui("inputOption.activeBackground", default: "#007fd466") : .clear)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(on.wrappedValue ? wb.theme.ui("inputOption.activeBorder", "focusBorder", default: "#007acc") : .clear))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(ToolbarButtonStyle(padding: 0)).foregroundStyle(wb.theme.inputFg)
        .tip(label)
    }

    // MARK: search & replace

    private func key(_ h: Hit) -> String { "\(h.path):\(h.line)" }

    private var visibleHits: [Hit] { hits.filter { !dismissed.contains(key($0)) } }

    private var grouped: [(String, [Hit])] {
        var order: [String] = []
        var map: [String: [Hit]] = [:]
        for h in visibleHits {
            if map[h.path] == nil { order.append(h.path) }
            map[h.path, default: []].append(h)
        }
        return order.map { ($0, map[$0]!) }
    }

    /// The pattern the desktop search used, mirrored locally for replacing.
    private var pattern: NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var p = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { p = "\\b(?:\(p))\\b" }
        return try? NSRegularExpression(pattern: p, options: matchCase ? [] : [.caseInsensitive])
    }

    private var template: String {
        // Literal mode: the replacement is plain text, not a $1 template.
        regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    private func replacedLine(_ line: String) -> String? {
        guard let re = pattern else { return nil }
        let r = re.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: template)
        return r == line ? nil : r
    }

    private func run() {
        guard !query.isEmpty, let d = wb.desktop else { return }
        guard !wb.root.isEmpty else { message = "Open a folder to search in it."; return }
        if regex, pattern == nil { message = "Invalid regular expression."; return }
        searching = true
        message = nil
        dismissed = []
        let root = wb.root, q = query, mc = matchCase, ww = wholeWord, rx = regex
        Task {
            do {
                hits = try await d.search(root: root, query: q, max: 5000, matchCase: mc, wholeWord: ww, regex: rx)
                let files = Set(hits.map(\.path)).count
                message = hits.isEmpty ? "No results found." : "\(hits.count) results in \(files) files"
            } catch {
                message = error.localizedDescription
            }
            searching = false
        }
    }

    /// Rewrites each file on the desktop (or the open buffer, which then shows
    /// as modified, like VS Code). Only lines that are still listed are touched.
    private func replace(in relPaths: [String]) async {
        guard let re = pattern, let d = wb.desktop else { return }
        var replaced = 0, changedFiles = 0
        for rel in relPaths {
            let path = wb.absolute(rel)
            let lines = Set(visibleHits.filter { $0.path == rel }.map { Int($0.line) })
            let (text, wasOpen, crlf): (String, Bool, Bool)
            if let open = wb.file(path), open.viewer == .text {
                (text, wasOpen, crlf) = (open.text, true, false)
            } else {
                guard let data = try? await d.readFile(path: path), let s = String(data: data, encoding: .utf8) else { continue }
                (text, wasOpen, crlf) = (s.replacingOccurrences(of: "\r\n", with: "\n"), false, s.contains("\r\n"))
            }
            let (out, count) = SearchReplace.apply(text, lines: lines, pattern: re, template: template)
            guard count > 0 else { continue }
            if wasOpen {
                wb.setText(path, out)
            } else {
                let bytes = Data((crlf ? out.replacingOccurrences(of: "\n", with: "\r\n") : out).utf8)
                do { try await d.writeFile(path: path, data: bytes) } catch {
                    wb.alert = "Couldn't write \(rel): \(error.localizedDescription)"
                    continue
                }
            }
            replaced += count
            changedFiles += 1
        }
        hits.removeAll { relPaths.contains($0.path) }
        message = "Replaced \(replaced) occurrence\(replaced == 1 ? "" : "s") in \(changedFiles) file\(changedFiles == 1 ? "" : "s")."
            + (relPaths.contains { wb.file(wb.absolute($0)) != nil } ? " Open files are modified; save them to keep the changes." : "")
    }
}

struct SideHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    @EnvironmentObject var wb: Workbench
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11))
            Spacer()
            actions.buttonStyle(ToolbarButtonStyle())
        }
        .foregroundStyle(wb.theme.sideBarTitleFg)
        .padding(.leading, 20).padding(.trailing, 10)
        .frame(height: 35)
    }
}
