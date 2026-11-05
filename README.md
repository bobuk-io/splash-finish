# Splash Finish

A little landing strip for AI agents. **Splash Finish** is a native macOS menu bar app that collects finished work and requests for attention from Claude Code, Codex, and pi in one quiet window. Because one agent interrupting you is a notification; five agents doing it is a committee.

![Splash Finish inbox](screenshots/splash-finish.png)

## 🚀 Install

Requires **macOS 14 or later** on Apple silicon or Intel. No Python packages, Homebrew, Xcode, `sudo`, or notification permissions required. Python **3.10+** is needed for the installer.

Once the repository is public:

```sh
curl -fsSL https://raw.githubusercontent.com/bobuk-io/splash-finish/main/install.py \
  | python3 -
```

While the repository is **private**, authenticate with `gh auth login` and use:

```sh
gh api repos/bobuk-io/splash-finish/contents/install.py \
  -H 'Accept: application/vnd.github.raw+json' | python3 -
```

The installer downloads the latest release, checks its SHA-256 and Developer ID signature, installs `Splash Finish.app` in `~/Applications`, and adds `splash-finish` to the first of `~/.local/bin`, `~/bin`, or `~/.bin` already on `PATH`. Otherwise it uses `~/.local/bin` and prints the line to add to your shell. Run it again to update.

The first release is **Developer ID signed but not notarized**. macOS Gatekeeper may block the downloaded app: use Finder → Control-click the app → Open, or System Settings → Privacy & Security → Open Anyway. Check the signature and checksum before doing so. A signature is not the same as Apple notarization.

Then connect your agents:

```sh
splash-finish install-skills
```

- **Claude Code:** start a new session to load the hooks and skill.
- **Codex:** open `/hooks`, review and trust the new hooks, then restart if needed. Splash Finish does not bypass Codex's hook trust. Hooks must be enabled in your Codex configuration.
- **pi:** use `/reload` in running sessions, or start a new one. Requires pi **1.5.0+** for the `agent_settled` and `ui_prompt_start` events.

Installation of integrations is explicit. The app will not edit agent settings just because you opened it.

## ✨ Use

The three bars in your menu bar are Splash Finish. One floating panel is shared by all agents:

- **Needs attention** appears above **Completed**. A new result expands the same window; a long list scrolls.
- **×** dismisses one notification. **Clear all** clears the list and hides the panel.
- **Snooze** hides the panel for 15 minutes or until a genuinely new event arrives, whichever comes first. The inbox is retained, including across app restarts.
- Click a row to return to its source when possible. A supplied session link is preferred; otherwise Splash Finish activates the originating app. macOS and terminal APIs do not guarantee the original tab or window can be selected.
- Use the menu bar to reopen the inbox, send a test notification, install integrations, or enable **Start at Login**. `Esc` snoozes; `⌘W` clears all when the panel has keyboard focus.

```sh
splash-finish show
splash-finish snooze
splash-finish clear
splash-finish status             # local inbox as JSON
splash-finish --help
```

A manually reported task looks like this:

```sh
splash-finish notify --agent Codex --task auth-refactor \
  --status done --title 'Authentication fixed' --detail 'Ready for review'

splash-finish notify --agent 'Claude Code' --task migration \
  --status attention --title 'Apply the migration?'
```

Keep `--agent` and `--task` stable for the same session: an update replaces its earlier notification instead of adding a duplicate. A new event wakes snooze; an identical repeated event does not. `--status running` removes an outdated notification without waking the panel. `--project` sets a label; otherwise the current directory name is used. A verified originating session URL can be supplied with `--source-url`.

### Deep links

The CLI uses `splash-finish://` URLs; automation can use them too. Percent-encode parameter values:

```sh
open 'splash-finish://event?agent=Codex&task=auth&status=done&title=Authentication%20fixed'
open 'splash-finish://show'
```

`agent`, `task`, and `status` (`done`, `attention`, or `running`) are required. Optional fields: `id` (event replay ID), `title`, `detail`, `project`, `source-pid`, `source-bundle`, and `source-url`. Source URLs accept only `https`, `http`, `vscode`, `vscode-insiders`, `cursor`, `windsurf`, `zed`, `iterm2`, or `codex`. An `id` may be replayed safely; duplicate query parameters are rejected.

Deep links are not authenticated: any local app can send them. They display bounded local text; Splash Finish never runs commands from a link. Open source links only if you trust the sender.

## 🧰 Agent integrations

```sh
splash-finish install-skills                 # all three
splash-finish install-skills --agent pi      # claude | codex | pi
splash-finish uninstall-skills               # remove all Splash Finish integrations
splash-finish uninstall-skills --agent codex
```

| Agent | What is installed | Signals |
|---|---|---|
| Claude Code | user skill and `~/.claude/settings.json` hooks | `Stop`, `StopFailure`, permission and supported input notifications |
| Codex | user skill and `~/.codex/hooks.json` hooks | `Stop` and `PermissionRequest`; `/hooks` trust required |
| pi | user skill and `~/.pi/agent/extensions/splash-finish.ts` | settled, extension UI prompts, common question tools, errors and interruption |

Completions mean **the agent stopped responding**, not that its claims or tests were independently verified. Agent hook APIs and external tools vary by version; not every possible request for input is observable. Background agents, remote containers and hosts that do not expose the local macOS app may need to send events explicitly. Claude Code can emit the sandbox network permission notification after a delay. Other installed hooks may change agent behavior after a `Stop` event; Splash Finish is only an observer and cannot predict subsequent continuation.

The installer preserves unrelated hooks/settings, rejects unmanaged files and symlinked configuration paths, and writes a uniquely named backup before changing an existing JSON config. Reinstall updates only Splash Finish entries. Config locations honor `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `PI_CODING_AGENT_DIR`. Removal does not delete the app, unrelated hooks, or configuration backups. Existing pi sessions need `/reload` after either operation.

## 🔒 Local by default

- No server, accounts, analytics, or external network requests during ordinary operation. The **installer** contacts GitHub.
- The inbox is stored in `~/Library/Application Support/Splash Finish/state.json` with private file permissions. Event titles may contain short excerpts from the agent's final response; don't put secrets in them. Source URLs may also be persisted.
- Hooks receive agent-supplied JSON locally, but the app stores only the short fields displayed in the inbox, not whole transcripts or tool inputs.
- Event payloads are bounded; malformed links and unsafe source URL schemes are rejected. Hook failures do not block the agent or approve permissions.
- Opening an external source link is a user-initiated action. App activation is best-effort, not proof of the correct terminal tab.
- This is a menu bar agent, not a background daemon. It runs after you open it (or enable Start at Login); a deep link or the CLI can also launch it.

## 🧹 Uninstall

```sh
splash-finish uninstall-skills
```

Quit Splash Finish from its menu. Remove `~/Applications/Splash Finish.app` and the `splash-finish` symlink from your local bin directory. If you also want to erase the inbox, remove `~/Library/Application Support/Splash Finish`. Existing hook backups are left beside the agent config files for you to inspect or remove.

## 🛠️ Development

```sh
swift test
python3 -m unittest discover -s Tests -v
node Tests/pi-extension.test.mjs       # Node 22.18+ for TypeScript stripping
Scripts/compile_and_run.sh --test      # ad-hoc local build
# With an active macOS desktop and no existing Splash Finish process:
SPLASH_FINISH_GUI_TESTS=1 python3 -m unittest discover -s Tests -p test_app_smoke.py -v
```

`Package.swift` builds a SwiftUI/AppKit app and a separate testable core. `Scripts/package_app.sh` assembles the `.app`; no Xcode project or third-party Swift packages are required. `install.py` is a standalone standard-library installer. Tests use temporary directories and do not alter your agent configs.

Create a **universal** release with an available Developer ID identity:

```sh
APP_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' Scripts/release.sh
```

This produces `build/Splash Finish.app`, `dist/SplashFinish-0.1.0-universal.zip`, and `dist/SHA256SUMS`. The signing identity used by the installer is pinned to the project's Developer ID team; update `TEAM_ID` in `install.py` if the project changes hands. A build without notarization will not pass Gatekeeper on a downloaded file. For a distributable notarized build, configure a `notarytool` keychain profile and run:

```sh
APP_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
  Scripts/release.sh --notarize YOUR_NOTARY_PROFILE
```

The script waits for Apple's response, staples the ticket, checks Gatekeeper, and regenerates the ZIP and checksum. It never creates a GitHub release on its own.

---

Your agents can go back to work now. You can, too. ☕
