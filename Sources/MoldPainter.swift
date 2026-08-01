import AppKit
import os

/// Takes a CLEAN icon plus a bucket, returns a moldy icon.
///
/// This class must never read an icon off disk. It only receives the clean
/// snapshot (as PNG data) from the Ledger. That is what stops mold-on-mold
/// sludge — see CLAUDE.md decision #2.

// TIER 2 — UNVERIFIED. Never compiled, never run. Depends on runtime
// behavior that was not observable when written. Rewrite freely.
// Do NOT patch symptom-by-symptom.
// (cacheKey() below is the one Tier 1 exception — pure Data/string logic.)

final class MoldPainter {

    private static let canvasSize = CGSize(width: 512, height: 512)

    /// Overlay PNGs loaded from the app bundle, keyed by bucket.
    /// 512x512, transparent background. No entry for .fresh — it's never painted.
    private var overlays: [Bucket: NSImage] = [:]

    /// Painted results, keyed by "cleanPNG hash + bucket".
    /// Same file at the same bucket should never be re-rendered.
    private var cache: [String: NSImage] = [:]

    init() {
        for bucket in [Bucket.spotty, .moldy, .fuzzy] {
            guard let url = Bundle.main.url(forResource: assetName(for: bucket), withExtension: "png"),
                  let image = NSImage(contentsOf: url)
            else {
                log.error("MoldPainter: failed to load overlay asset for \(bucket.rawValue, privacy: .public)")
                continue
            }
            overlays[bucket] = image
        }
    }

    private func assetName(for bucket: Bucket) -> String {
        switch bucket {
        case .fresh: return ""
        case .spotty: return "mold_spotty"
        case .moldy: return "mold_moldy"
        case .fuzzy: return "mold_fuzzy"
        }
    }

    /// Returns nil for .fresh — caller should then call IconWriter.apply(nil,...)
    /// to strip the custom icon entirely.
    func paint(cleanPNG: Data, bucket: Bucket) -> NSImage? {
        guard bucket != .fresh else { return nil }

        guard let overlay = overlays[bucket] else {
            log.error("paint: no overlay loaded for bucket \(bucket.rawValue, privacy: .public), skipping")
            return nil
        }

        let key = cacheKey(cleanPNG: cleanPNG, bucket: bucket)
        if let cached = cache[key] {
            return cached
        }

        guard let clean = NSImage(data: cleanPNG) else {
            log.error("paint: could not decode clean icon PNG, skipping")
            return nil
        }

        let result = composite(clean, overlay)
        cache[key] = result
        return result
    }

    // MARK: - Drawing

    /// Draw clean at full size, then draw overlay on top at full size,
    /// both into a fresh 512x512 bitmap. Preserve alpha.
    private func composite(_ clean: NSImage, _ overlay: NSImage) -> NSImage {
        let size = Self.canvasSize

        return NSImage(size: size, flipped: false) { drawRect in
            // `from:` is a region in the SOURCE image's own coordinate space,
            // not "scale native size to fit" — it must be each image's own
            // bounds, not the destination canvas size, or a clean icon whose
            // native size isn't 512x512 gets cropped/offset instead of scaled.
            clean.draw(in: drawRect, from: NSRect(origin: .zero, size: clean.size), operation: .copy, fraction: 1.0)
            overlay.draw(in: drawRect, from: NSRect(origin: .zero, size: overlay.size), operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    private func cacheKey(cleanPNG: Data, bucket: Bucket) -> String {
        "\(cleanPNG.hashValue)-\(bucket.rawValue)"
    }
}

// MARK: - Applying to disk

enum IconWriter {

    /// The ONLY place setIcon is ever called. Keep it that way — if Finder
    /// needs a refresh nudge after this, it belongs here, in one spot.
    ///
    /// Callers are responsible for only ever passing a path already present
    /// in the Ledger; this function has no ledger reference to check with.
    static func apply(_ image: NSImage?, to path: String) {
        let succeeded = NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        if !succeeded {
            log.error("IconWriter: setIcon returned false for \(path, privacy: .public)")
        }
    }
}
