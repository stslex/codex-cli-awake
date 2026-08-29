#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "Usage: $0 <version> <sha256> <output-file>" >&2
    exit 2
fi

version="$1"
checksum="$2"
output_file="$3"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
template="${script_dir}/../packaging/homebrew/codex-cli-awake.rb.template"

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use semantic versioning: ${version}" >&2
    exit 1
fi
if [[ ! "${checksum}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "SHA-256 must contain exactly 64 lowercase hexadecimal characters." >&2
    exit 1
fi

mkdir -p "$(dirname -- "${output_file}")"
sed \
    -e "s/{{VERSION}}/${version}/g" \
    -e "s/{{SHA256}}/${checksum}/g" \
    "${template}" > "${output_file}"

ruby -c "${output_file}" >/dev/null
echo "Rendered ${output_file}"
