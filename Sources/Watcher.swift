import Foundation
import os

// TIER 2 — UNVERIFIED. Never compiled, never run. Depends on runtime
// behavior that was not observable when written. Rewrite freely.
// Do NOT patch symptom-by-symptom.

/// Asks Spotlight what is in Downloads and Desktop, and when each file
/// was last opened.
///
/// macOS updates kMDItemLastUsedDate by itself every time a file is opened.
/// We only read it. We never write it.

struct WatchedFile {
    let path: String
    let lastUsed: Date
    let isDirectory: Bool
}

final class Watcher {

    // TODO: switch to real Downloads + Desktop once the painter has been
    // confirmed safe against ~/FridgeTest. See CLAUDE.md safety rules.
    var scopes: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FridgeTest", isDirectory: true)
    ]

    private let query = NSMetadataQuery()
    private var isRunning = false

    /// Called whenever Spotlight has fresh results.
    var onResults: (([WatchedFile]) -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        query.searchScopes = scopes
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQueryNotification),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQueryNotification),
            name: .NSMetadataQueryDidUpdate, object: query
        )

        query.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }

    /// Force a fresh read right now. Used by the hourly timer. Assumes the
    /// query is already running and gathered — see UNCERTAINTIES.md.
    func refresh() {
        deliverCurrentResults()
    }

    @objc private func handleQueryNotification(_ notification: Notification) {
        deliverCurrentResults()
    }

    private func deliverCurrentResults() {
        query.disableUpdates()
        let files = query.results.compactMap { $0 as? NSMetadataItem }.compactMap(parse)
        query.enableUpdates()

        log.debug("Watcher: delivering \(files.count, privacy: .public) files")
        onResults?(files)
    }

    // MARK: - Parsing

    /// Turn one NSMetadataItem into a WatchedFile.
    ///
    /// Fall back to kMDItemFSCreationDate when kMDItemLastUsedDate is nil.
    /// Return nil for folders, bundles, and anything hidden.
    private func parse(_ item: NSMetadataItem) -> WatchedFile? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
            return nil
        }

        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        guard !isDir.boolValue else { return nil } // folders and bundles are both directories

        let lastUsed = (item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date)
            ?? (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)
            ?? Date()

        return WatchedFile(path: path, lastUsed: lastUsed, isDirectory: false)
    }
}
