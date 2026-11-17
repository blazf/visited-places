#!/bin/zsh
# Builds a release VisitedPlaces.app into ./build (ad-hoc signed, runs locally).
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/VisitedPlaces"
APP="$ROOT/build/VisitedPlaces.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VisitedPlaces"
cp Resources/airports.tsv "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Visited Places</string>
  <key>CFBundleDisplayName</key><string>Visited Places</string>
  <key>CFBundleIdentifier</key><string>local.visitedplaces.app</string>
  <key>CFBundleExecutable</key><string>VisitedPlaces</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.travel</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad-hoc signatures change with every build, so the Keychain would treat each rebuild as a
# new app and ask for the password again. Pinning the designated requirement to the bundle
# id keeps "Always Allow" working across rebuilds.
codesign --force --sign - -r='designated => identifier "local.visitedplaces.app"' "$APP"
echo "Built $APP"
