import AppKit

/// Takes a CLEAN icon plus a bucket, returns a moldy icon.
///
/// This class must never read an icon off disk. It only receives the clean
/// snapshot from the Ledger. That is what stops mold-on-mold sludge.

final class MoldPainter {

    /// Overlay PNGs loaded from the app bundle, keyed by bucket.
    /// 512x512, transparent background.
    private var overlays: [Bucket: NSImage] = [:]

    /// Painted results, keyed by "cleanIconHash + bucket".
    /// Same file at the same bucket should never be re-rendered.
    private var cache: [String: NSImage] = [:]

    init() {
        // TODO: load mold_spotty / mold_moldy / mold_fuzzy from bundle
    }

    /// Returns nil for .fresh — caller should then call setIcon(nil,...)
    /// to strip the custom icon entirely.
    func paint(clean: NSImage, bucket: Bucket) -> NSImage? {
        // TODO: check cache, else composite and store
        return nil
    }

    // MARK: - Drawing

    /// Draw clean at full size, then draw overlay on top at full size,
    /// both into a fresh 512x512 bitmap. Preserve alpha.
    private func composite(_ clean: NSImage, _ overlay: NSImage) -> NSImage {
        // TODO
        fatalError("unimplemented")
    }

    private func cacheKey(clean: NSImage, bucket: Bucket) -> String {
        // TODO
        return ""
    }
}

// MARK: - Applying to disk

enum IconWriter {

    /// The ONLY place setIcon is ever called. Keep it that way.
    static func apply(_ image: NSImage?, to path: String) {
        // NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        // Passing nil restores the file's original icon perfectly.
        // TODO
    }
}