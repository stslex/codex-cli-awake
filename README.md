# Codex CLI Awake

[![Build](https://github.com/stslex/codex-cli-awake/actions/workflows/build.yml/badge.svg)](https://github.com/stslex/codex-cli-awake/actions/workflows/build.yml)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A small native macOS menu-bar companion for Codex CLI. It keeps long-running CLI work awake, owns the local CLI Remote Control connection, and makes active and recent sessions visible without opening another full application.

- Starts at login and reconnects CLI Remote Control after wake or transient network loss.
- Prevents idle system sleep always, never, or only while an interactive Codex CLI session is active.
- Shows named active sessions immediately, keeps recent sessions in a nested menu, and provides safe per-session actions.
- Uses no analytics, privileged helper, root component, or direct network client.

## Quick start

```bash
git clone https://github.com/stslex/codex-cli-awake.git
cd codex-cli-awake
./scripts/install.sh
```

The installer builds an ad-hoc signed app, copies it to `~/Applications/Codex Awake.app`, registers its per-user LaunchAgent, and starts it immediately. The default Awake mode for a new installation is **On active session**.

## Menu

The menu is arranged in three sections:

1. **Remote Control** — live connection state plus a manual start/reconnect action.
2. **Active Sessions** — loaded user sessions are shown immediately; recent CLI sessions stay out of the way in a nested **Recent Sessions** menu.
3. **Awake** — the current power assertion and the three sleep-prevention modes.

The forced-white menu-bar icon is an original terminal-and-network mark. Its terminal body fills while Codex Awake owns a power assertion, and its network nodes fill while CLI Remote Control is connected.

## Session actions

Each active or recent session opens a native submenu instead of launching a command immediately:

- **Open in ChatGPT** opens the exact `codex://threads/<session-id>` deep link.
- **Resume in Terminal** is available only for recent sessions, so an already-active session is never resumed twice.
- **Fork in New Terminal** creates an independent continuation of an active or recent session.
- **Reveal Working Directory** opens the session directory in Finder.
- **Copy** exposes the session name, ID, working directory, and ChatGPT deep link.
- **Archive Session** is available only for recent sessions and always requires confirmation. Delete and Stop actions are intentionally not exposed.

Resume and Fork open the built-in Terminal app. macOS may ask once for permission to let Codex Awake control Terminal.

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

Codex Awake is the login-start owner for CLI Remote Control. Its LaunchAgent starts the app when the user logs in; the app then runs the idempotent `codex remote-control start --json` command and refreshes the connection every ten seconds. This also reconnects the managed CLI host after wake or a transient network interruption.

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
```

The app bundle is written to `build/Codex Awake.app`.

Command-line diagnostics are available from the built executable:

```bash
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --detect-sessions
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --remote-status
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --list-active-sessions
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --list-sessions
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --remote-start
```

`--detect-sessions`, `--list-active-sessions`, and `--list-sessions` are read-only. `--remote-status` and `--remote-start` both ensure that CLI Remote Control is started before returning its status.

## Verify the installation

```bash
launchctl print "gui/$(id -u)/com.stslex.codex-awake-menu"
pmset -g assertions
```

When Codex Awake is holding the assertion, `pmset` lists a `CodexAwake` process with the assertion name `Codex Awake menu-bar mode`.

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

## Privacy and security

Codex Awake has no analytics, privileged helper, or root component. It reads the local process list and Codex state database, calls the public IOKit power-management API, and invokes the locally installed Codex CLI for Remote Control and explicit session actions. Network traffic and authentication remain owned by Codex CLI.

## Contributing

Issues and pull requests are welcome. Please run `swift build` and `./scripts/build.sh` before submitting a change.

## License

MIT
