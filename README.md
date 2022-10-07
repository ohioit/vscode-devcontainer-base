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
- Post-start script that properly configures docker credentials,
  kubeconfig and helm.

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

## Helm Credentials

In order for Helm to be able to access your private docker registry inside of the container,
you'll need to be sure you've done a `helm repo add` for any private registry on your host
first, you can do that with:

```bash
helm repo add artifactory ${REGISTRY_URL} --username=${YOUR_OHIO_ID}
```

Your password must be an API key or personal access token, not your Ohio password.

## Kubernetes credentials

In order for `kubectl` to work properly, you must have a working `~/.kube/config` file. You can
generate one from https://rancher.oit.ohio.edu.

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
    "remoteEnv": {
        "HOST_HOME": "${localEnv:HOME}"
    },
    "mounts": [
        "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
        "source=${localEnv:HOME},target=${localEnv:HOME},type=bind,readonly"
    ]
}
```

> Note that it is important that `HOST_HOME` be set correctly and that your
> home directory is mounted into the value of `HOST_HOME` or startup scripts
> will fail to setup credentials properly.

## Hooks

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
