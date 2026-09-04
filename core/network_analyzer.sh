#!/bin/bash
# ==============================================================================
# 脚本名称: network_analyzer.sh
# 功能说明: 网络专项排查，采集接口、连通性、连接数、端口监听、DNS、丢包与延迟等
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL) / macOS (Intel/Apple Silicon)
# 依赖工具: ip/ss (Linux) 或 ifconfig/netstat (macOS), ping, bc, curl/dig(可选)
# 安装依赖:
#   CentOS: yum install -y iproute procps-ng bind-utils
#   Ubuntu: apt install -y iproute2 procps dnsutils
#   macOS:  brew install coreutils (可选，提供 gtimeout)
# 使用方法: chmod +x network_analyzer.sh && ./network_analyzer.sh
# 输出文件: 默认 /tmp/network_report_$(date +%Y%m%d_%H%M%S).md
# ==============================================================================

# --- 配置区 ---
# 留空表示使用默认产物路径（$OUTPUT_DIR/network/），
# 可通过 -o 参数或 REPORT_PATH 环境变量覆盖
REPORT_PATH="${REPORT_PATH:-}"

# 连通性探测目标（可覆盖: PING_TARGETS="8.8.8.8 1.1.1.1" ./network_analyzer.sh）
PING_TARGETS="${PING_TARGETS:-8.8.8.8 1.1.1.1}"

# DNS 解析测试域名
DNS_TARGETS="${DNS_TARGETS:-www.baidu.com www.google.com}"

# 单次 ping 超时（秒）
PING_TIMEOUT=3

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
    --ping-targets)
        if [[ -n "$2" && "$2" != -* ]]; then
            PING_TARGETS="$2"
            shift 2
        else
            ss::log_error "$(ss::msgf MSG_NET_ERR_PING "--ping-targets")"
            exit 2
        fi
        ;;
    --dns-targets)
        if [[ -n "$2" && "$2" != -* ]]; then
            DNS_TARGETS="$2"
            shift 2
        else
            ss::log_error "$(ss::msgf MSG_NET_ERR_DNS "--dns-targets")"
            exit 2
        fi
        ;;
    -h | --help)
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_NET_HELP_DESC)" "$(ss::msg MSG_NET_HELP_PING_TARGETS)
$(ss::msg MSG_NET_HELP_DNS_TARGETS)"
        exit 0
        ;;
    *)
        # 忽略其他参数
        shift
        ;;
    esac
done

# 未通过 -o 指定时，使用默认产物路径（$OUTPUT_DIR/network/）
if [ -z "$REPORT_PATH" ]; then
    REPORT_PATH="$(ss::default_report_path network)"
fi

# 报告开始
ss::report_begin "$(ss::msg MSG_NET_REPORT_BEGIN)" 8

# ==============================================================================
# Markdown 报告头
# ==============================================================================
echo "# $(ss::msg MSG_NET_REPORT_TITLE)"
echo ""
if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
else
    OS_NAME="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Linux')"
fi
echo "> **$(ss::msg MSG_NET_LABEL_HOSTNAME):** $(hostname)  "
echo "> **$(ss::msg MSG_NET_LABEL_COLLECT_TIME):** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **$(ss::msg MSG_NET_LABEL_REPORT_FILE):** \`$REPORT_PATH\`  "
echo "> **$(ss::msg MSG_NET_LABEL_OS):** ${OS_NAME}  "
echo "> **$(ss::msg MSG_NET_LABEL_KERNEL):** $(uname -r)  "
echo ""
echo "---"
echo ""

# ==============================================================================
# 1. 网络接口信息
# ==============================================================================
ss::progress 1 8 "$(ss::msg MSG_NET_SECTION_IFACE)"
echo "## 1. $(ss::msg MSG_NET_SECTION_IFACE)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "| $(ss::msg MSG_NET_IFACE_HDR) |"
    echo "|------|-----|---------|------|-----|"
    for iface in $(ifconfig 2>/dev/null | grep -E '^[a-z0-9]+:' | awk -F: '{print $1}'); do
        [ "$iface" = "lo0" ] && continue
        mac=$(ifconfig "$iface" 2>/dev/null | awk '/ether/ {print $2; exit}')
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2; exit}')
        status=$(ifconfig "$iface" 2>/dev/null | awk -F': ' '/status/ {print $2; exit}')
        [ "$status" = "active" ] && st="🟢 UP" || st="⚪ DOWN"
        mtu=$(ifconfig "$iface" 2>/dev/null | awk -F': ' '/mtu/ {print $2; exit}')
        printf "| %s | %s | %s | %s | %s |\n" "$iface" "${mac:-N/A}" "${ip:-N/A}" "$st" "${mtu:-N/A}"
    done
    echo ""
else
    echo "| $(ss::msg MSG_NET_IFACE_HDR) |"
    echo "|------|-----|---------|------|-----|"
    for iface in $(ls /sys/class/net 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        mac=$(cat /sys/class/net/$iface/address 2>/dev/null)
        operstate=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
        [ "$operstate" = "up" ] && st="🟢 UP" || st="⚪ DOWN"
        mtu=$(cat /sys/class/net/$iface/mtu 2>/dev/null)
        ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet/ {print $2; exit}')
        printf "| %s | %s | %s | %s | %s |\n" "$iface" "${mac:-N/A}" "${ip:-N/A}" "$st" "${mtu:-N/A}"
    done
    echo ""
fi

# ==============================================================================
# 2. 路由与默认网关
# ==============================================================================
ss::progress 2 8 "$(ss::msg MSG_NET_SECTION_ROUTE)"
echo "## 2. $(ss::msg MSG_NET_SECTION_ROUTE)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "### $(ss::msg MSG_NET_ROUTE_TABLE) (netstat -rn)"
    echo ""
    echo '```'
    netstat -rn 2>/dev/null | head -40
    echo '```'
    gw=$(netstat -rn 2>/dev/null | awk '/default/ {print $2; exit}')
else
    echo "### $(ss::msg MSG_NET_ROUTE_TABLE) (ip route)"
    echo ""
    echo '```'
    ip route 2>/dev/null | head -40
    echo '```'
    gw=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
fi
echo ""
if [ -n "$gw" ]; then
    echo "> **$(ss::msg MSG_NET_LABEL_DEFAULT_GW):** \`$gw\`"
else
    echo "> $(ss::msg MSG_NET_WARN_NO_GW)"
fi
echo ""

# ==============================================================================
# 3. 连通性探测（ICMP 延迟与丢包）
# ==============================================================================
ss::progress 3 8 "$(ss::msg MSG_NET_SECTION_PING)"
echo "## 3. $(ss::msg MSG_NET_SECTION_PING)"
echo ""
echo "> **$(ss::msg MSG_NET_PING_CRITERIA):** $(ss::msg MSG_NET_PING_CRITERIA_DESC)"
echo ""
echo "| $(ss::msg MSG_NET_PING_HDR) |"
echo "|------|----------|--------|----------|----------|----------|"

for target in $PING_TARGETS; do
    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS ping: -c 5 发5个包, -t 超时
        result=$(ss::run_with_timeout $((PING_TIMEOUT * 5 + 2)) ping -c 5 -t $PING_TIMEOUT "$target" 2>/dev/null)
    else
        result=$(ss::run_with_timeout $((PING_TIMEOUT * 5 + 2)) ping -c 5 -W $PING_TIMEOUT "$target" 2>/dev/null)
    fi

    if [ -z "$result" ]; then
        printf "| %s | $(ss::msg MSG_NET_STATUS_UNREACHABLE) | - | - | - | - |\n" "$target"
        continue
    fi

    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS 输出: "5 packets transmitted, 0 packets received, 100.0% packet loss"
        # "round-trip min/avg/max/stddev = 10.1/12.3/15.6/1.2 ms"
        loss=$(echo "$result" | grep "packet loss" | awk -F', ' '{print $3}' | awk '{print $1}')
        rt=$(echo "$result" | grep "round-trip" | awk -F'= ' '{print $2}')
        min=$(echo "$rt" | awk -F'/' '{print $1}')
        avg=$(echo "$rt" | awk -F'/' '{print $2}')
        max=$(echo "$rt" | awk -F'/' '{print $3}')
    else
        # Linux 输出: "5 packets transmitted, 5 received, 0% packet loss, time ..."
        # "rtt min/avg/max/mdev = 10.1/12.3/15.6/1.2 ms"
        loss=$(echo "$result" | grep "packet loss" | awk -F', ' '{print $3}' | awk '{print $1}')
        rt=$(echo "$result" | grep "rtt" | awk -F'= ' '{print $2}')
        min=$(echo "$rt" | awk -F'/' '{print $1}')
        avg=$(echo "$rt" | awk -F'/' '{print $2}')
        max=$(echo "$rt" | awk -F'/' '{print $3}')
    fi

    loss_num=$(echo "$loss" | sed 's/%//')
    if [ -n "$loss_num" ] && [ "$(echo "$loss_num > 20" | bc 2>/dev/null || echo 0)" = "1" ]; then
        reach="$(ss::msg MSG_NET_STATUS_SEVERE_LOSS)"
    elif [ -n "$loss_num" ] && [ "$(echo "$loss_num > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
        reach="$(ss::msg MSG_NET_STATUS_MINOR_LOSS)"
    else
        reach="$(ss::msg MSG_NET_STATUS_NORMAL)"
    fi

    printf "| %s | %s | %s | %s | %s | %s |\n" "$target" "$reach" "${loss:-N/A}" "${min:-N/A}" "${avg:-N/A}" "${max:-N/A}"
done
echo ""

# ==============================================================================
# 4. 监听端口与服务
# ==============================================================================
ss::progress 4 8 "$(ss::msg MSG_NET_SECTION_PORT)"
echo "## 4. $(ss::msg MSG_NET_SECTION_PORT)"
echo ""

if command -v ss >/dev/null 2>&1 && [ "$OS_TYPE" != "Darwin" ]; then
    echo "| $(ss::msg MSG_NET_PORT_HDR) |"
    echo "|------|---------------|------|"
    ss -tulnp 2>/dev/null | tail -n +2 | while read -r proto recvq sendq local foreign state pid prog; do
        printf "| %s | %s | %s |\n" "$proto" "$local" "${prog:-N/A}"
    done
    echo ""
elif command -v netstat >/dev/null 2>&1; then
    echo "| $(ss::msg MSG_NET_PORT_HDR) |"
    echo "|------|---------------|------|"
    if [ "$OS_TYPE" = "Darwin" ]; then
        netstat -an -p tcp 2>/dev/null | grep LISTEN | while read -r proto recvq sendq local foreign state; do
            printf "| %s | %s | %s |\n" "$proto" "$local" "N/A"
        done
        netstat -an -p udp 2>/dev/null | grep -v "Address" | awk '$6=="*.{*}" || $6!="0.0.0.0:*"' | head -20 | while read -r proto recvq sendq local foreign state; do
            printf "| %s | %s | %s |\n" "$proto" "$local" "N/A"
        done
    else
        netstat -tulnp 2>/dev/null | tail -n +3 | while read -r proto recvq sendq local foreign state pid prog; do
            printf "| %s | %s | %s |\n" "$proto" "$local" "${prog:-N/A}"
        done
    fi
    echo ""
else
    echo "> $(ss::msg MSG_NET_WARN_NO_SS_NETSTAT)"
    echo ""
fi

# ==============================================================================
# 5. 活跃连接与连接数统计
# ==============================================================================
ss::progress 5 8 "$(ss::msg MSG_NET_SECTION_CONN)"
echo "## 5. $(ss::msg MSG_NET_SECTION_CONN)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    conn_out=$(netstat -an 2>/dev/null)
else
    conn_out=$(ss -an 2>/dev/null)
fi

if [ "$OS_TYPE" = "Darwin" ]; then
    total_conn=$(echo "$conn_out" | grep -E '^(tcp|udp)' | wc -l | tr -d ' ')
    est=$(echo "$conn_out" | grep -i "ESTABLISHED" | wc -l | tr -d ' ')
    time_wait=$(echo "$conn_out" | grep -i "TIME_WAIT" | wc -l | tr -d ' ')
    close_wait=$(echo "$conn_out" | grep -i "CLOSE_WAIT" | wc -l | tr -d ' ')
    fin_wait=$(echo "$conn_out" | grep -iE "FIN_WAIT" | wc -l | tr -d ' ')
else
    total_conn=$(echo "$conn_out" | grep -E '^(tcp|udp)' | wc -l | tr -d ' ')
    est=$(echo "$conn_out" | grep -i "ESTAB" | wc -l | tr -d ' ')
    time_wait=$(echo "$conn_out" | grep -i "TIME-WAIT" | wc -l | tr -d ' ')
    close_wait=$(echo "$conn_out" | grep -i "CLOSE-WAIT" | wc -l | tr -d ' ')
    fin_wait=$(echo "$conn_out" | grep -iE "FIN-WAIT" | wc -l | tr -d ' ')
fi

# 连接数压力判定
conn_status="$(ss::msg MSG_NET_STATUS_NORMAL)"
conn_note="$(ss::msg MSG_NET_CONN_NOTE_NORMAL)"
if [ "$close_wait" -gt 100 ]; then
    conn_status="$(ss::msg MSG_NET_STATUS_ABNORMAL)"
    conn_note="$(ss::msgf MSG_NET_CONN_NOTE_CLOSE_WAIT "$close_wait")"
elif [ "$time_wait" -gt 10000 ]; then
    conn_status="$(ss::msg MSG_NET_STATUS_HIGH)"
    conn_note="$(ss::msgf MSG_NET_CONN_NOTE_TIME_WAIT "$time_wait")"
fi

echo "| $(ss::msg MSG_NET_CONN_HDR) |"
echo "|------|------|------|"
echo "| $(ss::msg MSG_NET_ROW_TOTAL_CONN) | ${total_conn} | - |"
echo "| ESTABLISHED | ${est} | - |"
echo "| TIME_WAIT | ${time_wait} | - |"
echo "| CLOSE_WAIT | ${close_wait} | - |"
echo "| FIN_WAIT | ${fin_wait} | - |"
echo "| $(ss::msg MSG_NET_ROW_EVAL) | - | ${conn_status} |"
echo ""
echo "> $conn_note"
echo ""

# 按远程 IP 统计 TOP 连接（定位异常流量来源）
echo "### $(ss::msg MSG_NET_SUBSECTION_TOP10)"
echo ""
if [ "$OS_TYPE" = "Darwin" ]; then
    echo "$conn_out" | grep -iE "ESTABLISHED" | awk '{print $5}' | grep -oE '^[0-9.]+' | sort | uniq -c | sort -rn | head -10 | while read -r cnt ip; do
        printf "| %s | %s |\n" "$ip" "$cnt"
    done
else
    echo "$conn_out" | grep -iE "ESTAB" | awk '{print $5}' | grep -oE '^[0-9.]+' | sort | uniq -c | sort -rn | head -10 | while read -r cnt ip; do
        printf "| %s | %s |\n" "$ip" "$cnt"
    done
fi
echo ""
echo "| $(ss::msg MSG_NET_REMOTE_IP_HDR) |"
echo "|---------|--------|"
echo ""

# ==============================================================================
# 6. DNS 解析测试
# ==============================================================================
ss::progress 6 8 "$(ss::msg MSG_NET_SECTION_DNS)"
echo "## 6. $(ss::msg MSG_NET_SECTION_DNS)"
echo ""

# 当前 DNS 服务器
if [ "$OS_TYPE" = "Darwin" ]; then
    dns_servers=$(scutil --dns 2>/dev/null | grep "nameserver\[" | awk '{print $3}' | sort -u | tr '\n' ' ')
else
    dns_servers=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
fi
echo "> **$(ss::msg MSG_NET_LABEL_CURRENT_DNS):** ${dns_servers:-N/A}"
echo ""

echo "| $(ss::msg MSG_NET_DNS_HDR) |"
echo "|------|----------|----------|------|"
for domain in $DNS_TARGETS; do
    start_ts=$(date +%s%3N 2>/dev/null || date +%s)
    if command -v dig >/dev/null 2>&1; then
        resolved=$(dig +short +time=2 +tries=1 "$domain" 2>/dev/null | head -1)
    elif command -v getent >/dev/null 2>&1; then
        resolved=$(getent hosts "$domain" 2>/dev/null | awk '{print $1; exit}')
    else
        resolved=""
    fi
    end_ts=$(date +%s%3N 2>/dev/null || date +%s)
    cost=$((end_ts - start_ts))
    if [ -n "$resolved" ]; then
        printf "| %s | %s | %s | $(ss::msg MSG_NET_DNS_RESOLVED) |\n" "$domain" "$resolved" "$cost"
    else
        printf "| %s | $(ss::msg MSG_NET_DNS_FAILED) | %s | $(ss::msg MSG_NET_DNS_FAIL_STATUS) |\n" "$domain" "$cost"
    fi
done
echo ""

# ==============================================================================
# 7. 网卡流量统计（累计收发包/字节）
# ==============================================================================
ss::progress 7 8 "$(ss::msg MSG_NET_SECTION_TRAFFIC)"
echo "## 7. $(ss::msg MSG_NET_SECTION_TRAFFIC)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS 通过 netstat -ib 获取每接口收发统计
    echo "| $(ss::msg MSG_NET_TRAFFIC_HDR_MAC) |"
    echo "|------|--------|--------|----------|----------|-----------|"
    netstat -ib 2>/dev/null | awk 'NR>1 && $1!="Name" && $1!~/(lo|gif|stf|bridge|vnic)/ {
        iface=$1
        rx_pkt=$5; tx_pkt=$6
        rx_byte=$7; tx_byte=$8
        # 第9列开始为错误/丢包
        err=$9
        printf "| %s | %s | %s | %s | %s | %s |\n", iface, rx_pkt, tx_pkt, rx_byte, tx_byte, err
    }' | head -20
    echo ""
    echo "> $(ss::msg MSG_NET_TRAFFIC_NOTE_MAC)"
    echo ""
else
    echo "| $(ss::msg MSG_NET_TRAFFIC_HDR_LNX) |"
    echo "|------|--------|--------|----------|----------|------|--------|"
    while read -r iface rest; do
        [ "$iface" = "Inter-|" ] && continue
        iface=${iface%:}
        [ "$iface" = "lo" ] && continue
        set -- $rest
        # /proc/net/dev 列: rx_bytes rx_packets rx_err rx_drop ... tx_bytes tx_packets ...
        rx_bytes=$1
        rx_pkts=$2
        rx_err=$3
        rx_drop=$4
        tx_bytes=$9
        tx_pkts=${10}
        tx_drop=${11}
        printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
            "$iface" "$rx_pkts" "$tx_pkts" "$(ss::hr_bytes $rx_bytes)" "$(ss::hr_bytes $tx_bytes)" "$rx_err" "$tx_drop"
    done </proc/net/dev
    echo ""
fi

# ==============================================================================
# 8. 网络相关内核参数（TCP 调优与防护）
# ==============================================================================
ss::progress 8 8 "$(ss::msg MSG_NET_SECTION_KERNEL)"
echo "## 8. $(ss::msg MSG_NET_SECTION_KERNEL)"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "> $(ss::msg MSG_NET_KERNEL_NOTE_MAC)"
    echo ""
    echo "| $(ss::msg MSG_NET_KERNEL_HDR_MAC) |"
    echo "|------|-----|"
    echo "| net.inet.tcp.msl | $(ss::read_sysctl net.inet.tcp.msl) |"
    echo "| kern.ipc.somaxconn | $(ss::read_sysctl kern.ipc.somaxconn) |"
    echo ""
else
    echo "| $(ss::msg MSG_NET_KERNEL_HDR_LNX) |"
    echo "|------|-----|------|"
    tw_reuse=$(cat /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null)
    tw_recycle=$(cat /proc/sys/net/ipv4/tcp_tw_recycle 2>/dev/null || echo "N/A($(ss::msg MSG_NET_KERNEL_TW_RECYCLE_REMOVED))")
    somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null)
    max_conn=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || cat /proc/sys/net/nf_conntrack_max 2>/dev/null || echo "N/A")
    echo "| net.ipv4.tcp_tw_reuse | ${tw_reuse:-N/A} | $(ss::msg MSG_NET_KERNEL_DESC_TW_REUSE) |"
    echo "| net.ipv4.tcp_tw_recycle | ${tw_recycle} | $(ss::msg MSG_NET_KERNEL_DESC_TW_RECYCLE) |"
    echo "| net.core.somaxconn | ${somaxconn:-N/A} | $(ss::msg MSG_NET_KERNEL_DESC_SOMAXCONN) |"
    echo "| nf_conntrack_max | ${max_conn} | $(ss::msg MSG_NET_KERNEL_DESC_CONNTRACK) |"
    echo ""
    echo "> $(ss::msg MSG_NET_KERNEL_TIP)"
    echo ""
fi

# ==============================================================================
# 报告尾部
# ==============================================================================
echo "---"
echo ""
echo "## $(ss::msg MSG_NET_APPENDIX)"
echo ""
echo "$(ss::msg MSG_NET_APPENDIX_HINT)"
echo ""
echo '```'
echo "$(ss::msg MSG_NET_APPENDIX_PROMPT)"
echo "1. ICMP 探测的丢包率与延迟是否异常，是否为单一目标还是普遍问题"
echo "2. CLOSE_WAIT / TIME_WAIT 是否过高，是否存在连接泄漏"
echo "3. 监听端口是否有异常暴露，是否有非预期进程监听"
echo "4. DNS 解析是否失败或超时"
echo "5. 网卡是否有错误/丢包计数持续增长"
echo "6. 给出具体的排查命令或内核参数调优建议"
echo '```'
echo ""
echo "> $(ss::msg MSG_NET_REPORT_SAVED) \`$REPORT_PATH\`"

# 报告结束
ss::report_end "$REPORT_PATH"

# JSON 输出
if [ "$JSON_OUTPUT" = "true" ]; then
    summary="$(ss::msg MSG_NET_JSON_SUMMARY)"
    ss::print_json_metadata "success" "$REPORT_PATH" "network_analyzer.sh" 0 "$summary" ""
fi

# 通知推送（未启用 --notify 时静默跳过，推送失败不影响主流程）
ss::notify_send "$(ss::msg MSG_NET_REPORT_TITLE)" "$REPORT_PATH" || true

# 显式退出码
exit 0

# ==============================================================================
# 使用说明:
# 1. 直接运行: ./network_analyzer.sh
# 2. 自定义探测目标: ./network_analyzer.sh --ping-targets "8.8.8.8 223.5.5.5"
# 3. 自定义 DNS 目标: ./network_analyzer.sh --dns-targets "www.baidu.com www.google.com"
# 4. 修改输出路径: ./network_analyzer.sh -o /var/log/net.md
# 5. 静默模式: ./network_analyzer.sh --quiet
# 6. JSON 输出: ./network_analyzer.sh --json
# 7. 配合 crontab: 0 * * * * /path/to/network_analyzer.sh
# ==============================================================================
