# Visual Studio Code Base Container

This repository creates a base container that makes using
Visual Studio Code Development Containers a bit easier.

The container created is a Debian Stretch base with the
following additions:

- Timezone and Locale support
- Base packages like curl, git, sudo, zsh, python, etc.
- Skaffold, Helm, and kubectl
- Visual studio code user configured as uid and gid `1000:1000`.
- Visual studio code user having passwordless sudo.
- Post-start script that properly configures kubeconfig and helm.
- Various kubectl plugins and a comfortable `zsh` based shell.

The container no longer provides docker but is fully compatible
with the [docker-outside-of-docker](https://github.com/devcontainers/features/tree/main/src/docker-outside-of-docker)
feature. Simply add the following to your `.devcontainer.json`:

```json
"features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
}
```

Reminder: Legacy versions of this container expected the `.devcontainer.json`
to mount the docker socket. **You must remove that mount from legacy
devcontainers.**

> Note: This devcontainer may only work on Linux, Mac OS, and inside
> of WSL on Windows. It will likely fail outside of WSL.

## Security Note

This container uses a passwordless sudo for the user in the container.
This means you are effectively giving vscode access to root in the
container, and to your docker engine.

However, in order to run docker, you need to be able to do root things
and anyone can start a root container. Just be careful.

## Workstation Setup

Before you can start, you need to install a few packages locally.
You will need git and docker (or podman maybe) at bare minimum.

### Linux

Install git, if not already available.

- RedHat/CentOS/Fedora: `dnf install -y git`
- Debian/Ubuntu: `apt install -y git`

Install docker (or podman maybe).

- RedHat/CentOS/Fedora: [Install Docker](https://docs.docker.com/engine/install/centos/)
or `dnf install -y podman podman-docker`
- Debian/Ubuntu: `apt install -y docker docker.io` or `apt install -y podman
  podman-docker`

> Note: When using Docker, your local user will have to be in the `docker`
> group to use docker. You can use `id {user}` to see if your user is
> already in the group and `sudo gpasswd -a {user} docker` to add
> yourself to the group.
>
> You will likely need to logout and back in before your desktop notices
> the change.

### Mac

We recommend using [Homebrew](https://brew.sh/) to install the required
packages.

``` bash
brew install git
brew install docker
```

### Windows

For the best container experience on Windows, you'll need to setup WSL.
Once you have a working WSL environment, you can proceed with the Linux
steps above.

#### WSL

Windows Subsystem for Linux is a nice tool for running a near-native Linux
experience on Windows, with your choice of distribution. The most likely
distribution most will use is Ubuntu LTS, however there are some good options
using AlmaLinux, SUSE, or Debian. These instructions will not describe *how* to
install these, there are better guides online to get you there.

Once you have your WSL instance running, you can install Git using the native
package manager, perform the config, and clone the repo to start working with
the repo and ansible.

PowerShell: `wsl --update`

Update your WSL distro with one of the following commands

- Debian/Ubuntu: `sudo apt update && sudo apt full-upgrade`
- RedHat/CentOS/Fedora: `sudo dnf update --refresh`

Edit or create your /etc/wsl.conf in your WSL instance with the following
content:

```ini
[boot]
systemd=true
```

Restart your WSL

PowerShell: `wsl --shutdown`

Launch your WSL instance again, and then proceed with the native Linux
instructions above.

## Credentials

You will need to have access to your Docker, Kubernetes, and Helm credentials
to do much of this work. The easiest way to do this is inside of the container,
see below.

### Connecting with an AI agent

`adp-connect` sets up your access to Rancher (Kubernetes), Artifactory, Argo CD,
and GitHub. If you use an AI coding agent, you can ask it to help, for example:

> Read https://github.com/ohioit/vscode-devcontainer-base and help me connect to ADP.

The agent will install the tools, check what's already set up, and then ask
**you** to run one command in your own terminal. That's because signing in needs
your browser and prompts that only you should answer. When it's done, the agent
checks again to confirm everything works.

- The agent may suggest `adp-connect -a`. Use it if you follow common Ohio IT
  practices, and ask someone if you're not sure. It also sets up Artifactory and
  Argo CD, which need access that may have to be granted before they work.
- Never paste tokens or passwords into the chat. Type them only into the
  `adp-connect` prompts.
- If you've added servers of your own, the agent may tell you they're
  unreachable. That's usually not a problem with your Ohio setup.
- If `adp-connect` itself seems broken, the agent can help you draft an
  [issue](https://github.com/ohioit/vscode-devcontainer-base/issues/new?template=adp-connect.yml).
  It removes credentials and personal details first, and you review and submit it.

### Docker and Helm Registry Credentials

The container copies your host's Docker and Helm registry logins on startup, so `docker` and
`helm` work the same whether or not Visual Studio Code is attached (for example when the
container is started with the devcontainer CLI):

- Docker logins from your host's `~/.docker/config.json` go into
  `${DOCKER_CONFIG}/config.json`. The image sets `DOCKER_CONFIG=/home/vscode/.config/docker`.
- Helm's registry config (`~/.config/helm/registry/config.json`) gets your host's Docker logins
  plus its Helm logins (`~/.config/helm/registry/config.json`, or
  `~/Library/Preferences/helm/registry/config.json` on Mac OS). Where both have the same
  registry, the Helm login wins.

Only logins stored directly in those files carry over. Logins kept in a keychain can't be read
from the container, so they're left out and listed when the container starts. This includes
Docker Desktop's default on Mac OS and Windows, and `helm registry login` on Mac OS. In that
case, log in once inside the container with the same Artifactory Identity Token:

```bash
docker login docker.artifactory.oit.ohio.edu --username=${YOUR_OHIO_ID}
```

That login lasts until the container is set up again. Nothing else from your host's Docker
config (contexts, plugins, proxies) is copied.

Visual Studio Code's own Docker credential forwarding isn't used. When it connects, the Dev
Containers extension still points `credsStore` in `~/.docker/config.json` at its
`docker-credential-dev-containers-<id>` helper, which forwards lookups to your host's Docker
logins. But that only works while Visual Studio Code is connected, and with `DOCKER_CONFIG` set
elsewhere nothing reads that file.

### Kubernetes credentials

In order for `kubectl` to work properly, you must have a working `~/.kube/config` file. You can
generate one from Rancher. Note that these do not currently work in Codespaces. If you don't have
one, you can do the following:

1. Login to Rancher, open the cluster you want to use, and download the kubeconfig for
   that cluster using the toolbar at the top.
2. Repeat step (1) for any all other clusters you need.
3. **Manually** merge all of the kubeconfig files into one. They all have the same format.
4. Place the file into `~/.kube/config` on your host. If you're on Windows, this file should
   go into your WSL environment.

### Helm Credentials

Ohio charts are served from the OCI repository `oci://docker.artifactory.oit.ohio.edu/charts`,
so Helm only needs to be logged into that registry; no `helm repo add` is needed. Helm checks
its own registry login first and then falls back to Docker's, so your Artifactory Docker login
is normally all it needs. `adp-connect -a` on your host sets this up (it also removes the old
`artifactory` and `artifactory-push` repositories), and only logs Helm in separately when
Docker isn't available. To do it by hand on your host, use an Artifactory Identity Token, not
your Ohio password, with either command:

```bash
docker login docker.artifactory.oit.ohio.edu --username=${YOUR_OHIO_ID}
helm registry login docker.artifactory.oit.ohio.edu --username=${YOUR_OHIO_ID}
```

See [Docker and Helm Registry Credentials](#docker-and-helm-registry-credentials) for how
these reach the container. These do not currently work in Codespaces.

#### Classic (non-OCI) Helm repositories

If you use classic Helm repositories, add them on your host with `helm repo add`; the
container copies your host's `repositories.yaml` on startup.

To keep Ohio-specific repositories separate, optionally place them in a
`repositories-ohio.yaml` file beside `repositories.yaml` on your host. Container startup
merges its repositories with `repositories.yaml` before it adds repositories inferred from
project `Chart.yaml` dependencies. Existing repositories from either file are not replaced
by those inferred dependencies.

If you added repositories inside the container instead, copy the file out to your host.

> NOTE: The below commands will erase any configured helm repositories on your host. If
> you have some, run `helm repo add` on your host instead.

##### Linux/Windows

```bash
test -d "${HOST_HOME}"/.config/helm || mkdir -p "${HOST_HOME}"/.config/helm
cp ~/.config/helm/repositories.yaml "${HOST_HOME}/.config/helm/repositories.yaml
```

##### Mac OS

```bash
test -d "${HOST_HOME}"/Library/Preferences/helm || mkdir -p "${HOST_HOME}"/Library/Preferences/helm
cp ~/.config/helm/repositories.yaml "${HOST_HOME}/Library/Preferences/helm/repositories.yaml
```

## Usage as in GitHub Codespaces and Visual Studio Code

For basic usage, simply create a `.devcontainer/devcontainer.json`
in your repository that looks like the following:

```json
{
    "name": "Devcontainer",
    "image": "ghcr.io/ohioit/vscode-devcontainer-base",
    "features": {
        "ghcr.io/devcontainers/features/docker-outside-of-docker": {}
    },
    "customizations": {
        "vscode": {
            "extensions": [
                "editorconfig.editorconfig",
                "davidanson.vscode-markdownlint",
                "timonwong.shellcheck",
                "redhat.vscode-yaml",
                "eamodio.gitlens",
                "ms-azuretools.vscode-docker"
            ]
        }
    },
    "postCreateCommand": "/usr/local/bin/setup-container",
    "remoteUser": "vscode",
    "remoteEnv": {
        "HOST_HOME": "${localEnv:HOME}"
    },
    "mounts": [
        "source=${localEnv:HOME},target=${localEnv:HOME},type=bind,readonly"
    ]
}
```

Be sure to customize the `extensions` property to add any extensions you'd like
to automatically install into your container.

### Container Customizations

If you'd like to build your own container, you can use this as a base.
First, change your `.devcontainer.json` so that it builds the image
instead of using the image directly:

```json
...
"name": "Devcontainer",
"build": {
    "dockerFile": "Dockerfile"
},
"features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker": {}
},
...
```

Then, create a `Dockerfile` in `.devcontainer` using the base image, like this:

```dockerfile
FROM docker.artifactory.oit.ohio.edu/ais/vscode-devcontainer-base:VERSION

# Customize the image as root

# Optionally customize the image as vscode
USER 1000

# Make sure you switch back to root after
USER 0

# Do not set an entrypoint
```

### Hooks

The setup script supports two hooks, pre and post configuration. To run
hooks before anything else in the script or after everything is done,
place files into the appropriate directory in the container during your build.

```bash
PRE_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/pre-start
POST_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/post-start
```

In addition to container level hooks, you can also have hooks that run
only on your machine utilizing the "user hooks". To do this,
place a shell script in either `~/.devcontainer/hooks.d/pre-start` or
`~/.devcontainer/hooks.d/post-start`. Note that any command that accesses
content in your home directory may need to run using `sudo`.

Your home directory is mounted readonly with the same path in the container
as on your host. That is, `/Users/{username}` on Mac OS X and `/home/{username}`
on Linux and WSL.

An example of a simple hook that will override the internal
[PowerLevel10k](https://github.com/romkatv/powerlevel10k) shell prompt configuration
might look like this:

```bash
#!/bin/zsh
sudo cp "${HOST_HOME}/.p10k.zsh" /home/vscode/.p10k.zsh
sudo chown vscode:vscode /home/vscode/.p10k.zsh
```

This might be placed in the directory `/home/username/.devcontainer/hooks.d/post-start/p10k.sh`.

## Other Usages

This image is designed to _also_ be run directly. Simply use docker to run

```bash
docker run -ti --rm ghcr.io/ohioit/vscode-devcontainer-base
```

The container will start the shell by default. This can be useful to have access to the
tools in some cases. In addition, it can be used to help debug things in a Kubernetes cluster.
In this case, use the `/usr/local/bin/wait-for-death` entrypoint to help the container
start and shut down gracefully. Here's an example deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
        - name: test
          imagePullPolicy: Always
          image: ghcr.io/ohioit/vscode-devcontainer-base
          command: ["/usr/local/bin/wait-for-death"]
```
