# ADR-0002: Native Self-Updater

**Status:** Accepted

**Date:** 2026-08-29

**Decider:** Project owner

## Context

[ADR-0001](0001-signed-releases-and-homebrew.md) selected GitHub Releases and Homebrew as the initial packaged update path and rejected a custom updater until its trust, rollback, and package-manager boundaries could be reviewed. Codex Awake also supports source installation into `~/Applications`, where requiring a repository checkout for every update is inconvenient.

The existing release workflow already defines one trustworthy artifact: a universal app archive that is Developer ID-signed, Apple-notarized and stapled, Gatekeeper-assessed, SHA-256 checksummed, attested, and published under an immutable semantic-version tag. A native updater can consume that artifact without adding a framework, appcast service, privileged helper, or second release pipeline.

## Decision

Add a dependency-free native updater backed by the repository's latest stable GitHub Release. The app checks quietly after launch and at most once every six hours while running. It exposes its installed version and update state in the menu but never downloads or installs without explicit user confirmation.

An eligible update must use the exact stable tag and asset naming contract documented in `RELEASING.md`. The updater validates repository-owned HTTPS URLs, downloads the archive and checksum, verifies SHA-256 before extraction, and requires the extracted bundle identifier and version to match. Both the staging process and replacement helper require `codesign --verify` and a successful Gatekeeper assessment.

The verified bundle is copied to a hidden path beside the current application so final moves stay on one filesystem. A short-lived copy of the new executable waits for the running app to terminate, moves the existing bundle to a unique backup, moves the staged update into place, and relaunches it. If replacement or relaunch fails, the helper restores and relaunches the previous bundle.

The updater does not request administrator privileges. It fails without changing the current app when the containing directory is not writable. Homebrew-managed installations remain updateable through Homebrew and consume the same archive and checksum.

## Options considered

| Option | Complexity | Trust and rollback | Decision |
| --- | --- | --- | --- |
| Native updater over existing GitHub Release assets | Medium | Reuses Developer ID, notarization, Gatekeeper, checksum, and immutable tags; explicit local rollback | Selected |
| Sparkle | High | Mature feed and update machinery, but adds a framework, appcast, helper, and additional signing surface | Deferred |
| Homebrew only | Low | Strong package-manager ownership, but source-installed users must update manually | Retained as a parallel channel |
| Download and overwrite without staged verification | Low | No safe rollback and an unacceptable replacement window | Rejected |

## Consequences

- Writable source installations gain an in-app update path without a third-party runtime dependency.
- Release asset names and immutable tags become a public compatibility contract.
- A source-built ad-hoc app may discover updates and migrate to a signed release of the same semantic version, but it can install only an artifact accepted by the production signature and Gatekeeper checks.
- Homebrew remains authoritative for Homebrew-managed or otherwise unwritable installations.
- The app now makes direct unauthenticated HTTPS requests to GitHub for release metadata and, after confirmation, update assets; this is documented in the privacy section.
- Remote Control and interactive Codex CLI sessions remain running while only the menu application relaunches.
