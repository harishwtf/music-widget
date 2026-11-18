import AppKit
import WebKit

/// A small 16:9 YouTube player window. By default it sits at desktop level, next to the widgets
/// (normal windows cover it, just like widgets); the pin button floats it above everything.
/// Widgets themselves can only show still images, so this is how video plays "in" the widget area.
final class VideoPlayerController: NSObject {
    struct Status {
        var title: String
        var author: String
        var time: Double
        var duration: Double
        var playing: Bool
        var isAd: Bool
        var at: Date
    }

    private enum Mode { case embed, watchPage }

    var onChange: (() -> Void)?
    private(set) var videoID: String?
    private(set) var status: Status?
    /// A video is loaded (the window may be hidden while the widget shows another player).
    var isOpen: Bool { videoID != nil && panel != nil }

    private var panel: VideoPanel?
    private var container: NSView?
    private var webView: WKWebView?
    private var dockTimer: Timer?
    private var lastDock: NSRect?
    private var widgetShowsVideo = true
    private var notificationCenterPIDs: [pid_t: Bool] = [:]
    private var mode: Mode = .embed
    private var startTime: Double = 0
    private var pollTimer: Timer?
    private var bar: HoverBar?
    /// WebKit doesn't let the embed start itself; the helper presses play once it's ready.
    private var autoplayUntil: Date?

    private static let frameKey = "videoPanelFrame"
    private static let pinnedKey = "videoPanelFloating"
    private var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinnedKey) }
    }

    // MARK: Open / close

    func open(videoID: String, at time: Double) {
        self.videoID = videoID
        startTime = max(0, time)
        mode = .embed
        status = nil
        autoplayUntil = Date().addingTimeInterval(15)
        widgetShowsVideo = true
        if panel == nil { makePanel() }
        load()
        applyMode()
        startPolling()
        onChange?()
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        dockTimer?.invalidate()
        dockTimer = nil
        webView?.evaluateJavaScript("window.mwCmd && mwCmd('pause')")
        webView?.loadHTMLString("", baseURL: nil)
        panel?.orderOut(nil)
        status = nil
        videoID = nil
        onChange?()
    }

    func perform(_ command: MediaCommand) {
        autoplayUntil = nil
        let js: String
        switch command {
        case .playPause: js = "mwCmd('toggle')"
        case .play: js = "mwCmd('play')"
        case .pause: js = "mwCmd('pause')"
        case .previous: js = "mwCmd('restart')"
        case .next: js = "mwCmd('next')"
        default: return
        }
        webView?.evaluateJavaScript("window.mwCmd && \(js)") { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.poll() }
        }
    }

    // MARK: Window

    private func makePanel() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let proxy = MessageProxy(owner: self)
        config.userContentController.add(proxy, name: "mw")
        config.userContentController.addUserScript(WKUserScript(source: Self.pageScript,
                                                                injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        let panel = VideoPanel(contentRect: Self.savedFrame(),
                               styleMask: [.borderless, .nonactivatingPanel, .resizable],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 240, height: 135)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView = container

        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        let bar = HoverBar(pinned: pinned)
        bar.onClose = { [weak self] in self?.close() }
        bar.onPin = { [weak self] in self?.togglePin() }
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame),
                                               name: NSWindow.didResizeNotification, object: panel)
        self.panel = panel
        self.container = container
        self.webView = web
        self.bar = bar
    }

    private func togglePin() {
        pinned.toggle()
        applyMode()
    }

    /// Docked: laid exactly over the widget's video preview, one layer above the widget, following
    /// it if it moves. Floating ("pinned"): a free window on top of everything, movable and resizable.
    private func applyMode() {
        guard let panel else { return }
        bar?.setPinned(pinned)
        if pinned {
            dockTimer?.invalidate()
            dockTimer = nil
            panel.isMovableByWindowBackground = true
            panel.styleMask.insert(.resizable)
            panel.hasShadow = true
            container?.layer?.cornerRadius = 14
            panel.setFrame(Self.savedFrame(), display: true)
            panel.level = .floating
            panel.orderFrontRegardless()
        } else {
            panel.isMovableByWindowBackground = false
            panel.styleMask.remove(.resizable)
            panel.hasShadow = false
            updateDock()
            dockTimer?.invalidate()
            dockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updateDock()
            }
        }
    }

    /// The widget shows another player (Spotify / Music): get out of its way.
    func setWidgetShowsVideo(_ shows: Bool) {
        guard shows != widgetShowsVideo else { return }
        widgetShowsVideo = shows
        guard isOpen, !pinned, let panel else { return }
        if shows {
            updateDock()
        } else {
            webView?.evaluateJavaScript("window.mwCmd && mwCmd('pause')")
            panel.orderOut(nil)
        }
    }

    private func updateDock() {
        guard let panel, isOpen, !pinned else { return }
        guard widgetShowsVideo else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if let target = findDockTarget() {
            if panel.frame != target.rect { panel.setFrame(target.rect, display: true) }
            container?.layer?.cornerRadius = target.cornerRadius
            if panel.level.rawValue != target.level { panel.level = NSWindow.Level(rawValue: target.level) }
            lastDock = target.rect
        } else if lastDock == nil {
            // The widget isn't on the desktop: stand alone where the floating window would be.
            panel.setFrame(Self.savedFrame(), display: true)
            container?.layer?.cornerRadius = 14
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Finds our widget among the desktop widget windows (owned by Notification Center) and returns
    /// where its video preview is on screen.
    private func findDockTarget() -> (rect: NSRect, cornerRadius: CGFloat, level: Int)? {
        let geometries = DockStore.load()
        guard !geometries.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        var best: (rect: NSRect, cornerRadius: CGFloat, level: Int, score: Double)?
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, isNotificationCenter(pid),
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            // Window titles are only visible with Screen Recording permission; use them if we can.
            let name = w[kCGWindowName as String] as? String ?? ""
            if !name.isEmpty && name != "Now Playing" { continue }
            for (_, g) in geometries {
                // Widget windows have a few points of padding around the widget for its shadow.
                let padX = (bounds.width - g.widgetWidth) / 2
                let padY = (bounds.height - g.widgetHeight) / 2
                guard padX >= -1, padX <= 40, abs(padX - padY) < 2 else { continue }
                let top = bounds.minY + padY + g.y
                let rect = NSRect(x: bounds.minX + padX + g.x, y: primaryHeight - top - g.height,
                                  width: g.width, height: g.height).integral
                var score = -g.width                          // prefer the biggest of our widgets
                if name == "Now Playing" { score -= 100_000 }
                if let last = lastDock { score += hypot(rect.midX - last.midX, rect.midY - last.midY) * 4 }
                if best == nil || score < best!.score {
                    best = (rect, CGFloat(g.cornerRadius), layer + 1, score)
                }
            }
        }
        return best.map { ($0.rect, $0.cornerRadius, $0.level) }
    }

    private func isNotificationCenter(_ pid: pid_t) -> Bool {
        if let known = notificationCenterPIDs[pid] { return known }
        let result = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui"
        notificationCenterPIDs[pid] = result
        return result
    }

    @objc private func saveFrame() {
        guard let panel, pinned else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    private static func savedFrame() -> NSRect {
        if let s = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(s)
            if r.width >= 200, NSScreen.screens.contains(where: { $0.frame.intersects(r) }) { return r }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 384, height: 216)
        return NSRect(x: visible.minX + 40, y: visible.maxY - size.height - 300,
                      width: size.width, height: size.height)
    }

    // MARK: Loading

    private func load() {
        guard let id = videoID, let web = webView else { return }
        let start = Int(startTime)
        let urlString: String
        switch mode {
        case .embed:
            urlString = "https://www.youtube.com/embed/\(id)?autoplay=1&start=\(start)&playsinline=1&rel=0"
        case .watchPage:
            urlString = "https://www.youtube.com/watch?v=\(id)&t=\(start)s"
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        // YouTube only plays embeds that come with a website referrer (error 152/153 otherwise,
        // including when the referrer is youtube.com itself). example.com is reserved for this.
        request.setValue("https://example.com/", forHTTPHeaderField: "Referer")
        web.load(request)
    }

    fileprivate func handle(message: Any) {
        guard let dict = message as? [String: Any], let type = dict["type"] as? String else { return }
        diagLog("player  \(type) \(dict["code"] ?? dict["state"] ?? "") mode=\(mode)")
        if type == "error", mode == .embed {
            // The uploader disabled playback on other sites: use the full watch page instead.
            NSLog("VideoPlayer: embed refused; falling back to the watch page")
            if let t = status?.time { startTime = t }
            mode = .watchPage
            autoplayUntil = Date().addingTimeInterval(15)
            load()
        } else if type == "state" {
            poll()
        }
    }

    // MARK: Status

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard isOpen, let web = webView else { return }
        web.evaluateJavaScript("window.mwState ? mwState() : null") { [weak self] result, _ in
            guard let self, let json = result as? String, let data = json.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let state = (d["s"] as? NSNumber)?.intValue ?? -1
            let new = Status(title: d["title"] as? String ?? "",
                             author: d["author"] as? String ?? "",
                             time: (d["t"] as? NSNumber)?.doubleValue ?? 0,
                             duration: (d["d"] as? NSNumber)?.doubleValue ?? 0,
                             playing: state == 1 || state == 3,
                             isAd: (d["ad"] as? Bool) ?? false,
                             at: Date())
            if let id = d["id"] as? String, !id.isEmpty { self.videoID = id }
            if let until = self.autoplayUntil {
                if new.playing || Date() > until {
                    self.autoplayUntil = nil
                } else {
                    self.webView?.evaluateJavaScript("window.mwCmd && mwCmd('play')")
                }
            }
            let changed = self.status?.playing != new.playing || self.status?.title != new.title
                || self.status?.isAd != new.isAd || abs((self.status?.duration ?? 0) - new.duration) > 1
            self.status = new
            if changed { self.onChange?() }
        }
    }

    // MARK: Page scripts

    /// Injected into the YouTube page (embed, or the watch page as a fallback): reports status and
    /// takes commands. On the watch page it also hides everything except the video.
    private static let pageScript = """
    (function(){
      var path=location.pathname, onEmbed=path.indexOf('/embed/')==0, onWatch=path=='/watch';
      if(location.hostname.indexOf('youtube.com')<0||(!onEmbed&&!onWatch))return;
      function post(m){try{window.webkit.messageHandlers.mw.postMessage(m);}catch(e){}}
      if(onWatch){
        var css=document.createElement('style');
        css.textContent='html,body{overflow:hidden!important;background:#000!important}'+
          'video.html5-main-video{position:fixed!important;left:0!important;top:0!important;width:100vw!important;'+
          'height:100vh!important;z-index:2147483647!important;background:#000!important;object-fit:contain!important}';
        document.documentElement.appendChild(css);
      }
      function vid(){return document.querySelector('video.html5-main-video')||document.querySelector('video');}
      var reported=false;
      setInterval(function(){
        if(reported||!onEmbed)return;
        var e=document.querySelector('.ytp-error');
        if(e&&e.offsetParent!==null){reported=true;post({type:'error',code:(e.innerText||'').slice(0,60)});}
      },1000);
      window.mwState=function(){var v=vid();if(!v)return null;
        var t=document.title.replace(/^\\(\\d+\\)\\s*/,'').replace(/ - YouTube$/,'');
        var a=document.querySelector('.ytp-title-channel-name, ytd-watch-metadata ytd-channel-name a, #owner ytd-channel-name a');
        var id=onEmbed?path.split('/')[2]:(new URLSearchParams(location.search).get('v')||'');
        var p=document.querySelector('#movie_player, .html5-video-player');
        return JSON.stringify({t:v.currentTime,d:isFinite(v.duration)?v.duration:0,s:v.paused?2:1,title:t,
          author:a?a.textContent.trim():'',id:id,ad:!!(p&&p.classList.contains('ad-showing'))});};
      window.mwCmd=function(c){var v=vid();if(!v)return;
        if(c=='toggle'){if(v.paused){v.play();}else{v.pause();}}else if(c=='play'){v.play();}
        else if(c=='pause'){v.pause();}else if(c=='restart'){v.currentTime=0;}
        else if(c=='next'){var b=document.querySelector('.ytp-next-button');if(b)b.click();}};
    })();
    """
}

extension VideoPlayerController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Links clicked inside the player (title, channel, "watch on YouTube") open in the browser.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Avoids a retain cycle between the web view's content controller and the player.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: VideoPlayerController?
    init(owner: VideoPlayerController) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handle(message: message.body)
    }
}

final class VideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Top strip that appears on hover: drag to move, pin to keep on top, close.
final class HoverBar: NSView {
    var onClose: (() -> Void)?
    var onPin: (() -> Void)?
    private let closeButton = NSButton()
    private let pinButton = NSButton()
    private let gradient = CAGradientLayer()

    init(pinned: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = [NSColor.black.withAlphaComponent(0.65).cgColor, NSColor.clear.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
        for (button, action) in [(closeButton, #selector(closeTapped)), (pinButton, #selector(pinTapped))] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.contentTintColor = .white
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close video")
        closeButton.toolTip = "Close the video player"
        setPinned(pinned)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = 0
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPinned(_ pinned: Bool) {
        pinButton.image = NSImage(systemSymbolName: pinned ? "pip.enter" : "pip.exit",
                                  accessibilityDescription: pinned ? "Back into the widget" : "Pop out on top")
        pinButton.toolTip = pinned ? "Put the video back in the widget" : "Pop out into a window that stays on top"
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0 }

    @objc private func closeTapped() { onClose?() }
    @objc private func pinTapped() { onPin?() }
}
