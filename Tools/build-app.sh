#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/.build/AgentDeck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp AgentDeck/Info.plist "$app/Contents/Info.plist"
cp LICENSE AgentDeck/AgentDeck.icns AgentDeck/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
mkdir -p .build/module-cache
source Tools/select-sdk.sh
xcrun swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$PWD/.build/module-cache" -target "$(uname -m)-apple-macos14.0" \
    AgentDeck/Domain/*.swift AgentDeck/Integration/*.swift AgentDeck/Services/*.swift AgentDeck/UI/*.swift \
    -o "$app/Contents/MacOS/AgentDeck"
codesign --force --options runtime --timestamp=none --sign - "$app"
echo "$app"
