import Runestone
import SwiftUI
import UIKit

/// A VS Code color theme loaded from its JSON (JSONC, `include` chains).
/// `colors` style the workbench chrome, `tokenColors` the editor, and
/// `terminal.ansi*` the terminal.
final class VSTheme: ObservableObject {
    let name: String
    let isDark: Bool
    private let colors: [String: UIColor]
    /// TextMate scope (as written in the theme) -> foreground / fontStyle
    private let scopes: [(scope: String, color: UIColor?, style: String?)]

    init(name: String, json: [String: Any], includes: [[String: Any]] = []) {
        self.name = name
        var colors: [String: UIColor] = [:]
        var scopes: [(String, UIColor?, String?)] = []
        // Includes first, so the theme's own values win.
        for layer in includes + [json] {
            // Values are usually "#hex", but some themes put arrays in here.
            for (k, v) in layer["colors"] as? [String: Any] ?? [:] {
                if let s = v as? String, let c = UIColor(vsHex: s) { colors[k] = c }
            }
            for rule in layer["tokenColors"] as? [[String: Any]] ?? [] {
                let settings = rule["settings"] as? [String: Any] ?? [:]
                let fg = (settings["foreground"] as? String).flatMap(UIColor.init(vsHex:))
                let style = settings["fontStyle"] as? String
                let list: [String]
                if let s = rule["scope"] as? String {
                    list = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    list = rule["scope"] as? [String] ?? []
                }
                for s in list where !s.isEmpty { scopes.append((s, fg, style)) }
            }
        }
        self.colors = colors
        self.scopes = scopes
        let type = json["type"] as? String ?? includes.compactMap { $0["type"] as? String }.first
        isDark = type != "light" && type != "hc-light"
    }

    /// Loads a theme file, following `include` (relative to the file).
    static func load(data: Data, name: String, resolve: (String) -> Data?) -> VSTheme? {
        guard let json = parseJSONC(data) else { return nil }
        var includes: [[String: Any]] = []
        var next = json["include"] as? String
        var depth = 0
        while let inc = next, depth < 5, let d = resolve(inc), let j = parseJSONC(d) {
            includes.insert(j, at: 0)
            next = j["include"] as? String
            depth += 1
        }
        return VSTheme(name: name, json: json, includes: includes)
    }

    static func bundled(_ file: String) -> VSTheme {
        func read(_ name: String) -> Data? {
            let base = (name as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
            return Bundle.main.url(forResource: base, withExtension: "json", subdirectory: "themes")
                .flatMap { try? Data(contentsOf: $0) }
        }
        let data = read(file)!
        let name = (parseJSONC(data)?["name"] as? String) ?? file
        return load(data: data, name: name, resolve: read)!
    }

    static let fallback = bundled("github-dark-dimmed")

    // MARK: Workbench colors (keys from VS Code's color registry)

    func ui(_ key: String, _ fallbacks: String..., default def: String) -> Color {
        Color(uiColor(key, fallbacks, default: def))
    }

    func has(_ key: String) -> Bool { colors[key] != nil }

    func uiColor(_ key: String, _ fallbacks: [String] = [], default def: String) -> UIColor {
        for k in [key] + fallbacks { if let c = colors[k] { return c } }
        return UIColor(vsHex: def)!
    }

    var editorBg: Color { ui("editor.background", default: isDark ? "#1e1e1e" : "#ffffff") }
    var editorFg: Color { ui("editor.foreground", "foreground", default: isDark ? "#d4d4d4" : "#000000") }
    var sideBarBg: Color { ui("sideBar.background", default: isDark ? "#252526" : "#f3f3f3") }
    var sideBarFg: Color { ui("sideBar.foreground", "foreground", default: isDark ? "#cccccc" : "#616161") }
    var sideBarTitleFg: Color { ui("sideBarTitle.foreground", "sideBar.foreground", "foreground", default: "#bbbbbb") }
    var sectionHeaderBg: Color { ui("sideBarSectionHeader.background", default: "#00000000") }
    var activityBarBg: Color { ui("activityBar.background", default: isDark ? "#333333" : "#2c2c2c") }
    var activityFg: Color { ui("activityBar.foreground", default: "#ffffff") }
    var activityInactiveFg: Color { ui("activityBar.inactiveForeground", default: "#ffffff66") }
    var activityBorderActive: Color { ui("activityBar.activeBorder", "activityBar.foreground", default: "#ffffff") }
    var activityBadgeBg: Color { ui("activityBarBadge.background", default: "#007acc") }
    var tabsBg: Color { ui("editorGroupHeader.tabsBackground", default: isDark ? "#252526" : "#f3f3f3") }
    var tabActiveBg: Color { ui("tab.activeBackground", "editor.background", default: "#1e1e1e") }
    var tabInactiveBg: Color { ui("tab.inactiveBackground", default: "#2d2d2d") }
    var tabActiveFg: Color { ui("tab.activeForeground", default: "#ffffff") }
    var tabInactiveFg: Color { ui("tab.inactiveForeground", default: "#ffffff80") }
    var tabActiveBorderTop: Color { ui("tab.activeBorderTop", "focusBorder", default: "#00000000") }
    var tabBorder: Color { ui("tab.border", default: "#252526") }
    var panelBg: Color { ui("panel.background", "editor.background", default: "#1e1e1e") }
    var panelBorder: Color { ui("panel.border", default: "#80808059") }
    var panelTitleActiveFg: Color { ui("panelTitle.activeForeground", default: "#e7e7e7") }
    var panelTitleInactiveFg: Color { ui("panelTitle.inactiveForeground", default: "#e7e7e799") }
    var panelTitleActiveBorder: Color { ui("panelTitle.activeBorder", "focusBorder", default: "#e7e7e7") }
    var statusBarBg: Color { ui("statusBar.background", default: "#007acc") }
    var statusBarFg: Color { ui("statusBar.foreground", default: "#ffffff") }
    var statusBarBorder: Color { ui("statusBar.border", default: "#00000000") }
    var remoteBg: Color { ui("statusBarItem.remoteBackground", default: "#16825d") }
    var remoteFg: Color { ui("statusBarItem.remoteForeground", default: "#ffffff") }
    var listActiveBg: Color { ui("list.activeSelectionBackground", default: "#04395e") }
    var listActiveFg: Color { ui("list.activeSelectionForeground", "sideBar.foreground", "foreground", default: "#ffffff") }
    var listHoverBg: Color { ui("list.hoverBackground", default: "#2a2d2e") }
    var focusBorder: Color { ui("focusBorder", default: "#007fd4") }
    var inputBg: Color { ui("input.background", default: "#3c3c3c") }
    var inputFg: Color { ui("input.foreground", "foreground", default: "#cccccc") }
    var inputBorder: Color { ui("input.border", "focusBorder", default: "#00000000") }
    var quickInputBg: Color { ui("quickInput.background", "editorWidget.background", "sideBar.background", default: "#252526") }
    var quickInputFg: Color { ui("quickInput.foreground", "foreground", default: "#cccccc") }
    var widgetShadow: Color { ui("widget.shadow", default: "#0000005c") }
    var widgetBorder: Color { ui("widget.border", "editorWidget.border", default: "#ffffff17") }
    var buttonBg: Color { ui("button.background", default: "#0e639c") }
    var buttonFg: Color { ui("button.foreground", default: "#ffffff") }
    var descriptionFg: Color { ui("descriptionForeground", default: "#ccccccb3") }
    var errorFg: Color { ui("errorForeground", default: "#f48771") }
    var highlightFg: Color { ui("list.highlightForeground", default: "#2aaaff") }
    var breadcrumbFg: Color { ui("breadcrumb.foreground", default: "#cccccccc") }
    var modifiedDot: Color { ui("tab.unfocusedActiveModifiedBorder", "tab.activeModifiedBorder", "editor.foreground", default: "#ffffff") }
    var titleBarBg: Color { ui("titleBar.activeBackground", default: "#3c3c3c") }
    var titleBarFg: Color { ui("titleBar.activeForeground", default: "#cccccc") }
    var titleBarBorder: Color { ui("titleBar.border", default: "#00000000") }
    var dropBg: Color { ui("list.dropBackground", default: "#062f4a") }
    var findMatchBg: Color { ui("editor.findMatchHighlightBackground", default: "#ea5c0055") }
    var sashHover: Color { ui("sash.hoverBorder", "focusBorder", default: "#007fd4") }
    var tabHoverBg: Color { ui("tab.hoverBackground", "tab.inactiveBackground", default: "#2d2d2d") }
    var tabHoverFg: Color { ui("tab.hoverForeground", "tab.activeForeground", default: "#ffffff") }
    var statusItemHoverBg: Color { ui("statusBarItem.hoverBackground", default: "#ffffff1f") }
    var remoteHoverBg: Color { ui("statusBarItem.remoteHoverBackground", "statusBarItem.hoverBackground", default: "#ffffff1f") }
    var linkHoverFg: Color { ui("textLink.activeForeground", "textLink.foreground", "list.highlightForeground", default: "#3794ff") }

    // MARK: Terminal

    /// The 16 ANSI colors in xterm order, for SwiftTerm.
    var ansi: [UIColor] {
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let defaults = ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
                        "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#e5e5e5"]
        let keys = names.map { "terminal.ansi\($0)" } + names.map { "terminal.ansiBright\($0)" }
        return zip(keys, defaults).map { uiColor($0, default: $1) }
    }
    var terminalBg: UIColor { uiColor("terminal.background", ["panel.background", "editor.background"], default: "#1e1e1e") }
    var terminalFg: UIColor { uiColor("terminal.foreground", ["editor.foreground"], default: "#cccccc") }
    var terminalCursor: UIColor { uiColor("terminalCursor.foreground", ["editorCursor.foreground"], default: "#aeafad") }
    var terminalSelection: UIColor { uiColor("terminal.selectionBackground", ["editor.selectionBackground"], default: "#264f78") }

    // MARK: Editor tokens

    /// Tree-sitter capture name -> TextMate scopes to try, most specific first.
    private static let captureScopes: [String: [String]] = [
        "comment": ["comment"],
        "string": ["string"],
        "string.special": ["string.regexp", "string"],
        "escape": ["constant.character.escape", "constant.character"],
        "character": ["constant.character", "string"],
        "number": ["constant.numeric", "constant"],
        "boolean": ["constant.language", "constant"],
        "constant": ["variable.other.constant", "constant"],
        "constant.builtin": ["constant.language", "constant"],
        "keyword": ["keyword", "storage.type", "storage"],
        "keyword.return": ["keyword.control", "keyword"],
        "keyword.function": ["storage.type.function", "keyword", "storage"],
        "keyword.operator": ["keyword.operator", "keyword"],
        "include": ["keyword.control.import", "keyword.control", "keyword"],
        "conditional": ["keyword.control", "keyword"],
        "repeat": ["keyword.control", "keyword"],
        "exception": ["keyword.control", "keyword"],
        "operator": ["keyword.operator", "keyword"],
        "function": ["entity.name.function", "support.function"],
        "function.builtin": ["support.function", "entity.name.function"],
        "function.method": ["entity.name.function", "support.function"],
        "function.macro": ["entity.name.function.macro", "entity.name.function", "support.function"],
        "method": ["entity.name.function"],
        "constructor": ["entity.name.type", "entity.name.class", "support.class"],
        "type": ["entity.name.type", "support.type", "storage.type", "entity.name.class"],
        "type.builtin": ["support.type", "storage.type", "entity.name.type"],
        "variable": ["variable.other", "variable"],
        "variable.builtin": ["variable.language", "variable"],
        "variable.parameter": ["variable.parameter", "variable"],
        "parameter": ["variable.parameter", "variable"],
        "property": ["variable.other.property", "support.variable.property", "variable.other.object.property", "meta.object-literal.key", "variable"],
        "field": ["variable.other.property", "variable"],
        "attribute": ["entity.other.attribute-name"],
        "tag": ["entity.name.tag"],
        "label": ["entity.name.label", "entity.name.tag"],
        "namespace": ["entity.name.namespace", "entity.name.type.module", "entity.name.type"],
        "module": ["entity.name.namespace", "entity.name.type.module", "entity.name.type"],
        "punctuation": ["punctuation"],
        "punctuation.bracket": ["punctuation.definition.block", "punctuation"],
        "punctuation.delimiter": ["punctuation.separator", "punctuation"],
        "punctuation.special": ["punctuation.definition.template-expression", "punctuation"],
        "text.title": ["markup.heading", "entity.name.section"],
        "text.literal": ["markup.inline.raw", "markup.raw"],
        "text.uri": ["markup.underline.link"],
        "text.emphasis": ["markup.italic"],
        "text.strong": ["markup.bold"],
        "embedded": ["meta.embedded", "source"],
    ]

    private var tokenCache: [String: (UIColor?, String?)] = [:]
    private let lock = NSLock()

    /// Best theme rule for a capture like `function.method.builtin`.
    func token(for capture: String) -> (color: UIColor?, style: String?) {
        lock.lock(); defer { lock.unlock() }
        if let c = tokenCache[capture] { return c }
        var parts = capture.split(separator: ".").map(String.init)
        var result: (UIColor?, String?) = (nil, nil)
        search: while !parts.isEmpty {
            for wanted in Self.captureScopes[parts.joined(separator: ".")] ?? [] {
                if let hit = bestRule(for: wanted) { result = hit; break search }
            }
            parts.removeLast()
        }
        tokenCache[capture] = result
        return result
    }

    /// TextMate prefix matching: rule `keyword` matches `keyword.control`; the
    /// longest (most specific) matching rule wins, later rules break ties.
    private func bestRule(for scope: String) -> (UIColor?, String?)? {
        var best: (len: Int, color: UIColor?, style: String?)?
        for r in scopes where r.color != nil || r.style != nil {
            let s = r.scope.split(separator: " ").last.map(String.init) ?? r.scope
            if scope == s || scope.hasPrefix(s + ".") {
                if best == nil || s.count >= best!.len { best = (s.count, r.color, r.style) }
            }
        }
        return best.map { ($0.color, $0.style) }
    }
}

/// Runestone theme driven by a VS Code theme.
final class EditorTheme: Runestone.Theme {
    let vs: VSTheme
    let font: UIFont
    let bracketPairColors: [UIColor]
    init(_ vs: VSTheme, fontSize: CGFloat) {
        self.vs = vs
        font = UIFont(name: "Menlo-Regular", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let defaults = vs.isDark ? ["#ffd700", "#da70d6", "#179fff"] : ["#0431fa", "#319331", "#7b3814"]
        bracketPairColors = (1...6).compactMap { i in
            i <= 3 ? vs.uiColor("editorBracketHighlight.foreground\(i)", default: defaults[i - 1])
                : vs.has("editorBracketHighlight.foreground\(i)") ? vs.uiColor("editorBracketHighlight.foreground\(i)", default: "#ffffff") : nil
        }
    }
    var textColor: UIColor { vs.uiColor("editor.foreground", ["foreground"], default: "#d4d4d4") }
    var gutterBackgroundColor: UIColor { vs.uiColor("editorGutter.background", ["editor.background"], default: "#1e1e1e") }
    var gutterHairlineColor: UIColor { .clear }
    var lineNumberColor: UIColor { vs.uiColor("editorLineNumber.foreground", default: "#858585") }
    var lineNumberFont: UIFont { font }
    var selectedLineBackgroundColor: UIColor {
        vs.uiColor("editor.lineHighlightBackground", ["editor.lineHighlightBorder"], default: "#ffffff0a")
    }
    var selectedLinesLineNumberColor: UIColor { vs.uiColor("editorLineNumber.activeForeground", default: "#c6c6c6") }
    var selectedLinesGutterBackgroundColor: UIColor { gutterBackgroundColor }
    var invisibleCharactersColor: UIColor { vs.uiColor("editorWhitespace.foreground", default: "#e3e4e229") }
    var pageGuideHairlineColor: UIColor { vs.uiColor("editorRuler.foreground", default: "#5a5a5a") }
    var pageGuideBackgroundColor: UIColor { .clear }
    var markedTextBackgroundColor: UIColor { vs.uiColor("editor.selectionBackground", default: "#264f78") }
    var indentGuideColor: UIColor? {
        vs.uiColor("editorIndentGuide.background1", ["editorIndentGuide.background"], default: vs.isDark ? "#404040" : "#d3d3d3")
    }
    var activeIndentGuideColor: UIColor? {
        vs.uiColor("editorIndentGuide.activeBackground1", ["editorIndentGuide.activeBackground"], default: vs.isDark ? "#707070" : "#939393")
    }

    func textColor(for highlightName: String) -> UIColor? { vs.token(for: highlightName).color }

    func fontTraits(for highlightName: String) -> FontTraits {
        let style = vs.token(for: highlightName).style ?? ""
        var t: FontTraits = []
        if style.contains("bold") { t.insert(.bold) }
        if style.contains("italic") { t.insert(.italic) }
        return t
    }
}

extension UIColor {
    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`, as used in VS Code themes.
    convenience init?(vsHex: String) {
        var s = vsHex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a = s.count == 8 ? CGFloat(v & 0xff) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: a)
    }
}

/// JSON with comments and trailing commas (VS Code's settings and theme format).
func parseJSONC(_ data: Data) -> [String: Any]? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let cleaned = jsoncPass(jsoncPass(Array(text.unicodeScalars), stripComments: true), stripComments: false)
    var s = String.UnicodeScalarView()
    s.append(contentsOf: cleaned)
    return (try? JSONSerialization.jsonObject(with: Data(String(s).utf8))) as? [String: Any]
}

/// One string-aware pass: drops comments, or (second pass) trailing commas.
private func jsoncPass(_ src: [Unicode.Scalar], stripComments: Bool) -> [Unicode.Scalar] {
    var out: [Unicode.Scalar] = []
    out.reserveCapacity(src.count)
    var i = 0
    var inString = false
    while i < src.count {
        let c = src[i]
        let next: Unicode.Scalar? = i + 1 < src.count ? src[i + 1] : nil
        if inString {
            out.append(c)
            if c == "\\", let n = next { out.append(n); i += 1 } else if c == "\"" { inString = false }
        } else if c == "\"" {
            inString = true
            out.append(c)
        } else if stripComments, c == "/", next == "/" {
            while i < src.count, src[i] != "\n" { i += 1 }
            continue
        } else if stripComments, c == "/", next == "*" {
            i += 2
            while i + 1 < src.count, !(src[i] == "*" && src[i + 1] == "/") { i += 1 }
            i += 2
            continue
        } else if !stripComments, c == "," {
            var j = i + 1
            while j < src.count, CharacterSet.whitespacesAndNewlines.contains(src[j]) { j += 1 }
            if j < src.count, src[j] == "}" || src[j] == "]" { i += 1; continue }
            out.append(c)
        } else {
            out.append(c)
        }
        i += 1
    }
    return out
}

// MARK: Pointer hover (iPad trackpad), as on desktop VS Code

/// Hands `content` whether the pointer is over it.
struct Hovering<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var on = false
    var body: some View { content(on || Scenario.hoverAll).onHover { on = $0 } }
}

extension View {
    /// A list row's hover background. Pass `.clear` for a selected row, so the
    /// selection color shows as is.
    func hoverBackground(_ color: Color, cornerRadius: CGFloat = 0) -> some View {
        Hovering { on in
            background { if on { RoundedRectangle(cornerRadius: cornerRadius).fill(color) } }
        }
    }
}

extension View {
    /// A floating widget's surface (Quick Open, notifications): the theme's
    /// color over a blur of what's behind it.
    func floatingSurface(_ color: Color, cornerRadius: CGFloat) -> some View {
        background { ZStack { Rectangle().fill(.ultraThinMaterial); color.opacity(0.84) } }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// An icon's name for VoiceOver and as a pointer tooltip, like VS Code's.
    func tip(_ label: String) -> some View { accessibilityLabel(label).help(label) }
}

/// VS Code's toolbar icon button: a rounded highlight under the pointer
/// (toolbar.hoverBackground), a little stronger while pressed.
struct ToolbarButtonStyle: ButtonStyle {
    var padding: CGFloat = 3
    func makeBody(configuration: Configuration) -> some View {
        Hovering { on in
            configuration.label
                .padding(padding)
                .background(Color(white: 0.5, opacity: configuration.isPressed ? 0.45 : on ? 0.3 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .hoverEffectDisabled()
        }
    }
}

/// VS Code's text links: brighter and underlined under the pointer.
struct LinkButtonStyle: ButtonStyle {
    let hover: Color
    func makeBody(configuration: Configuration) -> some View {
        Hovering { on in
            configuration.label
                .underline(on)
                .foregroundStyle(on ? AnyShapeStyle(hover) : AnyShapeStyle(.foreground))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .hoverEffectDisabled()
        }
    }
}
