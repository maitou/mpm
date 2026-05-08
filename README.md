# mpm — Multi Proxy Manager

**English** | [中文](README.zh_CN.md)

## Overview

**mpm** is a multi-environment proxy manager for Linux.

It lets you switch and apply one local HTTP(S)/SOCKS proxy across shell, Docker, k3s, Go, and other development environments using reusable YAML preset groups — without manually editing scattered configs.

Inspired by tools like **nrm** / **yrm**, **mpm** provides simple commands for consistent proxy management across your system.

The CLI uses top-level verbs only (`use`, `current`, `ls`, `test`). See **`mpm --help`** for subcommands, options, and behavior.

## Install

### Requirements

- **Bash** 4+.
- **[yq](https://github.com/mikefarah/yq)** (mikefarah YAML) — required for `groups.yaml` / presets.
- **[jq](https://jqlang.github.io/jq/)** — required for `mpm current --json` / `mpm ls --json` (installer installs it).
- **curl** — required for `mpm test`.
- **sudo** for scopes that write under `/etc` (**docker**, **k3s**).

The installer installs **yq**, **jq**, and **curl** when missing. Default prefix is **`$HOME/.local`** (usually no root).

### One-shot install

Clone the repository and run **install.sh** (from any directory).

If **Git is unavailable** on the install machine (or `git clone` is blocked), download a source snapshot instead — for example **Code → Download ZIP** on the GitHub repository page — unpack it, `cd` into the extracted folder (next to **install.sh**, **`bin/mpm`**, **`lib/`**, **`share/`**), and run **`bash install.sh`** with the same flags as below.

**User-level** (install under the current user, default **`$HOME/.local`**, no root):

```bash
# Default (GitHub reachable)
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh
```

```bash
# Mainland China (CN-friendly download path for installer dependencies)
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh --download-source=cn
```

**System-wide** (install to `/usr/local`, requires **sudo**):

```bash
# Default
git clone https://github.com/maitou/mpm.git && cd mpm && sudo bash install.sh --prefix=/usr/local
```

```bash
# Mainland China (add --download-source=cn)
git clone https://github.com/maitou/mpm.git && cd mpm && sudo bash install.sh --prefix=/usr/local --download-source=cn
```

If you used the default prefix, ensure **`$HOME/.local/bin`** is on **`PATH`** (e.g. `export PATH="$HOME/.local/bin:$PATH"`), then run **`mpm --help`**. For a non-default prefix, add that prefix’s **`bin`** directory to **`PATH`** instead.

### Optional: mihomo systemd unit

To install a mihomo release archive and register **systemd** (separate from `mpm` CLI), use the script at the repo root.

On the mihomo **Linux** release assets, pick the **`.gz`** that matches your CPU architecture (for example **amd64** for typical x86_64 PCs and VMs, **arm64** for many ARM servers and Apple-silicon Linux VMs, **armv7** for older 32-bit ARM boards). Filenames follow `mihomo-linux-<arch>-<version>.gz`; download the one that fits your machine, then pass its path to the script (replace the placeholder below with your real file):

```bash
sudo ./install_mihomo_service.sh /path/to/mihomo-linux-*.gz
```

## Usage examples

```bash
mpm --list-scopes

# Apply built-in proxy group (sudo for docker/k3s on this machine)
sudo mpm use proxy-group

# Revert mpm-managed snippets
sudo mpm use direct-group

# Single stack
mpm use shell/proxy

# Same as above, plus sh export/unset lines on stdout (status table on stderr) for this session
eval "$(mpm use shell/proxy --export-shell-env)"

# Or refresh proxy env from inferred state without re-running use
eval "$(mpm shell-env --scopes=shell,go)"

mpm current
mpm ls
mpm test proxy-group --scopes=shell
```

## Scopes

| Scope   | What it touches | Root |
|---------|-----------------|------|
| `shell` | `~/.bashrc` mpm-marked `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` | no |
| `docker`| systemd drop-in for `docker.service` | yes |
| `k3s`   | systemd drop-ins for `k3s.service` / `k3s-agent.service` (if present) | yes |
| `go`    | No separate file writes in MVP; relies on **shell** exports for git-backed modules | no |

## Behavior notes

- **Multi-scope `use`**: best-effort; exit code **3** if some scopes fail after others succeeded.
- **Idempotent `use`**: each scope compares on-disk content to the target preset before writing.

## Out of scope

- Does **not** install or configure the proxy daemon itself (optional **install_mihomo_service.sh** only helps with mihomo).
- Does **not** modify image references in your git-hosted Kubernetes manifests or Dockerfiles.
