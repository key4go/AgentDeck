# Local builds and releases

From the repository, run `bash Tools/open-agentdeck.sh` to rebuild and open AgentDeck. Or run `bash Tools/package-release.sh` to build without opening it. The build requires the installed macOS Command Line Tools; it makes no downloads. It chooses a compatible SDK automatically, or accepts an explicit `SDKROOT` path.

The app is at `.build/AgentDeck.app`: open it in Finder or double-click it. The release script also creates a versioned, host-architecture ZIP and a matching SHA-256 file in `.build`. To check the archive, run `cd .build && shasum -a 256 -c AgentDeck-*.zip.sha256`.

The app targets macOS 14 or later and is signed locally with a hardened-runtime ad-hoc signature. It is not Developer ID signed or notarized, so macOS may require the user to approve opening it in Privacy & Security when copied to another Mac. Developer ID signing and notarization are separate distribution steps; see [Apple's distribution guidance](https://developer.apple.com/developer-id/).
