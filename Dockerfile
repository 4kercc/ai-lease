# =============================================================================
#  aidocker-base —— 给 AI 用的一次性容器基础镜像
# =============================================================================
#  自带 sshd + 常用调试工具，容器内以 root 运行，配合 aidocker 使用。
#
#  设计前提：容器由 aidocker 启动，端口只绑 127.0.0.1、
#  削减了 SYS_ADMIN/SYS_MODULE/SYS_PTRACE 等 capability、
#  限制了内存/CPU/进程数。本镜像里的 root 是「容器内 root」，
#  不是「宿主机 root」。
#
#  构建：
#    docker build -t <你的用户名>/aidocker-base:bookworm .
#  多架构：
#    docker buildx build --platform linux/amd64,linux/arm64 \
#      -t <你的用户名>/aidocker-base:bookworm --push .
# =============================================================================

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="aidocker-base" \
      org.opencontainers.image.description="Throwaway container base for AI agents: sshd + common dev tools, root inside, isolated from host" \
      org.opencontainers.image.source="https://github.com/<你的用户名>/aidocker" \
      org.opencontainers.image.documentation="https://github.com/<你的用户名>/aidocker#readme" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai

# 让 RUN 里的管道错误也能中断构建
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 单层装完，装完即清缓存
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        openssh-server \
        ca-certificates curl wget git \
        vim-tiny less file tree \
        python3 python3-pip python3-venv \
        jq unzip zip tar rsync \
        procps iproute2 net-tools dnsutils \
        tzdata; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# sshd 配置：
#   · 允许 root 登录 —— 容器本来就是一次性的，隔离靠 namespace 不靠这个
#   · 密码 + 公钥都开 —— aidocker 默认生成 24 位随机密码
#   · UsePAM no     —— 容器内没有完整 PAM 栈，关掉更省事
#   · 端口暴露由 aidocker 控制，默认只绑 127.0.0.1
RUN set -eux; \
    mkdir -p /run/sshd /root/.ssh /etc/ssh/sshd_config.d; \
    chmod 700 /root/.ssh; \
    ssh-keygen -A; \
    printf '%s\n' \
        'PermitRootLogin yes' \
        'PasswordAuthentication yes' \
        'UsePAM no' \
        'PrintMotd no' \
        > /etc/ssh/sshd_config.d/99-aidocker.conf

WORKDIR /work
EXPOSE 22

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD pgrep -x sshd >/dev/null || exit 1

CMD ["/usr/sbin/sshd", "-D", "-e"]

# -----------------------------------------------------------------------------
# 想加编译工具链（镜像会涨到 ~600MB）：
#   apt-get install -y --no-install-recommends build-essential pkg-config
# 想加 Node：
#   curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
# 想加 Go：
#   curl -fsSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | tar -C /usr/local -xz
#   ENV PATH=/usr/local/go/bin:$PATH
# 注意：镜像越大，aidocker 在小内存机器上的构建/导入越慢。
# -----------------------------------------------------------------------------
