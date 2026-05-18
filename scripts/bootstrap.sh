#!/bin/bash
set -euo pipefail

# ============================================================
# bootstrap.sh - 部署底座脚本
# 通过 Cloudflare API 配置 DNS，自动生成密码，启动服务
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

# 检查依赖
check_deps() {
    for cmd in curl jq dig docker openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少依赖: $cmd"
            exit 1
        fi
    done
}

# 加载 .env
load_env() {
    if [ ! -f .env ]; then
        log_error ".env 文件不存在！请从 .env.example 复制并编辑"
        exit 1
    fi
    set -a
    source .env
    set +a

    # 检查必要变量
    local required_vars=("DOMAIN" "ADMIN_EMAIL" "CF_API_TOKEN")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            log_error "缺少必要环境变量: $var"
            exit 1
        fi
    done
}

# 自动生成密码（如果还是占位符）
generate_passwords() {
    local changed=false

    if [ "${PG_PASSWORD:-}" = "change_this_password" ] || [ -z "${PG_PASSWORD:-}" ]; then
        PG_PASSWORD=$(openssl rand -base64 24)
        sed -i "s/^PG_PASSWORD=.*/PG_PASSWORD=${PG_PASSWORD}/" .env
        log_info "已生成 PG_PASSWORD"
        changed=true
    fi

    if [ "${REDIS_PASSWORD:-}" = "change_this_password" ] || [ -z "${REDIS_PASSWORD:-}" ]; then
        REDIS_PASSWORD=$(openssl rand -base64 24)
        sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=${REDIS_PASSWORD}/" .env
        log_info "已生成 REDIS_PASSWORD"
        changed=true
    fi

    if [ "${S3_SECRET_KEY:-}" = "change_this_password" ] || [ -z "${S3_SECRET_KEY:-}" ]; then
        S3_SECRET_KEY=$(openssl rand -base64 24)
        sed -i "s/^S3_SECRET_KEY=.*/S3_SECRET_KEY=${S3_SECRET_KEY}/" .env
        log_info "已生成 S3_SECRET_KEY"
        changed=true
    fi

    if [ "${S3_ACCESS_KEY:-}" = "foundation" ] || [ -z "${S3_ACCESS_KEY:-}" ]; then
        S3_ACCESS_KEY=$(openssl rand -hex 12)
        sed -i "s/^S3_ACCESS_KEY=.*/S3_ACCESS_KEY=${S3_ACCESS_KEY}/" .env
        log_info "已生成 S3_ACCESS_KEY"
        changed=true
    fi

    if [ "$changed" = true ]; then
        # 重新加载 .env
        set -a
        source .env
        set +a
        log_info "密码已自动生成并保存到 .env"
    fi

    # 同步 s3.json 中的密钥
    if [ -f config/seaweedfs/s3.json ]; then
        sed -i "s/__S3_ACCESS_KEY__/${S3_ACCESS_KEY}/g" config/seaweedfs/s3.json
        sed -i "s/__S3_SECRET_KEY__/${S3_SECRET_KEY}/g" config/seaweedfs/s3.json
        log_info "已同步 S3 密钥到 seaweedfs 配置文件"
    fi
}

# 通过 Cloudflare API 获取 Zone ID
get_zone_id() {
    log_info "正在获取 Cloudflare Zone ID for domain: ${DOMAIN}..."

    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    local success
    success=$(echo "$response" | jq -r '.success // false')

    if [ "$success" != "true" ]; then
        log_error "Cloudflare API 调用失败: $(echo "$response" | jq -r '.errors[0].message // "未知错误"')"
        exit 1
    fi

    ZONE_ID=$(echo "$response" | jq -r '.result[0].id // empty')
    if [ -z "$ZONE_ID" ]; then
        log_error "未找到域名 ${DOMAIN} 对应的 Zone"
        exit 1
    fi

    log_info "Zone ID: ${ZONE_ID}"
}

# 获取公网 IP
get_public_ip() {
    log_info "正在获取公网 IP..."

    PUBLIC_IP=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null || \
                curl -s --max-time 10 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 10 https://icanhazip.com 2>/dev/null || true)

    if [ -z "$PUBLIC_IP" ]; then
        log_error "无法获取公网 IP"
        exit 1
    fi

    log_info "公网 IP: ${PUBLIC_IP}"
}

# 创建/更新 DNS 记录
update_dns() {
    local records=("${PUBLIC_IP}" "${PUBLIC_IP}")
    local names=("*" "@")

    for i in "${!names[@]}"; do
        local name="${names[$i]}"
        local ip="${records[$i]}"

        log_info "正在更新 DNS 记录: ${name}.${DOMAIN} -> ${ip}"

        # 查找现有记录
        local existing
        existing=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${name}.${DOMAIN}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json")

        local record_id
        record_id=$(echo "$existing" | jq -r '.result[0].id // empty')

        if [ -n "$record_id" ]; then
            # 更新现有记录
            local update_result
            update_result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${record_id}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"A\",\"name\":\"${name}.${DOMAIN}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}")

            local update_success
            update_success=$(echo "$update_result" | jq -r '.success // false')
            if [ "$update_success" = "true" ]; then
                log_info "DNS 记录已更新: ${name}.${DOMAIN}"
            else
                log_error "DNS 更新失败: $(echo "$update_result" | jq -r '.errors[0].message // "未知错误"')"
            fi
        else
            # 创建新记录
            local create_result
            create_result=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"A\",\"name\":\"${name}.${DOMAIN}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}")

            local create_success
            create_success=$(echo "$create_result" | jq -r '.success // false')
            if [ "$create_success" = "true" ]; then
                log_info "DNS 记录已创建: ${name}.${DOMAIN}"
            else
                log_error "DNS 创建失败: $(echo "$create_result" | jq -r '.errors[0].message // "未知错误"')"
            fi
        fi
    done
}

# 等待 DNS 传播
wait_dns_propagation() {
    local target_ip="$PUBLIC_IP"
    local max_attempts=30
    local attempt=0

    log_info "等待 DNS 传播（最多 30 秒）..."

    while [ $attempt -lt $max_attempts ]; do
        local resolved_ip
        resolved_ip=$(dig +short "*.${DOMAIN}" @8.8.8.8 2>/dev/null | tail -1 || true)

        if [ "$resolved_ip" = "$target_ip" ]; then
            log_info "DNS 已传播: *.${DOMAIN} -> ${resolved_ip}"
            return 0
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    log_info "DNS 传播等待超时，继续部署..."
}

# 部署 Docker 服务
deploy_services() {
    log_info "正在拉取 Docker 镜像..."

    if ! docker compose pull 2>/dev/null; then
        log_error "Docker 镜像拉取失败"
        exit 1
    fi

    log_info "正在启动服务..."

    if ! docker compose up -d --build 2>/dev/null; then
        log_error "服务启动失败"
        exit 1
    fi

    log_info "服务已启动"
}

# 验证部署
verify_deployment() {
    log_info "正在验证服务状态..."

    if [ -f scripts/verify.sh ]; then
        bash scripts/verify.sh || true
    fi
}

# 打印连接信息
print_info() {
    echo ""
    echo "=========================================="
    echo "  Foundation Stack 部署完成！"
    echo "=========================================="
    echo ""
    echo "Dashboard / Health:"
    echo "  https://health.${DOMAIN}"
    echo ""
    echo "S3 Gateway:"
    echo "  https://s3.${DOMAIN}"
    echo "  Access Key: ${S3_ACCESS_KEY}"
    echo "  Secret Key: ${S3_SECRET_KEY}"
    echo ""
    echo "PostgreSQL:"
    echo "  Host: 127.0.0.1:5432"
    echo "  User: ${PG_USER}"
    echo "  Password: ${PG_PASSWORD}"
    echo "  Database: ${PG_DB}"
    echo ""
    echo "Redis:"
    echo "  Host: 127.0.0.1:6379"
    echo "  Password: ${REDIS_PASSWORD}"
    echo ""
    echo "配置文件路径:"
    echo "  .env        - 所有密码和密钥"
    echo "  Caddyfile   - 反向代理配置"
    echo "  sites/      - 应用子域名配置"
    echo ""
    echo "管理命令:"
    echo "  docker compose ps              - 查看服务状态"
    echo "  docker compose logs -f         - 查看日志"
    echo "  docker compose restart <name>  - 重启服务"
    echo "  bash scripts/backup.sh         - 手动备份"
    echo "  bash scripts/create-app.sh     - 添加新应用"
    echo "=========================================="
}

# 主流程
main() {
    echo "=========================================="
    echo "  Foundation Stack - 底座部署"
    echo "=========================================="
    echo ""

    cd "$(dirname "$0")/.."

    check_deps
    load_env
    generate_passwords
    get_zone_id
    get_public_ip
    update_dns
    wait_dns_propagation
    deploy_services
    verify_deployment
    print_info
}

main "$@"
