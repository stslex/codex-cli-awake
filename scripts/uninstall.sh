#!/bin/bash

set -euo pipefail

label="com.stslex.codex-awake-menu"
bundle_id="com.stslex.CodexAwake"
launch_domain="gui/$(id -u)"
applications_dir="${CODEX_AWAKE_APPLICATIONS_DIR:-${HOME}/Applications}"
installed_app="${applications_dir}/Codex Awake.app"
launch_agent="${HOME}/Library/LaunchAgents/${label}.plist"

if launchctl print "${launch_domain}/${label}" >/dev/null 2>&1; then
    launchctl bootout "${launch_domain}/${label}"
fi

rm -rf -- "${installed_app}"
rm -f -- "${launch_agent}"

if [[ "${1:-}" == "--purge" ]]; then
    defaults delete "${bundle_id}" >/dev/null 2>&1 || true
fi

echo "Uninstalled Codex Awake."
