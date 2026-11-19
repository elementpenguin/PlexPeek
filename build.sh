#!/bin/zsh
# Builds Plex Peek.app into ./build
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
APP="build/Plex Peek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PlexPeek" "$APP/Contents/MacOS/PlexPeek"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with your Apple Development certificate when available, so the app keeps
# the same identity across builds (otherwise Keychain asks again after every build).
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
