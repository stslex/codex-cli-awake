#!/bin/bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
info_plist="${project_dir}/Resources/Info.plist"
bundle="${project_dir}/build/Codex Awake.app"
release_dir="${project_dir}/build/release"
dist_dir="${project_dir}/dist"

: "${CODEX_AWAKE_SIGN_IDENTITY:?Set CODEX_AWAKE_SIGN_IDENTITY to a Developer ID Application identity.}"
: "${APPLE_NOTARY_KEY_PATH:?Set APPLE_NOTARY_KEY_PATH to an App Store Connect API key file.}"
: "${APPLE_NOTARY_KEY_ID:?Set APPLE_NOTARY_KEY_ID.}"
: "${APPLE_NOTARY_ISSUER_ID:?Set APPLE_NOTARY_ISSUER_ID.}"

if [[ "${CODEX_AWAKE_SIGN_IDENTITY}" == "-" ]]; then
    echo "Release packaging refuses ad-hoc signing." >&2
    exit 1
fi
if [[ ! -f "${APPLE_NOTARY_KEY_PATH}" ]]; then
    echo "Notary API key not found: ${APPLE_NOTARY_KEY_PATH}" >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "CFBundleShortVersionString must be semantic versioning: ${version}" >&2
    exit 1
fi

CODEX_AWAKE_SIGN_IDENTITY="${CODEX_AWAKE_SIGN_IDENTITY}" \
    "${script_dir}/build.sh" release --universal

rm -rf -- "${release_dir}"
mkdir -p "${release_dir}" "${dist_dir}"
submission_archive="${release_dir}/Codex-Awake-${version}-notary-submission.zip"
final_archive_name="Codex-Awake-${version}-universal.zip"
final_archive="${dist_dir}/${final_archive_name}"
checksum_file="${final_archive}.sha256"
cask_file="${dist_dir}/codex-cli-awake.rb"

updater_archive_name="$("${bundle}/Contents/MacOS/CodexAwake" --update-archive-name)"
if [[ "${updater_archive_name}" != "${final_archive_name}" ]]; then
    echo "Updater expects ${updater_archive_name}, but packaging would publish ${final_archive_name}." >&2
    exit 1
fi

rm -f -- "${final_archive}" "${checksum_file}" "${cask_file}"
ditto -c -k --keepParent --sequesterRsrc "${bundle}" "${submission_archive}"

xcrun notarytool submit "${submission_archive}" \
    --key "${APPLE_NOTARY_KEY_PATH}" \
    --key-id "${APPLE_NOTARY_KEY_ID}" \
    --issuer "${APPLE_NOTARY_ISSUER_ID}" \
    --wait
xcrun stapler staple "${bundle}"
xcrun stapler validate "${bundle}"
codesign --verify --deep --strict --verbose=2 "${bundle}"
spctl --assess --type execute --verbose=4 "${bundle}"

ditto -c -k --keepParent --sequesterRsrc "${bundle}" "${final_archive}"
(
    cd "${dist_dir}"
    shasum -a 256 "${final_archive_name}" > "${final_archive_name}.sha256"
)
checksum="$(awk '{print $1}' "${checksum_file}")"
"${script_dir}/render-homebrew-cask.sh" "${version}" "${checksum}" "${cask_file}"

echo "Packaged and notarized ${final_archive}"
echo "Checksum: ${checksum_file}"
echo "Homebrew Cask: ${cask_file}"
