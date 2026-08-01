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
