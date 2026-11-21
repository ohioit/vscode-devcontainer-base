#!/bin/bash
# Copies the host's Docker and Helm registry logins into the container so
# `docker` and `helm` work the same whether or not VS Code is attached (for
# example with the devcontainer CLI alone).
#
# Writes:
#   ${DOCKER_CONFIG}/config.json          host Docker logins
#   ~/.config/helm/registry/config.json   host Docker logins + host Helm logins
#                                         (Helm's win for a registry in both)
#
# The image sets DOCKER_CONFIG to a directory VS Code doesn't touch. VS Code's
# Dev Containers extension rewrites ~/.docker/config.json to forward Docker
# credentials to the host, but that only works while VS Code is attached; with
# DOCKER_CONFIG set elsewhere it is simply unused. Helm checks its own file
# first and then falls back to ${DOCKER_CONFIG}/config.json; Docker logins are
# also merged into Helm's file so Helm works even without DOCKER_CONFIG.
#
# Only inline credentials (`auths.<host>.auth` or `identitytoken`) are kept.
# Logins held in a host keychain (`credsStore`/`credHelpers`, e.g. Docker
# Desktop or the macOS keychain) can't be read from inside the container, and
# copying those references would break `docker`/`helm` here, so they're left
# out and listed. Nothing else from the host's Docker config (contexts,
# plugins, proxies) is copied, since it would point at host paths.
#
# The host is the source of truth: a file is replaced whenever its host
# sources exist, so logins made inside the container last until then. Never
# prints credentials.
#
# Usage: sync-registry-credentials [registry-to-check ...]
#   Each registry given is reported as usable or not (e.g.
#   docker.artifactory.oit.ohio.edu).

set -o pipefail

DOCKER_CONFIG_JSON="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
HELM_REGISTRY_CONFIG_JSON="${HELM_REGISTRY_CONFIG_JSON:-${HOME}/.config/helm/registry/config.json}"

if [[ -z "${HOST_HOME}" ]] || [[ ! -d "${HOST_HOME}" ]]; then
    echo "Note: The host home directory isn't available, so registry logins can't be shared with the container." 1>&2
    exit 0
fi

HOST_DOCKER_CONFIGS=("${HOST_HOME}/.docker/config.json")
# Linux/WSL, then Mac OS. Later files win for a registry in both.
HOST_HELM_CONFIGS=(
    "${HOST_HOME}/.config/helm/registry/config.json"
    "${HOST_HOME}/Library/Preferences/helm/registry/config.json"
)

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Copies each existing, valid host file into TEMP_DIR and prints the copies' paths.
read_host_configs() {
    local kind="$1"
    shift
    local candidate copy index=0

    for candidate in "$@"; do
        [[ -e "${candidate}" ]] || continue

        copy="${TEMP_DIR}/${kind}-${index}.json"
        index=$((index + 1))
        # shellcheck disable=SC2024 # Only reading the host file needs root.
        sudo cat "${candidate}" > "${copy}"
        if jq -e 'type == "object"' "${copy}" > /dev/null 2>&1; then
            echo "✓ Found ${kind} registry logins at ${candidate}" 1>&2
            echo "${copy}"
        else
            echo "Warning: ${candidate} isn't valid JSON; ignoring it." 1>&2
        fi
    done
}

mapfile -t DOCKER_SOURCES < <(read_host_configs Docker "${HOST_DOCKER_CONFIGS[@]}")
mapfile -t HELM_SOURCES < <(read_host_configs Helm "${HOST_HELM_CONFIGS[@]}")

# shellcheck disable=SC2016 # jq programs, not shell.
MERGED_AUTHS='reduce .[] as $config ({}; . * ($config.auths // {}))'
INLINE='with_entries(select((.value.auth // .value.identitytoken // "") != ""))'

# Writes {auths: <inline logins merged from the given files>} to $1, mode 600.
write_config() {
    local destination="$1"
    shift

    if ! jq -s "{auths: (${MERGED_AUTHS} | ${INLINE})}" "$@" > "${TEMP_DIR}/out.json"; then
        echo "Warning: Could not read the host's registry logins for ${destination}." 1>&2
        return 1
    fi
    mkdir -p "$(dirname "${destination}")"
    sudo install -m 600 -o vscode -g vscode "${TEMP_DIR}/out.json" "${destination}"
}

STATUS=0
if [[ ${#DOCKER_SOURCES[@]} -gt 0 ]]; then
    write_config "${DOCKER_CONFIG_JSON}" "${DOCKER_SOURCES[@]}" || STATUS=1
fi
if [[ $((${#DOCKER_SOURCES[@]} + ${#HELM_SOURCES[@]})) -gt 0 ]]; then
    write_config "${HELM_REGISTRY_CONFIG_JSON}" "${DOCKER_SOURCES[@]}" "${HELM_SOURCES[@]}" || STATUS=1

    USABLE="$(jq -r '.auths | keys | join(", ")' "${HELM_REGISTRY_CONFIG_JSON}" 2>/dev/null)"
    KEYCHAIN_ONLY="$(jq -s -r "(${MERGED_AUTHS}) as \$all | (\$all | ${INLINE} | keys) as \$inline
        | \$all | keys - \$inline | join(\", \")" "${DOCKER_SOURCES[@]}" "${HELM_SOURCES[@]}")"

    echo "✓ Registry logins copied from the host: ${USABLE:-(none)}"
    if [[ -n "${KEYCHAIN_ONLY}" ]]; then
        echo "Note: These registry logins are kept in a host keychain and can't be shared with the container: ${KEYCHAIN_ONLY}. Log in without a keychain on the host, or run 'docker login <registry>' inside the container." 1>&2
    fi
else
    echo "Note: No Docker or Helm registry logins were found on the host." 1>&2
fi

if [[ -z "${DOCKER_CONFIG}" ]]; then
    echo "Note: DOCKER_CONFIG isn't set, so VS Code may replace ${DOCKER_CONFIG_JSON} with credential forwarding that only works while it's attached." 1>&2
fi

has_login() {
    [[ "$(jq -r --arg registry "$2" '.auths // {} | has($registry)' "$1" 2>/dev/null)" = "true" ]]
}

for REGISTRY in "$@"; do
    if has_login "${DOCKER_CONFIG_JSON}" "${REGISTRY}"; then
        echo "✓ Docker and Helm are logged into ${REGISTRY}"
    elif has_login "${HELM_REGISTRY_CONFIG_JSON}" "${REGISTRY}"; then
        echo "✓ Helm is logged into ${REGISTRY} (Docker isn't; run 'docker login ${REGISTRY}' if you need it)"
    else
        echo "Note: No usable login for ${REGISTRY}. Log in on the host (docker login ${REGISTRY}), or run 'docker login ${REGISTRY}' inside the container." 1>&2
    fi
done

exit "${STATUS}"
