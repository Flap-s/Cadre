#!/bin/zsh
# Packs build.noindex/Cadre.app into build.noindex/Cadre.dmg: a window with Cadre, an arrow and the
# Applications folder to drag it onto. Run Scripts/build-app.sh first.
# Uses only macOS tools: hdiutil builds the image and Finder (via AppleScript) lays out the window,
# so the first run asks to allow controlling Finder.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
BUILD="$ROOT/build.noindex"
APP="$BUILD/Cadre.app"
WORK="$BUILD/dmg"
VOLUME="Cadre"
[[ -d "$APP" ]] || { echo "Build the app first: Scripts/build-app.sh"; exit 1; }
[[ ! -e "/Volumes/$VOLUME" ]] || { echo "Eject the disk named $VOLUME first."; exit 1; }

rm -rf "$WORK" && mkdir -p "$WORK/stage/.background"
swift "$ROOT/Scripts/make-dmg-background.swift" "$WORK/background.png" 1
swift "$ROOT/Scripts/make-dmg-background.swift" "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/stage/.background/background.tiff" >/dev/null
ditto "$APP" "$WORK/stage/Cadre.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/stage/.VolumeIcon.icns"

hdiutil create -quiet -srcfolder "$WORK/stage" -volname "$VOLUME" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF}')
trap '[[ -n "${MOUNT:-}" && -d "$MOUNT" ]] && hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true' EXIT

# Custom volume icon (SetFile ships with the Xcode command line tools).
xcrun SetFile -a C "$MOUNT" 2>/dev/null || true

# Window layout. Positions match Scripts/make-dmg-background.swift: 660×420 of content, plus the
# 28 pt title bar that Finder's bounds include.
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 140, 860, 588}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to false
    set background picture of viewOptions to (POSIX file "$MOUNT/.background/background.tiff" as alias)
    set position of item "Cadre.app" of container window to {180, 215}
    set position of item "Applications" of container window to {480, 215}
    set extension hidden of item "Cadre.app" to true
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Let Finder finish writing .DS_Store before detaching.
for _ in {1..20}; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
sync
hdiutil detach -quiet "$MOUNT"
MOUNT=""

rm -f "$BUILD/Cadre.dmg"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$BUILD/Cadre.dmg"
rm -f "$WORK/rw.dmg"
echo "Built $BUILD/Cadre.dmg"
