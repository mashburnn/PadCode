import SwiftUI

/// PadCode's own editor settings, kept on the iPad. A nil font/tab size means
/// "use the desktop's VS Code setting"; the theme can follow the desktop too.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let desktopTheme = "desktop"

    private let d = UserDefaults.standard

    @Published var themeChoice: String { didSet { d.set(themeChoice, forKey: "theme") } }
    /// Theme picked from the desktop's extensions (by VS Code name).
    @Published var desktopThemeName: String? { didSet { d.set(desktopThemeName, forKey: "desktopThemeName") } }
    @Published var fontSize: Double? { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var tabSize: Int? { didSet { d.set(tabSize, forKey: "tabSize") } }
    @Published var wordWrap: Bool { didSet { d.set(wordWrap, forKey: "wordWrap") } }
    @Published var showInvisibles: Bool { didSet { d.set(showInvisibles, forKey: "showInvisibles") } }
    @Published var formatOnSave: Bool { didSet { d.set(formatOnSave, forKey: "formatOnSave") } }
    /// files.autoSave = afterDelay (on by default: iPadOS closes background apps).
    @Published var autoSave: Bool { didSet { d.set(autoSave, forKey: "autoSave") } }
    @Published var trimTrailingWhitespace: Bool { didSet { d.set(trimTrailingWhitespace, forKey: "trimTrailingWhitespace") } }
    @Published var insertFinalNewline: Bool { didSet { d.set(insertFinalNewline, forKey: "insertFinalNewline") } }
    @Published var autoSuggest: Bool { didSet { d.set(autoSuggest, forKey: "autoSuggest") } }
    @Published var terminalFontSize: Double? { didSet { d.set(terminalFontSize, forKey: "terminalFontSize") } }
    @Published var minimap: Bool { didSet { d.set(minimap, forKey: "minimap") } }

    private init() {
        themeChoice = d.string(forKey: "theme") ?? Self.desktopTheme
        desktopThemeName = d.string(forKey: "desktopThemeName")
        fontSize = d.object(forKey: "fontSize") as? Double
        tabSize = d.object(forKey: "tabSize") as? Int
        wordWrap = d.bool(forKey: "wordWrap")
        showInvisibles = d.bool(forKey: "showInvisibles")
        formatOnSave = d.bool(forKey: "formatOnSave")
        autoSave = d.object(forKey: "autoSave") as? Bool ?? true
        trimTrailingWhitespace = d.bool(forKey: "trimTrailingWhitespace")
        insertFinalNewline = d.bool(forKey: "insertFinalNewline")
        autoSuggest = d.object(forKey: "autoSuggest") as? Bool ?? true
        terminalFontSize = d.object(forKey: "terminalFontSize") as? Double
        minimap = d.object(forKey: "minimap") as? Bool ?? true
    }

    /// Bundled themes: (file, display name).
    static let bundledThemes = [
        ("dark-modern", "Dark Modern"),
        ("github-dark-dimmed", "GitHub Dark Dimmed"),
        ("dark_plus", "Dark+"),
        ("dark_vs", "Dark (Visual Studio)"),
    ]

    /// files.trimTrailingWhitespace / files.insertFinalNewline.
    func cleanUp(_ text: String) -> String {
        var t = text
        if trimTrailingWhitespace {
            t = t.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    var l = Substring(line)
                    while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
                    return String(l)
                }
                .joined(separator: "\n")
        }
        if insertFinalNewline, !t.isEmpty, !t.hasSuffix("\n") { t += "\n" }
        return t
    }
}

/// VS Code-style Settings editor, shown as a sheet.
struct SettingsView: View {
    @EnvironmentObject var wb: Workbench
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var desktopThemes: [String] = []
    @State private var loadingThemes = false
    @AppStorage("homeDark") private var homeDark = false
    @AppStorage("canvasFollowsSystem") private var followsSystem = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Canvas", selection: canvasBinding) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    Picker("Color Theme", selection: themeBinding) {
                        Text("Same as \(wb.machine.name)'s VS Code").tag(AppSettings.desktopTheme)
                        ForEach(AppSettings.bundledThemes, id: \.0) { Text($0.1).tag($0.0) }
                        if !desktopThemes.isEmpty {
                            Divider()
                            ForEach(desktopThemes, id: \.self) { Text($0).tag("ext:" + $0) }
                        }
                    }
                    if loadingThemes { ProgressView("Reading themes from \(wb.machine.name)…").font(.footnote) }
                    stepperRow("Editor Font Size", value: $settings.fontSize, range: 8...32, fallback: Double(wb.fontSize))
                    stepperRow("Terminal Font Size", value: $settings.terminalFontSize, range: 8...32, fallback: Double(wb.fontSize))
                }
                Section("Editor") {
                    Picker("Tab Size", selection: tabBinding) {
                        Text("Desktop setting").tag(0)
                        ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                    }
                    Toggle("Word Wrap", isOn: $settings.wordWrap)
                    Toggle("Render Whitespace", isOn: $settings.showInvisibles)
                    Toggle("Suggestions While Typing", isOn: $settings.autoSuggest)
                    Toggle("Minimap", isOn: $settings.minimap)
                }
                Section {
                    Toggle("Auto Save", isOn: $settings.autoSave)
                    Toggle("Format on Save", isOn: $settings.formatOnSave)
                    Toggle("Trim Trailing Whitespace", isOn: $settings.trimTrailingWhitespace)
                    Toggle("Insert Final Newline", isOn: $settings.insertFinalNewline)
                } header: {
                    Text("Files")
                } footer: {
                    Text("Auto Save writes changes a second after you stop typing. Format on Save (⌘S only) uses the file's language server on the desktop.")
                }
                Section {
                    Button("Reload Settings from \(wb.machine.name)") { Task { await wb.syncSettings() } }
                    Button("Reset to Defaults", role: .destructive) { reset() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            loadingThemes = true
            desktopThemes = await wb.desktopThemes()
            loadingThemes = false
        }
        .onChange(of: settings.fontSize) { wb.applySettings() }
        .onChange(of: settings.tabSize) { wb.applySettings() }
        .preferredColorScheme(wb.theme.isDark ? .dark : .light)
    }

    /// System follows the iPad; Light and Dark pin it (as the sun/moon button does).
    private var canvasBinding: Binding<Int> {
        Binding(get: { followsSystem ? 0 : homeDark ? 2 : 1 }, set: { v in
            let dark = v == 0 ? Appearance.systemDark : v == 2
            followsSystem = v == 0
            if dark != homeDark { Appearance.flip(in: wb.scene) { homeDark = dark } }
        })
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { settings.desktopThemeName.map { "ext:" + $0 } ?? settings.themeChoice },
            set: { v in
                if v.hasPrefix("ext:") {
                    let name = String(v.dropFirst(4))
                    settings.desktopThemeName = name
                    settings.themeChoice = AppSettings.desktopTheme
                    Task { await wb.useDesktopTheme(named: name) }
                } else {
                    settings.desktopThemeName = nil
                    settings.themeChoice = v
                    if v == AppSettings.desktopTheme { Task { await wb.syncSettings() } } else { wb.applySettings() }
                }
            }
        )
    }

    private var tabBinding: Binding<Int> {
        Binding(get: { settings.tabSize ?? 0 }, set: { settings.tabSize = $0 == 0 ? nil : $0 })
    }

    private func stepperRow(_ title: String, value: Binding<Double?>, range: ClosedRange<Double>, fallback: Double) -> some View {
        let current = value.wrappedValue ?? fallback
        return Stepper(value: Binding(get: { current }, set: { value.wrappedValue = $0 }), in: range, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue == nil ? "\(Int(current)) (desktop)" : "\(Int(current))").foregroundStyle(.secondary)
            }
        }
    }

    private func reset() {
        settings.themeChoice = AppSettings.desktopTheme
        settings.desktopThemeName = nil
        settings.fontSize = nil
        settings.tabSize = nil
        settings.terminalFontSize = nil
        settings.wordWrap = false
        settings.showInvisibles = false
        settings.formatOnSave = false
        settings.autoSave = true
        settings.trimTrailingWhitespace = false
        settings.insertFinalNewline = false
        settings.autoSuggest = true
        settings.minimap = true
        Task { await wb.syncSettings() }
    }
}
