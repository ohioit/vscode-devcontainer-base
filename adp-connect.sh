#!/bin/bash
HAVE_GUM="$(which gum 2>/dev/null && 'true')"
TEMP_DIR=$(mktemp -d)
FORCE_UPDATE="${FORCE_UPDATE:-""}"
ENABLE_DEBUG="${ENABLE_DEBUG:-""}"
ACCEPT_SUPPLY_CHAIN_SECURITY="${ACCEPT_SUPPLY_CHAIN_SECURITY:-""}"
DEFAULT_RANCHER_HOSTNAME="rancher.oit.ohio.edu"

HTTP_DATA_METHODS=("POST" "PUT" "PATCH")

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT INT

log() {
    if [[ "${HAVE_GUM}" ]]; then
        gum log "$1"
    else
        echo -e "$1"
    fi
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
        read -p "$1 [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

call_rancher() {
    local token="$1"
    local url="$2"
    local method="$3:-GET"
    local data="$4"

    if [[ ${HTTP_DATA_METHODS[*]} =~ $method ]]; then
        RESPONSE=$(curl -s -X "$method" -H "Authorization: Bearer ${token}" -H "Accept: application/json" -H "Content-Type: application/json" -d "$data" "$url")
        RETURN=$?
    else
        RESPONSE=$(curl -s -H "Authorization: Bearer ${token}" -H "Accept: application/json" "$url")
        RETURN=$?
    fi

    if [[ $RETURN -ne 0 ]]; then
        error "❌ Error: Failed to call Rancher API at $url. Error code $RETURN."
        return 1
    fi

    if [[ "$(yq -r '.type' <<< "$RESPONSE")" == "error" ]]; then
        error "❌ $(yq -r '.message' <<< "$RESPONSE")"
        return 1
    fi

    echo "$RESPONSE"
}

download_latest_release() {
    local repo="$1"
    local binary_name="$2"
    local format="$3"

    local os
    local arch
    local arches
    local latest_release_json
    local checksum_files=("checksums" "checksums.txt" "sha256sum" "sha256sum.txt")
    local checksum_url
    local binary_url
    local download_result

    if [[ -n "${format}" ]]; then
        format=".$format"
    fi

    # Determine the operating system and architecture
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$arch" in
        x86_64) arches=("amd64" "x86_64") ;;
        *) arches=("$arch") ;;
    esac

    info "🔍 Searching for the latest release of $binary_name from $repo..."
    # Fetch the latest release data from GitHub API
    latest_release_json=$(curl -s "https://api.github.com/repos/$repo/releases/latest")

    for arch in "${arches[@]}"; do
        binary_url=$(echo "$latest_release_json" | grep -Ei "browser_download_url.*$binary_name.*$os.*$arch(\.|$format)\"" | cut -d '"' -f 4)

        if [[ -n "$binary_url" ]]; then
            break
        fi
    done

    if [[ -z "$binary_url" ]]; then
        error "❌  Error: Could not find the binary $binary_name for $os/$arch in the latest release."
        return 1
    fi

    binary_download_name="$(basename "${binary_url}")"

    if [[ -n "${HAVE_GUM}" ]]; then
        gum spin --show-error --show-output --title="Downloading $binary_name for $os/$arch..." -- \
            curl -sL --show-error "$binary_url" -o "${TEMP_DIR}/${binary_download_name}"
    else
        info "🔗 Downloading $binary_name for $os/$arch..."
        curl -L --show-error "$binary_url" -o "${TEMP_DIR}/${binary_download_name}"
    fi

    for checksum_file in "${checksum_files[@]}"; do
        checksum_url=$(echo "$latest_release_json" | grep -E "browser_download_url.*$checksum_file\"" | cut -d '"' -f 4)

        if [[ -n "$checksum_url" ]]; then
            break
        fi
    done

    if [[ -n "$checksum_url" ]] && ! [[ "${INSANE_CHECKSUMS}" = "true" ]]; then
        if [[ -n "${HAVE_GUM}" ]]; then
            gum spin --show-error --show-output --title="Downloading checksums..." -- \
                curl -sL --show-error "$checksum_url" -o "${TEMP_DIR}/${binary_name}_checksums"
        else
            info -e "🔗 Downloading checksums..."
            curl -L --show-error "$checksum_url" -o "${TEMP_DIR}/${binary_name}_checksums"
        fi

        if ! [[ -f "${TEMP_DIR}/${binary_name}_checksums" ]]; then
            error "❌  Error: Failed to download checksums."
            return 1
        fi

        checksum_output=$(sha256sum -c "${TEMP_DIR}/${binary_name}_checksums" 2>&1)
        grep -q "OK" <<< "$checksum_output"
        check_result=$?
        rm "${TEMP_DIR}/${binary_name}_checksums"

        if ! [[ ${check_result} -eq 0 ]]; then
            error "❌ Checksum of ${binary_name} verification failed: ${checksum_output}"
            cat "${TEMP_DIR}/${binary_name}_checksums"
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
        zip)
            unzip -q "${TEMP_DIR}/${binary_name}.$format" -d "$TEMP_DIR"
            rm "${TEMP_DIR}/${binary_name}.$format"
            ;;
        *)
            error "❌  Error: Unsupported format $format."
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

rancher_current_server() {
    yq -r '.CurrentServer' < "$HOME/.rancher/cli2.json"
}

rancher_login() {
    local rancher_hostname="$1"
    local rancher_token=""
    local rancher_user_id=""
    local rancher_project=""
    local current_server=""

    if [[ -z "$rancher_hostname" ]]; then
        error "❌ Error: No Rancher hostname provided."
        exit 1
    fi

    info "It's time to login to Rancher. Please go to https://${rancher_hostname}/dashboard/account and login. \
Once you've logged in, generate a new API Key. The scope you choose will limit the clusters you can interact with. \
Use \"no scope\" if you want to interact with all clusters. Once you've generated the key, copy the bearer token \
and paste it here."

    rancher_token=$(gum input --width=80 --placeholder="Rancher Bearer Token")

    rancher_user_id=$(call_rancher "$rancher_token" "https://${rancher_hostname}/v3/users?me=true" | yq -r '.data[0].id')
    if [[ -z "$rancher_user_id" ]]; then
        error "❌ Error: Failed to get user ID from Rancher."
        exit 1
    fi

    debug "Logged in user $rancher_user_id"

    if [[ -f "$HOME/.rancher/cli2.json" ]]; then
        rancher_project=$(yq -r '.Servers."'"${rancher_hostname}"'".project' < "$HOME/.rancher/cli2.json" | grep -v null)
    else
        rancher_project=$(call_rancher "$rancher_token" "https://${rancher_hostname}/v3/projects" | yq -r '.data[0].id')
        if [[ -z "$rancher_project" ]]; then
            error "❌ Error: Failed to find any projects in Rancher."
            exit 1
        fi
    fi

    debug "Using project $rancher_project"

    current_server=""
    if [[ -f "$HOME/.rancher/cli2.json" ]]; then
        rancher_current_server
        debug "Current server is $current_server"
    fi

    rancher login --token="${rancher_token}" --context="${rancher_project}" --name="${rancher_hostname}" "https://${rancher_hostname}"

    if [[ -n "${current_context}" ]]; then
        debug "Switching back to previous server ${current_server}"
        rancher server switch "${current_server}"
    fi
}

while getopts "udhI" arg; do
    case $arg in
        h) echo "Usage: $0 [options]"
           echo
           echo "Options:"
           echo "  -d  Enable debug mode."
           echo "  -u  Force update of all tools."
           echo "  -I  Accept supply chain security risks without prompting."
           exit 0 ;;
        d) ENABLE_DEBUG="true" ;;
        u) FORCE_UPDATE="true" ;;
        I) ACCEPT_SUPPLY_CHAIN_SECURITY="true" ;;
        *) error "❌  Error: Invalid option." && exit 1 ;;
    esac
done


if [[ -z "${ACCEPT_SUPPLY_CHAIN_SECURITY}" ]]; then
    if ! confirm "⚠️ This script will utilize a series of resources from \
the internet. The integrity of these cannot be assured, are you sure you want to \
continue?"; then
        info "😢  Quitting..."
        exit 1
    fi
else
    warn "🔓 This script will utilize a series of resources from the internet \
the integrity of these cannot be assured. You've accepted this risk with the -I flag or
the ACCEPT_SUPPLY_CHAIN_SECURITY environment variable. Continuing."
fi

if ! [[ -d "$HOME/.local/bin" ]]; then
    mkdir -p "$HOME/.local/bin"
fi

PATH="$HOME/.local/bin:$PATH"

if should_install "gum"; then
    download_latest_release "charmbracelet/gum" "gum" "tar.gz" || exit 1
    extract_download "gum" "tar.gz" || exit 1
    install --mode=0755 "${TEMP_DIR}/gum"*/"gum" "$HOME/.local/bin/gum" || exit 1
    info "🎉 Successfully installed gum!"

    HAVE_GUM="true"
fi

if should_install "yq"; then
    INSANE_CHECKSUMS="true" download_latest_release "mikefarah/yq" "yq" || exit 1
    install --mode=0755 "${TEMP_DIR}/yq" "$HOME/.local/bin/yq" || exit 1
    info "🎉 Successfully installed yq!"
fi

if should_install "rancher"; then
    download_latest_release "rancher/cli" "rancher" "tar.gz" || exit 1
    extract_download "rancher" "tar.gz" || exit 1
    install --mode=0755 "${TEMP_DIR}/rancher"*/"rancher" "$HOME/.local/bin/rancher" || exit 1
    info "🎉 Successfully installed rancher CLI!"
fi

debug "Checking for existing Rancher CLI configuration..."
if [[ -f "$HOME/.rancher/cli2.json" ]]; then
    debug "Validating existing configuration..."
    if ! [[ "$(yq -r '.Server.rancherDefault' < "$HOME/.rancher/cli2.json")" = "null" ]]; then
        warn "🚨 A 'rancherDefault' entry exists in your configuration and is known to cause problems. It's\
recommended to clear your config and start over."
        if confirm "Would you like to clear your Rancher CLI configuration?"; then
            rm -f "$HOME/.rancher/cli2.json"
            rancher_login "${DEFAULT_RANCHER_HOSTNAME}"
        fi
    fi

    if [[ "$(yq -r '.Servers | length' < "$HOME/.rancher/cli2.json")" = "0" ]]; then
        debug "Found $(yq -r '.Servers | length' < "$HOME/.rancher/cli2.json") servers in this configuration."
        rancher_login "${DEFAULT_RANCHER_HOSTNAME}"
    fi
else
    rancher_login "${DEFAULT_RANCHER_HOSTNAME}"
fi

ALL_RANCHERS_ADDED="false"
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

    RANCHER_HOSTNAME=$(gum input --width=80 --placeholder="Additional Rancher Hostname")

    rancher_login "${RANCHER_HOSTNAME}"
done

info "Validating all Rancher servers..."
RANCHER_CURRENT_SERVER=$(rancher_current_server)
for SERVER in $(yq -r '.Servers | to_entries[] | .key' < "$HOME/.rancher/cli2.json" | grep -v rancherDefault); do
    rancher server switch "${SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null
    gum spin --show-error --title="Checking ${SERVER}..." rancher project list
done
rancher server switch "${RANCHER_CURRENT_SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null

info "🎉 All Rancher servers are configured and validated!"
info "Generating kubeconfig..."

if [[ -f "$HOME/.kube/config" ]]; then
    debug "Backing up existing kubeconfig..."
    cp "$HOME/.kube/config" "${TEMP_DIR}/kubeconfig.yaml"
fi

RANCHER_CURRENT_SERVER=$(rancher_current_server)
for SERVER in $(yq -r '.Servers | to_entries[] | .key' < "$HOME/.rancher/cli2.json" | grep -v rancherDefault); do
    rancher server switch "${SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null
    for CLUSTER in $(rancher cluster list | grep -v CURRENT | sed 's/^*//g' | awk '{ print $1 }'); do
        rancher cluster kf "${CLUSTER}" > "${TEMP_DIR}/${SERVER}-${CLUSTER}.yaml"
        echo "===== ORIGINAL KUBECONFIG ===="
        cat "${TEMP_DIR}/kubeconfig.yaml"
        echo "===== NEW KUBECONFIG ===="
        yq -n 'load("'"${TEMP_DIR}/kubeconfig.yaml"'") *+d load("'"${TEMP_DIR}/${SERVER}-${CLUSTER}.yaml"'")'
    done
done
rancher server switch "${RANCHER_CURRENT_SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null

