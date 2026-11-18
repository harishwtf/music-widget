import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit

@main
struct MusicWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: delegate.monitor)
        } label: {
            Image(systemName: "music.note.list")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PlayerMonitor()
    private var receiver: CommandReceiver?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count {
            PreviewRenderer.render(to: URL(fileURLWithPath: args[i + 1]), useSample: args.contains("--sample"))
            NSApp.terminate(nil)
            return
        }
        // Quit cleanly on SIGTERM (pkill, logout) so the adapter child process is stopped too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        receiver = CommandReceiver(monitor: monitor)
        monitor.start()
        LoginItem.enableOnFirstLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Login item change failed: \(error)")
        }
    }

    static func enableOnFirstLaunch() {
        let key = "didSetupLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: PlayerMonitor

    var body: some View {
        ForEach(MediaSource.allCases) { source in
            let p = monitor.state.player(source)
            Text("\(source.displayName): \(summary(p))")
        }
        if monitor.state.player(.youtube).detail == SharedStore.chromeHint {
            Text("YouTube tip: \(SharedStore.chromeHint)")
        }
        if monitor.state.player(.youtube).videoID != nil {
            Button(monitor.state.player(.youtube).inVideoPlayer == true ? "Close Video Player" : "Play YouTube Video on Desktop") {
                monitor.handle(source: .youtube, command: .popOut)
            }
        }
        Divider()
        Button("Refresh Now") { monitor.refresh() }
        Toggle("Launch at Login", isOn: Binding(
            get: { LoginItem.isEnabled },
            set: { LoginItem.setEnabled($0) }
        ))
        Button("How to Add the Widget…") { showHelp() }
        Divider()
        Button("Quit Music Widget") { NSApp.terminate(nil) }
    }

    private func summary(_ p: PlayerState) -> String {
        guard p.isAvailable else { return "not open" }
        guard p.hasTrack else { return "nothing playing" }
        let status = p.isPlaying ? "▶︎" : "❚❚"
        return "\(status) \(p.title) – \(p.artist)"
    }

    private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add the Now Playing widget"
        alert.informativeText = """
        1. Right-click your desktop (or click the clock to open Notification Center) and choose Edit Widgets.
        2. Search for "Music Widget" and drag the Now Playing widget out in the size you like.
        3. Keep this app running (it lives in the menu bar and starts at login) so the widget stays live.

        The first time, macOS will ask permission for Music Widget to control Spotify, Music and your browser. Click OK on each.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
