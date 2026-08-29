# ADR-0001: Signed Releases and Homebrew Distribution

**Status:** Superseded in part by [ADR-0002](0002-native-self-updater.md)

**Date:** 2026-08-29

**Decider:** Project owner

## Context

Before this decision, Codex Awake was built from source and installed into `~/Applications` by a path-bound LaunchAgent. A packaged update channel must preserve native macOS trust, login startup, active Remote Control ownership, and running Codex CLI/TUI sessions. The repository does not currently have a Developer ID identity or notarization credentials configured, so it must not publish an apparently production-ready ad-hoc signed binary.

## Decision

Use `SMAppService.mainApp` for path-independent login startup and use a Homebrew Cask backed by immutable GitHub Release archives as the packaged update channel. GitHub Actions will build one universal archive, sign it with Developer ID and hardened runtime, notarize and staple it, verify it with Gatekeeper, checksum it, attest it, and only then create a release.

The source installer retains the old LaunchAgent only as a migration fallback when an ad-hoc local build cannot register with Service Management. Release artifacts never install that LaunchAgent.

## Options considered

| Option | Complexity | Trust and rollback | Decision |
| --- | --- | --- | --- |
| Homebrew Cask + GitHub Releases | Medium | Native checksum, immutable asset, straightforward rollback | Selected |
| Built-in Sparkle updater | High | Strong when fully signed, but adds framework, XPC, appcast, and signing surfaces | Deferred |
| Custom in-app downloader/replacer | High | Easy to implement incorrectly and duplicates package-manager policy | Rejected |
| Source-only installation | Low | No binary trust problem, but no convenient update path | Kept as development fallback |

## Consequences

- Login startup follows the app bundle across `~/Applications`, `/Applications`, and Homebrew upgrades.
- Public binaries cannot ship until Developer ID and notarization credentials are configured.
- Homebrew upgrades become the single packaged-update mechanism; source installs remain manual.
- A built-in updater can be reconsidered later, but only with a separate ADR covering framework packaging, signing, appcast integrity, rollback, and interaction with Homebrew.
- Release CI is intentionally stricter than local source builds: local builds may be ad-hoc signed, while public release builds may not.
