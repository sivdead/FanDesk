#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/build/FanDesk.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
arch=$(lipo -archs "$app/Contents/MacOS/FanDesk")
if [[ "$arch" != "arm64" ]]; then
    echo "Expected an arm64 build, got: $arch" >&2
    exit 1
fi
out="$PWD/build/release"
mkdir -p "$out"
stage=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/FanDesk.app"
ln -s /Applications "$stage/Applications"
cp docs/install.txt "$stage/安装说明.txt"
cp LICENSE "$stage/LICENSE.txt"
asset="FanDesk-$version-macos-arm64.dmg"
hdiutil create -volname "FanDesk $version" -srcfolder "$stage" -ov -format UDZO "$out/$asset"
hdiutil verify "$out/$asset"
(cd "$out" && shasum -a 256 "$asset" > SHA256SUMS.txt)
echo "Packaged: $out/$asset"
