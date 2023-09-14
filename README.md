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

### Docker Credentials

Visual Studio Code now correctly sets up Docker credentials when
inside a devcontainer.

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

In order for Helm to be able to access your private docker registry inside of the container,
you'll need to be sure you've done a `helm repo add` for any private registry on your host
first, you can do that with:

```bash
helm repo add artifactory ${REGISTRY_URL} --username=${YOUR_OHIO_ID}
```

Your password must be an API key or personal access token, not your Ohio password. Note
that these do not currently work in Codespaces. Once you have this done inside of the
container, you will need to copy this file out of the container onto your system.

> NOTE: The below commands will erase any configured helm repositories on your host. If
> you have some, you should run the above command on your host instead.

#### Linux/Windows

```bash
test -d "${HOST_HOME}"/.config/helm || mkdir -p "${HOST_HOME}"/.config/helm
cp ~/.config/helm/repositories.yaml "${HOST_HOME}/.config/repositories.yaml
```

#### Mac OS

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
      imagePullPolicy: Always
      containers:
        - name: test
          image: ghcr.io/ohioit/vscode-devcontainer-base
          command: ["/usr/local/bin/wait-for-death"]
```
