# Codex CLI Awake

A small native macOS menu-bar app that prevents idle system sleep while Codex CLI sessions are open.

Codex Awake uses a native IOKit power assertion. It does not prevent display sleep, modify global Energy Saver settings, or establish a Codex Remote connection.

## Modes

| Mode | Behavior |
| --- | --- |
| **On** | Always holds a `PreventUserIdleSystemSleep` assertion. |
| **Off** | Releases the assertion owned by Codex Awake. |
| **On active session** | Holds the assertion while an interactive Codex CLI/TUI process is present. |

The selected mode is stored in `UserDefaults` and restored after login. The menu-bar icon is a forced-white cup: filled while the assertion is active and outlined while it is inactive.

`On active session` checks the local process list every three seconds. It detects interactive `codex` processes with a TTY, including `codex --remote unix://`, and ignores background app servers, Remote Control watchdogs, MCP servers, code-mode hosts, and non-interactive commands.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools or Xcode with Swift 5.9 or later

## Install

```bash
git clone https://github.com/stslex/codex-cli-awake.git
cd codex-cli-awake
./scripts/install.sh
```

The installer builds an ad-hoc signed app, copies it to `~/Applications/Codex Awake.app`, installs a user LaunchAgent, and starts the app immediately. The default mode for a new installation is **On active session**.

## Build without installing

```bash
./scripts/build.sh
```

The app bundle is written to `build/Codex Awake.app`.

To run the process detector from a terminal:

```bash
./build/Codex\ Awake.app/Contents/MacOS/CodexAwake --detect-sessions
```

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
- Codex Remote availability also depends on the host app, network, account, workspace, and Remote connection state. See the official [Remote connections documentation](https://learn.chatgpt.com/docs/remote-connections).

## Privacy and security

Codex Awake runs entirely on the Mac. It reads the local process list to identify interactive Codex CLI sessions and calls the public IOKit power-management API. It has no analytics, network access, privileged helper, or root component.

## Contributing

Issues and pull requests are welcome. Please run `swift build` and `./scripts/build.sh` before submitting a change.

## License

MIT
