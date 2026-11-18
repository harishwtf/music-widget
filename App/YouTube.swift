import AppKit
import Foundation

/// Browsers whose tabs the helper can read and script.
enum ScriptableBrowser: CaseIterable {
    case chrome, safari

    var bundleID: String { self == .chrome ? "com.google.Chrome" : "com.apple.Safari" }
    var appName: String { self == .chrome ? "Google Chrome" : "Safari" }
    var displayName: String { self == .chrome ? "Chrome" : "Safari" }
    var isRunning: Bool { AppleScriptRunner.isRunning(bundleID: bundleID) }

    static func forBundleID(_ id: String) -> ScriptableBrowser? {
        allCases.first { $0.bundleID == id }
    }
}

/// One open YouTube tab.
struct YouTubeTab: Equatable {
    let browser: ScriptableBrowser
    let windowID: Int
    let tabIndex: Int
    let url: String
    /// Tab title with the "(3) " counter and " - YouTube" suffix removed.
    let title: String
    let isActive: Bool

    var videoID: String? { Self.videoID(from: url) }

    static func videoID(from url: String) -> String? {
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") {
            let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        guard host.hasSuffix("youtube.com") else { return nil }
        if comps.path == "/watch",
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        for prefix in ["/shorts/", "/live/", "/embed/"] where comps.path.hasPrefix(prefix) {
            if let id = comps.path.dropFirst(prefix.count).split(separator: "/").first, !id.isEmpty {
                return String(id)
            }
        }
        return nil
    }

    static func cleanTitle(_ raw: String) -> String {
        var t = raw
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        for suffix in [" - YouTube Music", " - YouTube"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
            break
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// YouTube in the browser. Two sources of truth are combined:
/// - the system Now Playing info (via mediaremote-adapter): accurate play state and position,
///   and play/pause/skip that work with no browser settings, but only while the browser is the
///   app macOS considers "Now Playing";
/// - the browser's own tab list (AppleScript): which YouTube videos are open, even when paused
///   or when another app took over Now Playing. Controlling those needs the browser's
///   "Allow JavaScript from Apple Events" setting.
final class YouTubeController {
    let source = MediaSource.youtube
    var onChange: (() -> Void)?
    private(set) var current = PlayerState(source: .youtube)
    let videoPlayer = VideoPlayerController()

    private let bridge: MediaRemoteBridge
    private var tabs: [YouTubeTab] = []
    private var scannedBrowsers: Set<ScriptableBrowser> = []
    private var lastScan = Date.distantPast
    /// The latest Now Playing info, only while a browser is the Now Playing app.
    private var nowPlaying: MediaRemoteBridge.NowPlaying?
    private var usingNowPlaying = false
    private var currentTab: YouTubeTab?
    private var focusVideoID: String?
    private var lastBrowser: ScriptableBrowser?

    private struct VideoInfo {
        var title: String
        var channel: String
        var duration: Double
        var elapsed: Double
    }
    private var known: [String: VideoInfo] = [:]
    private var thumbFiles: [String: String] = [:]
    private var frameFiles: [String: String] = [:]
    private var fetchingThumbs: Set<String> = []
    private var nowPlayingArtworkKey = ""
    private var nowPlayingArtworkFile: String?
    private var jsBlockedAt: Date?
    private var grabWork: DispatchWorkItem?

    static let browserNames: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome",
        "com.apple.Safari": "Safari",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "org.mozilla.firefox": "Firefox",
        "app.zen-browser.zen": "Zen",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    init(bridge: MediaRemoteBridge) {
        self.bridge = bridge
        super_init()
    }

    private func super_init() {
        videoPlayer.onChange = { [weak self] in
            self?.rebuild()
            self?.onChange?()
        }
    }

    // MARK: Desktop video player

    /// Moves the current video into the desktop player (pausing the browser), or closes the player.
    func togglePopOut() {
        if videoPlayer.isOpen {
            if let id = videoPlayer.videoID, let s = videoPlayer.status {
                known[id, default: VideoInfo(title: s.title, channel: s.author, duration: s.duration, elapsed: s.time)]
                    .elapsed = s.time
                focusVideoID = id
            }
            videoPlayer.close()
            rebuild()
            return
        }
        scan(force: true)
        rebuild()
        guard let id = current.videoID else { return }
        let time = current.elapsed(at: Date())
        // Pause the browser copy so the two don't play over each other.
        if usingNowPlaying, current.isPlaying {
            bridge.send(1)
        } else if let tab = currentTab, let js = Self.commandJS(.pause) {
            _ = runJS(js, in: tab)
        }
        videoPlayer.open(videoID: id, at: time)
        rebuild()
    }

    // MARK: Inputs

    /// Restores the last known video after a helper restart (as paused).
    func restore(from saved: PlayerState) {
        guard saved.hasTrack else { return }
        var p = saved
        if p.isPlaying {
            p.elapsed = p.elapsed(at: Date())
            p.isPlaying = false
        }
        p.elapsedAt = Date()
        p.inVideoPlayer = nil    // the player window doesn't survive a restart
        if let file = p.artworkFile, !Self.fileExists(file) { p.artworkFile = nil }
        if let id = p.videoID {
            known[id] = VideoInfo(title: p.title, channel: p.artist, duration: p.duration, elapsed: p.elapsed)
            if let file = p.artworkFile { thumbFiles[id] = file }
            focusVideoID = id
        }
        current = p
    }

    /// Called whenever the system's Now Playing app changes or updates.
    func update(from np: MediaRemoteBridge.NowPlaying?) {
        let previous = nowPlaying
        if let np, Self.browserNames[np.bundleID] != nil {
            nowPlaying = np
            if let b = ScriptableBrowser.forBundleID(np.bundleID) { lastBrowser = b }
            let key = np.title + "|" + np.artist
            if key != nowPlayingArtworkKey {
                nowPlayingArtworkKey = key
                nowPlayingArtworkFile = nil
            }
            if nowPlayingArtworkFile == nil, let data = np.artworkData, let image = NSImage(data: data) {
                nowPlayingArtworkFile = ArtworkStore.save(image, source: .youtube, key: "np-" + key,
                                                          maxSide: 960, keep: keepFiles())
            }
        } else {
            nowPlaying = nil
        }
        if previous?.title != nowPlaying?.title { scan(force: true) }
        rebuild()
        guard usingNowPlaying, let np = nowPlaying else { return }
        if previous?.title != np.title {
            scheduleFrameGrab(after: 4)          // new video: grab once it has rendered
        } else if previous?.playing == true && !np.playing {
            scheduleFrameGrab(after: 0.4)        // paused: show the frame it stopped on
        }
    }

    /// Called on every monitor tick.
    func poll() -> PlayerState {
        scan()
        rebuild()
        return current
    }

    // MARK: Commands

    func perform(_ command: MediaCommand) {
        guard command != .select else { return }
        if videoPlayer.isOpen {
            videoPlayer.perform(command)
            return
        }
        scan(force: true)
        rebuild()

        if usingNowPlaying {
            switch command {
            case .playPause: bridge.send(2)
            case .play: bridge.send(0)
            case .pause: bridge.send(1)
            case .next: bridge.send(4)
            case .previous: bridge.send(5)
            case .select, .volumeUp, .volumeDown, .popOut: return
            }
            scheduleFrameGrab(after: 1.5)
            return
        }

        if let tab = currentTab {
            focusVideoID = tab.videoID
            if let js = Self.commandJS(command), runJS(js, in: tab) != nil {
                scheduleFrameGrab(after: 1.5)
                return
            }
            // The browser blocks scripting: bring the video to the front so one click resumes it.
            if jsBlockedAt != nil, command == .play || command == .playPause {
                focus(tab)
            }
            rebuild()
            return
        }

        // No YouTube tab open: reopen the last video where it left off, or YouTube itself.
        if command == .play || command == .playPause {
            reopen()
        }
    }

    // MARK: State

    private func rebuild() {
        var p = PlayerState(source: .youtube)
        p.lastPlayedAt = current.lastPlayedAt

        if videoPlayer.isOpen, let id = videoPlayer.videoID,
           videoPlayer.status?.playing == true || nowPlaying?.playing != true {
            let s = videoPlayer.status
            let info = known[id]
            p.isAvailable = true
            p.isPlaying = s?.playing ?? true
            p.title = (s?.title).flatMap { $0.isEmpty ? nil : $0 } ?? info?.title ?? current.title
            p.artist = (s?.author).flatMap { $0.isEmpty ? nil : $0 } ?? info?.channel ?? "YouTube"
            if let s, !s.isAd {
                p.duration = s.duration > 0 ? s.duration : (info?.duration ?? 0)
                p.elapsed = s.time
                p.elapsedAt = s.at
            } else {
                // An ad is playing: keep the video's own length and position, frozen.
                p.duration = info?.duration ?? 0
                p.elapsed = info?.elapsed ?? 0
                p.elapsedAt = Date()
                p.isPlaying = false
            }
            p.videoID = id
            p.inVideoPlayer = true
            p.detail = s?.isAd == true ? "Ad playing on your desktop" : "Playing on your desktop"
            p.artworkFile = previewFile(for: id)
            if let s, !s.isAd, !p.title.isEmpty {
                known[id] = VideoInfo(title: p.title, channel: p.artist, duration: p.duration, elapsed: s.time)
            }
            usingNowPlaying = false
            current = p
            return
        }

        var tab: YouTubeTab?
        usingNowPlaying = false
        if let np = nowPlaying {
            let browser = ScriptableBrowser.forBundleID(np.bundleID)
            let candidates = tabs.filter { $0.browser == browser && $0.videoID != nil }
            tab = candidates.first { !np.title.isEmpty && $0.title.localizedCaseInsensitiveContains(np.title) }
                ?? candidates.first { !$0.title.isEmpty && np.title.localizedCaseInsensitiveContains($0.title) }
                ?? candidates.first { $0.isActive }
                ?? candidates.first
            // The browser is playing something, but we could read its tabs and none is YouTube.
            let provablyNotYouTube = browser.map { b in
                scannedBrowsers.contains(b) && !tabs.contains { $0.browser == b }
            } ?? false
            usingNowPlaying = !provablyNotYouTube
            if !usingNowPlaying { tab = nil }
        }
        if !usingNowPlaying {
            let videoTabs = tabs.filter { $0.videoID != nil }
            tab = videoTabs.first { $0.videoID != nil && $0.videoID == focusVideoID }
                ?? videoTabs.first { $0.isActive }
                ?? videoTabs.first
                ?? tabs.first
        }
        currentTab = tab
        if let tab { lastBrowser = tab.browser }
        let videoID = tab?.videoID

        if usingNowPlaying, let np = nowPlaying {
            p.isAvailable = true
            p.isPlaying = np.playing
            p.title = np.title.isEmpty ? (tab?.title ?? "") : np.title
            p.artist = np.artist
            p.duration = np.duration
            p.elapsed = np.elapsed
            p.elapsedAt = np.timestamp ?? Date()
            if let id = videoID {
                known[id] = VideoInfo(title: p.title, channel: np.artist, duration: np.duration, elapsed: np.elapsed)
                focusVideoID = id
            }
        } else if let tab {
            p.isAvailable = true
            if let id = videoID {
                let info = known[id]
                p.title = info?.title ?? tab.title
                p.artist = info?.channel ?? "YouTube"
                p.duration = info?.duration ?? 0
                p.elapsed = (current.videoID == id) ? current.elapsed(at: Date()) : (info?.elapsed ?? 0)
                // Another app took over Now Playing; the video is most likely paused.
                p.isPlaying = false
            }
            p.elapsedAt = Date()
        } else if let id = current.videoID, current.hasTrack {
            // Tab closed: remember the video so play can reopen it.
            p = current
            p.isAvailable = false
            if p.isPlaying {
                p.elapsed = p.elapsed(at: Date())
                p.isPlaying = false
            }
            p.elapsedAt = Date()
            p.detail = "Tab closed · press play to reopen"
            p.artworkFile = previewFile(for: id)
            current = p
            return
        } else {
            current = p
            return
        }

        p.videoID = videoID
        let browserName = tab?.browser.displayName
            ?? nowPlaying.flatMap { Self.browserNames[$0.bundleID] } ?? ""
        if !usingNowPlaying, jsBlockedAt != nil, tab?.browser == .chrome {
            p.detail = SharedStore.chromeHint
        } else if !browserName.isEmpty {
            p.detail = "YouTube in \(browserName)"
        }
        p.artworkFile = previewFile(for: videoID) ?? (usingNowPlaying ? nowPlayingArtworkFile : nil)
        current = p
    }

    // MARK: Tabs

    private static let chromeScanScript = """
    with timeout of 3 seconds
    tell application "Google Chrome"
        set sep to character id 31
        set rs to character id 30
        set out to ""
        repeat with w in windows
            set wid to id of w
            set act to active tab index of w
            set us to URL of every tab of w
            set ts to title of every tab of w
            repeat with i from 1 to count of us
                set u to item i of us
                if u contains "youtube.com/" or u contains "youtu.be/" then
                    set out to out & wid & sep & i & sep & u & sep & (item i of ts) & sep & (i = act) & rs
                end if
            end repeat
        end repeat
        return out
    end tell
    end timeout
    """

    private static let safariScanScript = """
    with timeout of 3 seconds
    tell application "Safari"
        set sep to character id 31
        set rs to character id 30
        set out to ""
        repeat with w in windows
            try
                set wid to id of w
                set act to index of current tab of w
                set us to URL of every tab of w
                set ts to name of every tab of w
                repeat with i from 1 to count of us
                    set u to item i of us
                    if u is not missing value then
                        if u contains "youtube.com/" or u contains "youtu.be/" then
                            set out to out & wid & sep & i & sep & u & sep & (item i of ts) & sep & (i = act) & rs
                        end if
                    end if
                end repeat
            end try
        end repeat
        return out
    end tell
    end timeout
    """

    private func scan(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastScan) > 2.5 else { return }
        lastScan = Date()
        var found: [YouTubeTab] = []
        var scanned: Set<ScriptableBrowser> = []
        for browser in ScriptableBrowser.allCases where browser.isRunning {
            let script = browser == .chrome ? Self.chromeScanScript : Self.safariScanScript
            guard let raw = AppleScriptRunner.string(script) else { continue }
            scanned.insert(browser)
            for record in raw.components(separatedBy: "\u{1E}") where !record.isEmpty {
                let f = record.components(separatedBy: unitSeparator)
                guard f.count >= 5, let wid = Int(f[0]), let idx = Int(f[1]) else { continue }
                found.append(YouTubeTab(browser: browser, windowID: wid, tabIndex: idx, url: f[2],
                                        title: YouTubeTab.cleanTitle(f[3]), isActive: f[4] == "true"))
            }
        }
        tabs = found
        scannedBrowsers = scanned
    }

    private func runJS(_ js: String, in tab: YouTubeTab) -> String? {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch tab.browser {
        case .chrome:
            script = """
            with timeout of 4 seconds
            tell application "Google Chrome" to execute tab \(tab.tabIndex) of window id \(tab.windowID) javascript "\(escaped)"
            end timeout
            """
        case .safari:
            script = """
            with timeout of 4 seconds
            tell application "Safari" to do JavaScript "\(escaped)" in tab \(tab.tabIndex) of window id \(tab.windowID)
            end timeout
            """
        }
        guard let result = AppleScriptRunner.run(script) else {
            if AppleScriptRunner.lastErrorNumber == 12
                || AppleScriptRunner.lastErrorMessage.localizedCaseInsensitiveContains("JavaScript") {
                jsBlockedAt = Date()
            }
            return nil
        }
        jsBlockedAt = nil
        return result.stringValue ?? ""
    }

    private func focus(_ tab: YouTubeTab) {
        let script: String
        switch tab.browser {
        case .chrome:
            script = """
            tell application "Google Chrome"
                set active tab index of window id \(tab.windowID) to \(tab.tabIndex)
                set index of window id \(tab.windowID) to 1
                activate
            end tell
            """
        case .safari:
            script = """
            tell application "Safari"
                set current tab of window id \(tab.windowID) to tab \(tab.tabIndex) of window id \(tab.windowID)
                set index of window id \(tab.windowID) to 1
                activate
            end tell
            """
        }
        AppleScriptRunner.run(script)
    }

    private func reopen() {
        var urlString = "https://www.youtube.com/"
        if let id = current.videoID {
            let t = Int(current.elapsed)
            urlString = "https://www.youtube.com/watch?v=\(id)" + (t > 5 ? "&t=\(t)s" : "")
        }
        guard let url = URL(string: urlString) else { return }
        if let browser = lastBrowser,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func commandJS(_ command: MediaCommand) -> String? {
        let video = "var v=document.querySelector('video.html5-main-video')||document.querySelector('video');"
        switch command {
        case .playPause: return "(function(){\(video)if(!v)return 'none';if(v.paused){v.play();}else{v.pause();}return 'ok';})()"
        case .play: return "(function(){\(video)if(!v)return 'none';v.play();return 'ok';})()"
        case .pause: return "(function(){\(video)if(!v)return 'none';v.pause();return 'ok';})()"
        case .next: return "(function(){var b=document.querySelector('.ytp-next-button');if(b){b.click();return 'ok';}return 'none';})()"
        case .previous: return "(function(){\(video)var b=document.querySelector('.ytp-prev-button');if(v&&v.currentTime>3){v.currentTime=0;return 'ok';}if(b){b.click();return 'ok';}return 'none';})()"
        case .select, .volumeUp, .volumeDown, .popOut: return nil
        }
    }

    // MARK: Preview images

    /// The current frame of the video, drawn into a canvas (YouTube streams through same-origin blobs,
    /// so the canvas isn't tainted).
    private static let frameJS = """
    (function(){var v=document.querySelector('video.html5-main-video')||document.querySelector('video');\
    if(!v||!v.videoWidth)return '';var c=document.createElement('canvas');c.width=960;\
    c.height=Math.round(960*v.videoHeight/v.videoWidth);c.getContext('2d').drawImage(v,0,0,c.width,c.height);\
    try{return c.toDataURL('image/jpeg',0.82);}catch(e){return '';}})()
    """

    private func scheduleFrameGrab(after delay: TimeInterval) {
        grabWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.grabFrame() }
        grabWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func grabFrame() {
        // Don't keep poking a browser that refuses scripting; retry once a minute.
        if let blocked = jsBlockedAt, Date().timeIntervalSince(blocked) < 60 { return }
        scan(force: true)
        rebuild()
        guard let tab = currentTab, let id = tab.videoID,
              let result = runJS(Self.frameJS, in: tab), result.hasPrefix("data:image"),
              let comma = result.firstIndex(of: ","),
              let data = Data(base64Encoded: String(result[result.index(after: comma)...])),
              let image = NSImage(data: data), image.size.width > 0 else { return }
        let key = "frame-\(id)-\(Int(Date().timeIntervalSince1970))"
        guard let file = ArtworkStore.save(image, source: .youtube, key: key, maxSide: 960,
                                           keep: keepFiles(except: frameFiles[id])) else { return }
        frameFiles[id] = file
        rebuild()
        onChange?()
    }

    private func previewFile(for videoID: String?) -> String? {
        guard let id = videoID else { return nil }
        if let f = frameFiles[id], Self.fileExists(f) { return f }
        if let f = thumbFiles[id], Self.fileExists(f) { return f }
        fetchThumbnail(id)
        return nil
    }

    /// YouTube's own 16:9 thumbnail for the video (no browser settings needed).
    private func fetchThumbnail(_ id: String) {
        guard !fetchingThumbs.contains(id) else { return }
        fetchingThumbs.insert(id)
        let urls = ["maxresdefault", "hqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg") }
        Self.fetchFirstImage(urls) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingThumbs.remove(id)
                guard let image,
                      let file = ArtworkStore.save(image, source: .youtube, key: "thumb-\(id)", maxSide: 960,
                                                   keep: self.keepFiles()) else { return }
                self.thumbFiles[id] = file
                self.rebuild()
                self.onChange?()
            }
        }
    }

    private static func fetchFirstImage(_ urls: [URL], completion: @escaping (NSImage?) -> Void) {
        guard let url = urls.first else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let image = NSImage(data: data), image.size.width > 160 {
                completion(image)
            } else {
                fetchFirstImage(Array(urls.dropFirst()), completion: completion)
            }
        }.resume()
    }

    /// Files to keep when saving new YouTube artwork: everything for the video on screen.
    private func keepFiles(except: String? = nil) -> Set<String> {
        var keep = Set<String>()
        if let id = currentTab?.videoID ?? current.videoID {
            if let f = thumbFiles[id] { keep.insert(f) }
            if let f = frameFiles[id], f != except { keep.insert(f) }
        }
        if let f = nowPlayingArtworkFile { keep.insert(f) }
        return keep
    }

    private static func fileExists(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: SharedStore.artworkURL(for: file).path)
    }
}
