# Server Scan

服务器性能诊断工具集，自动生成标准 Markdown 分析报告。

支持两种使用方式：
- **统一入口** `server-scan`：子命令风格，适合 Agent 调用
- **独立脚本**：直接执行各 `.sh` 脚本

## 工具列表

| 脚本 | 子命令 | 功能 | 适用场景 |
|------|--------|------|----------|
| `sys_overview.sh` | `overview` | 系统瓶颈总览 | 快速扫描 CPU / 内存 / 磁盘 / 网络 |
| `cpu_mem_analyzer.sh` | `cpu-mem` | CPU / 内存深度分析 | 排查负载高、内存不足、OOM 风险 |
| `disk_analyzer.sh` | `disk` | 磁盘空间 / IO / 健康分析 | 排查磁盘满、IO 瓶颈、SMART 预警 |
| `network_analyzer.sh` | `network` | 网络专项排查 | 接口、连通性、连接数、DNS |
| `security_scanner.sh` | `security` | 杀毒软件 / 主机安全防护检测 | 排查服务器上是否部署杀毒 / HIDS / EDR |

## 快速开始

### 使用统一入口

```bash
# 赋予执行权限
chmod +x server-scan sys_overview.sh cpu_mem_analyzer.sh disk_analyzer.sh network_analyzer.sh security_scanner.sh

# 查看帮助
./server-scan --help

# 运行系统瓶颈总览
./server-scan overview

# 磁盘专项分析
./server-scan disk

# 指定目录扫描（只扫描指定目录，跳过全盘扫描）
./server-scan disk -d /var/log
./server-scan disk -d /var/log -d /home/user
./server-scan disk -d "/var/log /home/user" --depth 5 --top 30

# 扫描杀毒软件 / 主机安全防护
./server-scan security

# 运行所有诊断
./server-scan all
```

### 直接执行脚本

```bash
./sys_overview.sh
./cpu_mem_analyzer.sh
./disk_analyzer.sh
./network_analyzer.sh
./security_scanner.sh
```

## 公共 CLI 选项

所有脚本支持以下公共选项：

| 选项 | 说明 |
|------|------|
| `-o, --output PATH` | 报告输出路径（覆盖默认路径） |
| `-c, --config FILE` | 指定配置文件（覆盖默认配置文件查找） |
| `-q, --quiet` | 静默模式（只输出报告路径一行，供 Agent 解析） |
| `--json` | 在 stdout 输出一行 JSON 元数据（供 Agent 程序化消费） |
| `--no-color` | 禁用 ANSI 颜色（Agent 调用时必需） |
| `--lang LANG` | 指定输出语言（zh_CN / en_US，默认跟随系统 LANG） |
| `--notify` | 启用通知推送（将扫描结果发送到配置的 Channel） |
| `--notify-channel NAME` | 指定通知渠道（默认: feishu） |
| `--webhook URL` | 指定 webhook 地址（覆盖配置文件） |
| `--notify-test` | 发送一条测试消息，验证通知配置是否正确 |
| `-h, --help` | 显示帮助信息 |

### 脚本特定选项

**disk_analyzer.sh:**
| 选项 | 说明 |
|------|------|
| `-d, --dir DIR` | 指定扫描目录（可多次指定或使用空格分隔多个目录） |
| `--depth N` | 子目录扫描深度（默认: 3） |
| `--top N` | 显示 Top N 结果（默认: 20） |

**network_analyzer.sh:**
| 选项 | 说明 |
|------|------|
| `--ping-targets "IP1 IP2"` | 连通性探测目标（默认: 8.8.8.8 1.1.1.1） |
| `--dns-targets "D1 D2"` | DNS 解析测试域名（默认: www.baidu.com www.google.com） |

**cpu_mem_analyzer.sh:**
| 选项 | 说明 |
|------|------|
| `--no-mpstat` | 禁用多核采样（Linux 下有效） |
| `--interval N` | 采样间隔（秒，默认: 1） |
| `--count N` | 采样次数（默认: 3） |

## Agent 集成

### 静默模式

```bash
# 静默模式：只输出报告路径一行
./server-scan overview --quiet
# 输出: /tmp/sys_overview_20240101_120000.md

# JSON 输出：输出结构化元数据
./server-scan overview --json
# 输出:
# {
#   "status": "success",
#   "report_path": "/tmp/sys_overview_20240101_120000.md",
#   "timestamp": "2024-01-01T12:00:00Z",
#   "hostname": "server01",
#   "script": "sys_overview.sh",
#   "duration_sec": 5,
#   "summary": "",
#   "bottlenecks": ""
# }
```

### 退出码

| 退出码 | 含义 |
|--------|------|
| 0 | 成功 |
| 1 | 发现瓶颈（或检测到防护软件） |
| 2 | 参数错误 |

## 国际化 (i18n)

支持中英文双语输出，语言优先级：`SS_LANG` 环境变量 > 系统 `LANG` > 默认中文。

```bash
# 默认中文（跟随系统语言）
./server-scan overview

# 临时切换为英文（环境变量）
SS_LANG=en_US ./server-scan overview

# 通过参数指定语言（仅当次运行生效）
./server-scan --lang en_US overview
```

语言包位于 `lib/i18n/`（`zh_CN.sh`、`en_US.sh`），新增语言只需复制模板并翻译。

## 系统支持

- **Linux**: CentOS / Ubuntu / Debian / RHEL
- **macOS**: Intel / Apple Silicon

## 依赖安装

**Linux:**
```bash
# CentOS/RHEL
yum install -y sysstat smartmontools bc

# Ubuntu/Debian
apt install -y sysstat smartmontools bc
```

**macOS:**
```bash
brew install coreutils smartmontools
```

## 报告内容

**系统总览报告** (`sys_overview.sh`)
- CPU / 内存 / 磁盘 / 网络 快速扫描
- 综合健康度评分与瓶颈结论
- 各维度瓶颈清单

**CPU / 内存报告** (`cpu_mem_analyzer.sh`)
- CPU 基础信息与负载评估
- CPU 时间分布与多核采样
- 内存总体概况与 Swap 分析
- OOM 风险评估
- 进程状态分布与资源消耗 Top 10
- 上下文切换与系统句柄统计

**磁盘报告** (`disk_analyzer.sh`)
- 块设备列表与 I/O 调度器
- 磁盘空间与 inode 使用率
- I/O 性能采样与实时负载快照
- 大文件与日志扫描
- LVM 逻辑卷信息
- SMART 健康状态
- Docker 空间占用专项扫描
- 指定目录空间占用分析

**网络报告** (`network_analyzer.sh`)
- 网络接口状态与流量
- 连通性测试（可自定义目标）
- TCP 连接状态统计
- 端口监听扫描
- DNS 解析测试
- 丢包与延迟分析

**安全扫描报告** (`security_scanner.sh`)
- 内置 20+ 款常见防护软件特征库（ClamAV / CrowdStrike / 云盾 / 云镜 / Wazuh 等）
- 四类信号交叉检测：进程名、systemd 服务、安装包（rpm/dpkg）、特征路径
- 按类别分类：传统杀毒 / 主机安全 (HIDS) / EDR 终端防护
- 检测结论与部署建议（只读检测，不会停止或修改任何防护软件）

## 自定义配置

### 命令行配置

```bash
# 修改报告输出路径
./server-scan overview -o /var/log/report.md

# 指定目录扫描
./server-scan disk -d /var/log --depth 5 --top 30
```

### 配置文件配置

在当前目录创建配置文件（如 `disk_analyzer.conf`），可自定义各项阈值：

```bash
# 磁盘使用率阈值
DISK_USAGE_WARNING_THRESHOLD=80
DISK_USAGE_CRITICAL_THRESHOLD=90

# I/O 性能阈值
IO_AWAIT_EXCELLENT_THRESHOLD=10
IO_AWAIT_GOOD_THRESHOLD=20
IO_AWAIT_SLOW_THRESHOLD=50

# Docker 扫描配置
DOCKER_DATA_DIR=""                   # 自定义 Docker 数据目录
DOCKER_IMAGE_TOP=15
DOCKER_CONTAINER_TOP=10
```

完整示例配置文件请参考 `disk_analyzer.conf.example`。

通知推送相关配置见下方 [通知推送 (Channel)](#通知推送-channel)，示例文件为 `notify.conf.example`。

## 通知推送 (Channel)

支持将扫描结果推送到外部 Channel，当前内置**飞书自定义机器人**。

### 快速配置

```bash
# 1. 复制配置文件模板
cp notify.conf.example notify.conf

# 2. 填入 webhook（飞书: 群设置 -> 群机器人 -> 添加自定义机器人）
vi notify.conf

# 3. 设置权限（配置文件含密钥，禁止其他用户读取）
chmod 600 notify.conf

# 4. 验证配置是否正确
./server-scan overview --notify-test

# 5. 执行扫描并推送
./server-scan overview --notify
```

### 配置项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `NOTIFY_ENABLED` | `false` | 是否默认启用推送；为 false 时用 `--notify` 按需启用 |
| `NOTIFY_CHANNEL` | `feishu` | 通知渠道，当前支持 `feishu` |
| `NOTIFY_WEBHOOK` | 空 | Webhook 地址（**必填**） |
| `NOTIFY_SECRET` | 空 | 签名密钥，机器人开启签名校验时填写 |
| `NOTIFY_MSG_TYPE` | `text` | 消息类型：`text` 纯文本 / `card` 交互式卡片 |
| `NOTIFY_MODE` | `summary` | `summary` 仅推送告警摘要 / `full` 推送完整报告 |
| `NOTIFY_MAX_BYTES` | `20000` | 全文模式下正文最大字节数 |
| `NOTIFY_TIMEOUT` | `10` | HTTP 请求超时（秒） |
| `NOTIFY_ON_ALERT_ONLY` | `false` | 仅在检测到告警（🔴/🟡）时推送 |
| `NOTIFY_MENTION_ALL` | `false` | 是否 @所有人 |
| `NOTIFY_MENTION_IDS` | 空 | @指定用户 open_id，逗号分隔 |
| `NOTIFY_SUMMARY_LINES` | `20` | 摘要模式提取的告警行上限 |

### 配置优先级

命令行参数 > 环境变量 > 配置文件。

配置文件查找顺序（找到第一个存在的文件即停止）：

1. `$NOTIFY_CONFIG`
2. 脚本 `-c/--config` 指定的配置文件
3. `$SCRIPT_DIR/notify.conf`
4. `$HOME/.server-scan/notify.conf`
5. `/etc/server-scan/notify.conf`

### 使用示例

```bash
# 按需单次推送
./server-scan overview --notify

# 临时指定 webhook（调试用；webhook 会出现在进程列表中）
./server-scan disk --notify --webhook "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"

# 定时巡检，仅在有告警时推送（避免正常状态刷屏）
NOTIFY_ON_ALERT_ONLY=true ./server-scan overview --notify

# 使用非默认路径的配置文件
NOTIFY_CONFIG=/etc/server-scan/notify.conf ./server-scan network --notify

# 推送完整报告并使用卡片消息
NOTIFY_MODE=full NOTIFY_MSG_TYPE=card ./server-scan overview --notify
```

### 安全提示

- `notify.conf` 可能包含 webhook 与签名密钥，已加入 `.gitignore`，请勿提交到代码仓库
- 建议设置 `chmod 600 notify.conf`；权限过宽时脚本会给出警告
- `--webhook` 参数会出现在进程列表中，生产环境建议改用配置文件
- 推送失败不会影响扫描本身，也不会改变脚本退出码

## 定时任务

```bash
# 每小时生成一次报告
0 * * * * /path/to/server-scan overview -o /var/log/sys_overview.md
0 * * * * /path/to/server-scan disk -o /var/log/disk_report.md
```

## 许可证

MIT
