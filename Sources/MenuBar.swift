import AppKit
import os

/// The only thing the user actually sees.
///
/// A fridge icon in the menu bar. Clicking it drops down the shelves:
/// fresh on top, rotting on the bottom.

let log = Logger(subsystem: "com.fridge.app", category: "main")

final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private let ledger = Ledger()
    private let watcher = Watcher()
    private let painter = MoldPainter()

    // MARK: - Lifecycle

    func start() {
        // TODO: create status item, load ledger, check permissions,
        // start watcher, schedule hourly timer, run loop once now
    }

    // MARK: - The loop

    /// Runs at launch and every hour. See CLAUDE.md for the exact steps.
    private func runLoop(files: [WatchedFile]) {
        // 1. New file? ledger.register with its clean icon
        // 2. Frozen? skip
        // 3. Days old -> bucket
        // 4. Bucket unchanged? skip, do not rewrite the icon
        // 5. Changed? painter.paint from clean snapshot, IconWriter.apply
        // 6. Missing from disk? ledger.forget
        // 7. ledger.save()
        // TODO
    }

    private func bucket(forDaysOld days: Int) -> Bucket {
        // 0-13 fresh, 14-20 spotty, 21-29 moldy, 30+ fuzzy
        // TODO
        return .fresh
    }

    // MARK: - Actions

    /// Move to Trash via NSWorkspace.shared.recycle. Never unlink directly.
    private func toss(path: String) {
        // TODO
    }

    /// Mark frozen, strip the custom icon, never rot again.
    private func freeze(path: String) {
        // TODO
    }

    /// EMERGENCY UNDO. Strips custom icons from every path in the Ledger.
    /// Build and test this FIRST, before pointing the app at any real folder.
    func unmoldAll() {
        // TODO
    }

    // MARK: - Permissions

    /// Full Disk Access is required because setIcon writes to the file.
    /// macOS will not prompt. Show a panel with a button that opens:
    /// x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess
    private func checkFullDiskAccess() {
        // TODO
    }
}