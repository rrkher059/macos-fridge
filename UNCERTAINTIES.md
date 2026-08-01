# Uncertainties

Everything here was written blind on Windows with no Swift toolchain. Each
entry is a specific assumption baked into Tier 2 code. Check them in the
order listed — several build on each other (Watcher's launch behavior in
particular gates whether the loop ever runs at all).

---

### 1. Initial run relies on NSMetadataQueryDidFinishGathering, not an explicit call
- File: MenuBar.swift, `start()`; Watcher.swift, `start()`
- What I assumed: calling `watcher.start()` triggers `query.start()`, and the
  async gather completing posts `.NSMetadataQueryDidFinishGathering`, which
  `handleQueryNotification` catches and forwards to `onResults` — this is what
  satisfies "run once at launch," with no separate explicit call needed.
- Why I'm unsure: never observed this notification fire. If it doesn't fire,
  or fires before the observer is registered (race between `query.start()`
  and `addObserver`), the app sits with an empty menu until the first hourly
  timer tick — a silent, hour-long stall on first launch.
- How to check on Mac in under 2 min: launch the app pointed at
  ~/FridgeTest (already seeded with a few files), watch Console.app filtered
  on subsystem `com.fridge.app`, confirm a `Watcher: delivering N files` log
  line appears within a few seconds of launch.
- If wrong: register the NotificationCenter observers *before* calling
  `query.start()` (currently they are added first, but verify), or add an
  explicit fallback: call `watcher.refresh()` on a short one-shot timer
  (~2s) after `start()` as a belt-and-suspenders kick.

### 2. NSMetadataQuery.searchScopes accepts [URL] directly, and is recursive
- File: Watcher.swift, `start()`
- What I assumed: `query.searchScopes = scopes` (an array of folder URLs)
  is valid, and Spotlight will return files in subfolders of ~/FridgeTest
  too, not just top-level contents.
- Why I'm unsure: Apple's docs say scopes can be URLs or scope-key strings,
  but I have not run this to confirm the recursion behavior in practice.
- How to check on Mac in under 2 min: create ~/FridgeTest/sub/deep.txt,
  launch the app, check whether it shows up in the menu / gets logged as
  delivered.
- If wrong: if it's not recursive and that matters, switch the predicate to
  scope by `kMDItemPath` prefix instead of relying on searchScopes recursion.
  If it over-recurses into places you don't want, add an `NSPredicate` clause
  excluding deeper paths.

### 3. NSMetadataQuery notifications and .results arrive on the main thread
- File: Watcher.swift, `deliverCurrentResults()`; MenuBar.swift, `runLoop`
- What I assumed: because `query.start()` is called from the main thread, the
  query schedules itself on the main run loop and both
  `NSMetadataQueryDidUpdate`/`DidFinishGathering` and access to `query.results`
  happen on main — so it's safe for `onResults` to call straight into
  `runLoop`, which touches `NSStatusItem` and the Ledger without hopping
  threads.
- Why I'm unsure: NSMetadataQuery has historically had surprising threading
  behavior in some configurations (it can deliver via an internal operation
  queue). If results land on a background thread, `statusItem?.menu = ...`
  inside `runLoop` would be a background-thread AppKit call — likely to
  misbehave or crash.
- How to check on Mac in under 2 min: add `log.debug("thread: \(Thread.isMainThread)")`
  at the top of `deliverCurrentResults()`, touch a file in FridgeTest, check
  the log.
- If wrong: wrap the body of `deliverCurrentResults()`'s notification-handler
  path (or `onResults?(files)` call) in `DispatchQueue.main.async`.

### 4. The predicate `%K LIKE '*'` on NSMetadataItemFSNameKey returns "everything," relying on scope to restrict
- File: Watcher.swift, `start()`
- What I assumed: this predicate matches any item with a filename (i.e. all
  files), and `searchScopes` is what actually limits results to
  Downloads/Desktop/FridgeTest — the predicate itself isn't doing filtering
  work.
- Why I'm unsure: I've seen this exact predicate pattern used for
  "match everything" NSMetadataQuery use cases, but never run it myself.
  If it needs to be non-empty/non-wildcard in some stricter way, or if
  scoped queries need a different predicate shape entirely, this silently
  returns zero results.
- How to check on Mac in under 2 min: same launch test as #1 — a non-zero
  delivered-file count confirms both the predicate and scope are working
  together.
- If wrong: fall back to enumerating the directory with `FileManager` and
  skip NSMetadataQuery's predicate/scope matching for the file list, using
  Spotlight (or direct `getResourceValue` calls) only for the lastUsed date.

### 5. Icon snapshot captures a real 512x512 bitmap, not a low-res icon stretched up
- File: MenuBar.swift, `snapshotCleanIconPNG(path:)`
- What I assumed: `NSWorkspace.shared.icon(forFile:)` returns an `NSImage`
  with multiple resolution representations, and setting `icon.size` to
  512x512 before reading `tiffRepresentation` gets the highest-quality
  representation scaled to that logical size — not a 32x32 bitmap blown up
  into blur.
- Why I'm unsure: this is exactly the "icon snapshot fidelity" risk flagged
  up front. `tiffRepresentation` picks a representation based on current
  `.size`, and whether that yields a genuinely sharp 512x512 vs an
  upscaled small icon depends on what representations the source file
  actually has (many file types only have small default icons).
- How to check on Mac in under 2 min: after first launch against
  ~/FridgeTest, check the logged `snapshotCleanIconPNG: captured WxH` line
  — if W/H come back as 512x512 but the resulting PNG looks blurry when
  opened, the representation was upscaled, not native.
- If wrong: iterate `icon.representations` explicitly and pick the largest
  available `pixelsWide`/`pixelsHigh` representation instead of trusting
  `.size` + `tiffRepresentation` to auto-select the best one.

### 6. Bundle.main.url(forResource:withExtension:) finds the Assets/*.png files
- File: MoldPainter.swift, `init()`
- What I assumed: once the Xcode project is set up tomorrow and
  Assets/mold_spotty.png etc. are added as target resources (any way —
  loose files or a folder reference), `Bundle.main.url(forResource:
  "mold_spotty", withExtension: "png")` finds them at runtime.
- Why I'm unsure: this depends entirely on how the files get added to the
  Xcode target, which hasn't happened yet. If added as a folder *reference*
  (blue folder) rather than a *group*, the file ends up nested under an
  `Assets/` subdirectory inside the bundle, and this lookup (which doesn't
  specify a subdirectory) will return nil for all three.
- How to check on Mac in under 2 min: build once, check the log for
  "failed to load overlay asset" — if it fires for all three, add
  `subdirectory: "Assets"` to the `url(forResource:withExtension:subdirectory:)`
  call, or drag the PNGs in as a group instead of a folder reference.
- If wrong: add the `subdirectory:` parameter, or move the PNGs into an
  asset catalog (.xcassets) and use `NSImage(named:)` instead.

### 7. NSImage(size:flipped:drawingHandler:) composites without coordinate-flip surprises
- File: MoldPainter.swift, `composite(_:_:)`
- What I assumed: passing `flipped: false` and drawing both images into the
  full-bounds rect (same source and destination rect, both starting at
  `.zero`) produces a correctly-oriented composite — no upside-down or
  mirrored output.
- Why I'm unsure: this is the "Core Graphics compositing" risk flagged up
  front. `flipped` affects the coordinate system the drawing handler sees;
  getting it backwards typically doesn't crash, it just silently produces
  an upside-down or offset image, which is easy to miss in a screenshot at
  a glance and only obvious on close inspection.
- How to check on Mac in under 2 min: force a bucket transition on a test
  file (or temporarily call `painter.paint` directly with a `.moldy`
  bucket in a throwaway debug action), open the resulting icon at large
  size in Finder (Get Info with a big preview), confirm the mold overlay
  sits right-side-up and covers the icon, not flipped or offset.
- If wrong: flip the `flipped:` parameter, or replace the drawing handler
  approach with explicit `NSGraphicsContext` + `lockFocus()/unlockFocus()`
  and draw with an explicitly constructed transform.

### 8. setIcon's effect shows up in Finder without an extra refresh nudge
- File: MoldPainter.swift, `IconWriter.apply(_:to:)`
- What I assumed: `NSWorkspace.shared.setIcon(_:forFile:options:)` alone is
  enough for Finder to redraw the icon promptly — no need to touch the
  file's mtime, call `NSWorkspace.shared.noteFileSystemChanged(_:)`, or
  relaunch Finder.
- Why I'm unsure: this is the #1 risk flagged up front. Finder icon caching
  is notoriously inconsistent across macOS versions; some workflows need a
  nudge, some don't.
- How to check on Mac in under 2 min: call `IconWriter.apply` on a test
  file in a Finder window that's already open and visible, watch whether
  the icon changes within a couple seconds without manually refreshing the
  window (cmd-R or closing/reopening the folder).
- If wrong: this is exactly why `apply()` is the only call site — add
  `NSWorkspace.shared.noteFileSystemChanged(path)` right after `setIcon`,
  or as a last resort touch the file's modification date, entirely inside
  this one function.

### 9. NSWorkspace.recycle's completion handler thread is unknown, so it's hopped to main defensively
- File: MenuBar.swift, `toss(path:)`
- What I assumed: I don't actually know which thread the completion
  handler fires on, so I wrapped the body in `DispatchQueue.main.async`
  before touching `ledger` or `statusItem`. This should be safe regardless
  of which thread it turns out to be.
- Why I'm unsure: never observed this API's completion-handler threading
  directly.
- How to check on Mac in under 2 min: add a `Thread.isMainThread` log
  inside the completion handler before the `DispatchQueue.main.async` hop,
  toss a test file, check the log — mostly curiosity at this point since
  the defensive hop should make it correct either way.
- If wrong: nothing to fix — the `DispatchQueue.main.async` wrapper handles
  both cases. Only remove it if profiling shows it's meaningfully delaying
  the UI update, which is unlikely.

### 10. AppDelegate stays alive via app.run() blocking, despite NSApplication.delegate being weak
- File: AppDelegate.swift, `static func main()`
- What I assumed: `NSApplication.delegate` is a weak property, so the
  `delegate` local variable must be kept alive by something else — here,
  by the fact that `app.run()` blocks synchronously for the entire process
  lifetime, keeping the local `let delegate` in scope the whole time.
- Why I'm unsure: this is the standard idiom for `@main` AppKit apps
  without a storyboard, and I'm fairly confident in it, but I have not
  compiled or run it, so an ARC/lifecycle mistake here would be silent
  (app quits or the delegate never receives callbacks) rather than a
  compiler error.
- How to check on Mac in under 2 min: launch the app, confirm
  `applicationDidFinishLaunching` actually fires (check for the menu bar
  icon appearing, or add a log line at the top of that method).
- If wrong: fall back to a `main.swift` file (no `@main` attribute) that
  does the same three lines at global scope instead of inside a static
  method — equally standard, removes any doubt about scope/lifetime.

### 11. Full Disk Access can be detected by probing a TCC-protected file
- File: MenuBar.swift, `checkFullDiskAccess()`
- What I assumed: there's no official API to ask "do I have FDA," so
  checking `FileManager.default.isReadableFile(atPath:)` against
  `~/Library/Safari/Bookmarks.plist` (a well-known TCC-gated path) is a
  reasonable proxy — it returns false without FDA, true with it.
- Why I'm unsure: never run this specific check. If Safari isn't installed,
  or Apple changes what's TCC-gated, or the app is sandboxed in some way
  I haven't accounted for, this could false-positive (says "has access"
  when it doesn't) and skip showing the permission prompt entirely.
- How to check on Mac in under 2 min: before granting FDA, launch the app
  and confirm the alert appears; grant FDA via the button, relaunch, and
  confirm the alert does NOT appear the second time.
- If wrong: swap the probe path for a different known-protected file
  (e.g. `~/Library/Application Support/com.apple.TCC/TCC.db`, which is
  reliably TCC-gated even with no other apps installed), or check for a
  failed `setIcon` return value on first real use as a secondary signal.

### 12. Data.hashValue is stable enough within one run to key the paint cache
- File: MoldPainter.swift, `cacheKey(cleanPNG:bucket:)`
- What I assumed: `Data.hashValue` is deterministic for equal `Data` values
  within a single process run (Swift's hash seed is randomized per-launch,
  not per-call), which is all the in-memory `cache` dictionary needs —
  it's never persisted or compared across runs.
- Why I'm unsure: not really OS-behavior risk, more "did I reason about
  Swift's hashing correctly" — low risk, but untested.
- How to check on Mac in under 2 min: not really testable in 2 minutes;
  if the cache misbehaves, its symptom would be a bucket that keeps
  getting re-composited every hour even though nothing changed. Watch the
  log for repeated `composite` log activity on files whose bucket hasn't
  changed.
- If wrong: use `cleanPNG.base64EncodedString()` as the cache key instead —
  slower, but immune to any hashing subtlety.

### 13. Rebuilding statusItem.menu on every loop pass is safe even if the menu is currently open
- File: MenuBar.swift, `runLoop`, `toss`, `freeze`, `unmoldAll`
- What I assumed: reassigning `statusItem?.menu` while the user has the
  menu open (e.g. during the hourly auto-refresh) doesn't crash or produce
  a visibly broken/flickering menu — AppKit swaps it cleanly.
- Why I'm unsure: never observed this. It's a minor cosmetic risk at worst,
  but worth knowing about ahead of a demo.
- How to check on Mac in under 2 min: open the menu, and while it's open,
  manually trigger `watcher.refresh()` (or just wait if a run happens to
  land) — check for flicker or a crash.
- If wrong: only rebuild the menu lazily, e.g. via
  `NSMenuDelegate.menuWillOpen(_:)`, instead of eagerly after every loop.

### 14. The Xcode project itself doesn't exist yet — these files assume a project will wire them up
- File: all of them; Info.plist
- What I assumed: tomorrow's first step is creating an Xcode project (or
  Package.swift) and adding Sources/*.swift, Assets/*.png, and Info.plist
  to a single app target, with the target's "Info.plist File" build
  setting pointed at this Info.plist.
- Why I'm unsure: this isn't really a code uncertainty, it's a "nothing
  here has been proven to build as a project" uncertainty. No .xcodeproj
  exists in this repo.
- How to check on Mac in under 2 min: create the project, add all files,
  build once (⌘B) before doing anything else — this alone will surface
  every Tier 2 compile-time mistake (typos, wrong API names, import
  issues) that reading code can't catch.
- If wrong: n/a — this is the first thing to do tomorrow, not something to
  "fix," but it's the gate everything else sits behind.

### 15. os.Logger string interpolation of bare Error values compiles
- File: MenuBar.swift, multiple `log.error(...)`/`log.critical(...)` calls
  that interpolate `\(error, privacy: .public)` directly
- What I assumed: `os.Logger`'s interpolation support (`OSLogInterpolation`)
  accepts `Error`-conforming values directly under Swift 5.9/macOS 13 SDKs.
  A code-reviewer pass flagged this as worth a specific check rather than
  assuming it silently — noted here rather than just fixed, since I'm not
  confident either way and don't want to pre-emptively wrap every error in
  `String(describing:)` if it isn't necessary.
- Why I'm unsure: never compiled. If the SDK version tomorrow doesn't
  support this interpolation form, it's a build error, not a runtime one —
  loud and immediate, but worth flagging so it isn't a surprise.
- How to check on Mac in under 2 min: this surfaces on the very first
  build (⌘B) — if it fails here, it fails immediately and obviously.
- If wrong: wrap every such interpolation as
  `\(error.localizedDescription, privacy: .public)` or
  `\(String(describing: error), privacy: .public)` — a mechanical find-replace
  across MenuBar.swift.

---

## Code-review findings not acted on

The code-reviewer pass (general-purpose agent standing in for a
project-level code-reviewer subagent — see the final summary) also flagged
that `Ledger.load()` decodes `file.version` but never validates it against
`Ledger.currentVersion`, so a future schema change that happened to still
decode under the current `Codable` types would be silently accepted with no
migration path. Not fixed: there is only one schema version in existence
right now, so adding migration logic today would be speculative
scaffolding for a problem that doesn't exist yet — exactly the kind of
premature abstraction CLAUDE.md's style section warns against. If a second
schema version is ever introduced, that's the moment to add a version
check in `load()`, not before.
