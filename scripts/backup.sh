#!/bin/bash
set -euo pipefail

# ============================================================
# backup.sh - 数据库和配置备份脚本
# 备份 PostgreSQL 并上传到 SeaweedFS S3
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

# 加载 .env
load_env() {
    cd "$(dirname "$0")/.."
    if [ ! -f .env ]; then
        log_error ".env 文件不存在"
        exit 1
    fi
    set -a
    source .env
    set +a
}

# 执行备份
do_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="/tmp/backup-${timestamp}.sql.gz"
    local backup_filename="backup-${timestamp}.sql.gz"

    log_info "开始 PostgreSQL 备份..."

    # pg_dumpall
    if ! docker exec postgres pg_dumpall -U "${PG_USER:-postgres}" 2>/dev/null | gzip > "$backup_file"; then
        log_error "PostgreSQL 备份失败"
        exit 1
    fi

    local backup_size
    backup_size=$(du -h "$backup_file" | cut -f1)
    log_info "备份文件大小: ${backup_size}"

    # 上传到 SeaweedFS S3
    log_info "正在上传到 S3..."

    local s3_endpoint="http://127.0.0.1:8333"
    local bucket="foundation-backups"

    # 确保 bucket 存在
    curl -sf -X PUT "${s3_endpoint}/${bucket}" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
        -H "Host: ${bucket}.s3.localhost" \
        --max-time 10 2>/dev/null || true

    # 上传文件
    if curl -sf -X PUT "${s3_endpoint}/${bucket}/${backup_filename}" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
        -H "Host: ${bucket}.s3.localhost" \
        -H "Content-Type: application/gzip" \
        --data-binary @"${backup_file}" \
        --max-time 60 2>/dev/null; then
        log_info "备份已上传到 S3: ${bucket}/${backup_filename}"
    else
        log_error "备份上传到 S3 失败"
        rm -f "$backup_file"
        exit 1
    fi

    # 清理本地临时文件
    rm -f "$backup_file"

    echo ""
    log_info "备份完成: ${backup_filename} (${backup_size})"
}

# 清理过期备份
cleanup_old_backups() {
    local retention_days="${BACKUP_RETENTION_DAYS:-7}"
    log_info "清理 ${retention_days} 天前的备份..."

    local s3_endpoint="http://127.0.0.1:8333"
    local bucket="foundation-backups"
    local cutoff_date
    cutoff_date=$(date -d "-${retention_days} days" +%Y%m%d)

    # 列出所有备份文件
    local response
    response=$(curl -sf -X GET "${s3_endpoint}/${bucket}/" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
        -H "Host: ${bucket}.s3.localhost" \
        --max-time 10 2>/dev/null || echo "")

    if [ -z "$response" ]; then
        log_info "没有找到备份文件或 bucket 为空"
        return
    fi

    # 解析并删除过期文件
    echo "$response" | grep -o 'backup-[0-9]\{8\}-[0-9]\{6\}\.sql\.gz' 2>/dev/null | while read -r filename; do
        local file_date
        file_date=$(echo "$filename" | grep -o 'backup-[0-9]\{8\}' | sed 's/backup-//')

        if [ "$file_date" -lt "$cutoff_date" ]; then
            log_info "删除过期备份: ${filename}"
            curl -sf -X DELETE "${s3_endpoint}/${bucket}/${filename}" \
                -H "Authorization: AWS ${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
                -H "Host: ${bucket}.s3.localhost" \
                --max-time 10 2>/dev/null || true
        fi
    done

    log_info "过期备份清理完成"
}

# 主流程
main() {
    echo "=========================================="
    echo "  Foundation Stack - 备份"
    echo "=========================================="
    echo ""

    load_env
    do_backup
    cleanup_old_backups

    echo ""
    log_info "所有操作完成"
    echo "=========================================="
}

main "$@"
