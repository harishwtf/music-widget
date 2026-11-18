# Music Widget

A macOS desktop / Notification Center widget with play, pause, skip and volume controls for
**Spotify**, **Apple Music** and **YouTube** (playing in Chrome, Safari, Arc, Brave, Edge…).

It has two parts:

- **MusicWidget.app** – a tiny menu-bar helper. Widgets are sandboxed and can't talk to other
  apps, so this helper watches the players, writes the now-playing state to a shared container,
  and carries out the commands the widget sends. It starts at login.
- **Now Playing widget** – the WidgetKit widget (small, medium, large) you add to the desktop.

## Build & install

```bash
./build.sh
```

That generates the Xcode project with XcodeGen, builds Release, ad-hoc signs both bundles with
their entitlements, copies the app to `/Applications` and launches it.
Requirements: Xcode, `brew install xcodegen`.

## Installer (.pkg)

```bash
./package.sh
```

Produces `dist/MusicWidget-<version>.pkg`, which installs the app into /Applications and launches it.
It is not signed with a Developer ID (none on this Mac), so on another Mac the first open is blocked:
right-click the .pkg ▸ Open, or allow it under System Settings ▸ Privacy & Security ▸ "Open Anyway".
From Terminal it installs without that dance: `sudo installer -pkg MusicWidget-1.0.0.pkg -target /`.
Apple Silicon only (the bundled media adapter is arm64).

## First run

1. macOS asks "MusicWidget wants access to control Spotify / Music / Google Chrome" – click **Allow**.
   (If you clicked Don't Allow: System Settings ▸ Privacy & Security ▸ Automation ▸ MusicWidget.)
2. Right-click the desktop ▸ **Edit Widgets** ▸ search "Music Widget" ▸ drag **Now Playing** out.

## How YouTube works

- **What's open:** the helper reads the YouTube tabs in Chrome and Safari, so the tile knows the
  video even when it's paused.
- **Playing it:** while the browser is the app macOS shows as "Now Playing", play/pause/skip go
  through the system media controls (the bundled
  [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), BSD-3). No setup needed.
- **When another app took over** (say you started Spotify), the helper has to script the tab
  directly. That needs a one-time browser setting: Chrome **View ▸ Developer ▸ Allow JavaScript
  from Apple Events** (Safari: **Develop ▸ Allow JavaScript from Apple Events**). Until then the
  widget shows a reminder and pressing play brings the YouTube tab to the front.
- **Tab closed:** the widget keeps the last video; press play to reopen it where you left off.
- **Preview:** the widget shows a 16:9 preview. That's YouTube's thumbnail, or, with the browser
  setting above, the actual frame the video is on (captured when you play, pause or switch videos).

## Video in the widget

macOS widgets can only draw still images, so the helper plays the video in its own borderless
window laid exactly over the widget's 16:9 preview, one layer above the widget. It looks and
behaves like video playing inside the widget:

- **Start it:** the ▶︎ (play.rectangle) button at the right of the widget's controls, or the menu
  bar item. The browser copy is paused and the video continues from the same point.
- **It follows the widget:** the widget records where its preview is drawn (`dock.json` in the
  shared folder); the helper finds the widget's window (owned by Notification Center) and keeps
  the video on it, checking twice a second, so moving the widget moves the video.
- **Switching to Spotify or Music** in the widget hides and pauses the video; switching back
  shows it again.
- **Hover the video's top edge** for close, and for a button that pops it out into a free window
  that stays on top of everything (and puts it back).
- When the widget isn't on screen (a full-screen app, or widgets hidden) the video waits in a
  standalone window until the desktop is back.

The player loads YouTube's embed page with `example.com` as the referrer; YouTube refuses embeds
without a website referrer (error 152/153). Videos whose owners disabled embedding fall back to
the full watch page with only the video shown.

## Keeping the widget fresh

macOS gives each widget a daily refresh budget; once it's spent, refresh requests are ignored
until it refills. So:

- Button taps don't use it: the widget waits (up to ~2.5 s) for the helper to report the result,
  and macOS redraws a widget after a tap for free.
- The helper only asks for a refresh when something the widget shows changes (song, play state,
  cover, which player), batches a song change with its cover, and skips requests for a state the
  widget has already drawn.
- `~/Library/Application Support/MusicWidget/diag.log` records each request and each redraw.

## Installer (.pkg)

```bash
./package.sh
```

Produces `dist/MusicWidget-<version>.pkg`, which installs the app into /Applications and launches it.
It is not signed with a Developer ID (none on this Mac), so on another Mac the first open is blocked:
right-click the .pkg ▸ Open, or allow it under System Settings ▸ Privacy & Security ▸ "Open Anyway".
From Terminal it installs without that dance: `sudo installer -pkg MusicWidget-1.0.0.pkg -target /`.
Apple Silicon only (the bundled media adapter is arm64).

## First run

1. macOS asks "MusicWidget wants access to control Spotify / Music / Google Chrome" – click **Allow**.
   (If you clicked Don't Allow: System Settings ▸ Privacy & Security ▸ Automation ▸ MusicWidget.)
2. Right-click the desktop ▸ **Edit Widgets** ▸ search "Music Widget" ▸ drag **Now Playing** out.

## How YouTube works

YouTube in a browser is read through the system's own Now Playing info (the same data Control
Center shows) using the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
(BSD-3). Play/pause/next go the same way when the browser is the current Now Playing app.
That covers the normal case: you are watching YouTube and it is the thing playing.
If another app (say Spotify) is the current Now Playing app and you press play on the YouTube
tile, the helper instead scripts the YouTube tab directly. In Chrome that needs a one-time setting:
**View ▸ Developer ▸ Allow JavaScript from Apple Events** (Safari: Develop ▸ Allow JavaScript from
Apple Events). Until it is on, the large widget and the menu bar show a reminder.

## Notes

- When another window is active, macOS draws desktop widgets in a tinted "vibrant" style: artwork
  becomes a monochrome silhouette and the pills go neutral. Click the desktop and it's full colour.
- Quit the helper from its menu bar icon; the widget then shows a "Start it" button.

## Layout

- `App/` – helper app: `PlayerMonitor` (polls + picks the active player), `Players` (Spotify /
  Music AppleScript, YouTube), `MediaRemoteBridge` (adapter stream), `PreviewRenderer`.
- `Widget/` – the WidgetKit extension.
- `Shared/` – model, shared store (`~/Library/Application Support/MusicWidget`, reachable from the
  sandboxed widget through a file exception entitlement, since App Groups need a paid Team ID), widget views, intents.
- `Vendor/mediaremote-adapter/` – the adapter script + framework.

Debug: `MusicWidget --render-previews <dir> [--sample]` renders the three sizes to PNG.
