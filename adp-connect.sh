#!/usr/bin/env bash
# ==============================================================================
# adp-connect: sets up a developer workstation for Ohio University's ADP
# services (Rancher/Kubernetes, Artifactory, Argo CD and GitHub).
#
# NOTES FOR AI AGENTS / LLM ASSISTANTS
# ------------------------------------
# A user may ask you to "connect me to ADP" or "set up adp-connect". Read this
# block, and the "Connecting a user with adp-connect" section of AGENTS.md in
# https://github.com/ohioit/vscode-devcontainer-base, before doing anything.
#
# 1. YOU MUST NOT RUN THE SETUP YOURSELF. It needs an interactive terminal
#    (prompts, a password field) and a web browser (SSO sign-ins). Your shell
#    has neither. The only invocations you may run yourself are:
#      adp-connect -D -I     Install/update the CLI tools only. No prompts.
#      adp-connect -C [-a]   Read-only status check. No prompts, prints no
#                            secrets. Ends with "NEXT:" and "RESULT:" lines.
#    Running anything else without a terminal exits with code 2 and changes
#    nothing.
#
# 2. Procedure:
#    a. If `adp-connect` is not on PATH, install it (Windows users: inside WSL):
#         mkdir -p ~/.local/bin && curl -fsSL \
#           https://raw.githubusercontent.com/ohioit/vscode-devcontainer-base/refs/heads/main/adp-connect.sh \
#           -o ~/.local/bin/adp-connect && chmod +x ~/.local/bin/adp-connect
#       then run `adp-connect -D -I` to install the tools.
#    b. Run `adp-connect -C -a` and read the result.
#    c. Ask the user whether they want a short explanation of the services:
#         Rancher     - the user interface for Kubernetes; how you get cluster access.
#         Artifactory - where your build artifacts are stored (container
#                       images, Helm charts, packages).
#         Argo CD     - what deploys your stuff to Kubernetes.
#         GitHub      - where your code and your deployment/release workflows live.
#    d. Tell the user to run, in their own terminal (not through you):
#         adp-connect -a   if they follow common Ohio IT practices (ask
#                          someone if in doubt). This also sets up Artifactory
#                          and Argo CD, which need access that may have to be
#                          granted first.
#         adp-connect      otherwise (Rancher, Kubernetes and GitHub only).
#       Tell them to expect prompts and browser sign-ins, and to come back
#       when it finishes.
#    e. Run `adp-connect -C` (with `-a` if they used it) again to confirm.
#    Do not offer users other flags; `adp-connect -h` lists them if needed.
#
# 3. Reading results. "Expected services" are hosts on .ohio.edu plus the
#    public services this script configures by default (github.com). They
#    should work. Any other host is something the user added themselves and
#    this project knows nothing about. If only those fail, tell the user
#    their expected services are fine and the failures may not be a real
#    problem. Don't troubleshoot them unless the user asks.
#
# 4. Credentials. Never ask the user to paste tokens or passwords into chat.
#    Never pass credentials as arguments or environment variables. Never print
#    credential files (~/.kube/config, ~/.rancher/cli2.json,
#    ~/.docker/config.json, ~/.config/gh/hosts.yml, the Argo CD config).
#    Never suggest -T (trace output contains secrets).
#
# 5. Troubleshooting and bug reports: see AGENTS.md. Only ever change the
#    user's own machine, never a connected service. Bugs go to
#    https://github.com/ohioit/vscode-devcontainer-base/issues; the user
#    files the issue after reviewing your sanitized draft.
#
# Exit codes: 0 ok; 1 error, or some services could not be set up (listed in
# the final summary); 2 needs an interactive terminal; 3 (-C) something is
# missing or expired, so rerun the NEXT command; 4 (-C) only unreachable
# hosts, so rerunning will not help (check the network/VPN).
# ==============================================================================
HAVE_GUM="$(which gum &>/dev/null && echo 'true')"
TEMP_DIR=$(mktemp -d)
SCRIPT_SOURCE_BRANCH="${SCRIPT_SOURCE_BRANCH:-main}"
SCRIPT_SOURCE_URL="https://raw.githubusercontent.com/ohioit/vscode-devcontainer-base/refs/heads/${SCRIPT_SOURCE_BRANCH}/adp-connect.sh"
FORCE_UPDATE="${FORCE_UPDATE:-""}"
ENABLE_DEBUG="${ENABLE_DEBUG:-""}"
SKIP_KUBECONFIG="${SKIP_KUBECONFIG:-""}"
FORCE_ADD_MORE_RANCHERS="${FORCE_ADD_MORE_RANCHERS:-""}"
FORCE_ADD_MORE_ARGOCD="${FORCE_ADD_MORE_ARGOCD:-""}"
FORCE_ADD_MORE_GITHUB="${FORCE_ADD_MORE_GITHUB:-""}"
FORCE_TRACE_MODE="${FORCE_TRACE_MODE:-"false"}"
FORCE_CURRENT_SHELL="${FORCE_CURRENT_SHELL:-"false"}"
ONLY_DOWNLOAD="${ONLY_DOWNLOAD:-""}"
ACCEPT_SUPPLY_CHAIN_SECURITY="${ACCEPT_SUPPLY_CHAIN_SECURITY:-""}"
DEFAULT_RANCHER_HOSTNAME="rancher.oit.ohio.edu"
DEFAULT_RANCHER_AUTH_PROVIDER="azureADProvider"
DEFAULT_ARTIFACTORY_HOSTNAME="artifactory.oit.ohio.edu"
DEFAULT_ARGOCD_HOSTNAME="argo.ops.kube.ohio.edu"
DEFAULT_GITHUB_SERVERS=("github.ohio.edu" "github.com")
KUBE_CLIENT_CONFIG_SECRET="${KUBE_CLIENT_CONFIG_SECRET:-dev-client-saved-config}"
KUBE_CLIENT_CONFIG_CONTEXT="${KUBE_CLIENT_CONFIG_CONTEXT:-ais-devtest}"
SEALED_SECRETS_CONTROLLER_NAME="sealed-secrets"
SEALED_SECRETS_CONTROLLER_NAMESPACE="sealed-secrets"
SETUP_INTERNAL_SERVICES="false"
USER_OHIOID=""
ARTIFACTORY_TOKEN=""
CHECK_ONLY=""
NEEDED_RANCHER_VERSION=2.11.3
FAILED_SERVICES=()
ORIGINAL_ARGS=("$@")

HTTP_DATA_METHODS=("POST" "PUT" "PATCH")
MAIN_SCRIPT_PID="${BASHPID:-$$}"

if [[ "${FORCE_TRACE_MODE}" = "true" ]]; then
    echo "🚨 Trace mode is enabled. Its output contains credentials: do not share it or paste it into an AI tool or an issue." >&2
    set -x
fi

cleanup() {
    rm -rf "$TEMP_DIR"
    rm -rf "${HOME}/.kube/config.incomplete"
}

on_interrupt() {
    cleanup
    trap - EXIT INT TERM
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# Determine the operating system and architecture
LOCAL_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
LOCAL_ARCH=$(uname -m)
case "$LOCAL_ARCH" in
    x86_64)
        LOCAL_ARCH=("amd64" "x86_64")
        KUBECTL_ARCH="amd64"
        ;;
    *)
        # shellcheck disable=SC2128
        KUBECTL_ARCH="${LOCAL_ARCH}"
        # shellcheck disable=SC2128
        LOCAL_ARCH=("${LOCAL_ARCH}")
        ;;
esac


log() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log "$1"
    else
        echo -e "$1"
    fi
}

gum() {
    command gum "$@"
    local rc=$?

    # Ctrl+C from gum prompts should terminate this script.
    if [[ ${rc} -eq 130 ]]; then
        # If we're in a subshell (for example command substitution), signal
        # the main script process so it exits too.
        if [[ ${BASH_SUBSHELL:-0} -gt 0 ]] || [[ ${ZSH_SUBSHELL:-0} -gt 0 ]]; then
            kill -INT "${MAIN_SCRIPT_PID}" 2>/dev/null
            return ${rc}
        fi

        on_interrupt
    fi

    return ${rc}
}

debug() {
    if [[ "${ENABLE_DEBUG}" ]]; then
        if [[ "${HAVE_GUM}" ]]; then
            gum log -l debug "$1"
        else
            echo -e "\e[34m$1\e[0m"
        fi
    fi
}

info() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log -l info "$1"
    else
        echo -e "\e[36m$1\e[0m"
    fi
}

instruction() {
    if [[ "${HAVE_GUM}" ]]; then
        gum style \
                --border-foreground=212 \
                --border=double \
                --align=center \
                --width=70 \
                --margin="1 2" \
                --padding="2 4 " "$1" >&2
    else
        echo -e "\e[35mℹ️ $1\e[0m" >&2
    fi
}

warn() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log -l warn "$1"
    else
        echo -e "\e[33m$1\e[0m"
    fi
}

error() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log -l error "$1"
    else
        echo -e "\e[31m$1\e[0m"
    fi
}

confirm() {
    if [[ "${HAVE_GUM}" ]]; then
        gum confirm --default=No "$1"
    else
        REPLY=""

        while true; do
            echo -n "$1 [y/N] "
            # shellcheck disable=SC2162
            read REPLY
            echo

            if [[ -z "${REPLY}" ]]; then
                REPLY="Y"
            fi

            if [[ "${REPLY}" =~ ^[YyNn]$ ]]; then
                break
            fi

            echo "${REPLY} is not valid, please enter Y or N"
        done

        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

get_ohioid() {
    info "Please enter your OHIO ID for logging into services."
    gum input --width=80 --placeholder="OHIO ID"
}

get_artifactory_token() {
    local artifactory_info
    artifactory_info=$(cat <<-'EOF'
	🐳 It's time to login to Artifactory.

    Go to https://artifactory.oit.ohio.edu and login with
    SAML SSO (button on the bottom). Once you've logged in,
    click on your username in the top right and select:

	→ Edit Profile
    → Generate an Identity Token. You cannot reuse an existing one.
    → Copy the Reference Token and paste it here (click the icon next to the field to copy it).
EOF
    )

    instruction "${artifactory_info}"
    ARTIFACTORY_TOKEN="$(gum input --password --width=80 --placeholder="Artifactory Token")"

    echo "${ARTIFACTORY_TOKEN}" | tr -d '[:space:]'
}

compare_versions() {
    # Remove leading 'v'/'V' if present and compare numerically.
    local ver1="${1#v}"
    local ver2="${2#v}"
    ver1="${ver1#V}"
    ver2="${ver2#V}"

    local ver1_major ver1_minor ver1_patch
    local ver2_major ver2_minor ver2_patch

    ver1_major=$(echo "${ver1}" | cut -d. -f1)
    ver1_minor=$(echo "${ver1}" | cut -d. -f2)
    ver1_patch=$(echo "${ver1}" | cut -d. -f3)

    ver2_major=$(echo "${ver2}" | cut -d. -f1)
    ver2_minor=$(echo "${ver2}" | cut -d. -f2)
    ver2_patch=$(echo "${ver2}" | cut -d. -f3)

    # Treat missing segments as 0.
    ver1_major="${ver1_major:-0}"
    ver1_minor="${ver1_minor:-0}"
    ver1_patch="${ver1_patch:-0}"
    ver2_major="${ver2_major:-0}"
    ver2_minor="${ver2_minor:-0}"
    ver2_patch="${ver2_patch:-0}"

    if (( 10#${ver1_major} > 10#${ver2_major} )); then
        return 1
    elif (( 10#${ver1_major} < 10#${ver2_major} )); then
        return 2
    fi

    if (( 10#${ver1_minor} > 10#${ver2_minor} )); then
        return 1
    elif (( 10#${ver1_minor} < 10#${ver2_minor} )); then
        return 2
    fi

    if (( 10#${ver1_patch} > 10#${ver2_patch} )); then
        return 1
    elif (( 10#${ver1_patch} < 10#${ver2_patch} )); then
        return 2
    fi

    return 0
}

version_sort() {
    # IMPORTANT: This function will only sort versions in the format of x.y.z
    # with an optional lowercase `v` prefix. It will break on other strings.
    #
    # It should work fine whether or not the versions are separated by spaces
    # or newlines but it will always return a list separated by newlines.
    echo "${@}" | tr ' ' '\n' | sed 's/v//g' | awk -F. '{ printf("%d.%d.%d\n", $1, $2, $3) }' | sort -t. -k1,1n -k2,2n -k3,3n
}

call_rancher() {
    local token="$1"
    local url="$2"
    local method="${3:-GET}"
    local data="$4"

    if [[ ${HTTP_DATA_METHODS[*]} =~ $method ]]; then
        RESPONSE=$(curl -s -X "$method" -H "Authorization: Bearer ${token}" -H "Accept: application/json" -H "Content-Type: application/json" -d "$data" "$url")
        RETURN=$?
    else
        RESPONSE=$(curl -s -H "Authorization: Bearer ${token}" -H "Accept: application/json" "$url")
        RETURN=$?
    fi

    if [[ $RETURN -ne 0 ]]; then
        error "❌ Error: Failed to call Rancher API at $url. Error code $RETURN." >&2
        return 1
    fi

    if [[ "$(yq -r '.type' <<< "$RESPONSE")" == "error" ]]; then
        error "❌ $(yq -r '.message' <<< "$RESPONSE")" >&2
        return 1
    fi

    printf '%s' "$RESPONSE"
}

download_latest_release() {
    local repo="$1"
    local binary_name="$2"
    local format="$3"

    local arch
    local latest_release_json
    local checksum_files=("checksums" "checksums.txt" "sha256sum" "sha256sum.txt")
    local checksum_url
    local binary_url

    if [[ -n "${format}" ]]; then
        format=".$format"
    fi

    info "🔍 Searching for the latest release of $binary_name from $repo..."

    latest_release_json=$(curl -s "https://api.github.com/repos/$repo/releases/latest")
    latest_release=$(printf '%s' "${latest_release_json}" | grep -e '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

    for arch in "${LOCAL_ARCH[@]}"; do
        if [[ -n "$format" ]]; then
            debug "Searching for $format package..."
            binary_url=$(printf '%s' "$latest_release_json" | grep -Ei "browser_download_url.*$binary_name.*$LOCAL_OS.*$arch(.*$latest_release)?(\.|$format)\"" | cut -d '"' -f 4)
        else
            debug "Searching for uncompressed binary..."
            binary_url=$(printf '%s' "$latest_release_json" | grep -Ei "browser_download_url.*$binary_name.*$LOCAL_OS.*$arch(.*$latest_release)?\"" | cut -d '"' -f 4)
        fi

        if [[ -n "$binary_url" ]]; then
            break
        fi
    done

    if [[ -z "$binary_url" ]]; then
        error "❌ Error: Could not find the binary $binary_name for $LOCAL_OS/${LOCAL_ARCH[0]} in the latest release."

        if [[ "${ENABLE_DEBUG}" = "true" ]]; then
            if which yq &>/dev/null; then
                debug "JSON from GitHub:"
                yq -P -C -o json <<< "${latest_release_json}"
            else
                debug "JSON from GitHub:"
                printf '%s' "${latest_release_json}"
            fi
        fi

	    return 1
    fi

    binary_download_name="$(basename "${binary_url}")"

    if [[ -n "${HAVE_GUM}" ]]; then
        gum spin --show-error --show-output --title="Downloading $binary_name for $LOCAL_OS/$arch..." -- \
            curl -sL --show-error "$binary_url" -o "${TEMP_DIR}/${binary_download_name}"
    else
        info "🔗 Downloading $binary_name for $LOCAL_OS/$arch..."
        curl -L --show-error "$binary_url" -o "${TEMP_DIR}/${binary_download_name}"
    fi

    for checksum_file in "${checksum_files[@]}"; do
        checksum_url=$(printf '%s' "$latest_release_json" | grep -E "browser_download_url.*$checksum_file\"" | cut -d '"' -f 4)

        if [[ -n "$checksum_url" ]]; then
            break
        fi
    done

    if [[ -n "$checksum_url" ]] && ! [[ "${INSANE_CHECKSUMS}" = "true" ]]; then
        if [[ -n "${HAVE_GUM}" ]]; then
            gum spin --show-error --show-output --title="Downloading checksums..." -- \
                curl -sL --show-error "$checksum_url" -o "${TEMP_DIR}/${binary_name}_checksums"
        else
            info "🔗 Downloading checksums..."
            curl -L --show-error "$checksum_url" -o "${TEMP_DIR}/${binary_name}_checksums"
        fi

        if ! [[ -f "${TEMP_DIR}/${binary_name}_checksums" ]]; then
            error "❌  Error: Failed to download checksums."
            return 1
        fi

        pushd "${TEMP_DIR}" 1>/dev/null || return 1
        checksum_output=$(sha256sum --ignore-missing -c "${TEMP_DIR}/${binary_name}_checksums" 2>&1)
        popd 1>/dev/null || return 1
        grep -q "OK" <<< "$checksum_output"
        check_result=$?
        rm "${TEMP_DIR}/${binary_name}_checksums"

        if ! [[ ${check_result} -eq 0 ]]; then
            error "❌ Checksum of ${binary_name} verification failed: ${checksum_output}"
            return 1
        fi

    else
        warn "⚠️  Warning: No checksums available for verification."
    fi

    mv "${TEMP_DIR}/${binary_download_name}" "${TEMP_DIR}/${binary_name}$format"
}

extract_download() {
    local binary_name="$1"
    local format="$2"

    info "📦 Extracting $binary_name..."
    case "$format" in
        tar.gz)
            tar -C "$TEMP_DIR" -xzf "${TEMP_DIR}/${binary_name}.$format"
            rm "${TEMP_DIR}/${binary_name}.$format"
            ;;
        tar.xz)
            tar -C "$TEMP_DIR" -xf "${TEMP_DIR}/${binary_name}.$format"
            rm "${TEMP_DIR}/${binary_name}.$format"
            ;;
        *)
            error "❌ Error: Unsupported format $format."
            return 1
            ;;
    esac
}

should_install() {
    local binary_name="$1"

    if [[ -n "${FORCE_UPDATE}" ]]; then
        return 0
    fi

    if which "$binary_name" &>/dev/null; then
        debug "👍 $binary_name is already installed."
        return 1
    fi

    return 0
}

is_in_array() {
    local needle="$1"
    shift

    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

rancher_current_server() {
    yq -r '.CurrentServer' < "$HOME/.rancher/cli2.json"
}

# Print the Rancher CLI configuration with credentials masked, for debug output.
print_rancher_config_redacted() {
    yq '(.. | select(key == "accessKey" or key == "secretKey" or key == "tokenKey")) = "REDACTED"' \
        "$HOME/.rancher/cli2.json"
}

# Pick the login provider for a Rancher server from the providers it has
# enabled (a public, unauthenticated endpoint), so users don't have to choose:
#   1. DEFAULT_RANCHER_AUTH_PROVIDER, if the server offers it;
#   2. otherwise its only single sign-on provider, if it has exactly one;
#   3. otherwise the local provider, if that's all it offers.
# Prints nothing when it can't decide, and the Rancher CLI then asks.
rancher_auth_provider() {
    local host="$1"
    local providers sso_providers

    providers=$(with_spinner "Checking how to sign in to ${host}..." \
        curl -s --connect-timeout 5 --max-time 10 -H "Accept: application/json" \
        "https://${host}/v3-public/authProviders" 2>/dev/null | \
        yq -p json -o json -r '.data[].type' 2>/dev/null | grep -E '^[A-Za-z]+Provider$')

    if [[ -z "${providers}" ]]; then
        # Couldn't ask the server; fall back to the default for the default server only.
        if [[ "${host}" = "${DEFAULT_RANCHER_HOSTNAME}" ]]; then
            printf '%s' "${DEFAULT_RANCHER_AUTH_PROVIDER}"
        fi
        return 0
    fi

    if [[ -n "${DEFAULT_RANCHER_AUTH_PROVIDER}" ]] && printf '%s\n' "${providers}" | grep -qxF "${DEFAULT_RANCHER_AUTH_PROVIDER}"; then
        printf '%s' "${DEFAULT_RANCHER_AUTH_PROVIDER}"
        return 0
    fi

    sso_providers=$(printf '%s\n' "${providers}" | grep -vx 'localProvider')
    if [[ -n "${sso_providers}" ]] && [[ "$(printf '%s\n' "${sso_providers}" | wc -l | tr -d ' ')" = "1" ]]; then
        printf '%s' "${sso_providers}"
    elif [[ -z "${sso_providers}" ]]; then
        printf '%s' "localProvider"
    fi
}

RANCHER_CONFIG_BACKED_UP=""
RANCHER_CONFIG_BACKUPS_TO_KEEP=3

# Copy the Rancher CLI config aside once per run before this script changes it.
backup_rancher_config() {
    local backup

    if [[ -n "${RANCHER_CONFIG_BACKED_UP}" ]] || ! [[ -f "$HOME/.rancher/cli2.json" ]]; then
        return 0
    fi

    backup="$HOME/.rancher/cli2.json.adp-connect-backup.$(date +%Y%m%d%H%M%S)"
    cp -p "$HOME/.rancher/cli2.json" "${backup}" && chmod 600 "${backup}" && RANCHER_CONFIG_BACKED_UP="${backup}"
    info "Backed up your Rancher CLI configuration to ${backup}."

    # Keep only the newest few backups. The timestamp suffix sorts chronologically.
    find "$HOME/.rancher" -maxdepth 1 -name 'cli2.json.adp-connect-backup.*' -type f 2>/dev/null | sort -r | \
        tail -n +$((RANCHER_CONFIG_BACKUPS_TO_KEEP + 1)) | while IFS= read -r old_backup; do
            rm -f "${old_backup}"
        done
}

# Returns 0 if the Rancher CLI config file is readable JSON with a Servers map.
rancher_config_parses() {
    [[ "$(yq -p json -o json -r '.Servers | type' "$HOME/.rancher/cli2.json" 2>/dev/null)" = "!!map" ]]
}

# Prints why the saved Rancher CLI entry for a server can't be used, or nothing
# if it looks complete. Never prints the values themselves.
rancher_entry_problem() {
    local server="$1"
    local config="$HOME/.rancher/cli2.json"
    local entry_url entry_token entry_project

    if ! rancher_config_parses; then
        echo "the Rancher CLI configuration file can't be parsed"
        return
    fi

    if [[ "$(yq -p json -o json -r '.Servers["'"${server}"'"] | type' "${config}" 2>/dev/null)" != "!!map" ]]; then
        echo "its entry is missing or not a valid object"
        return
    fi

    entry_url=$(yq -p json -o json -r '.Servers["'"${server}"'"].url // ""' "${config}" 2>/dev/null)
    entry_token=$(yq -p json -o json -r '.Servers["'"${server}"'"].tokenKey // ""' "${config}" 2>/dev/null)
    entry_project=$(yq -p json -o json -r '.Servers["'"${server}"'"].project // ""' "${config}" 2>/dev/null)

    if ! [[ "${entry_url}" =~ ^https?://[^/]+ ]]; then
        echo "its entry has no valid URL"
    elif [[ -z "${entry_token}" ]]; then
        echo "its entry has no saved token"
    elif ! [[ "${entry_project}" =~ ^[a-z0-9-]+:[a-z0-9-]+$ ]]; then
        echo "its entry has no valid project (context)"
    fi

    entry_token=""
}

# Remove one server's entry from the Rancher CLI config (after a backup).
remove_rancher_entry() {
    local server="$1"

    backup_rancher_config
    if ! rancher server delete "${server}" &>/dev/null; then
        yq -i -p json -o json 'del(.Servers["'"${server}"'"])' "$HOME/.rancher/cli2.json"
    fi
}

# Run a command with a spinner so slow network calls don't look like a hang.
# Exit code and stdout pass through. Without gum or a terminal it just runs.
with_spinner() {
    local title="$1"
    shift

    if [[ "${HAVE_GUM}" ]] && [ -t 2 ]; then
        gum spin --show-error --title="${title}" -- "$@"
    else
        "$@"
    fi
}

# Returns 0 if https://<host><path> answers at all (any HTTP status), showing
# a spinner meanwhile.
host_reachable() {
    local rc

    with_spinner "Checking whether $1 can be reached..." \
        curl -s -o /dev/null --connect-timeout 5 --max-time 10 "https://$1$2"
    rc=$?

    [[ ${rc} -ne 6 ]] && [[ ${rc} -ne 7 ]] && [[ ${rc} -ne 28 ]] && [[ ${rc} -ne 35 ]]
}

rancher_host_reachable() {
    host_reachable "$1" "/ping"
}

# Ask whether to retry servers that couldn't be reached. Returns 0 to retry.
ask_retry_unreachable() {
    local kind="$1"
    shift

    warn "Couldn't reach these ${kind} servers: $*"
    [[ "$(gum choose --header="Some servers may only be reachable on a specific VPN. Connect to it first if you need them." \
        "Try again" "Continue without them")" = "Try again" ]]
}

# Sign in to one GitHub server.
# Returns 0 if signed in, 1 if sign-in failed, 2 if it couldn't be reached.
github_login() {
    local host="$1"

    if ! host_reachable "${host}"; then
        return 2
    fi

    # shellcheck disable=SC2016
    if with_spinner "Checking your sign-in to ${host}..." \
        sh -c 'gh auth status --hostname="$1" > /dev/null 2>&1' _ "${host}"; then
        info "🎉 You're already authenticated to ${host}!"
        return 0
    fi

    info "🔐 Authenticating to ${host}..."
    if gh auth login --hostname="${host}" --web; then
        info "🎉 You're successfully authenticated to ${host}!"
        return 0
    fi

    record_failure "GitHub ${host}: login failed."
    return 1
}

# Validate one configured Rancher server, logging in again if needed.
# Returns 0 if usable, 1 if it failed, 2 if it couldn't be reached.
validate_rancher_server() {
    local server="$1"
    local entry_problem

    if ! rancher_host_reachable "${server}"; then
        return 2
    fi

    entry_problem=$(rancher_entry_problem "${server}")
    if [[ -n "${entry_problem}" ]]; then
        warn "🚨 The saved Rancher configuration for ${server} is broken (${entry_problem}). Logging in again."
        remove_rancher_entry "${server}"

        if ! rancher_login "${server}"; then
            record_failure "Rancher ${server}: its saved configuration was broken and logging in again failed. Skipping."
            return 1
        fi
    fi

    if ! rancher server switch "${server}" 2> >(grep -v "Saving config" >&2) >/dev/null; then
        record_failure "Rancher ${server}: could not switch to this server. Skipping."
        return 1
    fi

    if ! with_spinner "Checking ${server}..." rancher project list >/dev/null; then
        yq -i '.Servers["'"${server}"'"].project = ""' "$HOME/.rancher/cli2.json"

        # Only keep the server for the rest of the setup if logging in again
        # actually worked, otherwise kubeconfig generation would use it.
        if ! rancher_login "${server}" || \
           ! rancher server switch "${server}" 2> >(grep -v "Saving config" >&2) >/dev/null || \
           ! with_spinner "Checking ${server}..." rancher project list >/dev/null; then
            record_failure "Rancher ${server}: login failed. Skipping."
            return 1
        fi
    fi

    return 0
}

# Let the user pick their default Rancher server. Servers skipped earlier in
# this run are still listed, so nobody wonders where they went, but picking one
# explains why it can't be used instead of hanging on it.
select_default_rancher_server() {
    local server choice
    local -a options

    options=()
    for server in $(yq -r '.Servers | to_entries[] | .key' < "$HOME/.rancher/cli2.json" | grep -v rancherDefault); do
        if is_in_array "${server}" "${REACHABLE_RANCHER_SERVERS[@]}"; then
            options+=("${server}")
        else
            options+=("${server} (skipped: not reachable)")
        fi
    done

    while true; do
        choice=$(printf '%s\n' "${options[@]}" | gum choose --select-if-one --header="Select your default Rancher server:")

        if [[ -z "${choice}" ]]; then
            continue
        fi

        if [[ "${choice}" == *" (skipped: not reachable)" ]]; then
            warn "${choice%" (skipped: not reachable)"} couldn't be reached earlier in this run, so it can't be your default right now. \
If it needs a VPN, connect to it and run adp-connect again. Otherwise, pick another server."
            continue
        fi

        with_spinner "Switching to ${choice}..." rancher server switch "${choice}" 2> >(grep -v "Saving config" >&2) >/dev/null
        return $?
    done
}

# Rancher servers that don't put tokens in kubeconfigs generate kubeconfig users
# that run `rancher token --server=<server> --user=<cluster name>` as a credential
# plugin. The Rancher CLI caches that credential under "<user>_<cluster>[_<provider>]",
# so the plugin's key ("<cluster name>_") never matches the one rancher_login uses
# ("<OS user>__<provider>"). That means a second sign-in, and two credentials that
# expire and refresh separately. Point the plugin at the same user and provider
# rancher_login uses, so one credential per server serves both and is refreshed
# in one place. Entries that don't look like what Rancher generates are left
# alone with a warning.
align_rancher_exec_users() {
    local kubeconfig="$1"
    local server="$2"
    local provider="$3"
    local exec_user exec_args expected_args new_args

    for exec_user in $(yq -r '.users[] | select((.user.exec.command // "") | test("(^|/)rancher$")) | .name' "${kubeconfig}"); do
        exec_args=$(U="${exec_user}" yq -o json -I0 '.users[] | select(.name == strenv(U)) | .user.exec.args // []' "${kubeconfig}")
        expected_args=$(S="${server}" U="${exec_user}" yq -n -o json -I0 '["token", "--server=" + strenv(S), "--user=" + strenv(U)]')

        if [[ "${exec_args}" != "${expected_args}" ]]; then
            warn "The kubeconfig user ${exec_user} from ${server} signs in with unexpected Rancher CLI arguments, so it was left as-is. You may be asked to sign in again when you use it."
            continue
        fi

        new_args=$(S="${server}" W="$(whoami)" P="${provider}" yq -n -o json -I0 \
            '["token", "--server=" + strenv(S), "--user=" + strenv(W)] + (if strenv(P) == "" then [] else ["--auth-provider=" + strenv(P)] end)')
        U="${exec_user}" A="${new_args}" yq -i '(.users[] | select(.name == strenv(U)) | .user.exec.args) = (strenv(A) | from_json)' "${kubeconfig}"
        debug "Pointed kubeconfig user ${exec_user} at the Rancher CLI login for ${server}."
    done
}

# Record a service that could not be set up so the run can continue and the
# failure can be listed in the final summary.
record_failure() {
    warn "⚠️  $1"
    FAILED_SERVICES+=("$1")
}

# ------------------------------------------------------------------------------
# Status check (-C). Read-only, needs no terminal, and must never print
# credentials, usernames, emails or file contents. Every host is treated the
# same way.
# ------------------------------------------------------------------------------
STATUS_NEEDS_RERUN="false"
STATUS_UNREACHABLE="false"

status_line() {
    local key="$1"
    local status="$2"

    printf '%-60s %s\n' "${key}:" "${status}"

    case "${status}" in
        missing*|expired*) STATUS_NEEDS_RERUN="true" ;;
        unreachable*) STATUS_UNREACHABLE="true" ;;
    esac
}

# Print-only variant for informational lines that must not affect the result.
status_info() {
    printf '%-60s %s\n' "$1:" "$2"
}

# Returns 0 if https://<host> answers at all (any HTTP status), 1 otherwise.
status_host_reachable() {
    local url="$1"
    local rc

    curl -s -o /dev/null --connect-timeout 5 --max-time 10 "${url}"
    rc=$?

    [[ ${rc} -ne 6 ]] && [[ ${rc} -ne 7 ]] && [[ ${rc} -ne 28 ]] && [[ ${rc} -ne 35 ]]
}

# Classify a failed command's stderr as an auth problem or a network problem.
status_classify_error() {
    if printf '%s' "$1" | grep -qiE 'unauthori[sz]ed|unauthenticated|forbidden|401|403|expired|invalid session|credentials|token'; then
        echo "expired"
    else
        echo "unreachable"
    fi
}

script_checksum() {
    if ! [[ -f "$0" ]]; then
        echo "unknown"
    elif which sha256sum &>/dev/null; then
        sha256sum "$0" | awk '{ print $1 }'
    elif which shasum &>/dev/null; then
        shasum -a 256 "$0" | awk '{ print $1 }'
    else
        echo "unknown"
    fi
}

run_status_check() {
    local tool server token http_code output rc host context cluster
    local next_command="adp-connect"
    local repo line
    local -a rancher_servers github_servers contexts argocd_lines

    if [[ "${SETUP_INTERNAL_SERVICES}" = "true" ]]; then
        next_command="adp-connect -a"
    fi

    echo "[environment]"
    status_info "os" "${LOCAL_OS}/$(uname -m)"
    status_info "shell" "$(basename "${SHELL:-unknown}")"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        status_info "wsl" "yes"
    else
        status_info "wsl" "no"
    fi
    if printf '%s' ":${PATH}:" | grep -q ":${HOME}/.local/bin:"; then
        status_info "path.local_bin" "ok"
    else
        status_line "path.local_bin" "missing (add \$HOME/.local/bin to PATH)"
    fi
    if ! which yq &>/dev/null; then
        status_line "yq" "missing"
    elif yq --version 2>/dev/null | grep -q mikefarah; then
        status_info "yq" "ok"
    else
        status_line "yq" "missing (an incompatible yq is installed; remove it)"
    fi
    if which rancher &>/dev/null; then
        compare_versions "$(rancher --version | awk '{ print $3 }')" "${NEEDED_RANCHER_VERSION}"
        if [[ "$?" = "2" ]]; then
            status_line "rancher.version" "expired (older than ${NEEDED_RANCHER_VERSION}; a rerun upgrades it)"
        else
            status_info "rancher.version" "ok"
        fi
    fi
    if ! which docker &>/dev/null; then
        status_info "docker" "not installed"
    elif docker ps &>/dev/null; then
        status_info "docker" "running"
    else
        status_info "docker" "not running or not accessible"
    fi
    if which xdg-open &>/dev/null || which open &>/dev/null; then
        status_info "browser_opener" "ok"
    else
        status_info "browser_opener" "missing (browser sign-ins must be done by copying URLs)"
    fi
    if status_host_reachable "https://${DEFAULT_RANCHER_HOSTNAME}/ping"; then
        status_info "network.${DEFAULT_RANCHER_HOSTNAME}" "ok"
    else
        status_line "network.${DEFAULT_RANCHER_HOSTNAME}" "unreachable (check VPN/network)"
    fi
    status_info "adp-connect.sha256" "$(script_checksum)"

    echo
    echo "[services]"
    for tool in gum yq rancher kubectl kubeseal helm skaffold gh; do
        if which "${tool}" &>/dev/null; then
            status_info "tool.${tool}" "ok"
        else
            status_line "tool.${tool}" "missing"
        fi
    done
    if [[ "${SETUP_INTERNAL_SERVICES}" = "true" ]]; then
        if which argocd &>/dev/null; then
            status_info "tool.argocd" "ok"
        else
            status_line "tool.argocd" "missing"
        fi
    fi

    # Rancher
    rancher_servers=()
    if [[ -f "$HOME/.rancher/cli2.json" ]] && which yq &>/dev/null && ! rancher_config_parses; then
        status_line "rancher.config" "missing (the Rancher CLI config can't be parsed; a rerun backs it up and starts over)"
    elif [[ -f "$HOME/.rancher/cli2.json" ]] && which yq &>/dev/null; then
        while IFS= read -r server; do
            [[ -n "${server}" ]] && rancher_servers+=("${server}")
        done < <(yq -r '.Servers | to_entries[] | .key' "$HOME/.rancher/cli2.json" 2>/dev/null | grep -v rancherDefault)
    fi

    if [[ ${#rancher_servers[@]} -eq 0 ]]; then
        status_line "rancher" "missing (no Rancher servers configured)"
    fi

    for server in "${rancher_servers[@]}"; do
        output=$(rancher_entry_problem "${server}")
        if [[ -n "${output}" ]]; then
            status_line "rancher.${server}" "missing (saved config is broken: ${output}; a rerun repairs it)"
            continue
        fi

        if ! status_host_reachable "https://${server}/ping"; then
            status_line "rancher.${server}" "unreachable"
            continue
        fi

        token=$(yq -r '.Servers["'"${server}"'"].tokenKey // ""' "$HOME/.rancher/cli2.json" 2>/dev/null)

        # Pass the token on stdin so it never appears in the process list.
        http_code=$(printf 'Authorization: Bearer %s\n' "${token}" | \
            curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
                -H @- -H "Accept: application/json" "https://${server}/v3/users?me=true")
        token=""

        case "${http_code}" in
            2*) status_line "rancher.${server}" "ok" ;;
            401|403) status_line "rancher.${server}" "expired" ;;
            *) status_line "rancher.${server}" "unreachable (HTTP ${http_code})" ;;
        esac
    done

    # Kubernetes. `kubectl config view` redacts credentials by default.
    if which kubectl &>/dev/null && [[ -f "$HOME/.kube/config" ]]; then
        contexts=()
        while IFS= read -r context; do
            [[ -n "${context}" ]] && contexts+=("${context}")
        done < <(command kubectl config get-contexts -o name 2>/dev/null)

        if [[ ${#contexts[@]} -eq 0 ]]; then
            status_line "kubernetes" "missing (no contexts configured)"
        fi

        for context in "${contexts[@]}"; do
            # The -fqdn contexts point at the same clusters directly; skip them like the
            # Sealed Secrets setup does.
            [[ "${context}" =~ -fqdn$ ]] && continue

            cluster=$(command kubectl config view -o jsonpath='{.contexts[?(@.name=="'"${context}"'")].context.cluster}' 2>/dev/null)
            host=$(command kubectl config view -o jsonpath='{.clusters[?(@.name=="'"${cluster}"'")].cluster.server}' 2>/dev/null | sed -e 's|^[a-zA-Z]*://||' -e 's|[:/].*||')

            # Contexts whose credentials come from a plugin (e.g. `rancher token`) could
            # start an interactive sign-in, which a status check must never do.
            if [[ -n "$(command kubectl config view -o jsonpath='{.users[?(@.name=="'"$(command kubectl config view -o jsonpath='{.contexts[?(@.name=="'"${context}"'")].context.user}' 2>/dev/null)"'")].user.exec.command}' 2>/dev/null)" ]]; then
                status_info "kubernetes.${context} (${host})" "not checked (signs in through a credential plugin)"
                continue
            fi

            output=$(command kubectl --context="${context}" --request-timeout=5s get --raw /version 2>&1 >/dev/null)
            rc=$?

            if [[ ${rc} -eq 0 ]]; then
                status_line "kubernetes.${context} (${host})" "ok"
            else
                status_line "kubernetes.${context} (${host})" "$(status_classify_error "${output}")"
            fi
        done

        status_info "kubernetes.current_context" "$(command kubectl config current-context 2>/dev/null || echo none)"
        if [[ -n "$(command kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)" ]]; then
            status_info "kubernetes.current_namespace" "$(command kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)"
        else
            status_line "kubernetes.current_namespace" "missing"
        fi
    elif [[ -z "${SKIP_KUBECONFIG}" ]]; then
        status_line "kubernetes" "missing (no kubeconfig)"
    fi

    # GitHub
    github_servers=("${DEFAULT_GITHUB_SERVERS[@]}")
    if [[ -f "$HOME/.config/gh/hosts.yml" ]] && which yq &>/dev/null; then
        while IFS= read -r host; do
            if [[ -n "${host}" ]] && ! is_in_array "${host}" "${github_servers[@]}"; then
                github_servers+=("${host}")
            fi
        done < <(yq -r '. | keys | .[]' "$HOME/.config/gh/hosts.yml" 2>/dev/null)
    fi

    for host in "${github_servers[@]}"; do
        if ! which gh &>/dev/null; then
            status_line "github.${host}" "missing (gh not installed)"
        elif ! status_host_reachable "https://${host}"; then
            status_line "github.${host}" "unreachable"
        elif gh auth status --hostname="${host}" &>/dev/null; then
            status_line "github.${host}" "ok"
        else
            status_line "github.${host}" "missing (not signed in)"
        fi
    done

    if git config --global --get user.name &>/dev/null; then
        status_info "git.user.name" "set"
    else
        status_line "git.user.name" "missing"
    fi
    if git config --global --get user.email &>/dev/null; then
        status_info "git.user.email" "set"
    else
        status_line "git.user.email" "missing"
    fi

    if [[ "${SETUP_INTERNAL_SERVICES}" = "true" ]]; then
        # Artifactory: Docker registry
        host="docker.${DEFAULT_ARTIFACTORY_HOSTNAME}"
        if ! which docker &>/dev/null || ! docker ps &>/dev/null; then
            status_line "artifactory.docker (${host})" "missing (docker is not installed or not running)"
        elif ! status_host_reachable "https://${host}"; then
            status_line "artifactory.docker (${host})" "unreachable"
        elif docker login "${host}" <<< "" &>/dev/null; then
            status_line "artifactory.docker (${host})" "ok"
        else
            status_line "artifactory.docker (${host})" "missing (not logged in)"
        fi

        # Artifactory: Helm repositories
        for repo in artifactory artifactory-push; do
            if ! which helm &>/dev/null; then
                status_line "artifactory.helm.${repo} (${DEFAULT_ARTIFACTORY_HOSTNAME})" "missing (helm not installed)"
            elif helm search repo "${repo}" --fail-on-no-result -o yaml &>/dev/null; then
                status_line "artifactory.helm.${repo} (${DEFAULT_ARTIFACTORY_HOSTNAME})" "ok"
            else
                status_line "artifactory.helm.${repo} (${DEFAULT_ARTIFACTORY_HOSTNAME})" "missing"
            fi
        done

        # Argo CD. `--argocd-context` avoids switching the user's current context.
        if which argocd &>/dev/null; then
            argocd_lines=()
            # `argocd context` fails with "No local configuration found" when nothing is set up.
            if output=$(argocd context 2>/dev/null); then
                while IFS= read -r line; do
                    [[ -n "${line// /}" ]] && argocd_lines+=("${line}")
                done < <(printf '%s\n' "${output}" | grep -v '^CURRENT' | sed 's/^\*//')
            fi

            if [[ ${#argocd_lines[@]} -eq 0 ]]; then
                status_line "argocd" "missing (no Argo CD servers configured)"
            fi

            for line in "${argocd_lines[@]}"; do
                context=$(printf '%s' "${line}" | awk '{ print $1 }')
                host=$(printf '%s' "${line}" | awk '{ print $2 }' | sed 's|:.*||')

                output=$(argocd version --argocd-context "${context}" --grpc-web 2>&1 >/dev/null)
                rc=$?

                if [[ ${rc} -eq 0 ]]; then
                    status_line "argocd.${context} (${host})" "ok"
                else
                    status_line "argocd.${context} (${host})" "$(status_classify_error "${output}")"
                fi
            done
        fi
    fi

    echo
    if [[ "${STATUS_NEEDS_RERUN}" = "true" ]]; then
        echo "NEXT: ${next_command}"
        echo "RESULT: action-needed"
        return 3
    elif [[ "${STATUS_UNREACHABLE}" = "true" ]]; then
        echo "NEXT: none (rerunning will not help; some hosts are unreachable)"
        echo "RESULT: unreachable-only"
        return 4
    fi

    echo "NEXT: none"
    echo "RESULT: ok"
    return 0
}

rancher_login() {
    local rancher_hostname="$1"
    local rancher_token=""
    local rancher_project=""
    local current_server=""
    local login_result=0
    local entry_problem=""
    local auth_provider=""

    debug "Logging into $rancher_hostname"

    if [[ -z "$rancher_hostname" ]]; then
        error "❌ Error: No Rancher hostname provided."
        exit 1
    fi

    if [[ "${ENABLE_DEBUG}" = "true" ]]; then
        if [[ -f "$HOME/.rancher/cli2.json" ]]; then
            debug "Current Rancher configuration before token:"
            print_rancher_config_redacted
        else
            debug "No Rancher configuration before token."
        fi
    fi

    # Remove protocol if present
    # shellcheck disable=SC2001
    rancher_hostname=$(printf '%s' "$rancher_hostname" | sed -e 's|^[a-zA-Z]*://||')

    if [[ -e "${HOME}/.rancher/cli2.json" ]] && [[ "$(rancher server ls | grep -cF "${rancher_hostname}")" -gt 1 ]]; then
        warn "🚨 Multiple Rancher servers are configured with the hostname ${rancher_hostname}. Cleaning that up."

        backup_rancher_config
        for SERVER in $(rancher server ls | grep -F "${rancher_hostname}" | sed 's/^*//' | awk '{ print $1 }'); do
            rancher server delete "${SERVER}"
        done
    fi

    instruction "It's time to login to Rancher at ${rancher_hostname}. Look below for a token and a URL. Go to the URL in any browser \
(CTRL+Click on the link in most terminals) and enter the token provided. It may take a second after completing the login process for the CLI to notice and continue."
    warn "If you see a URL below that contains the string 'authProviders', ignore it."

    auth_provider=$(rancher_auth_provider "${rancher_hostname}")
    debug "Using auth provider '${auth_provider:-<ask>}' for ${rancher_hostname}"

    if [[ -n "${auth_provider}" ]]; then
        rancher_token_credential=$(rancher token --server "${rancher_hostname}" --user="$(whoami)" --auth-provider="${auth_provider}")
    else
        rancher_token_credential=$(rancher token --server "${rancher_hostname}" --user="$(whoami)")
    fi

    # shellcheck disable=SC2181
    if [[ "$?" -ne 0 ]]; then
        error "❌ Error: Failed to login to Rancher."

        # The Rancher CLI can save an empty entry for the server even when this fails.
        if [[ -f "$HOME/.rancher/cli2.json" ]] && [[ -n "$(rancher_entry_problem "${rancher_hostname}")" ]] && \
           [[ "$(rancher_entry_problem "${rancher_hostname}")" != "its entry is missing or not a valid object" ]]; then
            remove_rancher_entry "${rancher_hostname}"
        fi
        return 1
    fi

    rancher_token=$(printf '%s' "${rancher_token_credential}" | yq -r '.status.token')

    # shellcheck disable=SC2181
    if [[ "$?" -ne 0 ]] || [[ -z "$rancher_token" ]]; then
        error "❌ Error: Failed to get parse token response from Rancher."
        return 1
    fi

    # Reuse the previously selected project only if it is well formed and still
    # exists; a stale or garbled value would make every login fail.
    rancher_project=""
    if [[ -f "$HOME/.rancher/cli2.json" ]] && rancher_config_parses; then
        rancher_project=$(yq -p json -o json -r '.Servers["'"${rancher_hostname}"'"].project // ""' "$HOME/.rancher/cli2.json" 2>/dev/null)
    fi

    if [[ -n "${rancher_project}" ]]; then
        if ! [[ "${rancher_project}" =~ ^[a-z0-9-]+:[a-z0-9-]+$ ]] || \
           ! call_rancher "$rancher_token" "https://${rancher_hostname}/v3/projects/${rancher_project}" &>/dev/null; then
            debug "Saved project ${rancher_project} is no longer usable, picking a new one."
            rancher_project=""
        fi
    fi

    if [[ -z "${rancher_project}" ]]; then
        rancher_project=$(call_rancher "$rancher_token" "https://${rancher_hostname}/v3/projects" | yq -p json -o json -r '.data[0].id // ""' 2>/dev/null)

        if ! [[ "${rancher_project}" =~ ^[a-z0-9-]+:[a-z0-9-]+$ ]]; then
            error "❌ Error: Couldn't find any Rancher projects you can use on ${rancher_hostname}. If you're new, you may need to be granted access first."
            return 1
        fi
    fi

    debug "Using project $rancher_project"

    current_server=""
    current_context=""
    if [[ -f "$HOME/.rancher/cli2.json" ]]; then
        current_server=$(rancher_current_server)
        debug "Current server is $current_server"
    fi

    # Apparently Rancher will blow up the current context,
    # including nuking any configured namespace. Since the kube
    # context isn't our responsibility, we'll back it up and
    # restore it when this is done.
    if [[ -f "$HOME/.kube/config" ]]; then
        cp "$HOME/.kube/config" "$HOME/.kube/config.rancherlogin"
    fi

    if [[ "${ENABLE_DEBUG}" = "true" ]]; then
        if [[ -f "$HOME/.rancher/cli2.json" ]]; then
            debug "Current Rancher Configuration before login:"
            print_rancher_config_redacted
        fi
    fi

    rancher login --token="${rancher_token}" --context="${rancher_project}" --name="${rancher_hostname}" "https://${rancher_hostname}"
    login_result=$?

    if [[ -n "${current_context}" ]]; then
        debug "Switching back to previous server ${current_server}"
        rancher server switch "${current_server}"
    fi

    if [[ -f "$HOME/.kube/config" ]] && [[ -f "$HOME/.kube/config.rancherlogin" ]]; then
        rm "$HOME/.kube/config"
        mv "$HOME/.kube/config.rancherlogin" "$HOME/.kube/config"
    fi

    if [[ "${ENABLE_DEBUG}" = "true" ]]; then
        if [[ -f "$HOME/.rancher/cli2.json" ]]; then
            debug "Current Rancher configuration after login:"
            print_rancher_config_redacted
        fi
    fi

    if [[ ${login_result} -ne 0 ]]; then
        error "❌ Error: The Rancher CLI could not log in to ${rancher_hostname}."
        return 1
    fi

    # Make sure what the Rancher CLI saved is actually usable.
    entry_problem=$(rancher_entry_problem "${rancher_hostname}")
    if [[ -n "${entry_problem}" ]]; then
        error "❌ Error: After logging in to ${rancher_hostname}, ${entry_problem}."
        return 1
    fi
}

install_kubectl() {
    local kubectl_version="$1"

    gum spin --show-error --show-output --title="Downloading kubectl ${kubectl_version} for $LOCAL_OS/$KUBECTL_ARCH..." -- \
        curl -sL --show-error \
        "https://dl.k8s.io/release/v${kubectl_version}/bin/${LOCAL_OS}/${KUBECTL_ARCH}/kubectl" -o "$HOME/.local/bin/kubectl" || exit 1
    chmod 755 "$HOME/.local/bin/kubectl" || exit 1
    info "🎉 Successfully installed kubectl ${kubectl_version}!"
}

setup_kube_context() {
    if ! [[ -f "${HOME}/.kube/config.incomplete" ]]; then
        error "❌ Error: Cannot setup Kubernetes context except during kubeconfig setup. This is a bug, please rerun the script with '-T' and report the issue."
        exit 1
    fi

    instruction "It's time to setup the default Kubernetes cluster, project, and namespace you'll be using. \
You'll first pick your default Rancher server (if you have multiple). Then you'll get a numbered list of \
clusters and projects; pay attention to the columns, find the row with the project you'll use most often \
and enter the number in the first column. Last, you'll pick your default namespace."

    DEFAULT_NAMESPACE=""
    RANCHER_CURRENT_CLUSTER=""

    while [[ -z "${DEFAULT_NAMESPACE}" ]] || [[ -z "${RANCHER_CURRENT_CLUSTER}" ]]; do
        # Yes, we set this in the loop too just to make sure we're clean
        DEFAULT_NAMESPACE=""
        RANCHER_CURRENT_CLUSTER=""

        if ! select_default_rancher_server; then
            warn "Couldn't switch to that Rancher server. Please pick again."
            continue
        fi

        info "Loading clusters and projects from $(rancher_current_server); this can take a moment..."
        info "Select your default Kubernetes cluster and project:"
        rancher context switch

        RANCHER_CURRENT_CLUSTER=$(rancher context current | sed -n 's/.*Cluster:\([^ ]*\).*/\1/p')
        AVAILABLE_NAMESPACES=$(gum spin --show-error --title="Fetching namespaces you have access to..." -- rancher namespaces -q)

        # shellcheck disable=SC2181
        if [[ "$?" -ne 0 ]]; then
            warn "There was an error communicating with the ${RANCHER_CURRENT_CLUSTER} cluster. Please select a different cluster and project."
            AVAILABLE_NAMESPACES=""
        else
            AVAILABLE_NAMESPACES=$(printf '%s' "${AVAILABLE_NAMESPACES}" | sort)

            if [[ -z "${AVAILABLE_NAMESPACES}" ]]; then
                warn "You don't seem to have access to any namespaces in the $(rancher context current) context. Please select a different cluster and project."
                DEFAULT_NAMESPACE=""
            else
                info "Select your default namespace:"
                DEFAULT_NAMESPACE=$(printf '%s' "${AVAILABLE_NAMESPACES}" | gum choose --select-if-one --ordered)

                if ! [[ "$DEFAULT_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
                    warn "The namespace you selected (${DEFAULT_NAMESPACE}) is not a valid Kubernetes namespace name. This should not happen, please let ADP know and select a differnt namespace."
                    DEFAULT_NAMESPACE=""
                    continue
                fi

                KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config set-context "${RANCHER_CURRENT_CLUSTER}" --namespace="${DEFAULT_NAMESPACE}" >/dev/null
            fi
        fi
    done

    KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config use-context "${RANCHER_CURRENT_CLUSTER}" >/dev/null
}

while getopts "udThIRAGDKSaCc:s:r:g:" arg; do
    case $arg in
        h) echo "Usage: $0 [options]"
           echo
           echo "Options:"
           echo "  -d           Enable debug mode."
           echo "  -T           Enable trace mode."
           echo "  -u           Force update of all tools."
           echo "  -D           Only download tools, do not configure anything."
           echo "  -I           Accept supply chain security risks without prompting."
           echo "  -R           Prompt to add additional Rancher servers even if some are already configured."
           echo "  -A           Prompt to add additional ArgoCD servers even if some area already configured."
           echo "  -G           Prompt to add additional GitHub servers even if some are already configured."
           echo "  -K           Skip kubectl and kubeconfig."
           echo "  -a           Login to all ADP services, not just Rancher and Kubernetes."
           echo "  -C           Check status only (read-only, no prompts, no secrets printed). Combine with -a to include all services."
           echo "  -g <githubs> A space separated list of GitHub servers to add. Default: ${DEFAULT_GITHUB_SERVERS[*]}"
           echo "  -r <rancher> The Rancher server to login to. Default: $DEFAULT_RANCHER_HOSTNAME"
           echo "  -c <context> The Kubernetes context to use to store the client configuration. Default: $KUBE_CLIENT_CONFIG_CONTEXT"
           echo "  -s <secret>  The Kubernetes secret to use to store the client configuration. Default: $KUBE_CLIENT_CONFIG_SECRET"
           echo "  -h           Show this help message."
           echo
           echo "Exit codes: 0 ok; 1 error or some services could not be set up; 2 needs an interactive"
           echo "terminal; 3 (-C) something is missing or expired; 4 (-C) only unreachable hosts."
           exit 0 ;;
        d) ENABLE_DEBUG="true" ;;
        D) ONLY_DOWNLOAD="true" ;;
        T)
            warn "🚨 Trace mode is enabled. This causes severe issues with graphical selection prompts and may make the script unusable."
            warn "🚨 Trace output contains credentials: do not share it or paste it into an AI tool or an issue."
            set -x
            ;;
        u) FORCE_UPDATE="true" ;;
        I) ACCEPT_SUPPLY_CHAIN_SECURITY="true" ;;
        R) FORCE_ADD_MORE_RANCHERS="true" ;;
        A) FORCE_ADD_MORE_ARGOCD="true"
           SETUP_INTERNAL_SERVICES="true"
           ;;
        G) FORCE_ADD_MORE_GITHUB="true" ;;
        K) SKIP_KUBECONFIG="true" ;;
        a) SETUP_INTERNAL_SERVICES="true" ;;
        C) CHECK_ONLY="true" ;;
        c) KUBE_CLIENT_CONFIG_CONTEXT="$OPTARG" ;;
        s) KUBE_CLIENT_CONFIG_SECRET="$OPTARG" ;;
        r) DEFAULT_RANCHER_HOSTNAME="$OPTARG"
           DEFAULT_RANCHER_AUTH_PROVIDER=""
           ;;
        g) read -r -a DEFAULT_GITHUB_SERVERS <<< "$OPTARG" ;;
        *) error "❌  Error: Invalid option $arg." && exit 1 ;;
    esac
done

ALL_BINARIES_AVAILABLE="true"
for BINARY in curl tar awk sed grep git; do
    if ! which "${BINARY}" &>/dev/null; then
        error "❌ Error: ${BINARY} is required but not installed. Please contact ADP for assistance and let us know what operating system you're using."
        ALL_BINARIES_AVAILABLE="false"
    fi
done

if [[ "${ALL_BINARIES_AVAILABLE}" = "false" ]]; then
    exit 1
fi

if [[ "${CHECK_ONLY}" = "true" ]]; then
    PATH="${HOME}/.local/bin:${PATH}" run_status_check
    exit $?
fi

# Not interactive, but run from a file (for example by an AI agent or a CI job)
# rather than piped from curl: say how to run it properly and change nothing.
if ! [ -t 0 ] && [[ "${ONLY_DOWNLOAD}" != "true" ]] && [[ -f "$0" ]]; then
    echo "adp-connect needs an interactive terminal and a web browser, so it can't run here."
    echo "Ask the user to run this in their own terminal:"
    echo
    echo "    adp-connect ${ORIGINAL_ARGS[*]}"
    echo
    echo "To check status without a terminal, run: adp-connect -C (add -a to include all services)."
    exit 2
fi

if ! [[ -d "$HOME/.local/bin" ]]; then
    if ! mkdir -p "${HOME}"/.local/bin 2>/dev/null; then
        echo "❌ Error: Failed to create directory ${HOME}/.local/bin. Please check your permissions or available disk space."
        exit 1
    fi
fi

if ! [ -t 0 ] && [[ "${ONLY_DOWNLOAD}" != "true" ]]; then
    echo "Looks like you're running non-interactive, like from 'curl'."
    echo "Since this tool asks a lot of questions, it cannot be run this way. Installing to ${HOME}/.local/bin..."

    curl -s "${SCRIPT_SOURCE_URL}" -o "${HOME}/.local/bin/adp-connect"
    chmod +x "${HOME}/.local/bin/adp-connect"

    if ! printf '%s' "$PATH" | grep -q "$HOME/.local/bin"; then
        echo "Please ensure that \$HOME/.local/bin is in your PATH."

        case "$(basename "$SHELL")" in
            bash)
                echo "You should be able to add this line to your ~/.bashrc or ~/.bash_profile:"
                echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
                ;;
            zsh)
                echo "You should be able to add this line to your ~/.zshrc:"
                echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
                ;;
            fish)
                echo "You should be able to add this line to your ~/.config/fish/config.fish:"
                echo "    set -gx PATH \$HOME/.local/bin \$PATH"
                ;;
            csh|tcsh)
                echo "You should be able to add this line to your ~/.cshrc:"
                echo "    set path = (\$HOME/.local/bin \$path)"
                ;;
            *)
                echo "Please add \$HOME/.local/bin to your PATH in your shell's configuration file."
                ;;
        esac
    fi

    # shellcheck disable=SC2016
    echo 'adp-connect has been installed, please re-run it in a terminal with the command
 adp-connect, use `adp-connect -h` for help. To check status without a terminal, use `adp-connect -C`.'

    exit 2
fi

if ! [ "${FORCE_CURRENT_SHELL}" = "true" ]; then
    if which zsh &>/dev/null && ! [ -z "${BASH}" ]; then
        exec zsh "$0" "$@"
    fi
fi

if [ -n "${ZSH_NAME}" ]; then
    debug "Running in ZSH!"
elif [ -z "${BASH}" ]; then
    warn "Running in an unknown shell. This script has only been tested in bash and zsh, you may run into issues."
fi

git check-ref-format --branch "${SCRIPT_SOURCE_BRANCH}" >/dev/null || exit 1

if ! (grep --help 2>/dev/null | grep -q 'extended-regexp') && ! (which sw_vers >/dev/null && [ "$(sw_vers | grep ProductName | awk '{print $2}' | tr '[:upper:]' '[:lower:]')" = "macos" ]); then
    error "❌ Error: Your version of grep does not support extended regular expressions. Please contact ADP for assistance and let us know what operating system you're using."
    exit 1
fi

if [[ -z "${ACCEPT_SUPPLY_CHAIN_SECURITY}" ]]; then
    if ! confirm "⚠️  This script will utilize a series of resources from \
the internet. The integrity of these cannot be assured, are you sure you want to \
continue?"; then
        info " I am 😢 Quitting..."
        exit 1
    fi
else
    warn "🔓 This script will utilize a series of resources from the internet \
the integrity of these cannot be assured. You've accepted this risk with the -I flag or \
the ACCEPT_SUPPLY_CHAIN_SECURITY environment variable. Continuing."
fi

if [[ -n "${FORCE_UPDATE}" ]] || ! gum -v &>/dev/null; then
    download_latest_release "charmbracelet/gum" "gum" "tar.gz" || exit 1
    extract_download "gum" "tar.gz" || exit 1
    install -m "0755" "${TEMP_DIR}/gum"*/"gum" "$HOME/.local/bin/gum" || exit 1
    info "🎉 Successfully installed gum!"

    HAVE_GUM="true"
fi

# This version of `yq` is written in Go and supports both
# JSON and YAML. One tool, no interperters needed.
if should_install "yq"; then
    INSANE_CHECKSUMS="true" download_latest_release "mikefarah/yq" "yq" || exit 1
    install -m "0755" "${TEMP_DIR}/yq" "$HOME/.local/bin/yq" || exit 1
    info "🎉 Successfully installed yq!"
elif ! yq --version | grep -q mikefarah; then
    error "🚨 You have a version of 'yq' installed that is incompatible with this script."
    error "you'll have to remove it to continue. Don't worry, this script will install a better one"
    error " (https://github.com/mikefarah/yq)."

    exit 1
fi

should_install "rancher"
INSTALL_RANCHER=$?

if [[ "${INSTALL_RANCHER}" = "1" ]]; then
    compare_versions "$(rancher --version | awk '{ print $3 }')" "${NEEDED_RANCHER_VERSION}"
    if [[ "$?" = "2" ]]; then
        warn "🚨 Your version of Rancher CLI is less than ${NEEDED_RANCHER_VERSION}. Forcing an upgrade."
        INSTALL_RANCHER=0
    fi
fi

if [[ "${INSTALL_RANCHER}" = "0" ]]; then
    download_latest_release "rancher/cli" "rancher" "tar.gz" || exit 1
    extract_download "rancher" "tar.gz" || exit 1
    install -m "0755" "${TEMP_DIR}/rancher"*/"rancher" "$HOME/.local/bin/rancher" || exit 1
    info "🎉 Successfully installed rancher CLI!"
fi

if [[ ! "${ONLY_DOWNLOAD}" = "true" ]]; then
    debug "Checking for existing Rancher CLI configuration..."
    ALL_RANCHERS_ADDED="false"

    # Servers configured before this run; anything usable that isn't in this list
    # by the end of validation was added during this run.
    INITIAL_RANCHER_SERVERS=()
    if [[ -f "$HOME/.rancher/cli2.json" ]] && rancher_config_parses; then
        for SERVER in $(yq -r '.Servers | to_entries[] | .key' < "$HOME/.rancher/cli2.json" | grep -v rancherDefault); do
            INITIAL_RANCHER_SERVERS+=("${SERVER}")
        done
    fi

    if [[ -f "$HOME/.rancher/cli2.json" ]] && ! rancher_config_parses; then
        warn "🚨 Your Rancher CLI configuration can't be read, so it will be set up again."
        backup_rancher_config
        rm -f "$HOME/.rancher/cli2.json"
    fi

    if [[ -f "$HOME/.rancher/cli2.json" ]]; then
        if [[ -e "${HOME}"/.rancher/cli2.json ]] && [[ -z "$(yq -r '.Servers[].accessKey' "${HOME}"/.rancher/cli2.json)" ]]; then
            debug "Detected incomplete Rancher CLI configuration, deleting it."
            backup_rancher_config
            rm "${HOME}"/.rancher/cli2.json

            rancher_login "${DEFAULT_RANCHER_HOSTNAME}" || exit 1
        else
            if [[ -z "${FORCE_ADD_MORE_RANCHERS}" ]]; then
                ALL_RANCHERS_ADDED="true"
            fi

            debug "Validating existing configuration..."
            if ! [[ "$(yq -r '.Servers.rancherDefault' < "$HOME/.rancher/cli2.json")" = "null" ]]; then
                warn "🚨 A 'rancherDefault' entry exists in your configuration and is known to cause problems. It's\
        recommended to clear your config and start over."
                if confirm "Would you like to clear your Rancher CLI configuration?"; then
                    backup_rancher_config
                    rm -f "$HOME/.rancher/cli2.json"
                    rancher_login "${DEFAULT_RANCHER_HOSTNAME}" || exit 1
                fi
            fi

            if [[ "$(yq -r '.Servers | length' < "$HOME/.rancher/cli2.json")" = "0" ]]; then
                debug "Found $(yq -r '.Servers | length' < "$HOME/.rancher/cli2.json") servers in this configuration."
                rancher_login "${DEFAULT_RANCHER_HOSTNAME}" || exit 1
            fi
        fi
    else
        rancher_login "${DEFAULT_RANCHER_HOSTNAME}" || exit 1
    fi

    while ! [[ "${ALL_RANCHERS_ADDED}" = "true" ]]; do
        info "The following Rancher servers have been configured:"

        gum style \
            --border-foreground=212 \
            --border=double \
            --align=center \
            --width=50 \
            --margin="1 2" \
            --padding="2 4 " \
            "$(yq -r '.Servers | to_entries[] | .key' < "$HOME/.rancher/cli2.json" | grep -v rancherDefault)"

        gum confirm --default=No "Are there any additional Ranchers you want to setup?"
        if [[ $? -eq 1 ]]; then
            ALL_RANCHERS_ADDED="true"
            break
        fi

        RANCHER_HOSTNAME=$(gum input --width=80 --placeholder="Additional Rancher Hostname" | tr -d '[:space:]')

        if [[ -z "${RANCHER_HOSTNAME}" ]]; then
            ALL_RANCHERS_ADDED="true"
            break
        fi

        rancher_login "${RANCHER_HOSTNAME}" || record_failure "Rancher ${RANCHER_HOSTNAME}: login failed."
    done

    info "Validating all Rancher servers..."
    REACHABLE_RANCHER_SERVERS=()
    UNREACHABLE_RANCHER_SERVERS=()
    SERVERS_TO_VALIDATE=()
    for SERVER in $(yq -r '.Servers | to_entries[] | .key' < "$HOME/.rancher/cli2.json" | grep -v rancherDefault); do
        SERVERS_TO_VALIDATE+=("${SERVER}")
    done

    while [[ ${#SERVERS_TO_VALIDATE[@]} -gt 0 ]]; do
        NOT_REACHED=()
        for SERVER in "${SERVERS_TO_VALIDATE[@]}"; do
            validate_rancher_server "${SERVER}"
            case $? in
                0) REACHABLE_RANCHER_SERVERS+=("${SERVER}") ;;
                2) NOT_REACHED+=("${SERVER}") ;;
                *) UNREACHABLE_RANCHER_SERVERS+=("${SERVER}") ;;
            esac
        done

        SERVERS_TO_VALIDATE=()
        if [[ ${#NOT_REACHED[@]} -eq 0 ]]; then
            break
        fi

        if ask_retry_unreachable "Rancher" "${NOT_REACHED[@]}"; then
            SERVERS_TO_VALIDATE=("${NOT_REACHED[@]}")
        else
            for SERVER in "${NOT_REACHED[@]}"; do
                record_failure "Rancher ${SERVER}: unreachable (connection, timeout, or TLS error). Skipping."
                UNREACHABLE_RANCHER_SERVERS+=("${SERVER}")
            done
        fi
    done

    if [[ ${#UNREACHABLE_RANCHER_SERVERS[@]} -gt 0 ]]; then
        warn "Skipping these Rancher servers for the remaining setup: ${UNREACHABLE_RANCHER_SERVERS[*]}"
    fi

    if [[ ${#REACHABLE_RANCHER_SERVERS[@]} -gt 0 ]]; then
        info "🎉 Rancher servers are configured and validated: ${REACHABLE_RANCHER_SERVERS[*]}"
    else
        warn "No Rancher servers could be used in this run."
    fi

    if [[ -z "${SKIP_KUBECONFIG}" ]]; then
        info "Generating/updating kubeconfig (this will take some time)..."

        KUBE_CONFIGS=()
        KUBE_CURRENT_CONTEXT=""
        if [[ -f "$HOME/.kube/config" ]]; then
            debug "Backing up existing kubeconfig..."
            cp "$HOME/.kube/config" "$HOME/.kube/config.bak"

            KUBE_CURRENT_CONTEXT=$(yq -r '.current-context' "$HOME/.kube/config")
        else
            mkdir -p "$HOME/.kube"
        fi

        debug "Current kubeconfig context: ${KUBE_CURRENT_CONTEXT}"

        KUBE_CLUSTER_VERSIONS=()
        for SERVER in "${REACHABLE_RANCHER_SERVERS[@]}"; do
            debug "Switching to Rancher server ${SERVER}..."
            rancher server switch "${SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null
            # Must be the same choice rancher_login makes, so the credential keys match.
            SERVER_AUTH_PROVIDER=$(rancher_auth_provider "${SERVER}")
            for CLUSTER in $(with_spinner "Listing clusters on ${SERVER}..." rancher cluster list | grep -v CURRENT | sed 's/^*//g' | awk '{ print $1 }'); do
            TEMP_KUBE_CONFIG=$(printf '%s' "${SERVER}-${CLUSTER}" | base64)
            debug "Fetching kubeconfig for cluster ${CLUSTER} on server ${SERVER}..."
            if ! gum spin --show-error --title="Fetching kubeconfig for cluster ${CLUSTER}..." -- rancher cluster kf "${CLUSTER}" > "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml" || \
               ! [[ -s "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml" ]]; then
                record_failure "Kubernetes cluster ${CLUSTER} on ${SERVER}: could not fetch its kubeconfig. Skipping."
                rm -f "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml"
                continue
            fi

            CLUSTER_VERSION="$(with_spinner "Checking the Kubernetes version of ${CLUSTER}..." rancher inspect --type=cluster "${CLUSTER}" | yq -r '.version.gitVersion' | sed -E 's/^([vV]?[0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
            if ! [[ "${CLUSTER_VERSION}" =~ ^[vV]?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                record_failure "Kubernetes cluster ${CLUSTER} on ${SERVER}: could not read its version. Skipping."
                rm -f "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml"
                continue
            fi

            align_rancher_exec_users "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml" "${SERVER}" "${SERVER_AUTH_PROVIDER}"

            KUBE_CONFIGS+=("${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml")
            KUBE_CLUSTER_VERSIONS+=("${CLUSTER_VERSION}")
            done
        done

        if [[ ${#REACHABLE_RANCHER_SERVERS[@]} -eq 0 ]]; then
            warn "No reachable Rancher servers are available. Skipping kubeconfig and kubectl version setup."
        elif [[ ${#KUBE_CLUSTER_VERSIONS[@]} -eq 0 ]]; then
            warn "No cluster version data found from reachable Rancher servers. Skipping kubeconfig and kubectl version setup."
        else

        # Deduplicate and sort KUBE_CLUSTER_VERSIONS
        KUBE_CLUSTER_VERSIONS_UNIQUE=()
        while IFS= read -r line; do
            KUBE_CLUSTER_VERSIONS_UNIQUE+=("$line")
        done < <(printf '%s\n' "${KUBE_CLUSTER_VERSIONS[@]}" | sort -u)
        KUBE_CLUSTER_VERSIONS=("${KUBE_CLUSTER_VERSIONS_UNIQUE[@]}")

        debug "Found the following Kubernetes versions: ${KUBE_CLUSTER_VERSIONS[*]}"

        KUBE_LATEST_VERSION=$(version_sort "${KUBE_CLUSTER_VERSIONS[@]}" | tail -n 1)
        KUBE_OLDEST_VERSION=$(version_sort "${KUBE_CLUSTER_VERSIONS[@]}" | head -n 1)
        KUBE_TARGET_VERSION="${KUBE_LATEST_VERSION}"

        debug "Latest Kubernetes version: ${KUBE_LATEST_VERSION}"
        debug "Oldest Kubernetes version: ${KUBE_OLDEST_VERSION}"

        KUBE_LATEST_MAJOR=$(printf '%s' "${KUBE_LATEST_VERSION}" | cut -d. -f1)
        KUBE_LATEST_MINOR=$(printf '%s' "${KUBE_LATEST_VERSION}" | cut -d. -f2)
        KUBE_OLDEST_MAJOR=$(printf '%s' "${KUBE_OLDEST_VERSION}" | cut -d. -f1)
        KUBE_OLDEST_MINOR=$(printf '%s' "${KUBE_OLDEST_VERSION}" | cut -d. -f2)

        if [[ "${KUBE_LATEST_MAJOR}" != "${KUBE_OLDEST_MAJOR}" ]] || (( 10#${KUBE_LATEST_MINOR} > 10#${KUBE_OLDEST_MINOR} + 1 )); then
            KUBE_ALLOWED_MINOR=$((10#${KUBE_OLDEST_MINOR} + 1))
            KUBE_TARGET_VERSION=$(printf '%s\n' "${KUBE_CLUSTER_VERSIONS[@]}" | awk -F. -v major="${KUBE_OLDEST_MAJOR}" -v minor="${KUBE_ALLOWED_MINOR}" '$1 == major && $2 == minor {print $0}' | version_sort | tail -n 1)

            if [[ -z "${KUBE_TARGET_VERSION}" ]]; then
                KUBE_TARGET_VERSION="${KUBE_OLDEST_MAJOR}.${KUBE_ALLOWED_MINOR}.0"
            fi

            warn "Newest cluster version ${KUBE_LATEST_VERSION} is more than one minor newer than oldest ${KUBE_OLDEST_VERSION}. Capping kubectl target to ${KUBE_TARGET_VERSION}."
        fi

        debug "Kubectl target version: ${KUBE_TARGET_VERSION}"

        info "Validating kubectl version target (${KUBE_TARGET_VERSION}) based on reachable cluster versions (${KUBE_OLDEST_VERSION} to ${KUBE_LATEST_VERSION})."

        if should_install "kubectl"; then
            install_kubectl "${KUBE_TARGET_VERSION}" || exit 1
        else
            KUBECTL_CLIENT_VERSION=$(kubectl version --client -o yaml 2>/dev/null | yq -r '.clientVersion.gitVersion' | sed -E 's/^([vV]?[0-9]+\.[0-9]+\.[0-9]+).*/\1/')
            if [[ "$(which kubectl)" != "$HOME/.local/bin/kubectl" ]]; then
                warn "🚨 kubectl is already installed but managed by a different tool. Proceeding with your existing kubectl."
                if [[ -n "${KUBECTL_CLIENT_VERSION}" ]]; then
                    compare_versions "${KUBECTL_CLIENT_VERSION}" "${KUBE_TARGET_VERSION}"
                    if [[ "$?" = "2" ]]; then
                        warn "Your kubectl version (${KUBECTL_CLIENT_VERSION}) is older than the target version (${KUBE_TARGET_VERSION})."
                    fi
                fi
            else
                if [[ -z "${KUBECTL_CLIENT_VERSION}" ]]; then
                    warn "Could not determine local kubectl version. Proceeding without kubectl upgrade validation."
                else
                    compare_versions "${KUBECTL_CLIENT_VERSION}" "${KUBE_TARGET_VERSION}"
                    COMPARE_RESULT="$?"
                    if [[ "${COMPARE_RESULT}" = "2" ]]; then
                        info "🔍 kubectl (${KUBECTL_CLIENT_VERSION}) is older than target (${KUBE_TARGET_VERSION}). Upgrading kubectl..."
                        install_kubectl "${KUBE_TARGET_VERSION}" || exit 1
                    elif [[ "${COMPARE_RESULT}" = "1" ]]; then
                        debug "kubectl (${KUBECTL_CLIENT_VERSION}) is newer than the target (${KUBE_TARGET_VERSION})."
                    else
                        debug "kubectl (${KUBECTL_CLIENT_VERSION}) matches the target version (${KUBE_TARGET_VERSION})."
                    fi
                fi
            fi
        fi

        if [[ -f "${HOME}/.kube/config" ]]; then
            KUBE_CONFIGS+=("$HOME/.kube/config")
        fi

        OIFS=${IFS}; IFS=":"; KUBECONFIG="${KUBE_CONFIGS[*]}"; IFS=${OIFS}
        KUBECONFIG=${KUBECONFIG} kubectl config view --flatten > "$HOME/.kube/config.incomplete"

        if [[ -f "$HOME/.kube/config.bak" ]]; then
            for CONTEXT in $(yq eval -o json -I=0 '.contexts[]' "$HOME/.kube/config.bak"); do
                NAME=$(yq -r '.name' <<< "${CONTEXT}")

                if [[ -z "$(yq -r '.contexts[] | select(.name == "'"${NAME}"'")' "$HOME/.kube/config" 2>/dev/null)" ]]; then
                    continue
                fi
            done
        fi

        NEWLY_ADDED_RANCHER_SERVERS=()
        for SERVER in "${REACHABLE_RANCHER_SERVERS[@]}"; do
            if ! is_in_array "${SERVER}" "${INITIAL_RANCHER_SERVERS[@]}"; then
                NEWLY_ADDED_RANCHER_SERVERS+=("${SERVER}")
            fi
        done

        # The current context is kept as long as it still exists. A missing namespace
        # is fine (kubectl then uses "default"). Default selection only runs when
        # there is no usable current context or a new Rancher server was added.
        CURRENT_RANCHER_SERVER_NAME=""
        if [[ -n "${KUBE_CURRENT_CONTEXT}" ]] && [[ "${KUBE_CURRENT_CONTEXT}" != "null" ]] && \
           KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config get-contexts -o name 2>/dev/null | grep -qxF "${KUBE_CURRENT_CONTEXT}"; then
            KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config use-context "${KUBE_CURRENT_CONTEXT}" >/dev/null

            CURRENT_NAMESPACE=$(KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config view --minify --output 'jsonpath={..namespace}')
            CURRENT_CLUSTER_URL=$(KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config view --minify --output 'jsonpath={.clusters[0].cluster.server}')
            # shellcheck disable=SC2001
            CURRENT_RANCHER_SERVER_URL=$(printf '%s' "${CURRENT_CLUSTER_URL}" | sed -e 's|^\([^:/]*://[^/]*\).*|\1|')
            if [[ -n "${CURRENT_RANCHER_SERVER_URL}" ]]; then
                CURRENT_RANCHER_SERVER_NAME=$(rancher server ls | sed 's/^*//g' | grep -v CURRENT | grep -F "${CURRENT_RANCHER_SERVER_URL}" | awk '{ print $1 }' | head -n 1)
            fi

            debug "Current namespace: ${CURRENT_NAMESPACE}"
            debug "Current cluster URL: ${CURRENT_CLUSTER_URL}"
            debug "Current Rancher server: ${CURRENT_RANCHER_SERVER_URL}"
            debug "Current Rancher server name: ${CURRENT_RANCHER_SERVER_NAME}"

            if [[ ${#NEWLY_ADDED_RANCHER_SERVERS[@]} -gt 0 ]]; then
                info "You added ${NEWLY_ADDED_RANCHER_SERVERS[*]}, so you can now pick your default cluster, project and namespace."
                setup_kube_context
            elif [[ -n "${CURRENT_RANCHER_SERVER_NAME}" ]] && \
                 ! is_in_array "${CURRENT_RANCHER_SERVER_NAME}" "${REACHABLE_RANCHER_SERVERS[@]}"; then
                # Don't make the user replace their default with whatever happens to be
                # reachable right now (e.g. while off a VPN); check it on a later run.
                info "Keeping your current context (${KUBE_CURRENT_CONTEXT}). Its Rancher server, \
${CURRENT_RANCHER_SERVER_NAME}, couldn't be reached, so it wasn't checked."
            elif [[ -n "${CURRENT_NAMESPACE}" ]] && [[ -n "${CURRENT_RANCHER_SERVER_NAME}" ]] && \
                 ! (with_spinner "Checking your current namespace ${CURRENT_NAMESPACE}..." \
                        env KUBECONFIG="$HOME/.kube/config.incomplete" kubectl get namespace "${CURRENT_NAMESPACE}" -o name &>/dev/null); then
                warn "Your current namespace ${CURRENT_NAMESPACE} no longer exists or you can't access it."
                setup_kube_context
            fi
        else
            if [[ -n "${KUBE_CURRENT_CONTEXT}" ]] && [[ "${KUBE_CURRENT_CONTEXT}" != "null" ]]; then
                warn "Your current context ${KUBE_CURRENT_CONTEXT} no longer exists."
            fi
            setup_kube_context
        fi

        NEW_CONTEXT=$(KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config current-context 2>/dev/null)
        NEW_NAMESPACE=$(KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)
        NEW_CLUSTER_URL=$(KUBECONFIG="$HOME/.kube/config.incomplete" kubectl config view --minify --output 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)
        # shellcheck disable=SC2001
        NEW_RANCHER_SERVER_URL=$(printf '%s' "${NEW_CLUSTER_URL}" | sed -e 's|^\([^:/]*://[^/]*\).*|\1|')
        NEW_RANCHER_SERVER_NAME=""
        if [[ -n "${NEW_RANCHER_SERVER_URL}" ]]; then
            NEW_RANCHER_SERVER_NAME=$(rancher server ls | sed 's/^*//g' | grep -v CURRENT | grep -F "${NEW_RANCHER_SERVER_URL}" | awk '{ print $1 }' | head -n 1)
        fi

        debug "New context: ${NEW_CONTEXT}"
        debug "New namespace: ${NEW_NAMESPACE}"
        debug "New cluster URL: ${NEW_CLUSTER_URL}"
        debug "New Rancher server name: ${NEW_RANCHER_SERVER_NAME}"

        # Keep the Rancher CLI's current project in line with the default namespace.
        # Only possible when there is a namespace and its Rancher server is reachable.
        if [[ -z "${NEW_RANCHER_SERVER_NAME}" ]]; then
            debug "The current context isn't on a configured Rancher server; leaving the Rancher CLI context alone."
        elif ! is_in_array "${NEW_RANCHER_SERVER_NAME}" "${REACHABLE_RANCHER_SERVERS[@]}"; then
            debug "Skipping Rancher context switch because ${NEW_RANCHER_SERVER_NAME} is unreachable."
        elif [[ -n "${NEW_NAMESPACE}" ]]; then
            NEW_PROJECT_ID=$(with_spinner "Looking up the project for ${NEW_NAMESPACE}..." \
                env KUBECONFIG="$HOME/.kube/config.incomplete" kubectl get namespace "${NEW_NAMESPACE}" -o yaml 2>/dev/null | \
                yq -r '.metadata.annotations."field.cattle.io/projectId" // ""')

            if [[ -n "${NEW_PROJECT_ID}" ]]; then
                rancher server switch "${NEW_RANCHER_SERVER_NAME}" 2> >(grep -v "Saving config" >&2) >/dev/null
                rancher context switch "${NEW_PROJECT_ID}" 2> >(grep -v "Saving config" >&2) >/dev/null || \
                    debug "Couldn't switch the Rancher CLI to project ${NEW_PROJECT_ID}."
            fi
        fi

        mv "$HOME/.kube/config.incomplete" "$HOME/.kube/config"

        info "🎉 You now have access to $(yq '.contexts | length' ~/.kube/config) Kubernetes contexts!"
        info "Your default context is $(kubectl config current-context)."
        if [[ -n "$(kubectl config view --minify --output 'jsonpath={..namespace}')" ]]; then
            info "You'll be using the namespace $(kubectl config view --minify --output 'jsonpath={..namespace}') by default."
        else
            info "No default namespace is set for this context; kubectl will use 'default' unless you pass -n."
        fi
        fi
    fi


    # We do this whether or not we skip kubeconfig because we want to ensure
    # the kubeconfig is secure.
    if [[ -f "$HOME/.kube/config" ]]; then
        chmod 600 "$HOME/.kube/config"
    fi
fi

if should_install "kubeseal"; then
    download_latest_release "bitnami/sealed-secrets" "kubeseal" "tar.gz" || exit 1
    extract_download "kubeseal" "tar.gz" || exit 1
    install -m "0755" "${TEMP_DIR}/kubeseal" "$HOME/.local/bin/kubeseal" || exit 1
    info "🎉 Successfully installed kubeseal!"
fi

if [[ ! "${ONLY_DOWNLOAD}" = "true" ]]; then
    info "Fetching Sealed Secrets sealing certificates..."
    KUBESEAL_FAILED="false"
    KUBESEAL_SKIPPED=()
    for CONTEXT in $(yq eval -o json -I=0 '.contexts[]' "$HOME/.kube/config"); do
        NAME=$(yq -r '.name' <<< "${CONTEXT}")

        if [[ "${NAME}" =~ -fqdn$ ]]; then
            continue
        fi

        # Don't wait on clusters behind a Rancher server we already know is unreachable.
        CONTEXT_CLUSTER=$(yq -r '.context.cluster // ""' <<< "${CONTEXT}")
        CONTEXT_HOST=$(yq -r '.clusters[] | select(.name == "'"${CONTEXT_CLUSTER}"'") | .cluster.server // ""' "$HOME/.kube/config" | \
            head -n 1 | sed -e 's|^[a-zA-Z]*://||' -e 's|[:/].*||')
        if [[ -n "${CONTEXT_HOST}" ]] && is_in_array "${CONTEXT_HOST}" "${UNREACHABLE_RANCHER_SERVERS[@]}"; then
            KUBESEAL_SKIPPED+=("${NAME}")
            continue
        fi

        KUBESEAL_COMMAND=(kubeseal --context="${NAME}" --request-timeout=15s --fetch-cert
            --controller-name="${SEALED_SECRETS_CONTROLLER_NAME}"
            --controller-namespace="${SEALED_SECRETS_CONTROLLER_NAMESPACE}")

        # Contexts whose credentials come from an exec plugin (for example
        # `rancher token`) may need to sign in interactively. Run those in the
        # open, without a spinner, so any prompt is visible and can be answered.
        CONTEXT_USER=$(yq -r '.context.user // ""' <<< "${CONTEXT}")
        CONTEXT_USES_EXEC=$(yq -r '[.users[] | select(.name == "'"${CONTEXT_USER}"'") | .user.exec != null] | any' "$HOME/.kube/config")

        # Fetch into a temporary file so a failure never replaces a certificate
        # that was fetched successfully before.
        if [[ "${CONTEXT_USES_EXEC}" = "true" ]]; then
            info "Fetching the Sealed Secrets certificate for ${NAME}. Its credentials come from a plugin, so you may be asked to sign in below."
            "${KUBESEAL_COMMAND[@]}" > "${TEMP_DIR}/${NAME}.pem"
        else
            with_spinner "Fetching the Sealed Secrets certificate for ${NAME}..." "${KUBESEAL_COMMAND[@]}" > "${TEMP_DIR}/${NAME}.pem"
        fi
        KUBESEAL_RESULT=$?

        if [[ ${KUBESEAL_RESULT} -eq 0 ]] && [[ -s "${TEMP_DIR}/${NAME}.pem" ]]; then
            mv "${TEMP_DIR}/${NAME}.pem" "$HOME/.kube/${NAME}.pem"
        else
            rm -f "${TEMP_DIR}/${NAME}.pem"
            warn "❌ Warning: Failed to fetch Sealed Secrets certificate for ${NAME}."

            KUBESEAL_FAILED="true"
        fi
    done

    if [[ ${#KUBESEAL_SKIPPED[@]} -gt 0 ]]; then
        info "Skipped Sealed Secrets certificates for ${#KUBESEAL_SKIPPED[@]} contexts on unreachable Rancher servers; any certificates fetched earlier were kept."
    fi

    if [[ "${KUBESEAL_FAILED}" = "true" ]]; then
        warn "🚨 You won't be able to seal secrets for these clusters locally until this is resolved. \
This may be ok if you don't intend to use those clusters; otherwise, it may be a networking issue.
Please make sure you're on the VPN or VDI and can otherwise access the clusters with kubectl. If this keeps failing, \
check the errors shown above each warning."
    fi
fi

if should_install "helm"; then
    gum spin --show-error --title="Downloading Helm Installer..." -- \
        curl -Lo "${TEMP_DIR}/get-helm-3" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 755 "${TEMP_DIR}/get-helm-3"
    HELM_INSTALL_DIR="$HOME/.local/bin" USE_SUDO="false" gum spin --show-error \
        --title="Installing Helm..." "${TEMP_DIR}/get-helm-3" || exit 1
    info "🎉 Successfully installed Helm!"
fi

if should_install "skaffold"; then
    download_latest_release "GoogleContainerTools/skaffold" "skaffold" || exit 1
    install -m "0755" "${TEMP_DIR}/skaffold" "$HOME/.local/bin/skaffold" || exit 1
    info "🎉 Successfully installed skaffold!"
fi

if should_install "gh"; then
    download_latest_release "cli/cli" "gh" "tar.gz" || exit 1
    extract_download "gh" "tar.gz" || exit 1
    mv "${TEMP_DIR}"/gh_* "${TEMP_DIR}/gh"
    install -m "0755" "${TEMP_DIR}/gh/bin/gh" "$HOME/.local/bin/gh" || exit 1
    info "🎉 Successfully installed gh!"
fi

if [[ ! "${ONLY_DOWNLOAD}" = "true" ]]; then
    GITHUBS_TO_SETUP=("${DEFAULT_GITHUB_SERVERS[@]}")
    while [[ ${#GITHUBS_TO_SETUP[@]} -gt 0 ]]; do
        NOT_REACHED=()
        for GITHUB_SERVER in "${GITHUBS_TO_SETUP[@]}"; do
            github_login "${GITHUB_SERVER}"
            if [[ $? -eq 2 ]]; then
                NOT_REACHED+=("${GITHUB_SERVER}")
            fi
        done

        GITHUBS_TO_SETUP=()
        if [[ ${#NOT_REACHED[@]} -eq 0 ]]; then
            break
        fi

        if ask_retry_unreachable "GitHub" "${NOT_REACHED[@]}"; then
            GITHUBS_TO_SETUP=("${NOT_REACHED[@]}")
        else
            for GITHUB_SERVER in "${NOT_REACHED[@]}"; do
                record_failure "GitHub ${GITHUB_SERVER}: unreachable (connection, timeout, or TLS error). Skipping."
            done
        fi
    done

    if [[ "${FORCE_ADD_MORE_GITHUB}" = "true" ]]; then
        ALL_GITHUBS_ADDED="false"
    else
        ALL_GITHUBS_ADDED="true"
    fi

    while [[ "${ALL_GITHUBS_ADDED}" = "false" ]]; do
        info "The following Github servers have been configured:"

        gum style \
            --border-foreground=212 \
            --border=double \
            --align=center \
            --width=50 \
            --margin="1 2" \
            --padding="2 4 " \
            "$(yq '. | keys | .[]' "$HOME/.config/gh/hosts.yml")"

        if ! gum confirm --default=No "Are there any additional Github servers you want to setup?"; then
            ALL_GITHUBS_ADDED="true"
            break
        fi

        GITHUB_SERVER=$(gum input --width=80 --placeholder="Github Server")
        GITHUB_SERVER="${GITHUB_SERVER//[[:space:]]/}"

        if [[ -z "${GITHUB_SERVER}" ]]; then
            continue
        fi

        github_login "${GITHUB_SERVER}"
        if [[ $? -eq 2 ]]; then
            warn "Couldn't reach ${GITHUB_SERVER}. It may only be reachable on a specific VPN. Connect to it and add it again if you need it."
        fi
    done

    if ! git config --global --get init.defaultBranch &>/dev/null; then
        git config --global init.defaultBranch main
    fi

    if ! git config --global --get user.name &>/dev/null; then
        info "? What name will you use for git commits?"
        git config --global user.name "$(gum input --width=80 --placeholder="Your name for git commits:")" || exit 1
    fi

    if ! git config --global --get user.email &>/dev/null; then
        info "? What email will you use for git commits?"
        git config --global user.email "$(gum input --width=80 --placeholder="Your OHIO email for git commits:")" || exit 1
    fi

    info "You'll be committing as $(git config --global --get user.name) <$(git config --global --get user.email)>."
fi

if ! which git &>/dev/null; then
    warn "🚨 git is not installed. While this script does install the Github CLI, you still need to install\
 git itself. Please follow the appropriate steps for your operating system. On Windows, please install git\
 inside of WSL."
fi

if [[ "${SETUP_INTERNAL_SERVICES}" = "true" ]]; then
    if [[ ! "${ONLY_DOWNLOAD}" = "true" ]]; then
        HAVE_DOCKER="false"
        if which docker &>/dev/null; then
            if docker ps &>/dev/null; then
                HAVE_DOCKER="true"
            else
                warn "🚨 Docker is not running or is not accessible by your user. Please ensure 'docker ps' \
        works before continuing. If you need help, please let us know."
            fi
        else
            warn "🚨 Docker is not installed. You'll need to install Docker yourself. Please \
        follow the appropriate steps for your operating system. On Windows, please install Docker \
        inside of WSL. You can follow instructions for the Linux distribution you're using in WSL. \
        Note: In recent versions of WSL, this should just work. If you need help, please let us know."
        fi

        if [[ "${HAVE_DOCKER}" = "true" ]]; then
            # shellcheck disable=SC2016 # $1 is expanded by the inner sh, on purpose.
            if ! with_spinner "Checking your Artifactory Docker login..." \
                    sh -c 'docker login "$1" < /dev/null' _ docker."${DEFAULT_ARTIFACTORY_HOSTNAME}" &>/dev/null; then
                [[ -z "${USER_OHIOID}" ]] && USER_OHIOID="$(get_ohioid)"

                if [[ -z "${USER_OHIOID}" ]]; then
                    warn "Skipping Artifactory login for Docker and Helm. You'll need to configure these manually or rerun this script."
                else
                    while true; do
                        [[ -z "${ARTIFACTORY_TOKEN}" ]] && ARTIFACTORY_TOKEN="$(get_artifactory_token)"

                        if docker login -u "${USER_OHIOID}" --password-stdin docker."${DEFAULT_ARTIFACTORY_HOSTNAME}" <<< "${ARTIFACTORY_TOKEN}"; then
                            info "🎉 Successfully logged into Artifactory's Docker Registry!"
                            break
                        fi

                        warn "Artifactory login failed. Please try again."
                        ARTIFACTORY_TOKEN=""
                    done
                fi
            else
                info "🎉 You're already logged into Artifactory's Docker Registry!"
            fi
        fi
    fi

    if should_install "argocd"; then
        download_latest_release "argoproj/argo-cd" "argocd" || exit 1
        install -m "0755" "${TEMP_DIR}/argocd" "$HOME/.local/bin/argocd" || exit 1
        info "🎉 Successfully installed ArgoCD!"
    fi

    if [[ ! "${ONLY_DOWNLOAD}" = "true" ]]; then
        if which xdg-open &>/dev/null || which open &>/dev/null; then
            if ! argocd context | grep -v NAME | sed 's/^*//' | awk '{ print $2 }' | grep -q "${DEFAULT_ARGOCD_HOSTNAME}"; then
                info "Logging into ArgoCD at ${DEFAULT_ARGOCD_HOSTNAME}..."
                argocd login "${DEFAULT_ARGOCD_HOSTNAME}" --grpc-web --sso --skip-test-tls || \
                    record_failure "Argo CD ${DEFAULT_ARGOCD_HOSTNAME}: login failed."
            fi

            ARGOCD_CURRENT_CONTEXT="$(argocd context | grep '\*' | awk '{ print $2 }')"
            for ARGOCD_SERVER in $(argocd context | grep -v NAME | sed 's/^*//' | awk '{ print $2 }'); do
                if ! argocd context "${ARGOCD_SERVER}" 1>/dev/null; then
                    record_failure "Argo CD ${ARGOCD_SERVER}: could not switch to this server. Skipping."
                    continue
                fi

                if ! with_spinner "Checking Argo CD at ${ARGOCD_SERVER}..." argocd version &>/dev/null; then
                    info "Need to relogin to ArgoCD at ${ARGOCD_SERVER}..."
                    argocd login "${ARGOCD_SERVER}" --grpc-web --sso --skip-test-tls || \
                        record_failure "Argo CD ${ARGOCD_SERVER}: login failed."
                else
                    info "🎉 You're successfully authenticated to ArgoCD at $(printf '%s' "${ARGOCD_SERVER}" | awk -F: '{ print $1 }')!"
                fi
            done

            if [[ "${FORCE_ADD_MORE_ARGOCD}" = "true" ]]; then
                ALL_ARGOCDS_ADDED="false"
            else
                ALL_ARGOCDS_ADDED="true"
            fi

            while [[ "${ALL_ARGOCDS_ADDED}" = "false" ]]; do
                info "The following ArgoCD servers have been configured:"

                gum style \
                    --border-foreground=212 \
                    --border=double \
                    --align=center \
                    --width=50 \
                    --margin="1 2" \
                    --padding="2 4 " \
                    "$(argocd context | grep -v NAME | sed 's/^*//' | awk '{ print $2 }')"

                if ! gum confirm --default=No "Are there any additional ArgoCD servers you want to setup?"; then
                    ALL_ARGOCDS_ADDED="true"
                    break
                fi

                ARGOCD_SERVER=$(gum input --width=80 --placeholder="ArgoCD Server")

                if argocd context | grep -v NAME | sed 's/^*//' | awk '{ print $2 }' | grep -q "${ARGOCD_SERVER}"; then
                    warn "🚨 ${ARGOCD_SERVER} is already configured."
                    continue
                fi

                info "Logging into ArgoCD at ${ARGOCD_SERVER}..."
                if argocd login "${ARGOCD_SERVER}" --grpc-web --sso --skip-test-tls; then
                    info "🎉 You're successfully authenticated to $(printf '%s' "${ARGOCD_SERVER}" | awk -F: '{ print $1 }')!"
                else
                    record_failure "Argo CD ${ARGOCD_SERVER}: login failed."
                fi
            done

            if [[ -n "${ARGOCD_CURRENT_CONTEXT}" ]]; then
                argocd context "${ARGOCD_CURRENT_CONTEXT}" 1>/dev/null || \
                    warn "Could not switch Argo CD back to ${ARGOCD_CURRENT_CONTEXT}; run 'argocd context' to pick one."
            fi
        else
            warn "🚨 Your system is unable to open a browser from a cli (no xdg-open or open tools are available). Skipping ArgoCD configuration."
        fi

        if ! helm search repo artifactory --fail-on-no-result -o yaml &>/dev/null; then
            info "Adding Artifactory helm repository..."
            [[ -z "${USER_OHIOID}" ]] && USER_OHIOID="$(get_ohioid)"
            [[ -z "${ARTIFACTORY_TOKEN}" ]] && ARTIFACTORY_TOKEN="$(get_artifactory_token)"

            if [[ -n "${ARTIFACTORY_TOKEN}" ]] && [[ -n "${USER_OHIOID}" ]]; then
                helm repo add artifactory https://"${DEFAULT_ARTIFACTORY_HOSTNAME}"/artifactory/helm --username="${USER_OHIOID}" --password-stdin <<< "${ARTIFACTORY_TOKEN}" || exit 1
            else
                warn "Skipping adding Artifactory helm repository. You'll need to add it manually or rerun this script."
            fi
        else
            info "🎉 You're already authenticated to the Artifactory helm repository!"

        fi

        if ! helm search repo artifactory-push --fail-on-no-result -o yaml &>/dev/null; then
            info "Adding Artifactory helm repository with push access..."
            [[ -z "${USER_OHIOID}" ]] && USER_OHIOID="$(get_ohioid)"
            [[ -z "${ARTIFACTORY_TOKEN}" ]] && ARTIFACTORY_TOKEN="$(get_artifactory_token)"

            if [[ -n "${ARTIFACTORY_TOKEN}" ]] && [[ -n "${USER_OHIOID}" ]]; then
                helm repo add artifactory-push https://"${DEFAULT_ARTIFACTORY_HOSTNAME}"/artifactory/oit-helm --username="${USER_OHIOID}" --password-stdin <<< "${ARTIFACTORY_TOKEN}" || exit 1
            else
                warn "Skipping adding Artifactory helm repository with push access. You'll need to add it manually or rerun this script."
            fi

        else
            info "🎉 You're already authenticated to the Artifactory helm repository with push access!"
        fi

        helm repo update
    fi
fi

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
    warn "These services could not be set up:"
    for FAILED_SERVICE in "${FAILED_SERVICES[@]}"; do
        warn "  - ${FAILED_SERVICE}"
    done
    warn "Everything else has been set up. Run 'adp-connect -C' to check status."
    info "You should have the following tools installed and ready to use:"
    ls -1 "${HOME}"/.local/bin
    exit 1
fi

info "🎉 Everything should now be setup. You should have the following tools installed and ready to use:"
ls -1 "${HOME}"/.local/bin
