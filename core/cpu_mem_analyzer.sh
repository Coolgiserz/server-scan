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
# 留空表示使用默认产物路径（$OUTPUT_DIR/cpu_mem/），
# 可通过 -o 参数或 REPORT_PATH 环境变量覆盖
REPORT_PATH="${REPORT_PATH:-}"
ENABLE_MPSTAT="true" # Linux 下有效，macOS 自动忽略
SAMPLE_INTERVAL=1
SAMPLE_COUNT=3

# 获取项目根目录（脚本位于 core/ 子目录，根目录为其上一级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
            ss::log_error "$(ss::msg MSG_CPU_MEM_ERR_INTERVAL)"
            exit 2
        fi
        ;;
    --count)
        if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
            SAMPLE_COUNT="$2"
            shift 2
        else
            ss::log_error "$(ss::msg MSG_CPU_MEM_ERR_COUNT)"
            exit 2
        fi
        ;;
    -h | --help)
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_CPU_MEM_HELP_DESC)" "  --no-mpstat           $(ss::msg MSG_CPU_MEM_HELP_NO_MPSTAT)
  --interval N          $(ss::msg MSG_CPU_MEM_HELP_INTERVAL)
  --count N             $(ss::msg MSG_CPU_MEM_HELP_COUNT)"
        exit 0
        ;;
    *)
        # 忽略其他参数
        shift
        ;;
    esac
done

# 未通过 -o 指定时，使用默认产物路径（$OUTPUT_DIR/cpu_mem/）
if [ -z "$REPORT_PATH" ]; then
    REPORT_PATH="$(ss::default_report_path cpu_mem)"
fi

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
ss::report_begin "$(ss::msg MSG_CPU_MEM_REPORT_TITLE)" 12

# ==============================================================================
# OS 检测与基础信息
# ==============================================================================

echo "# $(ss::msg MSG_CPU_MEM_TITLE)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
    ARCH="$(uname -m)"
    UPTIME_INFO=$(uptime | sed 's/^.*up *//; s/, *[0-9]* user.*//; s/ day(s)/天/; s/ hour(s)/小时/; s/ minute(s)/分钟/')
    echo "> **$(ss::msg MSG_COMMON_OS):** macOS ${OS_NAME}  "
    echo "> **$(ss::msg MSG_CPU_MEM_ROW_ARCH):** ${ARCH}  "
else
    OS_NAME="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Linux')"
    ARCH="$(uname -m)"
    UPTIME_INFO=$(uptime -p 2>/dev/null || uptime | awk -F',' '{print $1}')
    echo "> **$(ss::msg MSG_COMMON_OS):** ${OS_NAME}  "
    echo "> **$(ss::msg MSG_CPU_MEM_ROW_ARCH):** ${ARCH}  "
fi

echo "> **$(ss::msg MSG_COMMON_HOSTNAME):** $(hostname)  "
echo "> **$(ss::msg MSG_COMMON_COLLECT_TIME):** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **$(ss::msg MSG_COMMON_KERNEL):** $(uname -r)  "
echo "> **$(ss::msg MSG_CPU_MEM_ROW_UPTIME):** ${UPTIME_INFO}  "
echo ""
echo "---"
echo ""

# ==============================================================================
# 1. CPU 基础信息
# ==============================================================================

ss::progress 1 12 "$(ss::msg MSG_CPU_MEM_SECTION_CPU_INFO)"
echo "## 1. $(ss::msg MSG_CPU_MEM_SECTION_CPU_INFO)"
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

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) |"
    echo "|------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_CPU_MODEL) | ${CPU_MODEL} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_PHY_CORES) | ${PHY_CORES} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_LOGIC_CORES) | ${LOGIC_CORES} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_THREADS) | ${THREADS_PER_CORE} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_BASE_FREQ) | ${CPU_FREQ_MHZ} MHz |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_L2_CACHE) | $(ss::hr_bytes ${L2_CACHE}) |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_L3_CACHE) | $(ss::hr_bytes ${L3_CACHE}) |"
    echo ""
else
    # Linux CPU 信息
    model=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    phy_cores=$(grep 'cpu cores' /proc/cpuinfo | head -1 | awk '{print $4}')
    logic_cores=$(nproc)
    siblings=$(grep 'siblings' /proc/cpuinfo | head -1 | awk '{print $3}')
    cache=$(grep 'cache size' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    flags=$(grep 'flags' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs | tr ' ' '\n' | grep -E 'vmx|svm|aes|avx|sse4' | tr '\n' ',' | sed 's/,$//')

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) |"
    echo "|------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_CPU_MODEL) | ${model:-N/A} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_PHY_CORES) | ${phy_cores:-N/A} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_LOGIC_CORES) | ${logic_cores:-N/A} |"
    if [ -n "$phy_cores" ] && [ "$phy_cores" -gt 0 ] && [ -n "$siblings" ]; then
        threads_per_core=$((siblings / phy_cores))
    else
        threads_per_core="N/A"
    fi
    echo "| $(ss::msg MSG_CPU_MEM_ROW_THREADS) | ${threads_per_core} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_CACHE) | ${cache:-N/A} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_FLAGS) | ${flags:-N/A} |"

    # CPU 频率
    min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    cur_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    if [ -n "$max_freq" ]; then
        echo "| $(ss::msg MSG_CPU_MEM_ROW_MIN_FREQ) | ${min_freq} MHz |"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_MAX_FREQ) | ${max_freq} MHz |"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_CUR_FREQ) | ${cur_freq} MHz |"
    fi
    echo ""
fi

# ==============================================================================
# 2. CPU 负载与使用率
# ==============================================================================

ss::progress 2 12 "$(ss::msg MSG_CPU_MEM_SECTION_LOAD)"
echo "## 2. $(ss::msg MSG_CPU_MEM_SECTION_LOAD)"
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
        load_eval="$(ss::msg MSG_STATUS_DANGER)"
    elif (($(echo "$load1 > $threshold_busy" | bc -l))); then
        load_eval="$(ss::msg MSG_STATUS_BUSY)"
    else
        load_eval="$(ss::msg MSG_STATUS_HEALTHY)"
    fi
else
    load_eval="⚪ 未安装 bc，无法精确评估"
fi

echo "> **$(ss::msg MSG_CPU_MEM_LABEL_EVAL_CRITERIA):** $(ss::msg MSG_CPU_MEM_CRITERIA_LOAD)"
echo ""
echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_EVAL) |"
echo "|------|------|------|"
echo "| $(ss::msg MSG_CPU_MEM_ROW_LOAD1) | $load1 | $load_eval |"
echo "| $(ss::msg MSG_CPU_MEM_ROW_LOAD5) | $load5 | - |"
echo "| $(ss::msg MSG_CPU_MEM_ROW_LOAD15) | $load15 | - |"
echo ""

echo "### CPU 时间分布 (top 快照)"
echo ""
echo "> **$(ss::msg MSG_CPU_MEM_KEY_INDICATOR):** $(ss::msg MSG_CPU_MEM_KEY_INDICATOR_WA)"
echo ""
echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_CPU_MEM_DESC) | $(ss::msg MSG_TABLE_STATUS) |"
echo "|------|------|------|------|"

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "| us (用户态) | ${us}% | 应用程序消耗 | - |"
    echo "| sy (系统态) | ${sy}% | 内核消耗 | - |"
    echo "| id (空闲) | ${id}% | CPU 空闲率 | - |"
    echo "| ni/wa/hi/si/st | N/A | macOS top 不拆分 | - |"
    echo ""
    echo "> ℹ️ $(ss::msg MSG_CPU_MEM_NOTE_MAC_TIME)"
    echo ""
else
    wa_num=$(echo "$wa" | awk '{printf "%d", $1}')
    if [ "$wa_num" -gt 20 ]; then wa_status="$(ss::msg MSG_STATUS_BOTTLENECK)"; elif [ "$wa_num" -gt 10 ]; then wa_status="$(ss::msg MSG_STATUS_HIGH)"; else wa_status="$(ss::msg MSG_STATUS_NORMAL)"; fi

    sy_num=$(echo "$sy" | awk '{printf "%d", $1}')
    if [ "$sy_num" -gt 20 ]; then sy_status="$(ss::msg MSG_STATUS_ABNORMAL)"; elif [ "$sy_num" -gt 10 ]; then sy_status="$(ss::msg MSG_STATUS_HIGH)"; else sy_status="$(ss::msg MSG_STATUS_NORMAL)"; fi

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
    ss::progress 3 12 "$(ss::msg MSG_CPU_MEM_SECTION_MPSTAT)"
    echo "## 3. $(ss::msg MSG_CPU_MEM_SECTION_MPSTAT)"
    echo ""
    echo "> **$(ss::msg MSG_CPU_MEM_DESC):** $(ss::msgf MSG_CPU_MEM_DESC_SAMPLING "${SAMPLE_COUNT}" "${SAMPLE_INTERVAL}")"
    echo ""
    echo "| CPU | usr% | sys% | iowait% | idle% | $(ss::msg MSG_TABLE_EVAL) |"
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

ss::progress 4 12 "$(ss::msg MSG_CPU_MEM_SECTION_MEM)"
echo "## 4. $(ss::msg MSG_CPU_MEM_SECTION_MEM)"
echo ""
echo "> **$(ss::msg MSG_CPU_MEM_LABEL_EVAL_CRITERIA):** $(ss::msg MSG_CPU_MEM_CRITERIA_MEM)"
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
        mem_status="$(ss::msg MSG_STATUS_INSUFFICIENT)"
    else
        mem_status="$(ss::msg MSG_STATUS_SUFFICIENT)"
    fi

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) (KB) | $(ss::msg MSG_TABLE_HUMAN_READABLE) | $(ss::msg MSG_TABLE_RATIO) | $(ss::msg MSG_TABLE_STATUS) |"
    echo "|------|-----------|----------|------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_TOTAL_MEM) | $TOTAL_KB | $(ss::hr_kb $TOTAL_KB) | 100% | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_USED_EST) | $used_kb | $(ss::hr_kb $used_kb) | ${used_pct}% | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_AVAIL) | $avail_kb | $(ss::hr_kb $avail_kb) | ${avail_pct}% | $mem_status |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_ACTIVE) | $active_kb | $(ss::hr_kb $active_kb) | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_FREE_PAGE) | $free_kb | $(ss::hr_kb $free_kb) | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_INACTIVE_PAGE) | $inactive_kb | $(ss::hr_kb $inactive_kb) | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_WIRED) | $wired_kb | $(ss::hr_kb $wired_kb) | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_COMPRESSED) | $compressed_kb | $(ss::hr_kb $compressed_kb) | - | - |"
    echo ""

    echo "> ℹ️ $(ss::msg MSG_CPU_MEM_NOTE_MAC_MEM)"
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
        mem_status="$(ss::msg MSG_STATUS_INSUFFICIENT)"
    elif [ "$avail_num" -lt 10 ]; then
        mem_status="$(ss::msg MSG_STATUS_TENSE)"
    else
        mem_status="$(ss::msg MSG_STATUS_SUFFICIENT)"
    fi

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) (KB) | $(ss::msg MSG_TABLE_HUMAN_READABLE) | $(ss::msg MSG_TABLE_RATIO) | $(ss::msg MSG_TABLE_STATUS) |"
    echo "|------|-----------|----------|------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_TOTAL_MEM) | $total_kb | $(ss::hr_kb $total_kb) | 100% | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_USED) | $used_kb | $(ss::hr_kb $used_kb) | ${used_pct}% | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_AVAIL_LNX) | $avail_kb | $(ss::hr_kb $avail_kb) | ${avail_pct}% | $mem_status |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_CACHE_BUF) | $buff_kb | $(ss::hr_kb $buff_kb) | ${cache_pct}% | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_FULL_FREE) | $free_kb_val | $(ss::hr_kb $free_kb_val) | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_SHARED) | $shared_kb | $(ss::hr_kb $shared_kb) | - | - |"
    echo ""
fi

# ==============================================================================
# 5. Swap 使用情况
# ==============================================================================

ss::progress 5 12 "$(ss::msg MSG_CPU_MEM_SECTION_SWAP)"
echo "## 5. $(ss::msg MSG_CPU_MEM_SECTION_SWAP)"
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
            swap_status="$(ss::msg MSG_CPU_MEM_SWAP_UNUSED)"
        else
            swap_status="$(ss::msg MSG_CPU_MEM_SWAP_USED_MAC)"
        fi

        echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_STATUS) |"
        echo "|------|------|------|"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_SWAP_TOTAL) | ${swap_total} | - |"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_SWAP_USED) | ${swap_used} | - |"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_SWAP_FREE) | ${swap_free} | $swap_status |"
        echo ""
    else
        echo "> ℹ️ $(ss::msg MSG_CPU_MEM_NOTE_MAC_SWAP)"
        echo ""
    fi
else
    # Linux Swap
    swap_line=$(free -k | grep '^Swap:')
    swap_total=$(echo "$swap_line" | awk '{print $2}')
    swap_used=$(echo "$swap_line" | awk '{print $3}')
    swap_free=$(echo "$swap_line" | awk '{print $4}')

    if [ "$swap_total" -eq 0 ]; then
        echo "> $(ss::msg MSG_CPU_MEM_SWAP_NOT_CONFIGURED)"
        echo ""
    else
        swap_pct=$(awk "BEGIN {printf \"%.2f\", $swap_used/$swap_total*100}")
        if [ "$swap_used" -gt 0 ]; then
            swap_status="$(ss::msgf MSG_CPU_MEM_SWAP_USED "${swap_pct}")"
        else
            swap_status="$(ss::msg MSG_CPU_MEM_SWAP_UNUSED)"
        fi

        echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) (KB) | $(ss::msg MSG_TABLE_HUMAN_READABLE) | $(ss::msg MSG_CPU_MEM_LABEL_USAGE_RATE) | $(ss::msg MSG_TABLE_STATUS) |"
        echo "|------|-----------|----------|--------|------|"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_SWAP_TOTAL) | $swap_total | $(ss::hr_kb $swap_total) | 100% | - |"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_SWAP_USED) | $swap_used | $(ss::hr_kb $swap_used) | ${swap_pct}% | $swap_status |"
        echo "| $(ss::msg MSG_CPU_MEM_ROW_SWAP_FREE) | $swap_free | $(ss::hr_kb $swap_free) | - | - |"
        echo ""
    fi
fi

# ==============================================================================
# 6. 内存压力与 OOM 风险 (Linux 详细 / macOS 简化)
# ==============================================================================

ss::progress 6 12 "$(ss::msg MSG_CPU_MEM_SECTION_OOM)"
echo "## 6. $(ss::msg MSG_CPU_MEM_SECTION_OOM)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "> ℹ️ macOS 不提供 /proc/meminfo 等价物，以下为 vm_stat 关键指标"
    echo ""
    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) (KB) | $(ss::msg MSG_CPU_MEM_DESC) |"
    echo "|------|-----------|------|"
    echo "| MemTotal | $TOTAL_KB | $(ss::msg MSG_CPU_MEM_ROW_TOTAL_MEM) |"
    echo "| MemAvailable ($(ss::msg MSG_CPU_MEM_ROW_USED_EST)) | $avail_kb | free + inactive |"
    echo "| MemFree | $free_kb | $(ss::msg MSG_CPU_MEM_ROW_FULL_FREE) |"
    echo "| Active | $active_kb | $(ss::msg MSG_CPU_MEM_ROW_ACTIVE) |"
    echo "| Inactive | $inactive_kb | $(ss::msg MSG_CPU_MEM_ROW_INACTIVE_PAGE) |"
    echo "| Wired | $wired_kb | $(ss::msg MSG_CPU_MEM_ROW_WIRED) |"
    echo "| Compressed | $compressed_kb | $(ss::msg MSG_CPU_MEM_ROW_COMPRESSED) |"
    echo ""

    # macOS 内存压力
    MEM_PRESSURE=$(ss::read_sysctl "kern.memorystatus_vm_pressure_level")
    echo "### $(ss::msg MSG_CPU_MEM_NOTE_MAC_PRESSURE)"
    echo ""
    echo "| $(ss::msg MSG_CPU_MEM_LABEL_LEVEL) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_CPU_MEM_LABEL_MEANING) |"
    echo "|------|------|------|"
    if [ "$MEM_PRESSURE" = "1" ]; then
        echo "| 压力级别 | 1 | $(ss::msg MSG_CPU_MEM_PRESSURE_NORMAL) |"
    elif [ "$MEM_PRESSURE" = "2" ]; then
        echo "| 压力级别 | 2 | $(ss::msg MSG_CPU_MEM_PRESSURE_WARN) |"
    elif [ "$MEM_PRESSURE" = "4" ]; then
        echo "| 压力级别 | 4 | $(ss::msg MSG_CPU_MEM_PRESSURE_CRITICAL) |"
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

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) (KB) | $(ss::msg MSG_CPU_MEM_DESC) |"
    echo "|------|-----------|------|"
    echo "| MemTotal | $mem_total | $(ss::msg MSG_CPU_MEM_ROW_TOTAL_MEM) |"
    echo "| MemAvailable | $mem_avail | $(ss::msg MSG_CPU_MEM_ROW_AVAIL_LNX) |"
    echo "| MemFree | $mem_free | $(ss::msg MSG_CPU_MEM_ROW_FULL_FREE) |"
    echo "| Buffers | $mem_buffers | 块设备缓存 |"
    echo "| Cached | $mem_cached | 文件页缓存 |"
    echo "| SReclaimable | $mem_sreclaimable | $(ss::msg MSG_CPU_MEM_ROW_RECLAIMABLE) Slab |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_RECLAIMABLE) | $reclaimable | Buffers+Cached+SReclaimable |"
    echo "| Active | $mem_active | $(ss::msg MSG_CPU_MEM_ROW_ACTIVE) |"
    echo "| Inactive | $mem_inactive | $(ss::msg MSG_CPU_MEM_ROW_INACTIVE_PAGE) |"
    echo "| AnonPages | $mem_anon | 匿名内存（进程堆栈等，需 Swap 才能释放） |"
    echo "| Mapped | $mem_mapped | 文件映射内存 |"
    echo "| Shmem | $mem_shmem | $(ss::msg MSG_CPU_MEM_ROW_SHARED) / tmpfs |"
    echo "| Slab | $mem_slab | 内核对象缓存 |"
    echo "| Dirty | $mem_dirty | 待写回磁盘的脏页 |"
    echo "| Writeback | $mem_writeback | 正在写回磁盘的页 |"
    echo "| Committed_AS | $mem_commit | 系统承诺分配的虚拟内存总量 |"
    echo ""

    # OOM 风险评估（仅 Linux 提供 /proc/sys/vm/overcommit_*）
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo "### $(ss::msg MSG_CPU_MEM_OOM_TITLE)"
        echo ""
        echo "> ℹ️ macOS 采用不同内存管理模型，无 Linux overcommit 机制，本节跳过。"
        echo ""
    else
        oom_score_adj=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo "N/A")
        ratio=$(cat /proc/sys/vm/overcommit_ratio 2>/dev/null || echo "N/A")

        echo "### $(ss::msg MSG_CPU_MEM_OOM_TITLE)"
        echo ""
        echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_CPU_MEM_DESC) |"
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

ss::progress 7 12 "$(ss::msg MSG_CPU_MEM_SECTION_PROC)"
echo "## 7. $(ss::msg MSG_CPU_MEM_SECTION_PROC)"
echo ""
echo "> **$(ss::msg MSG_CPU_MEM_KEY_INDICATOR):** $(ss::msg MSG_CPU_MEM_KEY_INDICATOR_PROC)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS ps 状态码与 Linux 不同，需要映射
    # macOS 常见状态: S(sleeping), R(running), T(stopped), Z(zombie), I(idle), U(uninterruptible wait)
    echo "| $(ss::msg MSG_CPU_MEM_LABEL_LEVEL) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_CPU_MEM_LABEL_MEANING) | $(ss::msg MSG_TABLE_EVAL) |"
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
        echo "### $(ss::msg MSG_CPU_MEM_ZOMBIE_DETAIL)"
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
    echo "| $(ss::msg MSG_CPU_MEM_LABEL_LEVEL) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_CPU_MEM_LABEL_MEANING) | $(ss::msg MSG_TABLE_EVAL) |"
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
        echo "### $(ss::msg MSG_CPU_MEM_D_DETAIL)"
        echo ""
        echo "| PID | 用户 | CPU% | MEM% | 命令 |"
        echo "|-----|------|------|------|------|"
        ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="D" {printf "| %s | %s | %s | %s | %s |\n", $2, $1, $3, $4, $11}'
        echo ""
    fi

    # Z 状态进程
    z_count=$(ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="Z" {count++} END {print count+0}')
    if [ "$z_count" -gt 0 ]; then
        echo "### $(ss::msg MSG_CPU_MEM_ZOMBIE_DETAIL)"
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

ss::progress 8 12 "$(ss::msg MSG_CPU_MEM_SECTION_CTX)"
echo "## 8. $(ss::msg MSG_CPU_MEM_SECTION_CTX)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS 通过 netstat -s 获取近似值
    CTXT_TOTAL=$(netstat -s 2>/dev/null | grep -i "context switch" | head -1 | awk '{print $1}')
    INTR_TOTAL=$(netstat -s 2>/dev/null | grep -i "interrupt" | head -1 | awk '{print $1}')

    echo "> ℹ️ $(ss::msg MSG_CPU_MEM_NOTE_MAC_NETSTAT)"
    echo ""
    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_CPU_MEM_LABEL_CUMULATIVE) | $(ss::msg MSG_CPU_MEM_DESC) |"
    echo "|------|--------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_CTX_SWITCH) | ${CTXT_TOTAL:-N/A} | $(ss::msg MSG_CPU_MEM_LABEL_APPROX_NETSTAT) |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_INTERRUPT) | ${INTR_TOTAL:-N/A} | $(ss::msg MSG_CPU_MEM_LABEL_APPROX_NETSTAT) |"
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

    echo "> **$(ss::msg MSG_CPU_MEM_LABEL_EVAL_CRITERIA):** $(ss::msg MSG_CPU_MEM_CRITERIA_CTX)"
    echo ""
    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_CPU_MEM_LABEL_CUMULATIVE) | $(ss::msg MSG_CPU_MEM_LABEL_PER_SEC) |"
    echo "|------|--------|----------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_CTX_SWITCH) (ctxt) | $ctxt_total | ${ctxt_rate:-N/A} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_INTERRUPT) (intr) | $intr_total | ${intr_rate:-N/A} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_SOFTIRQ) (softirq) | $softirq_total | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_FORK) (fork) | $processes_total | ${proc_rate:-N/A} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_UPTIME_SEC) | ${uptime_sec}s | - |"
    echo ""
fi

# ==============================================================================
# 9. Top 资源消耗进程
# ==============================================================================

ss::progress 9 12 "$(ss::msg MSG_CPU_MEM_SECTION_TOP)"
echo "## 9. $(ss::msg MSG_CPU_MEM_SECTION_TOP)"
echo ""

# CPU Top 10
echo "### $(ss::msg MSG_CPU_MEM_TOP_CPU)"
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
echo "### $(ss::msg MSG_CPU_MEM_TOP_MEM)"
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

ss::progress 10 12 "$(ss::msg MSG_CPU_MEM_SECTION_FD)"
echo "## 10. $(ss::msg MSG_CPU_MEM_SECTION_FD)"
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
            file_status="$(ss::msg MSG_STATUS_DANGER)"
        elif [ "$pct_int" -gt 80 ]; then
            file_status="$(ss::msg MSG_STATUS_HIGH)"
        else
            file_status="$(ss::msg MSG_STATUS_NORMAL)"
        fi
    else
        file_pct="N/A"
        file_status="-"
    fi

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_CPU_MEM_LABEL_USAGE_RATE) | $(ss::msg MSG_TABLE_STATUS) |"
    echo "|------|------|--------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_OPEN_FILES) | $KERN_FILES | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_FILE_LIMIT) | $KERN_MAXFILES | ${file_pct}% | $file_status |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_PROC_LIMIT) | $KERN_MAXPROC | - | - |"
    echo ""

    echo "> ℹ️ $(ss::msg MSG_CPU_MEM_NOTE_MAC_FD)"
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
            file_status="$(ss::msg MSG_STATUS_HIGH)"
        elif [ "${file_pct%.*}" -gt 90 ]; then
            file_status="$(ss::msg MSG_STATUS_DANGER)"
        else
            file_status="$(ss::msg MSG_STATUS_NORMAL)"
        fi
    else
        file_pct="N/A"
        file_status="-"
    fi

    proc_max=$(cat /proc/sys/fs/nr_open 2>/dev/null || echo "N/A")

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_CPU_MEM_LABEL_USAGE_RATE) | $(ss::msg MSG_TABLE_STATUS) |"
    echo "|------|------|--------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_ALLOC_HANDLE) | $file_allocated | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_UNUSED_HANDLE) | $file_unused | - | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_HANDLE_LIMIT) | $file_max | ${file_pct}% | $file_status |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_NR_OPEN) | $proc_max | - | - |"
    echo ""

    # 进程句柄 Top 5
    echo "### $(ss::msg MSG_CPU_MEM_TOP_FD)"
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
    ss::progress 11 12 "$(ss::msg MSG_CPU_MEM_SECTION_SLAB)"
    echo "## 11. $(ss::msg MSG_CPU_MEM_SECTION_SLAB)"
    echo ""

    sunreclaim=$(grep "^SUnreclaim:" /proc/meminfo 2>/dev/null | awk '{print $2}')

    echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) (KB) | $(ss::msg MSG_CPU_MEM_DESC) |"
    echo "|------|-----------|------|"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_SLAB_TOTAL) | $mem_slab | 内核对象缓存总量 |"
    echo "| SReclaimable | $mem_sreclaimable | $(ss::msg MSG_CPU_MEM_ROW_RECLAIMABLE) Slab |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_SUNRECLAIM) | $sunreclaim | 不可回收 Slab |"
    echo ""

    if command -v slabtop &>/dev/null; then
        echo "### $(ss::msg MSG_CPU_MEM_TOP_SLAB)"
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

ss::progress 12 12 "$(ss::msg MSG_CPU_MEM_SECTION_TREND)"
echo "## 12. $(ss::msg MSG_CPU_MEM_SECTION_TREND)"
echo ""

echo "> **$(ss::msg MSG_CPU_MEM_TREND_JUDGEMENT):**"
if command -v bc &>/dev/null && [ -n "$load1" ] && [ -n "$load5" ] && [ -n "$load15" ]; then
    if (($(echo "$load1 > $load5" | bc -l))) && (($(echo "$load5 > $load15" | bc -l))); then
        echo "> $(ss::msg MSG_CPU_MEM_TREND_UP)"
    elif (($(echo "$load1 < $load5" | bc -l))) && (($(echo "$load5 < $load15" | bc -l))); then
        echo "> $(ss::msg MSG_CPU_MEM_TREND_DOWN)"
    else
        echo "> $(ss::msg MSG_CPU_MEM_TREND_STABLE)"
    fi
else
    echo "> $(ss::msg MSG_CPU_MEM_TREND_UNAVAILABLE)"
fi
echo ""

echo "| $(ss::msg MSG_CPU_MEM_TIME_WINDOW) | $(ss::msg MSG_CPU_MEM_LOAD_VAL) | $(ss::msg MSG_CPU_MEM_RATIO_CORE) |"
echo "|----------|--------|--------------|"
if command -v bc &>/dev/null && [ "$CORES" != "N/A" ] && [ -n "$CORES" ] &&
    [ -n "$load1" ] && [ -n "$load5" ] && [ -n "$load15" ]; then
    ratio1=$(printf "%.2f" "$(echo "scale=2; $load1 / $CORES" | bc -l)")
    ratio5=$(printf "%.2f" "$(echo "scale=2; $load5 / $CORES" | bc -l)")
    ratio15=$(printf "%.2f" "$(echo "scale=2; $load15 / $CORES" | bc -l)")
    echo "| $(ss::msg MSG_CPU_MEM_1MIN) | $load1 | ${ratio1} |"
    echo "| $(ss::msg MSG_CPU_MEM_5MIN) | $load5 | ${ratio5} |"
    echo "| $(ss::msg MSG_CPU_MEM_15MIN) | $load15 | ${ratio15} |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_LOGIC_CORES_SIMPLE) | $CORES | $(ss::msg MSG_CPU_MEM_BASELINE) |"
else
    echo "| $(ss::msg MSG_CPU_MEM_1MIN) | $load1 | - |"
    echo "| $(ss::msg MSG_CPU_MEM_5MIN) | $load5 | - |"
    echo "| $(ss::msg MSG_CPU_MEM_15MIN) | $load15 | - |"
    echo "| $(ss::msg MSG_CPU_MEM_ROW_LOGIC_CORES_SIMPLE) | $CORES | $(ss::msg MSG_CPU_MEM_BASELINE) |"
fi
echo ""

# ==============================================================================
# 报告尾部
# ==============================================================================

echo "---"
echo ""
echo "## $(ss::msg MSG_CPU_MEM_APPENDIX)"
echo ""
echo "$(ss::msg MSG_CPU_MEM_APPENDIX_HINT)"
echo ""
echo '```'
echo "$(ss::msg MSG_CPU_MEM_APPENDIX_PROMPT)"
echo "1. $(ss::msg MSG_CPU_MEM_APPENDIX_P1)"
echo "2. $(ss::msg MSG_CPU_MEM_APPENDIX_P2)"
echo "3. $(ss::msg MSG_CPU_MEM_APPENDIX_P3)"
echo "4. $(ss::msg MSG_CPU_MEM_APPENDIX_P4)"
echo "5. $(ss::msg MSG_CPU_MEM_APPENDIX_P5)"
echo "6. $(ss::msg MSG_CPU_MEM_APPENDIX_P6)"
echo "7. $(ss::msg MSG_CPU_MEM_APPENDIX_P7)"
echo '```'
echo ""
echo "> 📄 **$(ss::msg MSG_COMMON_REPORT_SAVED):** \`$REPORT_PATH\`"

# 报告结束
ss::report_end "$REPORT_PATH"

# JSON 输出
if [ "$JSON_OUTPUT" = "true" ]; then
    summary="CPU/内存深度分析完成"
    ss::print_json_metadata "success" "$REPORT_PATH" "cpu_mem_analyzer.sh" 0 "$summary" ""
fi

# 通知推送（未启用 --notify 时静默跳过，推送失败不影响主流程）
ss::notify_send "$(ss::msg MSG_CPU_MEM_REPORT_TITLE)" "$REPORT_PATH" || true

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
