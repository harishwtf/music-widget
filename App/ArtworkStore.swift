import AppKit
import Foundation

/// Saves downscaled artwork into the shared container so the widget can read it.
enum ArtworkStore {
    /// Saves `image` and deletes this source's other artwork, except the files named in `keep`.
    static func save(_ image: NSImage, source: MediaSource, key: String,
                     maxSide: CGFloat = 512, keep: Set<String> = []) -> String? {
        let name = "artwork-\(source.rawValue)-\(stableHash(key)).jpg"
        let url = SharedStore.artworkURL(for: name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        guard let data = jpegData(image, maxSide: maxSide) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Artwork write failed: \(error)")
            return nil
        }
        // Prune older artwork for this source.
        let dir = SharedStore.containerURL
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasPrefix("artwork-\(source.rawValue)-") && f != name && !keep.contains(f) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        return name
    }

    static func jpegData(_ image: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cg, size: NSSize(width: w, height: h))
            .draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

func stableHash(_ s: String) -> String {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
    return String(h, radix: 16)
}
