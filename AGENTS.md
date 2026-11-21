# Repository Guide

## Overview

This repository builds the `ghcr.io/ohioit/vscode-devcontainer-base` image, a reusable Ubuntu
24.04 base for VS Code Development Containers. It supplies common development utilities,
Kubernetes tooling, an Ohio-oriented authentication/bootstrap script, and a configured Zsh
environment. The image is intended to work with the `docker-outside-of-docker` devcontainer
feature; it does not provide Docker itself.

## Connecting a user with adp-connect

Users may point you at this repository and ask to be connected to ADP (or "set up adp-connect").
Your job is to guide them, not to run the setup for them. The header comment at the top of
`adp-connect.sh` repeats the essentials.

### Procedure

1. **Install, if needed.** If `adp-connect` isn't on `PATH`, install it to `~/.local/bin`. Windows
   users must do this inside WSL.

   ```bash
   mkdir -p ~/.local/bin
   curl -fsSL https://raw.githubusercontent.com/ohioit/vscode-devcontainer-base/refs/heads/main/adp-connect.sh \
     -o ~/.local/bin/adp-connect
   chmod +x ~/.local/bin/adp-connect
   adp-connect -D -I   # installs the CLI tools only; no prompts
   ```

2. **Check status:** `adp-connect -C -a`. It's read-only, needs no terminal and prints no secrets.
   It ends with a `NEXT:` line and a `RESULT:` line.
3. **Offer to explain the services.** Ask the user whether they'd like a quick explanation, and only
   give it if they say yes:
   - **Rancher**: the user interface for Kubernetes, and how you get access to the clusters.
   - **Artifactory**: where your build artifacts are stored (container images, Helm charts,
     packages).
   - **Argo CD**: what deploys your stuff to Kubernetes.
   - **GitHub**: where your code lives, along with your deployment and release workflows.
4. **Hand off.** Ask the user to run the command in **their own terminal**, not through you:
   - `adp-connect -a` if they follow common Ohio IT practices. If they're not sure, they should ask
     someone. `-a` also sets up Artifactory and Argo CD, which need access that may have to be
     granted before they work.
   - `adp-connect` otherwise (Rancher, Kubernetes and GitHub only).

   Tell them to expect prompts and browser sign-ins, and to come back when it finishes. Don't offer
   other flags.
5. **Verify** with `adp-connect -C` (add `-a` if they used it).

**Never run any other invocation yourself.** The setup needs an interactive terminal and a browser.
Without a terminal it exits with code 2 and changes nothing.

Exit codes: `0` ok; `1` error, or some services couldn't be set up (listed in the final summary);
`2` needs an interactive terminal; `3` (`-C`) something is `missing` or `expired`, so rerun the
`NEXT:` command; `4` (`-C`) only `unreachable` hosts, so rerunning won't help.

### Reading `-C` results

- **Expected services** are hosts on `.ohio.edu`, plus the public services the script sets up by
  default (such as `github.com`). They should work, and failures are worth troubleshooting.
- **Other services** are any other host. Users can add their own servers, and this project knows
  nothing about them. If only other services fail, tell the user their expected services are fine
  and those failures may not be a real problem. Don't troubleshoot other services unless the user
  asks.
- `unreachable` on a `.ohio.edu` host usually means the user isn't on the VPN or the network is down.
  `expired` or `missing` means rerun the `NEXT:` command.
- `not checked (signs in through a credential plugin)` means the context gets its credentials from a
  plugin such as `rancher token`, which may need an interactive sign-in. That isn't a failure. Don't
  run `kubectl` against those contexts yourself; it could start a sign-in you can't complete. Ask the
  user to run `adp-connect` instead, which signs in up front.
- The script itself treats all hosts the same way. This distinction is only for how you explain the
  results.

### Credentials

- Never ask the user to paste tokens, passwords or their OHIO ID into the chat. They type those only
  into the `adp-connect` prompts.
- Never pass credentials as command arguments or environment variables.
- Never print or read credential files: `~/.kube/config`, `~/.rancher/cli2.json`,
  `~/.docker/config.json`, `~/.config/gh/hosts.yml`, or the Argo CD config. Use commands that only
  show structure, such as `adp-connect -C`, `kubectl config get-contexts`, or `rancher server ls`.
- Never suggest `-T`: trace output contains credentials. `-d` output has Rancher keys redacted, but
  still ask the user to share only the relevant error lines.

### Troubleshooting

Only ever change the **user's own machine**, never a connected service.

- **Allowed:** PATH and shell rc files, files in `~/.local/bin`, installing or upgrading local
  tools, starting Docker, and local CLI config files. Back up any config file first, and ask before
  each change.
- **Forbidden:** anything that changes a connected service. That means no
  `kubectl apply/create/delete/patch/edit`, no `helm install/upgrade/uninstall`, no `argocd app`
  actions, no creating or deleting Rancher tokens through the API, no `gh` repository or
  organization changes, and no pushing to Artifactory. Network checks are limited to DNS lookups and
  unauthenticated health endpoints (for example `https://<rancher>/ping`).

| Symptom | Likely fix on the user's machine |
| --- | --- |
| `network.rancher.oit.ohio.edu: unreachable` or other `.ohio.edu` hosts `unreachable` | Connect to the VPN or VDI, then check again |
| `path.local_bin: missing` | Add `export PATH="$HOME/.local/bin:$PATH"` to the shell rc file |
| `yq: missing (an incompatible yq is installed…)` | Remove the other `yq` (for example the Python one); `adp-connect` installs the right one |
| `rancher.version: expired` | Have the user rerun `adp-connect`; it upgrades the Rancher CLI |
| `expired` / `missing` on a service | Have the user rerun the `NEXT:` command |
| `docker: not running or not accessible` | Start Docker, or add the user to the `docker` group (log out and back in) |
| `browser_opener: missing` | Argo CD setup is skipped without `xdg-open`/`open`; install one, or have the user run `argocd login <host> --sso` themselves |
| A warning about a `rancherDefault` entry | Let `adp-connect` clear the Rancher CLI config when it asks |
| `rancher.<host>: missing (saved config is broken: …)` or `rancher.config: missing (… can't be parsed …)`, or the user saw `unable to parse context`, `No context set` or `unsupported protocol scheme ""` | The Rancher CLI config (`~/.rancher/cli2.json`) is damaged. Have the user rerun `adp-connect`: it backs the file up to `~/.rancher/cli2.json.adp-connect-backup.<timestamp>` (keeping the newest 3), removes the broken entry and logs in again. If that keeps failing, file an issue with the `-C` output. Don't open the file or its backups. |
| `Couldn't find any Rancher projects you can use on <host>` | The user may not have been granted access to any project yet; they should ask for access |
| Errors about bash/zsh on Windows | Run everything inside WSL |

### Filing an issue

Suggest an issue when an expected service fails while the `[environment]` checks look fine, or
when the fix needs a change to `adp-connect.sh`. You draft it, and the user submits it:

1. Collect: `adp-connect -C -a` output, the command the user ran, the error lines they copy from
   their terminal, and the OS/arch/shell/WSL and `adp-connect.sha256` values from `-C`. If more
   detail is needed, the user can rerun with `-d` and copy only the relevant lines.
2. Sanitize: remove anything that looks like a credential, the user's OHIO ID, name and email, and
   any hostname or context name that isn't on `.ohio.edu` or a public service. Replace those with
   `<user-added server>`.
3. Show the user the complete draft and get their approval.
4. Have the user open the issue form and paste the draft in, then submit it themselves, either with
   `gh issue create --repo ohioit/vscode-devcontainer-base --template adp-connect.yml --web` or at
   https://github.com/ohioit/vscode-devcontainer-base/issues/new?template=adp-connect.yml. Don't
   file the issue yourself.

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
  also be downloaded and used outside the image, which is its primary intent. `-C` is a
  read-only, non-interactive status check. If a user asks you to connect them, see
  [Connecting a user with adp-connect](#connecting-a-user-with-adp-connect).
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

Registry logins for Docker and Helm are handled by `sync-registry-credentials.sh` (installed as
`/usr/local/bin/sync-registry-credentials`) so both work with or without VS Code attached (e.g. the
devcontainer CLI alone). The image sets `DOCKER_CONFIG=/home/vscode/.config/docker`; VS Code's Dev
Containers extension rewrites `~/.docker/config.json` to forward credentials only while it is attached,
so that file is deliberately unused. Do not point anything back at `~/.docker`. The script writes:

- `${DOCKER_CONFIG}/config.json`: the host's `.docker/config.json` logins.
- `/home/vscode/.config/helm/registry/config.json`: the host's Docker logins, then its
  `.config/helm/registry/config.json` and `Library/Preferences/helm/registry/config.json` (later wins).

Only `auths` entries with an inline `auth` or `identitytoken` are kept; `credsStore`, `credHelpers` and
every other host Docker setting (contexts, plugin paths, proxies) are dropped, because host keychains and
paths are not reachable from the container. It must never print credentials. Helm (v3 and v4) checks its
own registry config first and then falls back to `${DOCKER_CONFIG}/config.json`. Ohio charts come from
`oci://docker.artifactory.oit.ohio.edu/charts`; `setup-container.sh` passes `docker.artifactory.oit.ohio.edu`
so startup reports whether it is usable. `adp-connect` only runs `helm registry login` when Docker has no
login for that registry.

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
bash -n sync-registry-credentials.sh
shellcheck setup-container.sh install-system-dependencies.sh install-user-dependencies.sh sync-registry-credentials.sh
git diff --check
```

For a Helm merge change, run the exact `yq eval-all` expression against two small YAML fixtures
and verify that each file's repository entries remain in the result. Build the image or run the
Skaffold workflow for changes affecting `Dockerfile`, package installation, entrypoint behavior,
or tooling versions.

When subtantive changes to the container are made, instruct the user to rebuild the devcontainer
to test changes.
