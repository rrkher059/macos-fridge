import AppKit
import os

/// The only thing the user actually sees.
///
/// A fridge icon in the menu bar. Clicking it drops down the shelves:
/// fresh on top, rotting on the bottom.

// TIER 2 — UNVERIFIED. Never compiled, never run. Depends on runtime
// behavior that was not observable when written. Rewrite freely.
// Do NOT patch symptom-by-symptom.
// (bucket(forDaysOld:) and daysOld(since:) below are the Tier 1 exceptions —
// pure logic, no OS calls.)

let log = Logger(subsystem: "com.fridge.app", category: "main")

final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem?
    private var timer: Timer?

    private let ledger = Ledger()
    private let watcher = Watcher()
    private let painter = MoldPainter()

    // MARK: - Lifecycle

    func start() {
        do {
            try ledger.load()
        } catch {
            // A corrupt/unreadable ledger can't be trusted to say what's
            // already been painted. Continuing with an empty in-memory
            // ledger would treat every already-rotting file as brand new
            // and snapshot its CURRENT (moldy) icon as "clean" — the exact
            // sludge CLAUDE.md decision #2 exists to prevent. Halt instead
            // of silently corrupting the record.
            log.critical("start: ledger failed to load, refusing to run: \(error, privacy: .public)")
            presentLedgerLoadFailureAlert(error: error)
            return
        }

        checkFullDiskAccess()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "🧊"
        item.menu = buildMenu()
        statusItem = item

        watcher.onResults = { [weak self] files in
            self?.runLoop(files: files)
        }
        watcher.start()

        // NSMetadataQueryDidFinishGathering fires once shortly after start(),
        // which delivers the "run once at launch" pass. The timer covers the
        // hourly re-checks after that. See UNCERTAINTIES.md.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.watcher.refresh()
        }
    }

    // MARK: - The loop

    /// Runs at launch and every hour. See CLAUDE.md for the exact steps.
    private func runLoop(files: [WatchedFile]) {
        let seenPaths = Set(files.map(\.path))

        for file in files {
            if ledger.entry(for: file.path) == nil {
                guard let cleanPNG = snapshotCleanIconPNG(path: file.path) else {
                    log.error("runLoop: could not snapshot clean icon for \(file.path, privacy: .public), skipping")
                    continue
                }
                ledger.register(path: file.path, cleanIconPNG: cleanPNG, lastUsed: file.lastUsed)
            }

            guard let entry = ledger.entry(for: file.path) else { continue }
            ledger.updateLastUsed(path: file.path, to: file.lastUsed)

            guard !entry.frozen else { continue }

            let days = daysOld(since: file.lastUsed)
            let newBucket = bucket(forDaysOld: days)
            guard newBucket != entry.currentBucket else { continue }

            let painted = painter.paint(cleanPNG: entry.cleanIconPNG, bucket: newBucket)
            IconWriter.apply(painted, to: file.path)
            ledger.updateBucket(path: file.path, to: newBucket)
        }

        for path in ledger.allPaths where !seenPaths.contains(path) {
            // A single Watcher pass isn't guaranteed to be a complete
            // snapshot (Spotlight indexing lag, an app's atomic-write-then-
            // rename, a momentarily locked file). Confirm the file is
            // actually gone before dropping its ledger entry — forgetting
            // a still-existing file makes it look "new" next pass, which
            // would snapshot its current (possibly already moldy) icon as
            // clean. CLAUDE.md's rule is "files gone from disk"; check disk.
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            ledger.forget(path: path)
        }

        do {
            try ledger.save()
        } catch {
            log.error("runLoop: failed to save ledger: \(error, privacy: .public)")
        }

        statusItem?.menu = buildMenu()
    }

    /// Whole elapsed days since `date`, measured as raw elapsed time rather
    /// than calendar-day alignment, so bucket transitions are deterministic
    /// regardless of what time of day a file was last used.
    private func daysOld(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) / 86400))
    }

    private func bucket(forDaysOld days: Int) -> Bucket {
        switch days {
        case ..<14: return .fresh
        case 14..<21: return .spotty
        case 21..<30: return .moldy
        default: return .fuzzy
        }
    }

    /// Reads the file's CURRENT icon and encodes it as PNG. Only ever called
    /// once per file, at first sighting, before we've painted anything on it.
    private func snapshotCleanIconPNG(path: String) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 512, height: 512)

        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }

        log.debug("snapshotCleanIconPNG: captured \(rep.pixelsWide, privacy: .public)x\(rep.pixelsHigh, privacy: .public) for \(path, privacy: .public)")
        return png
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let sortedPaths = ledger.allPaths.sorted { lhs, rhs in
            (ledger.entry(for: lhs)?.lastUsed ?? .distantPast) > (ledger.entry(for: rhs)?.lastUsed ?? .distantPast)
        }

        for path in sortedPaths {
            guard let entry = ledger.entry(for: path) else { continue }
            let name = (path as NSString).lastPathComponent
            let emoji = entry.frozen ? "❄️" : shelfEmoji(for: entry.currentBucket)
            let item = NSMenuItem(title: "\(emoji) \(name)", action: nil, keyEquivalent: "")

            let submenu = NSMenu()
            let tossItem = submenu.addItem(withTitle: "Toss", action: #selector(tossMenuAction(_:)), keyEquivalent: "")
            tossItem.target = self
            tossItem.representedObject = path
            let freezeItem = submenu.addItem(withTitle: entry.frozen ? "Frozen ❄️" : "Freeze", action: #selector(freezeMenuAction(_:)), keyEquivalent: "")
            freezeItem.target = self
            freezeItem.representedObject = path
            freezeItem.isEnabled = !entry.frozen
            item.submenu = submenu

            menu.addItem(item)
        }

        menu.addItem(.separator())
        let unmoldItem = menu.addItem(withTitle: "Unmold All", action: #selector(unmoldAllMenuAction), keyEquivalent: "")
        unmoldItem.target = self
        let quitItem = menu.addItem(withTitle: "Quit Fridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        return menu
    }

    private func shelfEmoji(for bucket: Bucket) -> String {
        switch bucket {
        case .fresh: return "🟢"
        case .spotty: return "🟡"
        case .moldy: return "🟠"
        case .fuzzy: return "🔴"
        }
    }

    @objc private func tossMenuAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        toss(path: path)
    }

    @objc private func freezeMenuAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        freeze(path: path)
    }

    @objc private func unmoldAllMenuAction() {
        unmoldAll()
    }

    // MARK: - Actions

    /// Move to Trash via NSWorkspace.shared.recycle. Never unlink directly.
    private func toss(path: String) {
        guard ledger.entry(for: path) != nil else { return }
        let url = URL(fileURLWithPath: path)

        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            // recycle's completion handler thread is undocumented here — see
            // UNCERTAINTIES.md. Hop to main defensively before touching the ledger/UI.
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    log.error("toss: recycle failed for \(path, privacy: .public): \(error, privacy: .public)")
                    return
                }
                self.ledger.forget(path: path)
                do {
                    try self.ledger.save()
                } catch {
                    log.error("toss: failed to save ledger: \(error, privacy: .public)")
                }
                self.statusItem?.menu = self.buildMenu()
            }
        }
    }

    /// Mark frozen, strip the custom icon, never rot again.
    private func freeze(path: String) {
        guard ledger.entry(for: path) != nil else { return }
        ledger.setFrozen(path: path, frozen: true)
        ledger.updateBucket(path: path, to: .fresh)
        IconWriter.apply(nil, to: path)

        do {
            try ledger.save()
        } catch {
            log.error("freeze: failed to save ledger: \(error, privacy: .public)")
        }
        statusItem?.menu = buildMenu()
    }

    /// EMERGENCY UNDO. Strips custom icons from every path in the Ledger.
    /// Build and test this FIRST, before pointing the app at any real folder.
    func unmoldAll() {
        for path in ledger.allPaths {
            IconWriter.apply(nil, to: path)
            ledger.updateBucket(path: path, to: .fresh)
        }

        do {
            try ledger.save()
        } catch {
            log.error("unmoldAll: failed to save ledger: \(error, privacy: .public)")
        }
        statusItem?.menu = buildMenu()
    }

    private func presentLedgerLoadFailureAlert(error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Fridge's ledger could not be loaded"
        alert.informativeText = "Fridge will not run until this is fixed, to avoid mistaking already-moldy icons for clean ones. Move or delete the file at \(Ledger.storeURL.path) if you don't need to recover it, then relaunch.\n\nError: \(error.localizedDescription)"
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Permissions

    /// Full Disk Access is required because setIcon writes to the file.
    /// macOS will not prompt. Show a panel with a button that opens:
    /// x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess
    private func checkFullDiskAccess() {
        // No official API to query FDA status directly; probing a
        // TCC-protected file is the common workaround. See UNCERTAINTIES.md.
        let probePath = ("~/Library/Safari/Bookmarks.plist" as NSString).expandingTildeInPath
        guard !FileManager.default.isReadableFile(atPath: probePath) else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Fridge needs Full Disk Access"
        alert.informativeText = "Fridge repaints file icons directly, which macOS only allows with Full Disk Access. It will not do anything until this is granted."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    }
}
