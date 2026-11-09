#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/swift-local.sh build -c release --build-system native --product BackupGenius
bin="$(Scripts/swift-local.sh build -c release --build-system native --show-bin-path)"
work="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/Backup Genius.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp "$bin/BackupGenius" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
swift -module-cache-path "$PWD/.build/cache/clang" Scripts/MakeIcon.swift "$app/Contents/Resources/BackupGenius.icns"
codesign --force --sign - --entitlements Resources/BackupGenius.entitlements "$app"
codesign --verify --strict "$app"
rm -rf 'dist/Backup Genius.app'
mv "$app" 'dist/Backup Genius.app'
printf '%s\n' "$PWD/dist/Backup Genius.app"
