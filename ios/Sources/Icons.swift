import SwiftUI
import UIKit

/// VS Code's product icons (the Codicon font).
enum Codicon: String {
    case files = "eaf0", search = "ea6d", settingsGear = "eb51", remote = "eb3a", close = "ea76"
    case chevronRight = "eab6", chevronDown = "eab4", add = "ea60", trash = "ea81", terminal = "ea85"
    case circleFilled = "ea71", error = "ea87", warning = "ea6c", bell = "eaa2", sourceControl = "ea68"
    case ellipsis = "ea7c", newFile = "ea7f", newFolder = "ea80", refresh = "eb37", collapseAll = "eac5"
    case vm = "ea7a", vmConnect = "eba9", vmOutline = "eb7a", plug = "eb2d", debugDisconnect = "ead0"
    case terminalPowershell = "ebc7", terminalBash = "ebca", terminalLinux = "ebc6", chevronUp = "eab7"
    case goToFile = "ea94", check = "eab2", sync = "ea77", account = "eb99", clearAll = "eabf"
    case caseSensitive = "eab1", wholeWord = "eb7e", regex = "eb38", folder = "ea83", folderOpened = "eaf7"
    case file = "ea7b", layoutSidebarLeft = "ebf3", layoutPanel = "ebf2", save = "eb4b", kebab = "eb10"
    case splitHorizontal = "eb56", desktopDownload = "ea78", arrowRight = "ea9c"
    case arrowUp = "eaa1", eye = "ea70", eyeClosed = "eae7", history = "ea82", home = "eb06", rootFolder = "eb46"
    case play = "eb2c", tools = "eb6d", arrowLeft = "ea9b", globe = "eb01", references = "eb36", radioTower = "eb34"
    case emptyWindow = "eae4", multipleWindows = "eb23", listTree = "eb86", openPreview = "eb28"
    case cloudUpload = "eac3", cloudDownload = "eac2", replace = "eb3d", replaceAll = "eb3c", preserveCase = "eb2e", settings = "eb52"
    case info = "ea74", checkAll = "ebb1", loading = "eb19", lightbulb = "ea61"
    case symbolMethod = "ea8c", symbolField = "eb5f", symbolVariable = "ea88", symbolClass = "eb5b"
    case symbolInterface = "eb61", symbolNamespace = "ea8b", symbolProperty = "eb65", symbolEnum = "ea95"
    case symbolEnumMember = "eb5e", symbolKeyword = "eb62", symbolSnippet = "eb66", symbolConstant = "eb5d"
    case symbolStruct = "ea91", symbolEvent = "ea86", symbolOperator = "eb64", symbolTypeParameter = "ea92"
    case symbolText = "ea93", symbolColor = "eb5c", symbolUnit = "ea96", symbolFile = "eb60"
    case symbolMisc = "eb63"

    var glyph: String { String(UnicodeScalar(UInt32(rawValue, radix: 16)!)!) }
}

struct CodiconView: View {
    let icon: Codicon
    var size: CGFloat = 16
    var body: some View {
        Text(icon.glyph).font(.custom("codicon", fixedSize: size))
    }
}

/// VS Code's default file icon theme (Seti), from `vs-seti-icon-theme.json`.
final class SetiIcons {
    static let shared = SetiIcons()

    struct Glyph {
        let char: String
        let color: Color
    }

    private var defs: [String: Glyph] = [:]
    private var byExt: [String: String] = [:]
    private var byName: [String: String] = [:]
    private var byLang: [String: String] = [:]
    private var defaultFile = "_default"

    private init() {
        guard let url = Bundle.main.url(forResource: "vs-seti-icon-theme", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (k, v) in json["iconDefinitions"] as? [String: [String: String]] ?? [:] {
            guard let ch = v["fontCharacter"], let code = UInt32(ch.dropFirst(), radix: 16),
                  let scalar = UnicodeScalar(code) else { continue }
            defs[k] = Glyph(char: String(scalar), color: Color(uiColor: UIColor(vsHex: v["fontColor"] ?? "#cccccc") ?? .gray))
        }
        byExt = json["fileExtensions"] as? [String: String] ?? [:]
        byName = json["fileNames"] as? [String: String] ?? [:]
        byLang = json["languageIds"] as? [String: String] ?? [:]
        defaultFile = json["file"] as? String ?? "_default"
    }

    /// Same precedence as VS Code: file name, then longest extension, then language.
    func glyph(for fileName: String) -> Glyph? {
        let lower = fileName.lowercased()
        if let id = byName[lower], let g = defs[id] { return g }
        var ext = lower
        while let dot = ext.firstIndex(of: ".") {
            ext = String(ext[ext.index(after: dot)...])
            if let id = byExt[ext], let g = defs[id] { return g }
        }
        if let lang = Language.id(for: fileName), let id = byLang[lang], let g = defs[id] { return g }
        return defs[defaultFile]
    }
}

struct FileIcon: View {
    let name: String
    var size: CGFloat = 16
    var body: some View {
        if let g = SetiIcons.shared.glyph(for: name) {
            // Seti glyphs are drawn small; VS Code renders them at 150%.
            Text(g.char).font(.custom("seti", fixedSize: size * 1.5)).foregroundStyle(g.color)
                .frame(width: size + 2, height: size)
        } else {
            CodiconView(icon: .file, size: size).frame(width: size + 2)
        }
    }
}

enum Fonts {
    /// Registers the bundled icon fonts once at launch.
    static func register() {
        for name in ["codicon", "seti"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}
