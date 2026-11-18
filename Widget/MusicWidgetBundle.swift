import WidgetKit
import SwiftUI

@main
struct MusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        MusicWidget()
    }
}

struct MusicEntry: TimelineEntry {
    let date: Date
    let state: SharedState
}

struct MusicProvider: TimelineProvider {
    func placeholder(in context: Context) -> MusicEntry {
        MusicEntry(date: Date(), state: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (MusicEntry) -> Void) {
        completion(MusicEntry(date: Date(), state: context.isPreview ? .sample : SharedStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MusicEntry>) -> Void) {
        let entry = MusicEntry(date: Date(), state: SharedStore.load())
        SharedStore.markRendered(entry.state)
        diagLog("widget  timeline \(context.family) active=\(entry.state.activeSource.rawValue) title=\(entry.state.active.title.prefix(30))")
        // The helper app reloads the widget whenever playback changes; this is just a safety net
        // so a dead helper is noticed within a few minutes.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
    }
}

struct MusicWidgetRootView: View {
    let state: SharedState
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins

    var body: some View {
        GeometryReader { geo in
            MusicWidgetEntryView(state: state, family: family)
                .frame(width: geo.size.width, height: geo.size.height)
                .environment(\.dockCanvas, DockCanvas(contentSize: geo.size, margins: margins))
        }
        .coordinateSpace(name: dockCoordinateSpace)
            .containerBackground(for: .widget) {
                WidgetBackground(state: state, family: family)
            }
    }
}

struct MusicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKind, provider: MusicProvider()) { entry in
            MusicWidgetRootView(state: entry.state)
        }
        .configurationDisplayName("Now Playing")
        .description("Play, pause and skip in Spotify, Apple Music and YouTube.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
