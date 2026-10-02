# ailease

给 AI、爬虫、CI、外包、临时运维开一个**用完即收**的环境。两种模式，一条命令：

```bash
sudo ailease new ai /clicd 2h           # 容器：容器内 root，只挂 /clicd，2 小时后自动停
sudo ailease new ai /clicd 2h --host    # 账号：ACL 限目录 + sudo 白名单，到期自动禁用
```

单文件 bash，root 运行。**容器版 / 账号版两个版本**共用同一套命令与参数，运行时自动判断用哪个。

---

## 为什么合并

原来有两个独立工具，各有各的适用面：

| | 容器（原 `aidocker`） | 账号（原 `aiuser.sh`） |
|---|---|---|
| 越界访问 | 命名空间隔离，宿主路径根本不存在 | ACL 只能授权，挡不住读 `/etc`、`/var/log` |
| 提权 | 容器内本来就是 root，无需绕过 | sudo 白名单可被解释器绕过 |
| 删错东西 | 容器内随便 `rm -rf /`，炸的是容器 | 靠 `aiuser-rm` 护栏 |
| 资源耗尽 | cgroup 硬限制 | ulimit 有限 |
| 清理 | 删容器，宿主机零残留 | 删账号 + 回收 ACL |
| 操作宿主机 | 做不到（挂 `/etc` 等于交出去） | 可以，`--rw/--ro` 授权 |
| 多目录 | 只挂一个 | 可重复 `--rw` / `--ro` |
| 无 docker 的机器 | 不可用 | 可用 |
| 磁盘配额 / 来源 IP 限制 | 无（bind mount 无配额） | 有 |

合并成一个 `ailease`：**默认优先用隔离更强的容器**，需要碰宿主机或机器跑不了 docker 时自动走账号版。安装也统一：`install` 装主程序与账号版，`install docker` 追加容器版。

---

## 快速开始

### 1. 安装

两个版本，按需装。**同一套命令与参数**，`new` 时自动判断用哪个。

```bash
sudo ./ailease install          # 主程序 + 账号版：护栏、回收器、SSH 收敛；不碰 docker
sudo ./ailease install docker   # 在上面基础上装 docker 引擎 + 基础镜像，启用容器版
sudo ./ailease install all      # 两者（等价 docker，因为 docker 版包含主程序）
```

`install`（默认 `host`）动作：迁移旧工具数据（见下）→ 建目录 → 写默认配置 → 装主程序到 `/usr/local/sbin/ailease` → 生成 `ailease-rm` 护栏 → 启用到期回收器（systemd timer，无 systemd 退回 cron）→ 重建 SSH 收敛块。

`install docker` 在此之上：检测并**尝试自动安装 docker**（apt/dnf/yum/zypper/apk）→ 拉取或构建基础镜像。装不上不致命，账号版照常可用。

一行从网上装（默认装账号版）：

```bash
wget -qO- https://raw.githubusercontent.com/4kercc/ai-lease/main/ailease | sudo bash
wget -qO- https://raw.githubusercontent.com/4kercc/ai-lease/main/ailease | sudo bash -s install docker
```

脚本检测到被管道喂进来（`$0` 是 `bash`），会按内置地址把主程序落到 `/usr/local/sbin/ailease`。别写成 `bash install`——那会让 bash 去找名为 `install` 的文件，管道内容被忽略；要么省略参数，要么 `bash -s install docker`。自建镜像站用 `AILEASE_URL=https://你的地址` 覆盖。

### 2. 开环境

```bash
sudo ailease new ai /clicd 2h           # 容器（默认）
sudo ailease new ai /clicd 2h --host    # 宿主机账号
```

位置参数顺序随意，自动识别：

| 位置 | 含义 | 省略时 |
|---|---|---|
| 名字 | 容器名 / 账号名 | 必填 |
| 目录 | 含 `/` 的参数 | 容器：`/var/lib/ailease/work/<名字>`；账号：`/srv/aiwork/<名字>` |
| 时长 | `30m` `2h` `7d` `2w` `1h30m` | `24h`（容器另支持 `never`） |
| 档位 | 仅 `--host` 用：`minimal` `dev` `ops` `none` | `minimal` |

```bash
sudo ailease new ai /clicd 7d --mem=4g --cpus=4     # 容器，大活
sudo ailease new ai /srv/data 12h --ro              # 容器，只读挂载
sudo ailease new ai /clicd 2h --public --pubkey-file=~/.ssh/id_ed25519.pub
sudo ailease new ai /clicd 2h --host dev            # 账号 + 开发档 sudo
sudo ailease new ai /clicd 2h --host none           # 账号，不给 sudo
```

容器创建后会打印登录方式、密码、挂载、到期、资源，并给出 `sudo ailease exec ai`。

### 3. 日常

```bash
sudo ailease list                 # 容器与账号都列出来
sudo ailease status ai            # 自动识别是容器还是账号
sudo ailease extend ai 1h         # 续期（容器会重新 start，账号会解锁）
sudo ailease exec ai              # 进容器
sudo ailease del ai               # 删除（会先问一句）
```

---

## 命令参考

| 命令 | 说明 |
|---|---|
| `new <名字> [目录] [时长] [选项]` | 建环境；默认容器，`--host` 走账号模式 |
| `create --name N [选项]` | 完整版账号创建（细调公钥、只读目录、配额时用） |
| `install [host\|docker\|all]` | 装主程序 / 追加 docker 版 / 两者；默认 `host` |
| `uninstall [--all]` | 卸载回收器与护栏（`--all` 连同容器与账号一起清） |
| `list` | 列出容器与账号 |
| `status <名字>` | 详情（自动识别容器 / 账号） |
| `exec <名字> [命令]` | 进容器，等同 `docker exec -it` |
| `extend <名字> <时长>` | 延长 |
| `del <名字> [-y]` | 删除（容器删容器；账号归档家目录后删） |
| `revoke <名字> [--purge]` | 只吊销账号：锁号不删，`--purge` 才删 |
| `fixacl [名字]` | 重放账号目录授权（装完 `acl` 包后用） |
| `cleanup` | 手动跑一次到期回收（容器 + 账号） |
| `check` | 环境自检 |
| `export [文件]` / `import <文件>` | 基础镜像离线导出 / 导入 |

全局：`--dry-run`（只打印不落盘）、`--quiet`、`-V`。

版本选择：默认 `auto`——docker 可用走容器版，否则走账号版；`--host` / `--container` 强制指定。也可把 `/etc/ailease/config` 的 `DEFAULT_MODE` 设成 `container` 或 `host` 固定默认（设成 `container` 时若 docker 不可用，仍会自动回退账号版并告警）。

---

## 容器模式

容器内以 root 运行，工作目录 `/work`，只挂你给的那一个目录。三条铁律脚本强制：

1. 不挂 `/var/run/docker.sock`（挂了等于给容器宿主机 root）
2. 不用 `--privileged` / `--pid=host` / `--network=host`
3. 不挂 `/`、`/etc`、`/root`、`/home` 等系统目录本体（`check_mount_path` 直接拒绝）

默认加固：`no-new-privileges`、削减 `SYS_ADMIN/SYS_MODULE/SYS_PTRACE/SYS_RAWIO/MKNOD/AUDIT_WRITE`、`pids-limit`、内存/CPU 上限、`nofile` 限制、端口只绑 `127.0.0.1`、`--restart no`。

资源默认值按宿主机推算（`DEFAULT_MEM` = 内存 1/4，夹在 128m~2048m；`DEFAULT_CPUS` = `min(nproc,2)`），避免在小机器上起不来。

**永不过期**：`sudo ailease new ai /clicd never`（`never` / `forever` / `permanent` 等价，写入 `EXPIRES=0`，回收器跳过）。代价是失去自动回收，只在长期项目上用。

**两条边界**：bind mount 的目录没有磁盘配额（容器写满 = 写满宿主分区）；容器内 root 写出的文件在宿主机属主是 root，要归你就加 `--user=$(id -u):$(id -g)`（代价是容器内不再是 root）。

容器选项：`--ro` `--public` `--bind=` `--port=` `--readonly` `--password=` `--pubkey=` `--pubkey-file=` `--user=` `--image=` `--mem=` `--cpus=` `--pids=`。

基础镜像默认 `ailease-base:bookworm`，由仓库自带的 `Dockerfile` **本地构建**，不依赖任何外部 registry（`install`/`new` 仍会先试 `docker pull`，拉不到就本地构建；构建带内存上限，不会拖垮小机器）。想改用自己推送到 registry 的现成镜像，把 `/etc/ailease/config` 里的 `DEFAULT_IMAGE` 指过去即可，重跑 `install` 会同步进配置。离线分发用 `export` / `import`。

---

## 宿主机账号模式（`--host`）

建一个限时 + 限权 + 限目录的宿主机账号。完整参数用 `create`：

```bash
sudo ailease create --name ai_dev --duration 7d \
  --pubkey-file ~/id_ed25519.pub --ssh-from 10.0.0.0/8 \
  --rw /srv/project --ro /opt/src --sudo-profile dev --quota 20G
```

| 选项 | 说明 | 默认 |
|---|---|---|
| `-n, --name NAME` | 账号名 `^[a-z_][a-z0-9_-]{0,31}$` | 必填 |
| `-t, --duration D` | 存活时长 | `24h` |
| `-p/--password` / `--password-stdin` / `--gen-password` | 密码来源 | — |
| `--force-change` | 首次登录强制改密 | 否 |
| `--pubkey` / `--pubkey-file` | 公钥 | — |
| `--ssh-from CIDR` | 仅允许该来源使用密钥（`from=`） | 不限 |
| `--rw PATH` / `--ro PATH` | 读写 / 只读目录，可重复 | — |
| `--workdir PATH` | 主工作目录 | `/srv/aiwork/<name>` |
| `--sudo-profile P` | `minimal` `dev` `ops` `none` | `minimal` |
| `--quota 20G` | 磁盘配额（需文件系统开 user quota） | — |
| `--shell PATH` / `--restricted` | 登录 shell / `/bin/rbash` | `/bin/bash` |

目录授权用 POSIX ACL：`--rw` 递归 `rwX` + 默认 ACL 继承，`--ro` 用 `rX`。工作目录不存在时以 root:root **0700** 建好再授权；已存在的目录只加 ACL，不动属主和原权限。授权路径做体检，拒绝把 `/`、`/etc`、`/usr`、`/var`、`/home` 本体交出去（子目录放行）。

**sudo 三档白名单**：

- `none`：不给 sudo
- `minimal`（默认）：包管理、`systemctl`/`journalctl`、`chmod`/`chown`、`mkdir`/`cp`/`mv`/`ln`、`tar`/`zip`、`rsync`/`curl`/`wget`/`scp`、`sed`/`awk`/`grep`/`find`、`ailease-rm`
- `dev`：追加 `git`、`python3`/`pip3`、`node`/`npm`、`docker`、`make`/`gcc`、编辑器、`ssh`、`bash`
- `ops`：追加 `kill`/`pkill`、`ip`/`ss`/`netstat`、`lsof`/`top`/`ps`、`loginctl`/`last`

无论哪档，`rm`/`dd`/`mkfs`/`fdisk`/`reboot`/`shutdown`/`insmod`/`chroot`/`visudo`/`su`/`passwd`/`mount`/`crontab` 等一律拒绝（黑名单用 `!` 取反，sudoers 最后匹配生效）。

**`ailease-rm` 护栏**：删除走白名单模型，只放行自家 home、`--workdir`、`--rw` 目录、`/tmp`、`/var/tmp`；系统保护根一律拒绝；`/tmp` 下非本人非 root 的文件拒绝（补 sticky bit 语义）；每次调用记 `rm.log`；只能经 sudo 由受管账号调用。

```bash
sudo ailease-rm -rf /srv/aiwork/ai_dev/build      # 允许
sudo ailease-rm /etc/nginx/nginx.conf             # 拒绝
```

**SSH 收敛**：关闭 TCP/X11/agent 转发与隧道、禁止空密码、`MaxSessions 8`。写成 `Match User` 块**追加在 `/etc/ssh/sshd_config` 末尾**，以 `# >>> ailease:<name> >>>` / `# <<< ailease:<name> <<<` 标记包裹，吊销时整块移除。每次写入都跑 `sshd -t`，失败即回滚。改完记得 `systemctl reload sshd`（脚本不自动重载）。

> 关于位置：实测（Debian 12 / OpenSSH 9.2）把 Match 块放进 `/etc/ssh/sshd_config.d/*.conf` 同样能正常工作——Match 作用域在 Include 文件结束时就重置，不会波及主配置里 Include 之后的 `Port`/`UsePAM`/`Subsystem`。本工具仍选择追加到主配置末尾，是为了不依赖该版本行为（早期 OpenSSH 与部分发行版对 Match 作用域边界的处理不一致），代价是要直接改主配置，因此带校验与回滚。若你的机器全是较新 OpenSSH，用 drop-in 也一样安全。

---

## 安全模型

容器模式是**结构性隔离**：AI 做什么都碰不到外面，不依赖策略是否正确。账号模式是**策略约束**：只约束命令名，约束不了命令内部行为。

**账号模式必读的边界**：一旦放行 `python3`/`node`/`bash`/`perl`，AI 等价于拿到 root shell，所以 `minimal` 刻意不给解释器，`dev`/`ops` 只发给可信的 AI。**但 `minimal` 也不是只读沙箱**——它放行的 `chmod`/`chown`/`cp`/`tee`/`find`/`tar`/`rsync` 都以 root 运行且能触达任意路径，实际语义是「root 级文件访问」，只有 `none` 才是真的只碰授权目录。

POSIX ACL 只有授予语义、没有拒绝语义：`/etc`、`/var/log` 这类天生 world-readable 的目录挡不住读，只能挡写。要真正的读隔离用容器模式。

这个工具解决的是**省事 + 防手滑 + 到期回收**，不是对抗性沙箱。要对抗性隔离请上独立 VM。

---

## 到期回收机制

两套模式共用一个回收器，每分钟跑一次 `ailease cleanup --quiet`，依次处理到期容器与到期账号。

- **容器**：到期 → `docker stop`；`PURGE_ON_EXPIRE=yes` 则连容器一起删。
- **账号**：到期 → 踢会话 → `usermod -L` → `chage -E 0` → 清空 `authorized_keys` → 移除 sudo/sshd/limits 配置 → 回收 ACL；`PURGE_ON_EXPIRE=yes` 则归档后 `userdel -r`。

另有粗粒度兜底：账号创建时把 `chage -E` 设成到期日的**次日**（`chage` 只有日期粒度，设当天会提前最多 23 小时踢人）。回收器停摆时，账号仍会在一天内失效。

docker 不可用时 `cleanup` 会跳过容器部分并提示，不会误判容器已消失。

---

## 文件布局

| 路径 | 内容 |
|---|---|
| `/usr/local/sbin/ailease` | 主程序 |
| `/usr/local/sbin/ailease-rm` | 账号模式的删除护栏 |
| `/etc/ailease/config` | 全局默认配置 |
| `/etc/sudoers.d/ailease-<name>` | sudo 策略片段，权限 `440` |
| `/etc/security/limits.d/ailease-<name>.conf` | 资源上限 |
| `/etc/ssh/sshd_config` | 末尾追加的受管 `Match User` 块 |
| `/etc/systemd/system/ailease-reaper.{service,timer}` | 回收器（无 systemd 时 `/etc/cron.d/ailease`） |
| `/etc/logrotate.d/ailease` | 日志轮转 |
| `/var/lib/ailease/containers/<name>.meta` | 容器元数据，权限 `600` |
| `/var/lib/ailease/users/<name>.meta` | 账号元数据，权限 `600` |
| `/var/lib/ailease/archive/` | 账号吊销时的家目录归档 |
| `/var/lib/ailease/work/<name>/` | 容器未指定目录时的默认挂载点 |
| `/var/log/ailease/audit.log` | 管理操作审计 |
| `/var/log/ailease/sudo-<name>.log` | 账号的 sudo 调用记录 |
| `/var/log/ailease/rm.log` | `ailease-rm` 的放行与拒绝记录 |

## 全局配置

编辑 `/etc/ailease/config`，保存即生效：

```bash
DEFAULT_MODE="auto"             # new 的默认版本：auto | container | host
DEFAULT_DURATION="24h"
DEFAULT_PROFILE="minimal"       # 账号模式的默认 sudo 档
DEFAULT_WORKROOT="/srv/aiwork"
DEFAULT_SHELL="/bin/bash"
PURGE_ON_EXPIRE="no"            # yes = 到期归档后删除账号 / 删除容器
KILL_ON_EXPIRE="yes"            # yes = 账号到期立即切断在线会话
REAPER_INTERVAL_SEC=60
INSTALL_DOCKER="yes"            # install docker 时是否自动装 docker（--no-docker 可关）
DEFAULT_MEM="512m"              # install 时按宿主机内存算出
DEFAULT_CPUS="2"
DEFAULT_PIDS="512"
DEFAULT_IMAGE="ailease-base:bookworm"
DEFAULT_BIND="127.0.0.1"
```

## 从旧工具迁移

`install` 会自动把 `aiuser` / `aidocker` 的现场并进来：停用并删除旧回收器（`aiuser-reaper`、`aidocker-reaper`）与旧 cron/logrotate 配置；把 `/var/lib/aidocker/containers`、`/var/lib/aiuser/{users,archive}` 搬到 `/var/lib/ailease/` 下；把 `/etc/sudoers.d/aiuser-*`、`/etc/security/limits.d/aiuser-*.conf` 改名为 `ailease-*`；清掉旧的 `sshd_config.d/aiuser-*.conf` 并重建 SSH 收敛块；重生成 sudoers（护栏路径 `aiuser-rm` → `ailease-rm`）；改写 `.bashrc` 里的旧标记与别名；删除旧命令 `/usr/local/sbin/{aiuser,aiuser-rm,aidocker}`。已有容器、账号、到期时间、归档全部保留。

> 更早的 `ai-tempuser` 一代请先在旧版 `aiuser.sh` 上跑一次 `install` 完成到 `aiuser` 的迁移，再迁到 `ailease`。

## 排错

**`new` 起不来 / 报 docker 不可用**：跑 `sudo ailease check` 看 docker 一节。想启用容器版：`sudo ailease install docker`；只用账号版：`new ... --host`。

**账号到期了但还活着**：`sudo ailease check` 看回收器一节，手工触发 `sudo ailease cleanup`。

**`sudo rm` 被拒**：设计如此，裸 `rm` 不在白名单。改用 `sudo ailease-rm <路径>`。

**`ailease-rm` 拒绝删 `/tmp` 下的文件**：该文件属主既不是调用者也不是 root。

**`setfacl` 找不到**：`apt install -y acl`（或 `dnf install -y acl`），然后 `sudo ailease fixacl <名字>`。

**容器里的文件宿主机改不了**：容器内 root 写出的文件属主是 root，用 `--user=$(id -u):$(id -g)` 重建。

**`--quota` 没生效**：需文件系统开 user quota，日志会提示并静默跳过。

**并发冲突**：`new`/`extend`/`del`/`revoke` 走 `flock` 加锁，同时执行会提示「另一个实例正在运行」。

## 卸载

```bash
sudo ailease uninstall          # 只卸回收器与护栏，保留容器与账号
sudo ailease uninstall --all    # 连同所有容器与账号一起清
```

之后可手工清理残留：

```bash
docker rmi ailease-base:bookworm debian:bookworm-slim
sudo rm -rf /var/lib/ailease /etc/ailease /var/log/ailease /usr/local/sbin/ailease
```

**卸载不会碰任何挂载目录，也不会碰你给账号授权的目录。**

## 依赖

必需：`coreutils`、`shadow`、`sudo`。

推荐：`docker`（容器版，`install docker` 会尝试自动装）、`acl`（账号版目录限制）、`openssh-server`（SSH 收敛）、`systemd`（精确回收器，无则退回 cron）、`quota`（可选）。

平台：Linux。`bash -n` 语法校验通过，脚本内已做 `set -Eeuo pipefail`。

---

`ailease` 合并取代了 `aiuser.sh` 与 `aidocker`，两者的原始文件与文档仍保留在仓库里作为参考（`README.md`、`README-aidocker.md`）。
