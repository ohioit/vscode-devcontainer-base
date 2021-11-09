# Visual Studio Code Base Container

This repository creates a base container that makes using
Visual Studio Code Development Containers a bit easier.

The container created is a Debian Stretch base with the
following additions:

- Timezone and Locale support
- Base packages like curl, git, sudo, zsh, python, etc.
- Docker client
- Skaffold, Helm, and kubectl
- Visual studio code user configured as uid and gid `1000:1000`.
- Visual studio code user having passwordless sudo.
- Key aliases to transparently use docker and kubectl tools.
- Post-start script that properly configures docker credentials and
  kubeconfig.

> Note: This devcontainer may only work on Linux, Mac OS, and inside
> of WSL on Windows. It will likely fail outside of WSL.

## Security Note

This container uses a passwordless sudo for the user in the container.
This means you are effectively giving vscode access to root in the
container, and to your docker engine.

However, in order to run docker, you need to be able to do root things
and anyone can start a root container. Just be careful.

## Docker Credentials

In order for Docker credentials to work properly inside of a devcontainer,
they must be captured inside Docker's `config.json`. If you use `docker login`
with a credentials store configured, it's very likely this will not work
since the credentials are stored in your system keychain.

You will likely have to remove the `credsStore` property in your
`config.json` and do `docker login` again. **However, this will store
your credentials unencrypted in a text file on your machine**.

Alternatively, you can run `docker login` when you're inside the container
which will be nuked when the container dies.

## Usage

To use this, first create a `Dockerfile` inside of a `.devcontainer`
directory at the root of your project, use this image as the from
line:

```dockerfile
FROM docker.artifactory.oit.ohio.edu/ais/vscode-devcontainer-base:VERSION

# Customize the image as root

# Optionally customize the image as vscode
USER 1000

# Make sure you switch back to root after
USER 0

# Do not set an entrypoint
```

Then create a `.devcontainer/devcontainer.json` file like the following:

```json
{
    "name": "Your Container Name",
    "build": {
        "dockerFile": "Dockerfile"
    },
    "extensions": [
        // List of extension IDs to install
    ],
    // The following three are very important
    "postCreateCommand": "/usr/local/bin/setup-container",
    "remoteUser": "vscode",
    "mounts": [
        "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
        "source=${env:HOME}/.kube/config,target=/home/vscode/.kube/hostconfig,type=bind",
        "source=${env:HOME}/.docker/config.json,target=/home/vscode/.docker/hostconfig.json,type=bind",
        "source=${env:HOME}/.ssh,target=/home/vscode/.ssh,type=bind"
    ]

}
```

> Note that the configurations above mount to `hostconfig` instead of the
> actual config file path. This is because these files need some munging to work
> properly, which `setup-container.sh` takes care of.

## Hooks

The setup script supports two hooks, pre and post configuration. To run
hooks before anything else in the script or after everything is done,
place files into the appropriate directory in the container during your build.

```bash
PRE_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/pre-start
POST_CONFIG_HOOKS=/usr/local/lib/devcontainer/hooks.d/post-start
```
