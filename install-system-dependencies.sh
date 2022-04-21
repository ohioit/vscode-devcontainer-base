#!/bin/bash
set -e

DPKG_ARCHITECTURE=$(dpkg --print-architecture)

echo "Installing Skaffold ${SKAFFOLD_VERSION}..."
curl -Lo /usr/local/bin/skaffold \
    https://github.com/GoogleContainerTools/skaffold/releases/download/v${SKAFFOLD_VERSION}/skaffold-linux-"${DPKG_ARCHITECTURE}"
chmod +x /usr/local/bin/skaffold

echo "Installing Kubectl ${KUBECTL_VERSION}..."
curl -LO \
    https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/"${DPKG_ARCHITECTURE}"/kubectl
chmod +x ./kubectl
mv ./kubectl /usr/local/bin/kubectl

echo "Installing Helm ${HELM_VERSION}..."
curl -Lo /tmp/helm.tar.gz https://get.helm.sh/helm-v${HELM_VERSION}-linux-"${DPKG_ARCHITECTURE}".tar.gz
tar -C /tmp -zxvf /tmp/helm.tar.gz
mv /tmp/linux-"${DPKG_ARCHITECTURE}"/helm /usr/local/bin
rm -Rf /tmp/helm.tar.gz /tmp/linux-"${DPKG_ARCHITECTURE}"
chmod +x /usr/local/bin/helm

echo "Installing Kubeseal ${KUBESEAL_VERISON}..."
curl -Lo /tmp/kubeseal.tar.gz https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-$(dpkg --print-architecture).tar.gz && \
    tar -C /tmp -zxvf /tmp/kubeseal.tar.gz && \
    install -m 755 /tmp/kubeseal /usr/local/bin/kubeseal
