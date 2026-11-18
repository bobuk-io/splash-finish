# Splash Finish

A little landing strip for AI agents. **Splash Finish** is a native macOS menu bar app that collects finished work and requests for attention from Claude Code, Codex, GitHub Copilot CLI, and pi in one quiet window. Because one agent interrupting you is a notification; five agents doing it is a committee.

![Splash Finish inbox](screenshots/splash-finish.png)

## 🚀 Install

Requires **macOS 14 or later** on Apple silicon or Intel. Choose Homebrew or the standalone installer. Both use the same Developer ID signed, notarized universal app. Xcode and notification permissions are not required.

### Homebrew

```sh
brew install --cask bobuk-io/tap/splash-finish
open "/Applications/Splash Finish.app"
```

Homebrew installs the app and the `splash-finish` CLI. If it requests cask trust, run `brew trust --cask bobuk-io/tap/splash-finish` and repeat the install command.

Keep one installation method. To move from the standalone installer, quit Splash Finish, remove only its old app in `~/Applications` and its old CLI symlink, then install with Homebrew. Keep `~/Library/Application Support/Splash Finish` to preserve the inbox. Run `splash-finish install-skills` afterward to refresh paths in agent integrations. Do not use `--force` to overwrite a different copy.

### Standalone installer

Python **3.10+** is required; no Python packages, Homebrew or `sudo` are needed.

```sh
curl -fsSL https://raw.githubusercontent.com/bobuk-io/splash-finish/main/install.py \
  | python3 -
```

The installer downloads the latest release, checks its SHA-256 and Developer ID signature, installs `Splash Finish.app` in `~/Applications`, and adds `splash-finish` to the first of `~/.local/bin`, `~/bin`, or `~/.bin` already on `PATH`. Otherwise it uses `~/.local/bin` and prints the line to add to your shell. Run it again to update.

The release is signed with Developer ID and notarized by Apple.

Then connect your agents:

```sh
splash-finish install-skills
```

- **Claude Code:** start a new session to load the hooks and skill.
- **Codex:** open `/hooks`, review and trust the new hooks, then restart if needed. Splash Finish does not bypass Codex's hook trust. Hooks must be enabled in your Codex configuration.
- **GitHub Copilot CLI:** restart existing sessions to load the skill and hooks. This integration is for the local CLI, not GitHub's cloud coding agent.
- **pi:** use `/reload` in running sessions, or start a new one. Requires pi **1.5.0+** for the `agent_settled` and `ui_prompt_start` events.

Installation of integrations is explicit. The app will not edit agent settings just because you opened it.

## Updates

A copy managed by Homebrew shows **Update Splash Finish via Homebrew…** in the menu. Sparkle is disabled for that copy. The action runs only `brew upgrade --cask --greedy bobuk-io/tap/splash-finish` with the owning Homebrew installation, shows live output and the actual result, and restarts the updated app. The progress window survives replacement of the app. Errors and cancellation are shown; closing the window does not cancel an update.

You can also quit the app, run that command in Terminal, and reopen it. Other casks are not upgraded. Your inbox and agent integrations are retained.

Standalone copies keep **Check for Updates…** and Sparkle updates from `https://bobuk.io/apps/splash-finish/appcast.xml`, with signed archives hosted on GitHub Releases. You can also rerun the standalone installer. Versions through 0.3.12 keep using the GitHub feed, which remains published for migration.

## ✨ Use

The three bars in your menu bar are Splash Finish. One floating panel is shared by all agents:

- **Needs attention** appears above **Completed**. A new result expands the same window; a long list scrolls.
- **×** dismisses one notification. **Clear all** clears the list and hides the panel. Right-click a row to open its source, copy its text, or dismiss it.
- Drag the panel anywhere; it reappears where you left it as long as that screen is still connected.
- **Snooze** hides the panel for 15 minutes or until a genuinely new event arrives, whichever comes first. The menu bar offers 15 minutes, 1 hour, or until tomorrow morning. The inbox is retained, including across app restarts.
- Click a row to return to its source when possible. A supplied session link is preferred; Rex session/block IDs, Orca terminal/workspace coordinates and WezTerm pane IDs are captured when available. In Orca, a click switches to the original project, terminal tab and split pane via its CLI. A successful exact transition (source link, Rex pane, Orca terminal or WezTerm pane), whether by `Return`, the card or its arrow, dismisses that notification; if it was the last one, the panel hides. If exact navigation fails, the card stays and Splash Finish may activate the originating app; it never chooses another Orca project or launches a replacement agent. Other terminals do not guarantee the original tab or window can be selected.
- Notification titles/details support inline Markdown: **bold**, *italic*, ~~strikethrough~~, `code`, and `[links](https://example.com)`. Web links open in the browser without dismissing the notification; other card clicks still return to the agent. Markdown is parsed before preview clipping, so long destinations do not leak into the label. Block layouts (headings, tables, lists) and images are not rendered.
- The inbox keeps at most the 200 most recent notifications; when it overflows, the oldest entries are dropped even if they were asking for attention.
- Use the menu bar to reopen the inbox, snooze, send a test notification, or open **Settings…** (`⌘,`). Settings holds the **Light / Dark** appearance switch, **Start at Login**, **Respect Do Not Disturb**, and buttons to install or uninstall agent skills. The panel stays dark until you choose Light. **Respect Do Not Disturb** hides automatic reveals, including the one at launch, while macOS Focus is on; events still land in the inbox and update the badge, and an explicit `show` always opens it. When the panel appears, it takes keyboard focus: `Esc` snoozes, `Backspace` (or `⌘W`) clears all, `↑` / `↓` select a notification, and `Return` opens its source. A new notification in an already-visible panel does not steal focus back if you switched away.
- `⌥⌘S` opens the inbox from anywhere, even when Splash Finish is not the active app.

```sh
splash-finish show
splash-finish snooze
splash-finish clear
splash-finish status             # short summary of the local inbox
splash-finish status --raw       # full inbox state as JSON
splash-finish doctor             # integration status, repair hints and last event
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

### Returning to Orca

Agents started in a **local Orca terminal** automatically pass their terminal handle, workspace and pane identity to Splash Finish. This works with pi, Claude Code, Codex and manual `splash-finish notify` calls; no per-project setup is needed. Changing the agent's working directory does not change the captured workspace. For rich pi questions, **Answer in pi** also returns to that terminal (reload the updated question adapter first).

Agents running in Orca's **built-in chat** have no terminal of their own; they pass their chat session identity instead. Clicking such a notification opens that exact chat and brings its workspace on screen, so a chat stays reachable even after you moved on to other work. Chats and terminals are ordered attempts: if one is gone, the other is still tried.

Orca is contacted only when you click a notification, not on every agent event. Splash Finish uses the CLI bundled with the installed Orca app, so Finder's `PATH` does not matter, and it opens chats through Orca's own bundled runtime client rather than reimplementing its protocol. If Orca restarted, it re-discovers the same pane using workspace/tab/pane IDs rather than reusing a stale terminal handle. A closed or unresolvable chat or pane produces an unavailable-source message instead of selecting a different agent. Existing notifications created before this support was added cannot recover coordinates retroactively. Remote/paired Orca runtimes are not supported.

New in **0.3.12 (build 18)**: return to the original local Rex pane.

Rex terminals inherit `REX_SESSION` and `REX_BLOCK`. Splash Finish captures both full IDs when the event is sent through manual `notify`, pi, Claude Code or Codex hooks. Rich pi questions also carry these IDs and their “Use pi” action returns to that pane. A click resolves the saved block inside the saved session, then uses these commands (all with `--autostart=false --timeout 3s`):

```sh
rex block inspect -s SESSION BLOCK --json
rex client ls --json
rex focus -s SESSION BLOCK
rex -C CLIENT do session.select session_id=SESSION window_id=WINDOW --json
rex session inspect SESSION --json
```

`SESSION` and `BLOCK` are the original full IDs; `WINDOW` is resolved from that block. Only one connected local macOS app client with a matching Rex process is accepted. The client must be open and **Remote Control** must be enabled by the user. Splash Finish never changes that setting. It requires a successful client action acknowledgement, verified exact server session/tab/pane focus, and successful app activation before dismissing a card. A closed pane, missing CLI, ambiguous clients, refused action or failed confirmation keeps the card and shows a useful error. It does not select a replacement session. The CLI is found in the installed app helper or the standard local Rex server installation, without relying on Finder's `PATH`.

Rex support is local only. SSH and explicitly remote `REX_SERVER` environments are excluded; remote hosts, floating/unplaced panes and older events without Rex coordinates cannot return exactly. A custom local socket is not saved: clicks use Rex's default local server and fail if the original IDs are absent there. Rex currently exposes a synchronous client action acknowledgement and server pane focus, but no independent query for the app's visible session; this is the available confirmation boundary. Live navigation requires a separate manual check, as automated tests do not switch the user's visible session.

### Deep links

The CLI uses `splash-finish://` URLs; automation can use them too. Percent-encode parameter values:

```sh
open 'splash-finish://event?agent=Codex&task=auth&status=done&title=Authentication%20fixed'
open 'splash-finish://show'
```

`agent`, `task`, and `status` (`done`, `attention`, or `running`) are required. Optional fields: `id` (event replay ID), `title`, `detail`, `project`, `source-pid`, `source-bundle`, and `source-url`. Rex coordinates use `rex-session` and `rex-block` (full typed UUIDs; both required). Orca coordinates use `orca-terminal` (runtime handle), `orca-worktree` (workspace identity), `orca-pane` (`tabId:leafId`) and `orca-session` (built-in chat identity); these are captured automatically by the CLI when inherited from Orca. Source URLs accept only `https`, `http`, `vscode`, `vscode-insiders`, `cursor`, `windsurf`, `zed`, `iterm2`, or `codex`. An `id` may be replayed safely; duplicate query parameters are rejected. Optional `run` and `sequence` are non-negative integers and must be provided together. They order updates per agent/task; older generations and non-increasing sequences are ignored, even after dismissing a notification. Once a task sends ordered updates, legacy unordered updates for that same task are ignored while the bounded ordering record remains. Pi supplies these fields; Claude and Codex hooks currently do not expose a reliable common ordering guarantee.

Deep links are not authenticated: any local app can send them. They display bounded local text; Splash Finish never runs commands from a link. Open source links only if you trust the sender.

## 🧰 Agent integrations

```sh
splash-finish install-skills                 # all agents
splash-finish install-skills --agent pi      # claude | codex | copilot | pi
splash-finish uninstall-skills               # remove all Splash Finish integrations
splash-finish uninstall-skills --agent codex
```

| Agent | What is installed | Signals |
|---|---|---|
| Claude Code | user skill and `~/.claude/settings.json` hooks | `Stop`, `StopFailure`, permission and supported input notifications |
| Codex | user skill and `~/.codex/hooks.json` hooks | `Stop` and `PermissionRequest`; `/hooks` trust required |
| GitHub Copilot CLI | user skill and `~/.copilot/hooks/splash-finish.json` | turn end, new prompt, session end, and supported permission/input notifications |
| pi | user skill and `~/.pi/agent/extensions/splash-finish.ts` | settled, extension UI prompts, common question tools, errors and interruption |

Pi notifications are fire-and-forget and never delay the agent. User-opened menus while Pi is idle (such as `/jewter`) do not trigger attention notifications or clear completed items; blocking dialogs during an active agent run still report requests for input. Subagent sessions (pi-subagents background children and in-process `run-N` sessions) are filtered: only requests for input are forwarded, so a fan-out of workers does not flood the inbox.

Copilot reports “Agent turn ended” without reading the answer or transcript. A turn can end while background work is still running; a later turn produces another notification. Only `permission_prompt` and `elicitation_dialog` notifications request attention; background notifications and subagent events are ignored. Tool completions cannot identify which question was resolved, so attention remains until a new prompt, turn end, or session end.

Set `SPLASH_FINISH_DISABLED=1` in managed worker processes (for example pi-selecta workers) to suppress their lifecycle hooks, rich questions and explicit `notify` calls. Leave it unset in the coordinator so only the coordinator asks the human and reports completion. Available in 0.3.8 and later. Pi integrations, installed hook shell guards, and the CLI honor this opt-out. After updating, reinstall integrations with `splash-finish install-skills` and run `/reload` in existing Pi sessions.

In 0.3.11, Codex hook events with an explicitly null or empty transcript path are ignored. This keeps temporary sessions used for tab titles and suggestions out of the inbox. Normal sessions and older hook payloads without a transcript-path field remain supported; JSON answers are not filtered by their text.

Completions mean **the agent stopped responding**, not that its claims or tests were independently verified. Agent hook APIs and external tools vary by version; not every possible request for input is observable. Background agents, remote containers and hosts that do not expose the local macOS app may need to send events explicitly. Claude Code can emit the sandbox network permission notification after a delay. Other installed hooks may change agent behavior after a `Stop` event; Splash Finish is only an observer and cannot predict subsequent continuation.

Open **Integrations…** in the menu bar or run `splash-finish doctor` to inspect installed files, hooks, update availability, and the last recorded event. Codex hook trust is not exposed to the inspector; use `/hooks` to check it. Event timestamps are recorded only by app versions supporting this feature.

The installer preserves unrelated hooks/settings, rejects unmanaged files and symlinked configuration paths, and writes a uniquely named backup before changing an existing shared JSON config, keeping the three newest backups. Reinstall updates only Splash Finish entries, and the app offers a repair when its version or location changed because hooks embed the absolute path of the binary. Config locations honor `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME`, and `PI_CODING_AGENT_DIR`; Copilot skills and hooks both use `COPILOT_HOME` when set. Removal does not delete the app, unrelated hooks, or configuration backups. Restart Copilot CLI or run `/reload` in existing pi sessions after changes.

### Rich pi questions

Install [pi-agent-ask](https://github.com/alexshpunt/pi-agent-ask) separately with `pi install npm:pi-agent-ask`. Do not install it alongside another provider of `ask_user`. Splash Finish checks the globally configured package and recommends installation if it is not detected; project-local and manually loaded packages cannot always be detected.

Run `splash-finish install-skills --agent pi` to install the integration. Rich questions are enabled automatically when pi-agent-ask is detected globally; an already-enabled integration is preserved on reinstall. Use the checkbox in **Integrations…** to enable or disable rich questions explicitly, including for project-local installations; the checkbox applies immediately. Run `/reload` in existing pi sessions after changes. Splash Finish never installs or removes pi-agent-ask itself.

The adapter uses pi-agent-ask's documented versioned lifecycle and submit events, without patching its UI. It supports multiple questions, single/multiple choices, custom answers, question and option notes. Submit waits for pi's acknowledgement; if the terminal answers first, the card closes. **Answer in pi** closes the card without answering it; Snooze preserves it; Clear all keeps pending questions. In the card, `⌘1`…`⌘9` toggle options and `⌘Return` submits; plain digits keep working inside the text fields. If the app is unavailable or a form is unsupported, the original pi interface remains available.

Question text and answers travel over a per-request local Unix socket in a user-private directory, not in the deep link or persisted inbox. Other processes running as your user are not a security boundary. A newer or older pi-agent-ask version may change its event contract; version 2.0.2 is the tested baseline.

## 🔒 Local by default

- No accounts or analytics. Standalone copies check the public update feed on bobuk.io and download signed archives from GitHub; the **installer** contacts GitHub. Homebrew-managed copies use Homebrew when you request an update. These services receive normal network request metadata; inbox contents are not sent.
- The inbox is stored in `~/Library/Application Support/Splash Finish/state.json` with private file permissions. Event titles may contain short excerpts from the agent's final response; don't put secrets in them. Source URLs may also be persisted.
- Hooks receive agent-supplied JSON locally, but the app does not store whole transcripts or tool inputs. Titles and details retain at most 4 KiB of UTF-8 text each for Markdown parsing; the compact panel shows only a preview. `status --raw` includes these retained excerpts. Markdown URLs are clickable only for `http`/`https`, without embedded credentials; images/HTML are never loaded.
- Event payloads are bounded; malformed links and unsafe source URL schemes are rejected. Hook failures do not block the agent or approve permissions.
- Opening an external source link is a user-initiated action. App activation is best-effort, not proof of the correct terminal tab.
- This is a menu bar agent, not a background daemon. It runs after you open it (or enable Start at Login); a deep link or the CLI can also launch it.

## 🧹 Uninstall

```sh
splash-finish uninstall-skills
```

Quit Splash Finish from its menu. Remove `~/Applications/Splash Finish.app` and the `splash-finish` symlink from your local bin directory. If you also want to erase the inbox, remove `~/Library/Application Support/Splash Finish`. Existing hook backups are left beside the agent config files for you to inspect or remove.

For a Homebrew installation, turn off **Start at Login**, run `splash-finish uninstall-skills`, quit the app, then run `brew uninstall --cask bobuk-io/tap/splash-finish`. This retains your data. Add `--zap` only to deliberately remove the inbox and app preferences; agent configuration backups are still retained.

## 🛠️ Development

Splash Finish uses [BobukKit](https://github.com/bobuk-io/BobukKit) for the inbox
window frame and wrapping shortcut hints. Notification cards, link hit targets,
question forms and keyboard commands remain app-owned.

BobukKit is a self-contained local package at `Vendor/BobukKit`. Do not edit that
copy: change `~/GitHub/bobuk.io/BobukKit`, then run its `Scripts/sync.sh` and
`Scripts/sync.sh --check` to update/check every registered app. Release EXTRA_TESTS
checks snapshot hashes and runs the kit tests without a separate checkout.
Build with Swift 6.2 or later (required by BobukKit).

```sh
swift test
bash Scripts/release/test_kit.sh    # offline release kit checks (publication order, feeds, cask, install)
python3 -m unittest discover -s Tests -v
node Tests/pi-extension.test.mjs       # Node 22.18+ for TypeScript stripping
node Tests/pi-questions.test.mjs
Scripts/compile_and_run.sh --test      # ad-hoc local build
# With an active macOS desktop and no existing Splash Finish process:
SPLASH_FINISH_GUI_TESTS=1 python3 -m unittest discover -s Tests -p test_app_smoke.py -v
```

`Package.swift` builds a SwiftUI/AppKit app and a separate testable core, with the pinned Sparkle binary dependency. `Scripts/package_app.sh` assembles the `.app`; no Xcode project is required. `install.py` is a standalone standard-library installer. Tests use temporary directories and do not alter your agent configs.

The app icon is **Landing Signal** (three raised amber bars on slate). Editable artwork and native-size PNGs live in [`Assets/AppIcon`](Assets/AppIcon/README.md); the build packages them into `Icon.icns` using macOS tools only. The menu-bar symbol remains monochrome.

`version.env` is the single source of truth for the release version: `Scripts/package_app.sh` embeds it in `Info.plist`, the app reads it back for `--version`, and CI verifies the built bundle against the file.

### Release

Releases use the shared bobuk.io release kit in [`Scripts/release`](Scripts/release/README.md), the same scheme as Ting and HAScS. App facts live in `release.env`. Write `docs/releases/v<next version>.md`, commit the landing copy for the release, then run:

```sh
APP_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' NOTARY_PROFILE=YOUR_NOTARY_PROFILE \
  Scripts/release_next.sh
```

It raises the patch version and `BUILD_NUMBER`, runs the Swift, installer and pi tests in the background while it builds, checks, notarizes and staples the universal app, signs the Sparkle appcast, installs the release in `~/Applications` and restarts it, commits and pushes, publishes the GitHub release (with `SplashFinish-<version>-universal.zip`, `SHA256SUMS` and the GitHub `appcast.xml` for 0.3.12 and older), updates `bobuk-io/homebrew-tap/Casks/splash-finish.rb` from the published archive digest, deploys the landing site with the feed and checks `https://bobuk.io/apps/splash-finish/appcast.xml`. After a failure, run the same command again. `Scripts/release/doctor.sh` checks readiness without changing anything. The signing identity used by the installer is pinned to the project's Developer ID team; update `TEAM_ID` in `install.py` if the project changes hands.

### Sparkle updates

Standalone copies embed Sparkle 2.10.1 and check `https://bobuk.io/apps/splash-finish/appcast.xml`. Homebrew-managed copies never start Sparkle.

The Ed25519 private signing key is stored in the macOS login Keychain under account `io.bobuk.splash-finish`. Back it up securely offline: losing it prevents the current app from verifying updates. Never commit or publish it. The public key is embedded in the app and in `release.env`. On the signing machine, put the verified Sparkle 2.10.1 release tools in `.build/sparkle-tools/bin` or set `SPARKLE_BIN` to their `bin` directory. Never modify the archive after the appcast signed it.

---

Your agents can go back to work now. You can, too. ☕
