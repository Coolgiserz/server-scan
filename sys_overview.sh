#!/bin/bash
# ==============================================================================
# 脚本名称: sys_overview.sh
# 功能说明: 系统瓶颈总览，快速定位 CPU / 内存 / 磁盘 / 网络 中的短板资源
#             汇总各维度关键指标并给出综合健康度评分与瓶颈结论
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL) / macOS (Intel/Apple Silicon)
# 依赖工具: bc, ps, top, df, vm_stat( macOS ), sysctl
# 使用方法: chmod +x sys_overview.sh && ./sys_overview.sh
# 输出文件: 默认 /tmp/sys_overview_$(date +%Y%m%d_%H%M%S).md
# ==============================================================================

# --- 配置区 ---
REPORT_PATH="/tmp/sys_overview_$(date '+%Y%m%d_%H%M%S').md"

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cli.sh"

# 解析公共参数（必须在主shell中直接调用，不能用命令替换）
ss::parse_common_args "$@"

# 脚本特定参数解析（当前无特定参数，仅处理 --help）
set -- "${SCRIPT_ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_OVERVIEW_HELP_DESC)" ""
        exit 0
        ;;
    *)
        ss::log_error "$(ss::msgf MSG_ERROR_UNKNOWN_ARG "$1")"
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_OVERVIEW_HELP_DESC)" ""
        exit 2
        ;;
    esac
done

# 结论汇总用：把各维度瓶颈写进数组，末尾生成「瓶颈清单」
declare -a BOTTLENECKS=()
add_bottleneck() {
    # $1=级别(red/yellow) $2=维度 $3=结论
    BOTTLENECKS+=("$1|$2|$3")
}

# 报告开始
ss::report_begin "$(ss::msg MSG_OVERVIEW_REPORT_TITLE)" 7

# ==============================================================================
# Markdown 报告头
# ==============================================================================
echo "# $(ss::msg MSG_OVERVIEW_TITLE)"
echo ""
if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
else
    OS_NAME="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Linux')"
fi
echo "> **$(ss::msg MSG_COMMON_HOSTNAME):** $(hostname)  "
echo "> **$(ss::msg MSG_COMMON_COLLECT_TIME):** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **$(ss::msg MSG_COMMON_REPORT_FILE):** \`$REPORT_PATH\`  "
echo "> **$(ss::msg MSG_COMMON_OS):** ${OS_NAME}  "
echo "> **$(ss::msg MSG_COMMON_KERNEL):** $(uname -r)  "
echo ""
echo "---"
echo ""

# ==============================================================================
# 1. CPU 维度
# ==============================================================================
ss::progress 1 7 "$(ss::msg MSG_OVERVIEW_SECTION_CPU)"
echo "## 1. $(ss::msg MSG_OVERVIEW_SECTION_CPU)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    LOAD_RAW=$(ss::read_sysctl "vm.loadavg")
    load1=$(echo "$LOAD_RAW" | awk '{print $2}')
    CORES=$(ss::read_sysctl "hw.ncpu")
    TOP_OUTPUT=$(top -l 1 -n 0 2>/dev/null)
    CPU_LINE=$(echo "$TOP_OUTPUT" | grep "CPU usage")
    id=$(echo "$CPU_LINE" | grep -o '[0-9.]*% idle' | grep -o '[0-9.]*' | head -1 || echo "0.0")
else
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    CORES=$(nproc 2>/dev/null)
    id=$(top -bn1 2>/dev/null | grep -E "^%?Cpu" | head -1 | grep -oP '\d+\.?\d*\s*id' | awk '{print $1}')
fi

# CPU 饱和度：load1 / 核心数
if command -v bc >/dev/null 2>&1 && [ -n "$load1" ] && [ -n "$CORES" ] && [ "$CORES" != "N/A" ] && [ "$CORES" -gt 0 ]; then
    ratio=$(echo "scale=2; $load1 / $CORES" | bc -l)
    busy_pct=$(echo "scale=0; 100 - $id" | bc -l 2>/dev/null || echo "N/A")
else
    ratio="N/A"
    busy_pct="N/A"
fi

# 综合判定
cpu_status="$(ss::msg MSG_STATUS_HEALTHY)"
cpu_note="$(ss::msg MSG_OVERVIEW_CPU_NORMAL)"
if [ "$ratio" != "N/A" ]; then
    if awk "BEGIN {exit !($ratio > 2.0)}"; then
        cpu_status="$(ss::msg MSG_STATUS_BOTTLENECK)"
        cpu_note="$(ss::msgf MSG_OVERVIEW_CPU_OVERLOAD "$(awk "BEGIN{printf \"%.1f\",$ratio}")")"
        add_bottleneck "red" "$(ss::msg MSG_DIM_CPU)" "$(ss::msgf MSG_OVERVIEW_BN_CPU_OVERLOAD "$load1" "$CORES" "$(awk "BEGIN{printf \"%.1f\",$ratio}")")"
    elif awk "BEGIN {exit !($ratio > 1.0)}"; then
        cpu_status="$(ss::msg MSG_STATUS_BUSY)"
        cpu_note="$(ss::msg MSG_OVERVIEW_CPU_QUEUING)"
        add_bottleneck "yellow" "$(ss::msg MSG_DIM_CPU)" "$(ss::msgf MSG_OVERVIEW_BN_CPU_QUEUE "$load1" "$CORES")"
    fi
fi

echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_STATUS) |"
echo "|------|------|------|"
echo "| $(ss::msg MSG_OVERVIEW_ROW_CORES) | ${CORES} | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_LOAD1) | ${load1} | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_LOAD_RATIO) | ${ratio} | $cpu_status |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_IDLE) | ${id}% | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_BUSY) | ${busy_pct}% | - |"
echo ""
echo "> $cpu_note"
echo ""

# ==============================================================================
# 2. 内存维度
# ==============================================================================
ss::progress 2 7 "$(ss::msg MSG_OVERVIEW_SECTION_MEM)"
echo "## 2. $(ss::msg MSG_OVERVIEW_SECTION_MEM)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    TOTAL_BYTES=$(ss::read_sysctl "hw.memsize")
    TOTAL_KB=$((TOTAL_BYTES / 1024))
    PAGE_SIZE=$(ss::read_sysctl "hw.pagesize")
    VM_STAT=$(vm_stat 2>/dev/null)
    parse_vm_stat() { echo "$VM_STAT" | grep "^$1:" | awk -F': *' '{print $2}' | sed 's/\.//'; }
    free_kb=$(($(parse_vm_stat "Pages free") * PAGE_SIZE / 1024))
    inactive_kb=$(($(parse_vm_stat "Pages inactive") * PAGE_SIZE / 1024))
    avail_kb=$((free_kb + inactive_kb))
else
    mem_line=$(free -k | grep '^Mem:')
    TOTAL_KB=$(echo "$mem_line" | awk '{print $2}')
    avail_kb=$(echo "$mem_line" | awk '{print $7}')
fi

if [ -n "$TOTAL_KB" ] && [ "$TOTAL_KB" -gt 0 ]; then
    avail_pct=$(awk "BEGIN {printf \"%.2f\", $avail_kb/$TOTAL_KB*100}")
else
    avail_pct="N/A"
fi

# 内存压力判定
mem_status="$(ss::msg MSG_STATUS_SUFFICIENT)"
mem_note="$(ss::msg MSG_OVERVIEW_MEM_SUFFICIENT)"
if [ "$avail_pct" != "N/A" ]; then
    avail_num=${avail_pct%.*}
    if [ "$avail_num" -lt 10 ]; then
        mem_status="$(ss::msg MSG_STATUS_INSUFFICIENT)"
        mem_note="$(ss::msgf MSG_OVERVIEW_MEM_CRITICAL "$avail_pct")"
        add_bottleneck "red" "$(ss::msg MSG_DIM_MEM)" "$(ss::msgf MSG_OVERVIEW_BN_MEM_LOW "$avail_pct")"
    elif [ "$avail_num" -lt 20 ]; then
        mem_status="$(ss::msg MSG_STATUS_TENSE)"
        mem_note="$(ss::msgf MSG_OVERVIEW_MEM_LOW "$avail_pct")"
        add_bottleneck "yellow" "$(ss::msg MSG_DIM_MEM)" "$(ss::msgf MSG_OVERVIEW_BN_MEM_TENSE "$avail_pct")"
    fi
fi

echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_HUMAN_READABLE) | $(ss::msg MSG_TABLE_STATUS) |"
echo "|------|------|----------|------|"
echo "| $(ss::msg MSG_OVERVIEW_ROW_TOTAL_MEM) | $TOTAL_KB | $(ss::hr_kb $TOTAL_KB) | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_AVAIL_MEM) | $avail_kb | $(ss::hr_kb $avail_kb) | $mem_status |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_AVAIL_PCT) | ${avail_pct}% | - | - |"
echo ""
echo "> $mem_note"
echo ""

# ==============================================================================
# 3. 磁盘维度
# ==============================================================================
ss::progress 3 7 "$(ss::msg MSG_OVERVIEW_SECTION_DISK)"
echo "## 3. $(ss::msg MSG_OVERVIEW_SECTION_DISK)"
echo ""

disk_max_pct="0"
disk_worst=""
disk_status="$(ss::msg MSG_STATUS_HEALTHY)"
disk_note="$(ss::msg MSG_OVERVIEW_DISK_NORMAL)"
if [ "$OS_TYPE" = "Darwin" ]; then
    while read -r fs size used avail capacity iused ifree ipct mount; do
        [ -z "$capacity" ] && continue
        use_num=$(echo "$capacity" | sed 's/%//')
        if [ "$use_num" -gt "$disk_max_pct" ]; then
            disk_max_pct=$use_num
            disk_worst=$mount
        fi
    done < <(df -h 2>/dev/null | grep -E '^/dev/')
else
    while read -r fs type size used avail use mount; do
        [ -z "$use" ] && continue
        use_num=$(echo "$use" | sed 's/%//')
        if [ "$use_num" -gt "$disk_max_pct" ]; then
            disk_max_pct=$use_num
            disk_worst=$mount
        fi
    done < <(df -hT 2>/dev/null | grep -E '^/dev/')
fi

if [ "$disk_max_pct" -ge 90 ]; then
    disk_status="$(ss::msg MSG_STATUS_BOTTLENECK)"
    disk_note="$(ss::msgf MSG_OVERVIEW_DISK_CRITICAL "$disk_worst" "$disk_max_pct")"
    add_bottleneck "red" "$(ss::msg MSG_DIM_DISK)" "$(ss::msgf MSG_OVERVIEW_BN_DISK_CRITICAL "$disk_worst" "$disk_max_pct")"
elif [ "$disk_max_pct" -ge 80 ]; then
    disk_status="$(ss::msg MSG_STATUS_HIGH)"
    disk_note="$(ss::msgf MSG_OVERVIEW_DISK_HIGH "$disk_worst" "$disk_max_pct")"
    add_bottleneck "yellow" "$(ss::msg MSG_DIM_DISK)" "$(ss::msgf MSG_OVERVIEW_BN_DISK_HIGH "$disk_worst" "$disk_max_pct")"
fi

echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_STATUS) |"
echo "|------|------|------|"
echo "| $(ss::msg MSG_OVERVIEW_ROW_WORST_MOUNT) | ${disk_worst:-$(ss::msg MSG_OVERVIEW_NONE)} | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_WORST_USAGE) | ${disk_max_pct}% | $disk_status |"
echo ""
echo "> $disk_note"
echo ""

# ==============================================================================
# 4. 网络维度（基础连通性 + 接口吞吐）
# ==============================================================================
ss::progress 4 7 "$(ss::msg MSG_OVERVIEW_SECTION_NET)"
echo "## 4. $(ss::msg MSG_OVERVIEW_SECTION_NET)"
echo ""

# 接口数量与状态（UP/down）
if [ "$OS_TYPE" = "Darwin" ]; then
    net_ifaces=$(ifconfig 2>/dev/null | grep -E '^[a-z0-9]+:' | awk -F: '{print $1}')
else
    net_ifaces=$(ls /sys/class/net 2>/dev/null)
fi

up_count=0
down_count=0
for iface in $net_ifaces; do
    # 排除回环
    [ "$iface" = "lo" ] && continue
    if [ "$OS_TYPE" = "Darwin" ]; then
        flags=$(ifconfig "$iface" 2>/dev/null | grep -E '^\s+status' | awk -F': ' '{print $2}')
        if echo "$flags" | grep -qi "active"; then up_count=$((up_count + 1)); else down_count=$((down_count + 1)); fi
    else
        operstate=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
        if [ "$operstate" = "up" ]; then up_count=$((up_count + 1)); else down_count=$((down_count + 1)); fi
    fi
done

# 连通性探测（默认网关）
gw_reachable="$(ss::msg MSG_STATUS_UNKNOWN)"
if command -v ping >/dev/null 2>&1; then
    if [ "$OS_TYPE" = "Darwin" ]; then
        gw=$(netstat -rn 2>/dev/null | awk '/default/ {print $2; exit}')
        ping_cmd="ping -c 1 -t 2"
    else
        gw=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
        ping_cmd="ping -c 1 -W 2"
    fi
    if [ -n "$gw" ]; then
        if ss::run_with_timeout 4 $ping_cmd "$gw" >/dev/null 2>&1; then
            gw_reachable="$(ss::msg MSG_STATUS_REACHABLE) (${gw})"
        else
            gw_reachable="$(ss::msg MSG_STATUS_UNREACHABLE) (${gw})"
            add_bottleneck "red" "$(ss::msg MSG_DIM_NET)" "$(ss::msgf MSG_OVERVIEW_BN_NET_GW "$gw")"
        fi
    fi
fi

net_status="$(ss::msg MSG_STATUS_NORMAL)"
net_note="$(ss::msg MSG_OVERVIEW_NET_NORMAL)"
if echo "$gw_reachable" | grep -q "$(ss::msg MSG_STATUS_UNREACHABLE)"; then
    net_status="$(ss::msg MSG_STATUS_ABNORMAL)"
fi

echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_STATUS) |"
echo "|------|------|------|"
echo "| $(ss::msg MSG_OVERVIEW_ROW_UP_IFACES) | ${up_count} | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_DOWN_IFACES) | ${down_count} | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_GW_CONN) | ${gw_reachable} | ${net_status} |"
echo ""
echo "> $net_note"
echo ""

# ==============================================================================
# 5. 进程与负载特征
# ==============================================================================
ss::progress 5 7 "$(ss::msg MSG_OVERVIEW_SECTION_PROC)"
echo "## 5. $(ss::msg MSG_OVERVIEW_SECTION_PROC)"
echo ""

# 僵尸进程 / D/U 状态进程
if [ "$OS_TYPE" = "Darwin" ]; then
    z_count=$(ps ax -o stat= 2>/dev/null | grep -c '^Z')
    u_count=$(ps ax -o stat= 2>/dev/null | grep -c '^U')
else
    z_count=$(ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="Z"' | wc -l | tr -d ' ')
    u_count=$(ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="D"' | wc -l | tr -d ' ')
fi

proc_status="$(ss::msg MSG_STATUS_NORMAL)"
proc_note="$(ss::msg MSG_OVERVIEW_PROC_NORMAL)"
if [ "$z_count" -gt 0 ]; then
    proc_status="$(ss::msg MSG_STATUS_ATTENTION)"
    proc_note="$(ss::msgf MSG_OVERVIEW_PROC_ZOMBIE "$z_count")"
    add_bottleneck "yellow" "$(ss::msg MSG_DIM_PROC)" "$(ss::msgf MSG_OVERVIEW_BN_PROC_ZOMBIE "$z_count")"
fi
if [ "$u_count" -gt 0 ]; then
    proc_status="$(ss::msg MSG_STATUS_ATTENTION)"
    proc_note="${proc_note}$(ss::msgf MSG_OVERVIEW_PROC_D_EXTRA "$u_count")"
    add_bottleneck "yellow" "$(ss::msg MSG_DIM_IO)" "$(ss::msgf MSG_OVERVIEW_BN_IO_D "$u_count")"
fi

echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_STATUS) |"
echo "|------|------|------|"
echo "| $(ss::msg MSG_OVERVIEW_ROW_ZOMBIE) | ${z_count} | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_DU) | ${u_count} | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_EVAL) | - | ${proc_status} |"
echo ""
echo "> $proc_note"
echo ""

# ==============================================================================
# 6. 句柄与限制
# ==============================================================================
ss::progress 6 7 "$(ss::msg MSG_OVERVIEW_SECTION_FD)"
echo "## 6. $(ss::msg MSG_OVERVIEW_SECTION_FD)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    KERN_FILES=$(ss::read_sysctl "kern.num_files")
    KERN_MAXFILES=$(ss::read_sysctl "kern.maxfiles")
    if [ "$KERN_MAXFILES" != "N/A" ] && [ "$KERN_MAXFILES" -gt 0 ]; then
        file_pct=$(awk "BEGIN {printf \"%.2f\", $KERN_FILES/$KERN_MAXFILES*100}")
    else
        file_pct="N/A"
    fi
    file_max=$KERN_MAXFILES
else
    file_nr=$(cat /proc/sys/fs/file-nr 2>/dev/null)
    file_allocated=$(echo "$file_nr" | awk '{print $1}')
    file_max=$(echo "$file_nr" | awk '{print $3}')
    if [ -n "$file_max" ] && [ "$file_max" -gt 0 ]; then
        file_pct=$(awk "BEGIN {printf \"%.2f\", $file_allocated/$file_max*100}")
    else
        file_pct="N/A"
    fi
fi

fd_status="$(ss::msg MSG_STATUS_NORMAL)"
fd_note="$(ss::msg MSG_OVERVIEW_FD_NORMAL)"
if [ "$file_pct" != "N/A" ]; then
    pct_int=${file_pct%.*}
    if [ "$pct_int" -gt 90 ]; then
        fd_status="$(ss::msg MSG_STATUS_DANGER)"
        fd_note="$(ss::msgf MSG_OVERVIEW_FD_CRITICAL "$file_pct")"
        add_bottleneck "red" "$(ss::msg MSG_DIM_FD)" "$(ss::msgf MSG_OVERVIEW_BN_FD_CRITICAL "$file_pct")"
    elif [ "$pct_int" -gt 80 ]; then
        fd_status="$(ss::msg MSG_STATUS_HIGH)"
        fd_note="$(ss::msgf MSG_OVERVIEW_FD_HIGH "$file_pct")"
        add_bottleneck "yellow" "$(ss::msg MSG_DIM_FD)" "$(ss::msgf MSG_OVERVIEW_BN_FD_HIGH "$file_pct")"
    fi
fi

echo "| $(ss::msg MSG_TABLE_METRIC) | $(ss::msg MSG_TABLE_VALUE) | $(ss::msg MSG_TABLE_RATIO) | $(ss::msg MSG_TABLE_STATUS) |"
echo "|------|------|--------|------|"
echo "| $(ss::msg MSG_OVERVIEW_ROW_FD_LIMIT) | ${file_max} | - | - |"
echo "| $(ss::msg MSG_OVERVIEW_ROW_FD_USAGE) | - | ${file_pct}% | ${fd_status} |"
echo ""
echo "> $fd_note"
echo ""

# ==============================================================================
# 7. 瓶颈结论汇总
# ==============================================================================
ss::progress 7 7 "$(ss::msg MSG_OVERVIEW_SECTION_SUMMARY)"
echo "## 7. $(ss::msg MSG_OVERVIEW_SECTION_SUMMARY)"
echo ""

total=${#BOTTLENECKS[@]}
if [ "$total" -eq 0 ]; then
    echo "> $(ss::msg MSG_OVERVIEW_SUMMARY_NO_BOTTLENECK)"
    echo ""
    echo "| $(ss::msg MSG_OVERVIEW_SECTION_SUMMARY) | $(ss::msg MSG_OVERVIEW_SUMMARY_CONCL) |"
    echo "|------|----------|"
    echo "| CPU | $(ss::msg MSG_STATUS_HEALTHY) |"
    echo "| $(ss::msg MSG_OVERVIEW_SECTION_MEM) | $(ss::msg MSG_STATUS_SUFFICIENT) |"
    echo "| $(ss::msg MSG_OVERVIEW_SECTION_DISK) | $(ss::msg MSG_STATUS_HEALTHY) |"
    echo "| $(ss::msg MSG_OVERVIEW_SECTION_NET) | $(ss::msg MSG_STATUS_NORMAL) |"
    echo "| $(ss::msg MSG_OVERVIEW_SECTION_PROC) | $(ss::msg MSG_STATUS_NORMAL) |"
    echo "| $(ss::msg MSG_OVERVIEW_SECTION_FD) | $(ss::msg MSG_STATUS_NORMAL) |"
    echo ""
else
    echo "> $(ss::msgf MSG_OVERVIEW_SUMMARY_FOUND "$total")"
    echo ""
    echo "| $(ss::msg MSG_OVERVIEW_SUMMARY_LEVEL) | $(ss::msg MSG_OVERVIEW_SUMMARY_DIM) | $(ss::msg MSG_OVERVIEW_SUMMARY_CONCL) |"
    echo "|------|------|------|"
    for item in "${BOTTLENECKS[@]}"; do
        IFS='|' read -r lvl dim desc <<<"$item"
        if [ "$lvl" = "red" ]; then icon="🔴"; else icon="🟡"; fi
        printf "| %s | %s | %s |\n" "$icon" "$dim" "$desc"
    done
    echo ""

    # 最关键瓶颈（第一个 red，否则第一个 yellow）
    first_red=""
    first_yellow=""
    for item in "${BOTTLENECKS[@]}"; do
        IFS='|' read -r lvl dim desc <<<"$item"
        if [ "$lvl" = "red" ] && [ -z "$first_red" ]; then first_red="$dim: $desc"; fi
        if [ "$lvl" = "yellow" ] && [ -z "$first_yellow" ]; then first_yellow="$dim: $desc"; fi
    done
    if [ -n "$first_red" ]; then
        echo "> 🎯 **$(ss::msg MSG_OVERVIEW_MOST_CRITICAL):** $first_red"
    elif [ -n "$first_yellow" ]; then
        echo "> 🎯 **$(ss::msg MSG_OVERVIEW_MOST_ATTENTION):** $first_yellow"
    fi
    echo ""
fi

echo "> $(ss::msg MSG_OVERVIEW_TIP)"
echo ""

# ==============================================================================
# 报告尾部
# ==============================================================================
echo "---"
echo ""
echo "## $(ss::msg MSG_OVERVIEW_APPENDIX)"
echo ""
echo "$(ss::msg MSG_OVERVIEW_APPENDIX_HINT)"
echo ""
echo '```'
echo "请分析以下系统瓶颈总览，重点关注："
echo "1. $(ss::msg MSG_OVERVIEW_APPENDIX_PROMPT1)"
echo "2. $(ss::msg MSG_OVERVIEW_APPENDIX_PROMPT2)"
echo "3. $(ss::msg MSG_OVERVIEW_APPENDIX_PROMPT3)"
echo '```'
echo ""
echo "> 📄 **$(ss::msg MSG_COMMON_REPORT_SAVED):** \`$REPORT_PATH\`"

# 报告结束
ss::report_end "$REPORT_PATH"

# JSON 输出
if [ "$JSON_OUTPUT" = "true" ]; then
    summary="发现 ${total} 项潜在瓶颈"
    bottlenecks=$(
        IFS=';'
        echo "${BOTTLENECKS[*]}"
    )
    ss::print_json_metadata "success" "$REPORT_PATH" "sys_overview.sh" 0 "$summary" "$bottlenecks"
fi

# 通知推送（未启用 --notify 时静默跳过，推送失败不影响主流程）
ss::notify_send "$(ss::msg MSG_OVERVIEW_REPORT_TITLE)" "$REPORT_PATH" || true

# 显式退出码
if [ "$total" -gt 0 ]; then
    exit 1
else
    exit 0
fi

# ==============================================================================
# 使用说明:
# 1. 直接运行: ./sys_overview.sh
# 2. 自定义输出: ./sys_overview.sh -o /var/log/overview.md
# 3. 静默模式: ./sys_overview.sh --quiet
# 4. JSON 输出: ./sys_overview.sh --json
# 5. 配合 crontab: 0 */6 * * * /path/to/sys_overview.sh
# ==============================================================================
