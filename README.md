# Foundation Stack

自建 PaaS 底座项目，提供标准化的基础设施栈，可用于快速部署个人/团队应用。

## 技术栈

```
                         ┌─────────────┐
                         │   Internet   │
                         └──────┬──────┘
                                │ 80/443
                         ┌──────▼──────┐
                         │    Caddy    │ 反向代理 + 自动 TLS (Cloudflare DNS-01)
                         │  (caddy-dns/cloudflare)
                         └──┬───┬───┬──┘
                            │   │   │
              ┌─────────────┘   │   └──────────────┐
              │                 │                   │
        ┌─────▼──────┐   ┌─────▼──────┐     ┌──────▼──────┐
        │ PostgreSQL │   │   Redis    │     │  SeaweedFS  │
        │   16-alpine │   │  7-alpine  │     │  (S3-compatible)
        │   :5432    │   │  :6379     │     │  :8333      │
        └────────────┘   └────────────┘     └─────────────┘
                                                    │
                                          ┌─────────┴─────────┐
                                          │                   │
                                    ┌─────▼─────┐     ┌──────▼──────┐
                                    │  App 备份  │     │  Loki 日志   │
                                    │           │     │  (可选)      │
                                    └───────────┘     └─────────────┘
```

## 组件说明

| 组件 | 版本 | 用途 | 端口 |
|------|------|------|------|
| **Caddy** | 最新 (custom build) | 反向代理，自动 HTTPS（Cloudflare DNS-01） | 80/443 |
| **PostgreSQL** | 16-alpine | 关系型数据库 | 127.0.0.1:5432 |
| **Redis** | 7-alpine | 缓存/消息队列 | 127.0.0.1:6379 |
| **SeaweedFS** | latest | 分布式文件存储 (S3-compatible) | 127.0.0.1:8333 |

## 前置条件

- 一台 Linux 服务器（Debian/Ubuntu/CentOS，2GB 内存以上）
- 域名已托管到 Cloudflare
- Cloudflare API Token（Zone:DNS:Edit 权限）
- 能够访问 GitHub（Docker 镜像下载）

## 快速开始

### 第一步：克隆并配置

```bash
git clone <repo-url> foundation-stack
cd foundation-stack
cp .env.example .env
vi .env   # 编辑 DOMAIN、ADMIN_EMAIL、CF_API_TOKEN
```

### 第二步：一键安装

```bash
bash scripts/install.sh
```

install.sh 会自动完成：
1. 检测 OS 并安装 Docker 和基础工具
2. 初始化系统配置（时区、内核参数、swap）
3. 自动生成安全密码
4. 配置 Cloudflare DNS 记录
5. 部署所有 Docker 服务
6. 验证服务健康状态
7. 添加每日备份 cron

### 第三步：验证

```bash
bash scripts/verify.sh
```

访问 https://health.你的域名 确认服务运行正常。

## 添加新应用

### 使用脚手架（推荐）

```bash
bash scripts/create-app.sh myapp 3000
```

脚本会自动：
1. 在 PostgreSQL 中创建数据库
2. 在 SeaweedFS 中创建 S3 bucket
3. 生成 Caddy 反向代理配置

### 手动添加

1. 创建 Docker Compose 文件，将 `networks` 设为 `foundation`（external）
2. 参考 `templates/app-docker-compose.yml`
3. 在 `sites/` 目录添加 Caddy 配置
4. 重新加载 Caddy：`docker exec caddy caddy reload --config /etc/caddy/Caddyfile`

## 备份策略

### 自动备份

每日凌晨 3 点自动执行（由 cron 驱动）：

```cron
0 3 * * * cd /path/to/foundation-stack && bash scripts/backup.sh >> /var/log/foundation-backup.log 2>&1
```

### 备份内容

- PostgreSQL 全量导出（pg_dumpall）
- 上传到 SeaweedFS 的 `foundation-backups` bucket

### 保留策略

默认保留 7 天，可通过 `.env` 中的 `BACKUP_RETENTION_DAYS` 调整。

### 手动备份

```bash
bash scripts/backup.sh
```

输出示例：
```
[INFO] 备份文件大小: 256M
[INFO] 备份已上传到 S3: foundation-backups/backup-20250101-030000.sql.gz
[INFO] 备份完成
```

## 服务管理

```bash
# 查看所有服务
docker compose ps

# 查看日志
docker compose logs -f

# 重启单个服务
docker compose restart postgres

# 停止所有服务
docker compose down

# 更新服务（拉取新镜像后重启）
docker compose pull
docker compose up -d
```

## 目录结构

```
foundation-stack/
├── .env                  # 环境变量（敏感信息，已 gitignore）
├── .env.example          # 环境变量模板
├── .gitignore
├── Dockerfile.caddy      # Caddy 自定义构建（含 cloudflare dns 模块）
├── Caddyfile             # Caddy 主配置
├── docker-compose.yml    # 服务编排
├── README.md             # 本文件
├── config/
│   ├── loki.yaml         # Loki 日志配置（可选）
│   └── seaweedfs/
│       └── s3.json       # SeaweedFS S3 认证配置
├── scripts/
│   ├── install.sh        # 一键安装（入口）
│   ├── provision.sh      # 服务器初始化
│   ├── bootstrap.sh      # 底座部署
│   ├── verify.sh         # 服务验证
│   ├── backup.sh         # 数据库备份
│   └── create-app.sh     # 应用脚手架
├── sites/                # 应用子域名 Caddy 配置（自动加载）
├── templates/
│   ├── app-docker-compose.yml   # 应用 Docker Compose 模板
│   └── app-caddyfile.conf       # 应用 Caddy 配置模板
└── data/                 # 容器数据卷（已 gitignore）
```

## 安全注意

1. **所有密码在 .env 中管理**，切勿提交到版本控制
2. 数据库和 S3 端口仅监听 127.0.0.1，不暴露到公网
3. Caddy 自动管理 TLS 证书，无需手动处理
4. 生产环境请使用非 root 用户运行 Docker
5. 定期更新 Docker 镜像以获取安全补丁

## 技术选型理由

### Caddy
- 自动 HTTPS，零配置 TLS
- 内建 Cloudflare DNS-01 ACME 支持
- 灵活的全局模板语法

### PostgreSQL
- 成熟稳定，生态丰富
- 16-alpine 镜像体积小（~200MB）
- pg_dumpall 全量备份可靠

### Redis
- 高性能内存数据库
- 7-alpine 极致轻量（~30MB）
- AOF 持久化保证数据安全

### SeaweedFS
- S3 兼容，单二进制文件部署
- 相比 MinIO 更轻量（~50MB vs ~300MB）
- 内置 master/volume 架构，可水平扩展
- 社区活跃，适合自建场景

## License

MIT License - 随意使用，欢迎贡献。
