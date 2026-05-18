#!/bin/bash
set -euo pipefail

# ============================================================
# provision.sh - 新服务器初始化脚本
# 自动检测 OS，安装 Docker、docker compose、基础工具
# ============================================================

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
RESET=$(tput sgr0)

log_info() {
    echo -e "${GREEN}[INFO]${RESET} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

# 检测 OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "无法检测操作系统类型"
        exit 1
    fi
    log_info "检测到操作系统: $OS $OS_VERSION"
}

# 设置时区
set_timezone() {
    local tz="${TIMEZONE:-Asia/Shanghai}"
    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$tz" 2>/dev/null || true
    elif [ -f /usr/share/zoneinfo/"$tz" ]; then
        ln -sf /usr/share/zoneinfo/"$tz" /etc/localtime
    fi
    log_info "时区已设置为: $tz"
}

# 安装 Docker（官方脚本，有中国镜像代理 fallback）
install_docker() {
    if command -v docker &>/dev/null; then
        log_info "Docker 已安装，版本: $(docker --version)"
        return
    fi

    log_info "正在安装 Docker..."

    # 尝试官方脚本
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        sh /tmp/get-docker.sh || true
    fi

    # 如果官方脚本失败，尝试中国镜像
    if ! command -v docker &>/dev/null; then
        log_info "官方源安装失败，尝试国内镜像..."
        if curl -fsSL https://get.daocloud.io/docker -o /tmp/get-docker.sh 2>/dev/null; then
            sh /tmp/get-docker.sh || true
        fi
    fi

    # 最终检查
    if ! command -v docker &>/dev/null; then
        log_error "Docker 安装失败，请手动安装"
        exit 1
    fi

    log_info "Docker 安装成功: $(docker --version)"

    # 启动 Docker
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
}

# 安装 docker compose plugin
install_docker_compose() {
    if docker compose version &>/dev/null; then
        log_info "Docker Compose 已安装: $(docker compose version)"
        return
    fi

    log_info "正在安装 Docker Compose plugin..."

    # 尝试通过官方仓库安装
    if command -v apt-get &>/dev/null; then
        apt-get install -y docker-compose-plugin 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y docker-compose-plugin 2>/dev/null || true
    fi

    # 如果没装上，手动下载
    if ! docker compose version &>/dev/null; then
        local arch
        arch=$(uname -m)
        local compose_version="v2.30.3"
        local download_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-${arch}"

        curl -fsSL "$download_url" -o /usr/libexec/docker/cli-plugins/docker-compose 2>/dev/null || \
        curl -fsSL "https://mirror.ghproxy.com/${download_url}" -o /usr/libexec/docker/cli-plugins/docker-compose 2>/dev/null || true

        if [ -f /usr/libexec/docker/cli-plugins/docker-compose ]; then
            chmod +x /usr/libexec/docker/cli-plugins/docker-compose
        fi
    fi

    if docker compose version &>/dev/null; then
        log_info "Docker Compose 安装成功: $(docker compose version)"
    else
        log_error "Docker Compose 安装失败，请手动安装"
        exit 1
    fi
}

# 安装基础工具
install_basic_tools() {
    log_info "正在安装基础工具..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl jq git openssl dnsutils 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y curl jq git openssl bind-utils 2>/dev/null || true
    elif command -v apk &>/dev/null; then
        apk add --no-cache curl jq git openssl bind-tools 2>/dev/null || true
    else
        log_error "不支持的包管理器"
        exit 1
    fi

    log_info "基础工具安装完成"
}

# 调内核参数
tune_kernel() {
    log_info "正在调整内核参数..."

    # vm.swappiness
    local current_swappiness
    current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
    if [ "$current_swappiness" -gt 10 ]; then
        sysctl -w vm.swappiness=10 2>/dev/null || true
        echo "vm.swappiness=10" > /etc/sysctl.d/99-foundation.conf 2>/dev/null || true
    fi

    # fs.file-max
    local current_file_max
    current_file_max=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
    if [ "$current_file_max" -lt 1000000 ]; then
        sysctl -w fs.file-max=1000000 2>/dev/null || true
        echo "fs.file-max=1000000" >> /etc/sysctl.d/99-foundation.conf 2>/dev/null || true
    fi

    log_info "内核参数调整完成"
}

# 检查并创建 swap
setup_swap() {
    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}' 2>/dev/null || echo 0)
    local mem_gb=$((mem_kb / 1024 / 1024))

    if [ "$mem_gb" -lt 4 ]; then
        if ! swapon --show 2>/dev/null | grep -q .; then
            log_info "内存小于 4GB 且无 swap，创建 2GB swapfile..."
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo "/swapfile none swap sw 0 0" >> /etc/fstab 2>/dev/null || true
            log_info "Swapfile 创建完成"
        else
            log_info "Swap 已存在，跳过"
        fi
    else
        log_info "内存 >= 4GB，跳过 swap 创建"
    fi
}

# 主流程
main() {
    echo "=========================================="
    echo "  Foundation Stack - 服务器初始化"
    echo "=========================================="

    # 加载 .env（如果有）
    if [ -f .env ]; then
        set -a
        source .env
        set +a
    fi

    detect_os
    set_timezone
    install_docker
    install_docker_compose
    install_basic_tools
    tune_kernel
    setup_swap

    echo ""
    log_info "服务器初始化完成！"
    echo "=========================================="
}

main "$@"
