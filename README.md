# Server Scan

服务器性能诊断工具集，自动生成标准 Markdown 分析报告。

## 工具列表

| 脚本 | 功能 | 适用场景 |
|------|------|----------|
| `cpu_mem_analyzer.sh` | CPU / 内存深度分析 | 排查负载高、内存不足、OOM 风险 |
| `disk_analyzer.sh` | 磁盘空间 / IO / 健康分析 | 排查磁盘满、IO 瓶颈、SMART 预警 |

## 快速开始

```bash
# 赋予执行权限
chmod +x cpu_mem_analyzer.sh disk_analyzer.sh

# 运行分析
./cpu_mem_analyzer.sh   # 输出到 /tmp/cpu_mem_report.md
./disk_analyzer.sh      # 输出到 /tmp/disk_report.md

# 指定目录扫描（只扫描指定目录，跳过全盘扫描）
./disk_analyzer.sh -d /var/log
./disk_analyzer.sh -d /var/log -d /home/user
./disk_analyzer.sh -d "/var/log /home/user" --depth 5 --top 30
```

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

## 自定义配置

### 环境变量配置

```bash
# 修改报告输出路径
REPORT_PATH=/var/log/report.md ./cpu_mem_analyzer.sh

# 开启实时 IO 采样（磁盘脚本）
ENABLE_REALTIME_IO=true ./disk_analyzer.sh

# 关闭多核采样（CPU 脚本）
ENABLE_MPSTAT=false ./cpu_mem_analyzer.sh
```

### 配置文件配置

在当前目录创建 `disk_analyzer.conf` 文件，可自定义以下配置：

#### 磁盘使用率阈值
```bash
DISK_USAGE_WARNING_THRESHOLD=80      # 磁盘使用率警告阈值（%）
DISK_USAGE_CRITICAL_THRESHOLD=90     # 磁盘使用率危险阈值（%）
```

#### inode 使用率阈值
```bash
INODE_USAGE_WARNING_THRESHOLD=70     # inode 使用率警告阈值（%）
INODE_USAGE_CRITICAL_THRESHOLD=90    # inode 使用率危险阈值（%）
```

#### I/O 性能阈值
```bash
IO_AWAIT_EXCELLENT_THRESHOLD=10      # I/O await 优秀阈值（ms）
IO_AWAIT_GOOD_THRESHOLD=20           # I/O await 正常阈值（ms）
IO_AWAIT_SLOW_THRESHOLD=50           # I/O await 缓慢阈值（ms）
IO_UTIL_HEALTHY_THRESHOLD=60         # I/O %util 健康阈值（%）
IO_UTIL_BUSY_THRESHOLD=80            # I/O %util 繁忙阈值（%）
```

#### 大文件扫描配置
```bash
LARGE_FILE_SCAN_DEPTH=6              # 大文件扫描深度
LARGE_FILE_SIZE_THRESHOLD="1G"       # 大文件大小阈值
LARGE_FILE_SCAN_TIMEOUT=30           # 大文件扫描超时时间（秒）
LARGE_FILE_TOP=20                    # 大文件 Top N
```

#### 日志文件扫描配置
```bash
LOG_SCAN_DIR="/var/log"              # 日志扫描目录
LOG_FILE_SIZE_THRESHOLD="100M"       # 日志文件大小阈值
```

#### Docker 扫描配置
```bash
DOCKER_DATA_DIR=""                   # 自定义 Docker 数据目录
DOCKER_IMAGE_TOP=15                  # Docker 镜像 Top N
DOCKER_CONTAINER_TOP=10              # Docker 容器 Top N
DOCKER_VOLUME_TOP=15                 # Docker 卷 Top N
DOCKER_LOG_SIZE_THRESHOLD="100M"     # Docker 日志文件大小阈值
DOCKER_BUILD_CACHE_TOP=15            # Docker 构建缓存 Top N
DOCKER_CONTAINER_LOG_TOP=10          # 运行中容器日志大小 Top N
```

#### 挂载点扫描配置
```bash
MOUNT_SCAN_DEPTH=1                   # 挂载点扫描深度
MOUNT_SCAN_TOP=10                    # 挂载点扫描 Top N
MOUNT_SCAN_TIMEOUT=20                # 挂载点扫描超时时间（秒）
```

#### 指定目录扫描模式配置
```bash
SCAN_DEPTH=3                         # 指定目录扫描深度
SCAN_TOP=20                          # 指定目录扫描 Top N
```

#### 实时 I/O 配置
```bash
ENABLE_REALTIME_IO="false"           # 是否启用实时 I/O 负载快照
REALTIME_IO_INTERVAL=2               # 实时 I/O 采样间隔（秒）
```

#### macOS I/O 阈值配置
```bash
MACOS_IO_TPS_THRESHOLD=1000          # macOS I/O tps 阈值
MACOS_IO_MBS_THRESHOLD=100           # macOS I/O MB/s 阈值
```

#### 报告建议阈值配置
```bash
REPORT_DISK_USAGE_WARNING=85         # 报告建议中的磁盘使用率警告阈值（%）
REPORT_INODE_USAGE_WARNING=80        # 报告建议中的 inode 使用率警告阈值（%）
REPORT_IO_AWAIT_WARNING=20           # 报告建议中的 I/O await 警告阈值（ms）
REPORT_IO_UTIL_WARNING=100           # 报告建议中的 I/O %util 警告阈值（%）
```

完整示例配置文件请参考 `disk_analyzer.conf.example`。

## 定时任务

```bash
# 每小时生成一次报告
0 * * * * /path/to/cpu_mem_analyzer.sh
0 * * * * /path/to/disk_analyzer.sh
```

## 许可证

MIT
