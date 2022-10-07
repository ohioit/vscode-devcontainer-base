FROM ubuntu:20.04

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
ARG LANG=en_US.UTF-8
ARG LANGUAGE=en_US.UTF-8
ARG LC_ALL=en_US.UTF-8

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
        wget \
        chroma \
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

ARG SKAFFOLD_VERSION=1.38.0
ARG KUBECTL_VERSION=1.20.0
ARG HELM_VERSION=3.7.2
ARG KUBESEAL_VERSION=0.17.1

COPY install-system-dependencies.sh /usr/local/bin/install-system-dependencies
RUN chmod +x /usr/local/bin/install-system-dependencies && \
    /usr/local/bin/install-system-dependencies

COPY install-user-dependencies.sh /usr/local/bin/install-user-dependencies
RUN chmod +x /usr/local/bin/install-user-dependencies

USER ${USER_UID}

RUN /usr/local/bin/install-user-dependencies

COPY --chown=vscode:vscode zshrc.zsh /home/vscode/.zshrc
COPY --chown=vscode:vscode zsh-aliases.zsh /home/vscode/.zsh-aliases.zsh
COPY --chown=vscode:vscode p10k.zsh /home/vscode/.p10k.zsh

USER 0

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint

COPY setup-container.sh /usr/local/bin/setup-container
RUN chmod u+rwx,g+rx,o+rx /usr/local/bin/setup-container /usr/local/bin/docker-entrypoint && \
    mkdir /home/vscode/.docker /home/vscode/.kube && \
    chown ${USER_UID}:${USER_GID} /home/vscode/.docker /home/vscode/.kube && \
    mkdir -p /usr/local/lib/devcontainer/hooks.d/pre-start && \
    mkdir -p /usr/local/lib/devcontainer/hooks.d/post-start

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
