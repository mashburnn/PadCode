import SwiftUI

/// VS Code's "Open Folder or File" dialog for remote windows: a path box that
/// browses the desktop as you type (the part after the last separator filters
/// the folder's entries), plus recent folders.
struct FolderPicker: View {
    @EnvironmentObject var wb: Workbench
    @State private var text = ""
    @State private var dir = ""
    @State private var entries: [Entry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showHidden = false
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var sep: String { wb.env?.os == .windows ? "\\" : "/" }

    /// Splits the box into (folder to list, filter text).
    private var parts: (base: String, leaf: String) {
        guard let cut = text.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return (dir, text) }
        var base = String(text[..<cut])
        if base.isEmpty { base = "/" } else if base.hasSuffix(":") { base += "\\" }
        return (base, String(text[text.index(after: cut)...]))
    }

    private var matches: [Entry] {
        let leaf = parts.leaf.lowercased()
        return entries.filter { e in
            (showHidden || leaf.hasPrefix(".") || !e.name.hasPrefix("."))
                && (leaf.isEmpty || e.name.lowercased().hasPrefix(leaf))
        }
    }

    private var recents: [String] {
        parts.leaf.isEmpty && dir == wb.env?.home ? wb.recentFolders : []
    }

    var body: some View {
        let t = wb.theme
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Open Folder or File").font(.system(size: 12, weight: .semibold))
                Spacer()
                iconButton(.arrowUp, "Parent folder") { text = parent(dir) + sep }
                iconButton(showHidden ? .eye : .eyeClosed, showHidden ? "Hide dotfiles" : "Show dotfiles") { showHidden.toggle() }
                iconButton(.home, "Home") { text = (wb.env?.home ?? "/") + sep }
                if !wb.root.isEmpty { iconButton(.close, "Cancel") { wb.picker = false } }
            }
            .foregroundStyle(t.quickInputFg)
            .padding(.horizontal, 10).padding(.top, 8)

            HStack(spacing: 6) {
                TextField("Path", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(rowCount - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { if !wb.root.isEmpty { wb.picker = false }; return .handled }
                    .onKeyPress(.tab) { complete(); return .handled }
                    .onChange(of: text) { selection = 0 }
                Button("Open") { openCurrent() }
                    .buttonStyle(.borderedProminent).tint(t.buttonBg).controlSize(.small)
            }
            .padding(6).background(t.inputBg).foregroundStyle(t.inputFg)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(t.focusBorder))
            .padding(8)

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(t.errorFg).padding(.horizontal, 12).padding(.bottom, 6)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !recents.isEmpty {
                            sectionLabel("recently opened")
                            ForEach(Array(recents.enumerated()), id: \.element) { i, path in
                                row(index: i, selected: i == selection) {
                                    CodiconView(icon: .history, size: 14)
                                    Text(wb.baseName(path)).font(.system(size: 13))
                                    Text(path).font(.system(size: 12)).foregroundStyle(t.descriptionFg).lineLimit(1)
                                } action: { wb.openFolder(path) }
                            }
                            sectionLabel(dir)
                        }
                        if loading && entries.isEmpty {
                            ProgressView().padding(12)
                        }
                        ForEach(Array(matches.enumerated()), id: \.element.name) { i, e in
                            let index = recents.count + i
                            row(index: index, selected: index == selection) {
                                if e.kind == .dir {
                                    CodiconView(icon: .folder, size: 14).frame(width: 18)
                                } else {
                                    FileIcon(name: e.name, size: 14)
                                }
                                Text(e.name).font(.system(size: 13))
                                if e.kind == .dir { Text(sep).font(.system(size: 13)).foregroundStyle(t.descriptionFg) }
                            } action: { pick(e) }
                        }
                    }
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            .frame(maxHeight: 440)
            .foregroundStyle(t.quickInputFg)
        }
        .frame(width: 640)
        .glass(t.quickInputBg, radius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.widgetBorder))
        .shadow(color: .black.opacity(t.isDark ? 0.4 : 0.15), radius: 30, y: 14)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: parts.base) { await load(parts.base) }
        .onAppear {
            if text.isEmpty { text = (wb.env?.home ?? "/") + sep }
            focused = true
        }
    }

    private var rowCount: Int { recents.count + matches.count }

    private func row(index: Int, selected: Bool, @ViewBuilder label: () -> some View, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) { label() }
            .padding(.horizontal, 12).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? wb.theme.listActiveBg : .clear)
            .hoverBackground(selected ? .clear : wb.theme.listHoverBg)
            .foregroundStyle(selected ? wb.theme.listActiveFg : wb.theme.quickInputFg)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .id(index)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(wb.theme.descriptionFg).lineLimit(1)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
    }

    private func iconButton(_ icon: Codicon, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { CodiconView(icon: icon, size: 16) }
            .buttonStyle(.plain).tip(label)
    }

    private func load(_ path: String) async {
        guard let d = wb.desktop, path != dir || entries.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            entries = try await d.listDir(path: path)
            dir = path
            error = nil
        } catch {
            self.error = "Can't open \(path): \(error.localizedDescription)"
        }
    }

    private func parent(_ path: String) -> String {
        let p = wb.parentDir(path)
        return p.hasSuffix(":") ? p + "\\" : p
    }

    private func pick(_ e: Entry) {
        let path = wb.desktop?.join(base: dir, name: e.name) ?? e.name
        if e.kind == .dir {
            text = path + sep
        } else {
            Task { await wb.openFileFromPicker(path) }
            wb.picker = false
        }
    }

    /// Tab: complete to the single (or common-prefix) match, like a shell.
    private func complete() {
        let m = matches
        guard let first = m.first else { return }
        if m.count == 1 { pick(first); return }
        var prefix = first.name
        for e in m.dropFirst() {
            while !e.name.lowercased().hasPrefix(prefix.lowercased()) { prefix.removeLast() }
        }
        if prefix.count > parts.leaf.count {
            text = (wb.desktop?.join(base: dir, name: prefix) ?? prefix)
        }
    }

    /// Enter: act on the highlighted row, or open the folder in the box.
    private func submit() {
        if selection < recents.count {
            wb.openFolder(recents[selection])
        } else if !parts.leaf.isEmpty, matches.indices.contains(selection - recents.count) {
            pick(matches[selection - recents.count])
        } else {
            openCurrent()
        }
    }

    /// Opens the folder shown in the box (or the file/folder its last part names).
    private func openCurrent() {
        let leaf = parts.leaf
        if !leaf.isEmpty, let e = entries.first(where: { $0.name == leaf }) {
            let path = wb.desktop?.join(base: dir, name: e.name) ?? leaf
            if e.kind == .dir { wb.openFolder(path) } else { pick(e) }
        } else if leaf.isEmpty, parts.base == dir {
            wb.openFolder(dir)
        } else {
            error = "No such folder: \(text)"
        }
    }
}
