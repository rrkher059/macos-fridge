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

## Window reopen via Dock icon — implemented, not fully re-verified (2026-08-01)

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

**Not fully re-verified as a result.** The fix itself is a standard,
widely-used pattern and the code is straightforward, but the actual
close-then-reopen cycle should be manually verified by clicking the red
close button and then the Dock icon, watching Activity Monitor briefly
afterward, before fully trusting it — rather than re-attempting automated
Apple Event-driven testing of window close, which is what triggered the
spike here.

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
