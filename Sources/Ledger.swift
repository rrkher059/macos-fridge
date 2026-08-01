import Foundation
import AppKit

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
    /// The file's ORIGINAL icon, captured the first time we saw it.
    /// Every paint starts from this. Never re-read the live icon.
    var cleanIconPNG: Data

    var lastUsed: Date
    var currentBucket: Bucket
    var frozen: Bool
    var firstSeen: Date
}

final class Ledger {

    private(set) var entries: [String: LedgerEntry] = [:]

    // MARK: - Disk

    /// Path to ledger.json. Creates the containing folder if missing.
    static var storeURL: URL {
        // TODO
        fatalError("unimplemented")
    }

    /// Load from disk. Empty ledger if the file does not exist yet.
    func load() throws {
        // TODO
    }

    /// Write to disk. Call at the end of every loop.
    func save() throws {
        // TODO
    }

    // MARK: - Entries

    func entry(for path: String) -> LedgerEntry? {
        // TODO
        return nil
    }

    /// First sighting. Snapshots the clean icon. Does nothing if already known.
    func register(path: String, cleanIcon: NSImage, lastUsed: Date) {
        // TODO
    }

    func updateBucket(path: String, to bucket: Bucket) {
        // TODO
    }

    func setFrozen(path: String, frozen: Bool) {
        // TODO
    }

    /// File no longer exists on disk. Drop it.
    func forget(path: String) {
        // TODO
    }

    /// Every path we know about. Used by "Unmold all".
    var allPaths: [String] {
        // TODO
        return []
    }
}