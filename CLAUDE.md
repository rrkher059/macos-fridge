# Fridge

A macOS menu-bar app that makes unopened files in Downloads and Desktop
visually rot. Old files grow mold on their icons. You clean up because
it's gross, not because a notification nagged you.

Target: working demo in one day.

---

## Non-negotiable decisions

These are already settled. Do not re-open them, do not propose alternatives.

### 1. No Finder Sync extension
Finder Sync extensions can only draw a small badge in the corner of an
icon. They cannot repaint the icon. We repaint the whole icon.

Use `NSWorkspace.shared.setIcon(_:forFile:options:)` instead. It writes a
custom icon directly onto the file and Finder picks it up immediately.

To remove mold: `NSWorkspace.shared.setIcon(nil, forFile: path)` restores
the file's original icon perfectly.

### 2. Always paint from the saved clean icon
Once a custom icon is set, asking macOS for "this file's icon" returns our
own moldy version. Painting on top of that compounds every cycle and turns
into sludge within two passes.

Rule: the first time a file is ever seen, snapshot its clean icon as PNG
data into the Ledger. Every future paint starts from that snapshot. Never
read the live icon off a file we have already touched.

### 3. Non-sandboxed, Full Disk Access
`setIcon` writes to the file, so the app ships non-sandboxed and requires
Full Disk Access. macOS will not prompt for this. On first launch, show a
panel with a button that opens:
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess`

### 4. `LSUIElement = YES`
No Dock icon, no window. Menu bar only.

---

## The four pieces

Keep these in four separate files. Do not merge them.

| File | Job |
|---|---|
| `Watcher.swift` | `NSMetadataQuery` scoped to Downloads + Desktop. Returns file paths plus `kMDItemLastUsedDate`. |
| `Ledger.swift` | Reads/writes one JSON file. Remembers every file seen, its clean icon, and whether it is frozen. |
| `MoldPainter.swift` | Takes clean icon + bucket, returns moldy `NSImage` via Core Graphics. Caches by bucket. |
| `MenuBar.swift` | The fridge popup. Fresh on top shelf, rotting on bottom. Toss and Freeze buttons. |

---

## Freshness buckets

Days since `kMDItemLastUsedDate`:

| Days | Bucket | Overlay |
|---|---|---|
| 0–13 | `fresh` | none — call `setIcon(nil,...)` |
| 14–20 | `spotty` | `mold_spotty.png` |
| 21–29 | `moldy` | `mold_moldy.png` |
| 30+ | `fuzzy` | `mold_fuzzy.png` |

Overlays are 512x512 transparent PNGs in `Assets/`, composited over the
clean icon at full size, then handed to `setIcon`.

If `kMDItemLastUsedDate` is missing, fall back to `kMDItemFSCreationDate`.

---

## The loop

Runs on a `Timer` every hour, and once at launch.

1. Watcher returns current file list.
2. For each file:
   - New to us? Snapshot clean icon into Ledger.
   - Frozen? Skip entirely.
   - Compute days old, map to bucket.
   - Bucket unchanged since last run? Skip — do not rewrite the icon.
   - Bucket changed? Paint from clean snapshot, `setIcon`, record new bucket.
3. Files gone from disk: drop from Ledger.
4. Save Ledger.

---

## Ledger JSON shape

```json
{
  "version": 1,
  "files": {
    "/Users/me/Downloads/thing.pdf": {
      "cleanIconPNG": "<base64>",
      "lastUsed": "2026-06-14T09:31:00Z",
      "currentBucket": "moldy",
      "frozen": false,
      "firstSeen": "2026-07-31T10:00:00Z"
    }
  }
}
```

Stored at `~/Library/Application Support/Fridge/ledger.json`.

---

## Actions

- **Toss** — move file to Trash via `NSWorkspace.shared.recycle`.
- **Freeze** — set `frozen: true`, call `setIcon(nil,...)`, never rot again.
- **Unmold all** — loop every file in Ledger, `setIcon(nil,...)`. This is the
  emergency undo. Build it in the first two hours and test it before
  anything else touches a real folder.

---

## Safety rules while building

- Point `Watcher` at `~/FridgeTest` (a junk folder with ~10 files) until the
  painter is confirmed working. Do not point it at real Downloads.
- Never delete a file without going through Trash.
- Never write an icon to a file not present in the Ledger.

---

## Style

- Swift 5.9+, AppKit, no third-party dependencies.
- No `print` for logging — use `os.Logger` with subsystem `com.fridge.app`.
- Small functions. If a function needs a comment explaining what it does,
  split it.
