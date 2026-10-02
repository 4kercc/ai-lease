#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  aiuser.sh — AI 临时账号生命周期管理器（单文件 / root 运行）
# =============================================================================
#  给 AI、爬虫、CI、外包、临时运维开一个「限时 + 限权 + 限目录」的账号：
#    1. 一条命令加账号，密码或 SSH 公钥随你
#    2. 存活时长到期自动禁用（精确到分钟），并断掉在线会话
#    3. 用 POSIX ACL 把可访问目录收进白名单，撤销时自动清理
#    4. sudo 白名单 + 危险命令黑名单，裸 rm 一律不给，删除走 aiuser-rm 护栏
#    5. 附带：配额、资源上限、SSH 收敛、审计日志、归档、一键吊销、环境自检
#
#  目标平台：Linux（systemd 或 cron）
#  依赖：coreutils、shadow、acl、sudo；openssh-server / quota / systemd 可选
#
#  快速开始
#    sudo ./aiuser.sh install
#    sudo ./aiuser.sh create --name ai_demo --duration 12h --gen-password
#    sudo ./aiuser.sh create --name ai_dev --duration 7d \
#         --pubkey-file ~/id_ed25519.pub --ssh-from 10.0.0.0/8 \
#         --rw /srv/project --ro /opt/src --sudo-profile dev --quota 20G
#    sudo ./aiuser.sh list
#    sudo ./aiuser.sh extend ai_dev 24h
#    sudo ./aiuser.sh revoke ai_dev --purge
#
#  子命令
#    install    安装到 /usr/local/sbin + 自动到期回收器（timer/cron）
#    uninstall  卸载回收器与配置（--all 连同受管账号一起清）
#    create     创建临时账号
#    list       列出受管账号与剩余时间
#    status     查看单个账号详情
#    extend     延长存活时长
#    revoke     立即吊销（锁定 + 断会话 + 清密钥 + 清 ACL）
#    cleanup    扫描并禁用过期账号（回收器定时调用）
#    check      环境自检（依赖、权限泄露、回收器状态）
#
#  ⚠ 信任边界（必读）
#    sudo 白名单只能约束「命令」，约束不了「命令内部的行为」。
#    一旦放行 python3 / node / bash / perl，AI 就等价于拿到 root shell。
#    因此：--sudo-profile minimal 不给任何解释器；dev / ops 才给，
#    且只应发给可信任的 AI。要真正隔离请用容器 / VM / systemd-nspawn，
#    本脚本解决的是「省事 + 防手滑 + 到期回收」，不是对抗性沙箱。
# =============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------ 常量/路径
VERSION="1.2.0"
SELF_DEST="/usr/local/sbin/aiuser"
AIRM_DEST="/usr/local/sbin/aiuser-rm"
CONF_DIR="/etc/aiuser"
CONF_FILE="$CONF_DIR/config"
LIB_DIR="/var/lib/aiuser"
USERS_DIR="$LIB_DIR/users"
ARCHIVE_DIR="$LIB_DIR/archive"
LOG_DIR="/var/log/aiuser"
AUDIT_LOG="$LOG_DIR/audit.log"
LOCK_FILE="$LIB_DIR/.lock"

SSHD_MAIN="/etc/ssh/sshd_config"
REAPER_SVC="/etc/systemd/system/aiuser-reaper.service"
REAPER_TIMER="/etc/systemd/system/aiuser-reaper.timer"
REAPER_CRON="/etc/cron.d/aiuser"
LOGROTATE_CONF="/etc/logrotate.d/aiuser"

# ------------------------------------------------------------------- 可调默认
DEFAULT_DURATION="24h"
DEFAULT_PROFILE="minimal"          # minimal | dev | ops | none
DEFAULT_WORKROOT="/srv/aiwork"
DEFAULT_SHELL="/bin/bash"
PURGE_ON_EXPIRE="no"               # yes = 到期归档后删除账号
KILL_ON_EXPIRE="yes"               # yes = 到期立即踢掉在线会话
REAPER_INTERVAL_SEC=60
[ -r "$CONF_FILE" ] && . "$CONF_FILE" || true

# --------------------------------------------------------------------- 运行时
DRY_RUN="no"
QUIET="no"
COLOR="no"
[[ -t 1 ]] && COLOR="yes"

if [[ $COLOR == yes ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_B=$'\033[36m'; C_D=$'\033[2m';  C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

log()  { [[ $QUIET == yes ]] && return 0; printf '%s\n' "$*"; }
info() { [[ $QUIET == yes ]] && return 0; printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { [[ $QUIET == yes ]] && return 0; printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

audit() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s | actor=%s | %s\n' "$(date -Is)" "${SUDO_USER:-root}" "$*" \
    >>"$AUDIT_LOG" 2>/dev/null || true
}

# 破坏性操作统一走这里，受 --dry-run 控制
run() {
  if [[ $DRY_RUN == yes ]]; then
    printf '  %s[dry-run]%s %s\n' "$C_D" "$C_0" "$*"
    return 0
  fi
  "$@"
}

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 运行（sudo $0 $*）"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  mkdir -p "$LIB_DIR" "$USERS_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$CONF_DIR"
  chmod 700 "$LIB_DIR" "$USERS_DIR"
  chmod 750 "$LOG_DIR"
}

# ------------------------------------------------------------------ 时长解析
# 支持：30s / 15m / 12h / 7d / 2w / 1h30m / 纯秒数
parse_duration() {
  local s="$1" total=0 num unit mult rest
  [[ -z $s ]] && die "时长不能为空"
  if [[ $s =~ ^[0-9]+$ ]]; then
    (( s > 0 )) || die "时长必须大于 0（示例：30m 12h 7d 2w 1h30m）"
    printf '%s' "$s"; return 0
  fi
  rest="$s"
  while [[ -n $rest ]]; do
    if [[ $rest =~ ^([0-9]+)([smhdw])(.*)$ ]]; then
      num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    else
      die "非法时长格式：$s（示例：30m 12h 7d 2w 1h30m）"
    fi
    case "$unit" in
      s) mult=1 ;;
      m) mult=60 ;;
      h) mult=3600 ;;
      d) mult=86400 ;;
      w) mult=604800 ;;
    esac
    total=$(( total + num * mult ))
  done
  (( total > 0 )) || die "时长必须大于 0"
  printf '%s' "$total"
}

# 判断字符串是否时长写法（2h / 1h30m / 45）
is_duration() {
  local s="$1"
  [[ $s =~ ^([0-9]+[smhdw])+$ ]] || [[ $s =~ ^[0-9]+$ ]]
}

human_duration() {
  local s="$1" d h m
  (( s < 0 )) && { printf '已过期'; return 0; }
  d=$(( s / 86400 )); s=$(( s % 86400 ))
  h=$(( s / 3600 ));  s=$(( s % 3600 ))
  m=$(( s / 60 ))
  if   (( d > 0 )); then printf '%dd%dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
  else                   printf '%dm' "$m"
  fi
}

# ------------------------------------------------------------------ meta 读写
meta_file()  { printf '%s/%s.meta' "$USERS_DIR" "$1"; }
meta_exists(){ [[ -f "$(meta_file "$1")" ]]; }
# 空文件 / 残缺文件不算「在管理中」：
# 否则 meta_save 中途崩溃留下空文件后，账号会被永久卡住无法重建
is_managed() {
  local f; f="$(meta_file "$1")"
  [[ -s $f ]] && grep -q '^NAME=' "$f" 2>/dev/null
}

meta_load() {
  local name="$1" f
  f="$(meta_file "$name")"
  [[ -r $f ]] || die "账号 $name 不在管理范围内（找不到 $f）"
  # shellcheck disable=SC1090
  . "$f"
  [[ -n ${HOME_DIR:-} && -n ${WORKDIR:-} ]] \
    || die "元数据损坏或为空：$f
    若该账号已不存在，删掉这个文件即可：rm -f $f"
  # 同步进 meta_save 使用的 M_* 命名空间：
  # 这样只改一个字段（如 STATUS）也能安全回写整份元数据
  M_NAME="${NAME:-$name}"
  M_CREATED="${CREATED:-0}"
  M_EXPIRES="${EXPIRES:-0}"
  M_DURATION="${DURATION:-0}"
  M_HOME="${HOME_DIR:-/home/$name}"
  M_WORKDIR="${WORKDIR:-}"
  M_RW="${RW_LIST:-}"
  M_RO="${RO_LIST:-}"
  M_PROFILE="${SUDO_PROFILE:-minimal}"
  M_SSHFROM="${SSH_FROM:-}"
  M_SHELL="${SHELL_BIN:-/bin/bash}"
  M_STATUS="${STATUS:-active}"
}

meta_save() {
  local name="$1" f tmp old_umask
  f="$(meta_file "$name")"
  tmp="$f.tmp.$$"
  old_umask="$(umask)"
  umask 077
  cat >"$tmp" <<EOF
NAME='${M_NAME:-$name}'
CREATED='${M_CREATED:-0}'
EXPIRES='${M_EXPIRES:-0}'
DURATION='${M_DURATION:-0}'
HOME_DIR='${M_HOME:-/home/$name}'
WORKDIR='${M_WORKDIR:-}'
RW_LIST='${M_RW:-}'
RO_LIST='${M_RO:-}'
SUDO_PROFILE='${M_PROFILE:-minimal}'
SSH_FROM='${M_SSHFROM:-}'
SHELL_BIN='${M_SHELL:-/bin/bash}'
STATUS='${M_STATUS:-active}'
EOF
  umask "$old_umask"
  chmod 600 "$tmp"
  # 原子替换：写一半崩掉也不会把原元数据截成空文件
  mv -f "$tmp" "$f"
}

user_exists() { id -u "$1" >/dev/null 2>&1; }

# 系统目录本体不得直接授权（子目录如 /etc/nginx/conf.d 允许）
SYSTEM_ROOTS=(/ /bin /boot /dev /etc /lib /lib32 /lib64 /proc /root /run /sbin /sys /usr /var)
check_grant_path() {
  local p="$1" r rp
  rp="$(readlink -m -- "$p" 2>/dev/null || printf '%s' "$p")"
  for r in "${SYSTEM_ROOTS[@]}"; do
    [[ $rp == "$r" ]] && die "拒绝把系统目录本体授权给临时账号：$rp（要授权请给具体子目录）"
  done
  [[ $rp == /home ]] && die "拒绝把 /home 整体授权（会横跨其他用户）"
  return 0
}

# ------------------------------------------------------------------- ACL 处理
apply_acl() {
  local u="$1" path="$2" mode="$3"   # mode: rw | ro
  [[ -e $path ]] || { warn "路径不存在，跳过 ACL：$path"; return 0; }
  if ! need_cmd setfacl; then
    warn "缺少 setfacl，$path 的 ACL 未设置（装包后执行 fixacl 补授权）"
    return 0
  fi
  local perm="rX"
  [[ $mode == rw ]] && perm="rwX"
  run setfacl -R -m "u:$u:$perm" "$path" \
    || warn "设置 ACL 失败：$path（$u 可能仍无法访问，装好 acl 包后跑 fixacl 补授权）"
  # 默认 ACL 只有目录能继承，对文件用 -d 会被 setfacl 拒绝
  if [[ -d $path ]]; then
    run setfacl -R -d -m "u:$u:$perm" "$path" \
      || warn "设置默认 ACL 失败：$path"
  fi
  ok "ACL $mode -> $path"
}

clear_acl() {
  local u="$1" path="$2"
  [[ -e $path ]] || return 0
  need_cmd setfacl || return 0
  run setfacl -R -x "u:$u" "$path" 2>/dev/null || true
  run setfacl -R -d -x "u:$u" "$path" 2>/dev/null || true
}

# ------------------------------------------------------------------ sudo 策略
# 生成 sudoers 片段：白名单 + 黑名单（! 取反，最后匹配生效）
gen_sudoers() {
  local u="$1" profile="$2"
  local f="/etc/sudoers.d/aiuser-$u"
  local U; U="${u^^}"; U="${U//[^A-Z0-9_]/_}"     # alias 名只允许大写/数字/下划线

  if [[ $DRY_RUN == yes ]]; then
    printf '  %s[dry-run]%s 生成 sudo 策略 [%s] -> %s\n' "$C_D" "$C_0" "$profile" "$f"
    return 0
  fi

  if [[ $profile == none ]]; then
    run rm -f "$f"
    info "sudo-profile=none，未授予任何 sudo 权限"
    return 0
  fi

  local allow_min allow_dev allow_ops
  allow_min="/usr/bin/apt, /usr/bin/apt-get, /usr/bin/dpkg, \\
    /usr/bin/yum, /usr/bin/dnf, /usr/bin/rpm, /usr/bin/zypper, \\
    /usr/bin/systemctl, /bin/systemctl, /usr/bin/journalctl, /bin/journalctl, \\
    /usr/bin/chmod, /bin/chmod, /usr/bin/chown, /bin/chown, /usr/bin/chgrp, /bin/chgrp, \\
    /usr/bin/mkdir, /bin/mkdir, /usr/bin/cp, /bin/cp, /usr/bin/mv, /bin/mv, \\
    /usr/bin/ln, /bin/ln, /usr/bin/touch, /usr/bin/stat, \\
    /usr/bin/tar, /bin/tar, /usr/bin/gzip, /usr/bin/gunzip, /usr/bin/zip, /usr/bin/unzip, \\
    /usr/bin/rsync, /usr/bin/curl, /usr/bin/wget, /usr/bin/scp, \\
    /usr/bin/tee, /usr/bin/sed, /usr/bin/awk, /usr/bin/grep, /usr/bin/find, /usr/bin/sort, \\
    $AIRM_DEST"

  allow_dev="/usr/bin/git, /usr/bin/python3, /usr/bin/pip3, /usr/bin/python, \\
    /usr/bin/node, /usr/bin/npm, /usr/bin/pnpm, /usr/bin/yarn, \\
    /usr/bin/docker, /usr/bin/make, /usr/bin/gcc, /usr/bin/g++, /usr/bin/ld, \\
    /usr/bin/vim, /usr/bin/nano, /usr/bin/vi, /usr/bin/less, /usr/bin/file, \\
    /usr/bin/tree, /usr/bin/diff, /usr/bin/patch, /usr/bin/jq, /usr/bin/ssh, \\
    /usr/bin/systemd-run, /usr/bin/env, /usr/bin/xargs, /usr/bin/bash"

  allow_ops="/usr/bin/kill, /bin/kill, /usr/bin/pkill, /usr/bin/nice, /usr/bin/ionice, \\
    /usr/bin/systemd-analyze, /usr/sbin/service, /usr/sbin/ss, /usr/bin/netstat, \\
    /usr/sbin/ip, /usr/bin/lsof, /usr/bin/top, /usr/bin/ps, /usr/bin/free, /usr/bin/df, \\
    /usr/bin/mountpoint, /usr/bin/systemd-cgls, /usr/bin/loginctl, /usr/bin/last"

  local ALLOW="$allow_min"
  [[ $profile == dev || $profile == ops ]] && ALLOW="$ALLOW, $allow_dev"
  [[ $profile == ops ]] && ALLOW="$ALLOW, $allow_ops"

  # 高危：裸 rm / 磁盘操作 / 关机重启 / 内核模块 / 提权面
  local DENY
  DENY="/usr/bin/rm, /bin/rm, /usr/bin/unlink, /usr/bin/shred, \\
    /usr/bin/dd, /bin/dd, /usr/sbin/mkfs, /sbin/mkfs, /usr/sbin/mkfs.*, /sbin/mkfs.*, \\
    /usr/sbin/fdisk, /sbin/fdisk, /usr/sbin/parted, /sbin/parted, /usr/sbin/sfdisk, \\
    /usr/sbin/wipefs, /usr/sbin/blkdiscard, /usr/bin/fallocate, \\
    /usr/sbin/reboot, /sbin/reboot, /usr/sbin/shutdown, /sbin/shutdown, \\
    /usr/sbin/halt, /sbin/halt, /usr/sbin/poweroff, /sbin/poweroff, /usr/bin/init, /sbin/init, \\
    /usr/sbin/insmod, /usr/sbin/rmmod, /usr/sbin/modprobe, /usr/bin/kexec, \\
    /usr/bin/chroot, /usr/sbin/chroot, /usr/sbin/visudo, /usr/bin/visudo, \\
    /usr/bin/passwd, /usr/bin/chpasswd, /usr/sbin/useradd, /usr/sbin/userdel, /usr/sbin/usermod, \\
    /usr/bin/su, /bin/su, /usr/bin/mount, /bin/mount, /usr/bin/umount, /bin/umount, \\
    /usr/bin/crontab, /usr/bin/at, /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff, \\
    /usr/bin/systemctl halt, /bin/systemctl reboot, /bin/systemctl poweroff, \\
    /usr/bin/chmod -R 777 /, /usr/bin/chmod -R 777 /*, /bin/chmod -R 777 /, \\
    /usr/bin/chown -R root /, /usr/bin/rm -rf /, /usr/bin/rm -rf /*"

  {
    echo "# 由 aiuser.sh $VERSION 生成于 $(date -Is) —— 请勿手改，改动请重跑 create/extend"
    echo "Defaults:$u !requiretty"
    echo "Defaults:$u env_reset"
    echo "Defaults:$u secure_path=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""
    echo "Defaults:$u logfile=\"$LOG_DIR/sudo-$u.log\""
    echo ""
    echo "Cmnd_Alias AI_DENY_${U} = $DENY"
    echo ""
    echo "Cmnd_Alias AI_ALLOW_${U} = $ALLOW"
    echo ""
    echo "# 白名单在前、黑名单在后：sudoers 以最后匹配的规则为准"
    echo "$u ALL=(root) AI_ALLOW_${U}, !AI_DENY_${U}"
  } >"$f"

  chmod 440 "$f"
  if need_cmd visudo; then
    visudo -cf "$f" >/dev/null 2>&1 || {
      rm -f "$f"
      die "sudoers 片段语法校验失败，已回滚：$f"
    }
  fi
  ok "sudo 策略 [$profile] -> $f"
}

# --------------------------------------------------------------- aiuser-rm 护栏
# 独立 wrapper：路径白名单模型，只有「授权目录 + /tmp + 自家 home」可删
emit_ai_rm() {
  run mkdir -p "$(dirname "$AIRM_DEST")"
  if [[ $DRY_RUN == yes ]]; then
    printf '  %s[dry-run]%s 写入 %s\n' "$C_D" "$C_0" "$AIRM_DEST"
    return 0
  fi
  cat >"$AIRM_DEST" <<'AIRM_EOF'
#!/usr/bin/env bash
# aiuser-rm — 受控删除。由 aiuser.sh 生成，请勿手改。
# 只允许删除：自家 home、授权工作目录、/tmp、/var/tmp。
# 其余路径一律拒绝（白名单模型），并记录审计。
set -Eeuo pipefail

META_DIR="/var/lib/aiuser/users"
RM_LOG="/var/log/aiuser/rm.log"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "aiuser-rm: 请通过 sudo 调用" >&2; exit 1; }

ACTOR="${SUDO_USER:-}"
if [[ -z $ACTOR ]]; then
  echo "aiuser-rm: 无法识别调用者（需经 sudo 调用）" >&2
  exit 1
fi

META="$META_DIR/$ACTOR.meta"
if [[ ! -r $META ]]; then
  echo "aiuser-rm: $ACTOR 不是受管账号，拒绝执行" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$META"

log_rm() {
  mkdir -p "$(dirname "$RM_LOG")" 2>/dev/null || true
  printf '%s | user=%s | rc=%s | %s\n' "$(date -Is)" "$ACTOR" "$1" "$2" >>"$RM_LOG" 2>/dev/null || true
}

# 允许根：home、工作目录、显式授权的读写目录、临时区
ALLOW_ROOTS=()
[[ -n ${HOME_DIR:-} ]] && ALLOW_ROOTS+=("$HOME_DIR")
[[ -n ${WORKDIR:-}  ]] && ALLOW_ROOTS+=("$WORKDIR")
if [[ -n ${RW_LIST:-} ]]; then
  read -r -a _rw <<<"$RW_LIST"
  ALLOW_ROOTS+=("${_rw[@]}")
fi
ALLOW_ROOTS+=(/tmp /var/tmp)

# 系统保护根：即使出现在参数里也直接拒
PROTECT_ROOTS=(
  / /bin /boot /dev /etc /lib /lib32 /lib64 /proc /root /run /sbin /srv /sys /usr /var
)

norm() { readlink -m -- "$1" 2>/dev/null || printf '%s' "$1"; }

TMP_ROOTS=(/tmp /var/tmp)
in_tmp() {
  local p="$1" r
  for r in "${TMP_ROOTS[@]}"; do is_under "$p" "$r" && return 0; done
  return 1
}

is_under() {  # $1=路径 $2=根  —— 相等或以 根/ 开头
  local p="$1" r="$2"
  [[ $r == / ]] && return 0
  [[ $p == "$r" || $p == "$r"/* ]]
}

verdict() {
  local p="$1" root rp
  rp="$(norm "$p")"
  # 1) 显式授权目录优先放行
  for root in "${ALLOW_ROOTS[@]}"; do
    [[ -z $root ]] && continue
    if is_under "$rp" "$root"; then
      # 但不得借授权目录跳到系统区（如 /tmp/../etc 已由 norm 展开，这里再兜一层）
      return 0
    fi
  done
  # 2) 命中系统保护根 -> 拒绝
  for root in "${PROTECT_ROOTS[@]}"; do
    if is_under "$rp" "$root"; then
      echo "deny:$rp"
      return 1
    fi
  done
  # 3) 白名单模型：未授权的一律拒绝
  echo "deny:$rp"
  return 1
}

# ---- 参数解析：分离选项与目标 ----
OPTS=(); TARGETS=(); SEEN_DD=0; NO_PRESERVE=0; DRY=0
for a in "$@"; do
  if (( SEEN_DD )); then TARGETS+=("$a"); continue; fi
  case "$a" in
    --) SEEN_DD=1 ;;
    --no-preserve-root) NO_PRESERVE=1; OPTS+=("$a") ;;
    -n|--dry-run) DRY=1 ;;
    -*) OPTS+=("$a") ;;
    *)  TARGETS+=("$a") ;;
  esac
done

(( ${#TARGETS[@]} )) || { echo "aiuser-rm: 未指定目标" >&2; exit 1; }

for t in "${TARGETS[@]}"; do
  if (( NO_PRESERVE )) && { [[ $t == / ]] || [[ $t == /* && $(norm "$t") == / ]]; }; then
    echo "aiuser-rm: 拒绝 --no-preserve-root 作用于根目录" >&2
    log_rm 1 "blocked-no-preserve-root $t"
    exit 1
  fi
  if ! verdict "$t" >/dev/null; then
    echo "aiuser-rm: 拒绝删除未授权路径：$t" >&2
    echo "aiuser-rm: 允许范围 -> ${ALLOW_ROOTS[*]}" >&2
    log_rm 1 "blocked $t"
    exit 1
  fi
  # 临时区越权保护：aiuser-rm 以 root 运行，内核 sticky bit 不生效，这里补上
  rp="$(norm "$t")"
  if in_tmp "$rp" && [[ -e $rp ]]; then
    own="$(stat -c '%U' "$rp" 2>/dev/null || echo '?')"
    if [[ $own != "$ACTOR" && $own != root ]]; then
      echo "aiuser-rm: 拒绝删除临时区中属于 $own 的文件：$t" >&2
      log_rm 1 "blocked-foreign-owner $t"
      exit 1
    fi
  fi
done

if (( DRY )); then
  echo "aiuser-rm: [dry-run] 将删除 ${#TARGETS[@]} 个目标：${TARGETS[*]}"
  log_rm 0 "dry-run ${TARGETS[*]}"
  exit 0
fi

log_rm 0 "allow ${TARGETS[*]}"
exec /bin/rm "${OPTS[@]+"${OPTS[@]}"}" -- "${TARGETS[@]}"
AIRM_EOF
  chmod 755 "$AIRM_DEST"
  ok "护栏已安装 -> $AIRM_DEST"
}

# ------------------------------------------------------------- sshd / limits
# SSH 收敛必须把 Match 块放在 sshd_config 的末尾。
# 放进 /etc/ssh/sshd_config.d/*.conf 是错的：Debian/Ubuntu/RHEL 的
# `Include /etc/ssh/sshd_config.d/*.conf` 位于 sshd_config 顶部，而 Match 的
# 生效范围会一路延续到文件结尾（Include 与主文件共用同一个 active 状态），
# 于是主配置里 UsePAM / Subsystem / PrintMotd 等指令被判定为「Match 块内不允许」，
# sshd -t 直接失败——旧实现只会静默回滚，SSH 收敛从未真正生效。
sshd_block_begin() { printf '# >>> aiuser:%s >>>' "$1"; }
sshd_block_end()   { printf '# <<< aiuser:%s <<<' "$1"; }

# 从 stdin 读入 sshd_config，剔除指定账号的受管块后写到 stdout
strip_sshd_block() {
  local u="$1"
  awk -v b="$(sshd_block_begin "$u")" -v e="$(sshd_block_end "$u")" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip!=1 {print}
  '
}

# 去掉尾部空行，避免反复 create/revoke 在 sshd_config 里堆积空行
trim_trailing_blanks() {
  awk '{l[NR]=$0} END{n=NR; while(n>0 && l[n]=="") n--; for(i=1;i<=n;i++) print l[i]}'
}

remove_sshd_block() {
  local u="$1"
  [[ -f $SSHD_MAIN ]] || return 0
  grep -qF "$(sshd_block_begin "$u")" "$SSHD_MAIN" 2>/dev/null || return 0
  if [[ $DRY_RUN == yes ]]; then
    printf '  %s[dry-run]%s 移除 SSH 收敛块 -> %s\n' "$C_D" "$C_0" "$SSHD_MAIN"
    return 0
  fi
  local tmp="$SSHD_MAIN.aiuser.$$" cur="$SSHD_MAIN.aiuser.bak.$$"
  cp -f "$SSHD_MAIN" "$cur" || return 0
  strip_sshd_block "$u" <"$cur" | trim_trailing_blanks >"$tmp"
  cp -f "$tmp" "$SSHD_MAIN"
  if need_cmd sshd && ! sshd -t 2>/dev/null; then
    cp -f "$cur" "$SSHD_MAIN"
    warn "移除 SSH 收敛块后 sshd 校验失败，已回滚"
  fi
  rm -f "$tmp" "$cur"
}

gen_sshd() {
  local u="$1"
  [[ -f $SSHD_MAIN ]] || { info "找不到 $SSHD_MAIN，跳过 SSH 收敛"; return 0; }
  # 旧版本写的 drop-in 会破坏 sshd，顺手清掉
  run rm -f "/etc/ssh/sshd_config.d/aiuser-$u.conf"
  if [[ $DRY_RUN == yes ]]; then
    printf '  %s[dry-run]%s 写入 SSH 收敛 -> %s 末尾\n' "$C_D" "$C_0" "$SSHD_MAIN"
    return 0
  fi
  # 没有 sshd 就无法校验；宁可不收敛，也不改坏主配置
  if ! need_cmd sshd; then
    warn "未找到 sshd，无法校验配置，跳过 SSH 收敛（不冒险改 $SSHD_MAIN）"
    return 0
  fi
  local tmp="$SSHD_MAIN.aiuser.$$" cur="$SSHD_MAIN.aiuser.bak.$$"
  cp -f "$SSHD_MAIN" "$cur" || { warn "无法读取 $SSHD_MAIN，跳过 SSH 收敛"; return 0; }
  {
    strip_sshd_block "$u" <"$cur" | trim_trailing_blanks
    printf '\n%s\n' "$(sshd_block_begin "$u")"
    printf '# 由 aiuser.sh %s 生成于 %s —— 请勿手改，改动请重跑 create/revoke\n' "$VERSION" "$(date -Is)"
    printf 'Match User %s\n' "$u"
    printf '    AllowTcpForwarding no\n'
    printf '    X11Forwarding no\n'
    printf '    PermitTunnel no\n'
    printf '    AllowAgentForwarding no\n'
    printf '    PermitEmptyPasswords no\n'
    printf '    MaxSessions 8\n'
    printf '%s\n' "$(sshd_block_end "$u")"
  } >"$tmp"
  cp -f "$tmp" "$SSHD_MAIN"
  if ! sshd -t 2>/dev/null; then
    cp -f "$cur" "$SSHD_MAIN"
    rm -f "$tmp" "$cur"
    warn "sshd 配置校验失败，已回滚 SSH 收敛（$SSHD_MAIN 未改动）"
    return 0
  fi
  rm -f "$tmp" "$cur"
  ok "SSH 收敛 -> $SSHD_MAIN 末尾（重载：systemctl reload sshd）"
}

gen_limits() {
  local u="$1"
  local f="/etc/security/limits.d/aiuser-$u.conf"
  if [[ $DRY_RUN == yes ]]; then
    printf '  %s[dry-run]%s 生成资源上限 -> %s\n' "$C_D" "$C_0" "$f"
    return 0
  fi
  [[ -d /etc/security/limits.d ]] || return 0
  cat >"$f" <<EOF
# 由 aiuser.sh 生成
$u  hard  nproc      256
$u  hard  nofile     4096
$u  hard  core       0
$u  hard  maxlogins  4
$u  soft  nproc      128
$u  soft  nofile     2048
EOF
  chmod 644 "$f"
  ok "资源上限 -> $f"
}

apply_quota() {
  local u="$1" spec="${2:-}" num mult=1 kb
  [[ -z $spec ]] && return 0
  need_cmd setquota || { warn "缺少 setquota，跳过磁盘配额"; return 0; }
  if ! quotaon -p / 2>/dev/null | grep -q 'user quota.*on'; then
    warn "根文件系统未启用 user quota，跳过配额设置（可用 XFS project quota 替代）"
    return 0
  fi
  case "$spec" in
    *[Kk]) num="${spec%[Kk]}" ;;
    *[Mm]) num="${spec%[Mm]}"; mult=1024 ;;
    *[Gg]) num="${spec%[Gg]}"; mult=1048576 ;;
    *[Tt]) num="${spec%[Tt]}"; mult=1073741824 ;;
    *) warn "配额格式无法识别：$spec（示例 20G）"; return 0 ;;
  esac
  [[ $num =~ ^[0-9]+$ ]] || { warn "配额数值非法：$spec"; return 0; }
  kb=$(( 10#$num * mult ))
  run setquota -u "$u" 0 "$kb" 0 "$(( kb * 11 / 10 ))" /
  ok "磁盘配额 -> $spec"
}

# --------------------------------------------------------------- 用户级收敛
inject_bashrc() {
  local u="$1" home="$2"
  local rc="$home/.bashrc"
  [[ $DRY_RUN == yes ]] && { printf '  %s[dry-run]%s 注入 %s\n' "$C_D" "$C_0" "$rc"; return 0; }
  touch "$rc"
  if grep -q 'AIUSER-BEGIN' "$rc" 2>/dev/null; then return 0; fi
  cat >>"$rc" <<'RC_EOF'

# >>> AIUSER-BEGIN >>>
export HISTTIMEFORMAT='%F %T '
export HISTSIZE=20000
export HISTFILESIZE=20000
umask 077
shopt -s histappend 2>/dev/null || true
# 把每条命令落进系统审计（root 可读）
export PROMPT_COMMAND='history -a; logger -t ai-audit -p authpriv.notice -- "cmd: $(history 1 | sed "s/^ *[0-9]* *//")" 2>/dev/null'
# 手滑防线：rm 一律走护栏（非安全边界，安全边界在 sudoers）
alias rm='/usr/local/sbin/aiuser-rm'
alias rmdir='/usr/local/sbin/aiuser-rm -d'
# >>> AIUSER-END >>>
RC_EOF
  chown "$u:$u" "$rc" 2>/dev/null || true
  chmod 600 "$rc"
}

install_pubkey() {
  local u="$1" home="$2" key="$3" from="$4"
  [[ -z $key ]] && return 0
  local line="$key"
  [[ -n $from ]] && line="from=\"$from\" $key"
  run install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
  if [[ $DRY_RUN == no ]]; then
    printf '%s\n' "$line" >"$home/.ssh/authorized_keys"
    chown "$u:$u" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
  fi
  ok "公钥已写入 $home/.ssh/authorized_keys${from:+ (from=$from)}"
}

# --------------------------------------------------------------------- 创建
cmd_create() {
  local name="" duration="$DEFAULT_DURATION" profile="$DEFAULT_PROFILE"
  local pw="" use_stdin=0 genpw=0 force_change=0 pubkey="" pubkey_file=""
  local ssh_from="" shell="$DEFAULT_SHELL" quota="" restricted=0
  local -a rw_list=() ro_list=()
  local workdir=""

  while (( $# )); do
    case "$1" in
      -n|--name)        name="$2"; shift 2 ;;
      --duration|-t)    duration="$2"; shift 2 ;;
      --password|-p)    pw="$2"; shift 2 ;;
      --password-stdin) use_stdin=1; shift ;;
      --gen-password)   genpw=1; shift ;;
      --force-change)   force_change=1; shift ;;
      --pubkey)         pubkey="$2"; shift 2 ;;
      --pubkey-file)    pubkey_file="$2"; shift 2 ;;
      --ssh-from)       ssh_from="$2"; shift 2 ;;
      --sudo-profile)   profile="$2"; shift 2 ;;
      --rw)             rw_list+=("$2"); shift 2 ;;
      --ro)             ro_list+=("$2"); shift 2 ;;
      --workdir)        workdir="$2"; shift 2 ;;
      --quota)          quota="$2"; shift 2 ;;
      --shell)          shell="$2"; shift 2 ;;
      --restricted)     restricted=1; shift ;;
      -h|--help)        usage; exit 0 ;;
      *) die "未知参数：$1（-h 查看用法）" ;;
    esac
  done

  [[ -n $name ]] || die "必须指定 --name"
  [[ $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "用户名非法：只允许小写字母/数字/下划线/短横线，且以字母或下划线开头"
  user_exists "$name" && ! is_managed "$name" && die "系统已存在同名用户 $name（非本工具管理，先人工处理）"
  is_managed "$name" && die "$name 已在管理中，用 extend / revoke / status"

  case "$profile" in minimal|dev|ops|none) ;; *) die "--sudo-profile 只能是 minimal|dev|ops|none" ;; esac

  # 密钥来源
  if [[ -n $pubkey_file ]]; then
    [[ -r $pubkey_file ]] || die "公钥文件不可读：$pubkey_file"
    pubkey="$(head -n1 "$pubkey_file")"
  fi
  if [[ -n $pubkey ]]; then
    [[ $pubkey =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] \
      || die "公钥格式不正确（应以 ssh-ed25519 / ssh-rsa / ecdsa-... 开头）"
  fi

  # 密码来源
  if (( use_stdin )); then
    IFS= read -r pw || die "从 stdin 读取密码失败"
  fi
  if (( genpw )); then
    pw="$(tr -dc 'A-Za-z0-9@#%^_+=!' </dev/urandom | head -c 24 || true)"
  fi
  [[ -z $pubkey && -z $pw ]] && die "至少提供一种凭据：--password / --password-stdin / --gen-password / --pubkey"
  if [[ -n $pw && ${#pw} -lt 8 ]]; then
    warn "密码长度不足 8 位，仍按你要求设置"
  fi

  local secs expires created
  secs="$(parse_duration "$duration")"
  created="$(date +%s)"
  expires=$(( created + secs ))

  local home="/home/$name"
  [[ -n $workdir ]] || workdir="$DEFAULT_WORKROOT/$name"

  # 授权路径体检：挡住「把 /etc 整个交出去」这类误配
  local g
  check_grant_path "$workdir"
  for g in "${rw_list[@]+"${rw_list[@]}"}" "${ro_list[@]+"${ro_list[@]}"}"; do
    check_grant_path "$g"
  done

  info "创建 $name：时长 $(human_duration "$secs")，到期 $(date -d "@$expires" '+%F %T')"

  local shell_bin="$shell"
  (( restricted )) && shell_bin="/bin/rbash"
  [[ -x $shell_bin ]] || shell_bin="/bin/bash"

  run useradd --create-home --home-dir "$home" --shell "$shell_bin" \
      --comment "AI temp account (managed by aiuser)" "$name"
  run usermod -U "$name" 2>/dev/null || true

  # 家目录收紧到 0700：useradd 默认按 UMASK 022 建 755，同机其他用户能进去读
  if [[ $DRY_RUN == no && -d $home ]]; then
    chmod 700 "$home"
  fi

  if [[ -n $pw ]]; then
    if [[ $DRY_RUN == no ]]; then
      printf '%s:%s\n' "$name" "$pw" | chpasswd
      (( force_change )) && chage -d 0 "$name"
    fi
    if (( force_change )); then
      ok "密码已设置（首次登录强制改密）"
    else
      ok "密码已设置"
    fi
  fi

  # 精确到期交给回收器；chage 取次日做粗粒度兜底，避免提前误杀
  run chage -E "$(date -d "@$(( expires + 86400 ))" +%F)" -m 0 -M 99999 -I -1 "$name"

  install_pubkey "$name" "$home" "$pubkey" "$ssh_from"

  # 工作目录：新建时由 root 持有 0700 并只对本账号开 ACL；已存在的目录一律不碰
  if [[ $DRY_RUN == no ]]; then
    if [[ ! -d $workdir ]]; then
      mkdir -p "$workdir"
      chown root:root "$workdir"
      chmod 0700 "$workdir"
    else
      info "工作目录已存在，保留其原有属主与权限：$workdir"
    fi
  fi
  apply_acl "$name" "$workdir" rw
  rw_list+=("$workdir")
  local p
  for p in "${ro_list[@]+"${ro_list[@]}"}"; do apply_acl "$name" "$p" ro; done
  for p in "${rw_list[@]+"${rw_list[@]}"}"; do
    [[ $p == "$workdir" ]] && continue
    apply_acl "$name" "$p" rw
  done

  gen_sudoers "$name" "$profile"
  gen_sshd "$name"
  gen_limits "$name"
  apply_quota "$name" "$quota"
  inject_bashrc "$name" "$home"

  M_NAME="$name"; M_CREATED="$created"; M_EXPIRES="$expires"
  M_DURATION="$secs"; M_HOME="$home"; M_WORKDIR="$workdir"
  M_RW="${rw_list[*]:-}"; M_RO="${ro_list[*]:-}"
  M_PROFILE="$profile"; M_SSHFROM="$ssh_from"; M_SHELL="$shell_bin"; M_STATUS="active"
  run meta_save "$name"

  audit "create name=$name duration=${secs}s expires=$expires profile=$profile workdir=$workdir rw='${M_RW}' ro='${M_RO}'"

  echo
  ok "账号就绪"
  printf '  %s用户名%s   %s\n' "$C_D" "$C_0" "$name"
  [[ -n $pw ]] && printf '  %s密码%s     %s\n' "$C_D" "$C_0" "$pw"
  printf '  %s到期%s     %s（%s 后）\n' "$C_D" "$C_0" "$(date -d "@$expires" '+%F %T')" "$(human_duration "$secs")"
  printf '  %s工作目录%s %s\n' "$C_D" "$C_0" "$workdir"
  printf '  %s可读%s     %s\n' "$C_D" "$C_0" "${ro_list[*]:-无}"
  printf '  %ssudo%s     %s\n' "$C_D" "$C_0" "$profile"
  printf '  %s删除%s     sudo aiuser-rm <路径>\n' "$C_D" "$C_0"
  echo
  [[ -n $pw ]] && warn "密码只显示这一次，请立即转交给使用者"

  if ! need_cmd setfacl; then
    echo
    warn "⚠ 本机缺少 setfacl，目录授权尚未生效：$name 现在访问不了 $workdir"
    warn "  1) 装包   apt install -y acl      （RHEL 系：dnf install -y acl）"
    warn "  2) 补授权 sudo $0 fixacl $name"
  fi
  return 0
}

# ------------------------------------------------ 极简入口：new / add / mk
# 用法：new <用户名> [目录] [时长] [sudo档位]
# 例：  new ai /clicd 2h
cmd_new() {
  local -a p=("$@")
  if (( ${#p[@]} == 0 )) || [[ ${p[0]:-} == -h || ${p[0]:-} == --help ]]; then
    cat <<'EOF'
用法：new <用户名> [目录] [时长] [sudo档位]

  sudo aiuser new ai /clicd 2h
      建 ai 账号 + /clicd 完全读写 + 2 小时有效 + 自动生成密码

  sudo aiuser new ai /clicd 2h dev
      同上，并额外放行 git / python / docker 等开发命令

  sudo aiuser new ai 2h
      不指定目录，默认给 /srv/aiwork/ai

  目录省略 -> /srv/aiwork/<用户名>
  时长省略 -> 24h（支持 30m 2h 12h 7d 2w 1h30m）
  档位省略 -> minimal（装包、改权限、删文件；不放行解释器）
             可选 dev（开发） / ops（运维） / none（无 sudo）
EOF
    return 0
  fi
  (( ${#p[@]} <= 4 )) || die "参数过多。用法：new <用户名> [目录] [时长] [档位]"

  local name="${p[0]}" dir="" dur="" profile=""
  local a
  for a in "${p[@]:1}"; do
    [[ -z $a ]] && continue
    if [[ $a == */* ]]; then                      # 含 / 的一律当目录
      [[ -n $dir ]] && die "指定了多个目录：$dir 与 $a"
      dir="$a"
    elif [[ $a == minimal || $a == dev || $a == ops || $a == none ]]; then
      profile="$a"
    elif is_duration "$a"; then                   # 2h / 90m / 45
      dur="$a"
    elif [[ -z $dir ]]; then                      # 剩下的当目录
      dir="$a"
    else
      die "参数无法识别：$a（用法：new <用户名> [目录] [时长] [档位]）"
    fi
  done
  dur="${dur:-$DEFAULT_DURATION}"
  profile="${profile:-$DEFAULT_PROFILE}"

  local -a args=(--name "$name" --duration "$dur" --gen-password --sudo-profile "$profile")

  if [[ -n $dir ]]; then
    dir="$(readlink -m -- "$dir" 2>/dev/null || printf '%s' "$dir")"
    # 不在这里建目录：交给 cmd_create，让它以 root:root 0700 建好再授权。
    # 在这里 mkdir 会让 cmd_create 走「已存在则保留原权限」分支，0700 加固被跳过。
    args+=(--workdir "$dir")
  fi

  cmd_create "${args[@]}"
}

# ----------------------------------------------------------------- 列表/详情
cmd_list() {
  local f name any=0
  printf '%-20s %-10s %-19s %-19s %-10s %s\n' NAME STATUS CREATED EXPIRES REMAIN SUDO
  printf '%s\n' "--------------------------------------------------------------------------------------------------"
  shopt -s nullglob
  for f in "$USERS_DIR"/*.meta; do
    any=1
    # shellcheck disable=SC1090
    ( . "$f"; printf '%-20s %-10s %-19s %-19s %-10s %s\n' \
        "$NAME" "$STATUS" \
        "$(date -d "@$CREATED" '+%F %T')" "$(date -d "@$EXPIRES" '+%F %T')" \
        "$(human_duration $(( EXPIRES - $(date +%s) )))" "$SUDO_PROFILE" )
  done
  shopt -u nullglob
  (( any )) || log "（暂无受管账号）"
}

cmd_status() {
  local name="${1:-}"; [[ -n $name ]] || die "用法：status <name>"
  meta_load "$name"
  local now remain
  now="$(date +%s)"; remain=$(( EXPIRES - now ))
  echo "账号      : $NAME"
  echo "状态      : $STATUS"
  echo "创建      : $(date -d "@$CREATED" '+%F %T')"
  echo "到期      : $(date -d "@$EXPIRES" '+%F %T')  （剩余 $(human_duration "$remain")）"
  echo "总时长    : $(human_duration "$DURATION")"
  echo "家目录    : $HOME_DIR"
  echo "工作目录  : $WORKDIR"
  echo "读写目录  : ${RW_LIST:-无}"
  echo "只读目录  : ${RO_LIST:-无}"
  echo "sudo 档位 : $SUDO_PROFILE"
  echo "SSH 来源  : ${SSH_FROM:-不限}"
  echo "Shell     : $SHELL_BIN"
  echo "系统状态  : $(user_exists "$NAME" && echo 存在 || echo 已删除) / $(passwd -S "$NAME" 2>/dev/null | awk '{print $2}' || echo '?')"
  echo "系统到期  : $(chage -l "$NAME" 2>/dev/null | awk -F': ' '/Account expires/{print $2}' || echo '?')"
  echo "sudo 文件 : $(ls -1 /etc/sudoers.d/aiuser-"$NAME" 2>/dev/null || echo 无)"
}

# --------------------------------------------------------------------- 延长
cmd_extend() {
  local name="${1:-}" dur="${2:-}"; [[ -n $name && -n $dur ]] || die "用法：extend <name> <时长>"
  meta_load "$name"
  local add expires
  add="$(parse_duration "$dur")"
  expires=$(( EXPIRES + add ))
  M_EXPIRES="$expires"; M_DURATION=$(( DURATION + add ))
  [[ $STATUS == expired || $STATUS == revoked ]] && M_STATUS="active"
  run meta_save "$name"
  run usermod -U "$name" 2>/dev/null || true
  run chage -E "$(date -d "@$(( expires + 86400 ))" +%F)" -m 0 -M 99999 -I -1 "$name"
  audit "extend name=$name add=${add}s new_expires=$expires"
  ok "$name 已延长 $(human_duration "$add")，新到期：$(date -d "@$expires" '+%F %T')"
}

# ------------------------------------------------------- 补授权（ACL 重放）
# 装好 acl 包后，把目录授权重新刷一遍；不带参数则处理所有受管账号
cmd_fixacl() {
  local name="${1:-}"
  need_cmd setfacl || die "先装 acl 包：apt install -y acl  /  dnf install -y acl"

  if [[ -z $name ]]; then
    local f found=0
    shopt -s nullglob
    for f in "$USERS_DIR"/*.meta; do
      found=1
      # shellcheck disable=SC1090
      ( . "$f"; echo "$NAME" ) | while read -r one; do cmd_fixacl "$one"; done
    done
    shopt -u nullglob
    (( found )) || log "（暂无受管账号）"
    return 0
  fi

  meta_load "$name"
  [[ $STATUS == active ]] || warn "$name 当前状态是 $STATUS，仍按元数据补授权"

  local p
  apply_acl "$name" "$WORKDIR" rw
  for p in $RW_LIST; do
    [[ $p == "$WORKDIR" ]] && continue
    apply_acl "$name" "$p" rw
  done
  for p in $RO_LIST; do
    apply_acl "$name" "$p" ro
  done
  audit "fixacl name=$name workdir=$WORKDIR"
  ok "$name 的目录授权已刷新"
}

# --------------------------------------------------------- 停用/吊销/回收
disable_user() {
  local name="$1" mode="${2:-expire}"   # expire | revoke
  meta_load "$name"

  if [[ $KILL_ON_EXPIRE == yes ]]; then
    run pkill -KILL -u "$name" 2>/dev/null || true
    info "已切断 $name 的在线会话"
  fi

  run usermod -L "$name" 2>/dev/null || true
  run chage -E 0 "$name" 2>/dev/null || true
  if [[ $DRY_RUN == no ]]; then
    if [[ -f "$HOME_DIR/.ssh/authorized_keys" ]]; then
      cp -f "$HOME_DIR/.ssh/authorized_keys" "$USERS_DIR/$name.authorized_keys.bak" 2>/dev/null || true
      : >"$HOME_DIR/.ssh/authorized_keys"
    fi
  fi
  ok "账号已锁定、密钥已摘除"

  run rm -f "/etc/sudoers.d/aiuser-$name"
  run rm -f "/etc/ssh/sshd_config.d/aiuser-$name.conf"   # 旧版本 drop-in 残留
  remove_sshd_block "$name"
  run rm -f "/etc/security/limits.d/aiuser-$name.conf"
  ok "sudo / sshd / limits 配置已移除"

  local p
  for p in $WORKDIR $RW_LIST $RO_LIST; do
    [[ -n $p ]] && clear_acl "$name" "$p"
  done
  ok "ACL 授权已回收"
}

archive_home() {
  local name="$1" home="$2" ts out
  [[ -d $home ]] || return 0
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$ARCHIVE_DIR/$name-$ts.tar.gz"
  if [[ $DRY_RUN == yes ]]; then
    printf '  %s[dry-run]%s tar 归档 %s -> %s\n' "$C_D" "$C_0" "$home" "$out"
    return 0
  fi
  tar -czf "$out" -C "$(dirname "$home")" "$(basename "$home")" 2>/dev/null || warn "归档失败：$home"
  chmod 600 "$out"
  ok "家目录已归档 -> $out"
}

cmd_revoke() {
  local name="${1:-}"; shift || true
  local purge=0 keep_home=0
  while (( $# )); do
    case "$1" in
      --purge) purge=1; shift ;;
      --keep-home) keep_home=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ -n $name ]] || die "用法：revoke <name> [--purge]"
  meta_load "$name"

  disable_user "$name" revoke

  if (( purge )); then
    if (( keep_home == 0 )); then archive_home "$name" "$HOME_DIR"; fi
    run userdel -r "$name" 2>/dev/null || run userdel "$name" 2>/dev/null || true
    ok "账号 $name 已删除"
    M_STATUS="purged"
  else
    M_STATUS="revoked"
    info "保留家目录 $HOME_DIR（--purge 可一并删除）"
  fi
  run meta_save "$name"
  audit "revoke name=$name purge=$purge"
}

# ---------------------------------------------------------------- 删除账号
# del <用户名> [-y] —— 一步到位：吊销 + 归档家目录 + 删除账号
cmd_del() {
  local name="${1:-}" force=0 keep_home=0
  shift || true
  while (( $# )); do
    case "$1" in
      -y|--yes)    force=1; shift ;;
      --keep-home) keep_home=1; shift ;;
      *) die "未知参数：$1（用法：del <用户名> [-y] [--keep-home]）" ;;
    esac
  done
  [[ -n $name ]] || die "用法：del <用户名> [-y] [--keep-home]"

  meta_load "$name"

  if (( force == 0 )); then
    if [[ -t 0 ]]; then
      printf '将删除账号 %s 及其家目录 %s（家目录会先归档到 %s）。确认？[y/N] ' \
        "$name" "$HOME_DIR" "$ARCHIVE_DIR"
      local ans=""
      read -r ans || true
      case "$ans" in
        y|Y|yes|YES) ;;
        *) info "已取消，账号保持原样"; return 0 ;;
      esac
    else
      die "非交互环境需显式确认：del $name -y"
    fi
  fi

  local -a extra=(--purge)
  (( keep_home )) && extra+=(--keep-home)
  cmd_revoke "$name" "${extra[@]}"
  ok "$name 已删除（家目录归档在 $ARCHIVE_DIR）"
}

cmd_cleanup() {
  local f name now
  now="$(date +%s)"
  shopt -s nullglob
  for f in "$USERS_DIR"/*.meta; do
    # shellcheck disable=SC1090
    ( . "$f"; echo "$NAME $EXPIRES $STATUS" ) | while read -r name exp st; do
      [[ $st == active ]] || continue
      (( exp <= now )) || continue
      echo "expired $name"
    done
  done | while read -r _ name; do
    info "处理到期账号：$name"
    meta_load "$name"
    disable_user "$name" expire
    if [[ $PURGE_ON_EXPIRE == yes ]]; then
      archive_home "$name" "$HOME_DIR"
      run userdel -r "$name" 2>/dev/null || run userdel "$name" 2>/dev/null || true
      M_STATUS="purged"
    else
      M_STATUS="expired"
    fi
    run meta_save "$name"
    audit "expire name=$name purge=$PURGE_ON_EXPIRE"
    ok "$name 已到期停用"
  done
  shopt -u nullglob
  return 0
}

# ------------------------------------------------------- 回收器 / 安装卸载
install_reaper() {
  run mkdir -p "$(dirname "$REAPER_CRON")"

  if need_cmd systemctl && [[ -d /run/systemd/system ]]; then
    if [[ $DRY_RUN == no ]]; then
      cat >"$REAPER_SVC" <<EOF
[Unit]
Description=AI temp account expiry reaper (aiuser)
After=network.target

[Service]
Type=oneshot
ExecStart=$SELF_DEST cleanup --quiet
Nice=10
IOSchedulingClass=idle
EOF
      cat >"$REAPER_TIMER" <<EOF
[Unit]
Description=Run aiuser cleanup periodically

[Timer]
OnBootSec=45s
OnUnitActiveSec=${REAPER_INTERVAL_SEC}s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
      chmod 644 "$REAPER_SVC" "$REAPER_TIMER"
      rm -f "$REAPER_CRON"
    fi
    run systemctl daemon-reload
    run systemctl enable --now aiuser-reaper.timer
    ok "到期回收器已启用：systemd timer（每 ${REAPER_INTERVAL_SEC}s）"
  else
    if [[ $DRY_RUN == no ]]; then
      cat >"$REAPER_CRON" <<EOF
# 由 aiuser.sh 生成 —— 每分钟检查一次到期账号
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root $SELF_DEST cleanup --quiet
EOF
      chmod 644 "$REAPER_CRON"
    fi
    ok "到期回收器已启用：cron（每分钟）"
  fi

  if [[ $DRY_RUN == no && -d /etc/logrotate.d ]]; then
    cat >"$LOGROTATE_CONF" <<EOF
$LOG_DIR/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF
    chmod 644 "$LOGROTATE_CONF"
  fi
}

# -------------------------------------------- 从旧版 ai-tempuser 自动迁移
# 把 ai-tempuser 时代的目录 / 片段 / 回收器迁到 aiuser 名下，避免留孤儿
migrate_legacy() {
  local old_lib="/var/lib/ai-tempuser" old_log="/var/log/ai-tempuser"
  local old_conf="/etc/ai-tempuser"
  local old_bin="/usr/local/sbin/ai-tempuser" old_rm="/usr/local/sbin/ai-rm"
  local moved=0 f base mf n p hm

  # 旧回收器先停掉，否则它还会继续去调旧主程序
  if [[ -f /etc/systemd/system/ai-tempuser-reaper.timer ]]; then
    run systemctl disable --now ai-tempuser-reaper.timer 2>/dev/null || true
    run rm -f /etc/systemd/system/ai-tempuser-reaper.service \
              /etc/systemd/system/ai-tempuser-reaper.timer
    run systemctl daemon-reload 2>/dev/null || true
    info "已停用旧回收器 ai-tempuser-reaper.timer"
    moved=1
  fi
  if [[ -f /etc/cron.d/ai-tempuser || -f /etc/logrotate.d/ai-tempuser ]]; then
    run rm -f /etc/cron.d/ai-tempuser /etc/logrotate.d/ai-tempuser
    moved=1
  fi

  # 数据 / 日志 / 配置目录整体搬过来（目标已存在则不覆盖）
  if [[ -d $old_lib && ! -e $LIB_DIR ]]; then
    run mv "$old_lib" "$LIB_DIR"; moved=1
  fi
  if [[ -d $old_log && ! -e $LOG_DIR ]]; then
    run mv "$old_log" "$LOG_DIR"; moved=1
  fi
  if [[ -d $old_conf && ! -e $CONF_DIR ]]; then
    run mv "$old_conf" "$CONF_DIR"; moved=1
  fi

  # 逐账号片段改名
  shopt -s nullglob
  for f in /etc/sudoers.d/ai-tempuser-*; do
    base="${f##*/ai-tempuser-}"
    run mv "$f" "/etc/sudoers.d/aiuser-$base"; moved=1
  done
  for f in /etc/ssh/sshd_config.d/ai-tempuser-*.conf; do
    base="${f##*/ai-tempuser-}"
    run mv "$f" "/etc/ssh/sshd_config.d/aiuser-$base"; moved=1
  done
  for f in /etc/security/limits.d/ai-tempuser-*.conf; do
    base="${f##*/ai-tempuser-}"
    run mv "$f" "/etc/security/limits.d/aiuser-$base"; moved=1
  done
  shopt -u nullglob

  if [[ -e $old_bin || -e $old_rm ]]; then
    run rm -f "$old_bin" "$old_rm"
    moved=1
  fi

  # sudoers 片段里写死的护栏路径从 ai-rm 变成了 aiuser-rm，逐账号重生成
  shopt -s nullglob
  for mf in "$USERS_DIR"/*.meta; do
    [[ -s $mf ]] || continue
    n="$(sed -n "s/^NAME='\(.*\)'$/\1/p" "$mf" | head -n1)"
    [[ -n $n ]] || continue
    p="$(sed -n "s/^SUDO_PROFILE='\(.*\)'$/\1/p" "$mf" | head -n1)"
    gen_sudoers "$n" "${p:-minimal}"
    hm="$(sed -n "s/^HOME_DIR='\(.*\)'$/\1/p" "$mf" | head -n1)"
    if [[ -n $hm && -f "$hm/.bashrc" ]]; then
      run sed -i -e 's|AI-TEMPUSER-BEGIN|AIUSER-BEGIN|' \
                   -e 's|AI-TEMPUSER-END|AIUSER-END|' \
                   -e 's|/usr/local/sbin/ai-rm|/usr/local/sbin/aiuser-rm|g' \
                   "$hm/.bashrc"
    fi
    moved=1
  done
  shopt -u nullglob

  if (( moved )); then
    ok "已从 ai-tempuser 迁移到 aiuser（旧命令 ai-tempuser / ai-rm 已移除）"
  fi
  return 0
}

# 旧版本把 SSH Match 块写进 sshd_config.d（见 gen_sshd 注释），升级时清掉并
# 把仍在管的账号按新方式重新写入 sshd_config 末尾
resync_sshd() {
  local f mf
  shopt -s nullglob
  for f in /etc/ssh/sshd_config.d/aiuser-*.conf; do run rm -f "$f"; done
  for mf in "$USERS_DIR"/*.meta; do
    [[ -s $mf ]] || continue
    # shellcheck disable=SC1090
    ( . "$mf" 2>/dev/null; printf '%s %s\n' "${NAME:-}" "${STATUS:-}" ) \
      | while read -r n st; do
          [[ -n $n && $st == active ]] && gen_sshd "$n"
        done
  done
  shopt -u nullglob
}

cmd_install() {
  migrate_legacy
  ensure_dirs
  if [[ $DRY_RUN == no ]]; then
    if [[ ! -f $CONF_FILE ]]; then
      cat >"$CONF_FILE" <<EOF
# aiuser 全局默认（改完立即生效，无需重装）
DEFAULT_DURATION="$DEFAULT_DURATION"
DEFAULT_PROFILE="$DEFAULT_PROFILE"
DEFAULT_WORKROOT="$DEFAULT_WORKROOT"
DEFAULT_SHELL="$DEFAULT_SHELL"
PURGE_ON_EXPIRE="$PURGE_ON_EXPIRE"
KILL_ON_EXPIRE="$KILL_ON_EXPIRE"
REAPER_INTERVAL_SEC=$REAPER_INTERVAL_SEC
EOF
      chmod 640 "$CONF_FILE"
      ok "默认配置 -> $CONF_FILE"
    fi
    local self; self="$(readlink -f "$0")"
    if [[ $self != "$SELF_DEST" ]]; then
      install -m 755 "$self" "$SELF_DEST"
      ok "主程序 -> $SELF_DEST"
    fi
  fi
  emit_ai_rm
  resync_sshd
  install_reaper
  ok "安装完成。下一步：sudo aiuser create --name ai_demo --duration 12h --gen-password"
}

cmd_uninstall() {
  local all=0
  while (( $# )); do case "$1" in --all) all=1; shift ;; *) die "未知参数：$1" ;; esac; done
  need_cmd systemctl && run systemctl disable --now aiuser-reaper.timer 2>/dev/null || true
  run rm -f "$REAPER_SVC" "$REAPER_TIMER" "$REAPER_CRON" "$LOGROTATE_CONF"
  need_cmd systemctl && run systemctl daemon-reload 2>/dev/null || true
  run rm -f "$AIRM_DEST"
  if (( all )); then
    local f name
    shopt -s nullglob
    for f in "$USERS_DIR"/*.meta; do
      # shellcheck disable=SC1090
      ( . "$f"; echo "$NAME" ) | while read -r name; do cmd_revoke "$name" --purge; done
    done
    shopt -u nullglob
  fi
  ok "回收器与护栏已卸载（配置与元数据保留在 $LIB_DIR / $CONF_DIR）"
}

# --------------------------------------------------------------------- 自检
cmd_check() {
  local rc=0
  echo "== 依赖 =="
  local c
  for c in useradd usermod userdel chage chpasswd passwd visudo setfacl getfacl tar; do
    if need_cmd "$c"; then printf '  %sok%s   %s\n' "$C_G" "$C_0" "$c"
    else printf '  %s缺%s   %s\n' "$C_R" "$C_0" "$c"; rc=1; fi
  done
  need_cmd sshd || warn "未检测到 sshd（跳过 SSH 相关检查）"

  echo "== 关键文件权限 =="
  local perms
  perms="$(stat -c '%a' /etc/shadow 2>/dev/null || echo '?')"
  [[ $perms == 600 || $perms == 640 || $perms == 000 ]] && printf '  %sok%s   /etc/shadow = %s\n' "$C_G" "$C_0" "$perms" \
    || { printf '  %s危%s   /etc/shadow = %s（应 <= 640）\n' "$C_R" "$C_0" "$perms"; rc=1; }
  grep -qE '^[[:space:]]*(@|#)?[[:space:]]*includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null \
    && printf '  %sok%s   sudoers 已 include /etc/sudoers.d\n' "$C_G" "$C_0" \
    || { printf '  %s危%s   sudoers 未 include /etc/sudoers.d，sudo 片段不会生效\n' "$C_R" "$C_0"; rc=1; }

  echo "== 家目录隔离（POSIX ACL 无法拒绝，只能靠默认权限）=="
  local d m
  for d in /home/*/; do
    [[ -d $d ]] || continue
    m="$(stat -c '%a' "$d")"
    if [[ $m =~ ^7 && ${#m} -eq 3 ]]; then
      printf '  %s危%s   %s = %s（其他用户可进入）\n' "$C_R" "$C_0" "$d" "$m"; rc=1
    fi
  done
  echo "  提示：/etc、/var/log 等系统目录天生 world-readable，ACL 只能『授权』不能『禁止』。"
  echo "        要强隔离请上容器 / systemd-nspawn / bwrap，本脚本只做省事 + 到期回收。"

  echo "== 回收器 =="
  if need_cmd systemctl && systemctl is-active --quiet aiuser-reaper.timer 2>/dev/null; then
    printf '  %sok%s   systemd timer 运行中\n' "$C_G" "$C_0"
  elif [[ -f $REAPER_CRON ]]; then
    printf '  %sok%s   cron 已安装\n' "$C_G" "$C_0"
  else
    printf '  %s危%s   回收器未安装，到期不会自动禁用（跑 install）\n' "$C_R" "$C_0"; rc=1
  fi

  echo "== 受管账号 =="
  local f n=0
  shopt -s nullglob
  for f in "$USERS_DIR"/*.meta; do n=$(( n + 1 )); done
  shopt -u nullglob
  echo "  受管账号数：$n"
  # 注意：check 是只读自检，不再顺带执行 cleanup（要回收请显式跑 cleanup）
  return $rc
}

# --------------------------------------------------------------------- 用法
usage() {
  cat <<EOF
aiuser.sh $VERSION — AI 临时账号生命周期管理器

用法：sudo $0 <子命令> [选项]

最常用 —— 三个位置参数，密码自动生成
  sudo $0 new ai /clicd 2h
      建 ai 账号，给 /clicd 完全读写，2 小时有效，自动生成密码并打印

首次使用先装（否则没有短命令，到期也不会自动禁用）
  sudo $0 install

子命令
  new|add <用户名> [目录] [时长] [档位]        极简创建（推荐）
                                              目录省略 -> /srv/aiwork/<用户名>
                                              时长省略 -> 24h
                                              档位省略 -> minimal
  install                                     安装到 $SELF_DEST + 启用到期回收器
  uninstall [--all]                           卸载回收器（--all 连同账号一起清）
  create --name N [选项]                       完整创建，需要细调时用
  list                                        列出受管账号与剩余时间
  status <name>                               查看详情
  extend <name> <时长>                         延长（如 24h、7d）
  del <用户名> [-y]                            删除账号：归档家目录后删干净
  revoke <name> [--purge] [--keep-home]       吊销：只锁号不删；加 --purge 才删
  fixacl [name]                               重放目录授权（装完 acl 包后用）
  cleanup                                     手动跑一次到期回收
  check                                       环境自检

create 选项
  -n, --name NAME          账号名（小写字母/数字/_/-，≤32 字符）        [必填]
  -t, --duration D         存活时长：30m 12h 7d 2w 1h30m               [默认 $DEFAULT_DURATION]
  -p, --password PASS      直接设密码（会进 shell history，慎用）
      --password-stdin     从标准输入读密码
      --gen-password       自动生成 24 位强密码并打印一次
      --force-change       首次登录强制改密
      --pubkey 'ssh-ed25519 AAAA...'  直接给公钥
      --pubkey-file PATH   从文件读公钥
      --ssh-from CIDR      仅允许该来源 IP 使用此密钥（写进 from=）
      --rw PATH            可读写目录（可重复，递归 + 默认 ACL 继承）
      --ro PATH            只读目录（可重复）
      --workdir PATH       主工作目录                                [默认 $DEFAULT_WORKROOT/<name>]
      --sudo-profile P     minimal | dev | ops | none                [默认 $DEFAULT_PROFILE]
                          minimal = 包管理/服务/文件操作/aiuser-rm，无解释器
                          dev     = 追加 git、python、node、docker 等（≈ 全权，注意）
                          ops     = 追加 kill、ip、lsof 等运维命令
      --quota 20G          磁盘配额（需文件系统开启 user quota）
      --shell PATH         登录 shell                               [默认 $DEFAULT_SHELL]
      --restricted         使用 /bin/rbash 受限 shell
  -h, --help               显示本帮助

全局
  --dry-run                只打印将要执行的动作，不落盘
  --quiet                  安静模式

示例
  # 最常用：建 ai 账号，给 /clicd 完全权限，2 小时有效，密码自动生成
  sudo $0 new ai /clicd 2h

  # 不指定目录，默认给 /srv/aiwork/ai
  sudo $0 new ai 2h

  # 需要开发命令（git/python/docker）时加第 4 个参数
  sudo $0 new ai /clicd 2h dev

  # 需要细调（公钥登录、只读目录、配额）时用完整版
  sudo $0 create --name ai_dev --duration 7d --pubkey-file ~/id_ed25519.pub \\
       --ssh-from 10.0.0.0/8 --rw /srv/project --ro /opt/src --sudo-profile dev --quota 20G

  sudo $0 list
  sudo $0 extend ai 1h
  sudo $0 revoke ai --purge

删除文件：sudo aiuser-rm <路径>   （只允许自家 home、授权目录、/tmp、/var/tmp）
EOF
}

# --------------------------------------------------------------------- main
main() {
  # 先抽全局开关
  local -a argv=()
  while (( $# )); do
    case "$1" in
      --dry-run) DRY_RUN=yes; shift ;;
      --quiet)   QUIET=yes; shift ;;
      --version|-V) echo "$VERSION"; exit 0 ;;
      *) argv+=("$1"); shift ;;
    esac
  done
  set -- "${argv[@]+"${argv[@]}"}"

  local sub="${1:-}"
  case "$sub" in
    ""|-h|--help|help) usage; exit 0 ;;
    install)   require_root; cmd_install ;;
    uninstall) require_root; shift; cmd_uninstall "$@" ;;
    check)     require_root; cmd_check ;;
    list)      require_root; cmd_list ;;
    status)    require_root; shift; cmd_status "$@" ;;
    cleanup)   require_root; cmd_cleanup ;;
    fixacl)    require_root; shift; cmd_fixacl "$@" ;;
    create|new|add|mk|extend|revoke|del|delete|remove)
      require_root
      ensure_dirs
      exec 9>"$LOCK_FILE"
      flock -n 9 || die "另一个实例正在运行，稍后再试"
      shift
      case "$sub" in
        create)              cmd_create "$@" ;;
        new|add|mk)          cmd_new "$@" ;;
        extend)              cmd_extend "$@" ;;
        revoke)              cmd_revoke "$@" ;;
        del|delete|remove)   cmd_del "$@" ;;
      esac
      ;;
    *) die "未知子命令：$sub（-h 查看用法）" ;;
  esac
}

main "$@"
