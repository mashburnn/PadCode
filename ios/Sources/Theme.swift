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
        if let type = json["type"] as? String ?? includes.compactMap { $0["type"] as? String }.first {
            isDark = type != "light" && type != "hc-light"
        } else { // VS Code's own themes omit "type": judge by the editor background
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            colors["editor.background"]?.getRed(&r, green: &g, blue: &b, alpha: nil)
            isDark = 0.299 * r + 0.587 * g + 0.114 * b < 0.5
        }
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

    /// Light Modern's sibling: neutral greys like the canvas, so dark reads as one surface too.
    static let fallback = bundled("dark-modern")
    /// Shown whenever the canvas is light, so panels and chrome agree.
    static let light = bundled("light-modern")

    // MARK: Workbench colors (keys from VS Code's color registry)

    func ui(_ key: String, _ fallbacks: String..., default def: String) -> Color {
        Color(uiColor(key, fallbacks, default: def))
    }

    func has(_ key: String) -> Bool { colors[key] != nil }

    func uiColor(_ key: String, _ fallbacks: [String] = [], default def: String) -> UIColor {
        for k in [key] + fallbacks { if let c = colors[k] { return c } }
        return UIColor(vsHex: isDark ? def : Self.lightDefaults[key] ?? def)!
    }

    /// VS Code's registry defaults for light themes, for keys its JSON themes leave out.
    /// The call sites' defaults are the dark ones (light-grey text, navy selections),
    /// which are unreadable or wrong on white.
    private static let lightDefaults: [String: String] = [
        "breadcrumb.foreground": "#616161cc",
        "editor.lineHighlightBackground": "#0000000a",
        "editor.selectionBackground": "#add6ff",
        "editor.wordHighlightBackground": "#57575740",
        "editorHoverWidget.border": "#c8c8c8",
        "editorLightBulb.foreground": "#ddb100",
        "editorRuler.foreground": "#d3d3d3",
        "editorStickyScroll.shadow": "#dddddd",
        "editorStickyScrollHover.background": "#f0f0f0",
        "editorWhitespace.foreground": "#33333333",
        "keybindingLabel.background": "#dddddd66",
        "keybindingLabel.bottomBorder": "#bbbbbb99",
        "list.dropBackground": "#d6ebff",
        "list.errorForeground": "#b01011",
        "list.highlightForeground": "#0066bf",
        "list.warningForeground": "#855f00",
        "minimapSlider.background": "#64646433",
        "minimapSlider.hoverBackground": "#64646459",
        "minimapSlider.activeBackground": "#00000033",
        "notificationsErrorIcon.foreground": "#e51400",
        "notificationsInfoIcon.foreground": "#1a85ff",
        "problemsErrorIcon.foreground": "#e51400",
        "problemsInfoIcon.foreground": "#1a85ff",
        "problemsWarningIcon.foreground": "#bf8803",
        "scrollbar.shadow": "#dddddd",
        "terminal.selectionBackground": "#add6ff",
        "terminalCursor.foreground": "#000000",
        "tree.indentGuidesStroke": "#a9a9a9",
        "tree.inactiveIndentGuidesStroke": "#a9a9a966",
        "widget.shadow": "#00000029",
    ]

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
    var widgetBorder: Color { ui("widget.border", "editorWidget.border", default: isDark ? "#ffffff17" : "#0000001a") }
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
    func hoverBackground(_ color: Color, cornerRadius: CGFloat = 0, inset: CGFloat = 0) -> some View {
        Hovering { on in
            background {
                if on { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(color).padding(.horizontal, inset) }
            }
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

/// Icon buttons: a soft rounded highlight under the pointer; pressing dips the
/// icon, and it springs back.
struct ToolbarButtonStyle: ButtonStyle {
    var padding: CGFloat = 3
    func makeBody(configuration: Configuration) -> some View {
        Hovering { on in
            configuration.label
                .padding(padding)
                .frame(minWidth: padding >= 3 ? 28 : nil, minHeight: padding >= 3 ? 28 : nil) // a finger-sized target around a 16 pt glyph; tight spots (tab ×) opt out
                .background(Color(white: 0.5, opacity: configuration.isPressed ? 0.32 : on ? 0.2 : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(Motion.pop, value: configuration.isPressed)
                .animation(Motion.hover, value: on)
                .contentShape(Rectangle())
                .hoverEffectDisabled()
        }
    }
}

// MARK: - PadCode's own look
// Not VS Code's: panels float as rounded cards on a darker canvas, popups are
// glass, and things move on springs.

extension UIColor {
    func mixed(with other: UIColor, _ f: CGFloat) -> UIColor {
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: a1 + (a2 - a1) * f)
    }
}

extension VSTheme {
    /// Behind the panels: the side bar's color, a shade darker.
    var canvasBg: Color {
        Color(uiColor("sideBar.background", ["editor.background"], default: isDark ? "#252526" : "#f3f3f3")
            .mixed(with: .black, isDark ? 0.38 : 0.07).withAlphaComponent(1))
    }
    var cardBorder: Color { isDark ? .white.opacity(0.07) : .black.opacity(0.12) }
    var placeholderFg: Color { ui("input.placeholderForeground", default: isDark ? "#ffffff80" : "#767676") }
    /// A text field's prompt in the theme's placeholder color (SwiftUI's default is unreadable on light themes).
    func prompt(_ s: String) -> Text { Text(s).foregroundStyle(placeholderFg) }
    /// Selection pills and indicators.
    var accent: Color { ui("focusBorder", "button.background", default: "#3794ff") }
    /// A raised fill on a panel: the active tab, the selected segment.
    var raised: Color { isDark ? .white.opacity(0.085) : .black.opacity(0.09) }
    var hoverFill: Color { isDark ? .white.opacity(0.045) : .black.opacity(0.05) }
}

/// Light ↔ dark: the new look spreads out from the toggle's corner over a
/// snapshot of the old one, so the editor and terminal (UIKit views that
/// recolor in one step) change together with the chrome. Reduce Motion: a fade.
enum Appearance {
    static var duration = 0.5 // the scenario slows it to catch it mid-way

    /// The system's light/dark setting (the screen's, which window overrides don't change).
    @MainActor static var systemDark: Bool {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (scene?.screen.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .dark
    }

    /// "System" canvas: follow the iPad's appearance (on launch and whenever PadCode comes forward).
    /// ponytail: not live while PadCode stays frontmost (e.g. sunset auto-switch); it catches up on the next activation.
    @MainActor static func syncWithSystem() {
        let d = UserDefaults.standard
        guard d.object(forKey: "canvasFollowsSystem") as? Bool ?? true else { return }
        if d.bool(forKey: "homeDark") != systemDark { d.set(systemDark, forKey: "homeDark") }
    }

    /// The sun/moon button and View ▸ Toggle Dark Canvas: an explicit choice stops following the system.
    @MainActor static func toggle(in scene: UIWindowScene?) {
        let d = UserDefaults.standard
        flip(in: scene) {
            d.set(false, forKey: "canvasFollowsSystem")
            d.set(!d.bool(forKey: "homeDark"), forKey: "homeDark")
        }
    }

    @MainActor static func flip(in scene: UIWindowScene?, _ change: () -> Void) {
        let scene = scene ?? UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let window = scene?.keyWindow ?? scene?.windows.first,
              let old = window.snapshotView(afterScreenUpdates: false) else { change(); return }
        window.addSubview(old)
        change()
        let b = window.bounds
        CATransaction.begin()
        CATransaction.setCompletionBlock { old.removeFromSuperview() }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2) { old.alpha = 0 }
        } else {
            // A hole in the old snapshot grows from the top-right corner, where the sun/moon lives.
            let c = CGPoint(x: b.maxX - 56, y: 36)
            func path(_ r: CGFloat) -> CGPath {
                let p = UIBezierPath(rect: b)
                p.append(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
                return p.cgPath
            }
            let mask = CAShapeLayer()
            mask.fillRule = .evenOdd
            mask.path = path(hypot(b.width, b.height))
            old.layer.mask = mask
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = path(1)
            a.toValue = mask.path
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.add(a, forKey: "reveal")
        }
        CATransaction.commit()
    }
}

/// Springs, so every part of the app moves alike. Reduce Motion gets short fades.
enum Motion {
    private static var reduce: Bool { UIAccessibility.isReduceMotionEnabled }
    /// Panels and tabs: quick, settles without overshoot.
    static var layout: Animation { reduce ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.86) }
    /// Indicators and small controls: a touch of overshoot.
    static var pop: Animation { reduce ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.66) }
    /// Popups and notifications arriving.
    static var popup: Animation { reduce ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.78) }
    /// Hover highlights coming and going.
    static var hover: Animation { .easeOut(duration: reduce ? 0.08 : 0.15) }
    /// Small content swaps (a badge, a breadcrumb, a find bar).
    static var quick: Animation { reduce ? .easeOut(duration: 0.12) : .snappy(duration: 0.18) }
}

/// A card's corners in the canvas color, laid over its content (the rect
/// minus the rounded rect). Covering instead of clipping keeps the editor and
/// terminal, which are UIKit views, from rendering through a mask.
struct CardCorners: Shape {
    var radius: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path(r)
        p.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return p
    }
}

private struct PopIn: ViewModifier {
    let active: Bool
    let anchor: UnitPoint
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.92 : 1, anchor: anchor)
            .offset(y: active ? (anchor.y < 0.5 ? -10 : 14) : 0)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    /// Popups grow out of their edge and settle; the spring that inserts them sets the feel.
    static func pop(from anchor: UnitPoint = .top) -> AnyTransition {
        .modifier(active: PopIn(active: true, anchor: anchor), identity: PopIn(active: false, anchor: anchor))
    }
}

// MARK: - Skeletons

/// A placeholder shape while content loads. One light band sweeps diagonally
/// across every placeholder on screen at once (a shared clock, global
/// coordinates), then rests, so loading reads as one calm wave, not a flicker.
struct Skeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 5
    let theme: VSTheme
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// Seconds per wave: the sweep, then a pause.
    static let period = 2.2
    static let sweep = 1.5
    /// How far the band travels (wider than any iPad window) and its width.
    static let span: CGFloat = 1900
    static let band: CGFloat = 320

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(theme.raised)
            .frame(width: width, height: height)
            .overlay { if !reduce { ShimmerBand(theme: theme).clipShape(shape) } }
    }

    /// Where the band's center is, in global x, at `date` (smoothstep eased).
    static func bandX(_ date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / sweep
        guard t < 1 else { return -band } // resting, off screen
        let eased = t * t * (3 - 2 * t)
        return -band + CGFloat(eased) * (span + band)
    }
}

/// The shared light band, placed in this view's frame (clip or mask it to a shape).
struct ShimmerBand: View {
    let theme: VSTheme
    /// 1 for fills; more for thin strokes, so an outline visibly catches the light.
    var strength: Double = 1

    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            TimelineView(.animation) { ctx in
                let x = Skeleton.bandX(ctx.date) - f.minX + f.minY * 0.35 // lower shapes light up a beat later
                // A glassy sheen: accent-tinted edges around a bright core.
                LinearGradient(colors: [.clear, theme.accent.opacity(0.10 * strength),
                                        .white.opacity(min((theme.isDark ? 0.24 : 0.8) * strength, 1)),
                                        theme.accent.opacity(0.10 * strength), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: Skeleton.band)
                    .offset(x: x - Skeleton.band / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A placeholder card's outline that catches the same band: a gleam runs
/// along its edges as the wave passes.
struct SkeletonOutline: View {
    let radius: CGFloat
    let theme: VSTheme
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.strokeBorder(theme.cardBorder)
            if !reduce {
                ShimmerBand(theme: theme, strength: 2.6).mask(shape.strokeBorder(lineWidth: 1.5))
            }
        }
        .allowsHitTesting(false)
    }
}

/// File-tree placeholder rows with varied lengths, so it looks like a listing.
struct SkeletonRows: View {
    let count: Int
    var indent: CGFloat = 20
    var rowHeight: CGFloat = 24
    let theme: VSTheme
    private static let widths: [CGFloat] = [118, 86, 140, 72, 104, 128, 64, 96, 150, 80, 112, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 8) {
                    Skeleton(width: 14, height: 14, radius: 4, theme: theme)
                    Skeleton(width: Self.widths[i % Self.widths.count], height: 10, theme: theme)
                }
                .padding(.leading, indent + (i % 5 == 3 ? 16 : 0))
                .frame(height: rowHeight)
            }
        }
        .transition(.opacity)
        .accessibilityLabel("Loading")
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.opacity(active ? 0 : 1).blur(radius: active ? 8 : 0).scaleEffect(active ? 0.985 : 1)
    }
}

extension AnyTransition {
    /// Loaded content arriving where its skeleton was: it comes into focus, it doesn't jump.
    static var blurFade: AnyTransition {
        // Arrives in focus; leaves quickly, so the new content isn't waiting on the old.
        .asymmetric(insertion: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false)),
                    removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

private struct BounceIn: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content.scaleEffect(shown ? 1 : 0.4)
            .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.35, dampingFraction: 0.5).delay(0.08), value: shown)
            .onAppear { shown = true }
    }
}

extension View {
    /// Pops in with a bounce when it appears (a notification's icon).
    func symbolBounceIn() -> some View { modifier(BounceIn()) }

    /// Staggered entrance: the `index`th item rises into place once `shown`.
    func rise(_ shown: Bool, _ index: Int) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.15)
                       : .spring(response: 0.5, dampingFraction: 0.82).delay(0.04 + Double(index) * 0.05), value: shown)
    }

    /// A floating panel on the canvas: the home page's card look (see `Card`).
    func card(_ t: VSTheme, fill: Color, radius: CGFloat = 16, highlighted: Bool = false) -> some View {
        modifier(Card(fill: fill, radius: radius, highlighted: highlighted, accent: t.accent))
    }

    /// Popups' surface: Liquid Glass tinted with the theme (iPadOS 26), else blur and tint.
    /// Every floating surface, one recipe: hover cards, the find bar, suggestions and
    /// toasts at 12/16, pickers `lifted` a little higher. One border, one shadow
    /// (stronger on dark), so they all sit at the same height above the panels.
    /// `solid` for ones that redraw on every keystroke (glass would re-sample each time).
    func floating(_ t: VSTheme, _ fill: Color, radius: CGFloat = 12, solid: Bool = false, lifted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return surface(fill, shape, radius: radius, solid: solid)
            .overlay(shape.strokeBorder(t.widgetBorder))
            .shadow(color: .black.opacity(lifted ? (t.isDark ? 0.4 : 0.15) : (t.isDark ? 0.35 : 0.12)),
                    radius: lifted ? 28 : 14, y: lifted ? 12 : 6)
    }

    @ViewBuilder private func surface(_ fill: Color, _ shape: RoundedRectangle, radius: CGFloat, solid: Bool) -> some View {
        if solid { background(fill).clipShape(shape) } else { glass(fill, radius: radius) }
    }

    @ViewBuilder func glass(_ tint: Color, radius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint.opacity(0.75)), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            floatingSurface(tint, cornerRadius: radius)
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

// MARK: PadCode's own look (the home page and the chrome around every window)

/// The home page's own palette: a light or dark canvas, flat cards, one green.
/// It travels in the environment, so flipping the toggle redraws every part.
struct HomeStyle {
    var dark = false
    var canvas: Color { dark ? Color(white: 0.065) : Color(red: 0.957, green: 0.957, blue: 0.949) } // a step below the panels (Dark Modern #181818, Light Modern #f8f8f8)
    var card: Color { dark ? Color(white: 0.145) : .white }
    var ink: Color { dark ? Color(white: 0.93) : Color(white: 0.11) }
    var muted: Color { dark ? Color(white: 0.6) : Color(white: 0.44) } // ≥ 4.5:1 on white
    var chip: Color { dark ? Color(white: 0.22) : Color(white: 0.91) }
    var chipFg: Color { dark ? Color(white: 0.78) : Color(white: 0.36) }
    var border: Color { dark ? Color.white.opacity(0.09) : Color.black.opacity(0.1) }
    var dot: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.09) }
    var shadow: Double { dark ? 0.4 : 1 } // multiplies the light shadows
    let green = Color(red: 0.18, green: 0.75, blue: 0.44)
    let red = Color(red: 0.85, green: 0.25, blue: 0.2)
}

struct HomeStyleKey: EnvironmentKey {
    static let defaultValue = HomeStyle()
}

extension EnvironmentValues {
    var home: HomeStyle {
        get { self[HomeStyleKey.self] }
        set { self[HomeStyleKey.self] = newValue }
    }
}

/// The canvas's dot grid, like a whiteboard.
struct DotGrid: View {
    @Environment(\.home) private var h
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 20
            var y: CGFloat = 10
            while y < size.height {
                var x: CGFloat = 10
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(h.dot))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small grey tag, like "#designed" on a sticky note.
struct Chip: View {
    @Environment(\.home) private var h
    let text: String
    var dot: Color? = nil
    init(_ text: String, dot: Color? = nil) { self.text = text; self.dot = dot }
    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 5, height: 5) }
            Text(text)
        }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(h.chipFg)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(h.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A whole card as a button: dips while pressed, opens on release. Tapping a
/// card feels like tapping a button, and a scroll that starts on it doesn't open.
struct PressToOpen: ViewModifier {
    var enabled = true
    let action: () -> Void
    @State private var pressed = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(Motion.pop, value: pressed)
            .onTapGesture { if enabled { action() } }
            .onLongPressGesture(minimumDuration: 0.6, pressing: { pressed = enabled && $0 }, perform: {})
    }
}

extension View {
    func pressToOpen(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        modifier(PressToOpen(enabled: enabled, action: action))
    }
}

/// A small capsule button in the page's own colors: outlined, or filled (dark).
struct PillButton: ButtonStyle {
    @Environment(\.home) private var h
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(filled ? h.ink : h.chip, in: Capsule())
            .foregroundStyle(filled ? h.canvas : h.ink)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.pop, value: configuration.isPressed)
    }
}

/// The one filled button on the page: a dark pill.
struct PrimaryButton: View {
    @Environment(\.home) private var h
    let title: String
    let theme: VSTheme
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Hovering { on in
                Label(title, systemImage: "arrow.right").labelStyle(TrailingIcon())
                    .font(.system(size: large ? 15 : 13, weight: .semibold)).fixedSize()
                    .padding(.horizontal, large ? 22 : 16).padding(.vertical, large ? 11 : 8)
                    .background(on ? h.ink.opacity(0.85) : h.ink, in: Capsule())
                    .foregroundStyle(h.canvas)
                    .shadow(color: .black.opacity(on ? 0.25 : 0.12), radius: 8, y: 3)
                    .animation(Motion.hover, value: on)
            }
        }
        .buttonStyle(PressDown())
        .hoverEffectDisabled()
    }
}


/// A panel as a card: soft shadow behind, the canvas painted over its corners
/// (covering, not clipping: the editor and terminal are UIKit views and would
/// render offscreen through a mask), and a thin border that turns green when
/// highlighted. Reads the light/dark look from the environment.
struct Card: ViewModifier {
    @Environment(\.home) private var h
    let fill: Color
    var radius: CGFloat = 16
    var highlighted = false
    /// The focused editor's edge: the theme's focus colour, like its tab underline and selections.
    var accent: Color = .accentColor

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(fill).shadow(color: .black.opacity(0.07 * h.shadow), radius: 10, y: 4))
            .background(fill)
            .overlay {
                ZStack {
                    CardCorners(radius: radius).fill(h.canvas, style: FillStyle(eoFill: true))
                    shape.strokeBorder(highlighted ? accent.opacity(0.8) : h.border, lineWidth: highlighted ? 1.5 : 1)
                }
                .allowsHitTesting(false)
            }
    }
}

/// Behind a window's panels: the canvas color with the dot grid.
struct DotCanvas: View {
    @Environment(\.home) private var h
    var body: some View { h.canvas.overlay(DotGrid()).ignoresSafeArea() }
}
