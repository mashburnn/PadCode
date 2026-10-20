import SwiftUI
import UniformTypeIdentifiers

/// Drops onto the Explorer or the window: files and folders from other apps
/// (Files, Photos…) are uploaded to the desktop; rows dragged within the
/// Explorer are moved.
@MainActor
func handleDrop(_ providers: [NSItemProvider], into dir: String, wb: Workbench) -> Bool {
    guard wb.desktop != nil, !dir.isEmpty, !providers.isEmpty else { return false }
    Task {
        var files: [URL] = []
        for p in providers {
            // Our own Explorer rows are dragged as their path (plain text, no file name).
            if p.suggestedName == nil, p.canLoadObject(ofClass: String.self),
               let s = await p.loadString(), !s.contains("\n") {
                if s.hasPrefix(TabDrag.mark) { continue } // an editor tab, not a file
                if wb.isWithin(s, wb.root) {
                    if s != wb.root { wb.requestMove(s, toDir: dir) }
                    continue
                }
            }
            if let url = await p.copyDroppedFile() { files.append(url) }
        }
        guard !files.isEmpty else { return }
        await wb.upload(files, to: dir)
        for f in files { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
    }
    return true
}

extension NSItemProvider {
    func loadString() async -> String? {
        await withCheckedContinuation { cont in
            _ = loadObject(ofClass: String.self) { s, _ in cont.resume(returning: s) }
        }
    }

    /// Copies the dropped file or folder somewhere we own: the URL handed to the
    /// completion handler is only valid inside it.
    func copyDroppedFile() async -> URL? {
        let types = registeredTypeIdentifiers
        let type = types.first { UTType($0)?.conforms(to: .folder) == true }
            ?? types.first { UTType($0)?.conforms(to: .data) == true }
            ?? types.first
        guard let type else { return nil }
        let name = suggestedName
        return await withCheckedContinuation { cont in
            _ = loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return cont.resume(returning: nil) }
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("drops", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                // The temp file's own name keeps the extension; suggestedName may not.
                var fileName = url.lastPathComponent
                if fileName.isEmpty || fileName.hasPrefix(".") || fileName.contains("NSIRD") {
                    fileName = name ?? "Dropped File"
                }
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(fileName)
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
