# Uncertainties

This file was originally written blind on Windows with no Swift toolchain.
Every entry below has now been checked on a real Mac. Each is marked
RESOLVED (confirmed working as assumed), FIXED (was wrong, now corrected),
or CONFIRMED-BROKEN (a real bug found, documented, not yet/never fixed).

---

### 1. Initial run relies on NSMetadataQueryDidFinishGathering — RESOLVED (moot)
Moot: Watcher no longer uses NSMetadataQuery at all (see #4). The rewritten
`Watcher.start()` scans synchronously and calls `onResults` before
returning, so "run once at launch" is just a direct function call with no
race to worry about.

### 2. NSMetadataQuery.searchScopes recursion — RESOLVED, but moot
Confirmed recursive: a file in `~/FridgeTest/sub/deep.txt` was returned
correctly. Moot now since NSMetadataQuery was dropped (#4) — the
replacement `FileManager.enumerator` is explicitly recursive by default
(with `.skipsPackageDescendants` so it doesn't descend into `.app`
bundles).

### 3. NSMetadataQuery notifications arrive on the main thread — RESOLVED, moot
Moot — no more NSMetadataQuery. The new Watcher has no async
notifications at all; `refresh()` runs synchronously on whatever thread
calls it (always the main thread, called from `MenuBarController`).

### 4. The predicate `%K LIKE '*'` matches "everything" — CONFIRMED-BROKEN, FIXED BY REWRITE
This was wrong, and it's the big one. `kMDItemFSName LIKE '*'` returns
**zero results**, confirmed directly with:
```
mdfind -onlyin ~/FridgeTest "kMDItemFSName LIKE '*'"   # empty
mdfind -onlyin ~/FridgeTest "kMDItemContentType == '*'" # returns everything
```
`LIKE` wildcards silently don't work for that attribute in Spotlight's
query language — no error, just nothing. Swapping the predicate to
`kMDItemContentType == '*'` fixed `mdfind`, but **NSMetadataQuery itself
still returned zero results** even with the corrected predicate, while
`mdfind` (a separate process talking to the same index) returned correct
results for the identical directory and predicate. This is a client-side
NSMetadataQuery quirk, not a Spotlight indexing gap.

Per CLAUDE.md's own escape hatch ("if NSMetadataQuery proves flaky in
under 20 minutes of work, drop it"), `Watcher.swift` was rewritten from
scratch as a plain `FileManager.enumerator` directory scan. Per-file
"last used" now comes from the low-level `MDItemCreate` /
`MDItemCopyAttribute(kMDItemLastUsedDate)` API instead of a search query —
same underlying Spotlight data, no predicate/search-scope involved at all.

Also tried and rejected: `URLResourceValues.contentAccessDate` (plain
POSIX atime) as a simpler substitute. Rejected because it bumps on *any*
read, including our own icon-snapshotting — which would silently reset
every file back to "fresh" every single hourly pass and defeat the app's
entire premise. `kMDItemLastUsedDate` only updates when Launch Services
actually opens the file for the user, which is the correct signal, and was
confirmed to update independent of our own file reads.

### 5. Icon snapshot captures a real 512x512 bitmap, not upscaled — RESOLVED (better than expected)
Snapshots come back at **1024x1024** (retina/@2x), sharp, not blurry —
confirmed by dumping the raw captured PNG and viewing it directly, not
just trusting the logged dimensions.

### 6. Bundle.main.url(forResource:) finds Assets/*.png — CONFIRMED-BROKEN, FIXED
The PNGs were added to the project as an asset catalog
(`Assets.xcassets`), not loose bundle resources, so
`Bundle.main.url(forResource:withExtension:)` returns nil for all three.
Fixed: `MoldPainter.init()` now loads overlays with `NSImage(named:)`,
which resolves through the asset catalog correctly. Confirmed all three
load at 1024x1024.

### 7. NSImage(size:flipped:drawingHandler:) composites without flip/crop — RESOLVED
Composited icons were dumped at full 1024x1024 resolution and inspected
directly (not just at a glance in Finder): overlay sits right-side-up,
alpha is preserved, the base icon (including real content-derived icons
like a Chrome-associated PDF icon, or a text file's live content preview)
remains fully recognizable underneath. No flip, no crop, no offset.
Checked at three sizes: ~16px (Finder list view), ~128px (Finder icon
view), and 1024px (direct dump) — consistent at all three. `spotty` and
`fuzzy` overlays were only bucket-tested end-to-end (not individually
dumped at full res like `moldy` was), but they go through the identical
`composite()` code path and were confirmed to load at correct pixel
dimensions, so a size/orientation bug specific to one and not the others
is unlikely.

### 8. setIcon shows up in Finder without an extra refresh nudge — RESOLVED
Confirmed with a Finder window open and visible the whole time: both
applying mold and restoring the original icon (via `unmoldAll`) appeared
within about a second with zero manual refresh, zero extra code needed.
`IconWriter.apply` needs no `noteFileSystemChanged` call.

### 9. NSWorkspace.recycle's completion handler thread — not re-tested
Not explicitly re-verified this session (didn't exercise the Toss action
via the real UI, only DebugCLI/unmoldAll paths). The existing defensive
`DispatchQueue.main.async` wrap is safe regardless of the answer, so this
is low-priority and left as-is per the original entry's own conclusion.

### 10. AppDelegate stays alive via app.run() — RESOLVED
Confirmed via `applicationDidFinishLaunching` firing every launch (menu
bar logic runs, ledger loads, watcher scans) across dozens of manual
launches this session.

### 11. Full Disk Access probe via Bookmarks.plist — CONFIRMED FLAKY (real, unresolved)
The probe (`isReadableFile` on `~/Library/Safari/Bookmarks.plist`) was
observed to return **different results across otherwise-identical
launches** of the same unmodified binary — sometimes the FDA alert
appeared, sometimes it silently didn't (both with FDA genuinely not
granted, confirmed by Fridge's absence from the Full Disk Access list in
System Settings the whole time). This matches the original entry's own
stated risk exactly. Root cause not identified. Left as-is since this
matches CLAUDE.md's specified mechanism and a better proxy isn't obviously
available, but be aware the FDA prompt may not reliably appear every
first launch.

### 12. Data.hashValue is stable enough within one run for the paint cache — not re-tested
Not specifically exercised this session. Low risk, left as-is per the
original entry.

### 13. Rebuilding statusItem.menu on every loop pass while open — not re-tested
Not exercised (couldn't get the status item to render on-screen at all
this session — see NEW FINDING below — so there was no open menu to test
against). Left as a real open question for Phase 2 menu work.

### 14. The Xcode project didn't exist yet — RESOLVED
Project now exists, target "Fridge" + "FridgeTests", builds clean with
`xcodebuild -scheme Fridge build`. `ENABLE_APP_SANDBOX = NO` explicit, no
entitlements file, ad-hoc code signing works non-interactively.
`xcodebuild test` passes both `LedgerTests` and `MenuBarBucketTests`.

### 15. os.Logger interpolation of bare Error values compiles — RESOLVED
Compiles fine under this SDK (Xcode 17F113 / macOS SDK 26.5). No changes
needed.

---

## NEW FINDING — status item does not render on screen (unresolved, significant)

Not one of the original 15, discovered during Phase 1 testing. The menu
bar icon — the app's *only* UI — never became visible on screen across
~15 separate launches (raw binary execution, `open`, with/without
`autosaveName`, with/without explicit `NSApp.activate()`), despite the
AppKit-side state being fully valid every time:

- `item.isVisible == true`, `item.button != nil`, correct
  `NSStatusItem.squareLength`, correct `.accessory` activation policy.
- System log (`log show --predicate 'process == "ControlCenter"'`) shows
  Control Center registering a real scene for the item every time, but
  logging `Created ephemaral instance ... with positioning .ephemeral`
  followed by the scene state cycling to `XX-None` (deactivated) within
  ~100–300ms of creation — every single time, from the very first launch
  onward, with a consistent short delay.
- Tried and did not fix it: setting `item.autosaveName`, explicitly
  calling `NSApp.setActivationPolicy(.accessory)` +
  `NSApp.activate(ignoringOtherApps: true)` before creating the item,
  waiting 25+ seconds before checking, using plain unambiguous text
  (`"FRIDGETEST"`) instead of an emoji title to rule out a glyph-rendering
  problem specifically.
- Ruled out: multiple displays (single real physical Retina display),
  screen-recording permission gaps in the capture tool (already granted),
  menu bar overflow/hidden section (plenty of empty space visible, no
  overflow indicator).

Separately, a **real, confirmed, and fixed bug** was found in the same
area: `checkFullDiskAccess()`'s `NSAlert.runModal()` can render its window
**behind every other app's windows and sit there invisibly while blocking
the main thread forever** — directly reproduced (the process was still
alive minutes later with zero visible dialog anywhere on screen, and
`lsappinfo` showed System Settings had been launched with
`parentASN="Fridge"`, meaning the button click handler DID fire at some
point behind the scenes). This happens because an accessory-policy
(LSUIElement) app never becomes frontmost on its own, and a plain
`NSAlert` has no special window-level treatment. Fixed by setting
`alert.window.level = .floating` on both alert sites in `MenuBar.swift`
before calling `runModal()`. This fix is real and worth keeping regardless
of the status-item mystery above.

The status-item non-rendering issue, however, persists even with that fix
and is NOT explained by it (confirmed by reproducing it in a run with
`checkFullDiskAccess()` temporarily bypassed entirely, so no alert was
ever involved).

**Best working theory:** this may be specific to how this session's Mac
launches processes (scripted `open`/direct binary execution rather than a
genuine Finder double-click, which may carry additional "real user
gesture" provenance that Control Center uses to decide whether to promote
a status item out of `.ephemeral`), and/or specific to ad-hoc "Sign to Run
Locally" code signing not being trusted enough for persistent menu bar
placement, and/or a genuinely new Control Center behavior in this macOS
version (SDK reports macOS 26.5 — newer than typical prior-generation
assumptions). None of these were confirmed as the root cause; all were
investigated as far as this environment allows (no `cliclick` or similar
tool available to simulate a true physical double-click; no Developer ID
signing certificate available to test a properly-signed build).

**What to do next:** launch the built `.app` by physically double-clicking
it in a real Finder window (not from a script) and check whether the icon
appears. If it does, the issue is specific to this scripted-testing
environment and nothing in the app needs to change. If it doesn't, this
is a hard blocker for the whole app and needs real investigation with
Console.app open live (not `log show` after the fact) and a proper
Developer ID-signed build to rule out signing-trust as the cause.

---

## Code-review findings not acted on

`Ledger.load()` decodes `file.version` but never validates it against
`Ledger.currentVersion` — a future schema change would be silently
accepted with no migration path. Not fixed: only one schema version
exists, so migration logic today would be speculative scaffolding for a
problem that doesn't exist yet. Add a version check in `load()` the
moment a second schema version is introduced, not before.
