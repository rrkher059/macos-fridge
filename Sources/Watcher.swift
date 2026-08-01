import Foundation

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

    /// While building, point this at ~/FridgeTest.
    /// Do NOT point it at real Downloads until the painter is confirmed.
    var scopes: [URL] = []

    private let query = NSMetadataQuery()

    /// Called whenever Spotlight has fresh results.
    var onResults: (([WatchedFile]) -> Void)?

    func start() {
        // TODO: configure predicate + searchScopes, observe
        // NSMetadataQueryDidFinishGathering and
        // NSMetadataQueryDidUpdate, then query.start()
    }

    func stop() {
        // TODO
    }

    /// Force a fresh read right now. Used by the hourly timer.
    func refresh() {
        // TODO
    }

    // MARK: - Parsing

    /// Turn one NSMetadataItem into a WatchedFile.
    ///
    /// Fall back to kMDItemFSCreationDate when kMDItemLastUsedDate is nil.
    /// Return nil for folders, bundles, and anything hidden.
    private func parse(_ item: NSMetadataItem) -> WatchedFile? {
        // TODO
        return nil
    }
}