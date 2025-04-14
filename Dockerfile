FROM ubuntu:22.04

LABEL org.opencontainers.image.source https://github.com/ohioit/vscode-devcontainer-base

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
        procps \
        iputils-ping \
        git \
        curl \
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
        unzip \
        golang-chroma \
        rsync \
        nmap \
        less && \
    pip3 install yq && \
    sed -i '/'${LANG}'/s/^# //g' /etc/locale.gen && \
    locale-gen && \
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

ARG SKAFFOLD_VERSION=2.13.2
ARG KUBECTL_VERSION=1.30.4
ARG HELM_VERSION=3.16.2
ARG KUBESEAL_VERSION=0.27.2
ARG K9S_VERSION=0.32.5

COPY install-system-dependencies.sh /usr/local/bin/install-system-dependencies
RUN chmod +x /usr/local/bin/install-system-dependencies && \
    /usr/local/bin/install-system-dependencies

COPY adp-connect.sh /usr/local/bin/adp-connect
COPY install-user-dependencies.sh /usr/local/bin/install-user-dependencies
RUN chmod +x /usr/local/bin/install-user-dependencies \
    /usr/local/bin/adp-connect

USER ${USER_UID}

RUN /usr/local/bin/install-user-dependencies

COPY --chown=vscode:vscode zshrc.zsh /home/vscode/.zshrc
COPY --chown=vscode:vscode zsh-aliases.zsh /home/vscode/.zsh-aliases.zsh
COPY --chown=vscode:vscode p10k.zsh /home/vscode/.p10k.zsh

USER 0

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY wait-for-death.sh /usr/local/bin/wait-for-death
COPY setup-container.sh /usr/local/bin/setup-container

RUN chmod u+rwx,g+rx,o+rx \
        /usr/local/bin/setup-container \
        /usr/local/bin/docker-entrypoint \
        /usr/local/bin/wait-for-death && \
    mkdir /home/vscode/.docker /home/vscode/.kube && \
    chown ${USER_UID}:${USER_GID} /home/vscode/.docker /home/vscode/.kube && \
    mkdir -p /usr/local/lib/devcontainer/hooks.d/pre-start && \
    mkdir -p /usr/local/lib/devcontainer/hooks.d/post-start

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
