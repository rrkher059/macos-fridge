import AppKit
import os

/// The only thing the user actually sees.
///
/// A normal window listing every tracked file, grouped into shelves by
/// freshness: fresh on top, rotting toward the bottom.
///
/// This was originally a menu bar status item. It was dropped — see
/// DECISIONS.md — after the status item's button consistently laid out
/// with a zero-height frame and never rendered on screen, across dozens of
/// launches, for reasons that were never resolved.

let log = Logger(subsystem: "com.fridge.app", category: "main")

final class MenuBarController: NSObject {

    private var timer: Timer?
    private var windowController: NSWindowController?
    private var scrollView: NSScrollView?

    private let ledger = Ledger()
    private let watcher = Watcher()
    private let painter = MoldPainter()

    private static let sections: [(Bucket, String)] = [
        (.fresh, "Fresh"),
        (.spotty, "Spotty"),
        (.moldy, "Moldy"),
        (.fuzzy, "Fuzzy"),
    ]

    // MARK: - Lifecycle

    func start() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let isFirstRun = !FileManager.default.fileExists(atPath: Ledger.storeURL.path)

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

        if isFirstRun {
            presentFirstRunExplainer()
        }
        checkFullDiskAccess()
        presentWindow()

        watcher.onResults = { [weak self] files in
            self?.runLoop(files: files)
        }
        watcher.start()

        // Watcher.start() kicks off an async scan that delivers the
        // "run once at launch" pass via onResults shortly after. The timer
        // covers the hourly re-checks after that.
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

            // paint() returning nil is only meaningful for .fresh (the
            // "strip back to original" signal). For any other bucket it
            // means the paint genuinely failed (missing overlay, undecodable
            // clean snapshot) — applying nil there would strip the icon to
            // the system default while still recording the bucket as
            // successfully painted, permanently desyncing the Ledger from
            // the file's actual on-disk icon (every future pass would then
            // see newBucket == entry.currentBucket and skip forever).
            if newBucket == .fresh {
                IconWriter.apply(nil, to: file.path)
                ledger.updateBucket(path: file.path, to: newBucket)
            } else if let painted = painter.paint(cleanPNG: entry.cleanIconPNG, bucket: newBucket) {
                IconWriter.apply(painted, to: file.path)
                ledger.updateBucket(path: file.path, to: newBucket)
            } else {
                log.error("runLoop: paint failed for \(file.path, privacy: .public), bucket \(newBucket.rawValue, privacy: .public) — leaving unchanged")
            }
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

        refreshWindowContent()
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

    // MARK: - Window

    private func presentWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fridge"
        window.center()
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scrollView

        let unmoldButton = ClosureButton(title: "Unmold All") { [weak self] in self?.unmoldAll() }
        let refreshButton = ClosureButton(title: "Refresh Now") { [weak self] in self?.watcher.refresh() }
        let quitButton = ClosureButton(title: "Quit Fridge") { NSApp.terminate(nil) }
        let bottomBar = NSStackView(views: [unmoldButton, refreshButton, quitButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8

        let contentStack = NSStackView(views: [scrollView, bottomBar])
        contentStack.orientation = .vertical
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(contentStack)
        window.contentView = contentView
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        windowController = controller

        refreshWindowContent()
    }

    /// Brings the window back after it's been closed. `isReleasedWhenClosed
    /// = false` keeps the NSWindow (and its NSWindowController) alive when
    /// closed, so this just needs to re-show it — no rebuild needed, though
    /// refreshing the content is cheap insurance against stale data.
    func reopenWindow() {
        refreshWindowContent()
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func refreshWindowContent() {
        guard let scrollView else { return }
        let grid = buildGrid()
        scrollView.documentView = grid
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -8),
        ])
    }

    /// One NSGridView for the whole list — a bucket's rows plus its header
    /// all share the same column grid, which is what gives every row's
    /// icon/name/time/buttons consistent alignment down the window.
    private func buildGrid() -> NSGridView {
        let grid = NSGridView(numberOfColumns: 6, rows: 0)
        grid.columnSpacing = 10
        grid.rowSpacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false

        let entries: [(path: String, entry: LedgerEntry)] = ledger.allPaths.compactMap { path in
            guard let entry = ledger.entry(for: path) else { return nil }
            return (path, entry)
        }

        var wroteAnyRow = false
        let maxRowsPerSection = 8

        for (bucket, title) in Self.sections {
            // Oldest (worst) first within a section — the most actionable
            // items surface at the top, and it's what determines which
            // rows survive the cap below.
            let inBucket = entries
                .filter { $0.entry.currentBucket == bucket }
                .sorted { $0.entry.lastUsed < $1.entry.lastUsed }
            guard !inBucket.isEmpty else { continue }
            wroteAnyRow = true

            let header = NSTextField(labelWithString: "\(title) — \(inBucket.count)")
            header.font = .boldSystemFont(ofSize: 12)
            header.textColor = .secondaryLabelColor
            let headerRow = grid.addRow(with: [header])
            headerRow.mergeCells(in: NSRange(location: 0, length: 6))
            headerRow.topPadding = 10

            for (path, entry) in inBucket.prefix(maxRowsPerSection) {
                grid.addRow(with: rowViews(path: path, entry: entry))
            }

            if inBucket.count > maxRowsPerSection {
                let more = NSTextField(labelWithString: "+\(inBucket.count - maxRowsPerSection) more")
                more.textColor = .secondaryLabelColor
                more.font = .systemFont(ofSize: 11)
                let moreRow = grid.addRow(with: [more])
                moreRow.mergeCells(in: NSRange(location: 0, length: 6))
            }
        }

        if !wroteAnyRow {
            let empty = NSTextField(labelWithString: "Nothing rotting. Your fridge is clean.")
            empty.textColor = .secondaryLabelColor
            let row = grid.addRow(with: [empty])
            row.mergeCells(in: NSRange(location: 0, length: 6))
        }

        return grid
    }

    private func rowViews(path: String, entry: LedgerEntry) -> [NSView] {
        let name = (path as NSString).lastPathComponent

        let iconView = NSImageView(image: currentIcon(forPath: path))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
        ])

        let nameLabel = NSTextField(labelWithString: entry.frozen ? "❄️ \(name)" : name)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeLabel = NSTextField(labelWithString: relativeTime(since: entry.lastUsed))
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.font = .systemFont(ofSize: 11)

        let revealButton = ClosureButton(title: "Reveal") { [weak self] in self?.reveal(path: path) }
        let freezeButton = ClosureButton(title: entry.frozen ? "Frozen" : "Freeze") { [weak self] in self?.freeze(path: path) }
        freezeButton.isEnabled = !entry.frozen
        let tossButton = ClosureButton(title: "Toss") { [weak self] in self?.confirmToss(path: path) }

        return [iconView, nameLabel, timeLabel, revealButton, freezeButton, tossButton]
    }

    /// The file's actual current on-disk icon — mold and all, if any is
    /// currently applied. Deliberately reads live from disk rather than
    /// recompositing from the Ledger's clean snapshot: the file's real icon
    /// already reflects the true current state, which is exactly what a
    /// row in this window should show.
    private func currentIcon(forPath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    private func relativeTime(since date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    private func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func confirmToss(path: String) {
        let name = (path as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Toss \u{201C}\(name)\u{201D}?"
        alert.informativeText = "This moves the file to Trash."
        alert.addButton(withTitle: "Toss")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        toss(path: path)
    }

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
                self.refreshWindowContent()
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
        refreshWindowContent()
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
        refreshWindowContent()
    }

    /// Shown once, only when no ledger file exists yet on disk — i.e. the
    /// very first launch. CLAUDE.md: "Explain in one sentence what the app
    /// is about to do before it does it."
    private func presentFirstRunExplainer() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Fridge repaints icons of old files in Downloads and Desktop so they visually rot until you deal with them."
        alert.addButton(withTitle: "Got it")
        alert.window.level = .floating
        alert.runModal()
    }

    private func presentLedgerLoadFailureAlert(error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Fridge's ledger could not be loaded"
        alert.informativeText = "Fridge will not run until this is fixed, to avoid mistaking already-moldy icons for clean ones. Move or delete the file at \(Ledger.storeURL.path) if you don't need to recover it, then relaunch.\n\nError: \(error.localizedDescription)"
        alert.addButton(withTitle: "Quit")
        alert.window.level = .floating
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Permissions

    /// Full Disk Access is required because setIcon writes to the file.
    /// macOS will not prompt. Show a panel with a button that opens:
    /// x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess
    ///
    /// There is no official API to query FDA status directly. Probing a
    /// TCC-protected proxy file (e.g. ~/Library/Safari/Bookmarks.plist) was
    /// tried and confirmed flaky — it gave different results across
    /// otherwise-identical launches (see UNCERTAINTIES.md #11). Instead this
    /// does the actual thing we care about — setIcon on a real file in a
    /// TCC-gated folder — and checks its real return value. Downloads and
    /// Desktop are the folders CLAUDE.md targets; a throwaway hidden file in
    /// Desktop is created, icon-set, checked, and removed immediately.
    private func checkFullDiskAccess() {
        guard !canSetIconInProtectedFolder() else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Fridge needs Full Disk Access"
        alert.informativeText = "Fridge repaints file icons directly, which macOS only allows with Full Disk Access. It will not do anything until this is granted."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        // A plain NSAlert can render BEHIND other apps' windows and sit
        // there invisibly while runModal() blocks forever if this app isn't
        // properly frontmost yet — confirmed by launching, waiting, and
        // finding the process still alive minutes later with no visible
        // dialog anywhere on screen. Forcing the alert's own window above
        // the normal window layer fixes it regardless of activation timing.
        alert.window.level = .floating

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Creates a throwaway hidden file in Desktop, attempts setIcon on it,
    /// and checks the real return value — then removes every trace. This is
    /// the actual operation the app needs (setIcon in a TCC-gated folder),
    /// not a guess based on some other file's readability.
    private func canSetIconInProtectedFolder() -> Bool {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let probe = desktop.appendingPathComponent(".fridge-fda-probe-\(UUID().uuidString)")

        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            // Can't even create the file — treat as no access rather than
            // crashing on an unrelated filesystem problem.
            return false
        }
        defer {
            NSWorkspace.shared.setIcon(nil, forFile: probe.path, options: [])
            try? FileManager.default.removeItem(at: probe)
        }

        let probeIcon = NSWorkspace.shared.icon(forFile: probe.path)
        return NSWorkspace.shared.setIcon(probeIcon, forFile: probe.path, options: [])
    }
}

/// A plain NSButton that runs a captured closure instead of needing a
/// separate target/selector dance.
private final class ClosureButton: NSButton {
    private let onClick: () -> Void

    init(title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(handleClick)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleClick() {
        onClick()
    }
}
