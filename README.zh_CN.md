# mpm — Multi Proxy Manager

[English](README.md) | **中文**

## 概述

**mpm** 是面向 Linux 的多环境代理管理工具。

它让你通过可复用的 **YAML 预设组合**，在 **apt**、**shell**、**Docker**、**kind**、**k3s**、**Go** 等开发环境里统一切换并套用同一套本机 **HTTP(S)/SOCKS** 代理，而无需手动编辑分散在各处的配置文件。

风格借鉴 **nrm**、**yrm** 等工具，**mpm** 用简洁的命令在全系统范围内提供一致的代理管理体验。CLI 仅支持顶层动词（`use`、`current`、`ls`、`test`、`shell-env`）；子命令、参数与行为说明以 **`mpm --help`** 为准。

安装完成后，**通常需要先编辑 `/etc/mpm/overrides.yaml`**，再执行 **`mpm use`**（见 [使用须知](#usage-notes)）。

## 安装

### 环境要求

- **Bash** 4+。
- **[yq](https://github.com/mikefarah/yq)**（mikefarah YAML）— 读取 **`groups.yaml`** / presets 必需。
- **[jq](https://jqlang.github.io/jq/)** — `mpm current --json` / `mpm ls --json` 需要（安装脚本会尝试安装）。
- **curl** — `mpm test` 需要。
- 写入 **`/etc`** 的作用域（**apt**、**docker**、**k3s**）由 mpm **内部 sudo** 完成（运行时会提示 **`sudo -v`**）。

安装脚本会按需安装 **yq**、**jq**、**curl**，默认前缀 **`/usr/local`**（`mpm` 在系统默认 PATH 中）。

### 一键安装

克隆仓库并以**当前用户**执行 **install.sh**（脚本会先 **`sudo -v`** 缓存凭证，再内部 sudo 写入 `/usr/local` 与 `/etc/mpm`）。

若安装环境**无法使用 Git**（或无法 `git clone`），可先下载源码包（例如仓库页的 **Code → Download ZIP**），解压后在目录根（与 **install.sh**、**`bin/mpm`**、**`lib/`**、**`share/`** 同级）执行 **`bash install.sh`**。

```bash
# 默认（GitHub 访问正常）
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh
```

```bash
# 国内（安装脚本下载依赖走国内友好路径）
git clone https://github.com/maitou/mpm.git && cd mpm && bash install.sh --download-source=cn
```

安装完成后执行 **`mpm --help`** 验证 CLI 可用；**不要**在此步直接 `mpm use` — 请先阅读 [使用须知](#usage-notes)。

### 可选：mihomo systemd

若要从发行版 **.gz** 安装 mihomo 并注册 **systemd**（与 `mpm` CLI 解耦），使用仓库根目录脚本。

在 mihomo **Linux** 发行资产中按 **CPU 架构**选 **`.gz`**（如 **amd64**、**arm64**、**armv7**），文件名一般为 `mihomo-linux-<架构>-<版本>.gz`，将实际路径传给脚本：

```bash
sudo ./install_mihomo_service.sh /path/to/mihomo-linux-*.gz
```

### 安装后下一步

安装时会生成 **`/etc/mpm/overrides.yaml`**（模板文件，字段默认注释）。在首次执行 **`mpm use proxy-group`** 前，请至少确认：

1. 本机代理监听地址与端口（WSL 用户几乎总是 **Windows 侧 IP + 端口**，不是 `127.0.0.1`）。
2. 按需取消注释并填写 **`defaults.proxy_port`**、**`scopes.<id>.proxy_host`**（内置名见 [proxy_host 内置名](#builtin-ip)）。

配置完成后再阅读 [使用示例](#usage-examples)。

### 卸载

<a id="uninstall"></a>

卸载 mpm **不会**自动撤销 **`mpm use`** 写入的代理配置。若需恢复直连，请先执行 **`mpm use direct-group`**。

与 **install.sh** 相同：请以**当前用户**执行（**不必**写 `sudo bash …` 或 `sudo mpm …`）。删除 `/usr/local` 或 `/etc/mpm` 时，脚本会先 **`sudo -v`** 缓存凭证，再内部调用 sudo。

```bash
# 默认：删除 /usr/local/bin/mpm 与 /usr/local/share/mpm；保留 /etc/mpm/overrides.yaml
bash uninstall.sh

# 或通过 CLI（选项相同）
mpm uninstall

# 同时删除系统 overrides
bash uninstall.sh --remove-overrides
```

可选参数：**`--prefix=DIR`**、**`--dry-run`**、**`--remove-overrides`**、**`--remove-yq`**、**`--remove-user-config`**。详见 **`bash uninstall.sh --help`**。

**`--prefix=$HOME/.local`** 且对该目录可写时，通常无需 sudo。**请勿**使用 **`sudo mpm uninstall`**（尤其带 **`--remove-user-config`** 时会误删 root 的配置目录）。

## 使用须知

<a id="usage-notes"></a>
内置预设默认多指向 **`http://127.0.0.1:7890`**（shell/apt）或 **`GATEWAY_IP:7890`**（docker/k3s）。除本机 loopback 且端口为 7890 外，多数环境需编辑 **`/etc/mpm/overrides.yaml`**（安装时会生成注释模板）；overrides **不修改** preset 文件，只影响运行时解析。优先级：**`MPM_OVERRIDES_FILE` > `/etc/mpm/overrides.yaml` > 内置 preset**。

### 覆盖配置说明

<a id="override-config"></a>

| 字段 | 说明 |
|------|------|
| `proxy_host` | 见 [proxy_host 内置名](#builtin-ip) 或字面 IP/hostname |
| `proxy_port` | 端口字符串（`1`–`65535`） |
| `no_proxy` | 整串替换 preset 中的 `no_proxy`（非合并） |

**同一 overrides 文件内：** `scopes.<id>` > `defaults`。无 overrides 文件（或某字段未设置）时，该字段使用 preset 内置默认值。

```bash
sudo nano /etc/mpm/overrides.yaml
```

### 作用域与组合

| 作用域 | 作用位置 | 提权 |
|--------|----------|------|
| `apt` | `/etc/apt/apt.conf.d/mpm-proxy.conf`（`Acquire::http::Proxy` 等）；**改后下一条 `apt-get` 即生效** | 内部 sudo |
| `shell` | `~/.bashrc` 中带 mpm 标记的 `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` | 否 |
| `docker` | `docker.service` 的 systemd drop-in（变更后需 **restart** docker） | 内部 sudo |
| `kind` | kind **节点容器内** `containerd` / `kubelet` 的 systemd drop-in（多集群；**禁止**节点内 `127.0.0.1` 代理） | 否（需 **docker** 组或 sudo docker） |
| `k3s` | `k3s.service` / `k3s-agent.service` 的 systemd drop-in（若存在；变更后需 **restart** unit） | 内部 sudo |
| `go` | MVP 不写独立文件；依赖 **shell** 导出供 git 模块等使用 | 否 |

内置组合定义在 **`share/profiles/groups.yaml`**：

| 组合 | 用途 |
|------|------|
| **`proxy-group`** | 各作用域映射到 **`proxy`** preset（URL 来自 preset + overrides）。 |
| **`direct-group`** | 移除 mpm 管理片段 / 应用 **`direct`** preset 语义。 |

也可单独执行 **`mpm use 作用域/preset`**（例如 **`mpm use docker/proxy`**）。**`proxy-group`** 默认顺序：**apt → shell → docker → kind → k3s → go**（apt/docker/k3s 内部 sudo；kind 需 docker CLI）。

### proxy_host 内置名

<a id="builtin-ip"></a>

在 **`proxy_host`** 字段可填下列**内置名**（直接写符号名，勿加 `${}`）：

| 内置名 | 含义 | 在 overrides 中的写法 | 常见适用 |
|--------|------|----------------------|----------|
| **`DEFAULT_IP`** | `127.0.0.1` | `DEFAULT_IP` | `shell` / `go` / `apt` 默认 |
| **`HOST_IP`** | 宿主机 LAN IPv4 | `HOST_IP` | 需 LAN 地址时 |
| **`GATEWAY_IP`** | 按作用域解析的 Docker/CNI 网关 | `GATEWAY_IP` | `docker` / `kind` / `k3s` preset 默认 |
| **`WSL_HOST_IP`** | WSL 环境下 Windows 宿主机 IPv4 | `WSL_HOST_IP` | WSL 全栈走 Windows 代理 |

`WSL_HOST_IP` 为运行时解析的 Windows 宿主机 IP，非 hostname。`k3s` 的 **`GATEWAY_IP`** 取自 CNI（`cni0` / `flannel.1`）；容器访问宿主机代理时 mihomo 须 **allow-lan** 且监听 `0.0.0.0:7890`。

### 按场景配置

<a id="overrides-examples"></a>

- **本机 7890**：若 mihomo/clash 监听 **`127.0.0.1:7890`**，可不编辑 overrides。
- **仅改端口**：`defaults.proxy_port: "10808"`（代理 host 仍用 preset 默认）。
- **WSL + Windows 代理**：见下方 YAML。

Windows 侧代理端口 **10808** 示例（全栈走 Windows 宿主机）：

```yaml
defaults:
  proxy_host: WSL_HOST_IP
  proxy_port: "10808"
```

`defaults.proxy_host` 会作用于所有 scope（含 **kind**）。若只改部分 scope，可在 `scopes.<id>.proxy_host` 单独覆盖。

`kind` preset 默认 **`GATEWAY_IP`**（kind docker 网桥 `172.18.0.1`）；在 WSL 上该地址通常**不是** Windows 代理，须用 **`WSL_HOST_IP`** 或依赖上述 `defaults`。

保存后可用 **`mpm current --scopes=shell`** 查看解析结果。临时指定 overrides 文件：

```bash
MPM_OVERRIDES_FILE=/path/to/overrides.yaml mpm current shell
```

### 内置预设模板

<a id="preset-templates"></a>

`share/profiles/presets/*.yaml` 定义各作用域的 proxy/direct URL，支持字面量、`${DEFAULT_IP}` 等与 **`params`**（如 **`params.PROXY_PORT`**）；[覆盖配置说明](#override-config) 中的 **`proxy_host` 内置名与 preset 一致**。

## 使用示例

<a id="usage-examples"></a>

以下命令假设 **`/etc/mpm/overrides.yaml` 已按你的环境配置**（见 [使用须知](#usage-notes)）。先验证解析结果：

```bash
mpm current --scopes=shell
# detail 中应显示期望的 host/port（或 overrides 摘要）
```

WSL 场景请先完成 [WSL + Windows 代理](#overrides-examples) 中的 YAML，再执行下列命令。

### 首次启用代理

```bash
mpm --list-scopes

# 内置走代理组合（apt → shell → docker → kind → k3s → go；apt/docker/k3s 内部 sudo）
mpm use proxy-group
```

### 撤销与单栈

```bash
mpm use direct-group

mpm use apt/proxy
mpm use shell/proxy
mpm use docker/proxy
```

### shell 立即生效

```bash
eval "$(mpm use shell/proxy --export-shell-env)"

# 不重跑 use，仅按推断状态刷新代理环境变量
eval "$(mpm shell-env --scopes=shell,go)"
```

### 查看与测试

```bash
mpm current
mpm ls
mpm test proxy-group --scopes=shell
```

### 请勿 sudo mpm

请勿使用 **`sudo mpm use proxy-group`** — shell 作用域会写入 **`/root/.bashrc`** 而非你的用户文件。

## 行为说明

- **多作用域 `use`**：尽力而为；若部分失败、部分成功，退出码为 **3**。
- **幂等 `use`**：各作用域在写入前比对磁盘上的目标 preset 内容（比对的是**解析后**的 URL）。
- **apt / docker / k3s**：需要时 mpm 会提示 **`sudo -v`**；请勿对整个命令使用 **`sudo mpm`**。

## 非目标

- **不**负责安装或启动代理进程本身（可选脚本 **install_mihomo_service.sh** 仅协助 mihomo）。
- **不**修改业务仓库里 Kubernetes 清单或 Dockerfile 中的镜像引用。
- **kind**：管理 **已存在** kind 集群各节点容器内的 containerd/kubelet 代理；新建集群后执行 **`mpm use kind/proxy`**（或与 **`proxy-group`** 一并应用）。与 **smoctl** create-time env 可并存。
