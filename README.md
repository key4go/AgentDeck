# AgentDeck

<img src="assets/agentdeck-icon.png" alt="AgentDeck icon" width="128">

AgentDeck is a compact 540 × 400 native macOS whiteboard for subagents in existing Codex main chats. AgentDeck is still under very heavy development.

## Open AgentDeck

AgentDeck targets macOS 14 and later. It connects automatically through the installed Codex CLI to the shared local App Server daemon. Open Codex before connecting. CLI 0.162.0 is the verified version.

1. Choose an existing main chat in the top menu. AgentDeck connects through the shared server; chats owned by another process use the experimental queue.
2. Drag a role onto its whiteboard, assign a task, and choose the requested subagent model and reasoning.
3. Click **Delegate task**. AgentDeck sends a request to the selected parent, which decides whether to start or route work to a subagent. The request appears in the main chat.
4. Codex performs native orchestration. A card gets a runtime identity when a matching reported child appears. Until then, it shows that delegation is requested or unconfirmed.
5. Use **Existing** to add an already-reported subagent from the selected main chat. Subsequent task requests go through the parent to the known child.
6. Select a card for its last completed result, actual runtime model where reported, and per-child total/input/output/cached tokens. A dash indicates unavailable usage. Interrupt appears when the child's actual active turn is known and controllable.

Boards and configurations are saved per main chat. Task submission does not create an independent main chat. Model and reasoning selections are requests for future delegated work. The parent controls actual spawning and routing.

The status indicator opens connection details, errors and approvals. Closing AgentDeck's proxy connection leaves the shared Codex daemon running.

## Build and check

Double-click `AgentDeck.app` or use `bash Tools/open-agentdeck.sh` from the checkout to rebuild and open it. Run the `AgentDeck` scheme in Xcode 16 or later. To run local checks and package:

```sh
bash Tools/check-foundation.sh
bash Tools/check-integration.sh
bash Tools/package-release.sh
```

Set `SDKROOT` to an installed compatible SDK if the selected SDK is newer than your Swift compiler. The package script writes a versioned local ZIP and SHA-256 checksum to `.build`.

[Security and privacy](docs/SECURITY.md) · [Release notes](docs/RELEASE.md)
