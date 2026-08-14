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

# 检测操作系统
OS_TYPE=$(uname -s)

# ==============================================================================
# 跨平台超时封装 run_with_timeout <秒> <命令...>
# ==============================================================================
if command -v timeout >/dev/null 2>&1; then
    run_with_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
    run_with_timeout() { gtimeout "$@"; }
else
    run_with_timeout() {
        local secs="$1"; shift
        "$@" &
        local pid=$!
        local waited=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
            if [ "$waited" -ge "$secs" ]; then
                kill "$pid" 2>/dev/null
                wait "$pid" 2>/dev/null
                return 124
            fi
        done
        wait "$pid" 2>/dev/null
    }
fi

# 使用临时文件收集报告，避免进程替换的异步/交错问题
TMP_REPORT=$(mktemp)

# 保存原始 stdout，用于末尾恢复并显示报告
exec 3>&1

# 将后续所有输出重定向到临时 Markdown 文件
exec > "$TMP_REPORT"

# ------------------------------------------------------------------------------
# 实时进度提示：打印到 fd3（终端），不进入报告文件
# ------------------------------------------------------------------------------
progress() {
    # $1=当前章节序号 $2=总章节数 $3=章节名
    printf '\r\033[K🔄 [%s/%s] %s ...\n' "$1" "$2" "$3" >&3
}

# 启动横幅（实时打印到终端，不进报告文件）
printf '\n\033[1;32m🚀 系统瓶颈总览 分析开始\033[0m (共 7 个章节，执行期间会逐章显示进度)\n' >&3

# ==============================================================================
# 通用辅助函数
# ==============================================================================
hr_kb() {
    local kb=$1
    if [ -z "$kb" ] || [ "$kb" = "0" ]; then echo "0KB"; return; fi
    local units=("KB" "MB" "GB" "TB")
    local unit_idx=0
    local value=$kb
    while awk "BEGIN {exit !($value >= 1024)}" 2>/dev/null && [ $unit_idx -lt 3 ]; do
        value=$(awk "BEGIN {printf \"%.2f\", $value/1024}")
        unit_idx=$((unit_idx + 1))
    done
    echo "${value}${units[$unit_idx]}"
}

read_sysctl() {
    sysctl -n "$1" 2>/dev/null || echo "N/A"
}

# 结论汇总用：把各维度瓶颈写进数组，末尾生成「瓶颈清单」
declare -a BOTTLENECKS=()
add_bottleneck() {
    # $1=级别(red/yellow) $2=维度 $3=结论
    BOTTLENECKS+=("$1|$2|$3")
}

# ==============================================================================
# Markdown 报告头
# ==============================================================================
echo "# 系统瓶颈总览报告"
echo ""
if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
else
    OS_NAME="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Linux')"
fi
echo "> **主机名:** $(hostname)  "
echo "> **采集时间:** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **报告文件:** \`$REPORT_PATH\`  "
echo "> **操作系统:** ${OS_NAME}  "
echo "> **内核版本:** $(uname -r)  "
echo ""
echo "---"
echo ""

# ==============================================================================
# 1. CPU 维度
# ==============================================================================
progress 1 7 "CPU 维度"
echo "## 1. CPU 维度"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    LOAD_RAW=$(read_sysctl "vm.loadavg")
    load1=$(echo "$LOAD_RAW" | awk '{print $2}')
    CORES=$(read_sysctl "hw.ncpu")
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
cpu_status="🟢 健康"
cpu_note="CPU 负载与空闲率均正常"
if [ "$ratio" != "N/A" ]; then
    if awk "BEGIN {exit !($ratio > 2.0)}"; then
        cpu_status="🔴 严重瓶颈"
        cpu_note="load1 达核心数的 $(awk "BEGIN{printf \"%.1f\",$ratio}") 倍，CPU 严重过载"
        add_bottleneck "red" "CPU" "load1($load1) 是核心数($CORES)的 $(awk "BEGIN{printf \"%.1f\",$ratio}") 倍"
    elif awk "BEGIN {exit !($ratio > 1.0)}"; then
        cpu_status="🟡 繁忙"
        cpu_note="load1 超过核心数，CPU 排队明显"
        add_bottleneck "yellow" "CPU" "load1($load1) > 核心数($CORES)，存在排队"
    fi
fi

echo "| 指标 | 数值 | 状态 |"
echo "|------|------|------|"
echo "| 逻辑核心数 | ${CORES} | - |"
echo "| 1 分钟负载 | ${load1} | - |"
echo "| 负载/核心比 | ${ratio} | $cpu_status |"
echo "| CPU 空闲率 | ${id}% | - |"
echo "| CPU 忙碌率(估) | ${busy_pct}% | - |"
echo ""
echo "> $cpu_note"
echo ""

# ==============================================================================
# 2. 内存维度
# ==============================================================================
progress 2 7 "内存维度"
echo "## 2. 内存维度"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    TOTAL_BYTES=$(read_sysctl "hw.memsize")
    TOTAL_KB=$((TOTAL_BYTES / 1024))
    PAGE_SIZE=$(read_sysctl "hw.pagesize")
    VM_STAT=$(vm_stat 2>/dev/null)
    parse_vm_stat() { echo "$VM_STAT" | grep "^$1:" | awk -F': *' '{print $2}' | sed 's/\.//'; }
    free_kb=$(( $(parse_vm_stat "Pages free") * PAGE_SIZE / 1024 ))
    inactive_kb=$(( $(parse_vm_stat "Pages inactive") * PAGE_SIZE / 1024 ))
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
mem_status="🟢 充足"
mem_note="可用内存充足"
if [ "$avail_pct" != "N/A" ]; then
    avail_num=${avail_pct%.*}
    if [ "$avail_num" -lt 10 ]; then
        mem_status="🔴 严重不足"
        mem_note="可用内存仅 ${avail_pct}%，随时可能触发 OOM / 大量 Swap"
        add_bottleneck "red" "内存" "可用内存仅 ${avail_pct}%（< 10%）"
    elif [ "$avail_num" -lt 20 ]; then
        mem_status="🟡 紧张"
        mem_note="可用内存 ${avail_pct}%，偏低，关注 Swap 增长"
        add_bottleneck "yellow" "内存" "可用内存 ${avail_pct}%（< 20%）"
    fi
fi

echo "| 指标 | 数值 | 人类可读 | 状态 |"
echo "|------|------|----------|------|"
echo "| 总内存 | $TOTAL_KB | $(hr_kb $TOTAL_KB) | - |"
echo "| 可用内存 | $avail_kb | $(hr_kb $avail_kb) | $mem_status |"
echo "| 可用占比 | ${avail_pct}% | - | - |"
echo ""
echo "> $mem_note"
echo ""

# ==============================================================================
# 3. 磁盘维度
# ==============================================================================
progress 3 7 "磁盘维度"
echo "## 3. 磁盘维度"
echo ""

disk_max_pct="0"
disk_worst=""
disk_status="🟢 健康"
disk_note="所有挂载点使用率正常"
if [ "$OS_TYPE" = "Darwin" ]; then
    while read -r fs size used avail capacity iused ifree ipct mount; do
        [ -z "$capacity" ] && continue
        use_num=$(echo "$capacity" | sed 's/%//')
        if [ "$use_num" -gt "$disk_max_pct" ]; then disk_max_pct=$use_num; disk_worst=$mount; fi
    done < <(df -h 2>/dev/null | grep -E '^/dev/')
else
    while read -r fs type size used avail use mount; do
        [ -z "$use" ] && continue
        use_num=$(echo "$use" | sed 's/%//')
        if [ "$use_num" -gt "$disk_max_pct" ]; then disk_max_pct=$use_num; disk_worst=$mount; fi
    done < <(df -hT 2>/dev/null | grep -E '^/dev/')
fi

if [ "$disk_max_pct" -ge 90 ]; then
    disk_status="🔴 严重瓶颈"
    disk_note="挂载点 \`$disk_worst\` 使用率 ${disk_max_pct}%，空间即将耗尽"
    add_bottleneck "red" "磁盘" "$disk_worst 使用率 ${disk_max_pct}%（>= 90%）"
elif [ "$disk_max_pct" -ge 80 ]; then
    disk_status="🟡 偏高"
    disk_note="挂载点 \`$disk_worst\` 使用率 ${disk_max_pct}%，需关注"
    add_bottleneck "yellow" "磁盘" "$disk_worst 使用率 ${disk_max_pct}%（>= 80%）"
fi

echo "| 指标 | 数值 | 状态 |"
echo "|------|------|------|"
echo "| 最高使用率挂载点 | ${disk_worst:-无} | - |"
echo "| 最高磁盘使用率 | ${disk_max_pct}% | $disk_status |"
echo ""
echo "> $disk_note"
echo ""

# ==============================================================================
# 4. 网络维度（基础连通性 + 接口吞吐）
# ==============================================================================
progress 4 7 "网络维度"
echo "## 4. 网络维度"
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
        if echo "$flags" | grep -qi "active"; then up_count=$((up_count+1)); else down_count=$((down_count+1)); fi
    else
        operstate=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
        if [ "$operstate" = "up" ]; then up_count=$((up_count+1)); else down_count=$((down_count+1)); fi
    fi
done

# 连通性探测（默认网关）
gw_reachable="未知"
if command -v ping >/dev/null 2>&1; then
    if [ "$OS_TYPE" = "Darwin" ]; then
        gw=$(netstat -rn 2>/dev/null | awk '/default/ {print $2; exit}')
        ping_cmd="ping -c 1 -t 2"
    else
        gw=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
        ping_cmd="ping -c 1 -W 2"
    fi
    if [ -n "$gw" ]; then
        if run_with_timeout 4 $ping_cmd "$gw" >/dev/null 2>&1; then
            gw_reachable="✅ 可达 (${gw})"
        else
            gw_reachable="🔴 不可达 (${gw})"
            add_bottleneck "red" "网络" "默认网关 ${gw} 不可达"
        fi
    fi
fi

net_status="🟢 正常"
net_note="网络接口与网关连通性正常"
if echo "$gw_reachable" | grep -q "不可达"; then
    net_status="🔴 异常"
fi

echo "| 指标 | 数值 | 状态 |"
echo "|------|------|------|"
echo "| UP 接口数 | ${up_count} | - |"
echo "| DOWN 接口数 | ${down_count} | - |"
echo "| 默认网关连通 | ${gw_reachable} | ${net_status} |"
echo ""
echo "> $net_note"
echo ""

# ==============================================================================
# 5. 进程与负载特征
# ==============================================================================
progress 5 7 "进程与负载特征"
echo "## 5. 进程与负载特征"
echo ""

# 僵尸进程 / D/U 状态进程
if [ "$OS_TYPE" = "Darwin" ]; then
    z_count=$(ps ax -o stat= 2>/dev/null | grep -c '^Z')
    u_count=$(ps ax -o stat= 2>/dev/null | grep -c '^U')
else
    z_count=$(ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="Z"' | wc -l | tr -d ' ')
    u_count=$(ps aux 2>/dev/null | awk 'NR>1 && substr($8,1,1)=="D"' | wc -l | tr -d ' ')
fi

proc_status="🟢 正常"
proc_note="无异常僵尸/阻塞进程"
if [ "$z_count" -gt 0 ]; then
    proc_status="🟡 关注"
    proc_note="存在 ${z_count} 个僵尸进程，检查父进程是否异常"
    add_bottleneck "yellow" "进程" "${z_count} 个僵尸进程"
fi
if [ "$u_count" -gt 0 ]; then
    proc_status="🟡 关注"
    proc_note="${proc_note}；存在 ${u_count} 个不可中断/IO 等待进程（D/U 状态）"
    add_bottleneck "yellow" "IO" "${u_count} 个 D/U 状态进程（磁盘 IO 阻塞）"
fi

echo "| 指标 | 数量 | 状态 |"
echo "|------|------|------|"
echo "| 僵尸进程 (Z) | ${z_count} | - |"
echo "| 不可中断/IO等待 (D/U) | ${u_count} | - |"
echo "| 综合评估 | - | ${proc_status} |"
echo ""
echo "> $proc_note"
echo ""

# ==============================================================================
# 6. 句柄与限制
# ==============================================================================
progress 6 7 "句柄与限制"
echo "## 6. 句柄与限制"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    KERN_FILES=$(read_sysctl "kern.num_files")
    KERN_MAXFILES=$(read_sysctl "kern.maxfiles")
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

fd_status="🟢 正常"
fd_note="文件句柄使用率正常"
if [ "$file_pct" != "N/A" ]; then
    pct_int=${file_pct%.*}
    if [ "$pct_int" -gt 90 ]; then
        fd_status="🔴 危险"
        fd_note="文件句柄使用率 ${file_pct}%，接近上限，可能拒绝新连接"
        add_bottleneck "red" "句柄" "文件句柄使用率 ${file_pct}%（> 90%）"
    elif [ "$pct_int" -gt 80 ]; then
        fd_status="🟡 偏高"
        fd_note="文件句柄使用率 ${file_pct}%，需关注"
        add_bottleneck "yellow" "句柄" "文件句柄使用率 ${file_pct}%（> 80%）"
    fi
fi

echo "| 指标 | 数值 | 使用率 | 状态 |"
echo "|------|------|--------|------|"
echo "| 系统句柄上限 | ${file_max} | - | - |"
echo "| 句柄使用率 | - | ${file_pct}% | ${fd_status} |"
echo ""
echo "> $fd_note"
echo ""

# ==============================================================================
# 7. 瓶颈结论汇总
# ==============================================================================
progress 7 7 "瓶颈结论汇总"
echo "## 7. 瓶颈结论汇总"
echo ""

total=${#BOTTLENECKS[@]}
if [ "$total" -eq 0 ]; then
    echo "> ✅ **未发现明显瓶颈**，系统各维度均处于健康区间。"
    echo ""
    echo "| 维度 | 总体结论 |"
    echo "|------|----------|"
    echo "| CPU | 🟢 健康 |"
    echo "| 内存 | 🟢 充足 |"
    echo "| 磁盘 | 🟢 健康 |"
    echo "| 网络 | 🟢 正常 |"
    echo "| 进程 | 🟢 正常 |"
    echo "| 句柄 | 🟢 正常 |"
    echo ""
else
    echo "> ⚠️ 共发现 **${total}** 项潜在瓶颈，按严重程度排列如下："
    echo ""
    echo "| 级别 | 维度 | 结论 |"
    echo "|------|------|------|"
    for item in "${BOTTLENECKS[@]}"; do
        IFS='|' read -r lvl dim desc <<< "$item"
        if [ "$lvl" = "red" ]; then icon="🔴"; else icon="🟡"; fi
        printf "| %s | %s | %s |\n" "$icon" "$dim" "$desc"
    done
    echo ""

    # 最关键瓶颈（第一个 red，否则第一个 yellow）
    first_red=""
    first_yellow=""
    for item in "${BOTTLENECKS[@]}"; do
        IFS='|' read -r lvl dim desc <<< "$item"
        if [ "$lvl" = "red" ] && [ -z "$first_red" ]; then first_red="$dim: $desc"; fi
        if [ "$lvl" = "yellow" ] && [ -z "$first_yellow" ]; then first_yellow="$dim: $desc"; fi
    done
    if [ -n "$first_red" ]; then
        echo "> 🎯 **最关键瓶颈:** $first_red"
    elif [ -n "$first_yellow" ]; then
        echo "> 🎯 **最需关注:** $first_yellow"
    fi
    echo ""
fi

echo "> 💡 建议：对标记维度运行专项脚本进一步深挖 —— CPU/内存见 \`cpu_mem_analyzer.sh\`，磁盘见 \`disk_analyzer.sh\`，网络见 \`network_analyzer.sh\`。"
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
echo "请分析以下系统瓶颈总览，重点关注："
echo "1. 综合瓶颈结论中排在最前的维度"
echo "2. 各维度的定量指标是否相互印证（如 D 状态进程多 + 磁盘使用率高 指向 IO 瓶颈）"
echo "3. 给出优先处理顺序与具体的专项排查命令"
echo '```'
echo ""
echo "> 📄 **报告已保存至:** \`$REPORT_PATH\`"

# 恢复 stdout 并输出
exec 1>&3
exec 3>&-
cat "$TMP_REPORT" | tee "$REPORT_PATH"
rm -f "$TMP_REPORT"

printf '\033[1;32m✅ 分析完成\033[0m 报告已保存至: %s\n' "$REPORT_PATH" >&3
echo ""
echo "✅ 系统瓶颈总览报告已生成: $REPORT_PATH"

# ==============================================================================
# 使用说明:
# 1. 直接运行: ./sys_overview.sh
# 2. 自定义输出: REPORT_PATH=/var/log/overview.md ./sys_overview.sh
# 3. 配合 crontab: 0 */6 * * * /path/to/sys_overview.sh
# ==============================================================================
