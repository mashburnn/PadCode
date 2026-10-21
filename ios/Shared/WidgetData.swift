import Foundation
import Security

/// What the Home Screen widget needs from the app. Kept in one Keychain item in
/// a group both can read: free signing has no App Groups, but its profile
/// allows any keychain group under the team.
struct WidgetData: Codable, Equatable {
    struct Host: Codable, Equatable { var id: String; var name: String; var host: String; var port: UInt16 }
    var token: String?
    var ssh: [Host] = []
    var knownOS: [String: String] = [:]
    /// The app's last tunnel listing, shown when the widget can't refresh.
    var tunnels: [WidgetMachine] = []

    private static var query: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "padcode.widget",
            kSecAttrAccount as String: "data",
        ]
        // "$(AppIdentifierPrefix)" (team id plus dot) comes from Info.plist.
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String {
            q[kSecAttrAccessGroup as String] = prefix + "com.mashburnkansana.padcode.shared"
        }
        return q
    }

    static func read() -> WidgetData? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: d)
    }

    func write() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        SecItemDelete(Self.query as CFDictionary)
        var q = Self.query
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// One row in the widget.
struct WidgetMachine: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case tunnel, ssh, local }
    var id: String
    var name: String
    var kind: Kind
    var online: Bool
    var os: String?

    /// Opens this machine in PadCode (handled by `.onOpenURL`).
    var url: URL { Self.url(for: id) }

    static func url(for id: String) -> URL {
        var c = URLComponents()
        c.scheme = "padcode"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "machine", value: id)]
        return c.url!
    }

    /// The machine id in a `padcode://open?machine=…` URL.
    static func id(in url: URL) -> String? {
        guard url.scheme == "padcode", url.host == "open" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "machine" }?.value
    }
}

/// The SF Symbol for a machine: its OS once known, else its kind.
func machineSymbol(os: String?, kind: WidgetMachine.Kind) -> String {
    if kind == .local { return "ipad" }
    switch os {
    case "mac": return "laptopcomputer"
    case "windows": return "pc"
    case "linux": return "server.rack"
    default: return kind == .ssh ? "server.rack" : "desktopcomputer"
    }
}
