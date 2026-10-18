import SwiftUI

/// The iPadOS menu bar (swipe down from the top, or hold ⌘ to see shortcuts),
/// laid out like VS Code's menus. Acts on the focused window's workbench.
struct PadCommands: Commands {
    @FocusedObject private var wb: Workbench?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File…") { wb?.side = .explorer; wb?.newFileRequest = true }.keyboardShortcut("n").disabled(wb?.root.isEmpty ?? true)
            Button("New Window") { wb?.newWindow() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Terminal") { wb?.newTerminal() }.keyboardShortcut("`", modifiers: [.control, .shift]).disabled(wb?.desktop == nil)
            Divider()
            Button("Open Folder or File…") { wb?.picker = true }.keyboardShortcut("o").disabled(wb?.desktop == nil)
            Button("Close Folder") { wb?.closeFolder() }.disabled(wb?.root.isEmpty ?? true)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { Task { await wb?.save() } }.keyboardShortcut("s").disabled(wb?.activeFile?.viewer != .text)
            Button("Revert File") { if let p = wb?.active { Task { await wb?.revert(p) } } }.disabled(wb?.activeFile?.viewer != .text)
            Button("Close Editor") { if let a = wb?.active { wb?.close(a) } }.keyboardShortcut("w").disabled(wb?.active == nil)
            Button("Reopen Closed Editor") { wb?.reopenClosed() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Upload from iPad…") { wb?.uploadTarget = wb?.root }.disabled(wb?.root.isEmpty ?? true)
            Button("Download to iPad…") { if let p = wb?.active { wb?.download(p) } }.disabled(wb?.activeFile?.viewer != .text)
        }
        // Replacing (not adding after) the system's own ⌘, item: iPadOS throws on
        // duplicate shortcuts in the menu bar and the app dies at launch.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { wb?.settingsOpen = true }.keyboardShortcut(",").disabled(wb == nil)
        }
        // A code editor has no rich text or printing: frees ⌘B (sidebar) and ⌘P (go to file).
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Files") { wb?.side = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Replace in Files") { wb?.side = .search; wb?.replaceMode = true }.keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            // These keys are handled by the editor itself (they're editor-only).
            Button("Format Document   ⇧⌥F") { if let p = wb?.active { Task { await wb?.languages.format(p) } } }
            Button("Rename Symbol   F2") { wb?.languages.beginRename() }
            Button("Quick Fix…   ⌘.") { wb?.languages.showCodeActions() }
            Button("Trigger Suggest   ⌃Space") { wb?.languages.requestCompletion() }
        }
        CommandMenu("Selection") {
            // The editor handles these keys itself; the menu sends them to it.
            line("Toggle Line Comment   ⌘/", #selector(PadTextView.toggleComment))
            Divider()
            line("Copy Line Up   ⇧⌥↑", #selector(PadTextView.copyLinesUp))
            line("Copy Line Down   ⇧⌥↓", #selector(PadTextView.copyLinesDown))
            line("Move Line Up   ⌥↑", #selector(PadTextView.moveLinesUp))
            line("Move Line Down   ⌥↓", #selector(PadTextView.moveLinesDown))
            line("Delete Line   ⇧⌘K", #selector(PadTextView.deleteLines))
            Divider()
            line("Indent Line   ⌘]", #selector(PadTextView.indentLines))
            line("Outdent Line   ⌘[", #selector(PadTextView.outdentLines))
            line("Insert Line Below   ⌘↩", #selector(PadTextView.insertLineBelow))
            line("Insert Line Above   ⇧⌘↩", #selector(PadTextView.insertLineAbove))
        }
        CommandMenu("View") {
            Button("Command Palette…") { wb?.palette = true }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Explorer") { wb?.side = .explorer }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Search") { wb?.side = .search }
            Button("Outline") { wb?.side = .outline }
            Button("Problems") { wb?.panelOpen = true; wb?.panelTab = .problems }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Terminal") { wb?.toggleTerminal() }.keyboardShortcut("`", modifiers: .control)
            Button("Ports") { wb?.panelOpen = true; wb?.panelTab = .ports }
            Divider()
            Button("Toggle Primary Side Bar") { if let w = wb { w.side = w.side == nil ? .explorer : nil } }.keyboardShortcut("b")
            Button("Toggle Panel") { wb?.togglePanel() }.keyboardShortcut("j")
            Button("Split Editor Right") { wb?.splitRight() }.keyboardShortcut("\\")
            Divider()
            Button("Word Wrap") { AppSettings.shared.wordWrap.toggle() }.keyboardShortcut("z", modifiers: .option)
            Button("Zoom In") { if let w = wb { w.fontSize = min(w.fontSize + 1, 32) } }.keyboardShortcut("=")
            Button("Zoom Out") { if let w = wb { w.fontSize = max(w.fontSize - 1, 8) } }.keyboardShortcut("-")
        }
        CommandMenu("Go") {
            Button("Back") { wb?.goBack() }.keyboardShortcut("-", modifiers: .control)
            Button("Forward") { wb?.goForward() }.keyboardShortcut("-", modifiers: [.control, .shift])
            Divider()
            Button("Go to File…") { wb?.quickOpen = true }.keyboardShortcut("p")
            Button("Go to Symbol in Editor…") { if wb?.activeFile?.viewer == .text { wb?.symbolPicker = true } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Go to Line/Column…   ⌃G") { if wb?.activeFile?.viewer == .text { wb?.gotoLine = true } }
            Divider()
            Button("Go to Definition   F12") { wb?.languages.goToDefinition() }
            Button("Find All References   ⇧F12") { wb?.languages.findReferences() }
            Button("Show Hover   ⌘K ⌘I") { wb?.languages.showHover() }
            Divider()
            Button("Next Editor") { wb?.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Editor") { wb?.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("First Editor Group") { wb?.focusedGroup = 0 }.keyboardShortcut("1")
            Button("Second Editor Group") { if let w = wb { if w.groups.count > 1 { w.focusedGroup = 1 } else { w.splitRight() } } }.keyboardShortcut("2")
        }
        CommandMenu("Run") {
            Button("Run File   ⌃F5") { wb?.runActiveFile() }.disabled(wb?.activeFile?.viewer != .text)
            Button("Run Task…") { wb?.taskPicker = true }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(wb?.root.isEmpty ?? true)
        }
        CommandMenu("Terminal") {
            Button("New Terminal") { wb?.newTerminal() }.disabled(wb?.desktop == nil)
            Button("Kill Terminal") { if let w = wb, let id = w.activeTerminal { w.killTerminal(id) } }.disabled(wb?.activeTerminal == nil)
            Divider()
            Button("Reconnect to Desktop") { Task { await wb?.reconnect() } }.disabled(wb == nil)
        }
    }
}

private func line(_ title: String, _ action: Selector) -> some View {
    Button(title) { UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil) }
}

extension Workbench {
    func cycleTab(_ step: Int) {
        guard groups.indices.contains(focusedGroup) else { return }
        let tabs = groups[focusedGroup].tabs
        guard let a = active, let i = tabs.firstIndex(of: a), !tabs.isEmpty else { return }
        active = tabs[(i + step + tabs.count) % tabs.count]
    }
}
