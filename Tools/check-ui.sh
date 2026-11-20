#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
source Tools/select-sdk.sh
xcrun swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$PWD/.build/module-cache" \
    AgentDeck/Domain/*.swift AgentDeck/Integration/*.swift AgentDeck/Services/*.swift \
    AgentDeck/UI/DeckWindow.swift AgentDeck/UI/WorkflowCanvas.swift AgentDeckTests/UIRenderCheck.swift \
    -o .build/ui-render-check
.build/ui-render-check
