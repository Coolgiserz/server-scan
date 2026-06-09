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

## 自定义配置

```bash
# 修改报告输出路径
REPORT_PATH=/var/log/report.md ./cpu_mem_analyzer.sh

# 开启实时 IO 采样（磁盘脚本）
ENABLE_REALTIME_IO=true ./disk_analyzer.sh

# 关闭多核采样（CPU 脚本）
ENABLE_MPSTAT=false ./cpu_mem_analyzer.sh
```

## 定时任务

```bash
# 每小时生成一次报告
0 * * * * /path/to/cpu_mem_analyzer.sh
0 * * * * /path/to/disk_analyzer.sh
```

## 许可证

MIT
