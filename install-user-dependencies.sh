#!/bin/bash
set -e

echo "Installing Kubectl Plugins..."
mkdir /tmp/krew && \
curl -fsSLo /tmp/krew/krew.tar.gz "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz"
tar -C /tmp/krew -zxvf "/tmp/krew/krew.tar.gz"
/tmp/krew/krew-linux_amd64 install krew

export PATH="${PATH}:/home/vscode/.krew/bin"

kubectl krew install neat debug-shell exec-cronjob mtail sniff secretdata

mkdir -p "/home/vscode/.zsh" || true
kubectl completion zsh > "/home/vscode/.zsh/kubernetes.sh"

echo "Installing Oh-My-ZSH..."
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${HOME}"/.oh-my-zsh/custom/themes/powerlevel10k
git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${HOME}"/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
git clone --depth=1 https://github.com/supercrabtree/k "${HOME}"/.oh-my-zsh/custom/plugins/k
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${HOME}"/.oh-my-zsh/custom/plugins/zsh-autosuggestions
git clone --depth=1 https://github.com/johanhaleby/kubetail.git "${HOME}"/.oh-my-zsh/custom/plugins/kubetail

echo "Installing ADP Tooling..."
PATH="${HOME}/.local/bin:${PATH}" /usr/local/bin/adp-connect -D -I || { echo "ADP Tooling installation failed"; exit 1; }
