#!/bin/bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
label="com.stslex.codex-awake-menu"
legacy_remote_label="com.stslex.codex-remote-control"
bundle_id="com.stslex.CodexAwake"
launch_domain="gui/$(id -u)"
applications_dir="${CODEX_AWAKE_APPLICATIONS_DIR:-${HOME}/Applications}"
installed_app="${applications_dir}/Codex Awake.app"
launch_agents_dir="${HOME}/Library/LaunchAgents"
launch_agent="${launch_agents_dir}/${label}.plist"
legacy_remote_launch_agent="${launch_agents_dir}/${legacy_remote_label}.plist"
log_dir="${HOME}/.codex/log"

"${script_dir}/build.sh" release

mkdir -p "${applications_dir}" "${launch_agents_dir}" "${log_dir}"

if launchctl print "${launch_domain}/${label}" >/dev/null 2>&1; then
    launchctl bootout "${launch_domain}/${label}"
fi

if launchctl print "${launch_domain}/${legacy_remote_label}" >/dev/null 2>&1; then
    launchctl bootout "${launch_domain}/${legacy_remote_label}"
fi
rm -f -- "${legacy_remote_launch_agent}"

stale_pids="$(pgrep -x CodexAwake || true)"
if [[ -n "${stale_pids}" ]]; then
    while IFS= read -r stale_pid; do
        [[ -n "${stale_pid}" ]] && kill -TERM "${stale_pid}"
    done <<< "${stale_pids}"

    for _ in {1..20}; do
        pgrep -x CodexAwake >/dev/null 2>&1 || break
        sleep 0.1
    done

    if pgrep -x CodexAwake >/dev/null 2>&1; then
        echo "An existing CodexAwake process did not terminate." >&2
        exit 1
    fi
fi

ditto "${project_dir}/build/Codex Awake.app" "${installed_app}"

temporary_plist="$(mktemp "${TMPDIR:-/tmp}/codex-awake-launch-agent.XXXXXX")"
install -m 0644 "${project_dir}/Resources/${label}.plist" "${temporary_plist}"
plutil -replace ProgramArguments \
    -json "[\"${installed_app}/Contents/MacOS/CodexAwake\"]" \
    "${temporary_plist}"
plutil -replace StandardOutPath \
    -string "${log_dir}/codex-awake-menu.out.log" \
    "${temporary_plist}"
plutil -replace StandardErrorPath \
    -string "${log_dir}/codex-awake-menu.err.log" \
    "${temporary_plist}"
plutil -lint "${temporary_plist}"
install -m 0644 "${temporary_plist}" "${launch_agent}"
rm -f -- "${temporary_plist}"

if ! defaults read "${bundle_id}" awakeMode >/dev/null 2>&1; then
    defaults write "${bundle_id}" awakeMode -string active-session
fi

launchctl bootstrap "${launch_domain}" "${launch_agent}"

echo "Installed ${installed_app}"
echo "Codex Awake is now running and will start automatically at login."
