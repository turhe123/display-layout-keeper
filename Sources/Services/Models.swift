import CoreGraphics
import Foundation

/// A single saved window: which app owns it, how to recognise it, and where it sat.
struct WindowRecord: Codable, Hashable {
    var bundleID: String
    var title: String
    /// Position of this window among the owning app's windows at capture time (fallback matching key).
    var index: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// All windows captured for one display configuration.
struct LayoutSnapshot: Codable, Identifiable {
    var signature: String
    var name: String
    var detail: String
    var savedAt: Date
    var windows: [WindowRecord]

    var id: String { signature }
}

/// Persists one JSON file per display signature in Application Support, capped to a fixed number of configurations.
final class SnapshotStore {
    static let maxConfigurations = 20

    private let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("DisplayLayoutKeeper/Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads every readable snapshot, newest first. Corrupt files are ignored.
    func loadAll() -> [LayoutSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(LayoutSnapshot.self, from: $0) } }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func save(_ snapshot: LayoutSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(for: snapshot.signature), options: .atomic)
        pruneOldest()
    }

    func delete(signature: String) {
        try? FileManager.default.removeItem(at: fileURL(for: signature))
    }

    private func pruneOldest() {
        let all = loadAll()
        guard all.count > Self.maxConfigurations else { return }
        for snapshot in all.dropFirst(Self.maxConfigurations) { delete(signature: snapshot.signature) }
    }

    private func fileURL(for signature: String) -> URL {
        directory.appendingPathComponent("\(Self.stableHash(signature)).json")
    }

    /// FNV-1a 64-bit hash: deterministic across launches (unlike `Hasher`), safe for file names.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
