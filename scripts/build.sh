#!/bin/bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
configuration="${1:-release}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${project_dir}/.build/module-cache}"

case "${configuration}" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

mkdir -p "${SWIFTPM_MODULECACHE_OVERRIDE}"
swift build --package-path "${project_dir}" -c "${configuration}"
binary_dir="$(swift build --package-path "${project_dir}" -c "${configuration}" --show-bin-path)"

bundle="${project_dir}/build/Codex Awake.app"
contents="${bundle}/Contents"

rm -rf -- "${bundle}"
mkdir -p "${contents}/MacOS"
install -m 0755 "${binary_dir}/CodexAwake" "${contents}/MacOS/CodexAwake"
install -m 0644 "${project_dir}/Resources/Info.plist" "${contents}/Info.plist"

codesign --force --deep --sign - "${bundle}"
plutil -lint "${contents}/Info.plist"
codesign --verify --deep --strict --verbose=2 "${bundle}"

echo "Built ${bundle}"
