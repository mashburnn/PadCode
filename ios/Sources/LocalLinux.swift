import Foundation
import SwiftUI
#if canImport(PadLinux)
import PadLinux
#endif

/// Alpine Linux running inside PadCode (the iSH arm64 emulator). PadCode talks
/// to it directly, in-process (core/src/local.rs): files, terminals, search and
/// language servers work as on any machine, with no SSH and no network.
@MainActor
final class LocalLinux {
    static let shared = LocalLinux()
    static let machine = MachineInfo(name: "This iPad", id: "local:linux", cluster: "local", online: true, protocol: nil)

    private var starting: Task<Void, Error>?
    private var booted = false

    /// Application Support/linux: the root filesystem (meta.db + data/), plus
    /// console.log with the guest kernel's messages.
    private static var root: URL {
        URL.applicationSupportDirectory.appendingPathComponent("linux", isDirectory: true)
    }

    /// Boots Linux the first time (one boot per app process).
    func start(_ progress: @escaping (String) -> Void) async throws {
        if booted { return }
        if let starting { return try await starting.value }
        let t = Task { try await boot(progress) }
        starting = t
        defer { starting = nil }
        try await t.value
    }

    private func boot(_ progress: (String) -> Void) async throws {
        #if canImport(PadLinux)
        let root = Self.root
        if !FileManager.default.fileExists(atPath: root.path) {
            progress("Setting up Linux…")
            try await Self.install(to: root)
        }
        progress("Starting Linux…")
        let path = root.path
        let rc = await Task.detached { padlinux_boot(path) }.value
        guard rc == 0 else { throw LinuxError("Linux didn't start (error \(rc)).") }
        booted = true
        #else
        throw LinuxError("This build doesn't include Linux (run build-linux.sh).")
        #endif
    }

    /// iOS drops a suspended app's listening sockets; iSH can recreate them
    /// (a dev server started in Linux keeps its port).
    func scenePhase(_ phase: ScenePhase) {
        #if canImport(PadLinux)
        guard booted else { return }
        if phase == .background { padlinux_suspend() }
        if phase == .active { padlinux_resume() }
        #endif
    }

    /// Copies the root filesystem out of the app (read-only) the first time.
    private static func install(to root: URL) async throws {
        guard let src = Bundle.main.url(forResource: "linux-root", withExtension: nil) else {
            throw LinuxError("This build doesn't include Linux's files.")
        }
        try await Task.detached {
            let fm = FileManager.default
            let tmp = root.deletingLastPathComponent().appendingPathComponent("linux-installing")
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: tmp)
            try fm.moveItem(at: tmp, to: root) // all or nothing: an interrupted copy starts over
            var dest = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dest.setResourceValues(values)
        }.value
    }
}

struct LinuxError: LocalizedError {
    var errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

extension MachineInfo {
    var isLocal: Bool { cluster == "local" }
}
