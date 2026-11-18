import AppKit
import Combine
import Foundation
import WidgetKit

/// Polls the players, picks the active one, writes the shared state and refreshes the widget.
final class PlayerMonitor: ObservableObject {
    @Published private(set) var state: SharedState = SharedStore.load()

    private let spotify = SpotifyController()
    private let music = MusicController()
    private let bridge = MediaRemoteBridge()
    private lazy var youtube = YouTubeController(bridge: bridge)

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var userSelection: (source: MediaSource, at: Date)?
    private var reloadWork: DispatchWorkItem?

    func start() {
        youtube.restore(from: state.player(.youtube))
        youtube.onChange = { [weak self] in self?.refresh() }
        spotify.onChange = { [weak self] in self?.refresh() }
        music.onChange = { [weak self] in self?.refresh() }
        bridge.onUpdate = { [weak self] np in
            DispatchQueue.main.async {
                self?.youtube.update(from: np)
                self?.refresh()
            }
        }
        bridge.start()

        let center = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh(after: 0.3)
            })
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        bridge.stop()
        var s = state
        s.helperHeartbeat = .distantPast
        SharedStore.save(s)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
    }

    func scheduleRefresh(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    func refresh() {
        let now = Date()
        let old = state
        var new = old
        let fetched = [
            spotify.fetch(previous: old.player(.spotify)),
            music.fetch(previous: old.player(.appleMusic)),
            youtube.poll(),
        ]
        for var p in fetched {
            let prev = old.player(p.source)
            if p.isPlaying && (!prev.isPlaying || prev.lastPlayedAt == .distantPast) {
                p.lastPlayedAt = now
            } else {
                p.lastPlayedAt = prev.lastPlayedAt
            }
            new.set(p)
        }
        new.activeSource = chooseActive(new, previous: old)
        youtube.videoPlayer.setWidgetShowsVideo(new.activeSource == .youtube)
        new.helperHeartbeat = now
        let changed = Self.visiblyDifferent(old, new)
        if changed { new.updatedAt = now }
        state = new
        SharedStore.save(new)
        if changed { requestWidgetReload() }
    }

    /// Commands arriving from the widget.
    func handle(source: MediaSource, command: MediaCommand) {
        if command == .select {
            userSelection = (source, Date())
            refresh()
            return
        }
        defer { refresh() }
        switch source {
        case .spotify: spotify.perform(command)
        case .appleMusic: music.perform(command)
        case .youtube:
            if command == .popOut {
                userSelection = (.youtube, Date())
                youtube.togglePopOut()
            } else {
                youtube.perform(command)
            }
        }
        scheduleRefresh(after: 0.5)
        scheduleRefresh(after: 2.0)
    }

    private func chooseActive(_ s: SharedState, previous: SharedState) -> MediaSource {
        let playing = s.players.filter { $0.isPlaying }
        if let sel = userSelection {
            // Keep the user's pick unless another player started after they chose.
            let newer = playing.filter { $0.source != sel.source && $0.lastPlayedAt > sel.at }
            if newer.isEmpty { return sel.source }
            userSelection = nil
        }
        if let best = playing.max(by: { $0.lastPlayedAt < $1.lastPlayedAt }) {
            return best.source
        }
        let recent = s.players.filter { $0.hasTrack && $0.lastPlayedAt > .distantPast }
        if let best = recent.max(by: { $0.lastPlayedAt < $1.lastPlayedAt }) {
            return best.source
        }
        if let withTrack = s.players.first(where: { $0.hasTrack }) {
            return withTrack.source
        }
        return previous.activeSource
    }

    /// Only changes the widget actually shows. Each reload request counts against WidgetKit's
    /// daily budget; once it's spent, macOS ignores requests and the widget goes stale.
    private static func visiblyDifferent(_ a: SharedState, _ b: SharedState) -> Bool {
        if a.activeSource != b.activeSource { return true }
        if a.helperIsRunning != b.helperIsRunning { return true }
        for source in MediaSource.allCases where a.player(source).isAvailable != b.player(source).isAvailable {
            return true
        }
        let x = a.active, y = b.active
        if x.isPlaying != y.isPlaying || x.title != y.title || x.artist != y.artist || x.album != y.album { return true }
        if x.artworkFile != y.artworkFile || x.volume != y.volume || x.detail != y.detail { return true }
        if x.videoID != y.videoID || x.inVideoPlayer != y.inVideoPlayer { return true }
        if abs(x.duration - y.duration) > 1 { return true }
        // A seek or restart (the progress bar would otherwise be off).
        if abs(x.elapsed(at: y.elapsedAt) - y.elapsed) > 5 { return true }
        return false
    }

    private func requestWidgetReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Already drawn (e.g. by the redraw that follows a button tap): don't spend budget.
            if SharedStore.lastRendered() >= self.state.updatedAt {
                diagLog("helper  reload-skip (already drawn) title=\(self.state.active.title.prefix(30))")
                return
            }
            diagLog("helper  reload-request active=\(self.state.activeSource.rawValue) title=\(self.state.active.title.prefix(30))")
            WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
        }
        reloadWork = work
        // Batch a song change with its cover art, which arrives a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

/// Listens for the distributed notifications the widget posts.
final class CommandReceiver {
    private var observers: [NSObjectProtocol] = []

    init(monitor: PlayerMonitor) {
        let center = DistributedNotificationCenter.default()
        for name in SharedStore.allCommandNames {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak monitor] note in
                guard let (source, command) = SharedStore.parse(commandName: note.name.rawValue) else { return }
                monitor?.handle(source: source, command: command)
            })
        }
    }
}
