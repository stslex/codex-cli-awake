# Codex CLI Awake

A native macOS menu-bar companion for Codex CLI. It keeps active CLI work awake, shows the CLI Remote Control connection, lists recent named sessions, and provides safe Remote and sleep controls in one menu.

## Menu

The menu is arranged in three sections:

1. **Remote Control** — live connection state plus a manual start/reconnect action.
2. **Active Sessions** — loaded user sessions are shown immediately; recent CLI sessions stay out of the way in a nested **Recent Sessions** menu.
3. **Awake** — the current power assertion and the three sleep-prevention modes.

The forced-white menu-bar icon is an original terminal-and-network mark. Its terminal body fills while Codex Awake owns a power assertion, and its network nodes fill while CLI Remote Control is connected.

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

## Install

```bash
git clone https://github.com/stslex/codex-cli-awake.git
cd codex-cli-awake
./scripts/install.sh
```

The installer builds an ad-hoc signed app, copies it to `~/Applications/Codex Awake.app`, installs a user LaunchAgent, removes the obsolete standalone Remote watchdog LaunchAgent if present, and starts the app immediately. The default mode for a new installation is **On active session**.

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

## Privacy and security

Codex Awake has no analytics, privileged helper, or root component. It reads the local process list and Codex state database, calls the public IOKit power-management API, and invokes the locally installed Codex CLI for Remote Control status and actions. Network traffic and authentication remain owned by Codex CLI.

## Contributing

Issues and pull requests are welcome. Please run `swift build` and `./scripts/build.sh` before submitting a change.

## License

MIT
