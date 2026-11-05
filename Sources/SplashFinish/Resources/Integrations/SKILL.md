---
name: splash-finish
description: Notify the user in the native Splash Finish macOS inbox when an AI task finishes or needs their attention. Use for explicit notification requests and questions that lifecycle hooks cannot detect.
---

<!-- Managed by Splash Finish. Reinstall to update; uninstall-skills removes this file. -->

# Splash Finish

The native app collects results and requests for attention in one window. Normal completions and supported approval prompts are reported automatically by the installed hooks/extension. Do not duplicate automatic completion notifications.

For an explicit notification request, or a question not captured by hooks, run:

```sh
__COMMAND__ notify --agent 'AGENT_NAME' --task 'STABLE_SESSION_ID' --status attention --title 'Short question' --detail 'What you need from the user'
```

Use `done` instead of `attention` for a final result. When work resumes, send `--status running` with the same agent/task identity to remove the outdated entry. Prefer the agent's session ID; for pi use `PI_SESSION_ID` when available. Use the same ID for all updates to a task, not a new random ID for every event.

- Keep titles short and factual. Do not claim success when a task failed or was interrupted.
- Never include secrets, credentials, full prompts or transcripts. The notification is visible on the user's desktop and its short text is stored locally.
- `--source-url` is optional: only provide a real session link supported by the originating app. Do not invent a URL. Without one Splash Finish attempts to activate the source application, not a particular tab.
- Do not change approval policies or bypass agent trust mechanisms.
- Notification delivery is best-effort; a failure must not interrupt the actual task.
