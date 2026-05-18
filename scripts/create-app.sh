#!/bin/bash
set -euo pipefail

# ============================================================
# create-app.sh - 创建新应用的脚手架脚本
# 用法: create-app.sh <app-name> [port]
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

usage() {
    echo "用法: $0 <app-name> [port]"
    echo ""
    echo "参数:"
    echo "  app-name   应用名称（字母数字和短横线）"
    echo "  port       应用端口号（默认 80）"
    echo ""
    echo "示例:"
    echo "  $0 myapp 3000"
    echo "  $0 blog 8080"
    exit 1
}

# 检查参数
if [ $# -lt 1 ]; then
    usage
fi

APP_NAME="$1"
PORT="${2:-80}"

# 验证 app-name 格式
if ! echo "$APP_NAME" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'; then
    log_error "应用名称只能包含字母、数字和短横线，且不能以短横线开头或结尾"
    exit 1
fi

# 验证端口
if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    log_error "端口必须是 1-65535 之间的数字"
    exit 1
fi

# 加载 .env
cd "$(dirname "$0")/.."
if [ ! -f .env ]; then
    log_error ".env 文件不存在！请先部署底座"
    exit 1
fi
set -a
source .env
set +a

echo "=========================================="
echo "  创建新应用: ${APP_NAME}"
echo "=========================================="
echo ""

# 创建 PostgreSQL 数据库
log_info "正在创建数据库: ${APP_NAME}..."
if docker exec postgres psql -U "${PG_USER:-postgres}" -d postgres -tc \
    "SELECT 1 FROM pg_database WHERE datname='${APP_NAME}'" 2>/dev/null | grep -q 1; then
    log_warn "数据库 ${APP_NAME} 已存在，跳过"
else
    if docker exec postgres psql -U "${PG_USER:-postgres}" -d postgres -c \
        "CREATE DATABASE ${APP_NAME}" 2>/dev/null; then
        log_info "数据库 ${APP_NAME} 创建成功"
    else
        log_error "数据库创建失败"
        exit 1
    fi
fi

# 通过 S3 API 创建 bucket
log_info "正在创建 S3 bucket: ${APP_NAME}..."
S3_ENDPOINT="http://127.0.0.1:8333"

if curl -sf -X PUT "${S3_ENDPOINT}/${APP_NAME}" \
    -H "Authorization: AWS ${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    --max-time 10 2>/dev/null; then
    log_info "S3 bucket ${APP_NAME} 创建成功"
else
    log_warn "S3 bucket 创建可能失败（如已存在可忽略）"
fi

# 生成 sites/app-name.caddy 文件
log_info "正在生成 Caddy 配置文件..."

cat > "sites/${APP_NAME}.caddy" << EOF
# ${APP_NAME}.caddy - 由 create-app.sh 自动生成
${APP_NAME}.{env.DOMAIN} {
    reverse_proxy ${APP_NAME}:${PORT}
}
EOF

log_info "Caddy 配置文件已生成: sites/${APP_NAME}.caddy"

# 显示结果
echo ""
echo "=========================================="
echo "  应用 ${APP_NAME} 创建完成！"
echo "=========================================="
echo ""
echo "子域名:"
echo "  https://${APP_NAME}.${DOMAIN}"
echo ""
echo "数据库连接串:"
echo "  postgres://${PG_USER}:${PG_PASSWORD}@postgres:5432/${APP_NAME}"
echo ""
echo "S3 配置:"
echo "  Endpoint:    http://seaweedfs:8333"
echo "  Bucket:      ${APP_NAME}"
echo "  Access Key:  ${S3_ACCESS_KEY}"
echo "  Secret Key:  ${S3_SECRET_KEY}"
echo ""
echo "服务配置参考（docker-compose）："
echo ""
echo "  services:"
echo "    ${APP_NAME}:"
echo "      image: your-image:latest"
echo "      restart: unless-stopped"
echo "      networks:"
echo "        - foundation"
echo "      environment:"
echo "        DATABASE_URL: postgres://${PG_USER}:${PG_PASSWORD}@postgres:5432/${APP_NAME}"
echo "        REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379"
echo "        S3_ENDPOINT: http://seaweedfs:8333"
echo "        S3_ACCESS_KEY: ${S3_ACCESS_KEY}"
echo "        S3_SECRET_KEY: ${S3_SECRET_KEY}"
echo "        S3_BUCKET: ${APP_NAME}"
echo ""
echo "  networks:"
echo "    foundation:"
echo "      external: true"
echo ""
echo "=========================================="
echo "  提示：配置完成后重新加载 Caddy"
echo "  docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
echo "=========================================="
