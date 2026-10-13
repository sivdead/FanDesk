#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift build -c release
swift run -c release --skip-build CoreChecks
bash scripts/model-checks.sh
bin="$(swift build -c release --show-bin-path)"
app="$PWD/build/FanDesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchServices" "$app/Contents/Library/LaunchDaemons"
cp "$bin/FanDesk" "$app/Contents/MacOS/FanDesk"
cp "$bin/FanDeskHelper" "$app/Contents/Library/LaunchServices/FanDeskHelper"
cp ThirdParty/* "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FanDesk</string>
<key>CFBundleIdentifier</key><string>local.jingwen.FanDesk</string>
<key>CFBundleName</key><string>FanDesk</string>
<key>CFBundleDisplayName</key><string>FanDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>FanDeskOwnerUID</key><integer>$(id -u)</integer>
</dict></plist>
EOF
cat > "$app/Contents/Library/LaunchDaemons/local.jingwen.FanDesk.helper.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.jingwen.FanDesk.helper</string>
<key>BundleProgram</key><string>Contents/Library/LaunchServices/FanDeskHelper</string>
<key>MachServices</key><dict><key>local.jingwen.FanDesk.helper</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
plutil -lint "$app/Contents/Info.plist" "$app/Contents/Library/LaunchDaemons/local.jingwen.FanDesk.helper.plist"
codesign --force --sign - --identifier local.jingwen.FanDesk.helper "$app/Contents/Library/LaunchServices/FanDeskHelper"
codesign --force --sign - --identifier local.jingwen.FanDesk "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"
