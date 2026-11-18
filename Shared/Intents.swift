import AppIntents
import Foundation

/// Fired by the widget's buttons. Runs inside the widget extension (sandboxed), so it
/// cannot talk to Spotify directly; it updates the shared state optimistically and
/// posts a distributed notification that the helper app picks up.
struct MediaCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Music Widget Command"
    static var description = IntentDescription("Controls Spotify, Apple Music or YouTube from the Music Widget.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Source") var source: String
    @Parameter(title: "Command") var command: String

    init() {}

    init(source: MediaSource, command: MediaCommand) {
        self.source = source.rawValue
        self.command = command.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let s = MediaSource(rawValue: source), let c = MediaCommand(rawValue: command) else {
            return .result()
        }
        let before = SharedStore.load()
        if c == .select || !before.helperIsRunning {
            // Switching tabs is instant; show it right away.
            var state = before
            state.activeSource = s
            SharedStore.save(state)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(SharedStore.commandName(source: s, command: c)),
            object: nil, userInfo: nil, deliverImmediately: true)
        guard before.helperIsRunning, c != .select else { return .result() }

        // Wait for the helper to carry out the command and write the new state (and let the cover
        // art catch up), then return. WidgetKit redraws the widget after an intent without
        // touching its daily refresh budget, so this redraw always shows the real result.
        let start = Date()
        let limit: TimeInterval = c == .popOut ? 3.0 : 2.5
        var lastChange: Date?
        var seen = before.updatedAt
        while Date().timeIntervalSince(start) < limit {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = SharedStore.load().updatedAt
            if now > seen {
                seen = now
                lastChange = Date()
            }
            if let lastChange, Date().timeIntervalSince(lastChange) > 0.4 { break }
        }
        return .result()
    }
}

/// Shown when the helper app is not running: launches it.
struct OpenHelperIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Music Widget"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        .result()
    }
}
