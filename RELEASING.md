# Releasing Codex Awake

Codex Awake publishes only universal, Developer ID-signed, Apple-notarized artifacts. The release workflow fails closed: an unsigned, unnotarized, unstapled, or Gatekeeper-rejected app never reaches GitHub Releases. The built-in updater and Homebrew Cask consume the same immutable archive and SHA-256 checksum.

## One-time repository setup

Add the following GitHub Actions configuration:

| Type | Name | Value |
| --- | --- | --- |
| Variable | `APPLE_DEVELOPER_ID_APPLICATION` | Full `Developer ID Application: ...` identity imported by the certificate |
| Secret | `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` export containing the certificate and private key |
| Secret | `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the `.p12` export |
| Secret | `APPLE_NOTARY_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key |
| Secret | `APPLE_NOTARY_KEY_ID` | API key ID |
| Secret | `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer ID |

Do not commit any certificate, private key, password, issuer configuration, or decoded signing material. The workflow writes decoded files only inside the ephemeral runner and removes them in an `always()` cleanup step.

## Validate without publishing

Run the **Release** workflow manually with `workflow_dispatch`. It runs tests and creates a clearly named `unnotarized-ci` artifact using ad-hoc signing. That artifact is for pipeline validation only; the workflow cannot create a GitHub Release on this trigger.

## Publish a release

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Resources/Info.plist`.
2. Merge a green build on the default branch.
3. Create and push a signed tag that exactly matches the marketing version:

   ```bash
   git tag -s v1.4.0 -m "release: v1.4.0"
   git push origin v1.4.0
   ```

4. The tag workflow verifies the version, runs tests, imports the ephemeral certificate, builds one `arm64` + `x86_64` app, signs with hardened runtime, submits it to Apple, staples the ticket, runs `codesign` and `spctl`, creates a SHA-256 checksum and Homebrew Cask, records build provenance, and finally creates the GitHub Release.

The workflow stops before publication when a setting is absent or any verification fails. Do not bypass a failed signing, notarization, Gatekeeper, checksum, or attestation step.

## Built-in updater contract

The application reads `https://api.github.com/repos/stslex/codex-cli-awake/releases/latest` without authentication. A stable release is eligible only when all of the following match exactly:

- tag: `v<CFBundleShortVersionString>` using three-component semantic versioning;
- archive: `Codex-Awake-<version>-universal.zip`;
- checksum: `Codex-Awake-<version>-universal.zip.sha256`;
- release and asset URLs: HTTPS URLs owned by this repository.

Do not rename those assets without changing and testing `AppUpdateClient` in the same release. `package-release.sh` asks the built application for `--update-archive-name` and fails before notarization when the application and packaging contract differ. The updater verifies the checksum before extraction, then requires the extracted app to have bundle identifier `com.stslex.CodexAwake`, the advertised version, a valid code signature, and a successful Gatekeeper assessment. It revalidates the staged bundle in the replacement helper.

The updater never installs automatically. It checks quietly after launch, exposes the result in the menu, and requires explicit confirmation before download and replacement. Replacement uses a same-directory staging bundle and a temporary backup. If the new app cannot be launched, the helper restores and relaunches the previous bundle.

Source-built, ad-hoc signed copies can discover a release and are offered a signed same-version replacement when appropriate, but they can install only a release artifact that passes the same Developer ID and Gatekeeper checks. An unwritable application directory is a non-destructive failure; Homebrew and administrator-owned installations remain managed by their installer.

## Homebrew tap

The release asset `codex-cli-awake.rb` is rendered from `packaging/homebrew/codex-cli-awake.rb.template` with the exact released version and archive checksum. After the first signed release:

1. Create the public `stslex/homebrew-tap` repository with a `Casks` directory.
2. Copy the generated asset to `Casks/codex-cli-awake.rb` in that repository.
3. Run `brew style --cask stslex/tap/codex-cli-awake` and `brew audit --cask --new stslex/tap/codex-cli-awake`.
4. Verify a clean install and upgrade on both Apple Silicon and Intel macOS before advertising the tap.

The Cask keeps the app's native Login Item across upgrades, relaunches the menu app after Homebrew replaces it, and removes the Login Item during uninstall. A `--zap` uninstall also removes preferences and the obsolete LaunchAgent logs.

## Rollback

- If GitHub publication fails, fix the cause and create a new patch version and tag. Do not replace a released archive under the same version.
- If the Homebrew Cask is broken, revert its tap commit or pin it to the last known-good release checksum.
- If Apple revokes or rejects the artifact, remove the affected release from the supported channel and publish a newly signed patch release.
- If a native updater defect is discovered, remove the affected release from the supported channel and publish a new patch release. Never replace assets under an existing tag because both the updater and Homebrew rely on immutable version-to-checksum mapping.

The native updater decision is documented in [ADR-0002](docs/adr/0002-native-self-updater.md), which partially supersedes [ADR-0001](docs/adr/0001-signed-releases-and-homebrew.md).
