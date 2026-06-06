# mpm — Multi Proxy Manager

[English](README.md) | **中文**

## 概述

**mpm** 是面向 Linux 的多环境代理管理工具。

它让你通过可复用的 **YAML 预设组合**，在 **shell**、**Docker**、**k3s**、**Go** 等开发环境里统一切换并套用同一套本机 **HTTP(S)/SOCKS** 代理，而无需手动编辑分散在各处的配置文件。

风格借鉴 **nrm**、**yrm** 等工具，**mpm** 用简洁的命令在全系统范围内提供一致的代理管理体验。CLI 仅支持顶层动词（`use`、`current`、`ls`、`test`）；子命令、参数与行为说明以 **`mpm --help`** 为准。

## 安装

### 环境要求

- **Bash** 4+。
- **[yq](https://github.com/mikefarah/yq)**（mikefarah YAML）— 读取 **`groups.yaml`** / presets 必需。
- **[jq](https://jqlang.github.io/jq/)** — `mpm current --json` / `mpm ls --json` 需要（安装脚本会尝试安装）。
- **curl** — `mpm test` 需要。
- 写入 **`/etc`** 的作用域需要 **sudo**（**docker**、**k3s**）。

安装脚本会按需安装 **yq**、**jq**、**curl**，默认前缀 **`$HOME/.local`**（一般无需 root）。

### 一键安装

克隆仓库并执行 **install.sh**（在任意目录执行即可）。

若安装环境**无法使用 Git**（或无法 `git clone`），可先在本机或能访问 GitHub 的环境下载源码包（例如仓库页的 **Code → Download ZIP**），将压缩包传到目标机并解压，在解压后的目录根目录（与 **install.sh**、**`bin/mpm`**、**`lib/`**、**`share/`** 同级）执行 **`bash install.sh`**，参数与下文一致。

**用户级**（安装到当前用户目录，默认 **`$HOME/.local`**，无需 root）：

```bash
# 默认（GitHub 访问正常）
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh
```

```bash
# 国内（安装脚本下载依赖走国内友好路径）
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh --download-source=cn
```

**系统级**（安装到 `/usr/local`，需 **sudo**）：

```bash
# 默认
git clone https://github.com/maitou/mpm.git && cd mpm && sudo bash install.sh --prefix=/usr/local
```

```bash
# 国内（加上 --download-source=cn）
git clone https://github.com/maitou/mpm.git && cd mpm && sudo bash install.sh --prefix=/usr/local --download-source=cn
```

安装完成后若使用默认前缀，请确保 **`$HOME/.local/bin`** 在 **`PATH`** 中（例如 `export PATH="$HOME/.local/bin:$PATH"`），再执行 **`mpm --help`**。若使用其他前缀，请把该前缀下的 **`bin`** 加入 **`PATH`**。

### 可选：mihomo systemd

若要从发行版 **.gz** 安装 mihomo 并注册 **systemd**（与 `mpm` CLI 解耦），使用仓库根目录脚本。

在 mihomo 的 **Linux** 发行资产里，按本机 **CPU 架构**选择对应的 **`.gz`**：常见 **amd64**（多数 x86_64 台式机/虚拟机）、**arm64**（许多 ARM 服务器、Apple 芯片上的 Linux 虚拟机等）、**armv7**（较老的 32 位 ARM 板等）。文件名一般为 `mihomo-linux-<架构>-<版本>.gz`；下载与机器匹配的那一个，再把**实际路径**传给脚本（下面示例里的路径请换成你下载的文件）：

```bash
sudo ./install_mihomo_service.sh /path/to/mihomo-linux-*.gz
```

## 使用示例

```bash
mpm --list-scopes

# 内置走代理组合（本机 docker/k3s 需 sudo）
sudo mpm use proxy-group

# 撤销 mpm 写入片段
sudo mpm use direct-group

# 只改某一栈
mpm use shell/proxy

# 同上，并在 stdout 输出可 eval 的 export/unset（状态表在 stderr），当前 shell 立即生效
eval "$(mpm use shell/proxy --export-shell-env)"

# 不重跑 use，仅按推断状态刷新代理环境变量
eval "$(mpm shell-env --scopes=shell,go)"

mpm current
mpm ls
mpm test proxy-group --scopes=shell
```

## 作用域

| 作用域   | 作用位置 | 需要 root |
|----------|----------|-----------|
| `shell`  | `~/.bashrc` 中带 mpm 标记的 `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` | 否 |
| `docker` | `docker.service` 的 systemd drop-in | 是 |
| `k3s`    | `k3s.service` / `k3s-agent.service` 的 systemd drop-in（若存在） | 是 |
| `go`     | MVP 不写独立文件；依赖 **shell** 导出供 git 模块等使用 | 否 |

## Preset 模板变量

`share/profiles/presets/*.yaml` 中 `http_proxy` / `https_proxy` / `all_proxy` 支持：

- **字面量**：`http://127.0.0.1:7890`（不含 `${` 则不替换）
- **内置变量**：`${DEFAULT_IP}`（127.0.0.1）、`${HOST_IP}`（宿主机 LAN IP）、`${GATEWAY_IP}`（按作用域解析）
- **自定义参数**：preset 内 `params.PROXY_PORT` 等，用于 `${PROXY_PORT}`

| 作用域 | 推荐变量 |
|--------|----------|
| `shell` / `go` | `${DEFAULT_IP}` |
| `docker` / `k3s` | `${GATEWAY_IP}` |

`k3s` 的 `GATEWAY_IP` 取自 **CNI**（`cni0` / `flannel.1`）。非 loopback 客户端访问 mihomo 时须开启 **allow-lan** 并监听 `0.0.0.0:7890`。

单元测试：`tests/template_test.sh`

## 行为说明

- **多作用域 `use`**：尽力而为；若部分失败、部分成功，退出码为 **3**。
- **幂等 `use`**：各作用域在写入前比对磁盘上的目标 preset 内容（比对的是**解析后**的 URL）。

## 非目标

- **不**负责安装或启动代理进程本身（可选脚本 **install_mihomo_service.sh** 仅协助 mihomo）。
- **不**修改业务仓库里 Kubernetes 清单或 Dockerfile 中的镜像引用。
