# Decisions

## Menu bar status item dropped — unresolved OS-level bug (2026-08-01)

**Decision:** The menu bar (`NSStatusItem`) is no longer the app's UI. A
normal `NSWindow` is. `LSUIElement` in Info.plist is `NO` — Fridge is a
regular, Dock-visible app now.

**Why:** The status item never rendered on screen across dozens of
launches (raw binary execution, `open`, and a genuine Finder double-click
— all three tried), despite every AppKit-level signal reporting it as
valid: `isVisible == true`, non-nil button, correct `.accessory`
activation policy, correct `NSStatusBar.system.thickness` (22pt).

Root cause, confirmed directly by logging immediately after creation:

```
item.isVisible=true, buttonFrame=(0.0, 0.0, 38.0, 0.0), statusBarThickness=22.000000
```

**The button's own frame has height 0.** Width is correct (38pt, sized for
its title). The status bar itself has the normal 22pt thickness. The
button view inside it never received a nonzero height during layout. A
zero-height view renders nothing, full stop — independent of title,
image, `autosaveName`, or explicit `isVisible = true`, all of which were
tried and ruled out one at a time:

- Plain-text title (`"FRIDGE"`, no image) — ruled out image loading as
  the cause. Still zero height, still invisible.
- `item.autosaveName` set — no effect.
- `NSApp.setActivationPolicy(.accessory)` + explicit `NSApp.activate()`
  before creation — no effect.
- `MenuBarController` confirmed retained (stored property on
  `AppDelegate`, not a local var); `applicationDidFinishLaunching`
  confirmed firing via a log line printed before anything else; status
  item confirmed created on the main thread after launch finished; the
  built `.app` bundle confirmed structurally valid (`Info.plist` in the
  right place, `CFBundleExecutable` matching the binary, `CFBundlePackageType
  = APPL`).
- Separately, Control Center's own system log showed it registering a
  real scene for the item but marking it `positioning .ephemeral` and
  tearing the scene down (`XX-None`) within ~100–300ms of creation, every
  launch — consistent with, though not conclusively proven to be caused
  by, the same underlying layout failure.

**Not the cause:** ad-hoc code signing was suspected (no Developer ID
certificate was available to test — private key generation didn't
complete and wasn't worth further time), and a `kTCCServiceListenEvent`
(Input Monitoring) TCC entry was found and initially misattributed to
this — but a full codebase search turned up zero uses of
`NSEvent.addGlobalMonitorForEvents`, `CGEventTap`, or any related API, so
that TCC request does not originate from this app's own code and its
connection to the rendering failure was never established. Do not grant
that permission; it isn't needed by anything in this design.

**Status: unresolved.** The zero-height button frame is the confirmed
mechanism; why AppKit lays it out with zero height on this machine is
not. Left as a known, documented dead end rather than a continued time
sink. If revisited later: try a properly Developer ID-signed build (not
ad-hoc), and check whether the same zero-height frame reproduces on a
different Mac / different macOS version before assuming it's fixable in
app code at all.

**What replaced it:** a normal `NSWindow` (previously built as `--window`
demo insurance, now the only UI) showing the same Ledger data — grouped
by bucket, real per-file icons, relative timestamps, Reveal in
Finder/Freeze/Toss per row, Unmold All/Refresh Now/Quit globally.

## Window reopen via Dock icon — implemented and verified safely (2026-08-01)

A Phase 2 code review caught a real dead end: with the menu bar gone and
`LSUIElement` now `NO`, closing the window (red button) left no way to
bring it back short of quitting and relaunching, since
`applicationShouldHandleReopen` was never implemented. Fixed in
`AppDelegate.swift` + `MenuBarController.reopenWindow()` — the standard,
well-established AppKit pattern for this (window kept alive via
`isReleasedWhenClosed = false`, re-shown via `showWindow(nil)` when the
Dock icon is clicked with no visible windows).

While testing this specific fix, driving a window close via
`osascript -e 'tell application "Fridge" to close window 1'` (a synthetic
Apple Event our app never declared any scripting support for) caused the
process to pin at 100% CPU in a tight loop of icon-rendering system calls
(`CarbonCore` icon "flippers", repeating continuously) for over 30
seconds before being killed. Root cause not identified — the AppleScript
command itself returned "Connection is invalid (-609)" once the process
was killed, which doesn't point at anything conclusive, and this exact
sequence (synthetic "close window" Apple Event to an app with no .sdef)
is unusual enough that it may be an artifact of that specific automation
path rather than something a real user would ever trigger by actually
clicking the close button.

**Since verified safely, avoiding that specific automation path.** Closing
was tested with a genuine synthetic keyboard event (CGEvent posting a real
Cmd+W key-down/up through the HID event system, the same path a physical
keypress takes) instead of an Apple Event: window closed cleanly, process
stayed at 0% CPU. Reopening was tested by invoking `open` on the running
app a second time — functionally what happens when the Dock icon is
clicked for an already-running app — and the same window (same
`CGWindowID`) came back with correct data, process CPU never exceeded
0.3% across several seconds of observation afterward. Both confirm the
fix works correctly for the real interaction paths a user would actually
trigger; whatever caused the earlier spike was specific to the synthetic
"close window" Apple Event itself, not this code.

## Watcher reverted back to ~/FridgeTest — real Downloads is not safe yet (2026-08-01)

Pointed the Watcher at real Downloads + Desktop, with the user's
explicit go-ahead, and actually launched the app against them. Reverted
immediately after discovering two real problems, neither hypothetical:

**1. Scale.** The real Downloads folder alone has 5,106 files. At roughly
0.7–1 second per file (a Spotlight metadata lookup plus a full-resolution
icon snapshot, per file, on first sight), a first run is a ~1-hour,
continuously-CPU-busy operation. Nothing in the current design tells the
user this is happening, how long it will take, or lets them see progress
— it just silently starts repainting the icons of every file older than
14 days, all at once, with no preview or confirmation step.

**2. Data loss risk under interruption — reproduced, not theoretical.**
The process was killed partway through (to stop the hour-long scan once
its scale became clear). `IconWriter.apply` (the actual `setIcon` disk
write) runs inline per-file inside the loop, but `ledger.save()` only
happens once, after the *entire* pass finishes. Killing the process
mid-pass left **53 real files with a custom icon already written to
disk, with zero corresponding Ledger entry** — confirmed directly via
`GetFileInfo`'s custom-icon attribute flag. Since "Unmold All" only
iterates `ledger.allPaths`, it would never have known these files needed
restoring. All 53 were found and fixed by hand
(`NSWorkspace.setIcon(nil,...)` on each, verified clean afterward) —
recoverable this time only because the affected paths were still sitting
in the log output.

An initial fix (call `ledger.save()` after every file, not just once at
the end) was tried and reverted — it makes the actual problem worse, not
better. The Ledger stores each file's clean icon as a full base64-encoded
PNG **inline in the same JSON file** (per CLAUDE.md's specified format);
at ~231KB average per entry, extrapolated to 5,106 files that's roughly
**1.1GB** for the ledger alone. Saving after every single file during a
scan of that size means rewriting an ever-growing file, up to ~1.1GB
each time, thousands of times in a row — turning an already-slow ~1-hour
scan into something dramatically worse, potentially many hours or an
effective hang, and writing terabytes of cumulative disk I/O in the
process.

**Status: reverted, not fixed.** `Watcher.scopes` points at `~/FridgeTest`
again. The real fix is architectural — most likely storing each file's
clean-icon snapshot as its own file on disk (keyed by path hash or
similar) rather than inline in one giant growing JSON, plus some form of
incremental or batched progress so an interrupted first run can resume
without redoing work or losing track of what's already been painted.
That's a real design decision (it changes the Ledger JSON shape CLAUDE.md
specifies), not something to sneak in unilaterally — flagging it here for
that decision to be made deliberately, rather than the scope being
switched back to Downloads/Desktop again without it.

## Fuzzy overlay asset had a baked-in opaque checkerboard, not real transparency (2026-08-01)

Found during a visual-quality pass at 1024px: every fuzzy-bucket file
showed a mold wreath around a completely blank hole where the base file
icon should have been — not "faint," genuinely nothing, checkerboard
pattern visible in the exported PNG. Reproduced consistently across
different files (a `.png`, a `.docx`) and confirmed it wasn't a testing
artifact by resetting a file's icon to pristine, verifying the reset with
a direct dump, then running exactly one clean pass and dumping again —
same result both times, ruling out any accumulated "sludge" from repeated
manual testing this session.

Root cause, confirmed by sampling raw pixel values: `mold_fuzzy.png`'s
center region had alpha = 255 (fully opaque) the whole time, painted with
literal light-gray/white pixel colors that happen to match a design
tool's on-screen transparency indicator — i.e. the checkerboard had been
flattened into the actual saved image data instead of being real alpha
transparency. `composite()`'s logic was never the problem; it was
faithfully drawing an overlay asset that opaquely covered the clean icon
underneath by design-file mistake, not by any compositing bug.

Fixed by flood-filling from the image center, converting every
connected low-saturation/light pixel (matching the two checkerboard
colors sampled directly) to alpha 0, stopping naturally at the wreath's
real artwork (saturated greens/browns, which don't match the flood-fill's
criteria). Verified the fix by re-sampling the same pixel coordinates
(alpha now 0) and by a fresh single-pass composite showing the real file
icon clearly through the hole. `mold_spotty.png` and `mold_moldy.png`
were checked for the same defect and don't have it — this was
fuzzy-specific.

## Ledger scaling rewrite — landed (2026-08-01)

The fix the previous entry called for. Clean icons are now individual PNG
files in `~/Library/Application Support/Fridge/icons/`, named by a SHA256
hash of the tracked path (`CryptoKit`, stable across launches — unlike
`Data.hashValue`, which is process-randomized). `LedgerEntry` stores only
`cleanIconFilename`; `Ledger.cleanIconData(for:)` reads the PNG back on
demand. `Ledger.load()` sweeps any icon file no surviving entry
references.

Measured directly, not estimated: the same 16 real-ish test files that
produced a 2.5MB `ledger.json` under the old inline-base64 format now
produce a 5KB one — roughly 500x smaller. Extrapolated to the 5,106-file
real Downloads folder from the previous incident, that's the difference
between a ~1.1GB ledger and one comfortably under 2MB.

`runLoop` now saves the Ledger after registering a new file (before any
paint happens) and again immediately after painting, rather than once at
the end of the entire pass — cheap and safe now that entries carry no
image data. This directly fixes the reproduced bug: a crash between
"we know about this file" and "we painted it" now leaves an unpainted,
harmless record instead of a painted file with no record. Explicitly
NOT implemented as "detect an interrupted scan and offer to resume" —
with per-file checkpointing, there's no separate interrupted-scan state
left to detect; the Ledger is simply always current as of the last file
processed.

Verified byte-identical `unmoldAll` restoration against the new format
directly: applied mold via the real running app, clicked "Unmold All" via
a genuine synthetic mouse click (`CGEvent`, not the AppleScript/Apple
Event path that caused problems earlier), and confirmed the restored
icon's PNG bytes matched the stored clean-icon file exactly. All Tier 1
tests updated for the new `LedgerEntry` shape and passing.

**Cut for time, deliberately:** batched processing with a visible
"Scanning N of M" progress indicator, and progressively populating the
window as files are processed rather than all at once at the end. The
per-file checkpointing above already means no work or Ledger state is
ever lost if a long scan is interrupted — the UI just doesn't show
progress during one. Worth adding before ever turning on real folders by
default for a folder anyone actually complained was slow.

**Landed:** a real "Add Downloads and Desktop" opt-in button in the
window's bottom bar (only shown while real folders aren't enabled),
gated behind a confirmation alert that states plainly what's about to
happen and reminds the user Unmold All reverses it. Persisted via
`UserDefaults` (`FridgeRealFoldersEnabled`) so the choice survives
relaunches — `~/FridgeTest` remains the default in the committed code
for every installation that hasn't explicitly opted in.

## Full-day code review (second pass) — one real bug found and fixed (2026-08-01)

An independent review pass over every diff since the start of this
session (not just the final-pass changes) found one bug worth fixing
and one accepted low-severity edge case.

**Fixed:** `IconWriter.apply`'s `setIcon` return value was logged on
failure but never propagated to callers — `runLoop`, `freeze`, and
`unmoldAll` all updated the Ledger's bucket/frozen state unconditionally,
regardless of whether the icon write actually succeeded. Same bug class
as the `Ledger.register()` fix above, just on the write side instead of
the snapshot side: a transient `setIcon` failure (locked file, momentary
TCC hiccup, read-only volume) would make the Ledger believe a file was
restored/painted/frozen when the on-disk icon never changed, with
`runLoop`'s "bucket unchanged, skip" logic then never retrying it. Most
serious for `unmoldAll`, the app's designated emergency undo — a partial
failure there used to be invisible. Fixed by making `apply` return
`Bool` and having all three call sites only update Ledger state when it
returns `true`, logging and leaving state untouched (so it's retried
later) otherwise. Re-verified afterward against the real running app:
rebuilt, relaunched, confirmed a file got repainted moldy again on
launch, clicked Unmold All, confirmed via `GetFileInfo`'s custom-icon
attribute flag that it cleared on multiple files.

**Accepted, not fixed:** the Full Disk Access probe
(`canSetIconInProtectedFolder`) creates a throwaway hidden dotfile on
the real `~/Desktop`, calls `setIcon` on it, and removes it via `defer`
— this runs on every launch regardless of whether real-folder scanning
is enabled, since testing FDA meaningfully requires touching an
actually TCC-protected folder (`~/FridgeTest` isn't one). If the process
is killed between file creation and the `defer` completing, a stray
empty hidden file with a custom icon could be left on the real Desktop,
untracked by the Ledger and unreachable by Unmold All (which only
touches Ledger paths) or by a future Desktop scan (which skips
dot-prefixed files). Low real-world severity — an empty throwaway file,
not a pre-existing user file — and not meaningfully fixable short of not
testing FDA against a real protected folder at all, which would defeat
the point of the check. Left as-is; flagged here rather than silently
ignored.
