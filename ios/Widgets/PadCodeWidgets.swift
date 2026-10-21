import SwiftUI
import WidgetKit

@main
struct PadCodeWidgets: WidgetBundle {
    var body: some Widget { MachinesWidget() }
}

/// Your machines and which are online; tap one to open it in PadCode.
struct MachinesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "machines", provider: Provider()) { entry in
            FamilyView(entry: entry)
        }
        .configurationDisplayName("Machines")
        .description("Your desktops, SSH hosts and this iPad's Linux. Tap one to open it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct FamilyView: View {
    @Environment(\.widgetFamily) private var family
    var entry: MachinesEntry
    var body: some View { MachinesWidgetView(entry: entry, family: family) }
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> MachinesEntry {
        MachinesEntry(machines: [
            WidgetMachine(id: "a", name: "Desktop", kind: .tunnel, online: true, os: "mac"),
            WidgetMachine(id: "b", name: "Server", kind: .ssh, online: true, os: "linux"),
            MachineStatus.thisIPad,
        ], signedIn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (MachinesEntry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        Task { completion(await MachineStatus.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MachinesEntry>) -> Void) {
        Task {
            let entry = await MachineStatus.load()
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}
