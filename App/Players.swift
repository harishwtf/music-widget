import AppKit
import Foundation

/// A player the helper can query and control through AppleScript (Spotify, Apple Music).
protocol ScriptablePlayer: AnyObject {
    var source: MediaSource { get }
    var bundleID: String { get }
    var appName: String { get }
    var onChange: (() -> Void)? { get set }
    func fetch(previous: PlayerState) -> PlayerState
    func perform(_ command: MediaCommand)
}

extension ScriptablePlayer {
    var isRunning: Bool { AppleScriptRunner.isRunning(bundleID: bundleID) }

    func commandScript(_ command: MediaCommand) -> String? {
        let body: String
        switch command {
        case .playPause: body = "playpause"
        case .play: body = "play"
        case .pause: body = "pause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .volumeUp: body = "set v to (sound volume) + 10\nif v > 100 then set v to 100\nset sound volume to v"
        case .volumeDown: body = "set v to (sound volume) - 10\nif v < 0 then set v to 0\nset sound volume to v"
        case .select, .popOut: return nil
        }
        return "with timeout of 4 seconds\ntell application \"\(appName)\"\n\(body)\nend tell\nend timeout"
    }

    /// Default command handling: launch the app for play, otherwise script it.
    func performDefault(_ command: MediaCommand) {
        guard let script = commandScript(command) else { return }
        if !isRunning {
            guard command == .play || command == .playPause else { return }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    AppleScriptRunner.run("with timeout of 4 seconds\ntell application \"\(self.appName)\"\nplay\nend tell\nend timeout")
                    self.onChange?()
                }
            }
            return
        }
        AppleScriptRunner.run(script)
    }
}

// MARK: - Spotify

final class SpotifyController: ScriptablePlayer {
    let source = MediaSource.spotify
    let bundleID = "com.spotify.client"
    let appName = "Spotify"
    var onChange: (() -> Void)?

    private var artworkKey = ""
    private var artworkFile: String?

    private static let statusScript = """
    with timeout of 4 seconds
    tell application "Spotify"
        set sep to character id 31
        if player state is stopped then
            return "stopped"
        end if
        set playState to "paused"
        if player state is playing then
            set playState to "playing"
        end if
        set trk to current track
        return playState & sep & (name of trk) & sep & (artist of trk) & sep & (album of trk) & sep & ((duration of trk) as text) & sep & ((player position) as text) & sep & (artwork url of trk) & sep & ((sound volume) as text) & sep & (id of trk)
    end tell
    end timeout
    """

    func fetch(previous: PlayerState) -> PlayerState {
        var p = PlayerState(source: source)
        p.lastPlayedAt = previous.lastPlayedAt
        guard isRunning else { return p }
        p.isAvailable = true
        guard let raw = AppleScriptRunner.string(Self.statusScript), raw != "stopped" else { return p }
        let f = raw.components(separatedBy: unitSeparator)
        guard f.count >= 9 else { return p }
        p.isPlaying = f[0] == "playing"
        p.title = f[1]
        p.artist = f[2]
        p.album = f[3]
        p.duration = scriptNumber(f[4]) / 1000
        p.elapsed = scriptNumber(f[5])
        p.elapsedAt = Date()
        p.volume = Int(scriptNumber(f[7]))
        updateArtwork(urlString: f[6], key: f[8])
        p.artworkFile = artworkFile
        return p
    }

    private func updateArtwork(urlString: String, key: String) {
        guard key != artworkKey else { return }
        artworkKey = key
        guard let url = URL(string: urlString) else { artworkFile = nil; return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = NSImage(data: data) else { return }
            let file = ArtworkStore.save(image, source: .spotify, key: key)
            DispatchQueue.main.async {
                guard self.artworkKey == key else { return }
                self.artworkFile = file
                self.onChange?()
            }
        }.resume()
    }

    func perform(_ command: MediaCommand) { performDefault(command) }
}

// MARK: - Apple Music

final class MusicController: ScriptablePlayer {
    let source = MediaSource.appleMusic
    let bundleID = "com.apple.Music"
    let appName = "Music"
    var onChange: (() -> Void)?

    private var artworkKey = ""
    private var artworkFile: String?

    private static let statusScript = """
    with timeout of 4 seconds
    tell application "Music"
        set sep to character id 31
        if player state is stopped then
            return "stopped"
        end if
        set playState to "paused"
        if player state is playing then
            set playState to "playing"
        end if
        set trk to current track
        return playState & sep & (name of trk) & sep & (artist of trk) & sep & (album of trk) & sep & ((duration of trk) as text) & sep & ((player position) as text) & sep & ((sound volume) as text) & sep & (persistent ID of trk)
    end tell
    end timeout
    """

    private static let artworkScript = """
    with timeout of 4 seconds
    tell application "Music"
        if (count of artworks of current track) is 0 then
            return ""
        end if
        return raw data of artwork 1 of current track
    end tell
    end timeout
    """

    func fetch(previous: PlayerState) -> PlayerState {
        var p = PlayerState(source: source)
        p.lastPlayedAt = previous.lastPlayedAt
        guard isRunning else { return p }
        p.isAvailable = true
        guard let raw = AppleScriptRunner.string(Self.statusScript), raw != "stopped" else { return p }
        let f = raw.components(separatedBy: unitSeparator)
        guard f.count >= 8 else { return p }
        p.isPlaying = f[0] == "playing"
        p.title = f[1]
        p.artist = f[2]
        p.album = f[3]
        p.duration = scriptNumber(f[4])
        p.elapsed = scriptNumber(f[5])
        p.elapsedAt = Date()
        p.volume = Int(scriptNumber(f[6]))
        updateArtwork(key: f[7])
        p.artworkFile = artworkFile
        return p
    }

    private func updateArtwork(key: String) {
        guard key != artworkKey else { return }
        artworkKey = key
        artworkFile = nil
        guard let result = AppleScriptRunner.run(Self.artworkScript) else { return }
        let data = result.data
        guard !data.isEmpty, let image = NSImage(data: data) else { return }
        artworkFile = ArtworkStore.save(image, source: .appleMusic, key: key)
    }

    func perform(_ command: MediaCommand) { performDefault(command) }
}
