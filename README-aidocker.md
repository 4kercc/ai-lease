# aidocker

> ⚠️ 本工具已并入 [`ailease`](README-ailease.md)，对应 `ailease new ...`（默认容器模式）。本文件作为历史参考保留，新部署请直接用 `ailease`。

给 AI 一个**用完即焚的一次性容器**：它在容器里是 root，随便折腾，但能碰到的只有你挂进去的那一个目录。

单文件 bash，root 运行，依赖宿主机已有的 docker。

```bash
sudo aidocker new ai /clicd 2h
```

起一个容器，把 `/clicd` 挂到容器内 `/work`，容器内 root 权限，2 小时后自动停，SSH 端口只开在 `127.0.0.1`。

---

## 为什么比宿主机临时账号强

| | 宿主机账号（aiuser.sh） | 容器（aidocker） |
|---|---|---|
| 越界访问 | ACL 只能授权，挡不住读 `/etc`、`/var/log` | 命名空间隔离，宿主机路径**根本不存在** |
| 进程可见性 | 能看到全部进程 | 只看到容器内自己的 |
| 提权 | sudo 白名单可被解释器绕过 | 容器内本来就是 root，无需绕过 |
| 删错东西 | 靠 `aiuser-rm` 护栏 | 容器内随便 `rm -rf /`，炸的是容器 |
| 资源耗尽 | ulimit 有限 | cgroup 硬限制内存/CPU/进程数 |
| 清理 | 删账号 + 回收 ACL | 删容器，宿主机零残留 |

**核心差异**：宿主机方案是「限制 AI 能做什么」，容器方案是「AI 做什么都碰不到外面」。后者是结构性的，不依赖策略是否正确。

---

## 快速开始

### 1. 安装

本地有脚本：

```bash
sudo ./aidocker install
```

一行从网上直接装：

```bash
wget -qO- https://raw.githubusercontent.com/4kercc/ai-lease/main/aidocker | sudo bash
```

脚本检测到自己是被管道喂进来的（`$0` 是 `bash` 而不是文件路径），会自动按内置地址把主程序落到 `/usr/local/sbin/aidocker`。也可以显式写子命令：

```bash
wget -qO- https://raw.githubusercontent.com/4kercc/ai-lease/main/aidocker | sudo bash -s install
```

**别写成 `bash install`** —— 那会让 bash 去找一个名为 `install` 的文件，管道内容直接被忽略。要么省略参数，要么用 `bash -s install`。

自建镜像站的话用环境变量覆盖地址：

```bash
wget -qO- 你的地址 | sudo AIDOCKER_URL=https://你的地址 bash
```

基础镜像 `aidocker-base:bookworm` 由仓库自带的 `Dockerfile` 本地构建（会先试 `docker pull`，拉不到就本地构建），并安装到期回收器。构建过程带内存上限，不会把小机器的其他服务拖垮。

### 2. 起容器

```bash
sudo aidocker new ai /clicd 2h
```

输出：

```
 登录     ssh -p 2001 root@你的服务器IP
 密码     Q^QZ1TgTrmK+V#UG1d3u+F9T
 路径     /clicd -> /work (rw)
 到期     2026-10-02 22:15:31（2h0m 后）
 资源     mem=128m cpus=1 pids=512
 归属     容器内 root 写出的文件，在宿主机上属主是 root（要归你可加 --user=0:0）

 进容器   sudo aidocker exec ai
```

「登录」那行的地址会自动适配：绑 `127.0.0.1` 就显示本机地址，加 `--public` 时自动探测服务器公网 IP 填进去，不用手工替换。

### 3. 用完删掉

```bash
sudo aidocker del ai
```

停容器 → 删容器 → 清元数据。**宿主机目录一个字节都不动。**

---

## 命令参考

| 命令 | 说明 |
|---|---|
| `new <名字> [目录] [时长] [选项]` | 起容器 |
| `install` | 构建基础镜像 + 装回收器 |
| `uninstall [--all]` | 卸载（`--all` 连同容器一起删） |
| `export [文件]` | 导出基础镜像，供离线分发到别的机器 |
| `import <文件>` | 导入基础镜像（小内存机器免构建） |
| `list` | 列出受管容器与剩余时间 |
| `status <名字>` | 详情（含 docker 实际状态、IP、启动时间） |
| `exec <名字> [命令]` | 进容器，等价 `docker exec -it` |
| `extend <名字> <时长>` | 延长，已停的容器会重新 `docker start` |
| `del <名字> [-y]` | 停并删容器 |
| `cleanup` | 手动跑一次到期回收 |
| `check` | 环境自检 |

### new 的位置参数

顺序随意，自动识别：

| 参数 | 识别方式 | 省略时 |
|---|---|---|
| 名字 | 第一个参数 | 必填 |
| 目录 | 含 `/` 的参数 | `/var/lib/aidocker/work/<名字>` |
| 时长 | `30m` `2h` `7d`，或 `never` | `24h` |

### new 的选项

| 选项 | 说明 |
|---|---|
| `--ro` | 目录只读挂载 |
| `--public` | 端口绑 `0.0.0.0`（默认只绑 `127.0.0.1`） |
| `--readonly` | 容器根文件系统只读，只留 `/tmp` `/run` 可写 |
| `--password=xxx` | 指定容器内 root 密码（默认自动生成 24 位） |
| `--pubkey='ssh-ed25519 AAAA...'` | 用公钥登录，不走密码 |
| `--pubkey-file=PATH` | 从文件读公钥（取首行），省得把长密钥贴进命令行 |
| `--user=uid:gid` | 以该 uid/gid 运行，挂载目录里写出的文件归它 |
| `--image=xxx` | 换镜像 |
| `--mem=2g --cpus=2 --pids=512` | 资源上限 |

示例：

```bash
sudo aidocker new ai /clicd 2h                        # 最简
sudo aidocker new ai /srv/data 7d --mem=4g --cpus=4   # 大活
sudo aidocker new ai /opt/src 12h --ro                # 只读参考
sudo aidocker new ai /work 24h --user=1000:1000       # 文件归属自己
```

### 永不过期

```bash
sudo aidocker new ai /clicd never
```

`never` / `forever` / `permanent` 三种写法等价。写入元数据的 `EXPIRES=0`，回收器扫描时直接跳过，`list` 显示「永不过期 / never」，`extend` 会提示无需延长。

**代价是失去自动回收保护。** 创建时会明确告警，但意味着：如果 AI 忘了收尾，容器会一直占着内存和端口。只在长期项目上用，并且自己记着 `aidocker del`。

`0` 不是 `never` 的简写——传 `0` 会被拒绝并提示改用 `never`，避免误输入把容器变成永久存在。

---

## 镜像分发

默认镜像 `aidocker-base:bookworm` 由仓库自带的 `Dockerfile` 本地构建，不依赖任何外部 registry。

`install` 和 `new` 都会**优先 `docker pull`**，拉不到才本地构建。所以新机器上一条命令就够：

```bash
sudo aidocker install
```

### 用自己的镜像

如果你已经把镜像推到了自己的 registry，改 `aidocker` 第 49 行的 `BASE_IMAGE`：

```bash
BASE_IMAGE="<你的镜像名>"
```

重跑 `install` 会自动同步进 `/etc/aidocker/config`——已装过的机器不用手工改配置。

仓库里的 `Dockerfile` 可直接构建推送：

```bash
docker build -t <你的镜像名> .
docker push <你的镜像名>
```

多架构一次推：

```bash
docker buildx create --use --name aidocker-builder
docker buildx build --platform linux/amd64,linux/arm64 \
  -t <你的镜像名> --push .
```

**arm64 在 x86 机器上会很慢**：要经 QEMU 逐条翻译 ARM 指令，`apt-get install` 那一层 amd64 用 24 秒，arm64 起步 187 秒，整层跑完十几分钟。只用 x86 服务器的话 `--platform linux/amd64` 就够了；确实要 arm64 建议挂 GitHub Actions 用原生 runner。

### 没外网的机器

源机导出（约 88MB）：

```bash
sudo aidocker export /tmp/aidocker-base.tar.gz
```

目标机导入：

```bash
scp 源机:/tmp/aidocker-base.tar.gz .
sudo aidocker import aidocker-base.tar.gz
```

导出的是 `docker save` + gzip 的产物，完整性可用 `gzip -t` 校验。

---

## 安全模型

### 三条铁律

脚本强制，手工绕过等于放弃隔离：

1. **不挂 `/var/run/docker.sock`** —— 挂了等于给容器宿主机 root，前面所有隔离归零
2. **不用 `--privileged` / `--pid=host` / `--network=host`** —— 隔离直接失效
3. **不挂 `/`、`/etc`、`/root`、`/home` 等系统目录本体** —— `check_mount_path` 会直接拒绝

### 默认加固

```
--security-opt no-new-privileges
--cap-drop=SYS_ADMIN,SYS_MODULE,SYS_PTRACE,SYS_RAWIO,MKNOD,AUDIT_WRITE
--pids-limit 512          防 fork bomb
--memory / --cpus         cgroup 硬限制
--ulimit nofile=4096:4096
-p 127.0.0.1::22          端口只开本机
--restart no              不自动重启
```

### 资源默认值按宿主机推算

写死 `--mem=2g` 在 469MiB 的机器上根本起不来。所以：

- `DEFAULT_MEM` = 宿主机内存的 1/4，夹在 `128m` ~ `2048m`
- `DEFAULT_CPUS` = `min(nproc, 2)`
- 构建镜像时 `--memory` = 可用内存的 3/4，避免触发 OOM Killer 带走别的服务

`install` 时如果内存 < 1GiB 会明确告警。

---

## 隔离实测结果

在 Debian 12 / 1 核 / 469MiB 的真实服务器上实测（同时跑着 jellyfin、qbittorrent、samba）：

| 验证项 | 结果 |
|---|---|
| 容器内身份 | `root` |
| 宿主机父目录 `/tmp/aitest` | 不可见 |
| 挂载点外文件 `/work/../outside.txt` | 读不到 |
| PID namespace | 容器内 4 个进程 vs 宿主机 124 个 |
| 容器内 PID 1 | `sleep 900`（容器自己的，不是宿主 init） |
| `/etc/shadow` | 容器自己的（`root:*::0:::::`） |
| cgroup 内存限制 | `memory.max = 50331648`（48MiB）生效 |
| cgroup 进程限制 | `pids.max = 64` 生效 |
| cgroup CPU 限制 | `cpu.max = 30000 100000`（0.3 核）生效 |
| 容器内 `mount` | 被拒绝（SYS_ADMIN 已削减） |
| 容器空闲内存占用 | 1.5 MiB |
| 装完软件后占用 | 6.7 MiB / 128 MiB |
| 构建镜像期间 | 生产容器全程无感，构建上限 183m |
| 完整流程 | install / new / list / status / extend / check / del 全通 |

镜像构建：`debian:bookworm-slim`（116MB）→ `aidocker-base:bookworm`（379MB），76 秒完成。

---

## 两条必须知道的边界

**1. bind mount 的目录没有磁盘配额**

容器内写满 `/work` = 写满宿主机对应分区。`--storage-opt` 管不到 bind mount。给 AI 挂载大目录时，建议单独分区，或定期 `df` 盯一下。

**2. 容器内 root 写出的文件，宿主机属主是 root**

实测确认：容器内 `echo x > /work/f`，宿主机上 `-rw-r--r-- 1 0 0`。你之后用普通用户改不了这些文件。

解法是加 `--user`：

```bash
sudo aidocker new ai /work 2h --user=$(id -u):$(id -g)
```

代价是容器内不再是 root，装系统包会受限。**二选一，不能都要。**

---

## 和 aiuser.sh 怎么选

| 场景 | 用哪个 |
|---|---|
| AI 只在一个目录里改代码/跑脚本 | `aidocker` |
| AI 要装各种软件、随便折腾环境 | `aidocker` |
| AI 需要改宿主机配置、装系统服务 | `aiuser` |
| AI 要操作宿主机上多个已有目录 | `aiuser`（ACL 授权多个） |
| 宿主机没装 docker / 内存太小 | `aiuser` |
| 最高安全要求 | 两个都别用，上独立 VM |

容器方案不是万能的：它要求宿主机有 docker，镜像和容器占磁盘，小内存机器上跑不了重负载。但对「给 AI 一个目录让它干活」这个具体需求，它是更正确的抽象。

---

## 文件布局

| 路径 | 内容 |
|---|---|
| `/usr/local/sbin/aidocker` | 主程序 |
| `/etc/aidocker/config` | 全局默认 |
| `/var/lib/aidocker/containers/<名字>.meta` | 容器元数据，权限 `600` |
| `/var/lib/aidocker/work/<名字>/` | 未指定目录时的默认挂载点 |
| `/var/log/aidocker/audit.log` | 操作审计 |
| `/etc/systemd/system/aidocker-reaper.{service,timer}` | 到期回收器 |

全局默认在 `/etc/aidocker/config`：

```bash
DEFAULT_DURATION="24h"
DEFAULT_MEM="128m"          # install 时按宿主机内存算出
DEFAULT_CPUS="1"
DEFAULT_PIDS="512"
DEFAULT_IMAGE="aidocker-base:bookworm"
DEFAULT_BIND="127.0.0.1"
PURGE_ON_EXPIRE="no"        # yes = 到期直接删容器
REAPER_INTERVAL_SEC=60
```

---

## 排错

**`new` 报内存不足或容器起不来**

宿主机可用内存不够。降 `--mem`，或者先 `free -m` 看看谁在吃。

**`docker build` 失败**

小内存机器上构建可能触顶。脚本已用 `--memory` 限制，但如果你把限制调太小会失败。直接跑 `sudo aidocker install` 看完整报错。

**AI 说 SSH 连不上**

默认只绑 `127.0.0.1`，只有宿主机本机能连。从别的机器连要加 `--public`，但那会暴露到公网——**务必同时改用公钥认证**：

```bash
sudo aidocker new ai /clicd 2h --public --pubkey='ssh-ed25519 AAAA...'
```

**容器里的文件宿主机改不了**

见上面「两条边界」第 2 条，用 `--user` 重建。

**到期了容器还在跑**

```bash
sudo aidocker check      # 看回收器那一节
sudo aidocker cleanup    # 手动触发一次
```

**想换基础镜像**

```bash
sudo aidocker new ai /clicd 2h --image=ubuntu:24.04
```

但那个镜像里没有 sshd，`new` 会起不来。自定义镜像要自带 sshd 并监听 22。

---

## 卸载

```bash
sudo aidocker uninstall          # 只卸回收器，保留容器
sudo aidocker uninstall --all    # 连同所有受管容器一起删
docker rmi aidocker-base:bookworm debian:bookworm-slim
sudo rm -rf /var/lib/aidocker /etc/aidocker /var/log/aidocker /usr/local/sbin/aidocker
```

**卸载不会碰任何挂载目录。** 宿主机上你给 AI 的那些目录原样保留。
