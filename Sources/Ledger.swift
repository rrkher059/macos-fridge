import Foundation
import CryptoKit

/// Remembers every file we have ever seen.
///
/// This is the single source of truth. If a file is not in here, we have
/// never touched its icon and must not touch it now.
///
/// Stored at ~/Library/Application Support/Fridge/ledger.json
///
/// Clean icon snapshots are NOT stored inline here — see DECISIONS.md.
/// A real Downloads folder can hold thousands of files; embedding a
/// ~200KB+ base64 PNG per entry in one JSON file that gets rewritten
/// wholesale made ledger.json balloon toward a gigabyte and made every
/// save catastrophically slow. Each clean icon is its own PNG file in
/// `icons/`, named by a stable hash of the path; the entry stores only
/// that filename.

enum Bucket: String, Codable {
    case fresh, spotty, moldy, fuzzy
}

struct LedgerEntry: Codable {
    /// Filename (within Ledger.iconsDirectory) of the file's ORIGINAL icon,
    /// captured the first time we saw it. Every paint starts from this.
    /// Never re-read the live icon.
    var cleanIconFilename: String

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

    private static let currentVersion = 2

    // MARK: - Disk

    /// Path to ledger.json. Creates the containing folder if missing.
    static var storeURL: URL {
        let dir = supportDirectory
        return dir.appendingPathComponent("ledger.json")
    }

    /// Where clean-icon PNGs live, one file per tracked path. Creates the
    /// directory if missing.
    static var iconsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var supportDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Fridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stable (not process-randomized, unlike String.hashValue) filename for
    /// a given path's clean icon.
    private static func iconFilename(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).png"
    }

    /// Load from disk. Empty ledger if the file does not exist yet. Sweeps
    /// any icon file in iconsDirectory that no surviving entry references —
    /// e.g. left behind by a file that was tossed or forgotten.
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
        sweepOrphanedIcons()
    }

    private func sweepOrphanedIcons() {
        let referenced = Set(entries.values.map(\.cleanIconFilename))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.iconsDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for fileURL in contents where !referenced.contains(fileURL.lastPathComponent) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Write to disk. Cheap now that entries don't carry image data — safe
    /// to call after every file during a long scan, not just once at the
    /// end. See DECISIONS.md: a crash between painting a file and saving
    /// the Ledger's record of it used to leave a real file repainted with
    /// no way for Unmold All to find it again.
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

    /// The file's original clean icon, read from its own file on disk.
    func cleanIconData(for path: String) -> Data? {
        guard let entry = entries[path] else { return nil }
        return try? Data(contentsOf: Self.iconsDirectory.appendingPathComponent(entry.cleanIconFilename))
    }

    /// First sighting. Snapshots the clean icon to its own file. Does
    /// nothing if already known. Returns false if the icon file couldn't be
    /// written — in that case no entry is created, rather than creating one
    /// that points at a file that doesn't exist, which would silently and
    /// permanently block this path from ever being painted (cleanIconData
    /// would return nil forever, with no way to recover short of forgetting
    /// and re-registering the path).
    @discardableResult
    func register(path: String, cleanIconPNG: Data, lastUsed: Date) -> Bool {
        guard entries[path] == nil else { return true }
        let filename = Self.iconFilename(forPath: path)
        do {
            try cleanIconPNG.write(to: Self.iconsDirectory.appendingPathComponent(filename), options: .atomic)
        } catch {
            return false
        }
        entries[path] = LedgerEntry(
            cleanIconFilename: filename,
            lastUsed: lastUsed,
            currentBucket: .fresh,
            frozen: false,
            firstSeen: Date()
        )
        return true
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

    /// File no longer exists on disk. Drop it, and its clean-icon file.
    func forget(path: String) {
        if let entry = entries[path] {
            try? FileManager.default.removeItem(at: Self.iconsDirectory.appendingPathComponent(entry.cleanIconFilename))
        }
        entries.removeValue(forKey: path)
    }

    /// Every path we know about. Used by "Unmold all".
    var allPaths: [String] {
        Array(entries.keys)
    }
}
