import Foundation
import SwiftUI

/// The three players the widget knows about.
enum MediaSource: String, Codable, CaseIterable, Identifiable {
    case spotify
    case appleMusic
    case youtube

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        case .youtube: return "YouTube"
        }
    }

    var symbolName: String {
        switch self {
        case .spotify: return "waveform"
        case .appleMusic: return "music.note"
        case .youtube: return "play.rectangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .appleMusic: return Color(red: 0.98, green: 0.18, blue: 0.28)
        case .youtube: return Color(red: 1.0, green: 0.0, blue: 0.0)
        }
    }

    /// Does this source support a volume control from the widget?
    var supportsVolume: Bool { self != .youtube }
}

/// Commands the widget can send to the helper app.
enum MediaCommand: String, Codable, CaseIterable {
    case playPause
    case play
    case pause
    case next
    case previous
    case select
    case volumeUp
    case volumeDown
    /// YouTube only: open or close the desktop video player.
    case popOut
}

/// Snapshot of one player, as written by the helper app.
struct PlayerState: Codable, Equatable {
    var source: MediaSource
    /// The app is running (Spotify / Music) or a YouTube tab is reporting playback.
    var isAvailable: Bool = false
    var isPlaying: Bool = false
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    /// Seconds.
    var duration: Double = 0
    /// Seconds into the track at `elapsedAt`.
    var elapsed: Double = 0
    var elapsedAt: Date = .distantPast
    /// File name inside the shared container (nil = no artwork).
    var artworkFile: String? = nil
    /// 0...100 when the player exposes it.
    var volume: Int? = nil
    /// When this source last started playing; used to pick the active source.
    var lastPlayedAt: Date = .distantPast
    /// Extra context, e.g. the browser name for YouTube.
    var detail: String = ""
    /// YouTube video ID, used for the preview image and to reopen the video.
    var videoID: String? = nil
    /// YouTube is playing in the desktop video player.
    var inVideoPlayer: Bool? = nil

    init(source: MediaSource) { self.source = source }

    var hasTrack: Bool { !title.isEmpty }

    /// Date range used by SwiftUI's live timer views.
    var progressRange: ClosedRange<Date> {
        let start = elapsedAt.addingTimeInterval(-elapsed)
        return start...start.addingTimeInterval(max(duration, 1))
    }

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        return min(max(elapsed + date.timeIntervalSince(elapsedAt), 0), max(duration, elapsed))
    }
}

/// Everything the widget needs, written atomically to the shared container.
struct SharedState: Codable {
    var players: [PlayerState]
    var activeSource: MediaSource
    var updatedAt: Date
    var helperHeartbeat: Date

    static var empty: SharedState {
        SharedState(players: MediaSource.allCases.map { PlayerState(source: $0) },
                    activeSource: .spotify,
                    updatedAt: .distantPast,
                    helperHeartbeat: .distantPast)
    }

    func player(_ source: MediaSource) -> PlayerState {
        players.first { $0.source == source } ?? PlayerState(source: source)
    }

    mutating func set(_ player: PlayerState) {
        if let i = players.firstIndex(where: { $0.source == player.source }) {
            players[i] = player
        } else {
            players.append(player)
        }
    }

    var active: PlayerState { player(activeSource) }

    /// The helper writes a heartbeat every couple of seconds.
    var helperIsRunning: Bool { Date().timeIntervalSince(helperHeartbeat) < 20 }
}

/// Reads and writes the shared state and artwork in the App Group container.
enum SharedStore {
    static let appGroupID = "group.com.harish.musicwidget"
    static let widgetKind = "MusicWidget"
    static let commandPrefix = "com.harish.musicwidget.cmd"
    static let chromeHint = "In Chrome, turn on View ▸ Developer ▸ Allow JavaScript from Apple Events"

    /// Path relative to the real home directory; the widget extension is granted this folder
    /// through a sandbox file exception (App Groups need a Team ID, which ad-hoc signing lacks).
    static let sharedFolder = "Library/Application Support/MusicWidget"

    static var containerURL: URL {
        // NSHomeDirectory() points inside the sandbox container for the extension, so ask the passwd db.
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        let url = URL(fileURLWithPath: home).appendingPathComponent(sharedFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var stateURL: URL { containerURL.appendingPathComponent("state.json") }
    static var renderedURL: URL { containerURL.appendingPathComponent("rendered.txt") }

    /// The widget writes the `updatedAt` of the state it just drew, so the helper can skip
    /// reload requests the widget doesn't need (each one counts against WidgetKit's daily budget).
    static func markRendered(_ state: SharedState) {
        try? String(state.updatedAt.timeIntervalSince1970).write(to: renderedURL, atomically: true, encoding: .utf8)
    }

    static func lastRendered() -> Date {
        guard let s = try? String(contentsOf: renderedURL, encoding: .utf8), let t = Double(s) else { return .distantPast }
        return Date(timeIntervalSince1970: t)
    }

    static func artworkURL(for file: String) -> URL {
        containerURL.appendingPathComponent(file)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func load() -> SharedState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(SharedState.self, from: data) else {
            return .empty
        }
        return state
    }

    static func save(_ state: SharedState) {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    static func commandName(source: MediaSource, command: MediaCommand) -> String {
        "\(commandPrefix).\(source.rawValue).\(command.rawValue)"
    }

    static var allCommandNames: [String] {
        MediaSource.allCases.flatMap { s in MediaCommand.allCases.map { commandName(source: s, command: $0) } }
    }

    static func parse(commandName name: String) -> (MediaSource, MediaCommand)? {
        guard name.hasPrefix(commandPrefix + ".") else { return nil }
        let parts = name.dropFirst(commandPrefix.count + 1).split(separator: ".")
        guard parts.count == 2,
              let source = MediaSource(rawValue: String(parts[0])),
              let command = MediaCommand(rawValue: String(parts[1])) else { return nil }
        return (source, command)
    }
}

/// Appends a line to diag.log in the shared folder (kept small). Used to see whether the
/// widget actually redraws when the helper asks it to.
func diagLog(_ message: String) {
    let url = SharedStore.containerURL.appendingPathComponent("diag.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int, size > 200_000 {
        try? FileManager.default.removeItem(at: url)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = max(Int(seconds.rounded()), 0)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
