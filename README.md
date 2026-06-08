# mpm — Multi Proxy Manager

**English** | [中文](README.zh_CN.md)

## Overview

**mpm** is a multi-environment proxy manager for Linux.

It lets you switch and apply one local HTTP(S)/SOCKS proxy across shell, apt, Docker, k3s, Go, and other development environments using reusable YAML preset groups — without manually editing scattered configs.

Inspired by tools like **nrm** / **yrm**, **mpm** provides simple commands for consistent proxy management across your system.

The CLI uses top-level verbs only (`use`, `current`, `ls`, `test`, `shell-env`). See **`mpm --help`** for subcommands, options, and behavior.

After install, you **usually need to edit `/etc/mpm/overrides.yaml`** before **`mpm use`** (see [Before you use](#usage-notes)).

## Install

### Requirements

- **Bash** 4+.
- **[yq](https://github.com/mikefarah/yq)** (mikefarah YAML) — required for `groups.yaml` / presets.
- **[jq](https://jqlang.github.io/jq/)** — required for `mpm current --json` / `mpm ls --json` (installer installs it).
- **curl** — required for `mpm test`.
- **sudo** (prompted once via `sudo -v`) for scopes that write under `/etc` (**apt**, **docker**, **k3s**).

The installer installs **yq**, **jq**, and **curl** when missing. Default prefix is **`/usr/local`** (`mpm` is on the default system PATH).

### One-shot install

Clone the repository and run **install.sh** as your user (the script caches **`sudo -v`** then uses internal sudo for `/usr/local` and `/etc/mpm`).

If **Git is unavailable** on the install machine (or `git clone` is blocked), download a source snapshot instead — for example **Code → Download ZIP** on the GitHub repository page — unpack it, `cd` into the extracted folder (next to **install.sh**, **`bin/mpm`**, **`lib/`**, **`share/`**), and run **`bash install.sh`**.

```bash
# Default (GitHub reachable)
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh
```

```bash
# Mainland China (CN-friendly download path for installer dependencies)
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh --download-source=cn
```

Run **`mpm --help`** to verify the CLI; **do not** run **`mpm use`** yet — read [Before you use](#usage-notes) next.

### Optional: mihomo systemd unit

To install a mihomo release archive and register **systemd** (separate from `mpm` CLI), use the script at the repo root.

On the mihomo **Linux** release assets, pick the **`.gz`** that matches your CPU architecture (for example **amd64** for typical x86_64 PCs and VMs, **arm64** for many ARM servers and Apple-silicon Linux VMs, **armv7** for older 32-bit ARM boards). Filenames follow `mihomo-linux-<arch>-<version>.gz`; download the one that fits your machine, then pass its path to the script (replace the placeholder below with your real file):

```bash
sudo ./install_mihomo_service.sh /path/to/mihomo-linux-*.gz
```

### Next steps after install

**install.sh** seeds **`/etc/mpm/overrides.yaml`** (commented template). Before your first **`mpm use proxy-group`**, confirm:

1. Where your proxy listens (on WSL, that is almost always the **Windows host IP and port**, not `127.0.0.1`).
2. Uncomment and set **`defaults.proxy_port`** and **`scopes.<id>.proxy_host`** as needed (builtin names — see [Builtin proxy_host tokens](#builtin-ip)).

Then read [Usage examples](#usage-examples).

## Before you use

<a id="usage-notes"></a>

Built-in presets default to **`http://127.0.0.1:7890`** (shell/apt) or **`GATEWAY_IP:7890`** (docker/k3s). Unless your proxy listens on loopback **7890**, edit **`/etc/mpm/overrides.yaml`** (**created on install as a commented template**). **Overrides do not change** shipped preset files under `/usr/local/share/mpm/`; they affect runtime resolution only.

**Overall resolution:** **`MPM_OVERRIDES_FILE`** > **`/etc/mpm/overrides.yaml`** > built-in preset.

### Override configuration

<a id="override-config"></a>

| Field | Description |
|-------|-------------|
| `proxy_host` | [Builtin proxy_host tokens](#builtin-ip) or literal IP/hostname |
| `proxy_port` | Port string (`1`–`65535`) |
| `no_proxy` | Full replacement of preset `no_proxy` (not merged) |

**Within one overrides file:** `scopes.<id>` > `defaults`. If no overrides file exists (or a field is unset), mpm uses built-in preset defaults for that field.

```bash
sudo nano /etc/mpm/overrides.yaml
```

### Scopes and groups

| Scope | What it touches | Privileged |
|-------|-----------------|------------|
| `apt` | `/etc/apt/apt.conf.d/mpm-proxy.conf` (`Acquire::http::Proxy`, etc.); **effective on the next `apt-get`** | internal sudo |
| `shell` | `~/.bashrc` mpm-marked `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` | no |
| `docker` | systemd drop-in for `docker.service` (**restart** docker after change) | internal sudo |
| `k3s` | systemd drop-ins for `k3s.service` / `k3s-agent.service` (if present; **restart** units after change) | internal sudo |
| `go` | No separate file writes in MVP; relies on **shell** exports for git-backed modules | no |

Built-in groups live in **`share/profiles/groups.yaml`**:

| Group | Purpose |
|-------|---------|
| **`proxy-group`** | Map each scope to its **`proxy`** preset (URLs from presets + overrides). |
| **`direct-group`** | Remove mpm-managed fragments / apply **`direct`** preset semantics. |

You can also run **`mpm use SCOPE/PRESET`** (e.g. **`mpm use docker/proxy`**). **`proxy-group`** runs **apt → shell → docker → k3s → go** (internal sudo for apt/docker/k3s).

### Builtin proxy_host tokens

<a id="builtin-ip"></a>

In **`proxy_host`**, write these **token names** literally (no `${}` wrapper):

| Token | Meaning | In overrides | Typical use |
|-------|---------|--------------|-------------|
| **`DEFAULT_IP`** | `127.0.0.1` | `DEFAULT_IP` | Default for `shell` / `go` / `apt` |
| **`HOST_IP`** | Host LAN IPv4 | `HOST_IP` | When LAN address is needed |
| **`GATEWAY_IP`** | Docker/CNI gateway for the scope | `GATEWAY_IP` | Default for `docker` / `k3s` presets |
| **`WSL_HOST_IP`** | Windows host IPv4 from WSL | `WSL_HOST_IP` | WSL — proxy on Windows host |

**`WSL_HOST_IP`** is resolved at runtime to the Windows host IP, **not** a hostname. For **`k3s`**, **`GATEWAY_IP`** uses the **CNI** bridge (`cni0` / `flannel.1`); non-loopback clients need mihomo **allow-lan** and `0.0.0.0:7890`.

### Configure by scenario

<a id="overrides-examples"></a>

- **Local 7890**: If mihomo/clash listens on **`127.0.0.1:7890`**, leave overrides unchanged.
- **Port only**: `defaults.proxy_port: "10808"` (host stays at preset default).
- **WSL + Windows proxy**: YAML below.

Example when the Windows proxy uses port **10808** (all scopes via Windows host):

```yaml
defaults:
  proxy_port: "10808"
scopes:
  apt:
    proxy_host: WSL_HOST_IP
  shell:
    proxy_host: WSL_HOST_IP
  go:
    proxy_host: WSL_HOST_IP
  docker:
    proxy_host: WSL_HOST_IP
  k3s:
    proxy_host: WSL_HOST_IP
```

Then check with **`mpm current --scopes=shell`**. Temporary overrides file:

```bash
MPM_OVERRIDES_FILE=/path/to/overrides.yaml mpm current shell
```

### Built-in preset templates

<a id="preset-templates"></a>

`share/profiles/presets/*.yaml` defines proxy/direct URLs per scope, with literals, `${DEFAULT_IP}`, and **`params`** (e.g. **`params.PROXY_PORT`**). Override **`proxy_host`** tokens match preset builtin names; see [Override configuration](#override-config).

## Usage examples

<a id="usage-examples"></a>

The commands below assume **`/etc/mpm/overrides.yaml` is configured** for your environment (see [Before you use](#usage-notes)). Verify first:

```bash
mpm current --scopes=shell
# detail should show expected host/port (or overrides summary)
```

For WSL, complete the YAML in [WSL + Windows proxy](#overrides-examples) before running these commands.

### First-time proxy enable

```bash
mpm --list-scopes

# Built-in proxy group (apt → shell → docker → k3s → go; internal sudo for apt/docker/k3s)
mpm use proxy-group
```

### Revert and single-stack

```bash
mpm use direct-group

mpm use apt/proxy
mpm use shell/proxy
mpm use docker/proxy
```

### Immediate shell env

```bash
eval "$(mpm use shell/proxy --export-shell-env)"

# Refresh proxy env from inferred state without re-running use
eval "$(mpm shell-env --scopes=shell,go)"
```

### Inspect and test

```bash
mpm current
mpm ls
mpm test proxy-group --scopes=shell
```

### Do not sudo mpm

Do **not** run **`sudo mpm use proxy-group`** — shell scope would write **`/root/.bashrc`** instead of your user file.

## Behavior notes

- **Multi-scope `use`**: best-effort; exit code **3** if some scopes fail after others succeeded.
- **Idempotent `use`**: each scope compares on-disk content to the **resolved** target preset before writing.
- **apt / docker / k3s**: mpm prompts for **`sudo -v`** once when needed; do not prefix the whole command with **`sudo mpm`**.

## Out of scope

- Does **not** install or configure the proxy daemon itself (optional **install_mihomo_service.sh** only helps with mihomo).
- Does **not** modify image references in your git-hosted Kubernetes manifests or Dockerfiles.
- Does **not** configure **kind** cluster node proxies (use kind cluster YAML / future kind scope).
