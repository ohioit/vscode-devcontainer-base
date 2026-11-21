#!/bin/bash
set -e

DPKG_ARCHITECTURE=$(dpkg --print-architecture)

mkdir /tmp/ohio-pkgs || true
rm -Rf /tmp/ohio-pkgs/* || true

echo "Installing Skaffold ${SKAFFOLD_VERSION}..."
curl -Lo /usr/local/bin/skaffold \
    https://github.com/GoogleContainerTools/skaffold/releases/download/v"${SKAFFOLD_VERSION}"/skaffold-linux-"${DPKG_ARCHITECTURE}"
chmod +x /usr/local/bin/skaffold

echo "Installing Kubectl ${KUBECTL_VERSION}..."
curl -LO \
    https://dl.k8s.io/v"${KUBECTL_VERSION}"/kubernetes-client-"$(uname -s | tr '[:upper:]' '[:lower:]')"-"${DPKG_ARCHITECTURE}".tar.gz
tar -C /tmp/ohio-pkgs -zxvf kubernetes-client-"$(uname -s | tr '[:upper:]' '[:lower:]')"-"${DPKG_ARCHITECTURE}".tar.gz
chmod +x /tmp/ohio-pkgs/kubernetes/client/bin/*
mv /tmp/ohio-pkgs/kubernetes/client/bin/* /usr/local/bin/

echo "Installing Helm ${HELM_VERSION}..."
curl -Lo /tmp/ohio-pkgs/helm.tar.gz https://get.helm.sh/helm-v"${HELM_VERSION}"-linux-"${DPKG_ARCHITECTURE}".tar.gz
tar -C /tmp/ohio-pkgs -zxvf /tmp/ohio-pkgs/helm.tar.gz
mv /tmp/ohio-pkgs/linux-"${DPKG_ARCHITECTURE}"/helm /usr/local/bin
rm -Rf /tmp/ohio-pkgs/*
chmod +x /usr/local/bin/helm

echo "Installing Kubeseal ${KUBESEAL_VERISON}..."
curl -Lo /tmp/ohio-pkgs/kubeseal.tar.gz https://github.com/bitnami-labs/sealed-secrets/releases/download/v"${KUBESEAL_VERSION}"/kubeseal-"${KUBESEAL_VERSION}"-linux-"${DPKG_ARCHITECTURE}".tar.gz && \
    tar -C /tmp/ohio-pkgs -zxvf /tmp/ohio-pkgs/kubeseal.tar.gz && \
    install -m 755 /tmp/ohio-pkgs/kubeseal /usr/local/bin/kubeseal && \
    rm -Rf /tmp/ohio-pkgs/*

echo "Installing k9s ${K9S_VERSION}..."
curl -Lo /tmp/ohio-pkgs/k9s.tar.gz https://github.com/derailed/k9s/releases/download/v"${K9S_VERSION}"/k9s_Linux_"${DPKG_ARCHITECTURE}".tar.gz && \
    tar -C /tmp/ohio-pkgs -zxvf /tmp/ohio-pkgs/k9s.tar.gz && \
    install -m 755 /tmp/ohio-pkgs/k9s /usr/local/bin/k9s && \
    rm -Rf /tmp/ohio-pkgs/*

echo "Installing yq ${YQ_VERSION}..."
# mikefarah/yq (Go), which setup-container.sh and adp-connect expect.
YQ_BINARY="yq_linux_${DPKG_ARCHITECTURE}"
YQ_RELEASE_URL="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}"
curl -fLo /tmp/ohio-pkgs/"${YQ_BINARY}" "${YQ_RELEASE_URL}/${YQ_BINARY}"
curl -fsSLo /tmp/ohio-pkgs/yq-checksums "${YQ_RELEASE_URL}/checksums"
curl -fsSLo /tmp/ohio-pkgs/yq-checksums-order "${YQ_RELEASE_URL}/checksums_hashes_order"
# Each checksums line is "<file> <hash>...", in the order checksums_hashes_order lists.
YQ_SHA256_FIELD=$(( $(grep -n '^SHA-256$' /tmp/ohio-pkgs/yq-checksums-order | cut -d: -f1) + 1 ))
awk -v file="${YQ_BINARY}" -v field="${YQ_SHA256_FIELD}" '$1 == file { print $field "  " file }' \
    /tmp/ohio-pkgs/yq-checksums > /tmp/ohio-pkgs/yq.sha256sum
(cd /tmp/ohio-pkgs && sha256sum --check yq.sha256sum)
install -m 755 /tmp/ohio-pkgs/"${YQ_BINARY}" /usr/local/bin/yq
rm -Rf /tmp/ohio-pkgs/*
