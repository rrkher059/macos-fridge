import Foundation

// TIER 1 — pure logic, no OS calls. Reviewed but never compiled.

/// Remembers every file we have ever seen.
///
/// This is the single source of truth. If a file is not in here, we have
/// never touched its icon and must not touch it now.
///
/// Stored at ~/Library/Application Support/Fridge/ledger.json

enum Bucket: String, Codable {
    case fresh, spotty, moldy, fuzzy
}

struct LedgerEntry: Codable {
    /// The file's ORIGINAL icon, captured the first time we saw it, as PNG data.
    /// Every paint starts from this. Never re-read the live icon.
    var cleanIconPNG: Data

    var lastUsed: Date
    var currentBucket: Bucket
    var frozen: Bool
    var firstSeen: Date
}

/// On-disk shape. See CLAUDE.md for the JSON layout.
private struct LedgerFile: Codable {
    var version: Int
    var files: [String: LedgerEntry]
}

final class Ledger {

    private(set) var entries: [String: LedgerEntry] = [:]

    private static let currentVersion = 1

    // MARK: - Disk

    /// Path to ledger.json. Creates the containing folder if missing.
    static var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Fridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.json")
    }

    /// Load from disk. Empty ledger if the file does not exist yet.
    func load() throws {
        let url = Self.storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = [:]
            return
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(LedgerFile.self, from: data)
        entries = file.files
    }

    /// Write to disk. Call at the end of every loop.
    func save() throws {
        let file = LedgerFile(version: Self.currentVersion, files: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: Self.storeURL, options: .atomic)
    }

    // MARK: - Entries

    func entry(for path: String) -> LedgerEntry? {
        entries[path]
    }

    /// First sighting. Snapshots the clean icon. Does nothing if already known.
    func register(path: String, cleanIconPNG: Data, lastUsed: Date) {
        guard entries[path] == nil else { return }
        entries[path] = LedgerEntry(
            cleanIconPNG: cleanIconPNG,
            lastUsed: lastUsed,
            currentBucket: .fresh,
            frozen: false,
            firstSeen: Date()
        )
    }

    func updateBucket(path: String, to bucket: Bucket) {
        guard entries[path] != nil else { return }
        entries[path]?.currentBucket = bucket
    }

    /// Refresh the tracked lastUsed value from a fresh Watcher observation.
    /// Does not affect currentBucket — the caller decides whether to repaint.
    func updateLastUsed(path: String, to date: Date) {
        guard entries[path] != nil else { return }
        entries[path]?.lastUsed = date
    }

    func setFrozen(path: String, frozen: Bool) {
        guard entries[path] != nil else { return }
        entries[path]?.frozen = frozen
    }

    /// File no longer exists on disk. Drop it.
    func forget(path: String) {
        entries.removeValue(forKey: path)
    }

    /// Every path we know about. Used by "Unmold all".
    var allPaths: [String] {
        Array(entries.keys)
    }
}
