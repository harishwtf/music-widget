import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Root

/// Set by the preview renderer: SwiftUI's live timer views can't be rasterised offscreen.
var widgetStaticRendering = false

struct MusicWidgetEntryView: View {
    let state: SharedState
    let family: WidgetFamily

    var body: some View {
        if !state.helperIsRunning {
            HelperOfflineView(family: family)
        } else {
            switch family {
            case .systemSmall: SmallWidgetView(state: state)
            case .systemLarge:
                if state.active.source == .youtube { VideoLargeView(state: state) } else { LargeWidgetView(state: state) }
            default:
                if state.active.source == .youtube { VideoMediumView(state: state) } else { MediumWidgetView(state: state) }
            }
        }
    }
}

/// Container background: full-bleed artwork for the small widget, a tinted surface otherwise.
struct WidgetBackground: View {
    let state: SharedState
    let family: WidgetFamily

    var body: some View {
        let player = state.active
        ZStack {
            if family == .systemSmall && state.helperIsRunning {
                if let image = player.artworkImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [player.source.color, player.source.color.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            } else {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [player.source.color.opacity(0.22), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

extension PlayerState {
    var artworkImage: NSImage? {
        guard let file = artworkFile else { return nil }
        return NSImage(contentsOf: SharedStore.artworkURL(for: file))
    }

    var displayTitle: String {
        if hasTrack { return title }
        return isAvailable ? "Nothing playing" : "\(source.displayName) isn't open"
    }

    var displayArtist: String {
        if hasTrack { return artist }
        return isAvailable ? "Press play to start" : "Press play to open it"
    }
}

// MARK: - Families

struct SmallWidgetView: View {
    let state: SharedState
    private var player: PlayerState { state.active }

    var body: some View {
        ZStack {
            if player.source == .youtube {
                Color.clear.modifier(DockAnchor(cornerRadius: 20, fullWidget: true))
            }
            LinearGradient(colors: [.clear, .black.opacity(0.1), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .padding(-20)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    SourceCycleBadge(current: player.source)
                }
                Spacer(minLength: 0)
                Text(player.displayTitle)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text(player.displayArtist)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .opacity(0.85)
                HStack(spacing: 14) {
                    ControlButton(systemName: "backward.fill", size: 12,
                                  intent: MediaCommandIntent(source: player.source, command: .previous))
                    PlayPauseButton(player: player, size: 14)
                    ControlButton(systemName: "forward.fill", size: 12,
                                  intent: MediaCommandIntent(source: player.source, command: .next))
                    Spacer()
                }
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
    }
}

struct MediumWidgetView: View {
    let state: SharedState
    private var player: PlayerState { state.active }

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(player: player, size: 112, cornerRadius: 14)
            VStack(alignment: .leading, spacing: 4) {
                SourcePicker(state: state, compact: true)
                Spacer(minLength: 2)
                Text(player.displayTitle)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(player.displayArtist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressRow(player: player, showTimes: false)
                    .padding(.top, 2)
                HStack {
                    ControlsRow(player: player, size: 15)
                    Spacer()
                    if let v = player.volume, player.source.supportsVolume {
                        VolumeControl(player: player, volume: v, compact: true)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

struct LargeWidgetView: View {
    let state: SharedState
    private var player: PlayerState { state.active }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                SourcePicker(state: state, compact: false)
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 16) {
                ArtworkView(player: player, size: 160, cornerRadius: 18)
                VStack(alignment: .leading, spacing: 6) {
                    Text(player.displayTitle)
                        .font(.system(size: 19, weight: .bold))
                        .lineLimit(3)
                    Text(player.displayArtist)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !player.album.isEmpty {
                        Text(player.album)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if !player.detail.isEmpty {
                        Text(player.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            ProgressRow(player: player, showTimes: true)
            ZStack {
                ControlsRow(player: player, size: 22)
                if let v = player.volume, player.source.supportsVolume {
                    HStack {
                        VolumeControl(player: player, volume: v, compact: false)
                        Spacer()
                    }
                }
            }
        }
    }
}

struct HelperOfflineView: View {
    let family: WidgetFamily

    var body: some View {
        VStack(spacing: family == .systemSmall ? 8 : 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: family == .systemSmall ? 26 : 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Music Widget isn't running")
                .font(.system(size: family == .systemSmall ? 12 : 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Button(intent: OpenHelperIntent()) {
                Text("Start it")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

/// An image that stays visible when macOS draws desktop widgets as one tinted material
/// (whenever another window is active).
struct ArtworkImage: View {
    let image: NSImage
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .vibrant {
            if #available(macOS 15, *) {
                Image(nsImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .luminanceToAlpha()
            }
        } else {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}

/// 16:9 video preview: the current frame when the browser allows it, otherwise YouTube's thumbnail.
struct VideoPreview: View {
    let player: PlayerState
    let width: CGFloat
    var cornerRadius: CGFloat = 12

    var body: some View {
        let height = (width * 9 / 16).rounded()
        ZStack {
            if let image = player.artworkImage {
                ArtworkImage(image: image)
            } else {
                LinearGradient(colors: [player.source.color.opacity(0.95), player.source.color.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: player.source.symbolName)
                    .font(.system(size: height * 0.32, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if player.duration > 0 {
                Text(formatTime(player.duration))
                    .font(.system(size: width > 200 ? 11 : 9, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .modifier(DockAnchor(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}

/// Opens or closes the video player that plays inside the preview.
struct PopOutButton: View {
    let player: PlayerState
    var size: CGFloat = 13

    var body: some View {
        if player.videoID != nil {
            let open = player.inVideoPlayer == true
            Button(intent: MediaCommandIntent(source: .youtube, command: .popOut)) {
                Image(systemName: open ? "stop.circle" : "play.rectangle")
                    .font(.system(size: size, weight: .semibold))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(open ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        }
    }
}

/// Elapsed / total, ticking live while playing.
struct TimeLabel: View {
    let player: PlayerState

    var body: some View {
        HStack(spacing: 0) {
            if player.isPlaying && player.duration > 0 && !widgetStaticRendering {
                Text(timerInterval: player.progressRange, countsDown: false)
            } else {
                Text(formatTime(player.elapsed))
            }
            if player.duration > 0 {
                Text(" / \(formatTime(player.duration))")
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

// MARK: - Video layouts (YouTube)

struct VideoMediumView: View {
    let state: SharedState
    private var player: PlayerState { state.active }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                VideoPreview(player: player, width: 158, cornerRadius: 10)
                if player.detail == SharedStore.chromeHint {
                    Text(player.detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(width: 158, alignment: .leading)
                } else if player.hasTrack {
                    TimeLabel(player: player)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                SourcePicker(state: state, compact: true)
                Spacer(minLength: 2)
                Text(player.displayTitle)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                Text(player.displayArtist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressRow(player: player, showTimes: false)
                    .padding(.top, 3)
                HStack(spacing: 0) {
                    ControlsRow(player: player, size: 14)
                    Spacer(minLength: 0)
                    PopOutButton(player: player, size: 12)
                }
                .padding(.top, 2)
            }
        }
    }
}

struct VideoLargeView: View {
    let state: SharedState
    private var player: PlayerState { state.active }
    private var showsHint: Bool { player.detail == SharedStore.chromeHint }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                VideoPreview(player: player, width: geo.size.width, cornerRadius: 14)
                Text(player.displayTitle)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .padding(.top, 10)
                HStack(spacing: 6) {
                    Text(showsHint ? player.detail : player.displayArtist)
                        .font(.system(size: showsHint ? 10 : 12, weight: .medium))
                        .foregroundStyle(showsHint ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(showsHint ? 2 : 1)
                    Spacer(minLength: 4)
                    SourcePicker(state: state, compact: true)
                }
                .padding(.top, 3)
                Spacer(minLength: 4)
                ProgressRow(player: player, showTimes: true)
                ZStack {
                    ControlsRow(player: player, size: 20)
                    HStack {
                        Spacer()
                        PopOutButton(player: player, size: 14)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

struct ArtworkView: View {
    let player: PlayerState
    let size: CGFloat
    var cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            if let image = player.artworkImage {
                ArtworkImage(image: image)
            } else {
                LinearGradient(colors: [player.source.color.opacity(0.95), player.source.color.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: player.source.symbolName)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}

/// Three pills to choose which player the widget controls.
struct SourcePicker: View {
    let state: SharedState
    let compact: Bool
    var overMedia: Bool = false
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MediaSource.allCases) { source in
                let selected = state.activeSource == source
                let available = state.player(source).isAvailable
                let vibrant = renderingMode == .vibrant
                let fill: Color = vibrant ? Color.primary.opacity(selected ? 0.32 : 0.08)
                    : selected ? source.color
                    : overMedia ? Color.black.opacity(0.55) : Color.primary.opacity(0.08)
                let text: Color = vibrant ? Color.primary.opacity(selected || available ? 1 : 0.5)
                    : selected ? Color.white
                    : overMedia ? Color.white.opacity(available ? 0.9 : 0.6)
                    : Color.primary.opacity(available ? 0.8 : 0.4)
                Button(intent: MediaCommandIntent(source: source, command: .select)) {
                    HStack(spacing: 4) {
                        Image(systemName: source.symbolName)
                            .font(.system(size: compact ? 9 : 10, weight: .bold))
                        if !compact || selected {
                            Text(source.displayName)
                                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, compact ? 7 : 10)
                    .padding(.vertical, compact ? 4 : 5)
                    .background(fill, in: Capsule())
                    .foregroundStyle(text)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Small-widget badge: tap to switch to the next player.
struct SourceCycleBadge: View {
    let current: MediaSource
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var next: MediaSource {
        let all = MediaSource.allCases
        let i = all.firstIndex(of: current) ?? 0
        return all[(i + 1) % all.count]
    }

    var body: some View {
        Button(intent: MediaCommandIntent(source: next, command: .select)) {
            HStack(spacing: 4) {
                Image(systemName: current.symbolName).font(.system(size: 9, weight: .bold))
                Text(current.displayName).font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(renderingMode == .vibrant ? Color.primary.opacity(0.3) : current.color.opacity(0.9), in: Capsule())
            .foregroundStyle(renderingMode == .vibrant ? Color.primary : Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    let intent: MediaCommandIntent

    var body: some View {
        Button(intent: intent) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .frame(width: size * 1.9, height: size * 1.9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PlayPauseButton: View {
    let player: PlayerState
    let size: CGFloat

    var body: some View {
        Button(intent: MediaCommandIntent(source: player.source, command: .playPause)) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size, weight: .bold))
                .frame(width: size * 2.3, height: size * 2.3)
                .background(Color.primary.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ControlsRow: View {
    let player: PlayerState
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.8) {
            ControlButton(systemName: "backward.fill", size: size * 0.85,
                          intent: MediaCommandIntent(source: player.source, command: .previous))
            PlayPauseButton(player: player, size: size)
            ControlButton(systemName: "forward.fill", size: size * 0.85,
                          intent: MediaCommandIntent(source: player.source, command: .next))
        }
    }
}

struct VolumeControl: View {
    let player: PlayerState
    let volume: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            ControlButton(systemName: "speaker.minus.fill", size: compact ? 10 : 12,
                          intent: MediaCommandIntent(source: player.source, command: .volumeDown))
            if !compact {
                Text("\(volume)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
            }
            ControlButton(systemName: "speaker.plus.fill", size: compact ? 10 : 12,
                          intent: MediaCommandIntent(source: player.source, command: .volumeUp))
        }
        .foregroundStyle(.secondary)
    }
}

struct ProgressRow: View {
    let player: PlayerState
    let showTimes: Bool

    private var live: Bool { player.isPlaying && player.duration > 0 && !widgetStaticRendering }

    var body: some View {
        VStack(spacing: 3) {
            if live {
                ProgressView(timerInterval: player.progressRange, countsDown: false,
                             label: { EmptyView() }, currentValueLabel: { EmptyView() })
                    .progressViewStyle(.linear)
                    .tint(player.source.color)
            } else {
                StaticProgressBar(fraction: player.duration > 0 ? min(player.elapsed / player.duration, 1) : 0,
                                  color: player.source.color)
            }
            if showTimes {
                HStack {
                    if live {
                        Text(timerInterval: player.progressRange, countsDown: false)
                    } else {
                        Text(formatTime(player.elapsed))
                    }
                    Spacer()
                    Text(formatTime(player.duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct StaticProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: max(geo.size.width * fraction, 4))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Sample data for the widget gallery

extension SharedState {
    static var sample: SharedState {
        var s = SharedState.empty
        var p = PlayerState(source: .spotify)
        p.isAvailable = true
        p.isPlaying = true
        p.title = "Stinkfist"
        p.artist = "TOOL"
        p.album = "Ænima"
        p.duration = 311
        p.elapsed = 74
        p.elapsedAt = Date()
        p.volume = 60
        s.set(p)
        var m = PlayerState(source: .appleMusic); m.isAvailable = true; s.set(m)
        var y = PlayerState(source: .youtube); y.isAvailable = true; s.set(y)
        s.activeSource = .spotify
        s.helperHeartbeat = Date()
        s.updatedAt = Date()
        return s
    }
}
