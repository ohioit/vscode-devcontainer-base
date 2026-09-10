# Repository Guide

## Overview

This repository builds the `ghcr.io/ohioit/vscode-devcontainer-base` image, a reusable Ubuntu
24.04 base for VS Code Development Containers. It supplies common development utilities,
Kubernetes tooling, an Ohio-oriented authentication/bootstrap script, and a configured Zsh
environment. The image is intended to work with the `docker-outside-of-docker` devcontainer
feature; it does not provide Docker itself.

## Repository Layout

- `Dockerfile` is the image definition. It declares tool versions, installs apt packages, creates
  the passwordless-sudo `vscode` user, runs the installation scripts, and installs the entrypoint
  and startup scripts.
- `install-system-dependencies.sh` downloads and installs tooling that is available system-wide,
  it runs as root during the build.
- `install-user-dependencies.sh` runs as `vscode`. It installs user specific tools like shell
  customizations and anything that would live in ~. It also invokes `adp-connect` for ADP tooling.
- `adp-connect.sh` is a standalone interactive bootstrap utility. It handles authentication and
  configuration for Rancher, Artifactory, Argo CD, GitHub, and related developer tooling. It can
  also be downloaded and used outside the image, which is its primary intent.
- `docker-entrypoint.sh` changes from root to a login shell for `vscode` when the image is run
  directly.
- `setup-container.sh` configures host-mounted state after startup, including kubeconfig and Helm
  repositories, and runs devcontainer lifecycle hooks.
- `zshrc.zsh`, `zsh-aliases.zsh`, and `p10k.zsh` define the interactive shell experience.
- `debug-webserver.py` is a small Flask server for container debugging.
- `skaffold.yaml` defines the local image build and push workflow.
- `README.md` is the end-user source of truth for workstation setup, credentials, and usage.

## Build and Development

Use the workspace task or run this command to develop and push the image through Skaffold:

```bash
skaffold build -p local
```

For one-off image work, `docker build` uses the `Dockerfile` in the repository root. Changes to
the installation scripts should be considered image-build changes; test them in a rebuilt image
when possible. Do not add Docker socket mounts to example devcontainer configurations: the
documented `docker-outside-of-docker` feature owns that integration.

Note: When testing the image, DO NOT simply run `skaffold build` or `skaffold build -p local` as it
will push a new latest. Be sure to add the `--push=false` argument to skaffold to avoid pushing the image
to the public registry.

## Runtime Model

The final image starts as root, then `docker-entrypoint.sh` opens a login shell as `vscode`.
`setup-container.sh` expects an optional `HOST_HOME` mount and creates or refreshes configuration
under `/home/vscode`. It runs image hooks from:

```text
/usr/local/lib/devcontainer/hooks.d/pre-start
/usr/local/lib/devcontainer/hooks.d/post-start
```

It also runs equivalent host hooks from `${HOST_HOME}/.devcontainer/hooks.d/` when available.
Preserve the `vscode:vscode` ownership of files copied into `/home/vscode`.

## Host Kubernetes and Helm Configuration

When `HOST_HOME` is available, startup copies `${HOST_HOME}/.kube/config` to
`/home/vscode/.kube/config`. It selects a Helm repository configuration from these host paths:

```text
${HOST_HOME}/.config/helm/repositories.yaml
${HOST_HOME}/Library/Preferences/helm/repositories.yaml
```

An optional sibling `repositories-ohio.yaml` is merged with the selected `repositories.yaml`
before the script processes dependencies from `/workspaces/*/helm/Chart.yaml`. Chart-derived
repositories are only added when neither their URL nor their generated name is already configured;
this avoids replacing repositories supplied by either host file. OCI dependencies are skipped.

## Shell Script Conventions

- Shell scripts use Bash. Keep existing four-space indentation and quote variable expansions.
- Use `set -e` in installer scripts where a failed command must abort image construction.
- Scripts that run during the image build must be non-interactive. `adp-connect.sh` intentionally
  supports interactive use, but its image-build invocation supplies flags for unattended setup.
- Keep downloads architecture-aware by using the variables established in the relevant script.
- Update `README.md` whenever image behavior, supported configuration paths, or user workflows
  change.

## YAML and yq

The repository uses Mike Farah `yq` v4 syntax. For multi-file YAML transformations, use
`yq eval-all`, not jq-style slurp assumptions. The Helm repository merge currently uses:

```bash
yq eval-all '. as $repository_config ireduce ({}; . *+ $repository_config)' \
  repositories.yaml repositories-ohio.yaml
```

`ireduce` deep-merges the documents and `*+` appends arrays, preserving both `repositories`
lists. `-s` with jq's `add` operator is not valid for the installed `yq` version.

## Validation

Run focused checks for modified scripts:

```bash
bash -n setup-container.sh
bash -n install-system-dependencies.sh
bash -n install-user-dependencies.sh
shellcheck setup-container.sh install-system-dependencies.sh install-user-dependencies.sh
git diff --check
```

For a Helm merge change, run the exact `yq eval-all` expression against two small YAML fixtures
and verify that each file's repository entries remain in the result. Build the image or run the
Skaffold workflow for changes affecting `Dockerfile`, package installation, entrypoint behavior,
or tooling versions.

When subtantive changes to the container are made, instruct the user to rebuild the devcontainer
to test changes.
