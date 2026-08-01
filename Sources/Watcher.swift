import Foundation
import CoreServices
import os

/// Scans Downloads + Desktop for files, and when each was last opened.
///
/// macOS updates kMDItemLastUsedDate by itself every time a file is opened.
/// We only read it. We never write it.
///
/// This started as an NSMetadataQuery (Spotlight search) implementation, but
/// that returned zero results in practice: the "match everything" predicate
/// (`kMDItemFSName LIKE '*'`) silently matches nothing — confirmed with
/// `mdfind -onlyin <dir> "kMDItemFSName LIKE '*'"` returning empty even
/// though the same directory's files are indexed and queryable by other
/// predicates. Swapping to a working predicate (`kMDItemContentType == '*'`)
/// still returned zero results from NSMetadataQuery specifically, even
/// though `mdfind` on the command line returns correct results for the
/// same directory and predicate — a client-side NSMetadataQuery quirk, not
/// a Spotlight indexing gap. Per CLAUDE.md's own escape hatch ("if
/// NSMetadataQuery proves flaky in under 20 minutes of work, drop it"),
/// this rewrites the whole thing as a plain FileManager directory scan.
///
/// Per-file "last used" still comes from Spotlight — just the low-level
/// per-item MDItemCreate/MDItemCopyAttribute API instead of a search query.
/// This matters: URLResourceValues.contentAccessDate (plain POSIX atime)
/// was tried as a simpler substitute and rejected — it bumps on ANY read,
/// including our own icon-snapshotting, which would silently reset every
/// file to "fresh" on every loop pass and defeat the entire premise of the
/// app. kMDItemLastUsedDate only updates when Launch Services actually
/// opens the file for the user, which is the correct signal.

struct WatchedFile {
    let path: String
    let lastUsed: Date
    let isDirectory: Bool
}

final class Watcher {

    // Reverted to FridgeTest after a real run against Downloads found 5,106
    // files — a roughly hour-long first scan that mass-repaints every file
    // older than 14 days with no incremental checkpointing. Re-enable only
    // after runLoop saves progress per-file (see MenuBar.swift) has been
    // verified safe against a folder that size. See DECISIONS.md.
    var scopes: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FridgeTest", isDirectory: true)
    ]

    /// Called whenever a scan produces a fresh file list.
    var onResults: (([WatchedFile]) -> Void)?

    /// Kicks off the first scan. "Run once at launch" is just calling this.
    func start() {
        refresh()
    }

    func stop() {}

    /// Scan every scope right now. Used at launch and by the hourly timer.
    /// Runs off the main thread — Downloads/Desktop can hold thousands of
    /// files, and enumerating them plus reading Spotlight metadata per file
    /// must not block the window. `onResults` is always called back on the
    /// main thread, since its only listener (MenuBarController.runLoop)
    /// touches AppKit UI.
    func refresh() {
        // Snapshot scopes on the caller's thread (always main — start(),
        // the hourly timer, and the "Add Downloads and Desktop" flow are
        // all main-thread) before handing off to the background queue.
        // `scopes` is a plain var with no synchronization; reading it from
        // inside the background closure instead would race against
        // confirmEnableRealFolders() reassigning it from the main thread
        // while a scan (which can take close to an hour against a real
        // Downloads folder) is still in flight.
        let scopesSnapshot = scopes
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var files: [WatchedFile] = []
            for scope in scopesSnapshot {
                files.append(contentsOf: self.scan(scope))
            }
            log.debug("Watcher: delivering \(files.count, privacy: .public) files")
            DispatchQueue.main.async {
                self.onResults?(files)
            }
        }
    }

    // MARK: - Scanning

    private func scan(_ root: URL) -> [WatchedFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            log.error("Watcher: could not enumerate \(root.path, privacy: .public)")
            return []
        }

        var results: [WatchedFile] = []
        for case let url as URL in enumerator {
            guard let file = parse(url) else { continue }
            results.append(file)
        }
        return results
    }

    /// Turn one filesystem URL into a WatchedFile.
    ///
    /// Falls back to kMDItemFSCreationDate when kMDItemLastUsedDate is nil.
    /// Returns nil for hidden files, folders, and app bundles/packages.
    private func parse(_ url: URL) -> WatchedFile? {
        guard !url.lastPathComponent.hasPrefix(".") else { return nil }

        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return nil
        }
        if values.isDirectory == true { return nil }
        if values.isPackage == true { return nil }

        let path = url.path
        let lastUsed = lastUsedDate(forPath: path) ?? creationDate(forPath: path) ?? Date()

        return WatchedFile(path: path, lastUsed: lastUsed, isDirectory: false)
    }

    private func lastUsedDate(forPath path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private func creationDate(forPath path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemFSCreationDate) as? Date
    }
}
