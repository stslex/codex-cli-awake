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
entitlements="${project_dir}/Resources/CodexAwake.entitlements"
sign_identity="${CODEX_AWAKE_SIGN_IDENTITY:--}"

rm -rf -- "${bundle}"
mkdir -p "${contents}/MacOS"
install -m 0755 "${binary_dir}/CodexAwake" "${binary}"
install -m 0644 "${project_dir}/Resources/Info.plist" "${contents}/Info.plist"

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
