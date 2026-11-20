#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash Tools/build-app.sh
app=".build/SWORAX.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
archive=".build/SWORAX-${version}-macos-$(uname -m).zip"
codesign --verify --strict "$app"
ditto -c -k --norsrc --keepParent "$app" "$archive"
(
    cd .build
    shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
)
echo "$PWD/$archive"
