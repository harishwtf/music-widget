import AppKit
import SwiftUI
import WidgetKit

/// Debug helper: renders the widget views to PNG files so they can be checked without
/// adding the widget to the desktop. Run with `MusicWidget --render-previews <dir> [--sample]`.
enum PreviewRenderer {
    @MainActor
    static func render(to dir: URL, useSample: Bool) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        widgetStaticRendering = true
        let state = useSample ? SharedState.sample : SharedStore.load()
        let sizes: [(WidgetFamily, CGSize, String)] = [
            (.systemSmall, CGSize(width: 170, height: 170), "small"),
            (.systemMedium, CGSize(width: 364, height: 170), "medium"),
            (.systemLarge, CGSize(width: 364, height: 382), "large"),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (family, size, name) in sizes {
                let view = ZStack {
                    WidgetBackground(state: state, family: family)
                    MusicWidgetEntryView(state: state, family: family).padding(16)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let file = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: file)
            }
        }
    }
}
