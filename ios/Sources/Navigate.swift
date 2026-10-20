import SwiftUI

/// Codicon + VS Code color key for an LSP SymbolKind.
func symbolIcon(_ kind: UInt8) -> (Codicon, String) {
    switch kind {
    case 1: (.symbolFile, "symbolIcon.fileForeground")
    case 2, 3, 4: (.symbolNamespace, "symbolIcon.moduleForeground")
    case 5: (.symbolClass, "symbolIcon.classForeground")
    case 6, 9, 12: (.symbolMethod, "symbolIcon.methodForeground")
    case 7: (.symbolProperty, "symbolIcon.propertyForeground")
    case 8: (.symbolField, "symbolIcon.fieldForeground")
    case 10: (.symbolEnum, "symbolIcon.enumeratorForeground")
    case 11: (.symbolInterface, "symbolIcon.interfaceForeground")
    case 13: (.symbolVariable, "symbolIcon.variableForeground")
    case 14: (.symbolConstant, "symbolIcon.constantForeground")
    case 22: (.symbolEnumMember, "symbolIcon.enumeratorMemberForeground")
    case 23: (.symbolStruct, "symbolIcon.structForeground")
    case 24: (.symbolEvent, "symbolIcon.eventForeground")
    case 25: (.symbolOperator, "symbolIcon.operatorForeground")
    case 26: (.symbolTypeParameter, "symbolIcon.typeParameterForeground")
    default: (.symbolMisc, "symbolIcon.textForeground")
    }
}

/// Loads the active file's outline and refreshes it as the file changes.
@MainActor
final class OutlineModel: ObservableObject {
    @Published var symbols: [DocSymbol] = []
    @Published var message: String?
    @Published var loading = false

    func load(_ wb: Workbench) async {
        guard let f = wb.activeFile, f.viewer == .text else {
            symbols = []
            message = "The active editor cannot provide outline information."
            return
        }
        loading = true
        defer { loading = false }
        // A server may still be starting; give it a moment.
        for attempt in 0..<10 {
            if let s = await wb.languages.symbols(f.path) {
                symbols = s
                message = s.isEmpty ? "No symbols found in document '\(f.name)'." : nil
                return
            }
            if wb.languages.languageId(for: f.path) == nil || wb.languages.missing[Language.id(for: f.path) ?? ""] != nil { break }
            // Cancelled (the next keystroke restarts this): stop, don't fire the remaining tries at once.
            guard (try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))) != nil else { return }
        }
        symbols = []
        message = "No outline: \(f.name) has no language server on \(wb.machine.name)."
    }
}

/// VS Code's OUTLINE view (sidebar).
struct OutlineView: View {
    @EnvironmentObject var wb: Workbench
    @EnvironmentObject var status: EditorStatus
    @StateObject private var model = OutlineModel()

    var body: some View {
        let t = wb.theme
        let caretLine = status.line - 1
        // Innermost symbol containing the caret is highlighted, like VS Code's "follow cursor".
        let current = model.symbols.lastIndex { Int($0.range.start.line) <= caretLine && caretLine <= Int($0.range.end.line) }
        VStack(alignment: .leading, spacing: 0) {
            SideHeader(title: "OUTLINE") {
                Button { Task { await model.load(wb) } } label: { CodiconView(icon: .refresh) }
            }
            if let m = model.message {
                Text(m).font(.system(size: 12)).foregroundStyle(t.descriptionFg).padding(.horizontal, 20).padding(.top, 4)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.symbols.enumerated()), id: \.offset) { i, sym in
                        let (icon, color) = symbolIcon(sym.kind)
                        HStack(spacing: 5) {
                            CodiconView(icon: icon, size: 14).foregroundStyle(t.ui(color, default: "#cccccc"))
                            Text(sym.name).font(.system(size: 13)).lineLimit(1)
                            if let d = sym.detail { Text(d).font(.system(size: 12)).foregroundStyle(t.descriptionFg).lineLimit(1) }
                            Spacer()
                        }
                        .padding(.leading, CGFloat(sym.depth) * 12 + 16)
                        .frame(height: 22)
                        .background(i == current ? t.listActiveBg : .clear)
                        .hoverBackground(i == current ? .clear : t.listHoverBg)
                        .foregroundStyle(i == current ? t.listActiveFg : t.sideBarFg)
                        .contentShape(Rectangle())
                        .onTapGesture { reveal(sym) }
                    }
                }
            }
        }
        .task(id: "\(wb.active ?? "")#\(wb.activeFile?.revision ?? 0)#\(status.edits)") {
            // Debounce: refresh after edits settle.
            guard (try? await Task.sleep(for: .milliseconds(model.symbols.isEmpty ? 0 : 700))) != nil else { return }
            await model.load(wb)
        }
    }

    private func reveal(_ s: DocSymbol) {
        guard let p = wb.active else { return }
        Task { await wb.open(p, line: Int(s.selection.start.line) + 1, column: Int(s.selection.start.character)) }
    }
}

/// Go to Symbol in Editor (⇧⌘O).
struct SymbolPicker: View {
    @EnvironmentObject var wb: Workbench
    @StateObject private var model = OutlineModel()
    @State private var query = ""

    struct Item: Identifiable {
        let id: Int
        let symbol: DocSymbol
    }

    var body: some View {
        QuickPickList(
            placeholder: model.loading ? "Loading symbols…" : (model.message ?? "Go to symbol in editor"),
            query: $query,
            items: matches,
            row: { item in
                let (icon, color) = symbolIcon(item.symbol.kind)
                return AnyView(HStack(spacing: 6) {
                    CodiconView(icon: icon, size: 14).foregroundStyle(wb.theme.ui(color, default: "#cccccc"))
                    Text(item.symbol.name).font(.system(size: 13))
                    if let d = item.symbol.detail { Text(d).font(.system(size: 12)).foregroundStyle(wb.theme.descriptionFg).lineLimit(1) }
                    Spacer()
                    Text("\(item.symbol.selection.start.line + 1)").font(.system(size: 11)).foregroundStyle(wb.theme.descriptionFg)
                })
            },
            pick: { item in
                wb.symbolPicker = false
                guard let p = wb.active else { return }
                Task { await wb.open(p, line: Int(item.symbol.selection.start.line) + 1, column: Int(item.symbol.selection.start.character)) }
            },
            dismiss: { wb.symbolPicker = false })
        .task { await model.load(wb) }
    }

    private var matches: [Item] {
        let q = query.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        return model.symbols.enumerated()
            .filter { q.isEmpty || $0.element.name.lowercased().contains(q) }
            .map { Item(id: $0.offset, symbol: $0.element) }
    }
}

/// Go to Symbol in Workspace.
struct WorkspaceSymbolPicker: View {
    @EnvironmentObject var wb: Workbench
    @State private var query = ""
    @State private var results: [WorkspaceSymbol] = []
    @State private var searching = false

    struct Item: Identifiable {
        let id: Int
        let symbol: WorkspaceSymbol
    }

    var body: some View {
        QuickPickList(
            placeholder: searching ? "Searching…" : query.isEmpty ? "Type to search symbols in the workspace"
                : results.isEmpty ? "No matching symbols" : "Go to symbol in workspace",
            query: $query,
            items: results.prefix(200).enumerated().map { Item(id: $0.offset, symbol: $0.element) },
            row: { item in
                let s = item.symbol
                let (icon, color) = symbolIcon(s.kind)
                return AnyView(HStack(spacing: 6) {
                    CodiconView(icon: icon, size: 14).foregroundStyle(wb.theme.ui(color, default: "#cccccc"))
                    Text(s.name).font(.system(size: 13))
                    if let c = s.container { Text(c).font(.system(size: 12)).foregroundStyle(wb.theme.descriptionFg).lineLimit(1) }
                    Spacer()
                    Text(wb.relative(s.path)).font(.system(size: 11)).foregroundStyle(wb.theme.descriptionFg).lineLimit(1).truncationMode(.head)
                })
            },
            pick: { item in
                wb.workspaceSymbolPicker = false
                let s = item.symbol
                Task { await wb.open(s.path, line: Int(s.selection.start.line) + 1, column: Int(s.selection.start.character)) }
            },
            dismiss: { wb.workspaceSymbolPicker = false })
        .task(id: query) {
            let q = query.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard !q.isEmpty else { results = []; return }
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return } // typing
            searching = true
            let found = await wb.languages.workspaceSymbols(q)
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }
}

/// Go to Line (⌃G): "42" or "42:7".
struct GotoLinePicker: View {
    @EnvironmentObject var wb: Workbench
    @State private var query = ""

    struct Item: Identifiable {
        let id = 0
        let line: Int
        let column: Int?
    }

    var body: some View {
        let lines = (wb.activeFile?.text.split(separator: "\n", omittingEmptySubsequences: false).count) ?? 0
        let current = wb.activeFile?.cursor ?? (line: 1, column: 1)
        QuickPickList(
            placeholder: "Go to line 1–\(lines)  (current: \(current.line):\(current.column)). Type a line, or line:column",
            query: $query,
            items: parsed.map { [$0] } ?? [],
            row: { item in AnyView(Text("Go to line \(item.line)\(item.column.map { ", column \($0)" } ?? "")").font(.system(size: 13))) },
            pick: { item in
                wb.gotoLine = false
                guard let p = wb.active else { return }
                Task { await wb.open(p, line: min(max(item.line, 1), max(lines, 1)), column: item.column.map { max($0 - 1, 0) }) }
            },
            dismiss: { wb.gotoLine = false })
    }

    private var parsed: Item? {
        let parts = query.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).split(separator: ":")
        guard let first = parts.first, let line = Int(first) else { return nil }
        return Item(line: line, column: parts.count > 1 ? Int(parts[1]) : nil)
    }
}
