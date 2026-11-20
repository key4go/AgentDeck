#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/module-cache
source Tools/select-sdk.sh
xcrun swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$PWD/.build/module-cache" \
    AgentDeck/Domain/*.swift AgentDeck/Integration/*.swift AgentDeck/Services/*.swift AgentDeckTests/FoundationCheck.swift \
    -o .build/foundation-check
.build/foundation-check
