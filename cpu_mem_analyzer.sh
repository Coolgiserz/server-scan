#!/bin/bash
# ==============================================================================
# 脚本名称: cpu_mem_analyzer.sh
# 功能说明: CPU 与内存专项深度分析，兼容 Linux 与 macOS
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL) / macOS (Intel/Apple Silicon)
# 依赖工具: sysstat (Linux 可选), bc, ps, top
# Linux 安装: yum/apt install -y sysstat bc
# macOS 安装: brew install coreutils (可选，提供 numfmt 功能)
# 使用方法: chmod +x cpu_mem_analyzer.sh && ./cpu_mem_analyzer.sh
# 输出文件: 默认 /tmp/cpu_mem_report_$(date +%Y%m%d_%H%M%S).md
# ==============================================================================

# --- 配置区 ---
REPORT_PATH="/tmp/cpu_mem_report_$(date '+%Y%m%d_%H%M%S').md"
ENABLE_MPSTAT="true" # Linux 下有效，macOS 自动忽略
SAMPLE_INTERVAL=1
SAMPLE_COUNT=3

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cli.sh"

# 解析公共参数（必须在主shell中直接调用，不能用命令替换）
ss::parse_common_args "$@"

# 脚本特定参数解析（解析 SCRIPT_ARGS 中剩余的参数）
set -- "${SCRIPT_ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-mpstat)
        ENABLE_MPSTAT="false"
        shift
        ;;
    --interval)
        if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
            SAMPLE_INTERVAL="$2"
            shift 2
        else
            ss::log_error "错误: --interval 需要指定数字参数"
            exit 2
        fi
        ;;
    --count)
        if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
            SAMPLE_COUNT="$2"
            shift 2
        else
            ss::log_error "错误: --count 需要指定数字参数"
            exit 2
        fi
        ;;
    -h | --help)
        ss::print_usage "$(basename "$0")" "CPU 与内存专项深度分析，兼容 Linux 与 macOS" "  --no-mpstat           禁用多核采样（Linux 下有效）
  --interval N          采样间隔（秒，默认: 1）
  --count N             采样次数（默认: 3）"
        exit 0
        ;;
    *)
        # 忽略其他参数
        shift
        ;;
    esac
done

# ==============================================================================
# 按系统选择命令 / 工具探测
# 集中定义平台相关命令，后续统一引用，避免散落的裸调用跨平台失效
# ==============================================================================
if [ "$OS_TYPE" = "Darwin" ]; then
    # --- macOS: 使用 sysctl / vm_stat / top -l / ps ---
    : # macOS 专有命令在各章节内通过 command -v / OS_TYPE 判定选用
elif [ "$OS_TYPE" = "Linux" ]; then
    # --- Linux: 使用 /proc、top -bn1、mpstat(可选) ---
    : # Linux 专有命令在各章节内通过 command -v / OS_TYPE 判定选用
else
    echo "> ⚠️ 当前系统 ($OS_TYPE) 不是受支持的 Linux/macOS，部分功能可能不可用。" >&3
fi

# 报告开始
ss::report_begin "CPU/内存 分析" 12

# ==============================================================================
# OS 检测与基础信息
# ==============================================================================

echo "# CPU / 内存 深度分析报告"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
    ARCH="$(uname -m)"
    UPTIME_INFO=$(uptime | sed 's/^.*up *//; s/, *[0-9]* user.*//; s/ day(s)/天/; s/ hour(s)/小时/; s/ minute(s)/分钟/')
    echo "> **操作系统:** macOS ${OS_NAME}  "
    echo "> **架构:** ${ARCH}  "
else
    OS_NAME="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Linux')"
    ARCH="$(uname -m)"
    UPTIME_INFO=$(uptime -p 2>/dev/null || uptime | awk -F',' '{print $1}')
    echo "> **操作系统:** ${OS_NAME}  "
    echo "> **架构:** ${ARCH}  "
fi

echo "> **主机名:** $(hostname)  "
echo "> **采集时间:** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **内核版本:** $(uname -r)  "
echo "> **运行时长:** ${UPTIME_INFO}  "
echo ""
echo "---"
echo ""

# ==============================================================================
# 1. CPU 基础信息
# ==============================================================================

ss::progress 1 12 "CPU 基础信息"
echo "## 1. CPU 基础信息"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS CPU 信息
    CPU_MODEL=$(ss::read_sysctl "machdep.cpu.brand_string")
    PHY_CORES=$(ss::read_sysctl "hw.physicalcpu")
    LOGIC_CORES=$(ss::read_sysctl "hw.ncpu")
    SIBLINGS=$(ss::read_sysctl "hw.logicalcpu")
    CPU_FREQ=$(ss::read_sysctl "hw.cpufrequency")
    # Apple Silicon 等新硬件上 hw.cpufrequency 可能不存在
    if [ -n "$CPU_FREQ" ] && [ "$CPU_FREQ" != "N/A" ]; then
        CPU_FREQ_MHZ=$(echo "scale=0; $CPU_FREQ / 1000000" | bc 2>/dev/null || awk "BEGIN{printf \"%.0f\", $CPU_FREQ/1000000}")
    else
        CPU_FREQ_MHZ="N/A"
    fi
    L2_CACHE=$(ss::read_sysctl "hw.l2cachesize")
    L3_CACHE=$(ss::read_sysctl "hw.l3cachesize")

    # 预先计算每核心线程数，避免在 exec > >(tee) 下复杂的命令替换导致输出重复
    if command -v bc >/dev/null 2>&1 && [ -n "$SIBLINGS" ] && [ -n "$PHY_CORES" ] && [ "$PHY_CORES" != "N/A" ] && [ "$PHY_CORES" -gt 0 ]; then
        THREADS_PER_CORE=$(echo "scale=1; $SIBLINGS / $PHY_CORES" | bc)
    else
        THREADS_PER_CORE=$(awk "BEGIN{printf \"%.1f\", $SIBLINGS/$PHY_CORES}" 2>/dev/null || echo "N/A")
    fi

    echo "| 指标 | 数值 |"
    echo "|------|------|"
    echo "| CPU 型号 | ${CPU_MODEL} |"
    echo "| 物理核心数 | ${PHY_CORES} |"
    echo "| 逻辑核心数 (含超线程) | ${LOGIC_CORES} |"
    echo "| 每核心线程数 | ${THREADS_PER_CORE} |"
    echo "| 基础频率 | ${CPU_FREQ_MHZ} MHz |"
    echo "| L2 缓存 | $(ss::hr_bytes ${L2_CACHE}) |"
    echo "| L3 缓存 | $(ss::hr_bytes ${L3_CACHE}) |"
    echo ""
else
    # Linux CPU 信息
    model=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    phy_cores=$(grep 'cpu cores' /proc/cpuinfo | head -1 | awk '{print $4}')
    logic_cores=$(nproc)
    siblings=$(grep 'siblings' /proc/cpuinfo | head -1 | awk '{print $3}')
    cache=$(grep 'cache size' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    flags=$(grep 'flags' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs | tr ' ' '\n' | grep -E 'vmx|svm|aes|avx|sse4' | tr '\n' ',' | sed 's/,$//')

    echo "| 指标 | 数值 |"
    echo "|------|------|"
    echo "| CPU 型号 | ${model:-N/A} |"
    echo "| 物理核心数 | ${phy_cores:-N/A} |"
    echo "| 逻辑核心数 (含超线程) | ${logic_cores:-N/A} |"
    if [ -n "$phy_cores" ] && [ "$phy_cores" -gt 0 ] && [ -n "$siblings" ]; then
        threads_per_core=$((siblings / phy_cores))
    else
        threads_per_core="N/A"
    fi
    echo "| 每核心线程数 | ${threads_per_core} |"
    echo "| 缓存大小 | ${cache:-N/A} |"
    echo "| 关键特性 | ${flags:-N/A} |"

    # CPU 频率
    min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    cur_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    if [ -n "$max_freq" ]; then
        echo "| 最低频率 | ${min_freq} MHz |"
        echo "| 最高频率 | ${max_freq} MHz |"
        echo "| 当前频率 | ${cur_freq} MHz |"
    fi
    echo ""
fi

# ==============================================================================
# 2. CPU 负载与使用率
# ==============================================================================

ss::progress 2 12 "CPU 负载与使用率"
echo "## 2. CPU 负载与使用率"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS 负载
    LOAD_RAW=$(ss::read_sysctl "vm.loadavg")
    # 输出格式: { 1.23 2.34 3.45 }
    load1=$(echo "$LOAD_RAW" | awk '{print $2}')
    load5=$(echo "$LOAD_RAW" | awk '{print $3}')
    load15=$(echo "$LOAD_RAW" | awk '{print $4}')

    # macOS top 快照
    # top -l 1 -n 0: -l 1 表示1次快照，-n 0 表示不显示进程列表
    TOP_OUTPUT=$(top -l 1 -n 0 2>/dev/null)

    # 解析 CPU 行: "CPU usage: 10.0% user, 5.0% sys, 85.0% idle"
    CPU_LINE=$(echo "$TOP_OUTPUT" | grep "CPU usage")
    # macOS grep 不支持 -P，改用 grep -o 配合简单正则
    us=$(echo "$CPU_LINE" | grep -o '[0-9.]*% user' | grep -o '[0-9.]*' | head -1 || echo "0.0")
    sy=$(echo "$CPU_LINE" | grep -o '[0-9.]*% sys' | grep -o '[0-9.]*' | head -1 || echo "0.0")
    id=$(echo "$CPU_LINE" | grep -o '[0-9.]*% idle' | grep -o '[0-9.]*' | head -1 || echo "0.0")
    # macOS top 没有直接的 ni/wa/hi/si/st 拆分，近似处理
    ni="0.0"
    wa="N/A"
    hi="N/A"
    si="N/A"
    st="N/A"
else
    # Linux 负载
    load1=$(cat /proc/loadavg | awk '{print $1}')
    load5=$(cat /proc/loadavg | awk '{print $2}')
    load15=$(cat /proc/loadavg | awk '{print $3}')

    # Linux top 快照
    cpu_line=$(top -bn1 | grep -E "^%?Cpu\(s\)" | head -1)
    us=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*us' | awk '{print $1}' || echo "0.0")
    sy=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*sy' | awk '{print $1}' || echo "0.0")
    ni=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*ni' | awk '{print $1}' || echo "0.0")
    id=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*id' | awk '{print $1}' || echo "0.0")
    wa=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*wa' | awk '{print $1}' || echo "0.0")
    hi=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*hi' | awk '{print $1}' || echo "0.0")
    si=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*si' | awk '{print $1}' || echo "0.0")
    st=$(echo "$cpu_line" | grep -oP '\d+\.?\d*\s*st' | awk '{print $1}' || echo "0.0")
fi

# 评估负载
if [ "$OS_TYPE" = "Darwin" ]; then
    CORES=$LOGIC_CORES
else
    CORES=$logic_cores
fi

if command -v bc &>/dev/null && [ "$CORES" != "N/A" ] && [ -n "$CORES" ] &&
    [ -n "$load1" ] && [ -n "$load5" ] && [ -n "$load15" ]; then
    threshold_busy=$(echo "$CORES * 1.0" | bc -l)
    threshold_danger=$(echo "$CORES * 2.0" | bc -l)
    if (($(echo "$load1 > $threshold_danger" | bc -l))); then
        load_eval="🔴 危险"
    elif (($(echo "$load1 > $threshold_busy" | bc -l))); then
        load_eval="🟡 繁忙"
    else
        load_eval="🟢 健康"
    fi
else
    load_eval="⚪ 未安装 bc，无法精确评估"
fi

echo "> **评估标准:** load1 < 核心数×0.7 健康，> 核心数 繁忙，> 核心数×2 危险"
echo ""
echo "| 指标 | 数值 | 评估 |"
echo "|------|------|------|"
echo "| 1分钟负载 | $load1 | $load_eval |"
echo "| 5分钟负载 | $load5 | - |"
echo "| 15分钟负载 | $load15 | - |"
echo ""

echo "### CPU 时间分布 (top 快照)"
echo ""
echo "> **关键指标:** wa(IO等待) > 20% 说明磁盘瓶颈；sy(系统态) > 20% 说明内核开销大"
echo ""
echo "| 指标 | 数值 | 说明 | 状态 |"
echo "|------|------|------|------|"

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "| us (用户态) | ${us}% | 应用程序消耗 | - |"
    echo "| sy (系统态) | ${sy}% | 内核消耗 | - |"
    echo "| id (空闲) | ${id}% | CPU 空闲率 | - |"
    echo "| ni/wa/hi/si/st | N/A | macOS top 不拆分 | - |"
    echo ""
    echo "> ℹ️ macOS 的 \`top\` 不输出 wa/ni/hi/si/st 等细分指标，建议结合 \`iostat\` 分析磁盘等待"
    echo ""
else
    wa_num=$(echo "$wa" | awk '{printf "%d", $1}')
    if [ "$wa_num" -gt 20 ]; then wa_status="🔴 瓶颈"; elif [ "$wa_num" -gt 10 ]; then wa_status="🟡 偏高"; else wa_status="🟢 正常"; fi

    sy_num=$(echo "$sy" | awk '{printf "%d", $1}')
    if [ "$sy_num" -gt 20 ]; then sy_status="🔴 过高"; elif [ "$sy_num" -gt 10 ]; then sy_status="🟡 偏高"; else sy_status="🟢 正常"; fi

    echo "| us (用户态) | ${us}% | 应用程序消耗 | - |"
    echo "| sy (系统态) | ${sy}% | 内核消耗 | $sy_status |"
    echo "| ni (nice) | ${ni}% | 低优先级进程 | - |"
    echo "| id (空闲) | ${id}% | CPU 空闲率 | - |"
    echo "| wa (IO等待) | ${wa}% | 等待磁盘 IO | $wa_status |"
    echo "| hi (硬中断) | ${hi}% | 硬件中断 | - |"
    echo "| si (软中断) | ${si}% | 软件中断 | - |"
    echo "| st (steal) | ${st}% | 被宿主机偷走 | - |"
    echo ""
fi

# ==============================================================================
# 3. 多核 CPU 详细采样 (仅 Linux)
# ==============================================================================

if [ "$OS_TYPE" != "Darwin" ] && [ "$ENABLE_MPSTAT" = "true" ] && command -v mpstat &>/dev/null; then
    ss::progress 3 12 "多核 CPU 详细采样 (mpstat)"
    echo "## 3. 多核 CPU 详细采样 (mpstat)"
    echo ""
    echo "> **说明:** 采样 ${SAMPLE_COUNT} 次，每次间隔 ${SAMPLE_INTERVAL} 秒，取平均值"
    echo ""
    echo "| CPU | usr% | sys% | iowait% | idle% | 评估 |"
    echo "|-----|------|------|---------|-------|------|"

    mpstat -P ALL $SAMPLE_INTERVAL $SAMPLE_COUNT 2>/dev/null | awk '
        /^Average:/ {
            cpu = $2
            usr = $3 + 0
            sys = $4 + 0
            iowait = $6 + 0
            idle = $12 + 0

            eval = ""
            if (iowait > 20) eval = "🔴 IO瓶颈"
            else if (iowait > 10) eval = "🟡 IO偏高"
            else if (usr + sys > 80) eval = "🟡 高负载"
            else if (idle > 70) eval = "🟢 空闲"
            else eval = "✅ 正常"

            printf "| %s | %.1f | %.1f | %.1f | %.1f | %s |\n", cpu, usr, sys, iowait, idle, eval
        }
    '
    echo ""
fi

# ==============================================================================
# 4. 内存总体概况
# ==============================================================================

ss::progress 4 12 "内存总体概况"
echo "## 4. 内存总体概况"
echo ""
echo "> **评估标准:** available < 总内存 10% 为危险；Swap 使用 > 0 说明曾发生内存交换"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS 内存：通过 vm_stat 和 sysctl
    PAGE_SIZE=$(ss::read_sysctl "hw.pagesize")
    TOTAL_BYTES=$(ss::read_sysctl "hw.memsize")
    TOTAL_KB=$((TOTAL_BYTES / 1024))

    # vm_stat 输出示例（macOS 格式）：
    # Pages free: 12345
    # Pages active: 67890
    # Pages inactive: 11111
    # Pages speculative: 2222
    # Pages wired down: 3333
    # Pages occupied by compressor: 4444
    VM_STAT=$(vm_stat 2>/dev/null)

    parse_vm_stat() {
        # vm_stat 输出中键值之间有大量空格，使用冒号+空格作为分隔符
        echo "$VM_STAT" | grep "^$1:" | awk -F': *' '{print $2}' | sed 's/\.//'
    }

    pages_free=$(parse_vm_stat "Pages free")
    pages_active=$(parse_vm_stat "Pages active")
    pages_inactive=$(parse_vm_stat "Pages inactive")
    # shellcheck disable=SC2034
    pages_speculative=$(parse_vm_stat "Pages speculative")
    pages_wired=$(parse_vm_stat "Pages wired down")
    pages_compressed=$(parse_vm_stat "Pages occupied by compressor")

    # 计算近似值
    # macOS 可用内存 ≈ free + inactive (可被回收)
    # used ≈ active + wired + compressed
    free_kb=$((pages_free * PAGE_SIZE / 1024))
    inactive_kb=$((pages_inactive * PAGE_SIZE / 1024))
    active_kb=$((pages_active * PAGE_SIZE / 1024))
    wired_kb=$((pages_wired * PAGE_SIZE / 1024))
    compressed_kb=$((pages_compressed * PAGE_SIZE / 1024))

    avail_kb=$((free_kb + inactive_kb))
    used_kb=$((active_kb + wired_kb + compressed_kb))

    # 计算百分比（防止 vm_stat 解析失败导致 TOTAL_KB 为零）
    if [ -n "$TOTAL_KB" ] && [ "$TOTAL_KB" -gt 0 ]; then
        used_pct=$(awk "BEGIN {printf \"%.2f\", $used_kb/$TOTAL_KB*100}")
        avail_pct=$(awk "BEGIN {printf \"%.2f\", $avail_kb/$TOTAL_KB*100}")
    else
        used_pct="0.00"
        avail_pct="0.00"
    fi

    avail_num=$(echo "$avail_pct" | awk '{printf "%d", $1}')
    if [ "$avail_num" -lt 10 ]; then
        mem_status="🔴 严重不足"
    else
        mem_status="🟢 充足"
    fi

    echo "| 指标 | 数值 (KB) | 人类可读 | 占比 | 状态 |"
    echo "|------|-----------|----------|------|------|"
    echo "| 总内存 | $TOTAL_KB | $(ss::hr_kb $TOTAL_KB) | 100% | - |"
    echo "| 已使用 (估算) | $used_kb | $(ss::hr_kb $used_kb) | ${used_pct}% | - |"
    echo "| 可用 (free+inactive) | $avail_kb | $(ss::hr_kb $avail_kb) | ${avail_pct}% | $mem_status |"
    echo "| 活跃内存 | $active_kb | $(ss::hr_kb $active_kb) | - | - |"
    echo "| 空闲页 | $free_kb | $(ss::hr_kb $free_kb) | - | - |"
    echo "| 非活跃页 | $inactive_kb | $(ss::hr_kb $inactive_kb) | - | - |"
    echo "| 锁定页 (wired) | $wired_kb | $(ss::hr_kb $wired_kb) | - | - |"
    echo "| 压缩页 | $compressed_kb | $(ss::hr_kb $compressed_kb) | - | - |"
    echo ""

    echo "> ℹ️ macOS 内存管理采用统一内存架构，inactive 页面可被快速回收，因此可用内存包含 inactive。"
    echo ""
else
    # Linux 内存
    free_kb=$(free -k | grep '^Mem:')
    total_kb=$(echo "$free_kb" | awk '{print $2}')
    used_kb=$(echo "$free_kb" | awk '{print $3}')
    free_kb_val=$(echo "$free_kb" | awk '{print $4}')
    shared_kb=$(echo "$free_kb" | awk '{print $5}')
    buff_kb=$(echo "$free_kb" | awk '{print $6}')
    avail_kb=$(echo "$free_kb" | awk '{print $7}')

    if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ]; then
        used_pct=$(awk "BEGIN {printf \"%.2f\", $used_kb/$total_kb*100}")
        avail_pct=$(awk "BEGIN {printf \"%.2f\", $avail_kb/$total_kb*100}")
        cache_pct=$(awk "BEGIN {printf \"%.2f\", $buff_kb/$total_kb*100}")
    else
        used_pct="0.00"
        avail_pct="0.00"
        cache_pct="0.00"
    fi

    avail_num=$(echo "$avail_pct" | awk '{printf "%d", $1}')
    if [ "$avail_num" -lt 5 ]; then
        mem_status="🔴 严重不足"
    elif [ "$avail_num" -lt 10 ]; then
        mem_status="🟡 紧张"
    else
        mem_status="🟢 充足"
    fi

    echo "| 指标 | 数值 (KB) | 人类可读 | 占比 | 状态 |"
    echo "|------|-----------|----------|------|------|"
    echo "| 总内存 | $total_kb | $(ss::hr_kb $total_kb) | 100% | - |"
    echo "| 已使用 | $used_kb | $(ss::hr_kb $used_kb) | ${used_pct}% | - |"
    echo "| 可用 (available) | $avail_kb | $(ss::hr_kb $avail_kb) | ${avail_pct}% | $mem_status |"
    echo "| 缓存/缓冲 | $buff_kb | $(ss::hr_kb $buff_kb) | ${cache_pct}% | - |"
    echo "| 完全空闲 | $free_kb_val | $(ss::hr_kb $free_kb_val) | - | - |"
    echo "| 共享内存 | $shared_kb | $(ss::hr_kb $shared_kb) | - | - |"
    echo ""
fi

# ==============================================================================
# 5. Swap 使用情况
# ==============================================================================

ss::progress 5 12 "Swap 使用情况"
echo "## 5. Swap 使用情况"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS swap: sysctl vm.swapusage
    SWAP_INFO=$(sysctl vm.swapusage 2>/dev/null)
    if [ -n "$SWAP_INFO" ]; then
        # 格式: vm.swapusage: total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)
        # macOS grep 不支持 -P，改用 awk
        swap_total=$(echo "$SWAP_INFO" | awk -F'total = ' '{print $2}' | awk '{print $1}')
        swap_used=$(echo "$SWAP_INFO" | awk -F'used = ' '{print $2}' | awk '{print $1}')
        swap_free=$(echo "$SWAP_INFO" | awk -F'free = ' '{print $2}' | awk '{print $1}')

        # 简单判断是否使用
        if echo "$SWAP_INFO" | grep -q "used = 0.00M"; then
            swap_status="🟢 未使用 - 内存充足"
        else
            swap_status="🟡 已使用 - 曾发生内存交换"
        fi

        echo "| 指标 | 数值 | 状态 |"
        echo "|------|------|------|"
        echo "| Swap 总量 | ${swap_total} | - |"
        echo "| Swap 已用 | ${swap_used} | - |"
        echo "| Swap 空闲 | ${swap_free} | $swap_status |"
        echo ""
    else
        echo "> ℹ️ 无法获取 macOS Swap 信息"
        echo ""
    fi
else
    # Linux Swap
    swap_line=$(free -k | grep '^Swap:')
    swap_total=$(echo "$swap_line" | awk '{print $2}')
    swap_used=$(echo "$swap_line" | awk '{print $3}')
    swap_free=$(echo "$swap_line" | awk '{print $4}')

    if [ "$swap_total" -eq 0 ]; then
        echo "> ⚠️ **未配置 Swap**。内存耗尽时将触发 OOM Killer 直接杀死进程，建议配置适量 Swap。"
        echo ""
    else
        swap_pct=$(awk "BEGIN {printf \"%.2f\", $swap_used/$swap_total*100}")
        if [ "$swap_used" -gt 0 ]; then
            swap_status="🟡 已使用 ${swap_pct}% - 曾发生内存交换"
        else
            swap_status="🟢 未使用 - 内存充足"
        fi

        echo "| 指标 | 数值 (KB) | 人类可读 | 使用率 | 状态 |"
        echo "|------|-----------|----------|--------|------|"
        echo "| Swap 总量 | $swap_total | $(ss::hr_kb $swap_total) | 100% | - |"
        echo "| Swap 已用 | $swap_used | $(ss::hr_kb $swap_used) | ${swap_pct}% | $swap_status |"
        echo "| Swap 空闲 | $swap_free | $(ss::hr_kb $swap_free) | - | - |"
        echo ""
    fi
fi

# ==============================================================================
# 6. 内存压力与 OOM 风险 (Linux 详细 / macOS 简化)
# ==============================================================================

ss::progress 6 12 "内存压力与 OOM 风险"
echo "## 6. 内存压力与 OOM 风险"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "> ℹ️ macOS 不提供 /proc/meminfo 等价物，以下为 vm_stat 关键指标"
    echo ""
    echo "| 指标 | 数值 (KB) | 说明 |"
    echo "|------|-----------|------|"
    echo "| MemTotal | $TOTAL_KB | 物理内存总量 |"
    echo "| MemAvailable (估算) | $avail_kb | free + inactive 页面 |"
    echo "| MemFree | $free_kb | 完全空闲页 |"
    echo "| Active | $active_kb | 活跃内存页 |"
    echo "| Inactive | $inactive_kb | 非活跃内存页（优先回收） |"
    echo "| Wired | $wired_kb | 锁定内存（无法交换） |"
    echo "| Compressed | $compressed_kb | 被压缩的内存页 |"
    echo ""

    # macOS 内存压力
    MEM_PRESSURE=$(ss::read_sysctl "kern.memorystatus_vm_pressure_level")
    echo "### macOS 内存压力级别"
    echo ""
    echo "| 级别 | 数值 | 含义 |"
    echo "|------|------|------|"
    if [ "$MEM_PRESSURE" = "1" ]; then
        echo "| 压力级别 | 1 | 🟢 正常 |"
    elif [ "$MEM_PRESSURE" = "2" ]; then
        echo "| 压力级别 | 2 | 🟡 警告 - 开始压缩内存 |"
    elif [ "$MEM_PRESSURE" = "4" ]; then
        echo "| 压力级别 | 4 | 🔴 紧急 - 可能触发 OOM |"
    else
        echo "| 压力级别 | ${MEM_PRESSURE} | - |"
    fi
    echo ""
else
    # Linux /proc/meminfo 详细
    read_meminfo() {
        grep "^$1:" /proc/meminfo 2>/dev/null | awk '{print $2}'
    }

    mem_total=$(read_meminfo "MemTotal")
    mem_free=$(read_meminfo "MemFree")
    mem_avail=$(read_meminfo "MemAvailable")
    mem_buffers=$(read_meminfo "Buffers")
    mem_cached=$(read_meminfo "Cached")
    mem_sreclaimable=$(read_meminfo "SReclaimable")
    mem_active=$(read_meminfo "Active")
    mem_inactive=$(read_meminfo "Inactive")
    mem_dirty=$(read_meminfo "Dirty")
    mem_writeback=$(read_meminfo "Writeback")
    mem_anon=$(read_meminfo "AnonPages")
    mem_mapped=$(read_meminfo "Mapped")
    mem_shmem=$(read_meminfo "Shmem")
    mem_slab=$(read_meminfo "Slab")
    mem_commit=$(read_meminfo "Committed_AS")

    reclaimable=$((mem_buffers + mem_cached + mem_sreclaimable))

    echo "| 指标 | 数值 (KB) | 说明 |"
    echo "|------|-----------|------|"
    echo "| MemTotal | $mem_total | 物理内存总量 |"
    echo "| MemAvailable | $mem_avail | 真正可用内存（含可回收缓存） |"
    echo "| MemFree | $mem_free | 完全未使用内存 |"
    echo "| Buffers | $mem_buffers | 块设备缓存 |"
    echo "| Cached | $mem_cached | 文件页缓存 |"
    echo "| SReclaimable | $mem_sreclaimable | 可回收 Slab |"
    echo "| 可回收缓存合计 | $reclaimable | Buffers+Cached+SReclaimable |"
    echo "| Active | $mem_active | 活跃内存页 |"
    echo "| Inactive | $mem_inactive | 非活跃内存页（优先回收） |"
    echo "| AnonPages | $mem_anon | 匿名内存（进程堆栈等，需 Swap 才能释放） |"
    echo "| Mapped | $mem_mapped | 文件映射内存 |"
    echo "| Shmem | $mem_shmem | 共享内存 / tmpfs |"
    echo "| Slab | $mem_slab | 内核对象缓存 |"
    echo "| Dirty | $mem_dirty | 待写回磁盘的脏页 |"
    echo "| Writeback | $mem_writeback | 正在写回磁盘的页 |"
    echo "| Committed_AS | $mem_commit | 系统承诺分配的虚拟内存总量 |"
    echo ""

    # OOM 风险评估（仅 Linux 提供 /proc/sys/vm/overcommit_*）
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo "### OOM 风险评估"
        echo ""
        echo "> ℹ️ macOS 采用不同内存管理模型，无 Linux overcommit 机制，本节跳过。"
        echo ""
    else
        oom_score_adj=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo "N/A")
        ratio=$(cat /proc/sys/vm/overcommit_ratio 2>/dev/null || echo "N/A")

        echo "### OOM 风险评估"
        echo ""
        echo "| 指标 | 数值 | 说明 |"
        echo "|------|------|------|"
        echo "| overcommit_memory | $oom_score_adj | 0=启发式 1=始终允许 2=严格限制 |"
        echo "| overcommit_ratio | $ratio% | 可超量提交的百分比 |"
        echo ""
    fi

    if [ "$oom_score_adj" = "2" ]; then
        echo "> ℹ️ 当前为严格内存限制模式 (overcommit_memory=2)，内存分配失败率较高"
        echo ""
    elif [ "$oom_score_adj" = "1" ]; then
        echo "> ⚠️ 当前为始终允许模式 (overcommit_memory=1)，OOM 风险最高"
        echo ""
    else
        echo "> ℹ️ 当前为启发式模式 (overcommit_memory=0)，根据请求大小判断是否允许"
        echo ""
    fi
fi

# ==============================================================================
# 7. 进程状态分布
# ==============================================================================

ss::progress 7 12 "进程状态分布"
echo "## 7. 进程状态分布"
echo ""
echo "> **关键指标:** D 状态进程多 = 磁盘 IO 瓶颈；Z 状态进程 > 0 = 应用 Bug"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS ps 状态码与 Linux 不同，需要映射
    # macOS 常见状态: S(sleeping), R(running), T(stopped), Z(zombie), I(idle), U(uninterruptible wait)
    echo "| 状态 | 数量 | 含义 | 评估 |"
    echo "|------|------|------|------|"

    ps ax -o stat= 2>/dev/null | awk '{
        stat = substr($1, 1, 1)
        count[stat]++
    } END {
        for (s in count) {
            meaning = ""
            eval = ""
            if (s == "R") { meaning = "运行中"; eval = "✅ 正常"; }
            else if (s == "S") { meaning = "睡眠(可中断)"; eval = "✅ 正常"; }
            else if (s == "U") { meaning = "不可中断等待"; eval = "🟡 关注"; }
            else if (s == "T") { meaning = "已停止"; eval = "⚪ 调试中"; }
            else if (s == "Z") { meaning = "僵尸进程"; eval = "🔴 需处理"; }
            else if (s == "I") { meaning = "空闲"; eval = "✅ 正常"; }
            else { meaning = "其他"; eval = "-"; }
            printf "| %s | %d | %s | %s |\n", s, count[s], meaning, eval
        }
    }'
    echo ""

    # macOS 僵尸进程
    z_count=$(ps ax -o stat= 2>/dev/null | grep -c '^Z')
    if [ "$z_count" -gt 0 ]; then
        echo "### Z 状态进程详情 (僵尸进程)"
        echo ""
        echo "| PID | PPID | 用户 | 命令 |"
        echo "|-----|------|------|------|"
        ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="Z" {printf "| %s | %s | %s | %s |\n", $2, $3, $1, $11}'
        echo ""
        echo "> ⚠️ 存在 $z_count 个僵尸进程，建议检查其父进程是否异常退出"
        echo ""
    fi
else
    # Linux 进程状态
    echo "| 状态 | 数量 | 含义 | 评估 |"
    echo "|------|------|------|------|"
    ps aux 2>/dev/null | awk 'NR>1 {
        stat = substr($8, 1, 1)
        count[stat]++
    } END {
        for (s in count) {
            meaning = ""
            eval = ""
            if (s == "R") { meaning = "运行中"; eval = "✅ 正常"; }
            else if (s == "S") { meaning = "睡眠(可中断)"; eval = "✅ 正常"; }
            else if (s == "D") { meaning = "不可中断睡眠(IO等待)"; eval = "🟡 关注"; }
            else if (s == "T") { meaning = "已停止"; eval = "⚪ 调试中"; }
            else if (s == "Z") { meaning = "僵尸进程"; eval = "🔴 需处理"; }
            else if (s == "I") { meaning = "空闲(内核线程)"; eval = "✅ 正常"; }
            else { meaning = "其他"; eval = "-"; }
            printf "| %s | %d | %s | %s |\n", s, count[s], meaning, eval
        }
    }'
    echo ""

    # D 状态进程
    d_count=$(ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="D" {count++} END {print count+0}')
    if [ "$d_count" -gt 0 ]; then
        echo "### D 状态进程详情 (IO 等待)"
        echo ""
        echo "| PID | 用户 | CPU% | MEM% | 命令 |"
        echo "|-----|------|------|------|------|"
        ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="D" {printf "| %s | %s | %s | %s | %s |\n", $2, $1, $3, $4, $11}'
        echo ""
    fi

    # Z 状态进程
    z_count=$(ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="Z" {count++} END {print count+0}')
    if [ "$z_count" -gt 0 ]; then
        echo "### Z 状态进程详情 (僵尸进程)"
        echo ""
        echo "| PID | PPID | 用户 | 命令 |"
        echo "|-----|------|------|------|"
        ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="Z" {printf "| %s | %s | %s | %s |\n", $2, $3, $1, $11}'
        echo ""
        echo "> ⚠️ 存在 $z_count 个僵尸进程，建议检查其父进程是否异常退出"
        echo ""
    fi
fi

# ==============================================================================
# 8. 上下文切换与中断统计 (Linux 原生 / macOS 近似)
# ==============================================================================

ss::progress 8 12 "上下文切换与中断统计"
echo "## 8. 上下文切换与中断统计"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS 通过 netstat -s 获取近似值
    CTXT_TOTAL=$(netstat -s 2>/dev/null | grep -i "context switch" | head -1 | awk '{print $1}')
    INTR_TOTAL=$(netstat -s 2>/dev/null | grep -i "interrupt" | head -1 | awk '{print $1}')

    echo "> ℹ️ macOS 通过 netstat 近似统计，部分指标可能无法精确获取"
    echo ""
    echo "| 指标 | 累计值 | 说明 |"
    echo "|------|--------|------|"
    echo "| 上下文切换 | ${CTXT_TOTAL:-N/A} | 近似值 (netstat) |"
    echo "| 中断 | ${INTR_TOTAL:-N/A} | 近似值 (netstat) |"
    echo ""
else
    # Linux /proc/stat
    ctxt_total=$(grep '^ctxt ' /proc/stat | awk '{print $2}')
    intr_total=$(grep '^intr ' /proc/stat | awk '{print $2}')
    processes_total=$(grep '^processes ' /proc/stat | awk '{print $2}')
    softirq_total=$(grep '^softirq ' /proc/stat | awk '{print $2}')

    uptime_sec=$(awk '{print int($1)}' /proc/uptime)

    if [ "$uptime_sec" -gt 0 ]; then
        ctxt_rate=$(awk "BEGIN {printf \"%.2f\", $ctxt_total / $uptime_sec}")
        intr_rate=$(awk "BEGIN {printf \"%.2f\", $intr_total / $uptime_sec}")
        proc_rate=$(awk "BEGIN {printf \"%.2f\", $processes_total / $uptime_sec}")
    fi

    echo "> **评估标准:** 上下文切换率 > 50k/s 偏高，> 100k/s 需优化进程模型"
    echo ""
    echo "| 指标 | 累计值 | 每秒平均 |"
    echo "|------|--------|----------|"
    echo "| 上下文切换 (ctxt) | $ctxt_total | ${ctxt_rate:-N/A} |"
    echo "| 硬件中断 (intr) | $intr_total | ${intr_rate:-N/A} |"
    echo "| 软中断 (softirq) | $softirq_total | - |"
    echo "| 进程创建 (fork) | $processes_total | ${proc_rate:-N/A} |"
    echo "| 系统运行时间 | ${uptime_sec}s | - |"
    echo ""
fi

# ==============================================================================
# 9. Top 资源消耗进程
# ==============================================================================

ss::progress 9 12 "Top 资源消耗进程"
echo "## 9. Top 资源消耗进程"
echo ""

# CPU Top 10
echo "### CPU 占用 Top 10"
echo ""
echo "| PID | 用户 | CPU% | MEM% | VSZ (KB) | RSS (KB) | 状态 | 命令 |"
echo "|-----|------|------|------|----------|----------|------|------|"

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS ps aux 格式: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND
    ps aux -r 2>/dev/null | head -11 | tail -10 | awk '{
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",
        $2, $1, $3, $4, $5, $6, $8, $11
    }'
else
    ps aux --sort=-%cpu 2>/dev/null | head -11 | tail -10 | awk '{
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",
        $2, $1, $3, $4, $5, $6, $8, $11
    }'
fi
echo ""

# 内存 Top 10
echo "### 内存占用 Top 10 (按 RSS 物理内存)"
echo ""
echo "| PID | 用户 | CPU% | MEM% | VSZ (KB) | RSS (KB) | 状态 | 命令 |"
echo "|-----|------|------|------|----------|----------|------|------|"

if [ "$OS_TYPE" = "Darwin" ]; then
    ps aux -m 2>/dev/null | head -11 | tail -10 | awk '{
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",
        $2, $1, $3, $4, $5, $6, $8, $11
    }'
else
    ps aux --sort=-%mem 2>/dev/null | head -11 | tail -10 | awk '{
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",
        $2, $1, $3, $4, $5, $6, $8, $11
    }'
fi
echo ""

# ==============================================================================
# 10. 系统句柄与限制
# ==============================================================================

ss::progress 10 12 "系统句柄与限制"
echo "## 10. 系统句柄与限制"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS 句柄统计
    KERN_FILES=$(ss::read_sysctl "kern.num_files")
    KERN_MAXFILES=$(ss::read_sysctl "kern.maxfiles")
    KERN_MAXPROC=$(ss::read_sysctl "kern.maxproc")

    if [ "$KERN_MAXFILES" != "N/A" ] && [ "$KERN_MAXFILES" -gt 0 ]; then
        file_pct=$(awk "BEGIN {printf \"%.2f\", $KERN_FILES/$KERN_MAXFILES*100}")
        pct_int=${file_pct%.*}
        if [ "$pct_int" -gt 90 ]; then
            file_status="🔴 危险"
        elif [ "$pct_int" -gt 80 ]; then
            file_status="🟡 偏高"
        else
            file_status="🟢 正常"
        fi
    else
        file_pct="N/A"
        file_status="-"
    fi

    echo "| 指标 | 数值 | 使用率 | 状态 |"
    echo "|------|------|--------|------|"
    echo "| 已打开文件数 | $KERN_FILES | - | - |"
    echo "| 系统文件上限 | $KERN_MAXFILES | ${file_pct}% | $file_status |"
    echo "| 系统进程上限 | $KERN_MAXPROC | - | - |"
    echo ""

    echo "> ℹ️ macOS 不支持按进程统计句柄数（无 /proc/PID/fd），建议使用 \`lsof -p PID | wc -l\` 手动检查"
    echo ""
else
    # Linux 句柄
    file_nr=$(cat /proc/sys/fs/file-nr 2>/dev/null)
    file_allocated=$(echo "$file_nr" | awk '{print $1}')
    file_unused=$(echo "$file_nr" | awk '{print $2}')
    file_max=$(echo "$file_nr" | awk '{print $3}')

    if [ "$file_max" -gt 0 ]; then
        file_pct=$(awk "BEGIN {printf \"%.2f\", $file_allocated/$file_max*100}")
        if [ "${file_pct%.*}" -gt 80 ]; then
            file_status="🟡 偏高"
        elif [ "${file_pct%.*}" -gt 90 ]; then
            file_status="🔴 危险"
        else
            file_status="🟢 正常"
        fi
    else
        file_pct="N/A"
        file_status="-"
    fi

    proc_max=$(cat /proc/sys/fs/nr_open 2>/dev/null || echo "N/A")

    echo "| 指标 | 数值 | 使用率 | 状态 |"
    echo "|------|------|--------|------|"
    echo "| 已分配句柄 | $file_allocated | - | - |"
    echo "| 未使用句柄 | $file_unused | - | - |"
    echo "| 系统句柄上限 | $file_max | ${file_pct}% | $file_status |"
    echo "| 单进程句柄上限 (nr_open) | $proc_max | - | - |"
    echo ""

    # 进程句柄 Top 5
    echo "### 进程句柄使用 Top 5"
    echo ""
    echo "| PID | 用户 | 句柄数 | 命令 |"
    echo "|-----|------|--------|------|"
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        if [ -d "/proc/$pid/fd" ]; then
            count=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
            cmd=$(cat /proc/$pid/comm 2>/dev/null | tr '\n' ' ')
            user=$(ps -o user= -p $pid 2>/dev/null | tr -d ' ')
            echo "$count $pid $user $cmd"
        fi
    done | sort -rn | head -5 | awk '{
        printf "| %s | %s | %s | %s |\n", $2, $3, $1, $4
    }'
    echo ""
fi

# ==============================================================================
# 11. 内核内存 (Slab) - Linux 专属
# ==============================================================================

if [ "$OS_TYPE" != "Darwin" ]; then
    ss::progress 11 12 "内核内存 (Slab) 详情"
    echo "## 11. 内核内存 (Slab) 详情"
    echo ""

    sunreclaim=$(grep "^SUnreclaim:" /proc/meminfo 2>/dev/null | awk '{print $2}')

    echo "| 指标 | 数值 (KB) | 说明 |"
    echo "|------|-----------|------|"
    echo "| Slab (总量) | $mem_slab | 内核对象缓存总量 |"
    echo "| SReclaimable | $mem_sreclaimable | 可回收 Slab |"
    echo "| SUnreclaim | $sunreclaim | 不可回收 Slab |"
    echo ""

    if command -v slabtop &>/dev/null; then
        echo "### Slab 占用 Top 10"
        echo ""
        echo "| 对象名 | 活跃数 | 总数量 | 单个大小 | 总大小 |"
        echo "|--------|--------|--------|----------|--------|"
        slabtop -s c -o 2>/dev/null | tail -n +8 | head -10 | awk '{
            printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5
        }'
        echo ""
    fi
fi

# ==============================================================================
# 12. 负载趋势分析
# ==============================================================================

ss::progress 12 12 "负载趋势分析"
echo "## 12. 负载趋势分析"
echo ""

echo "> **趋势判断:**"
if command -v bc &>/dev/null && [ -n "$load1" ] && [ -n "$load5" ] && [ -n "$load15" ]; then
    if (($(echo "$load1 > $load5" | bc -l))) && (($(echo "$load5 > $load15" | bc -l))); then
        echo "> 📈 **负载呈上升趋势** — 系统越来越忙"
    elif (($(echo "$load1 < $load5" | bc -l))) && (($(echo "$load5 < $load15" | bc -l))); then
        echo "> 📉 **负载呈下降趋势** — 系统正在恢复"
    else
        echo "> ➡️ **负载相对平稳** — 无明显趋势"
    fi
else
    echo "> ⚪ 未安装 bc 或负载数据不完整，无法计算趋势"
fi
echo ""

echo "| 时间窗口 | 负载值 | 与核心数比值 |"
echo "|----------|--------|--------------|"
if command -v bc &>/dev/null && [ "$CORES" != "N/A" ] && [ -n "$CORES" ] &&
    [ -n "$load1" ] && [ -n "$load5" ] && [ -n "$load15" ]; then
    ratio1=$(printf "%.2f" "$(echo "scale=2; $load1 / $CORES" | bc -l)")
    ratio5=$(printf "%.2f" "$(echo "scale=2; $load5 / $CORES" | bc -l)")
    ratio15=$(printf "%.2f" "$(echo "scale=2; $load15 / $CORES" | bc -l)")
    echo "| 1分钟 | $load1 | ${ratio1} |"
    echo "| 5分钟 | $load5 | ${ratio5} |"
    echo "| 15分钟 | $load15 | ${ratio15} |"
    echo "| 逻辑核心数 | $CORES | 基准线 |"
else
    echo "| 1分钟 | $load1 | - |"
    echo "| 5分钟 | $load5 | - |"
    echo "| 15分钟 | $load15 | - |"
    echo "| 逻辑核心数 | $CORES | 基准线 |"
fi
echo ""

# ==============================================================================
# 报告尾部
# ==============================================================================

echo "---"
echo ""
echo "## 附录：分析建议"
echo ""
echo "将此报告粘贴给大模型时，可附加以下提示词："
echo ""
echo '```'
echo "请分析以下 CPU/内存 报告，重点关注："
echo "1. CPU 负载与核心数比值是否合理，wa(IO等待)是否过高"
echo "2. 内存 available 是否充足，Swap 是否被使用"
echo "3. 是否存在僵尸进程或大量 D/U 状态进程"
echo "4. 上下文切换率是否异常偏高"
echo "5. 哪些进程是 CPU/内存 消耗大户，是否存在内存泄漏嫌疑"
echo "6. 文件句柄使用率是否接近上限"
echo "7. 给出具体的优化建议或扩容方案"
echo '```'
echo ""
echo "> 📄 **报告已保存至:** \`$REPORT_PATH\`"

# 报告结束
ss::report_end "$REPORT_PATH"

# JSON 输出
if [ "$JSON_OUTPUT" = "true" ]; then
    summary="CPU/内存深度分析完成"
    ss::print_json_metadata "success" "$REPORT_PATH" "cpu_mem_analyzer.sh" 0 "$summary" ""
fi

# 显式退出码
exit 0

# ==============================================================================
# 使用说明:
# 1. 直接运行: ./cpu_mem_analyzer.sh
#    输出同时显示在终端并写入 Markdown 文件
# 2. 自定义输出路径: ./cpu_mem_analyzer.sh -o /var/log/report.md
# 3. Linux 下开启多核采样: ./cpu_mem_analyzer.sh (默认已开启)
# 4. 禁用多核采样: ./cpu_mem_analyzer.sh --no-mpstat
# 5. 自定义采样间隔和次数: ./cpu_mem_analyzer.sh --interval 2 --count 5
# 6. 静默模式: ./cpu_mem_analyzer.sh --quiet
# 7. JSON 输出: ./cpu_mem_analyzer.sh --json
# 8. 配合 crontab 定时执行: 0 * * * * /path/to/cpu_mem_analyzer.sh
# ==============================================================================
