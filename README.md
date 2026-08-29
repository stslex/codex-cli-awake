# Codex CLI Awake

[![Build](https://github.com/stslex/codex-cli-awake/actions/workflows/build.yml/badge.svg)](https://github.com/stslex/codex-cli-awake/actions/workflows/build.yml)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A small native macOS menu-bar companion for Codex CLI. It keeps long-running CLI work awake, owns the local CLI Remote Control connection, and makes active and recent sessions visible without opening another full application.

- Registers itself as a native macOS Login Item and reconnects CLI Remote Control after wake or transient network loss.
- Prevents idle system sleep always, never, or only while an interactive Codex CLI session is active.
- Shows named active sessions immediately, keeps recent sessions in a nested menu, and provides safe per-session actions, including returning to the exact terminal that owns a live CLI session.
- Checks its public GitHub Releases feed for updates without analytics, a privileged helper, or a root component.

## Quick start

```bash
git clone https://github.com/stslex/codex-cli-awake.git
cd codex-cli-awake
./scripts/install.sh
```

The installer builds an ad-hoc signed app, copies it to `~/Applications/Codex Awake.app`, registers it with macOS Service Management, and starts it immediately. The default Awake mode for a new installation is **On active session**. If Service Management is unavailable for a source build, the installer keeps a compatibility LaunchAgent as a fail-safe and reports that choice.

### Distribution status

Source installation is the supported path until the first Developer ID-signed and Apple-notarized GitHub release is published. The repository already contains the universal release pipeline, native updater, and Homebrew Cask generator, but it intentionally does not publish an ad-hoc signed binary. Until that first release exists, the update menu reports **No published release**.

After the first signed release and public tap are available, users can update from the app when it is installed in a writable location such as `~/Applications`, or use Homebrew:

```bash
brew tap stslex/tap
brew install --cask codex-cli-awake
```

Do not treat that command as available until the tap is linked from this README or the GitHub Releases page contains a notarized asset.

## Menu

The menu is arranged in four sections:

1. **Remote Control** — live connection state plus a manual start/reconnect action.
2. **Active Sessions** — loaded user sessions are shown immediately; recent CLI sessions stay out of the way in a nested **Recent Sessions** menu.
3. **Awake** — the current power assertion and the three sleep-prevention modes.
4. **App** — native Launch at Login state, installed version, update status and action, manual refresh, and quit.

The forced-white menu-bar icon combines a terminal with a small cloud in its upper-right corner. The terminal body fills while Codex Awake owns a power assertion, and the cloud fades when CLI Remote Control is disconnected.

## Session actions

Each active or recent session opens a native submenu instead of launching a command immediately:

- **Focus in Terminal** returns to the exact Ghostty, Terminal, or iTerm2 surface that owns an active CLI process.
- **Open in Terminal** appears for a Remote-active session whose original local terminal is no longer available and attaches it to a new Terminal window.
- **Open in ChatGPT** opens the exact `codex://threads/<session-id>` deep link.
- **Resume in Terminal** is available only for recent sessions, so an already-active session is never resumed twice.
- **Fork in New Terminal** creates an independent continuation of an active or recent session.
- **Reveal Working Directory** opens the session directory in Finder.
- **Copy** exposes the session name, ID, working directory, and ChatGPT deep link.
- **Archive Session** is available only for recent sessions and always requires confirmation. Delete and Stop actions are intentionally not exposed.

Focus matches the active Codex process to its TTY before activating a terminal surface. Terminal and iTerm2 expose that TTY directly. For Ghostty, Codex Awake briefly assigns a unique title to the exact TTY, focuses the one matching surface through Ghostty's native AppleScript interface, and immediately restores the previous title. It never guesses between ambiguous active processes.

Open, Resume, and Fork launch the built-in Terminal app. macOS may ask once for permission to let Codex Awake control Ghostty, Terminal, or iTerm2.

### Per-session profiles

Resume and Fork preserve the selected session's CLI profile by rebuilding the command with the same `--profile <name>` before the subcommand. Codex thread metadata does not contain the profile name, so Codex Awake keeps a local session-ID-to-profile mapping in `UserDefaults`:

- While a CLI session is active, the app captures an explicit `--profile` or `-p` from its process command and remembers it.
- If an older recent session has no known mapping, the first Resume or Fork asks for its original profile and remembers the answer.
- **Default (no --profile)** is an explicit saved choice, never a silent fallback.
- **Profile: ...** in a session submenu lets you inspect or correct the saved choice.

The mapping changes only how Codex Awake launches future Resume and Fork commands. It does not rewrite the Codex thread or its transcript.

## Awake modes

| Mode | Behavior |
| --- | --- |
| **On** | Always holds a `PreventUserIdleSystemSleep` assertion. |
| **Off** | Releases the assertion owned by Codex Awake. |
| **On active session** | Holds the assertion while an interactive Codex CLI/TUI process is present. |

The selected mode is stored in `UserDefaults` and restored after login. `On active session` checks the local process list every three seconds. It detects interactive `codex` processes with a TTY, including `codex --remote unix://`, and ignores app servers, Remote Control helpers, MCP servers, code-mode hosts, and non-interactive commands.

Codex Awake uses a native IOKit power assertion. It does not prevent display sleep or modify global Energy Saver settings.

## CLI Remote Control

Codex Awake is the login-start owner for CLI Remote Control. macOS starts the main app through `SMAppService.mainApp`; the app then runs the idempotent `codex remote-control start --json` command and refreshes the connection every ten seconds. This also reconnects the managed CLI host after wake or a transient network interruption.

The **Launch at Login** menu item exposes the actual Service Management state. If macOS requires approval, it opens **System Settings > General > Login Items**. Turning the item off unregisters only Codex Awake; it does not stop Remote Control or any attached CLI/TUI session.

The menu exposes a manual **Start / Reconnect Remote Control** action. Remote shutdown is intentionally not exposed because the current managed daemon shutdown path also disconnects attached CLI/TUI sessions.

Only one app can own the Remote host connection. If ChatGPT Desktop has **Control this Mac** enabled, close it or disable that setting before enabling the CLI Remote host. Codex Awake reports this ownership conflict as a connection error.

See the official [Remote connections documentation](https://learn.chatgpt.com/docs/remote-connections) for account, workspace, network, sleep, and mobile requirements.

## Requirements

- macOS 13 or later
- A Codex CLI version that provides `remote-control` and managed `app-server daemon` commands
- Xcode Command Line Tools or Xcode with Swift 5.9 or later to build from source

## Build without installing

```bash
./scripts/build.sh
./scripts/build.sh release --universal
```

The app bundle is written to `build/Codex Awake.app`. The first command builds for the current Mac; `--universal` builds one `arm64` and `x86_64` bundle.

The build also renders the code-native application artwork into a complete macOS `.icns` resource. The same terminal-and-cloud icon is assigned explicitly to native alerts, including update dialogs.

Command-line diagnostics are available from the built executable:

```bash
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --detect-sessions
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --remote-status
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --list-active-sessions
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --list-sessions
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --remote-start
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --check-for-updates
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --login-item-status
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --register-login-item
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --unregister-login-item
```

`--detect-sessions`, `--list-active-sessions`, and `--list-sessions` are local read-only commands. `--check-for-updates` makes a read-only request to this repository's latest GitHub Release. `--remote-status` and `--remote-start` both ensure that CLI Remote Control is started before returning its status.

## Verify the installation

```bash
~/Applications/Codex\ Awake.app/Contents/MacOS/CodexAwake --login-item-status
pmset -g assertions
```

The Login Item command reports `enabled` when native login start is active. When Codex Awake is holding the assertion, `pmset` lists a `CodexAwake` process with the assertion name `Codex Awake menu-bar mode`.

## Uninstall

```bash
./scripts/uninstall.sh
```

Use `./scripts/uninstall.sh --purge` to remove the saved mode as well.

## Important behavior

- **Off** releases only the assertion created by Codex Awake. Other applications can independently prevent sleep.
- ChatGPT's **Keep this Mac awake** setting is separate from this app.
- Closing the MacBook lid still follows macOS clamshell rules.
- Active user sessions are identified from rollout files currently held open by the managed app-server. Service and sub-agent rollouts are excluded.
- Session names and working directories come from the local Codex state database and remain on the Mac.
- Per-session profile selections are stored locally in the Codex Awake `UserDefaults` domain and are not written into Codex thread metadata.
- The installer removes the obsolete standalone `com.stslex.codex-remote-control` LaunchAgent so Codex Awake is the single login-start owner.

## Releases and updates

Tagged releases are built once in GitHub Actions as a universal app, signed with Developer ID, notarized and stapled by Apple, checked by Gatekeeper, checksummed, and attested before a GitHub Release can be created. Missing credentials or any failed verification stops publication.

Codex Awake performs a quiet update check shortly after launch and no more than once every six hours while it remains open. It never downloads or installs an update automatically. When a newer release is available, choose **Install Update ...** in the menu and confirm the operation.

The native updater has no third-party framework or privileged helper. It accepts only the exact immutable ZIP and SHA-256 assets for a stable semantic-version tag in `stslex/codex-cli-awake`, verifies the checksum, bundle identifier, version, code signature, and Gatekeeper assessment, then stages the app beside the current bundle. A short-lived copy of the new signed executable waits for Codex Awake to quit, keeps a rollback copy during replacement, relaunches the new app, and restores the previous bundle if relaunch fails. It does not stop CLI sessions or the managed Remote Control daemon.

Self-update requires the app's parent directory to be writable. A source-built ad-hoc copy can migrate to the signed release even when both have the same semantic version. Homebrew-managed or administrator-owned installations should continue to use `brew upgrade --cask codex-cli-awake`; the in-app action fails without modifying the existing app when replacement is not permitted. See [RELEASING.md](RELEASING.md), [ADR-0001](docs/adr/0001-signed-releases-and-homebrew.md), and [ADR-0002](docs/adr/0002-native-self-updater.md).

## Privacy and security

Codex Awake has no analytics, privileged helper, or root component. It reads the local process list and Codex state database, calls the public IOKit power-management API, and invokes the locally installed Codex CLI for Remote Control and explicit session actions. Remote Control traffic and authentication remain owned by Codex CLI. The only network request made directly by Codex Awake is an unauthenticated HTTPS request to GitHub for release metadata and, after explicit installation confirmation, the selected release archive and checksum.

## Contributing

Issues and pull requests are welcome. Please run `swift build` and `./scripts/build.sh` before submitting a change.

## License

MIT
