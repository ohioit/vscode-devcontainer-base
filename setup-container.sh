#!/bin/bash
PRE_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/pre-start
POST_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/post-start

if [[ -d "${PRE_CONFIG_HOOKS}" ]] && [ "$(ls -A "${PRE_CONFIG_HOOKS}")" ]; then
    for HOOK in "${PRE_CONFIG_HOOKS}"/*; do
        ${HOOK}
    done
fi

jq 'del(.credsStore)' /home/vscode/.docker/hostconfig.json > /home/vscode/.docker/config.json
sudo mkdir /root/.docker /root/.kube
sudo ln -s /home/vscode/.docker/config.json /root/.docker/config.json
cp /home/vscode/.kube/hostconfig /home/vscode/.kube/config
sudo ln -s /home/vscode/.kube/config /root/.kube/config

if [[ -e /home/vscode/.helm-repositories.yaml ]]; then
    mkdir -p /home/vscode/.config/helm 2>/dev/null || true
    sudo mkdir -p /root/.config/helm 2>/dev/null || true

    ln -sf /home/vscode/.helm-repositories.yaml /home/vscode/.config/helm/repositories.yaml
    sudo ln -sf /home/vscode/.helm-repositories.yaml /root/.config/helm/repositories.yaml
fi

if [[ -d "${POST_CONFIG_HOOKS}" ]] && [ "$(ls -A "${POST_CONFIG_HOOKS}")" ]; then
    for HOOK in "${POST_CONFIG_HOOKS}"/*; do
        ${HOOK}
    done
fi
