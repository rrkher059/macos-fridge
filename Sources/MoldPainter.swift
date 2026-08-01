import AppKit
import os

/// Takes a CLEAN icon plus a bucket, returns a moldy icon.
///
/// This class must never read an icon off disk. It only receives the clean
/// snapshot (as PNG data) from the Ledger. That is what stops mold-on-mold
/// sludge — see CLAUDE.md decision #2.


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
            // Overlays live in Assets.xcassets, not as loose bundle resources —
            // NSImage(named:) is what actually finds them. See UNCERTAINTIES.md #6.
            guard let image = NSImage(named: assetName(for: bucket)) else {
                log.error("MoldPainter: failed to load overlay asset for \(bucket.rawValue, privacy: .public)")
                continue
            }
            overlays[bucket] = image

            // TEMPORARY DEBUG — remove once asset-catalog overlay loading is
            // confirmed on a real Mac (UNCERTAINTIES.md #6). NSImage.size is
            // point size, not pixel size, so this reads the actual bitmap
            // representation's pixel dimensions instead.
            let name = self.assetName(for: bucket)
            if let rep = image.representations.first {
                log.debug("MoldPainter: loaded \(name, privacy: .public) — \(rep.pixelsWide, privacy: .public)x\(rep.pixelsHigh, privacy: .public)")
            } else {
                log.debug("MoldPainter: loaded \(name, privacy: .public) — no representations found")
            }
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
    ///
    /// Returns whether setIcon actually succeeded. Callers must not update
    /// Ledger state (bucket, frozen) on a false return — doing so would
    /// record a change that never actually happened on disk, with no way
    /// to notice or retry later.
    @discardableResult
    static func apply(_ image: NSImage?, to path: String) -> Bool {
        let succeeded = NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        if !succeeded {
            log.error("IconWriter: setIcon returned false for \(path, privacy: .public)")
        }
        return succeeded
    }
}
