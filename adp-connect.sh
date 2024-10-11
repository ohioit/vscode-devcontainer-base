#!/bin/bash
HAVE_GUM="$(which gum 2>/dev/null && 'true')"
TEMP_DIR=$(mktemp -d)
FORCE_UPDATE="${FORCE_UPDATE:-""}"
ENABLE_DEBUG="${ENABLE_DEBUG:-""}"
SKIP_KUBECONFIG="${SKIP_KUBECONFIG:-""}"
FORCE_ADD_MORE_RANCHERS="${FORCE_ADD_MORE_RANCHERS:-""}"
FORCE_ADD_MORE_ARGOCD="${FORCE_ADD_MORE_ARGOCD:-""}"
FORCE_ADD_MORE_GITHUB="${FORCE_ADD_MORE_GITHUB:-""}"
ACCEPT_SUPPLY_CHAIN_SECURITY="${ACCEPT_SUPPLY_CHAIN_SECURITY:-""}"
DEFAULT_RANCHER_HOSTNAME="rancher.oit.ohio.edu"
DEFAULT_ARTIFACTORY_HOSTNAME="artifactory.oit.ohio.edu"
DEFAULT_ARGOCD_HOSTNAME="argo.ops.kube.ohio.edu"
DEFAULT_GITHUB_SERVERS=("github.ohio.edu" "github.com")
KUBE_CLIENT_CONFIG_SECRET="${KUBE_CLIENT_CONFIG_SECRET:-dev-client-saved-config}"
KUBE_CLIENT_CONFIG_CONTEXT="${KUBE_CLIENT_CONFIG_CONTEXT:-ais-devtest}"
STORE_CLIENT_CONFIG="${STORE_CLIENT_CONFIG:-true}"
HAVE_GPG="false"
SEALED_SECRETS_CONTROLLER_NAME="sealed-secrets"
SEALED_SECRETS_CONTROLLER_NAMESPACE="sealed-secrets"
USER_OHIOID=""
ARTIFACTORY_TOKEN=""

HTTP_DATA_METHODS=("POST" "PUT" "PATCH")

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT INT

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

get_ohioid() {
    info "Please enter your OHIO ID for logging into services."
    gum input --width=80 --placeholder="OHIO ID"
}

get_artifactory_token() {
    info "🐳 It's time to login to Artifactory Go to https://artifatory.oit.ohio.edu
 and login. Once you've logged in, click on your username in the top right and select:
 → Profile → Generate an API Key (not an Identity Token) → Copy the API Key and paste it here."
    gum input --width=80 --placeholder="Artifactory Token"

    echo "${ARTIFACTORY_TOKEN}"
}

compare_versions() {
  # Copilot wrote this one and I'm too lazy to fully verify or grok it.
  # Remove leading 'v' if present
  ver1="${1#v}"
  ver2="${2#v}"

  IFS='.' read -r -a ver1 <<< "$ver1"
  IFS='.' read -r -a ver2 <<< "$ver2"

  for ((i=0; i<${#ver1[@]}; i++)); do
    if [[ ${ver1[i]} -gt ${ver2[i]:-0} ]]; then
      return 1
    elif [[ ${ver1[i]} -lt ${ver2[i]:-0} ]]; then
      return 2
    fi
  done

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
    latest_release=$(echo "${latest_release_json}" | grep -e '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

    for arch in "${LOCAL_ARCH[@]}"; do
        binary_url=$(echo "$latest_release_json" | grep -Ei "browser_download_url.*$binary_name.*$LOCAL_OS.*$arch(.*$latest_release)?(\.|$format)\"" | cut -d '"' -f 4)

        if [[ -n "$binary_url" ]]; then
            break
        fi
    done

    if [[ -z "$binary_url" ]]; then
        error "❌ Error: Could not find the binary $binary_name for $LOCAL_OS/$LOCAL_ARCH in the latest release."

        if [[ "${ENABLE_DEBUG}" = "true" ]]; then
            if which yq &>/dev/null; then
                debug "JSON from GitHub:"
                yq -P -C -o json <<< "${latest_release_json}"
            else
                debug "JSON from GitHub:"
                echo "${latest_release_json}"
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

    # Remove protocol if present
    rancher_hostname=$(echo "$rancher_hostname" | sed -e 's|^[a-zA-Z]*://||')

    info "It's time to login to Rancher, follow the prompts to login. NOTE: It may take a few seconds after\
 completing the login process for the CLI to notice and continue."
    rancher_token_credential=$(rancher token --server "https://${rancher_hostname}" --user="$(whoami)" --auth-provider=azureADProvider)

    if [[ "$?" -ne 0 ]]; then
        error "❌ Error: Failed to login to Rancher."
        exit 1
    fi

    rancher_token=$(echo "${rancher_token_credential}" | yq -r '.status.token')

    if [[ "$?" -ne 0 ]] || [[ -z "$rancher_token" ]]; then
        error "❌ Error: Failed to get parse token response from Rancher."
        exit 1
    fi

    rancher_project=""
    if [[ -f "$HOME/.rancher/cli2.json" ]]; then
        rancher_project=$(yq -r '.Servers."'"${rancher_hostname}"'".project' < "$HOME/.rancher/cli2.json" | grep -v null)
    fi

    if [[ -z "$rancher_project" ]]; then
        rancher_project=$(call_rancher "$rancher_token" "https://${rancher_hostname}/v3/projects" | yq -r '.data[0].id')
        if [[ -z "$rancher_project" ]]; then
            error "❌ Error: Failed to find any projects in Rancher."
            exit 1
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

    rancher login --token="${rancher_token}" --context="${rancher_project}" --name="https://${rancher_hostname}" "https://${rancher_hostname}"

    if [[ -n "${current_context}" ]]; then
        debug "Switching back to previous server ${current_server}"
        rancher server switch "${current_server}"
    fi

    if [[ -f "$HOME/.kube/config" ]] && [[ -f "$HOME/.kube/config.rancherlogin" ]]; then
        rm "$HOME/.kube/config"
        mv "$HOME/.kube/config.rancherlogin" "$HOME/.kube/config"
    fi

    debug "Injecting credentials into Rancher CLI configuration..."
    for CLUSTER in $(rancher cluster ls --format '{{.Cluster.Name}}_{{.Cluster.ID}}'); do
        yq -i ".Servers.\"https://${rancher_hostname}\".kubeCredentials[\"${CLUSTER}\"] = ${rancher_token_credential}" "$HOME/.rancher/cli2.json"
    done
}

install_kubectl() {
    local kubectl_version="$1"

    gum spin --show-error --show-output --title="Downloading kubectl ${kubectl_version} for $LOCAL_OS/$KUBECTL_ARCH..." -- \
        curl -sL --show-error \
        "https://dl.k8s.io/release/v${kubectl_version}/bin/${LOCAL_OS}/${KUBECTL_ARCH}/kubectl" -o "$HOME/.local/bin/kubectl" || exit 1
    chmod 755 "$HOME/.local/bin/kubectl" || exit 1
    info "🎉 Successfully installed kubectl ${kubectl_version}!"
}

ALL_BINARIES_AVAILABLE="true"
for BINARY in curl tar awk sed grep; do
    if ! which "${BINARY}" &>/dev/null; then
        error "❌ Error: ${BINARY} is required but not installed. Please contact ADP for assistance and let us know what operating system you're using."
        ALL_BINARIES_AVAILABLE="false"
    fi
done

if [[ "${ALL_BINARIES_AVAILABLE}" = "false" ]]; then
    exit 1
fi

if ! grep --help | grep -q 'extended-regexp'; then
    error "❌ Error: Your version of grep does not support extended regular expressions. PPlease contact ADP for assistance and let us know what operating system you're using."
    exit 1
fi

if ! bash -c 'help readarray' &>/dev/null; then
    error "❌ Error: Your version of bash does not support readarray. Please contact ADP for assistance and let us know what operating system you're using."
    exit 1
fi

while getopts "udhIRAGKSc:s:" arg; do
    case $arg in
        h) echo "Usage: $0 [options]"
           echo
           echo "Options:"
           echo "  -d           Enable debug mode."
           echo "  -u           Force update of all tools."
           echo "  -I           Accept supply chain security risks without prompting."
           echo "  -R           Prompt to add additional Rancher servers even if some are already configured."
           echo "  -A           Prompt to add additional ArgoCD servers even if some area already configured."
           echo "  -G           Prompt to add additional GitHub servers even if some are already configured."
           echo "  -K           Skip kubectl and kubeconfig."
           echo "  -S           Don't store this client configuration in the Kubernetes cluster."
           echo "  -c <context> The Kubernetes context to use to store the client configuration. Default: $KUBE_CLIENT_CONFIG_CONTEXT"
           echo "  -s <secret>  The Kubernetes secret to use to store the client configuration. Default: $KUBE_CLIENT_CONFIG_SECRET"
           echo "  -h           Show this help message."
           exit 0 ;;
        d) ENABLE_DEBUG="true" ;;
        u) FORCE_UPDATE="true" ;;
        I) ACCEPT_SUPPLY_CHAIN_SECURITY="true" ;;
        R) FORCE_ADD_MORE_RANCHERS="true" ;;
        A) FORCE_ADD_MORE_ARGOCD="true" ;;
        G) FORCE_ADD_MORE_GITHUB="true" ;;
        K) SKIP_KUBECONFIG="true" ;;
        S) STORE_CLIENT_CONFIG="false" ;;
        c) KUBE_CLIENT_CONFIG_CONTEXT="$OPTARG" ;;
        s) KUBE_CLIENT_CONFIG_SECRET="$OPTARG" ;;
        *) error "❌  Error: Invalid option $arg." && exit 1 ;;
    esac
done

if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo "The directory $HOME/.local/bin is not in your PATH. Please add it to your shell profile."
    echo "For example, add the following line to your ~/.bashrc or ~/.zshrc:"
    echo
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo
    echo "Then reopen your terminal."

    exit 1
fi

if [[ -z "${ACCEPT_SUPPLY_CHAIN_SECURITY}" ]]; then
    if ! confirm "⚠️  This script will utilize a series of resources from \
the internet. The integrity of these cannot be assured, are you sure you want to \
continue?"; then
        info "😢 Quitting..."
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

if should_install "gum"; then
    download_latest_release "charmbracelet/gum" "gum" "tar.gz" || exit 1
    extract_download "gum" "tar.gz" || exit 1
    install --mode=0755 "${TEMP_DIR}/gum"*/"gum" "$HOME/.local/bin/gum" || exit 1
    info "🎉 Successfully installed gum!"

    HAVE_GUM="true"
fi

# This version of `yq` is written in Go and supports both
# JSON and YAML. One tool, no interperters needed.
if should_install "yq"; then
    INSANE_CHECKSUMS="true" download_latest_release "mikefarah/yq" "yq" || exit 1
    install --mode=0755 "${TEMP_DIR}/yq" "$HOME/.local/bin/yq" || exit 1
    info "🎉 Successfully installed yq!"
fi

should_install "rancher"
INSTALL_RANCHER=$?
NEEDED_RANCHER_VERSION=2.9.0

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
    install --mode=0755 "${TEMP_DIR}/rancher"*/"rancher" "$HOME/.local/bin/rancher" || exit 1
    info "🎉 Successfully installed rancher CLI!"
fi

if [[ "${STORE_CLIENT_CONFIG}" = "true" ]]; then
    if ! which gpg &>/dev/null; then
        warn "🚨 gpg is not installed. If you want to store/recall your credentials across machines, you'll need to have gpg installed on each." 1>&2
        STORE_CLIENT_CONFIG="false"
    fi
fi

debug "Checking for existing Rancher CLI configuration..."
ALL_RANCHERS_ADDED="false"
if [[ -f "$HOME/.rancher/cli2.json" ]]; then
    if [[ -z "${FORCE_ADD_MORE_RANCHERS}" ]]; then
        ALL_RANCHERS_ADDED="true"
    fi

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

    if ! gum spin --show-error --title="Checking ${SERVER}..." rancher project list; then
        rancher_login "${SERVER}"
    fi
done
rancher server switch "${RANCHER_CURRENT_SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null

info "🎉 All Rancher servers are configured and validated!"

if [[ -z "${SKIP_KUBECONFIG}" ]]; then
    info "Generating/updating kubeconfig..."

    KUBE_CONFIGS=()
    KUBE_CURRENT_CONTEXT=""
    if [[ -f "$HOME/.kube/config" ]]; then
        debug "Backing up existing kubeconfig..."
        cp "$HOME/.kube/config" "$HOME/.kube/config.bak"

        KUBE_CONFIGS+=("$HOME/.kube/config")
        KUBE_CURRENT_CONTEXT=$(yq -r '.current-context' "$HOME/.kube/config")
    else
        mkdir -p "$HOME/.kube"
    fi

    debug "Current kubeconfig context: ${KUBE_CURRENT_CONTEXT}"

    RANCHER_CURRENT_SERVER=$(rancher_current_server)
    KUBE_CLUSTER_VERSIONS=()
    for SERVER in $(yq -r '.Servers | to_entries[] | .key' < "$HOME/.rancher/cli2.json" | grep -v rancherDefault); do
        rancher server switch "${SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null
        for CLUSTER in $(rancher cluster list | grep -v CURRENT | sed 's/^*//g' | awk '{ print $1 }'); do
            if [[ -z "${SKIP_KUBECONFIG}" ]]; then
                TEMP_KUBE_CONFIG=$(echo "${SERVER}-${CLUSTER}" | base64)
                rancher cluster kf "${CLUSTER}" > "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml"

                yq -r '.users[] | .name' "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml" | while read -r KUBECONFIG_USER; do
                    debug "Configuring kubectl to use Rancher CLI authentication for ${KUBECONFIG_USER}..."

                    yq -i '.users[] |= (
                        select(.name == "'"${KUBECONFIG_USER}"'") |
                            .user |= (
                                del(.token) |
                                    .exec = {
                                        "apiVersion": "client.authentication.k8s.io/v1beta1",
                                        "command": "rancher",
                                        "args": [
                                            "token",
                                            "--server='"${SERVER}"'",
                                            "--cluster='"${CLUSTER}"'",
                                            "--user='"${KUBECONFIG_USER}"'",
                                            "--auth-provider=azureADProvider"
                                        ]
                                    }
                            )
                    )' "${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml"
                done

                KUBE_CONFIGS+=("${TEMP_DIR}/${TEMP_KUBE_CONFIG}.yaml")
            fi
            KUBE_CLUSTER_VERSIONS+=("$(rancher inspect --type=cluster "${CLUSTER}" | yq -r '.version.gitVersion')")
        done
    done
    rancher server switch "${RANCHER_CURRENT_SERVER}" 2> >(grep -v "Saving config" >&2) >/dev/null
    readarray -t KUBE_CLUSTER_VERSIONS < <(printf '%s\n' "${KUBE_CLUSTER_VERSIONS[@]}" | sort -u)

    debug "Found the following Kubernetes versions: ${KUBE_CLUSTER_VERSIONS[*]}"

    KUBE_LATEST_VERSION=$(version_sort "${KUBE_CLUSTER_VERSIONS[@]}" | tail -n 1)
    KUBE_OLDEST_VERSION=$(version_sort "${KUBE_CLUSTER_VERSIONS[@]}" | head -n 1)

    debug "Latest Kubernetes version: ${KUBE_LATEST_VERSION}"
    debug "Oldest Kubernetes version: ${KUBE_OLDEST_VERSION}"

    if should_install "kubectl"; then
        install_kubectl "${KUBE_LATEST_VERSION}" || exit 1
    else
        if [[ "$(which kubectl)" != "$HOME/.local/bin/kubectl" ]]; then
            warn "🚨 kubectl is already installed but managed by a different tool. Proceeding with your existing kubectl."
            rancher kubectl version >/dev/null
        else
            if rancher kubectl version 2>&1 | grep -qi "version difference"; then
                info "🔍 Found a large version difference between kubectl and the clusters. Upgrading kubectl..."
                install_kubectl "${KUBE_LATEST_VERSION}" || exit 1
            fi
        fi
    fi

    OIFS=${IFS}; IFS=":"; KUBECONFIG="${KUBE_CONFIGS[*]}"; IFS=${OIFS}
    KUBECONFIG=${KUBECONFIG} kubectl config view --flatten > "$HOME/.kube/config"

    if [[ -f "$HOME/.kube/config.bak" ]]; then
        for CONTEXT in $(yq eval -o json -I=0 '.contexts[]' "$HOME/.kube/config.bak"); do
            NAMESPACE=$(yq -r '.context.namespace' <<< "${CONTEXT}")
            NAME=$(yq -r '.name' <<< "${CONTEXT}")

            if [[ -z "$(yq -r '.contexts[] | select(.name == "'"${NAME}"'")' "$HOME/.kube/config" 2>/dev/null)" ]]; then
                continue
            fi

            if [[ "${NAMESPACE}" = "null" ]]; then
                kubectl config set-context "${NAME}" --namespace "" 1>/dev/null
            else
                kubectl config set-context "${NAME}" --namespace "${NAMESPACE}" 1>/dev/null
            fi
        done
    fi

    if [[ -n "${KUBE_CURRENT_CONTEXT}" ]]; then
        kubectl config use-context "${KUBE_CURRENT_CONTEXT}" >/dev/null
    else
        if [[ "$(rancher project ls -q | wc -l)" -gt 1 ]]; then
            info "Select your default Kubernetes context:"
        fi
        echo "Select your default Kubernetes cluster and project:"
        rancher context switch

        KUBE_CURRENT_CONTEXT=$(rancher context current | awk '{ print $1 }' | awk -F: '{ print $2 }')

        kubectl config use-context "${KUBE_CURRENT_CONTEXT}" >/dev/null
    fi

    CURRENT_NAMESPACE=$(kubectl config view --minify --output 'jsonpath={.contexts[?(@.name=="'$(kubectl config current-context)'")].context.namespace}')

    if [[ -n "${CURRENT_NAMESPACE}" ]]; then
        if ! (rancher namespaces -q | grep -q "${CURRENT_NAMESPACE}"); then
            warn "Your current namespace ${CURRENT_NAMESPACE} does not exist in project $(rancher context current | sed 's/.*Project://')".
            CURRENT_NAMESPACE=""
        fi
    fi

    if [[ -z "${CURRENT_NAMESPACE}" ]]; then
        info "Select your default namespace:"
        # shellcheck disable=SC2046
        DEFAULT_NAMESPACE=$(gum choose --select-if-one --ordered \
            $(rancher namespaces -q | sort | tr '\n' ' '))
        kubectl config set-context --current --namespace="${DEFAULT_NAMESPACE}" >/dev/null
    fi

    info "🎉 You now have access to $(yq '.contexts | length' ~/.kube/config) Kubernetes contexts!"
    info "Your default context is $(kubectl config current-context)."
    info "You'll be using the namespace $(kubectl config view --minify --output 'jsonpath={..namespace}') by default."
fi

# We do this whether or not we skip kubeconfig because we want to ensure
# the kubeconfig is secure.
if [[ -f "$HOME/.kube/config" ]]; then
    chmod 600 "$HOME/.kube/config"
fi

if should_install "kubeseal"; then
    download_latest_release "bitnami-labs/sealed-secrets" "kubeseal" "tar.gz" || exit 1
    extract_download "kubeseal" "tar.gz" || exit 1
    install --mode=0755 "${TEMP_DIR}/kubeseal" "$HOME/.local/bin/kubeseal" || exit 1
    info "🎉 Successfully installed kubeseal!"
fi

info "Fetching Sealed Secrets sealing certificates..."
for CONTEXT in $(yq eval -o json -I=0 '.contexts[]' "$HOME/.kube/config"); do
    NAME=$(yq -r '.name' <<< "${CONTEXT}")

    if [[ ! "${NAME}" =~ -fqdn$ ]]; then
        kubeseal --context="${NAME}" --request-timeout=2s --fetch-cert --controller-name="${SEALED_SECRETS_CONTROLLER_NAME}" --controller-namespace="${SEALED_SECRETS_CONTROLLER_NAMESPACE}" > "$HOME/.kube/$NAME.pem"
    fi
done

if should_install "k9s"; then
    download_latest_release "derailed/k9s" "k9s" "tar.gz" || exit 1
    extract_download "k9s" "tar.gz" || exit 1
    install --mode=0755 "${TEMP_DIR}/k9s" "$HOME/.local/bin/k9s" || exit 1
    info "🎉 Successfully installed k9s!"
fi

if should_install "skaffold"; then
    download_latest_release "GoogleContainerTools/skaffold" "skaffold" || exit 1
    install --mode=0755 "${TEMP_DIR}/skaffold" "$HOME/.local/bin/skaffold" || exit 1
    info "🎉 Successfully installed skaffold!"
fi

if should_install "gh"; then
    download_latest_release "cli/cli" "gh" "tar.gz" || exit 1
    extract_download "gh" "tar.gz" || exit 1
    mv "${TEMP_DIR}"/gh_* "${TEMP_DIR}/gh"
    install --mode=0755 "${TEMP_DIR}/gh/bin/gh" "$HOME/.local/bin/gh" || exit 1
    info "🎉 Successfully installed gh!"
fi

for GITHUB_SERVER in "${DEFAULT_GITHUB_SERVERS[@]}"; do
    if gh auth status --hostname="${GITHUB_SERVER}" &>/dev/null; then
        info "🎉 You're already authenticated to ${GITHUB_SERVER}!"
    else
        info "🔐 Authenticating to ${GITHUB_SERVER}..."
        gh auth login --hostname="${GITHUB_SERVER}" --web || exit 1
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

    if gh auth status --hostname="${GITHUB_SERVER}" &>/dev/null; then
        warn "🚨 ${GITHUB_SERVER} is already configured."
        continue
    fi

    info "🔐 Authenticating to ${GITHUB_SERVER}..."
    gh auth login --hostname="${GITHUB_SERVER}" --web || exit 1

    info "🎉 You're successfully authenticated to ${GITHUB_SERVER}!"
done

if ! git config --global --get init.defaultBranch &>/dev/null; then
    git config --global init.defaultBranch main
fi

if ! git config --global --get user.name &>/dev/null; then
    git config --global user.name "$(gum input --width=80 --placeholder="Your name for git commits:")" || exit 1
fi

if ! git config --global --get user.email &>/dev/null; then
    git config --global user.email "$(gum input --width=80 --placeholder="Your OHIO email for git commits:")" || exit 1
fi

info "You'll be committing as $(git config --global --get user.name) <$(git config --global --get user.email)>."

if ! which git &>/dev/null; then
    warn "🚨 git is not installed. While this script does install the Github CLI, you still need to install\
 git itself. Please follow the appropriate steps for your operating system. On Windows, please install git\
 inside of WSL."
fi

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
    if ! docker login docker."${DEFAULT_ARTIFACTORY_HOSTNAME}" <<< "" &>/dev/null; then
        [[ -z "${USER_OHIOID}" ]] && USER_OHIOID="$(get_ohioid)"
        [[ -z "${ARTIFACTORY_TOKEN}" ]] && ARTIFACTORY_TOKEN="$(get_artifactory_token)"

        if [[ -z "${ARTIFACTORY_TOKEN}" ]] || [[ -z "${USER_OHIOID}" ]]; then
            warn "Skipping Artifactory login for Docker and Helm. You'll need to configure these manually or rerun this script."
        else
            if docker login -u "$(USER_OHIOID)" --password-stdin docker."${DEFAULT_ARTIFACTORY_HOSTNAME}" <<< "$(ARTIFACTORY_TOKEN)"; then
                info "🎉 Successfully logged into Artifactory's Docker Registry!"
            else
                exit 1
            fi
        fi
    else
        info "🎉 You're already logged into Artifactory's Docker Registry!"
    fi
fi

if should_install "argocd"; then
    download_latest_release "argoproj/argo-cd" "argocd" || exit 1
    install --mode=0755 "${TEMP_DIR}/argocd" "$HOME/.local/bin/argocd" || exit 1
    info "🎉 Successfully installed ArgoCD!"
fi

if which xdg-open &>/dev/null || which open &>/dev/null; then
    if ! argocd context | grep -v NAME | sed 's/^*//' | awk '{ print $2 }' | grep -q "${DEFAULT_ARGOCD_HOSTNAME}"; then
        info "Logging into ArgoCD at ${DEFAULT_ARGOCD_HOSTNAME}..."
        argocd login "${DEFAULT_ARGOCD_HOSTNAME}" --grpc-web --sso --skip-test-tls || exit 1
    fi

    ARGOCD_CURRENT_CONTEXT="$(argocd context | grep '\*' | awk '{ print $2 }')"
    for ARGOCD_SERVER in $(argocd context | grep -v NAME | sed 's/^*//' | awk '{ print $2 }'); do
        argocd context "${ARGOCD_SERVER}" 1>/dev/null || exit 1
        if ! argocd version &>/dev/null; then
            info "Need to relogin to ArgoCD at ${ARGOCD_SERVER}..."
            argocd login "${ARGOCD_SERVER}" --grpc-web --sso --skip-test-tls || exit 1
        else
            info "🎉 You're successfully authenticated to ArgoCD at $(echo "${ARGOCD_SERVER}" | awk -F: '{ print $1 }')!"
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
        argocd login "${ARGOCD_SERVER}" --grpc-web --sso --skip-test-tls || exit 1

        info "🎉 You're successfully authenticated to $(echo "${ARGOCD_SERVER}" | awk -F: '{ print $1 }')!"
    done

    argocd context "${ARGOCD_CURRENT_CONTEXT}" 1>/dev/null || exit 1
else
    warn "🚨 Your system is unable to open a browser from a cli (no xdg-open or open tools are available). Skipping ArgoCD configuration."
fi

if should_install "helm"; then
    gum spin --show-error --title="Downloading Helm Installer..." -- \
        curl -Lo "${TEMP_DIR}/get-helm-3" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 755 "${TEMP_DIR}/get-helm-3"
    HELM_INSTALL_DIR="$HOME/.local/bin" USE_SUDO="false" gum spin --show-error \
        --title="Installing Helm..." "${TEMP_DIR}/get-helm-3" || exit 1
    info "🎉 Successfully installed Helm!"
fi

if ! helm search repo artifactory --fail-on-no-result -o yaml &>/dev/null; then
    if [[ -n "${ARTIFACTORY_TOKEN}" ]] && [[ -n "${USER_OHIOID}" ]]; then
        info "Adding Artifactory helm repository..."
        [[ -z "${USER_OHIOID}" ]] && USER_OHIOID="$(get_ohioid)"
        [[ -z "${ARTIFACTORY_TOKEN}" ]] && ARTIFACTORY_TOKEN="$(get_artifactory_token)"
        helm repo add artifactory https://"${DEFAULT_ARTIFACTORY_HOSTNAME}"/artifactory/helm --username="${USER_OHIOID}" --password-stdin <<< "${ARTIFACTORY_TOKEN}" || exit 1
    fi
else
    info "🎉 You're already authenticated to the Artifactory helm repository!"
fi

if ! helm search repo artifactory-push --fail-on-no-result -o yaml &>/dev/null; then
    if [[ -n "${ARTIFACTORY_TOKEN}" ]] && [[ -n "${USER_OHIOID}" ]]; then
        info "Adding Artifactory helm repository with push access..."
        [[ -z "${USER_OHIOID}" ]] && USER_OHIOID="$(get_ohioid)"
        [[ -z "${ARTIFACTORY_TOKEN}" ]] && ARTIFACTORY_TOKEN="$(get_artifactory_token)"
        helm repo add artifactory-push https://"${DEFAULT_ARTIFACTORY_HOSTNAME}"/artifactory/oit-helm --username="${USER_OHIOID}" --password-stdin <<< "${ARTIFACTORY_TOKEN}" || exit 1
    fi
else
    info "🎉 You're already authenticated to the Artifactory helm repository with push access!"
fi
