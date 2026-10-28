#!/bin/zsh
# Builds Cadre.app into ./build. Set CODESIGN_IDENTITY to sign with your Developer ID;
# otherwise the app is signed ad hoc with a requirement pinned to its bundle identifier.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/Cadre.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
# GitHub "owner/repo" the app checks for updates: UPDATE_REPOSITORY, else the git remote.
if [[ -z "${UPDATE_REPOSITORY:-}" ]]; then
  REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  UPDATE_REPOSITORY="$(sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<< "$REMOTE")"
  [[ "$UPDATE_REPOSITORY" == */* && "$REMOTE" == *github.com* ]] || UPDATE_REPOSITORY=""
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Cadre"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cadre"

# Icon
ICON_WORK="$ROOT/build/icon"
rm -rf "$ICON_WORK" && mkdir -p "$ICON_WORK/Cadre.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ICON_WORK/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_WORK/icon.png" --out "$ICON_WORK/Cadre.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON_WORK/icon.png" --out "$ICON_WORK/Cadre.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/Cadre.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cadre</string>
  <key>CFBundleDisplayName</key><string>Cadre</string>
  <key>CFBundleIdentifier</key><string>app.cadre.Cadre</string>
  <key>CFBundleExecutable</key><string>Cadre</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CadreUpdateRepository</key><string>$UPDATE_REPOSITORY</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Cadre records your microphone only during screen recordings, when you enable it.</string>
  <key>NSCameraUsageDescription</key><string>Cadre shows your webcam only during screen recordings, when you enable it.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>app.cadre.Cadre</string>
      <key>CFBundleURLSchemes</key><array><string>cadre</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

xattr -cr "$APP"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
else
  # An ad-hoc signature's default requirement is the binary's hash, so macOS would forget the
  # Screen Recording permission after every rebuild. Pin the requirement to the bundle identifier.
  codesign --force --deep --sign - --requirements '=designated => identifier "app.cadre.Cadre"' "$APP"
fi
echo "Built $APP (version $VERSION${UPDATE_REPOSITORY:+, updates from $UPDATE_REPOSITORY})"
