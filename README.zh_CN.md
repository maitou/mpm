# mpm — Multi Proxy Manager

[English](README.md) | **中文**

## 概述

**mpm** 在 Linux 本机把同一套 **HTTP(S)/SOCKS** 代理（例如本机 [mihomo](https://github.com/MetaCubeX/mihomo) 监听 `http://127.0.0.1:7890`）写入 **shell**、**Docker**、**k3s** 以及与 **Go 工具链出站**相关的路径；通过 **`share/profiles/groups.yaml`** 里的 **group** 或 **`scope/preset`** 切换，**不**修改业务代码仓库。

CLI 仅支持顶层动词（`use`、`current`、`ls`、`test`）。完整约定见 **`mpm --help`** 与 [mpm/doc/mpm-prd.md](doc/mpm-prd.md)。

## 安装

### 环境要求

- **Bash** 4+。
- **[yq](https://github.com/mikefarah/yq)**（mikefarah YAML）— 读取 **`groups.yaml`** / presets 必需。
- **[jq](https://jqlang.github.io/jq/)** — `mpm current --json` / `mpm ls --json` 需要（安装脚本会尝试安装）。
- **curl** — `mpm test` 需要。
- 写入 **`/etc`** 的作用域需要 **sudo**（**docker**、**k3s**）。

### 安装方式

安装脚本会按需安装 **yq**、**jq**、**curl**，默认前缀 **`$HOME/.local`**（一般无需 root）。

#### 一键安装

克隆仓库并执行 **install.sh**（在任意目录执行即可）。

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

#### 自动安装

本地**已有**本仓库时，在仓库根目录（与 **install.sh**、**`bin/mpm`**、**`lib/`**、**`share/`** 同级）执行 **`bash install.sh`**，由脚本自动补齐依赖。

**用户级**：

```bash
# 默认
cd /path/to/mpm && bash install.sh
```

```bash
# 国内
cd /path/to/mpm && bash install.sh --download-source=cn
```

**系统级**：

```bash
# 默认
cd /path/to/mpm && sudo bash install.sh --prefix=/usr/local
```

```bash
# 国内
cd /path/to/mpm && sudo bash install.sh --prefix=/usr/local --download-source=cn
```

安装完成后若使用默认前缀，请确保 **`$HOME/.local/bin`** 在 **`PATH`** 中（例如 `export PATH="$HOME/.local/bin:$PATH"`），再执行 **`mpm --help`**。若使用其他前缀，请把该前缀下的 **`bin`** 加入 **`PATH`**。

### 可选：mihomo systemd

若要从发行版 **.gz** 安装 mihomo 并注册 **systemd**（与 `mpm` CLI 解耦），使用仓库根目录脚本：

```bash
sudo ./install_mihomo_service.sh /path/to/mihomo-linux-amd64-*.gz
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

## 行为说明

- **多作用域 `use`**：尽力而为；若部分失败、部分成功，退出码为 **3**。
- **幂等 `use`**：各作用域在写入前比对磁盘上的目标 preset 内容。

## 非目标

- **不**负责安装或启动代理进程本身（可选脚本 **install_mihomo_service.sh** 仅协助 mihomo）。
- **不**修改业务仓库里 Kubernetes 清单或 Dockerfile 中的镜像引用。
