# Fridge

fridge :)

A macOS menu-bar app for Downloads and Desktop. Files you don't touch grow
mold on their icons — right on the icon, in Finder, not a notification. The
longer a file sits untouched, the worse it looks, in four stages from fresh
to fuzzy. You clean up because it's gross, not because something nagged you.

Click the 🧊 in the menu bar to see every tracked file (freshest on top,
rotting on the bottom), toss one to the Trash, or freeze one so it never
rots again.

## Status

Written entirely on a Windows machine with no Swift toolchain — nothing has
been compiled or run yet. See `UNCERTAINTIES.md` for the specific runtime
assumptions to verify first on a Mac (in particular #1 and #14, which gate
whether the app does anything at all).

## Opening it in Xcode

There is no `.xcodeproj` yet. First time setup on the Mac:

1. Create a new Xcode project: **macOS App**, AppKit (not SwiftUI)
   lifecycle, Swift.
2. Add `Sources/*.swift`, `Assets/*.png`, and `Info.plist` to the app
   target.
3. In the target's Build Settings, set **Info.plist File** to point at the
   provided `Info.plist` (it already has `LSUIElement` set, so the app runs
   with no Dock icon and no windows — menu bar only).
4. Build (⌘B) — this alone will surface most of the unverified assumptions
   in `UNCERTAINTIES.md`.

## Full Disk Access

Painting a moldy icon onto a file means writing to that file, which macOS
only allows with Full Disk Access — and it won't prompt for it on its own.
On first launch, Fridge checks for this itself and, if missing, shows its
own panel with a button that opens straight to
System Settings > Privacy & Security > Full Disk Access. Grant it there and
relaunch.

## If something goes wrong: Unmold All

Click the 🧊 menu bar icon and choose **Unmold All** at the bottom of the
dropdown. It strips the custom icon from every file Fridge knows about,
restoring each one's original icon — the emergency undo. Build and test
this first, before ever pointing the app at a real Downloads or Desktop
folder.
