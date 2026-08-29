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
installed_executable="${installed_app}/Contents/MacOS/CodexAwake"
restore_existing_app_on_failure=false

restore_existing_app() {
    local exit_status=$?
    if [[ "${exit_status}" -eq 0 || "${restore_existing_app_on_failure}" != true ]]; then
        return
    fi
    if [[ -x "${installed_executable}" ]]; then
        "${installed_executable}" --register-login-item >/dev/null 2>&1 || true
        /usr/bin/open -g "${installed_app}" >/dev/null 2>&1 || true
    fi
}

trap restore_existing_app EXIT

supports_login_item_cli() {
    local executable="$1"
    [[ -x "${executable}" ]] && /usr/bin/strings "${executable}" | /usr/bin/grep -q -- "--unregister-login-item"
}

stop_running_app() {
    local stale_pids
    stale_pids="$(pgrep -x CodexAwake || true)"
    if [[ -z "${stale_pids}" ]]; then
        return
    fi

    while IFS= read -r stale_pid; do
        [[ -n "${stale_pid}" ]] && kill -TERM "${stale_pid}"
    done <<< "${stale_pids}"

    for _ in {1..20}; do
        pgrep -x CodexAwake >/dev/null 2>&1 || return 0
        sleep 0.1
    done

    echo "An existing CodexAwake process did not terminate." >&2
    exit 1
}

install_legacy_fallback() {
    local temporary_plist
    temporary_plist="$(mktemp "${TMPDIR:-/tmp}/codex-awake-launch-agent.XXXXXX")"
    install -m 0644 "${project_dir}/Resources/${label}.plist" "${temporary_plist}"
    plutil -replace ProgramArguments \
        -json "[\"${installed_executable}\"]" \
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
    launchctl bootstrap "${launch_domain}" "${launch_agent}"
}

"${script_dir}/build.sh" release

mkdir -p "${applications_dir}" "${launch_agents_dir}" "${log_dir}"

if launchctl print "${launch_domain}/${label}" >/dev/null 2>&1; then
    launchctl bootout "${launch_domain}/${label}"
fi

if launchctl print "${launch_domain}/${legacy_remote_label}" >/dev/null 2>&1; then
    launchctl bootout "${launch_domain}/${legacy_remote_label}"
fi
rm -f -- "${legacy_remote_launch_agent}"

restore_existing_app_on_failure=true
if supports_login_item_cli "${installed_executable}"; then
    "${installed_executable}" --unregister-login-item >/dev/null 2>&1 || true
fi
stop_running_app

ditto "${project_dir}/build/Codex Awake.app" "${installed_app}"

if ! defaults read "${bundle_id}" awakeMode >/dev/null 2>&1; then
    defaults write "${bundle_id}" awakeMode -string active-session
fi

registration_output="$(mktemp "${TMPDIR:-/tmp}/codex-awake-registration.XXXXXX")"
registration_exit=0
"${installed_executable}" --register-login-item >"${registration_output}" 2>&1 || registration_exit=$?

case "${registration_exit}" in
    0)
        rm -f -- "${launch_agent}"
        /usr/bin/open -g "${installed_app}"
        login_message="Launch at Login is enabled through macOS Service Management."
        ;;
    2)
        rm -f -- "${launch_agent}"
        /usr/bin/open -g "${installed_app}"
        login_message="Launch at Login needs approval in System Settings > General > Login Items."
        ;;
    *)
        echo "SMAppService registration failed; using the legacy per-user LaunchAgent fallback." >&2
        sed -n '1,20p' "${registration_output}" >&2
        install_legacy_fallback
        login_message="Launch at Login is enabled through the compatibility LaunchAgent."
        ;;
esac
rm -f -- "${registration_output}"
restore_existing_app_on_failure=false

echo "Installed ${installed_app}"
echo "${login_message}"
