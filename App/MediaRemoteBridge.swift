import Foundation

/// Streams the system "Now Playing" info (what the Control Center player shows) through the
/// bundled mediaremote-adapter, which is what lets us see YouTube playing in a browser.
final class MediaRemoteBridge {
    struct NowPlaying {
        var bundleID: String
        var playing: Bool
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var timestamp: Date?
        var artworkData: Data?
    }

    var onUpdate: ((NowPlaying?) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var stopped = false
    private var restartDelay: TimeInterval = 2
    private let queue = DispatchQueue(label: "com.harish.musicwidget.mediaremote")

    private var scriptPath: String? {
        Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl")
    }

    private var frameworkPath: String? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework").path
    }

    func start() {
        stopped = false
        killStaleAdapters()
        launch()
    }

    /// An adapter left behind by a helper that was killed (e.g. during a reinstall) keeps streaming
    /// forever; stop any before starting ours.
    private func killStaleAdapters() {
        guard let script = scriptPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped, let script = scriptPath, let framework = frameworkPath else {
            NSLog("MediaRemoteBridge: adapter files missing")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "stream", "--no-diff", "--debounce=150"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("mediaremote-adapter: \(text)")
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard let self, !self.stopped else { return }
            NSLog("mediaremote-adapter exited (\(proc.terminationStatus)); restarting in \(self.restartDelay)s")
            let delay = self.restartDelay
            self.restartDelay = min(self.restartDelay * 2, 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.launch() }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("MediaRemoteBridge: failed to start adapter: \(error)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty, let json = try? JSONSerialization.jsonObject(with: line) else { return }
        restartDelay = 2
        var payload: Any? = json
        if let wrapper = json as? [String: Any], wrapper["type"] != nil {
            payload = wrapper["payload"]
        }
        guard let dict = payload as? [String: Any] else {
            onUpdate?(nil)
            return
        }
        let np = NowPlaying(
            bundleID: dict["bundleIdentifier"] as? String ?? "",
            playing: dict["playing"] as? Bool ?? false,
            title: dict["title"] as? String ?? "",
            artist: dict["artist"] as? String ?? "",
            album: dict["album"] as? String ?? "",
            duration: (dict["duration"] as? NSNumber)?.doubleValue ?? 0,
            elapsed: (dict["elapsedTime"] as? NSNumber)?.doubleValue ?? 0,
            timestamp: Self.parseDate(dict["timestamp"] as? String),
            artworkData: (dict["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
        )
        onUpdate?(np)
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Sends a MediaRemote command id (0 play, 1 pause, 2 toggle, 4 next, 5 previous).
    func send(_ commandID: Int) {
        guard let script = scriptPath, let framework = frameworkPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [script, framework, "send", "\(commandID)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                NSLog("MediaRemoteBridge: send failed: \(error)")
            }
        }
    }
}
