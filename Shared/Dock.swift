import SwiftUI
import WidgetKit

/// Where the video preview sits inside the widget (points, top-left origin, including the
/// widget's content margins). The widget records it; the helper lays the video player over it.
struct DockGeometry: Codable, Equatable {
    var widgetWidth: Double
    var widgetHeight: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var cornerRadius: Double
}

enum DockStore {
    static var url: URL { SharedStore.containerURL.appendingPathComponent("dock.json") }
    private static var cache: [String: DockGeometry] = [:]

    /// Only the real widget records (not the helper's preview renderer, which uses other sizes).
    static var isWidgetProcess: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".widget") == true }

    static func record(_ geometry: DockGeometry, family: String) {
        guard isWidgetProcess, cache[family] != geometry else { return }
        cache[family] = geometry
        var all = load()
        all[family] = geometry
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    static func load() -> [String: DockGeometry] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: DockGeometry].self, from: data) else { return [:] }
        return all
    }
}

/// The widget's content size and margins, passed down from the root view.
struct DockCanvas {
    var contentSize: CGSize = .zero
    var margins = EdgeInsets()
}

private struct DockCanvasKey: EnvironmentKey {
    static let defaultValue = DockCanvas()
}

extension EnvironmentValues {
    var dockCanvas: DockCanvas {
        get { self[DockCanvasKey.self] }
        set { self[DockCanvasKey.self] = newValue }
    }
}

let dockCoordinateSpace = "musicWidgetRoot"

/// Records this view's position inside the widget.
struct DockAnchor: ViewModifier {
    let cornerRadius: CGFloat
    /// Cover the whole widget (small size) instead of this view's own frame.
    var fullWidget = false
    @Environment(\.dockCanvas) private var canvas
    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                let _ = record(geo.frame(in: .named(dockCoordinateSpace)))
                Color.clear
            }
        )
    }

    private func record(_ frame: CGRect) {
        guard canvas.contentSize.width > 0 else { return }
        let m = canvas.margins
        let widgetWidth = canvas.contentSize.width + m.leading + m.trailing
        let widgetHeight = canvas.contentSize.height + m.top + m.bottom
        let g = fullWidget
            ? DockGeometry(widgetWidth: widgetWidth, widgetHeight: widgetHeight, x: 0, y: 0,
                           width: widgetWidth, height: widgetHeight, cornerRadius: cornerRadius)
            : DockGeometry(widgetWidth: widgetWidth, widgetHeight: widgetHeight,
                           x: frame.minX + m.leading, y: frame.minY + m.top,
                           width: frame.width, height: frame.height, cornerRadius: cornerRadius)
        DockStore.record(g, family: "\(family)")
    }
}
