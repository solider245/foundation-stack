#!/bin/bash
set -euo pipefail

# ============================================================
# verify.sh - 验证所有服务正常运行
# ============================================================

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
RESET=$(tput sgr0)
BOLD=$(tput bold)

PASS=0
FAIL=0

log_pass() {
    PASS=$((PASS + 1))
    echo -e "${GREEN}[PASS]${RESET} $1"
}

log_fail() {
    FAIL=$((FAIL + 1))
    echo -e "${RED}[FAIL]${RESET} $1"
}

print_result() {
    echo ""
    echo "=========================================="
    echo "  验证结果: ${GREEN}${PASS} 通过${RESET}, ${RED}${FAIL} 失败${RESET}"
    echo "=========================================="

    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
}

check_docker_daemon() {
    if docker info &>/dev/null; then
        log_pass "Docker daemon 运行中"
    else
        log_fail "Docker daemon 未运行"
    fi
}

check_containers() {
    local expected_containers=("caddy" "postgres" "redis" "seaweedfs")

    for container in "${expected_containers[@]}"; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            local status
            status=$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null)
            if [ "$status" = "running" ]; then
                log_pass "容器 ${container} 运行中"
            else
                log_fail "容器 ${container} 状态: ${status}"
            fi
        else
            log_fail "容器 ${container} 未运行"
        fi
    done
}

check_ports() {
    local ports=(80 443 5432 6379 8333)
    local names=("HTTP" "HTTPS" "PostgreSQL" "Redis" "SeaweedFS S3")

    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local name="${names[$i]}"

        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            log_pass "端口 ${port} (${name}) 已监听"
        else
            log_fail "端口 ${port} (${name}) 未监听"
        fi
    done
}

check_postgres() {
    local container="postgres"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        if docker exec "$container" pg_isready -U "${PG_USER:-postgres}" &>/dev/null; then
            log_pass "PostgreSQL 连接正常"
        else
            log_fail "PostgreSQL 连接失败"
        fi
    else
        log_fail "PostgreSQL 容器未运行，跳过检查"
    fi
}

check_redis() {
    local container="redis"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        local password="${REDIS_PASSWORD:-}"
        if docker exec "$container" redis-cli -a "$password" ping 2>/dev/null | grep -q "PONG"; then
            log_pass "Redis 连接正常"
        else
            log_fail "Redis 连接失败"
        fi
    else
        log_fail "Redis 容器未运行，跳过检查"
    fi
}

check_s3() {
    if curl -sf --max-time 5 http://127.0.0.1:8333 &>/dev/null; then
        log_pass "SeaweedFS S3 响应正常"
    else
        log_fail "SeaweedFS S3 无响应"
    fi
}

check_certificate() {
    local domain="${DOMAIN:-}"
    if [ -z "$domain" ]; then
        log_fail "DOMAIN 未设置，跳过证书检查"
        return
    fi

    if curl -sf --max-time 10 "https://health.${domain}" &>/dev/null; then
        log_pass "HTTPS 证书正常 (health.${domain})"
    else
        log_fail "HTTPS 证书检查失败 (health.${domain})"
    fi
}

# 主流程
main() {
    echo "=========================================="
    echo "  Foundation Stack - 服务验证"
    echo "=========================================="
    echo ""

    cd "$(dirname "$0")/.."

    # 加载 .env
    if [ -f .env ]; then
        set -a
        source .env
        set +a
    fi

    check_docker_daemon
    check_containers
    check_ports
    check_postgres
    check_redis
    check_s3
    check_certificate

    print_result
}

main "$@"
