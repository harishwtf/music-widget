#!/bin/zsh
# Builds Music Widget, installs it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
rm -rf build/Build/Products/Release/MusicWidget.app
xcodebuild -project MusicWidget.xcodeproj -scheme MusicWidget -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build 2>&1 \
  | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" || true

APP="build/Build/Products/Release/MusicWidget.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

# Apply entitlements with ad-hoc signatures (Xcode wants a provisioning profile for App Groups otherwise).
codesign --force --sign - --entitlements Widget/MusicWidgetExtension.entitlements \
  "$APP/Contents/PlugIns/MusicWidgetExtension.appex"
codesign --force --sign - "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign - --entitlements App/MusicWidget.entitlements "$APP"

# `./build.sh --no-install` stops here (used by package.sh).
[ "${1:-}" = "--no-install" ] && { echo "Built $APP"; exit 0; }

pkill -x MusicWidget 2>/dev/null || true
sleep 0.5
rm -rf /Applications/MusicWidget.app
ditto "$APP" /Applications/MusicWidget.app
open /Applications/MusicWidget.app
# WidgetKit keeps the old widget process alive; kill it so the desktop picks up the new build.
sleep 1; pkill -f MusicWidgetExtension 2>/dev/null || true
echo "Installed and launched /Applications/MusicWidget.app"
