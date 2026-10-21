import Security
import SwiftUI

/// A Linux machine reached over SSH with PadCode's own key.
struct SSHHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16 = 22
    var user: String
    /// The host key the user trusted ("SHA256:…"); nil until the first connection.
    var fingerprint: String?

    /// As a desktop to the rest of the app (windows, restore, recent folders, icons).
    var machine: MachineInfo { MachineInfo(name: name, id: "ssh:\(id.uuidString)", cluster: "ssh", online: true, protocol: nil) }
    var address: String { "\(user)@\(host)\(port == 22 ? "" : ":\(port)")" }
}

extension MachineInfo {
    var isSSH: Bool { cluster == "ssh" }
}

/// Saved SSH hosts, shared by all windows.
@MainActor
final class SSHHosts: ObservableObject {
    static let shared = SSHHosts()
    @Published private(set) var hosts: [SSHHost] = SSHHosts.load()

    private static func load() -> [SSHHost] {
        UserDefaults.standard.data(forKey: "sshHosts").flatMap { try? JSONDecoder().decode([SSHHost].self, from: $0) } ?? []
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(hosts), forKey: "sshHosts")
        WidgetBridge.publish()
    }

    func save(_ h: SSHHost) {
        if let i = hosts.firstIndex(where: { $0.id == h.id }) { hosts[i] = h } else { hosts.append(h) }
        persist()
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        persist()
    }

    func host(for machine: MachineInfo) -> SSHHost? { hosts.first { $0.machine.id == machine.id } }

    /// Remembers (or, with nil, forgets) the host key the user accepted.
    func trust(_ fingerprint: String?, for machine: MachineInfo) {
        guard var h = host(for: machine) else { return }
        h.fingerprint = fingerprint
        save(h)
    }
}

/// PadCode's SSH key, made once on this iPad. The private half stays in the
/// Keychain (this device only); the public half goes in each host's authorized_keys.
enum SSHKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "padcode.ssh",
        kSecAttrAccount as String: "ed25519",
    ]

    static var privateKey: String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// The public key line, creating the key pair the first time.
    static var publicKey: String {
        if let key = privateKey {
            if let pub = UserDefaults.standard.string(forKey: "sshPublicKey") { return pub }
            // Reinstalled: settings were wiped but the Keychain kept the key. Keep
            // using it (hosts already trust it) rather than making a new one.
            if let pub = try? sshPublicKey(privatePem: key) {
                UserDefaults.standard.set(pub, forKey: "sshPublicKey")
                return pub
            }
        }
        guard let k = try? sshGenerateKey() else { return "" }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(k.privatePem.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return "" }
        UserDefaults.standard.set(k.publicOpenssh, forKey: "sshPublicKey")
        return k.publicOpenssh
    }

    /// One line to run on the host: adds PadCode's key to authorized_keys.
    static var setupCommand: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(publicKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }
}

/// Add or edit an SSH host; shows PadCode's key and the one-line setup.
struct SSHHostSheet: View {
    var editing: SSHHost?
    let theme: VSTheme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var copied: String?

    var body: some View {
        let t = theme
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Host") { TextField("name or IP address", text: $host).textContentType(.URL) }
                    LabeledContent("User") { TextField("login name", text: $user).textContentType(.username) }
                    LabeledContent("Port") { TextField("22", text: $port).keyboardType(.numberPad) }
                    LabeledContent("Name") { TextField("optional", text: $name) }
                } header: {
                    Text("Linux machine")
                } footer: {
                    if !port.isEmpty, UInt16(port) == nil { Text("Port must be a number from 1 to 65535.").foregroundStyle(.red) }
                }
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()

                Section {
                    Text(SSHKey.publicKey).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button { copy(SSHKey.setupCommand, "setup") } label: {
                        Label(copied == "setup" ? "Copied" : "Copy Setup Command", systemImage: copied == "setup" ? "checkmark" : "terminal")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { copy(SSHKey.publicKey, "key") } label: {
                        Label(copied == "key" ? "Copied" : "Copy Public Key", systemImage: copied == "key" ? "checkmark" : "key")
                            .contentTransition(.symbolEffect(.replace))
                    }
                } header: {
                    Text("PadCode's key")
                } footer: {
                    Text("Run the setup command once on the machine (it adds this key to ~/.ssh/authorized_keys). The private key never leaves this iPad.")
                }
            }
            .navigationTitle(editing == nil ? "Add SSH Host" : "Edit SSH Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(host.trimmed.isEmpty || user.trimmed.isEmpty || UInt16(port) == nil)
                }
            }
        }
        .tint(t.accent)
        .onAppear {
            guard let e = editing else { return }
            (name, host, port, user) = (e.name, e.host, String(e.port), e.user)
        }
    }

    private func copy(_ s: String, _ what: String) {
        UIPasteboard.general.string = s
        withAnimation(Motion.pop) { copied = what }
    }

    private func save() {
        var h = editing ?? SSHHost(name: "", host: "", user: "")
        let changedAddress = h.host != host.trimmed || h.port != UInt16(port) ?? 22
        h.host = host.trimmed
        h.user = user.trimmed
        h.port = UInt16(port) ?? 22
        h.name = name.trimmed.isEmpty ? h.host : name.trimmed
        if changedAddress { h.fingerprint = nil } // a different machine: trust it afresh
        SSHHosts.shared.save(h)
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Error {
    /// What to show a person: the core's message, not the generated
    /// `PadError.Other(msg: "…")` that `localizedDescription` gives.
    var userMessage: String {
        guard let e = self as? PadError else { return localizedDescription }
        switch e {
        case let .AuthExpired(msg), let .Offline(msg), let .Conflict(msg), let .Closed(msg), let .SshAuth(msg), let .Other(msg),
             let .NoServer(msg, _, _), let .HostKeyUnknown(msg, _), let .HostKeyChanged(msg, _):
            return msg
        }
    }
}
