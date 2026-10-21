import AppIntents
import Network
import SwiftUI
import WidgetKit

/// The widget's state at one moment.
struct MachinesEntry: TimelineEntry {
    var date = Date.now
    var machines: [WidgetMachine] = []
    var signedIn = false
    /// The live check failed; these are the app's last known results.
    var stale = false
}

/// Which machines are online right now: tunnels from the dev-tunnels service,
/// SSH hosts by a quick TCP connect, and Linux on this iPad.
enum MachineStatus {
    static let thisIPad = WidgetMachine(id: "local:linux", name: "This iPad", kind: .local, online: true, os: "linux")

    static func load() async -> MachinesEntry {
        let data = WidgetData.read() ?? WidgetData()
        async let probed = withTaskGroup(of: WidgetMachine.self) { g in
            for h in data.ssh {
                g.addTask {
                    WidgetMachine(id: h.id, name: h.name, kind: .ssh, online: await reachable(h.host, h.port), os: data.knownOS[h.id])
                }
            }
            return await g.reduce(into: []) { $0.append($1) }
        }
        var stale = false
        var tunnels: [WidgetMachine] = []
        if let token = data.token {
            do {
                tunnels = try await fetchTunnels(token: token).map { var m = $0; m.os = data.knownOS[m.id]; return m }
            } catch {
                tunnels = data.tunnels
                stale = true
            }
        }
        let order: [WidgetMachine.Kind] = [.tunnel, .ssh, .local]
        let all = (tunnels + (await probed) + [thisIPad]).sorted {
            ($0.online ? 0 : 1, order.firstIndex(of: $0.kind)!, $0.name.lowercased())
                < ($1.online ? 0 : 1, order.firstIndex(of: $1.kind)!, $1.name.lowercased())
        }
        return MachinesEntry(machines: all, signedIn: data.token != nil, stale: stale)
    }

    /// The same listing as core/src/tunnel.rs `list_machines`, in Swift so the
    /// widget doesn't link the whole Rust core.
    static func fetchTunnels(token: String) async throws -> [WidgetMachine] {
        let url = URL(string: "https://global.rel.tunnels.api.visualstudio.com/tunnels?global=true&labels=vscode-server-launcher&api-version=2023-09-27-preview")!
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("github client_id=01ab8ac9400c4e429b23 \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("padcode-widget/0.1", forHTTPHeaderField: "User-Agent")
        let (body, response) = try await URLSession.shared.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(TunnelList.self, from: body).value.flatMap { $0.value ?? [] }.compactMap { t in
            guard let id = t.tunnelId, let name = t.labels?.first(where: { $0 != "vscode-server-launcher" && !$0.hasPrefix("protocolv") }) ?? t.name
            else { return nil }
            return WidgetMachine(id: id, name: name, kind: .tunnel, online: (t.status?.hostConnectionCount?.count ?? 0) > 0)
        }
    }

    private struct TunnelList: Decodable { var value: [Region] }
    private struct Region: Decodable { var value: [Tunnel]? }
    private struct Tunnel: Decodable {
        var tunnelId: String?
        var name: String?
        var labels: [String]?
        var status: Status?
    }
    private struct Status: Decodable { var hostConnectionCount: Count? }
    /// A plain number or `{ "current": n, "limit": m }`.
    private struct Count: Decodable {
        var count: UInt64
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(UInt64.self) { count = n; return }
            struct Detailed: Decodable { var current: UInt64 }
            count = try c.decode(Detailed.self).current
        }
    }

    /// Whether something accepts TCP connections at host:port within 1.5 s.
    static func reachable(_ host: String, _ port: UInt16) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { cont in
            let q = DispatchQueue(label: "padcode.probe")
            let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            var finished = false
            func finish(_ ok: Bool) {
                guard !finished else { return }
                finished = true
                c.cancel()
                cont.resume(returning: ok)
            }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }
}

/// The refresh button: running it is enough, WidgetKit reloads afterwards.
struct RefreshMachines: AppIntent {
    static var title: LocalizedStringResource = "Refresh Machines"
    func perform() async throws -> some IntentResult { .result() }
}

/// PadCode's canvas colours, light and dark: the same numbers as the app's
/// HomeStyle (Theme.swift), which the widget extension can't import.
private struct WidgetPalette {
    let dark: Bool
    var bg: Color { dark ? Color(white: 0.065) : Color(red: 0.957, green: 0.957, blue: 0.949) }
    var row: Color { dark ? Color(white: 0.145) : .white }
    var fg: Color { dark ? Color(white: 0.93) : Color(white: 0.11) }
    var dim: Color { dark ? Color(white: 0.6) : Color(white: 0.44) }
    var chip: Color { dark ? Color(white: 0.22) : Color(white: 0.91) }
    var border: Color { dark ? .white.opacity(0.09) : .black.opacity(0.07) }
    let green = Color(red: 0.18, green: 0.75, blue: 0.44)
}

struct MachinesWidgetView: View {
    var entry: MachinesEntry
    var family: WidgetFamily
    @Environment(\.colorScheme) private var scheme
    private var W: WidgetPalette { .init(dark: scheme == .dark) } // reads as the old static palette at the call sites

    private var online: [WidgetMachine] { entry.machines.filter(\.online) }

    var body: some View {
        Group {
            if family == .systemSmall {
                small
            } else {
                list(rows: family == .systemLarge ? 10 : 4)
            }
        }
        .foregroundStyle(W.fg)
        .containerBackground(for: .widget) { W.bg }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // The app mark: a small ink tile, like the home page's.
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9, weight: .bold))
                .foregroundStyle(W.bg)
                .frame(width: 20, height: 20)
                .background(W.fg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .widgetAccentable()
            Text("Machines").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if family != .systemSmall { // the small one shows the count big
                Text("\(online.count) online").font(.system(size: 11)).foregroundStyle(W.dim)
            }
            Spacer(minLength: 0)
            Button(intent: RefreshMachines()) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(W.dim)
            }
            .buttonStyle(.plain)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            Text("\(online.count)").font(.system(size: 34, weight: .semibold, design: .rounded))
            Text(online.count == 1 ? "machine online" : "machines online").font(.system(size: 11)).foregroundStyle(W.dim)
            if let m = online.first(where: { $0.kind != .local }) ?? online.first {
                HStack(spacing: 5) {
                    dot(m.online)
                    Text(m.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }
        }
        .widgetURL((online.first(where: { $0.kind != .local }) ?? online.first)?.url)
    }

    private func list(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header.padding(.bottom, 2)
            ForEach(entry.machines.prefix(rows)) { m in
                Link(destination: m.url) { row(m) }
            }
            Spacer(minLength: 0)
            if let note = entry.stale ? "Couldn't refresh · showing last known" : entry.signedIn ? nil : "Sign in to PadCode to see your tunnels" {
                Text(note).font(.system(size: 10)).foregroundStyle(W.dim)
            }
        }
    }

    private func row(_ m: WidgetMachine) -> some View {
        HStack(spacing: 8) {
            Image(systemName: machineSymbol(os: m.os, kind: m.kind)).font(.system(size: 12))
                .frame(width: 18).foregroundStyle(m.online ? W.fg : W.dim)
            Text(m.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(m.online ? W.fg : W.dim)
                .widgetAccentable()
            Spacer(minLength: 4)
            Text(m.kind == .tunnel ? "Tunnel" : m.kind == .ssh ? "SSH" : "iPad").font(.system(size: 10, weight: .medium))
                .foregroundStyle(W.dim)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(W.chip, in: Capsule())
            dot(m.online)
        }
        .padding(.horizontal, 8).frame(maxHeight: 26)
        .background(W.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(W.border))
    }

    private func dot(_ online: Bool) -> some View {
        Circle().fill(online ? W.green : W.dim.opacity(0.6)).frame(width: 6, height: 6)
            .widgetAccentable()
    }
}
