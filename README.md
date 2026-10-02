# aiuser.sh

> ⚠️ 本工具已并入 [`ailease`](README-ailease.md)，对应 `ailease new ... --host` 模式。本文件作为历史参考保留，新部署请直接用 `ailease`。

给 AI、爬虫、CI、外包、临时运维开一个**限时 + 限权 + 限目录**的 Linux 账号，到期自动禁用并归档，事后一键吊销。

单文件 bash，root 运行，除 `acl` 包外零外部依赖。

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [核心特性](#核心特性)
- [快速开始](#快速开始)
- [命令参考](#命令参考)
- [安全模型](#安全模型)
- [到期回收机制](#到期回收机制)
- [文件布局](#文件布局)
- [全局配置](#全局配置)
- [审计与日志](#审计与日志)
- [排错](#排错)
- [卸载](#卸载)
- [限制与替代方案](#限制与替代方案)

---

## 它解决什么问题

丢一个 root 账号给 AI 跑自动化，等于把整台机器交出去。但建一个真正受限的账号要手工做六件事：加用户、配密钥、算到期日、写 `chage`、铺 `setfacl`、编 `sudoers`——还容易配错，事后忘了回收。

这个脚本把六件事收成一条命令，并保证到期一定回收。

```bash
sudo aiuser new ai /clicd 2h
```

建 `ai` 账号、给 `/clicd` 完全读写、2 小时后自动禁用、密码自动生成并打印。就这样。

---

## 核心特性

| 能力 | 实现方式 |
|---|---|
| 快速加账号 | 密码或 SSH 公钥，支持锁来源 IP（`from=`） |
| 存活时长 | 精确到分钟，systemd timer / cron 每分钟扫描，到期自动锁定 |
| 目录限制 | POSIX ACL 递归授权 + 默认 ACL 继承，吊销时自动回收 |
| 权限限制 | sudo 三档白名单 + 危险命令黑名单兜底，裸 `rm` 一律不授予 |
| 删除护栏 | `aiuser-rm` 白名单模型，只放行自家 home、授权目录、`/tmp`、`/var/tmp` |
| 资源上限 | `nproc` / `nofile` / `maxlogins` / `core`，可选磁盘配额 |
| 审计 | 独立 sudo 日志、bash 命令历史进 syslog、`aiuser-rm` 拒绝记录 |
| 生命周期 | 延长、吊销、归档、一键清理，全部幂等 |
| 自检 | `check` 扫描依赖、权限泄露、回收器状态 |

---

## 快速开始

### 1. 安装

```bash
sudo ./aiuser.sh install
```

安装动作：建目录 → 写默认配置 → 把主程序复制到 `/usr/local/sbin/aiuser` → 生成 `/usr/local/sbin/aiuser-rm` 护栏 → 启用到期回收器（systemd timer，无 systemd 时退回 cron）→ 写 logrotate 规则。

装完即可直接调用：

```bash
sudo aiuser --help
```

**别跳过这一步。** 不装的话：`aiuser` 和 `aiuser-rm` 短命令都不存在（只能 `bash aiuser.sh ...`），而且**到期回收器没装上，账号到期后不会自动禁用**，只剩 `chage` 的次日兜底。

**从旧版 `ai-tempuser` 升级**：覆盖脚本后跑一次 `install` 就行，安装过程会自动迁移——停用旧的 `ai-tempuser-reaper.timer`、把 `/var/lib/ai-tempuser`、`/var/log/ai-tempuser`、`/etc/ai-tempuser` 整体改名到 `aiuser`、逐账号搬移 `sudoers.d` / `sshd_config.d` / `limits.d` 片段、按新护栏路径重新生成 sudoers、把 SSH 收敛从 `sshd_config.d` 迁移到 `sshd_config` 末尾的受管块、清掉 `.bashrc` 里的旧标记，最后删除旧命令 `ai-tempuser` 和 `ai-rm`。已有账号、到期时间、归档全部原样保留，不用重建。

### 2. 开一个账号

```bash
sudo aiuser new ai /clicd 2h
```

四个位置参数，顺序随意：

| 位置 | 含义 | 省略时 |
|---|---|---|
| 用户名 | 要建的账号名 | 必填 |
| 目录 | 给它完全读写权限的目录 | `/srv/aiwork/<用户名>` |
| 时长 | 能用多久 | `24h` |
| 档位 | sudo 权限档 | `minimal` |

目录不存在会自动建出来；已存在的目录只加 ACL 授权，属主和原有权限一律不碰。密码自动生成并打印一次。

几种常见写法：

```bash
sudo aiuser new ai /clicd 2h          # 目录 + 2 小时
sudo aiuser new ai /clicd             # 目录 + 默认 24 小时
sudo aiuser new ai 2h                 # 默认目录 + 2 小时
sudo aiuser new ai                    # 全默认
sudo aiuser new ai /clicd 2h dev      # 额外放行 git / python / docker
```

时长写法：`30m` `2h` `12h` `7d` `2w` `1h30m`。档位：`minimal` `dev` `ops` `none`。

需要更细的控制（公钥登录、只读目录、磁盘配额、来源 IP 限制）时，用完整版 `create`：

```bash
sudo aiuser create --name ai_dev \
  --duration 7d \
  --pubkey-file ~/id_ed25519.pub \
  --ssh-from 10.0.0.0/8 \
  --rw /srv/project \
  --ro /opt/src \
  --sudo-profile dev \
  --quota 20G
```

### 3. 日常操作

```bash
sudo aiuser list                      # 谁还在，还剩多久
sudo aiuser status ai                # 单个账号详情
sudo aiuser extend ai 1h              # 续命一小时
sudo aiuser del ai                    # 删除账号（会先问一句）
```

账号内部删除文件：

```bash
sudo aiuser-rm /clicd/tmp/build                # 护栏校验后执行
```

---

## 命令参考

### 全局开关

| 开关 | 说明 |
|---|---|
| `--dry-run` | 只打印将要执行的动作，不落盘 |
| `--quiet` | 安静模式，抑制常规输出 |
| `-h, --help` | 显示帮助 |
| `-V, --version` | 显示版本 |

### new（推荐入口）

```bash
sudo aiuser new <用户名> [目录] [时长] [档位]
```

位置参数，顺序随意。识别规则：

| 参数 | 识别方式 |
|---|---|
| 用户名 | 第一个参数 |
| 目录 | 含 `/` 的参数 |
| 时长 | 匹配 `30m` `2h` `7d` `2w` `1h30m` 或纯数字 |
| 档位 | `minimal` / `dev` / `ops` / `none` |

目录不存在会自动创建；已存在则只加 ACL，不动属主与原有权限。密码自动生成。

等价于：

```bash
sudo aiuser create --name <用户名> --duration <时长> \
     --gen-password --sudo-profile <档位> --workdir <目录>
```

别名：`add`、`mk`。省略参数时打印用法。

### install

```bash
sudo aiuser install
```

幂等，可重复执行。已有配置不会被覆盖。

### uninstall

```bash
sudo aiuser uninstall          # 只卸回收器与护栏
sudo aiuser uninstall --all    # 连同所有受管账号一起吊销
```

`/var/lib/aiuser` 与 `/etc/aiuser` 会保留，便于事后取证。

### create

```bash
sudo aiuser create --name NAME [选项]
```

| 选项 | 说明 | 默认 |
|---|---|---|
| `-n, --name NAME` | 账号名。`^[a-z_][a-z0-9_-]{0,31}$` | 必填 |
| `-t, --duration D` | 存活时长：`30m` `12h` `7d` `2w` `1h30m` 或纯秒数 | `24h` |
| `-p, --password PASS` | 直接设密码（会进 shell history） | — |
| `--password-stdin` | 从标准输入读密码 | — |
| `--gen-password` | 自动生成 24 位强密码并打印一次 | — |
| `--force-change` | 首次登录强制改密 | — |
| `--pubkey 'ssh-ed25519 AAAA...'` | 直接给公钥 | — |
| `--pubkey-file PATH` | 从文件读公钥（取首行） | — |
| `--ssh-from CIDR` | 仅允许该来源使用此密钥，写进 `from=` | 不限 |
| `--rw PATH` | 可读写目录，可重复 | — |
| `--ro PATH` | 只读目录，可重复 | — |
| `--workdir PATH` | 主工作目录 | `/srv/aiwork/<name>` |
| `--sudo-profile P` | `minimal` `dev` `ops` `none` | `minimal` |
| `--quota 20G` | 磁盘配额，需文件系统开启 user quota | — |
| `--shell PATH` | 登录 shell | `/bin/bash` |
| `--restricted` | 使用 `/bin/rbash` 受限 shell | 否 |

密码与公钥至少提供一种。

创建时会做**授权路径体检**：拒绝把 `/`、`/etc`、`/usr`、`/var`、`/home` 等系统目录本体交出去（子目录如 `/etc/nginx/conf.d` 放行）。

### list

```bash
sudo aiuser list
```

输出 `NAME / STATUS / CREATED / EXPIRES / REMAIN / SUDO` 六列。

### status

```bash
sudo aiuser status ai_dev
```

除元数据外，还会交叉验证系统侧真实状态：用户是否还存在、`passwd -S` 的锁定标志、`chage -l` 的系统到期日、sudoers 片段是否在位。

### extend

```bash
sudo aiuser extend ai_dev 24h
```

在现有到期时间上叠加，同时解除锁定。已 `expired` / `revoked` 的账号会被重新激活。

### del

```bash
sudo aiuser del ai            # 交互确认
sudo aiuser del ai -y         # 跳过确认（脚本/AI 调用用这个）
```

一步删干净：踢掉在线会话 → 锁定账号 → 摘除密钥 → 移除 sudo / sshd / limits 配置 → 回收 ACL → **归档家目录** → `userdel -r`。归档落在 `/var/lib/aiuser/archive/`。

终端里会问一句 `确认？[y/N]`；非交互环境（管道、脚本）必须显式加 `-y`，否则直接拒绝，避免误删。

别名：`delete`、`remove`。

想要**只锁号不删**，用 `revoke`。

### fixacl

```bash
sudo aiuser fixacl ai        # 刷单个账号
sudo aiuser fixacl           # 刷所有受管账号
```

按元数据把目录授权重新刷一遍。典型用途：建号时机器上还没装 `acl` 包，事后补装——跑一次即可，不用重建账号、不用换密码。

它走的是递归 `setfacl -R`，对备份快照这类超大目录会遍历全部文件，耗时可能很长。只要顶层权限时手工两条更划算：

```bash
setfacl -m  u:ai:rwx  /clicd-backups
setfacl -d -m u:ai:rwx /clicd-backups
```

### revoke

和 `del` 的区别：`revoke` 默认**只锁号、不删账号**，适合临时冻结或留待取证。要一步删干净用 `del`。

```bash
sudo aiuser revoke ai_dev                  # 吊销，保留家目录
sudo aiuser revoke ai_dev --purge          # 归档后删除账号
sudo aiuser revoke ai_dev --purge --keep-home   # 删除账号但不归档
```

吊销动作序列：踢掉在线会话 → `usermod -L` → `chage -E 0` → 备份并清空 `authorized_keys` → 移除 sudo / sshd / limits 配置 → 回收 ACL 授权。

### cleanup

```bash
sudo aiuser cleanup
```

扫描并处理所有已到期账号。回收器定时调用的就是这个命令，也可以手工触发。

### check

```bash
sudo aiuser check
```

检查项：依赖命令是否齐全、`/etc/shadow` 权限、sudoers 是否 include `/etc/sudoers.d`、`/home/*` 是否存在跨用户可读、回收器是否在跑、受管账号数量。发现问题返回非零。

---

## 安全模型

### sudo 三档白名单

| 档位 | 包含 | 适用 |
|---|---|---|
| `none` | 不授予任何 sudo | 只做纯文件读写 |
| `minimal` | 包管理、`systemctl`/`journalctl`、`chmod`/`chown`/`chgrp`、`mkdir`/`cp`/`mv`/`ln`/`touch`、`tar`/`zip`、`rsync`/`curl`/`wget`/`scp`、`sed`/`awk`/`grep`/`find`、`aiuser-rm` | 默认档。**不含任何解释器** |
| `dev` | 追加 `git`、`python3`/`pip3`、`node`/`npm`、`docker`、`make`/`gcc`、编辑器、`ssh`、`bash` | 需要构建与脚本 |
| `ops` | 追加 `kill`/`pkill`、`ip`/`ss`/`netstat`、`lsof`/`top`/`ps`、`loginctl`/`last` | 需要看进程与网络 |

`minimal` 档放行的具体命令：

```
apt apt-get dpkg yum dnf rpm zypper
systemctl journalctl
chmod chown chgrp mkdir cp mv ln touch stat
tar gzip gunzip zip unzip rsync curl wget scp
tee sed awk grep find sort
aiuser-rm
```

### 危险命令黑名单

无论哪一档，以下命令一律拒绝，白名单里出现也会被 `!` 取反覆盖（sudoers 以最后匹配的规则为准）：

```
rm unlink shred                      # 裸删除，删除必须走 aiuser-rm
dd mkfs mkfs.* fdisk parted sfdisk   # 磁盘写入
wipefs blkdiscard fallocate
reboot shutdown halt poweroff init   # 关机重启
insmod rmmod modprobe kexec          # 内核模块
chroot visudo su                     # 提权面
passwd chpasswd useradd userdel usermod   # 账号管理
mount umount crontab at              # 挂载与计划任务
chmod -R 777 /   chown -R root /   rm -rf /
```

### aiuser-rm 护栏

删除操作走白名单模型，判定顺序：

1. 目标路径 `readlink -m` 规范化（解析 `..` 与符号链接）
2. 落在**允许根**内 → 放行：自家 home、`--workdir`、所有 `--rw` 目录、`/tmp`、`/var/tmp`
3. 落在**系统保护根**内 → 拒绝：`/` `/bin` `/boot` `/dev` `/etc` `/lib` `/lib32` `/lib64` `/proc` `/root` `/run` `/sbin` `/srv` `/sys` `/usr` `/var`
4. 其余一律拒绝

附加防线：

- `--no-preserve-root` 作用于 `/` 直接拒绝
- 临时区 owner 校验：`aiuser-rm` 以 root 运行，内核 sticky bit 不生效，因此显式检查 `/tmp`、`/var/tmp` 下目标文件的属主，非调用者且非 root 的一律拒绝
- 每次调用写 `/var/log/aiuser/rm.log`，拒绝原因一并记录
- 只能经 `sudo` 调用，且调用者必须是受管账号

```bash
sudo aiuser-rm -rf /srv/aiwork/ai_dev/build      # 允许
sudo aiuser-rm /etc/nginx/nginx.conf             # 拒绝
sudo aiuser-rm /tmp/别人的文件                     # 拒绝（属主校验）
```

### 目录访问控制与 ACL 的边界

`--rw` 使用 `setfacl -R -m u:NAME:rwX` 加递归默认 ACL，新建文件自动继承；`--ro` 用 `rX`。

工作目录默认 `/srv/aiwork/<name>`，属主 root、权限 `0700`，只对目标账号开 ACL——其他用户进不去。

**必须知道的边界**：POSIX ACL 只有授予语义，没有拒绝语义。`/etc`、`/var/log`、`/usr` 这类系统目录天生 world-readable，ACL 挡不住读取，只能挡住写入。`check` 子命令会检查 `/home/*` 是否存在跨用户可读，并把这个提醒再打印一次。

要真正的读隔离，需要容器 / `systemd-nspawn` / `bwrap` 级别的挂载命名空间。

### 信任边界

sudo 白名单只约束**命令名**，约束不了**命令内部的行为**。

一旦放行 `python3`、`node`、`bash`、`perl` 中的任何一个，AI 就等价于拿到 root shell，白名单形同虚设。所以：

- `minimal` 档刻意不给任何解释器
- `dev` / `ops` 只该发给可信的 AI

**但 `minimal` 也不是只读沙箱。** 它放行的 `chmod`、`chown`、`cp`、`mv`、`mkdir`、`tee`、`sed`、`awk`、`find`、`tar`、`rsync` 都以 root 运行且能触达任意路径：`sudo chmod 777 /etc/shadow`、`sudo tee /etc/...`、`sudo find / -exec ...`、`sudo tar --to-command ...` 都是**不需要任何解释器**的提权路径。所以 `minimal` 的实际语义是「root 级文件访问」，只有 `none` 才是真的只碰授权目录。要限制到目录级，用容器方案（aidocker）。

这个脚本解决的是**省事 + 防手滑 + 到期回收**，不是对抗性沙箱。

---

## 到期回收机制

两套机制叠加，互不依赖：

**精确控制（分钟级）**：创建时把到期 Unix 时间戳写进元数据，回收器每分钟扫描一次。到期即执行：踢掉在线会话 → `usermod -L` → `chage -E 0` → 清空 `authorized_keys` → 移除 sudo / sshd / limits 配置 → 回收 ACL。默认保留家目录，状态置 `expired`；把 `PURGE_ON_EXPIRE` 设为 `yes` 则归档后连账号一起删。

**粗粒度兜底（天级）**：`chage -E` 设置为到期日的**次日**。之所以不设成当天，是因为 `chage` 只有日期粒度——对 12 小时的账号，设成当天会提前最多 23 小时把人踢掉。次日生效意味着即使回收器停摆，账号也会在一天内失效。

回收器载体：有 systemd 时用 `aiuser-reaper.timer`（`OnBootSec=45s`，`OnUnitActiveSec=60s`）；否则写 `/etc/cron.d/aiuser` 每分钟执行 `aiuser cleanup --quiet`。

---

## 文件布局

安装后产生：

| 路径 | 内容 |
|---|---|
| `/usr/local/sbin/aiuser` | 主程序 |
| `/usr/local/sbin/aiuser-rm` | 删除护栏 |
| `/etc/aiuser/config` | 全局默认配置 |
| `/etc/sudoers.d/aiuser-<name>` | sudo 策略片段，权限 `440` |
| `/etc/ssh/sshd_config` | 末尾追加的受管 `Match User` 块（SSH 收敛），以 `# >>> aiuser:<name> >>>` 标记 |
| `/etc/security/limits.d/aiuser-<name>.conf` | 资源上限 |
| `/etc/systemd/system/aiuser-reaper.{service,timer}` | 回收器 |
| `/etc/logrotate.d/aiuser` | 日志轮转 |
| `/var/lib/aiuser/users/<name>.meta` | 账号元数据，权限 `600` |
| `/var/lib/aiuser/archive/` | 吊销时的家目录归档 |
| `/var/lib/aiuser/.lock` | 并发锁 |
| `/var/log/aiuser/audit.log` | 管理操作审计 |
| `/var/log/aiuser/sudo-<name>.log` | 该账号的 sudo 调用记录 |
| `/var/log/aiuser/rm.log` | `aiuser-rm` 的放行与拒绝记录 |

SSH 收敛内容：关闭 TCP 转发、X11 转发、隧道、agent 转发，禁止空密码，`MaxSessions 8`。

这些指令写成 `Match User` 块，**追加在 `/etc/ssh/sshd_config` 末尾**，并以 `# >>> aiuser:<name> >>>` / `# <<< aiuser:<name> <<<` 标记包裹，吊销时按标记整块移除。每次写入后都会跑 `sshd -t`，校验失败即回滚，不会改坏主配置。改完记得 `systemctl reload sshd`（脚本不自动重载，避免打断在线会话）。

> 位置说明：实测（Debian 12 / OpenSSH 9.2）放进 `/etc/ssh/sshd_config.d/*.conf` 也能正常工作，Match 作用域在 Include 文件结束时会重置。追加到主配置末尾是为了不依赖该版本行为，代价是要直接改主配置。

账号 `.bashrc` 尾部会注入一段带标记的配置：命令历史带时间戳、`umask 077`、每条命令通过 `logger -t ai-audit` 落到 `authpriv.notice`、`rm` 别名指向 `aiuser-rm`。

---

## 全局配置

编辑 `/etc/aiuser/config`，保存即生效：

```bash
DEFAULT_DURATION="24h"          # 默认存活时长
DEFAULT_PROFILE="minimal"       # 默认 sudo 档位
DEFAULT_WORKROOT="/srv/aiwork"  # 默认工作目录根
DEFAULT_SHELL="/bin/bash"
PURGE_ON_EXPIRE="no"            # yes = 到期归档后删除账号
KILL_ON_EXPIRE="yes"            # yes = 到期立即切断在线会话
REAPER_INTERVAL_SEC=60          # 回收器扫描间隔（秒）
```

---

## 审计与日志

| 日志 | 来源 | 内容 |
|---|---|---|
| `audit.log` | 脚本自身 | 每次 create / extend / revoke / expire，含操作者与参数 |
| `sudo-<name>.log` | sudo | 该账号执行的每条 sudo 命令 |
| `rm.log` | `aiuser-rm` | 放行的删除目标、被拒绝的目标与原因 |
| syslog `ai-audit` | bash `PROMPT_COMMAND` | 该账号 shell 里敲的每条命令 |

`logrotate` 规则每周轮转，保留 8 份，压缩归档。

---

## 排错

**`chage -l` 显示的到期日比 `--duration` 晚一天**

正常。`chage -E` 是粗粒度兜底，真实到期时间看 `aiuser status` 里的「到期」字段，那才是回收器依据的时间戳。

**账号到期了但还活着**

```bash
sudo aiuser check
```

看回收器那一节是否报错。手工触发一次：`sudo aiuser cleanup`。

**`sudo rm` 被拒了**

设计如此。裸 `rm` 不在任何白名单里，改用 `sudo aiuser-rm <路径>`。

**`aiuser-rm` 拒绝删除 `/tmp` 下的文件**

该文件属主既不是调用者也不是 root。属主校验就是为了堵住「root 无视 sticky bit 删别人文件」这个越权面。

**`--quota` 没生效**

需要文件系统开启 user quota。日志会提示「根文件系统未启用 user quota」，此时配额被静默跳过，其余功能不受影响。XFS 可以用 project quota 替代。

**`setfacl` 找不到 —— 目录授权没生效**

```bash
apt install -y acl        # Debian / Ubuntu
dnf install -y acl        # RHEL / Fedora
```

缺少时 ACL 步骤被跳过并告警，**账号会照常创建，但目录权限一点没给**——AI 登录后访问工作目录会 Permission denied。装完包补授权：

```bash
sudo aiuser fixacl ai
```

`check` 子命令会把缺 `setfacl` 标为错误。

**输出里的「可读 无」是什么意思**

那是 `--ro`（只读目录）清单，没指定就是「无」，属于正常。读写权限看上一行「工作目录」。只有用 `create --ro /opt/src` 这类写法时，这里才会列出内容。

**忘记密码 / 需要重置**

当前版本没有 `reset` 子命令，手工处理：

```bash
sudo chpasswd <<< "ai_dev:新密码"
```

**`create` 报「系统已存在同名用户」**

该用户不是本工具建的。先人工确认用途再决定是否处理，脚本不会碰非受管账号。

**并发冲突**

`create` / `extend` / `revoke` 走 `flock` 加锁，同时执行会提示「另一个实例正在运行」。

---

## 卸载

```bash
sudo aiuser uninstall          # 卸回收器与护栏，保留账号
sudo aiuser uninstall --all    # 连同所有受管账号一起吊销
```

之后可手工清理残留：

```bash
sudo rm -rf /var/lib/aiuser /etc/aiuser /var/log/aiuser /usr/local/sbin/aiuser
```

---

## 限制与替代方案

| 需求 | 本脚本 | 替代方案 |
|---|---|---|
| 读隔离 | 不做，ACL 没有拒绝语义 | 容器 / `systemd-nspawn` / `bwrap` |
| 对抗性沙箱 | 不做，解释器即可逃逸 | gVisor / Firecracker / VM |
| 内核级调用过滤 | 不做 | seccomp / AppArmor / SELinux |
| 系统调用审计 | 只记命令 | auditd 规则 |
| 多机统一管理 | 不做 | 配置管理平台 |

本脚本定位是**单机上的临时账号生命周期管理**：省事、防手滑、到期必回收。需要硬隔离时，把它当作容器方案的补充，而不是替代。

---

## 依赖

必需：`coreutils`、`shadow`（`useradd`/`chage`）、`sudo`。

推荐：`acl`（目录限制，缺了功能不完整）、`openssh-server`（SSH 收敛）、`systemd`（精确回收器；无则退回 cron）、`quota`（磁盘配额，可选）。

平台：Linux。`bash -n` 语法校验通过，脚本内已做 `set -Eeuo pipefail` 与 `shellcheck` 风格的引号处理。
