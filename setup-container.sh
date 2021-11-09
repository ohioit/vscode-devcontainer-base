#!/bin/bash
PRE_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/pre-start
POST_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/post-start

for HOOK in "${PRE_CONFIG_HOOKS}"/*; do
    ${HOOK}
done

jq 'del(.credsStore)' /home/vscode/.docker/hostconfig.json > /home/vscode/.docker/config.json
sudo mkdir /root/.docker /root/.kube
sudo ln -s /home/vscode/.docker/config.json /root/.docker/config.json
cp /home/vscode/.kube/hostconfig /home/vscode/.kube/config
sudo ln -s /home/vscode/.kube/config /root/.kube/config

for HOOK in "${POST_CONFIG_HOOKS}"/*; do
    ${HOOK}
done
