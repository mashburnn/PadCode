import SwiftUI
import WidgetKit

/// Keeps the Home Screen widget's copy of the token, SSH hosts and OS icons
/// current, and opens the machine a widget row links to.
@MainActor
enum WidgetBridge {
    static func publish() {
        let a = Account.shared
        let data = WidgetData(
            token: a.token,
            ssh: SSHHosts.shared.hosts.map { .init(id: $0.machine.id, name: $0.name, host: $0.host, port: $0.port) },
            knownOS: a.knownOS,
            tunnels: a.machines.map { WidgetMachine(id: $0.id, name: $0.name, kind: .tunnel, online: $0.online, os: a.knownOS[$0.id]) })
        guard data != WidgetData.read() else { return }
        data.write()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The saved machine a `padcode://open?machine=…` URL names. Anything else
    /// is ignored: the URL can come from outside PadCode.
    static func machine(for url: URL) async -> MachineInfo? {
        guard let id = WidgetMachine.id(in: url) else { return nil }
        if id == LocalLinux.machine.id { return LocalLinux.machine }
        if let h = SSHHosts.shared.hosts.first(where: { $0.machine.id == id }) { return h.machine }
        if !Account.shared.loadedOnce { await Account.shared.refresh() }
        return Account.shared.machines.first { $0.id == id }
    }
}

/// Every window takes widget links: the window already showing that machine
/// comes forward; any other window opens a new one for it.
struct OpensMachineLinks: ViewModifier {
    var current: MachineInfo?
    /// The home window's own open (it can turn into the workbench on one-window iPads).
    var open: ((MachineInfo, String?) -> Void)?
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .handlesExternalEvents(preferring: Set(current.map { [WidgetMachine.url(for: $0.id).absoluteString] } ?? []), allowing: ["*"])
            .onOpenURL { url in
                Task {
                    guard let m = await WidgetBridge.machine(for: url), m.id != current?.id else { return }
                    // Straight into the last folder used there, like reopening VS Code.
                    let folder = UserDefaults.standard.stringArray(forKey: "recentFolders.\(m.id)")?.first
                    if let open { open(m, folder) } else { openWindow(id: "workbench", value: WorkbenchTarget(machine: m, folder: folder)) }
                }
            }
    }
}

/// The widget's three sizes side by side, inside the app (test screenshots).
struct WidgetPreview: View {
    var entry: MachinesEntry
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            card(.systemSmall, 170, 170)
            card(.systemMedium, 379, 170)
            card(.systemLarge, 379, 379)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(home.chip)
    }

    @Environment(\.home) private var home

    /// Each size as the Home Screen draws it: the widget's own (canvas) background, the system's 22 pt corners.
    private func card(_ family: WidgetFamily, _ w: CGFloat, _ h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return MachinesWidgetView(entry: entry, family: family)
            .padding(16)
            .frame(width: w, height: h)
            .background(home.canvas, in: shape)
            .overlay(shape.strokeBorder(home.border))
            .shadow(color: .black.opacity(0.08 * home.shadow), radius: 12, y: 4)
    }
}
