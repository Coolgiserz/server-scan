#!/bin/bash
# ==============================================================================
# 脚本名称: security_scanner.sh
# 功能说明: 检测服务器上是否安装/运行了杀毒软件或主机安全防护软件
#             通过 进程名 / systemd 服务 / 安装包 / 特征路径 多信号交叉检测
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL) / macOS (Intel/Apple Silicon)
# 依赖工具: ps, grep, awk; systemctl/rpm/dpkg (按系统可用性探测)
# 使用方法: chmod +x security_scanner.sh && ./security_scanner.sh
# 输出文件: 默认 /tmp/security_scan_$(date +%Y%m%d_%H%M%S).md
# ==============================================================================

# --- 配置区 ---
REPORT_PATH="/tmp/security_scan_$(date '+%Y%m%d_%H%M%S').md"

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cli.sh"

# 解析公共参数（必须在主shell中直接调用，不能命令替换）
ss::parse_common_args "$@"

# 脚本特定参数解析（当前无特定参数，仅处理 --help）
set -- "${SCRIPT_ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_SECURITY_HELP_DESC)" ""
        exit 0
        ;;
    *)
        ss::log_error "$(ss::msgf MSG_ERROR_UNKNOWN_ARG "$1")"
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_SECURITY_HELP_DESC)" ""
        exit 2
        ;;
    esac
done

# ==============================================================================
# 已知杀毒/安全防护软件特征库（只读检测，不做任何删除/停止操作）
# 格式: 名称|厂商|类别|进程模式|服务名|包名关键字|特征路径
# 说明: 字段内多个候选用空格分隔；字段为空表示无该信号；禁止在字段中使用 |
# ==============================================================================
AV_SIGNATURES=(
    "ClamAV|$(ss::msg MSG_SECURITY_VENDOR_CLAMAV)|$(ss::msg MSG_SECURITY_CAT_AV)|^clamd ^freshclam ^clamav-milter|clamav-daemon clamav-freshclam clamd|clamav|/etc/clamav /var/lib/clamav"
    "ESET NOD32|ESET|$(ss::msg MSG_SECURITY_CAT_AV)|^esets_daemon ^esets_service|esets|eset|/etc/opt/eset"
    "Kaspersky Endpoint Security|Kaspersky|$(ss::msg MSG_SECURITY_CAT_AV)|^kesl ^kav4fs|kesl|kesl kav4fs|/etc/opt/kaspersky /opt/kaspersky"
    "Trend Micro Deep Security|Trend Micro|$(ss::msg MSG_SECURITY_CAT_HOST)|^ds_agent ^dsa|ds_agent|trendmicro|/opt/ds_agent /var/opt/ds_agent"
    "Sophos Endpoint|Sophos|$(ss::msg MSG_SECURITY_CAT_HOST)|^savd ^savscand|sav-linux|sophos|/opt/sophos-av /etc/sav"
    "Symantec Endpoint Protection|Symantec|$(ss::msg MSG_SECURITY_CAT_HOST)|^symcfgd ^savscand ^snac|symantec|symantec|/opt/Symantec /etc/symantec"
    "McAfee Trellix|McAfee|$(ss::msg MSG_SECURITY_CAT_HOST)|^macmnsvc ^mfendisk ^vselogd|mfedisk|mcafee trellix|/opt/McAfee /var/McAfee"
    "Bitdefender GravityZone|Bitdefender|$(ss::msg MSG_SECURITY_CAT_HOST)|^bdagent ^bdredline|best|bitdefender|/etc/bd /opt/BitDefender"
    "Comodo Antivirus|Comodo|$(ss::msg MSG_SECURITY_CAT_AV)|^cmdagent|cmdav|comodo|/opt/COMODO /etc/cmdav"
    "F-PROT Antivirus|F-PROT|$(ss::msg MSG_SECURITY_CAT_AV)|^f-protd ^fpscand|f-prot|f-prot|/opt/f-prot"
    "Avast Antivirus|Avast|$(ss::msg MSG_SECURITY_CAT_AV)|^avastd|avast|avast|/etc/avast /var/lib/avast"
    "CrowdStrike Falcon|CrowdStrike|$(ss::msg MSG_SECURITY_CAT_EDR)|^falcon-sensor|falcon-sensor|falcon|/opt/CrowdStrike /etc/falcon"
    "SentinelOne|SentinelOne|$(ss::msg MSG_SECURITY_CAT_EDR)|^sentinelagent ^sentineld|sentinelone|sentinelone|/opt/sentinelone /etc/sentinelone"
    "Carbon Black|VMware|$(ss::msg MSG_SECURITY_CAT_EDR)|^cbagentd ^cbdaemon|cbagentd|carbonblack|/opt/cb /etc/carbonblack"
    "Wazuh Agent|Wazuh|$(ss::msg MSG_SECURITY_CAT_HOST)|^wazuh-agentd ^wazuh-modulesd|wazuh-agent|wazuh|/var/ossec"
    "ossec-hids|OSSEC|$(ss::msg MSG_SECURITY_CAT_HOST)|^ossec-agentd ^ossec-syscheckd|ossec|ossec|/var/ossec"
    "AliYunDun|Alibaba Cloud|$(ss::msg MSG_SECURITY_CAT_HOST)|^AliYunDun ^AliHids ^aliyun_assist|aegis|aegis aliyun-assist|/usr/local/aegis"
    "AliSecGuard|Alibaba Cloud|$(ss::msg MSG_SECURITY_CAT_HOST)|^AliSecGuard|aegis|aegis|/usr/local/aegis"
    "Tencent YunJing|Tencent Cloud|$(ss::msg MSG_SECURITY_CAT_HOST)|^YDService|-yd-service|ydservice|/usr/local/qcloud/YunJing"
    "QAX Safe|QAX|$(ss::msg MSG_SECURITY_CAT_HOST)|^qaxsafe ^qaxclient|qax|qax|/usr/local/qaxsafe /opt/qaxsafe"
    "Sangfor EDR|Sangfor|$(ss::msg MSG_SECURITY_CAT_EDR)|^sfedr|sfedr|sangfor|/usr/local/sangfor"
    "360 QClient|360|$(ss::msg MSG_SECURITY_CAT_HOST)|^qclient|360sd|360|/usr/local/qclient"
    "Huorong Linux|Huorong|$(ss::msg MSG_SECURITY_CAT_AV)|^hravd|huorong|huorong|/usr/local/hrav"
    # --- 国际主流 EDR / 漏洞管理 ---
    "Microsoft Defender for Endpoint|Microsoft|$(ss::msg MSG_SECURITY_CAT_EDR)|^wdavdaemon ^mdatp|mdatp|mdatp|/opt/microsoft/mdatp"
    "Palo Alto Cortex XDR|Palo Alto Networks|$(ss::msg MSG_SECURITY_CAT_EDR)|^traps ^pqt_service|traps|cortex-xdr|/opt/traps /etc/paloaltonetworks"
    "FortiClient Endpoint|Fortinet|$(ss::msg MSG_SECURITY_CAT_EDR)|^forticlientd ^fortiesmd|forticlient|forticlient|/opt/forticlient /etc/forticlient"
    "Qualys Cloud Agent|Qualys|$(ss::msg MSG_SECURITY_CAT_HOST)|^qualys-cloud-agent|qualys-cloud-agent|qualys-cloud-agent|/usr/local/qualys"
    "Tenable Nessus Agent|Tenable|$(ss::msg MSG_SECURITY_CAT_HOST)|^nessusd|nessus-agent|nessus-agent|/opt/nessus /Library/Nessus"
    # --- 国内云厂商 / 主机安全 ---
    "Huawei Cloud HSS|Huawei Cloud|$(ss::msg MSG_SECURITY_CAT_HOST)|^hostguard ^hostwatch|hostguard|hostguard|/usr/local/hostguard"
    "Qingteng WanXiang|Qingteng Cloud|$(ss::msg MSG_SECURITY_CAT_HOST)|^qtagent|qingteng|qingteng|/usr/local/qingteng"
    "Chaitin CloudWalker|Chaitin Tech|$(ss::msg MSG_SECURITY_CAT_HOST)|^cwagent|cloudwalker|cloudwalker|/usr/local/cloudwalker"
    "Yulong HIDS|YSRC|$(ss::msg MSG_SECURITY_CAT_HOST)|^yulong-agent|yulong-hids|yulong|/usr/local/yulong-hids /usr/yulong-hids"
    # --- macOS 专用安全工具 ---
    "Santa|North Pole Security|$(ss::msg MSG_SECURITY_CAT_HOST)|^santad|com.northpolesec.santa|santa|/opt/santa /usr/local/bin/santactl"
    "LuLu|Objective-See|$(ss::msg MSG_SECURITY_CAT_HOST)|^LuLu|lulu|lulu|/Applications/LuLu.app"
)

# 检测结果收集
declare -a FOUND_ITEMS=()   # 名称|厂商|类别|信号列表
add_found() {
    # $1=名称 $2=厂商 $3=类别 $4=信号描述
    FOUND_ITEMS+=("$1|$2|$3|$4")
}

# ==============================================================================
# 权限预检：判断当前用户能否看到所有进程
#    普通用户运行 ps 只能看到自己的进程，root 运行的杀毒守护进程会被漏检
# ==============================================================================
CAN_SEE_ALL_PROCS="true"
if [ "$OS_TYPE" = "Darwin" ]; then
    _test_pid=$(ps -eo pid= -o user= 2>/dev/null | awk '$2=="root" {print $1; exit}')
    if [ -n "$_test_pid" ] && ! ps -p "$_test_pid" -o comm= >/dev/null 2>&1; then
        CAN_SEE_ALL_PROCS="false"
    fi
else
    _test_pid=$(ps -eo pid= -o user= 2>/dev/null | awk '$2=="root" {print $1; exit}')
    if [ -n "$_test_pid" ] && [ ! -r "/proc/$_test_pid/comm" ]; then
        CAN_SEE_ALL_PROCS="false"
    fi
fi

# 报告开始（3 个章节：检测方法说明并入报告头，实际章节: 结果汇总/详情/结论）
ss::report_begin "$(ss::msg MSG_SECURITY_REPORT_TITLE)" 3

# ==============================================================================
# Markdown 报告头
# ==============================================================================
echo "# $(ss::msg MSG_SECURITY_TITLE)"
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
if [ "$CAN_SEE_ALL_PROCS" = "false" ]; then
    echo "> $(ss::msg MSG_SECURITY_PERM_HEADER)  "
fi
echo ""
echo "> $(ss::msg MSG_SECURITY_METHOD_HINT)"
echo ""
echo "---"
echo ""

# ==============================================================================
# 采集各检测信号（一次性采集，避免重复执行）
# ==============================================================================
ss::progress 1 3 "$(ss::msg MSG_SECURITY_SECTION_COLLECT)"

# 1) 进程列表快照
PS_SNAPSHOT="$(ps -eo comm= 2>/dev/null)"

# 2) systemd 服务列表（unit + 状态），不可用时为空
SYSTEMD_SNAPSHOT=""
if command -v systemctl >/dev/null 2>&1; then
    SYSTEMD_SNAPSHOT="$(systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null || true)"
fi

# 3) 已安装包清单快照
PKG_SNAPSHOT=""
PKG_TOOL=""
if command -v rpm >/dev/null 2>&1; then
    PKG_SNAPSHOT="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null || true)"
    PKG_TOOL="rpm"
elif command -v dpkg >/dev/null 2>&1; then
    PKG_SNAPSHOT="$(dpkg-query -W -f='${Package}\n' 2>/dev/null || true)"
    PKG_TOOL="dpkg"
fi

# ==============================================================================
# 1. 检测结果汇总
# ==============================================================================
ss::progress 2 3 "$(ss::msg MSG_SECURITY_SECTION_RESULT)"
echo "## 1. $(ss::msg MSG_SECURITY_SECTION_RESULT)"
echo ""

for sig in "${AV_SIGNATURES[@]}"; do
    IFS='|' read -r name vendor category proc_pattern svc_name pkg_keys feature_paths <<<"$sig"
    signals=()

    # --- 信号 A: 进程匹配 ---
    if [ -n "$proc_pattern" ]; then
        matched_procs=""
        for pat in $proc_pattern; do
            hit="$(echo "$PS_SNAPSHOT" | grep -E -- "$pat" | sort -u | head -5 || true)"
            if [ -n "$hit" ]; then
                matched_procs="${matched_procs}${hit}"$'\n'
            fi
        done
        matched_procs="$(echo "$matched_procs" | sort -u | grep -v '^$' | head -5 || true)"
        if [ -n "$matched_procs" ]; then
            signals+=("$(ss::msg MSG_SECURITY_SIGNAL_PROC): $(echo "$matched_procs" | tr '\n' ' ')")
        fi
    fi

    # --- 信号 B: systemd 服务匹配 ---
    if [ -n "$svc_name" ] && [ -n "$SYSTEMD_SNAPSHOT" ]; then
        matched_svcs=""
        for svc in $svc_name; do
            hit="$(echo "$SYSTEMD_SNAPSHOT" | grep -E -- "$svc" | awk '{print $1}' | sort -u | head -5 || true)"
            if [ -n "$hit" ]; then
                matched_svcs="${matched_svcs}${hit}"$'\n'
            fi
        done
        matched_svcs="$(echo "$matched_svcs" | sort -u | grep -v '^$' | head -5 || true)"
        if [ -n "$matched_svcs" ]; then
            signals+=("$(ss::msg MSG_SECURITY_SIGNAL_SVC): $(echo "$matched_svcs" | tr '\n' ' ')")
        fi
    fi

    # --- 信号 C: 安装包匹配 ---
    if [ -n "$pkg_keys" ] && [ -n "$PKG_SNAPSHOT" ]; then
        matched_pkgs=""
        for kw in $pkg_keys; do
            hit="$(echo "$PKG_SNAPSHOT" | grep -i -- "$kw" | sort -u | head -5 || true)"
            if [ -n "$hit" ]; then
                matched_pkgs="${matched_pkgs}${hit}"$'\n'
            fi
        done
        matched_pkgs="$(echo "$matched_pkgs" | sort -u | grep -v '^$' || true)"
        if [ -n "$matched_pkgs" ]; then
            signals+=("$(ss::msg MSG_SECURITY_SIGNAL_PKG) (${PKG_TOOL}): $(echo "$matched_pkgs" | tr '\n' ' ')")
        fi
    fi

    # --- 信号 D: 特征路径匹配 ---
    if [ -n "$feature_paths" ]; then
        matched_paths=""
        for p in $feature_paths; do
            if [ -e "$p" ]; then
                matched_paths="${matched_paths}${p} "
            fi
        done
        if [ -n "$matched_paths" ]; then
            signals+=("$(ss::msg MSG_SECURITY_SIGNAL_PATH): ${matched_paths}")
        fi
    fi

    # 任一信号命中即记录
    if [ ${#signals[@]} -gt 0 ]; then
        sig_desc="$(printf '%s; ' "${signals[@]}")"
        add_found "$name" "$vendor" "$category" "${sig_desc%; }"
    fi
done

total_found=${#FOUND_ITEMS[@]}

if [ "$total_found" -eq 0 ]; then
    echo "| $(ss::msg MSG_SECURITY_TABLE_PRODUCT) | $(ss::msg MSG_SECURITY_TABLE_VENDOR) | $(ss::msg MSG_SECURITY_TABLE_CATEGORY) | $(ss::msg MSG_SECURITY_TABLE_SIGNALS) |"
    echo "|------|------|------|------|"
    echo "| $(ss::msg MSG_SECURITY_NONE_FOUND) | - | - | - |"
    echo ""
    if [ "$CAN_SEE_ALL_PROCS" = "false" ]; then
        echo "> $(ss::msg MSG_SECURITY_PERM_LIMITED)"
        echo ""
    fi
else
    echo "| $(ss::msg MSG_SECURITY_TABLE_PRODUCT) | $(ss::msg MSG_SECURITY_TABLE_VENDOR) | $(ss::msg MSG_SECURITY_TABLE_CATEGORY) | $(ss::msg MSG_SECURITY_TABLE_SIGNALS) |"
    echo "|------|------|------|------|"
    for item in "${FOUND_ITEMS[@]}"; do
        IFS='|' read -r name vendor category sig_desc <<<"$item"
        printf "| %s | %s | %s | %s |\n" "$name" "$vendor" "$category" "$sig_desc"
    done
    echo ""
fi

# ==============================================================================
# 2. 检测方法与信号说明
# ==============================================================================
ss::progress 3 3 "$(ss::msg MSG_SECURITY_SECTION_METHOD)"
echo "## 2. $(ss::msg MSG_SECURITY_SECTION_METHOD)"
echo ""
echo "| $(ss::msg MSG_SECURITY_METHOD_SIGNAL) | $(ss::msg MSG_SECURITY_METHOD_DESC) | $(ss::msg MSG_SECURITY_METHOD_COVERAGE) |"
echo "|------|------|------|"
echo "| $(ss::msg MSG_SECURITY_SIGNAL_PROC) | $(ss::msg MSG_SECURITY_METHOD_PROC_DESC) | $(ss::msg MSG_SECURITY_METHOD_PROC_COV) |"
echo "| $(ss::msg MSG_SECURITY_SIGNAL_SVC) | $(ss::msg MSG_SECURITY_METHOD_SVC_DESC) | $(ss::msg MSG_SECURITY_METHOD_SVC_COV) |"
echo "| $(ss::msg MSG_SECURITY_SIGNAL_PKG) | $(ss::msg MSG_SECURITY_METHOD_PKG_DESC) | $(ss::msg MSG_SECURITY_METHOD_PKG_COV) |"
echo "| $(ss::msg MSG_SECURITY_SIGNAL_PATH) | $(ss::msg MSG_SECURITY_METHOD_PATH_DESC) | $(ss::msg MSG_SECURITY_METHOD_PATH_COV) |"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    echo "> ⚠️ $(ss::msg MSG_SECURITY_NOTE_MACOS)"
    echo ""
fi
if [ -z "$SYSTEMD_SNAPSHOT" ]; then
    echo "> ⚠️ $(ss::msg MSG_SECURITY_NOTE_NO_SYSTEMD)"
    echo ""
fi
if [ -z "$PKG_SNAPSHOT" ]; then
    echo "> ⚠️ $(ss::msg MSG_SECURITY_NOTE_NO_PKG)"
    echo ""
fi

# 权限检查结论
echo "| $(ss::msg MSG_SECURITY_PERM_CHECK) | $(ss::msg MSG_SECURITY_TABLE_SIGNALS) |"
echo "|------|------|"
if [ "$CAN_SEE_ALL_PROCS" = "true" ]; then
    echo "| $(ss::msg MSG_SECURITY_PERM_FULL) | - |"
else
    echo "| $(ss::msg MSG_SECURITY_PERM_LIMITED) | - |"
fi
echo ""

# ==============================================================================
# 3. 结论
# ==============================================================================
echo "## 3. $(ss::msg MSG_SECURITY_SECTION_CONCLUSION)"
echo ""

if [ "$total_found" -eq 0 ]; then
    if [ "$CAN_SEE_ALL_PROCS" = "false" ]; then
        echo "> $(ss::msg MSG_SECURITY_CONCLUSION_NONE_INCOMPLETE)"
    else
        echo "> ✅ $(ss::msg MSG_SECURITY_CONCLUSION_NONE)"
    fi
    echo ""
    echo "> $(ss::msg MSG_SECURITY_CONCLUSION_NONE_HINT)"
    echo ""
else
    echo "> $(ss::msgf MSG_SECURITY_CONCLUSION_FOUND "$total_found")"
    echo ""
    # 按类别统计
    av_count=0
    host_count=0
    edr_count=0
    for item in "${FOUND_ITEMS[@]}"; do
        IFS='|' read -r name vendor category sig_desc <<<"$item"
        case "$category" in
        "$(ss::msg MSG_SECURITY_CAT_AV)") av_count=$((av_count + 1)) ;;
        "$(ss::msg MSG_SECURITY_CAT_HOST)") host_count=$((host_count + 1)) ;;
        "$(ss::msg MSG_SECURITY_CAT_EDR)") edr_count=$((edr_count + 1)) ;;
        esac
    done
    echo "| $(ss::msg MSG_SECURITY_TABLE_CATEGORY) | $(ss::msg MSG_SECURITY_TABLE_COUNT) |"
    echo "|------|------|"
    if [ "$av_count" -gt 0 ]; then echo "| $(ss::msg MSG_SECURITY_CAT_AV) | $av_count |"; fi
    if [ "$host_count" -gt 0 ]; then echo "| $(ss::msg MSG_SECURITY_CAT_HOST) | $host_count |"; fi
    if [ "$edr_count" -gt 0 ]; then echo "| $(ss::msg MSG_SECURITY_CAT_EDR) | $edr_count |"; fi
    echo ""
    echo "> $(ss::msg MSG_SECURITY_CONCLUSION_FOUND_HINT)"
    echo ""
fi

# ==============================================================================
# 报告尾部
# ==============================================================================
echo "---"
echo ""
echo "## $(ss::msg MSG_SECURITY_APPENDIX)"
echo ""
echo "$(ss::msg MSG_SECURITY_APPENDIX_HINT)"
echo ""
echo '```'
echo "$(ss::msg MSG_SECURITY_APPENDIX_PROMPT1)"
echo "$(ss::msg MSG_SECURITY_APPENDIX_PROMPT2)"
echo '```'
echo ""
echo "> 📄 **$(ss::msg MSG_COMMON_REPORT_SAVED):** \`$REPORT_PATH\`"

# 报告结束
ss::report_end "$REPORT_PATH"

# JSON 输出
if [ "$JSON_OUTPUT" = "true" ]; then
    if [ "$total_found" -eq 0 ]; then
        summary="$(ss::msg MSG_SECURITY_JSON_SUMMARY_NONE)"
    else
        summary="$(ss::msgf MSG_SECURITY_JSON_SUMMARY_FOUND "$total_found")"
    fi
    if [ "$CAN_SEE_ALL_PROCS" = "false" ]; then
        summary="${summary} ($(ss::msg MSG_SECURITY_JSON_PERM_WARN))"
    fi
    found_list=$(
        IFS=';'
        echo "${FOUND_ITEMS[*]}"
    )
    ss::print_json_metadata "success" "$REPORT_PATH" "security_scanner.sh" 0 "$summary" "$found_list"
fi

# 显式退出码：检测到防护软件时返回 1（与 sys_overview.sh 保持一致的约定）
if [ "$total_found" -gt 0 ]; then
    exit 1
else
    exit 0
fi

# ==============================================================================
# 使用说明:
# 1. 直接运行: ./security_scanner.sh
# 2. 自定义输出: ./security_scanner.sh -o /var/log/security_scan.md
# 3. 静默模式: ./security_scanner.sh --quiet
# 4. JSON 输出: ./security_scanner.sh --json
# ==============================================================================
