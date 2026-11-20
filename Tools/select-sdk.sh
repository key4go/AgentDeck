#!/bin/bash
# Source after changing to the repository root and creating the module cache.
if [[ -n "${SDKROOT:-}" ]]; then
    sdk="$SDKROOT"
else
    # The selected CLT SDK can be newer than the installed Swift compiler.
    # Test imports before using it, then try other installed versioned SDKs.
    default_sdk="$(xcrun --show-sdk-path)"
    major="$(sw_vers -productVersion | cut -d. -f1)"
    sdk_dir="$(dirname "$default_sdk")"
    installed=("$sdk_dir"/MacOSX[0-9]*.sdk)
    candidates=("$default_sdk" "$sdk_dir"/MacOSX"$major".*.sdk)
    for ((i=${#installed[@]}-1; i>=0; i--)); do candidates+=("${installed[i]}"); done
    sdk=""
    for candidate in "${candidates[@]}"; do
        [[ -d "$candidate" ]] || continue
        if printf 'import SwiftUI\n' | xcrun swiftc -swift-version 6 -sdk "$candidate" \
            -module-cache-path "$PWD/.build/module-cache" -target "$(uname -m)-apple-macos14.0" \
            -typecheck - >/dev/null 2>&1; then
            sdk="$candidate"
            break
        fi
    done
    if [[ -z "$sdk" ]]; then
        echo "No compatible macOS SDK found. Set SDKROOT to an installed SDK compatible with Swift." >&2
        exit 1
    fi
fi
