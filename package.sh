#!/bin/zsh
# Builds Music Widget and wraps it in a macOS installer: dist/MusicWidget-<version>.pkg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
./build.sh --no-install
rm -rf dist/tmp && mkdir -p dist/tmp/stage
# Copy without extended attributes (com.apple.provenance can't be removed in place) so the
# payload has no ._ metadata files. The ad-hoc signature does not depend on xattrs.
ditto --noextattr --noqtn "build/Build/Products/Release/MusicWidget.app" dist/tmp/stage/MusicWidget.app
APP="dist/tmp/stage/MusicWidget.app"

pkgbuild --component "$APP" \
  --install-location /Applications \
  --scripts pkg/scripts \
  --identifier com.harish.musicwidget \
  --version "$VERSION" \
  dist/tmp/MusicWidget-component.pkg

sed "s/VERSION/$VERSION/" pkg/distribution.xml > dist/tmp/distribution.xml
productbuild --distribution dist/tmp/distribution.xml \
  --resources pkg/resources \
  --package-path dist/tmp \
  "dist/MusicWidget-$VERSION.pkg"
rm -rf dist/tmp
echo "Installer: dist/MusicWidget-$VERSION.pkg"
