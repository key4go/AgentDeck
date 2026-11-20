# Security and privacy

SWORAX connects to the locally installed Codex executable and its shared App Server. Codex manages its own account, credentials, network connections, sandbox and approval settings.

- SWORAX stores local preferences, project folders, agent profiles, tasks, instructions, linked chat identifiers, completion records and available token totals in macOS preferences. Completed outputs may also be saved locally.
- To show per-task token counts, SWORAX may read matching local Codex session records. These files can contain conversation data; the app extracts the matching usage totals for display.
- Delegation requests are sent to the selected main chat and are visible there. The main chat decides how to carry out the request. For a chat owned by another process, SWORAX uses an experimental queue; acceptance does not guarantee completion.
- Removing an agent unlinks its local profile; it does not delete the original Codex chat or its session history.

The app is signed locally with an ad-hoc signature. Report security issues privately with a minimal reproduction using non-sensitive data.
