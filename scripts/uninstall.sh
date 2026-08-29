#!/bin/bash

set -euo pipefail

label="com.stslex.codex-awake-menu"
bundle_id="com.stslex.CodexAwake"
launch_domain="gui/$(id -u)"
applications_dir="${CODEX_AWAKE_APPLICATIONS_DIR:-${HOME}/Applications}"
installed_app="${applications_dir}/Codex Awake.app"
launch_agent="${HOME}/Library/LaunchAgents/${label}.plist"
installed_executable="${installed_app}/Contents/MacOS/CodexAwake"

if [[ -x "${installed_executable}" ]] && \
   /usr/bin/strings "${installed_executable}" | /usr/bin/grep -q -- "--unregister-login-item"; then
    "${installed_executable}" --unregister-login-item >/dev/null 2>&1 || \
        echo "Warning: macOS did not remove the Login Item; remove it in System Settings if it remains." >&2
fi

if launchctl print "${launch_domain}/${label}" >/dev/null 2>&1; then
    launchctl bootout "${launch_domain}/${label}"
fi

stale_pids="$(pgrep -x CodexAwake || true)"
if [[ -n "${stale_pids}" ]]; then
    while IFS= read -r stale_pid; do
        [[ -n "${stale_pid}" ]] && kill -TERM "${stale_pid}"
    done <<< "${stale_pids}"
fi

rm -rf -- "${installed_app}"
rm -f -- "${launch_agent}"

if [[ "${1:-}" == "--purge" ]]; then
    defaults delete "${bundle_id}" >/dev/null 2>&1 || true
fi

echo "Uninstalled Codex Awake."
