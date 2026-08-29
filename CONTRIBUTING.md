# Contributing

Thank you for improving Codex CLI Awake.

## Development workflow

1. Create a focused branch.
2. Make the smallest change that solves the problem.
3. Run `swift test`.
4. Run `./scripts/build.sh release --universal` and verify the generated app bundle.
5. Test all three Awake modes, native Login Item registration, Remote reconnection, session listing, and the update-menu states before opening a pull request.

Release tags and Homebrew Casks follow [RELEASING.md](RELEASING.md). Never upload an ad-hoc signed app as a public release.

Updater changes must preserve the exact GitHub Release asset contract and include tests for version comparison, trusted URLs, checksum validation, staged replacement, and rollback. Never weaken Developer ID, Gatekeeper, or bundle-identity verification to make a local fixture installable.

Keep user-facing text, documentation, commit messages, and code comments in English.
