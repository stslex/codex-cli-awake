#!/bin/bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
configuration="release"
universal=false
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${project_dir}/.build/module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${SWIFTPM_MODULECACHE_OVERRIDE}}"

for argument in "$@"; do
    case "${argument}" in
        debug|release)
            configuration="${argument}"
            ;;
        --universal)
            universal=true
            ;;
        *)
            echo "Usage: $0 [debug|release] [--universal]" >&2
            exit 2
            ;;
    esac
done

mkdir -p "${SWIFTPM_MODULECACHE_OVERRIDE}"
build_arguments=(--package-path "${project_dir}" -c "${configuration}")
if [[ "${universal}" == true ]]; then
    build_arguments+=(--arch arm64 --arch x86_64)
fi
if [[ "${CODEX_AWAKE_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
    build_arguments+=(--disable-sandbox)
fi

swift build "${build_arguments[@]}"
binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"

bundle="${project_dir}/build/Codex Awake.app"
contents="${bundle}/Contents"
binary="${contents}/MacOS/CodexAwake"
resources="${contents}/Resources"
entitlements="${project_dir}/Resources/CodexAwake.entitlements"
sign_identity="${CODEX_AWAKE_SIGN_IDENTITY:--}"
icon_master="${project_dir}/build/CodexAwake-1024.png"
iconset="${project_dir}/build/CodexAwake.iconset"

rm -rf -- "${bundle}"
rm -rf -- "${iconset}"
mkdir -p "${contents}/MacOS" "${resources}" "${iconset}"
install -m 0755 "${binary_dir}/CodexAwake" "${binary}"
install -m 0644 "${project_dir}/Resources/Info.plist" "${contents}/Info.plist"

"${binary}" --render-app-icon "${icon_master}"
while read -r filename size; do
    sips -z "${size}" "${size}" "${icon_master}" --out "${iconset}/${filename}" >/dev/null
done <<'ICON_SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
ICON_SIZES
iconutil -c icns "${iconset}" -o "${resources}/CodexAwake.icns"
rm -rf -- "${iconset}" "${icon_master}"

codesign_arguments=(
    --force
    --deep
    --options runtime
    --entitlements "${entitlements}"
)
if [[ "${sign_identity}" == "-" ]]; then
    codesign_arguments+=(--timestamp=none)
else
    codesign_arguments+=(--timestamp)
fi
codesign_arguments+=(--sign "${sign_identity}")

codesign "${codesign_arguments[@]}" "${bundle}"
plutil -lint "${contents}/Info.plist"
plutil -lint "${entitlements}"
test -s "${resources}/CodexAwake.icns"
codesign --verify --deep --strict --verbose=2 "${bundle}"

if [[ "${universal}" == true ]]; then
    architectures="$(lipo -archs "${binary}")"
    [[ " ${architectures} " == *" arm64 "* ]] || {
        echo "Universal build is missing arm64: ${architectures}" >&2
        exit 1
    }
    [[ " ${architectures} " == *" x86_64 "* ]] || {
        echo "Universal build is missing x86_64: ${architectures}" >&2
        exit 1
    }
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${contents}/Info.plist")"
echo "Built Codex Awake ${version} at ${bundle}"
