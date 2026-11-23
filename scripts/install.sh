#!/bin/sh
# Builds Agent Dots.app into ~/Applications, links the CLI, and (re)starts it at login.
set -e
cd "$(dirname "$0")/.."
swift build -c release

APP="$HOME/Applications/Agent Dots.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HOME/.local/bin"
cp .build/release/AgentDots "$APP/Contents/MacOS/agent-dots"
cp assets/sounds/*.wav "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.bicrick.agent-dots</string>
<key>CFBundleName</key><string>Agent Dots</string>
<key>CFBundleExecutable</key><string>agent-dots</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
codesign --force -s - "$APP" >/dev/null 2>&1 || true
ln -sfn "$APP/Contents/MacOS/agent-dots" "$HOME/.local/bin/agent-dots"

PLIST="$HOME/Library/LaunchAgents/dev.bicrick.agent-dots.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.bicrick.agent-dots</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/agent-dots</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardErrorPath</key><string>/tmp/agent-dots.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/dev.bicrick.agent-dots" 2>/dev/null || true
sleep 0.5
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Agent Dots installed and running."
