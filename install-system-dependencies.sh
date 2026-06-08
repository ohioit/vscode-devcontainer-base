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
    https://storage.googleapis.com/kubernetes-release/release/v"${KUBECTL_VERSION}"/bin/linux/"${DPKG_ARCHITECTURE}"/kubectl
chmod +x ./kubectl
mv ./kubectl /usr/local/bin/kubectl

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
