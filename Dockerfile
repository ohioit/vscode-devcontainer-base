FROM ubuntu:20.04

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
ARG LANG=en_US.UTF-8
ARG LANGUAGE=en_US.UTF-8
ARG LC_ALL=en_US.UTF-8
ARG HAVE_NERD_GLYPHS=false

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get -y dist-upgrade && \
    apt-get -y install \
        curl \
        git \
        sudo \
        zsh \
        shellcheck \
        jq \
        netcat \
        dnsutils \
        python3.9 \
        python3-pip \
        locales \
        apt-transport-https \
        ca-certificates \
        software-properties-common \
        vim \
        less && \
    pip3 install yq && \
    sed -i '/'${LANG}'/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | apt-key add - && \
    add-apt-repository \
    "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') \
        $(lsb_release -cs) \
        stable" && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    apt-get autoremove --purge && rm -Rf /var/cache/apt/archives && \
    unset DEBIAN_FRONTEND

ENV LANG ${LANG}
ENV LANGUAGE ${LANGUAGE}
ENV LC_ALL ${LC_ALL}

RUN groupadd -g $USER_GID $USERNAME && \
    useradd -s /bin/zsh -m -d /home/vscode -u $USER_UID -g $USER_GID $USERNAME && \
    mkdir -p /etc/sudoers.d && \
    echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME

ARG SKAFFOLD_VERSION=v1.35.1

RUN curl -Lo /usr/local/bin/skaffold https://github.com/GoogleContainerTools/skaffold/releases/download/${SKAFFOLD_VERSION}/skaffold-linux-$(dpkg --print-architecture) && \
    chmod +x /usr/local/bin/skaffold

ARG KUBECTL_VERSION=v1.20.0

RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/$(dpkg --print-architecture)/kubectl && \
    chmod +x ./kubectl && \
    mv ./kubectl /usr/local/bin/kubectl

ARG HELM_VERSION=v3.7.2

RUN curl -Lo /tmp/helm.tar.gz https://get.helm.sh/helm-${HELM_VERSION}-linux-$(dpkg --print-architecture).tar.gz && \
    tar -C /tmp -zxvf /tmp/helm.tar.gz && \
    mv /tmp/linux-$(dpkg --print-architecture)/helm /usr/local/bin && \
    rm -Rf /tmp/helm.tar.gz /tmp/linux-$(dpkg --print-architecture) && \
    chmod +x /usr/local/bin/helm

ARG KUBESEAL_VERSION=0.17.1
RUN curl -Lo /tmp/kubeseal.tar.gz https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-$(dpkg --print-architecture).tar.gz && \
    tar -C /tmp -zxvf /tmp/kubeseal.tar.gz && \
    install -m 755 /tmp/kubeseal /usr/local/bin/kubeseal

COPY setup-container.sh /usr/local/bin/setup-container
RUN chmod +x /usr/local/bin/setup-container && \
    mkdir /home/vscode/.docker /home/vscode/.kube && \
    chown ${USER_UID}:${USER_GID} /home/vscode/.docker /home/vscode/.kube && \
    mkdir -p /usr/local/lib/devcontainer/hooks.d/pre-start && \
    mkdir -p /usr/local/lib/devcontainer/hooks.d/post-start

USER ${USER_UID}

RUN sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
RUN test "${HAVE_NERD_GLYPHS}" = "true" && sed -ri 's/ZSH_THEME=.*/ZSH_THEME="agnoster"/' /home/vscode/.zshrc || true
RUN echo 'source ~/.zsh-aliases' >> ~/.zshrc

COPY zsh-aliases.sh /home/vscode/.zsh-aliases

USER 0
