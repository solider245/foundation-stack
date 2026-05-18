#!/bin/bash
set -euo pipefail

# ============================================================
# install.sh - 一键安装入口脚本
# 1. 检查环境
# 2. 初始化 .env
# 3. 运行 provision.sh（系统初始化）
# 4. 运行 bootstrap.sh（服务部署）
# 5. 安装备份 cron
# ============================================================

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

log_info() {
    echo -e "${GREEN}[INFO]${RESET} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

# 检查基础依赖
check_deps() {
    log_info "检查基础依赖..."

    for cmd in git; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少依赖: $cmd"
            exit 1
        fi
    done

    # Docker 可能还没有安装，先检查但不强制
    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version)"
    else
        log_warn "Docker 未安装，provision.sh 将自动安装"
    fi

    log_info "基础依赖检查通过"
}

# 初始化 .env
init_env() {
    if [ -f .env ]; then
        log_info ".env 文件已存在，跳过初始化"
        log_warn "如需重新配置，请手动编辑 .env"
        return
    fi

    if [ ! -f .env.example ]; then
        log_error ".env.example 文件不存在"
        exit 1
    fi

    cp .env.example .env
    log_info ".env 文件已从 .env.example 创建"
    echo ""
    echo "=========================================="
    echo "  请编辑 .env 文件，配置以下信息："
    echo ""
    echo "  DOMAIN        - 你的域名"
    echo "  ADMIN_EMAIL   - 管理员邮箱"
    echo "  CF_API_TOKEN  - Cloudflare API Token"
    echo ""
    echo "  密码项可保留默认值，部署时自动生成"
    echo "=========================================="
    echo ""

    read -r -p "是否现在编辑 .env？(y/N): " edit_now
    if [[ "$edit_now" =~ ^[Yy]$ ]]; then
        ${EDITOR:-vi} .env
    fi
}

# 运行 provision.sh
run_provision() {
    if [ ! -f scripts/provision.sh ]; then
        log_error "scripts/provision.sh 不存在"
        exit 1
    fi

    log_info "开始系统初始化..."
    bash scripts/provision.sh
    log_info "系统初始化完成"
}

# 运行 bootstrap.sh
run_bootstrap() {
    if [ ! -f scripts/bootstrap.sh ]; then
        log_error "scripts/bootstrap.sh 不存在"
        exit 1
    fi

    log_info "开始部署底座服务..."
    bash scripts/bootstrap.sh
    log_info "底座部署完成"
}

# 安装备份 cron
install_backup_cron() {
    local script_path
    script_path="$(pwd)/scripts/backup.sh"

    if [ ! -f "$script_path" ]; then
        log_warn "backup.sh 不存在，跳过 cron 安装"
        return
    fi

    log_info "正在安装备份 cron（每天凌晨 3 点）..."

    # 检查是否已有 cron
    if crontab -l 2>/dev/null | grep -q "$script_path"; then
        log_info "备份 cron 已存在"
        return
    fi

    # 添加 cron
    (
        crontab -l 2>/dev/null || true
        echo "0 3 * * * cd $(pwd) && bash ${script_path} >> /var/log/foundation-backup.log 2>&1"
    ) | crontab -

    log_info "备份 cron 已安装：每天凌晨 3:00 执行"
}

# 主流程
main() {
    echo ""
    echo "=========================================="
    echo "  Foundation Stack - 一键安装"
    echo "  PaaS 底座：Caddy + PostgreSQL + Redis + SeaweedFS"
    echo "=========================================="
    echo ""

    # 切换到项目根目录
    cd "$(dirname "$0")/.."
    local project_root
    project_root=$(pwd)
    log_info "项目根目录: ${project_root}"

    check_deps
    init_env
    run_provision
    run_bootstrap
    install_backup_cron

    echo ""
    echo "=========================================="
    echo -e "  ${GREEN}安装完成！${RESET}"
    echo "=========================================="
    echo ""
    echo "快速命令:"
    echo "  cd ${project_root}"
    echo "  docker compose ps                  - 查看服务状态"
    echo "  docker compose logs -f             - 查看日志"
    echo "  bash scripts/backup.sh             - 手动备份"
    echo "  bash scripts/create-app.sh <name>  - 添加新应用"
    echo "  bash scripts/verify.sh             - 验证服务"
    echo ""
    echo "配置文件:"
    echo "  ${project_root}/.env"
    echo "  ${project_root}/Caddyfile"
    echo "  ${project_root}/docker-compose.yml"
    echo ""
}

main "$@"
