#!/bin/bash
PRE_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/pre-start
POST_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/post-start

if [[ -n "${HOST_HOME}" ]] && [[ -d "${HOST_HOME}/.devcontainer/hooks.d/pre-start" ]]; then
    echo "Running user pre-configure hooks..."
    for HOOK in "${HOST_HOME}/.devcontainer/hooks.d/pre-start}"/*; do
        echo " - ${HOOK}..."
        ${HOOK}
    done
fi

if [[ -d "${PRE_CONFIG_HOOKS}" ]] && [ "$(ls -A "${PRE_CONFIG_HOOKS}")" ]; then
    echo "Running image pre-configure hooks..."
    for HOOK in "${PRE_CONFIG_HOOKS}"/*; do
        echo " - ${HOOK}..."
        ${HOOK}
    done
fi

mkdir -p /home/vscode/.docker /home/vscode/.kube /home/vscode/.config/helm || true
sudo mkdir -p /root/.config || true

sudo ln -sf /home/vscode/.docker /root/.docker
sudo ln -sf /home/vscode/.kube /root/.kube
sudo ln -sf /home/vscode/.config/helm /root/.config/helm

echo "Setting up Docker..."
if [[ -e /var/run/docker.sock ]]; then
    sudo groupadd -r -g "$(stat -c '%g' /var/run/docker.sock)" docker
    sudo gpasswd -a vscode docker
fi

if [[ -z "${HOST_HOME}" ]]; then
    echo "Warning: HOST_HOME environment variable is not, unable to setup user customizations. This means that things like docker, helm, kubectl, and skaffold will not work" 1>&2
elif [[ ! -d "${HOST_HOME}" ]]; then
    echo "Warning: Your home directory does not seem to be available at ${HOST_HOME}. This means things like docker, helm, kubectl, and skaffold will not work" 1>&2
else
    echo "Setting up Docker credentials..."
    if [[ -e "${HOST_HOME}/.docker/config.json" ]]; then
        sudo jq 'del(.credsStore)' "${HOST_HOME}/.docker/config.json" > /home/vscode/.docker/config.json
    else
        echo "Warning: Docker credentials not found in ${HOST_HOME}/.docker/config.json, you will be unable to use Artifactory until this is setup." 1>&2
    fi

    echo "Setting up Kubernetes..."

    if [[ ! -e "${HOST_HOME}/.kube/config" ]]; then
        echo "Warning: Kubeconfig not found in ${HOST_HOME}/.kube/config. Pleaese go to https://rancher.oit.ohio.edu and setup your local kubeconfig. Your Kubernetes cluster will not be accessible until you do this and restart this container." 1>&2
    else
        sudo cp "${HOST_HOME}/.kube/config" /home/vscode/.kube/config
        sudo chown vscode:vscode /home/vscode/.kube/config
    fi

    echo "Setting up Helm..."

    if [[ -e "${HOST_HOME}/.config/helm/repositories.yaml" ]]; then
        HELM_REPOSITORIES_YAML=/home/vscode/.config/helm/repositories.yaml
        sudo cp "${HOST_HOME}/.config/helm/repositories.yaml" "${HELM_REPOSITORIES_YAML}"
        sudo chown vscode:vscode "${HELM_REPOSITORIES_YAML}"
    else
        echo "Note: No user helm repositories were found in ${HOST_HOME}/.config/helm/repositories.yaml. You will not be able to use helm charts in Artifactory until this is setup." 1>&2
    fi

    for WORKSPACE in /workspaces/*; do
        if [[ -e "${WORKSPACE}/helm/Chart.yaml" ]]; then
            for DEPENDENCY in $(helm dep list "${WORKSPACE}/helm" | grep -v NAME | awk '{ print $3 }'); do
                if ! [[ -e "${HELM_REPOSITORIES_YAML}" ]] || ! [[ "$(yq -r '.repositories[].url' ${HELM_REPOSITORIES_YAML})" =~ "${DEPENDENCY}"$ ]]; then
                    helm repo add "${DEPENDENCY}" "${DEPENDENCY}"
                fi
            done
        fi
    done
fi

# Post config hooks
if [[ -d "${POST_CONFIG_HOOKS}" ]] && [ "$(ls -A "${POST_CONFIG_HOOKS}")" ]; then
    echo "Running image post-configure hooks..."
    for HOOK in "${POST_CONFIG_HOOKS}"/*; do
        echo "- ${HOOK}..."
        ${HOOK}
    done
fi

if [[ -n "${HOST_HOME}" ]] && [[ -d "${HOST_HOME}/.devcontainer/hooks.d/post-start" ]]; then
    echo "Running user post-configure hooks..."
    for HOOK in "${HOST_HOME}/.devcontainer/hooks.d/post-start"/*; do
        echo " - ${HOOK}..."
        ${HOOK}
    done
fi


if [[ -d "${HOST_HOME}" ]]; then
    echo "Note: Your host home directory is avaialble at ${HOST_HOME}"
fi

echo "Container setup done! Please close this window."
