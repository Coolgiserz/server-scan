#!/bin/bash
# ==============================================================================
# 脚本名称: service_monitor.sh
# 描述:   宿主机服务健康扫描。按「systemd unit 状态 + 进程名 + 端口监听」
#         三路信号组合判定指定服务（redis/mysql/mongod 等）是否正常运行。
#         服务列表通过配置文件 SERVICE_NAMES 自定义，也可用命令行
#         --service 临时追加；常见服务内置 unit 名/进程名/默认端口映射，
#         支持 SERVICE_<大写服务名>_UNIT / _PROCESS / _PORT 按服务覆盖。
#         检测到异常时写入告警库并通过飞书通知（notify.sh）推送摘要，
#         通知正文包含异常服务名、异常状态与检测时间。
#         是否发送由统一配置 NOTIFY_ON_ALERT_ONLY 决定（true 仅异常推送，false 正常也推）。
#         单次扫描模型，适配 crontab 或外部定时调度系统触发。
# 依赖:   ps/awk/grep/sed/tr/sort；Linux: ss（兜底 netstat）、systemctl（可选）；
#         macOS: netstat（无 systemd，自动跳过 unit 信号）
# 退出码: 0=正常 1=存在告警 2=参数错误
# ==============================================================================

set -euo pipefail

REPORT_PATH="${REPORT_PATH:-}"

# 服务扫描默认配置（可通过配置文件 SERVICE_* 或命令行覆盖）
SERVICE_NAMES="${SERVICE_NAMES:-}"
SERVICE_PROBE_TIMEOUT="${SERVICE_PROBE_TIMEOUT:-5}"

# 定位项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../lib/cli.sh
source "$SCRIPT_DIR/lib/cli.sh"
# shellcheck source=../lib/alerts.sh
source "$SCRIPT_DIR/lib/alerts.sh"

# --- 配置初始化（加载 server-scan.conf 中 SERVICE_ 前缀项） ---
ss::config_init SERVICE_
ss::parse_common_args "$@"
ss::config_reload

# --- 脚本特有参数 ---
# 无条件声明，避免 bash 3.2 + set -u 下引用未声明数组报 unbound
_CLI_SERVICES=()

# 帮助文本（脚本特有选项）
_SS_SERVICE_OPTIONS_HELP="  --service NAME       $(ss::msg MSG_SERVICE_HELP_SERVICE)"

# 解析脚本特有参数（公共参数已在 ss::parse_common_args 中处理）
# 空数组在 bash 3.2 + set -u 下直接展开会报未绑定，故按计数保护
if [ ${#SCRIPT_ARGS[@]} -gt 0 ]; then
    set -- "${SCRIPT_ARGS[@]}"
else
    set --
fi
while [ $# -gt 0 ]; do
    case "$1" in
    --service)
        if [ $# -lt 2 ]; then
            ss::log_error "$(ss::msg MSG_SERVICE_ERR_SERVICE_ARG)"
            exit 2
        fi
        _CLI_SERVICES+=("$2")
        shift 2
        ;;
    --service=*)
        _CLI_SERVICES+=("${1#*=}")
        shift
        ;;
    -h | --help)
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_SERVICE_HELP_DESC)" "$_SS_SERVICE_OPTIONS_HELP"
        exit 0
        ;;
    *)
        ss::log_error "$(ss::msgf MSG_ERROR_UNKNOWN_ARG "$1")"
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_SERVICE_HELP_DESC)" "$_SS_SERVICE_OPTIONS_HELP"
        exit 2
        ;;
    esac
done

# --- SERVICE_PROBE_TIMEOUT 合法性校验（非法回退默认值 5 秒） ---
case "$SERVICE_PROBE_TIMEOUT" in
'' | *[!0-9]*)
    if [ "$QUIET" != "true" ]; then
        printf '\033[1;33m⚠️  %s\033[0m\n' \
            "$(ss::msgf MSG_SERVICE_WARN_TIMEOUT_INVALID "$SERVICE_PROBE_TIMEOUT" "5")" >&2
    fi
    SERVICE_PROBE_TIMEOUT=5
    ;;
esac

# --- 监控目标构建 ---
# 来源：配置文件 SERVICE_NAMES（空格/逗号分隔） + 命令行 --service（可重复）
# 统一转小写后去重，保持用户输入顺序
SERVICE_TARGETS=()
_service_raw="$(printf '%s' "$SERVICE_NAMES" | tr ',' ' ')"
if [ ${#_CLI_SERVICES[@]} -gt 0 ]; then
    _service_raw="$_service_raw ${_CLI_SERVICES[*]}"
fi
# set -f 关闭路径名扩展：防止含 * ? [ 的 token 被 glob 展开成文件名
set -f
for _t in $(printf '%s' "$_service_raw" | tr ' \t,' '\n\n\n' | sed '/^$/d' | tr '[:upper:]' '[:lower:]' | awk 'NF && !seen[$0]++'); do
    SERVICE_TARGETS+=("$_t")
done
set +f
NO_TARGETS=false
if [ ${#SERVICE_TARGETS[@]} -eq 0 ]; then
    NO_TARGETS=true
fi

# --- 进程可见性预检（非 root 时部分进程不可见，判定需降级防误报） ---
CAN_SEE_ALL_PROCS="true"
# awk 提前 exit 会使 ps 收到 SIGPIPE，pipefail 下需 || true 兜底
_test_pid=$(ps -eo pid= -o user= 2>/dev/null | awk '$2=="root" {print $1; exit}' || true)
# 判定口径：ps 能否实际读到 root 进程名（跨平台一致）。不用 /proc/<pid>/comm
# 可读性判定：Linux 4.10 起该文件为 0400，非 root 恒不可读，但 ps 经
# /proc/<pid>/stat 仍能列出全部进程名，旧判定会在非 root cron 场景误报
# 可见性受限，把「进程缺失且无端口佐证」的真实 critical 降级为 warning
if [ -n "$_test_pid" ] && [ -z "$(ps -p "$_test_pid" -o comm= 2>/dev/null)" ]; then
    CAN_SEE_ALL_PROCS="false"
fi

# --- 检测时间戳（统一嵌入告警详情，满足通知含检测时间的要求） ---
SCAN_TS="$(date '+%Y-%m-%d %H:%M:%S')"

# ==============================================================================
# 一次性快照采集：无论监控多少个服务，进程/systemd/端口各只探测一次
# ==============================================================================

# --- 快照 1: 进程表（comm 精确词匹配 + args 词匹配，覆盖 java 类与改标题进程） ---
# args 快照按 PID/PPID 排除自身（$$）与命令替换 fork 的同 argv 子 shell
# （ppid==$$），避免 --service 参数中的服务名造成误报；不按名称/路径子串
# 过滤：不受 ps 输出宽度截断与调用路径形态影响，也不会误杀部署路径含
# 脚本名的合法进程
PS_COMM_SNAPSHOT="$(ps -eo comm= 2>/dev/null || true)"
PS_ARGS_SNAPSHOT="$(ps -eo pid=,ppid=,args= 2>/dev/null |
    awk -v self="$$" '$1 != self && $2 != self {
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, ""); print
     }' || true)"
# args 命令行位置快照（每行仅取第一个字段），供普通候选名做命令名匹配，
# 避免无关进程参数文本中出现服务名（如 tail -f /var/log/redis.log）造成误报
PS_ARGS_CMD_SNAPSHOT="$(printf '%s\n' "$PS_ARGS_SNAPSHOT" | awk 'NF {print $1}')"

# --- 快照 2: systemd unit 状态表（Linux 且 systemd 真实可用时） ---
SYSTEMD_OK=false
SYSTEMD_SNAPSHOT=""
if [ "$OS_TYPE" = "Linux" ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    _systemd_raw="$(ss::run_with_timeout "$SERVICE_PROBE_TIMEOUT" systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null || true)"
    if [ -n "$_systemd_raw" ]; then
        # 去掉行首可能的 ● / * 等标记字符，保证 $1 为 unit 名
        SYSTEMD_SNAPSHOT="$(printf '%s\n' "$_systemd_raw" | sed 's/^[^A-Za-z0-9_.]*//')"
        SYSTEMD_OK=true
    fi
fi

# --- 快照 3: TCP LISTEN 端口表（归一化为空格包围串 " 22 80 6379 "） ---
# 选 ss/netstat 解析而非 /dev/tcp 实连：语义准确且无副作用（不触发服务端连接日志）
LISTEN_PORTS=" "
_snapshot_listen_ports() {
    local raw=""
    if [ "$OS_TYPE" = "Linux" ]; then
        if command -v ss >/dev/null 2>&1; then
            raw="$(ss::run_with_timeout "$SERVICE_PROBE_TIMEOUT" ss -ltn 2>/dev/null |
                awk 'NR>1 {n=split($4,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n]}' || true)"
        elif command -v netstat >/dev/null 2>&1; then
            raw="$(ss::run_with_timeout "$SERVICE_PROBE_TIMEOUT" netstat -ltn 2>/dev/null |
                awk '$1 ~ /^tcp/ {n=split($4,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n]}' || true)"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        # macOS: netstat -an -p tcp，本地地址形如 *.6379 / 127.0.0.1.631（点号分隔）
        raw="$(ss::run_with_timeout "$SERVICE_PROBE_TIMEOUT" netstat -an -p tcp 2>/dev/null |
            awk '$1 ~ /^tcp/ && $NF == "LISTEN" {n=split($4,a,"."); if (a[n] ~ /^[0-9]+$/) print a[n]}' || true)"
    fi
    LISTEN_PORTS=" $(printf '%s\n' "$raw" | sort -u | tr '\n' ' ')"
}
_snapshot_listen_ports

# --- 端口成员判定（bash 3.2 安全，不依赖关联数组） ---
_ss_port_listening() {
    case "$LISTEN_PORTS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
    esac
}

# --- unit 状态查询：stdout 输出 "active running" 等；空串表示 unit 未在快照中出现 ---
_ss_unit_state() {
    printf '%s\n' "$SYSTEMD_SNAPSHOT" |
        awk -v u="$1" '$1 == u || $1 == u".service" {print $3, $4; exit}'
}

# --- 进程匹配：stdout 输出命中的候选名，未命中返回 1 ---
# 分层匹配防误报：
# - comm 快照为内核维护的命令名，无参数文本污染，做全行词匹配
# - args 快照仅对首字段（命令名位置）做词匹配，覆盖改标题守护进程
#   （如 "redis-server *:6379"），同时避免无关进程的参数文本恰好含
#   服务名（编辑器会话、tail -f 日志、包装 shell 等）造成误命中
# - 含点的候选名视为 java 类全限定名（如 kafka.Kafka、
#   org.elasticsearch.bootstrap.Elasticsearch），其标识只出现在参数中部，
#   额外做一次 args 全行词匹配
# 不用 grep -q：-q 命中即退出会使上游 printf 收到 SIGPIPE，pipefail 下误判为未命中；
# 改为 grep 全量读入后丢弃输出（>/dev/null），无 SIGPIPE 风险
_ss_proc_match() {
    local p
    for p in $1; do
        if printf '%s\n' "$PS_COMM_SNAPSHOT" | grep -wF -- "$p" >/dev/null 2>&1 ||
            printf '%s\n' "$PS_ARGS_CMD_SNAPSHOT" | grep -wF -- "$p" >/dev/null 2>&1; then
            printf '%s' "$p"
            return 0
        fi
        case "$p" in
        *.*)
            if printf '%s\n' "$PS_ARGS_SNAPSHOT" | grep -wF -- "$p" >/dev/null 2>&1; then
                printf '%s' "$p"
                return 0
            fi
            ;;
        esac
    done
    return 1
}

# --- 内置服务映射：向 _SVC_UNITS/_SVC_PROCS/_SVC_PORTS 输出空格分隔候选 ---
# 优先级（在 _evaluate_service 中实现）：配置覆盖键 > 内置映射 > 同名兜底
_ss_service_builtin() {
    local name="$1"
    _SVC_UNITS=""
    _SVC_PROCS=""
    _SVC_PORTS=""
    case "$name" in
    redis)
        _SVC_UNITS="redis redis-server"
        _SVC_PROCS="redis-server"
        _SVC_PORTS="6379"
        ;;
    mysql)
        _SVC_UNITS="mysql mysqld mariadb"
        _SVC_PROCS="mysqld"
        _SVC_PORTS="3306"
        ;;
    mariadb)
        _SVC_UNITS="mariadb mysql mysqld"
        _SVC_PROCS="mysqld mariadbd"
        _SVC_PORTS="3306"
        ;;
    mongod | mongodb)
        _SVC_UNITS="mongod mongodb"
        _SVC_PROCS="mongod"
        _SVC_PORTS="27017"
        ;;
    postgresql | postgres)
        _SVC_UNITS="postgresql postgres"
        _SVC_PROCS="postgres"
        _SVC_PORTS="5432"
        ;;
    nginx)
        _SVC_UNITS="nginx"
        _SVC_PROCS="nginx"
        _SVC_PORTS="80 443"
        ;;
    docker)
        _SVC_UNITS="docker"
        _SVC_PROCS="dockerd"
        _SVC_PORTS=""
        ;;
    sshd | ssh)
        _SVC_UNITS="sshd ssh"
        _SVC_PROCS="sshd"
        _SVC_PORTS="22"
        ;;
    rabbitmq | rabbitmq-server)
        _SVC_UNITS="rabbitmq-server"
        _SVC_PROCS="rabbitmq"
        _SVC_PORTS="5672 15672"
        ;;
    kafka)
        _SVC_UNITS="kafka"
        _SVC_PROCS="kafka.Kafka"
        _SVC_PORTS="9092"
        ;;
    zookeeper)
        _SVC_UNITS="zookeeper"
        _SVC_PROCS="zookeeper"
        _SVC_PORTS="2181"
        ;;
    elasticsearch)
        _SVC_UNITS="elasticsearch"
        _SVC_PROCS="org.elasticsearch.bootstrap.Elasticsearch elasticsearch"
        _SVC_PORTS="9200 9300"
        ;;
    memcached)
        _SVC_UNITS="memcached"
        _SVC_PROCS="memcached"
        _SVC_PORTS="11211"
        ;;
    clickhouse)
        _SVC_UNITS="clickhouse-server"
        _SVC_PROCS="clickhouse-server clickhouse-serv"
        _SVC_PORTS="9000 8123"
        ;;
    *)
        # 未知服务：按同名 unit + 同名进程兜底探测，可用覆盖键显式指定
        _SVC_UNITS="$name"
        _SVC_PROCS="$name"
        _SVC_PORTS=""
        ;;
    esac
}

# --- 告警收集器 ---
_abnormal=0
_abnormal_list=""
_record_abnormal() {
    local name="$1"
    _abnormal=$((_abnormal + 1))
    _abnormal_list="${_abnormal_list}${name};"
}

RESULT_ROWS=("$(ss::msg MSG_SERVICE_COL_SERVICE)|$(ss::msg MSG_SERVICE_COL_METHOD)|$(ss::msg MSG_SERVICE_COL_UNIT)|$(ss::msg MSG_SERVICE_COL_PROCESS)|$(ss::msg MSG_SERVICE_COL_PORT)|verdict|$(ss::msg MSG_SERVICE_COL_STATUS)")

# --- 单服务判定 ---
# 解析覆盖键(${!var} 间接展开，禁 eval) → 匹配三路信号 → 判定矩阵 →
# 追加 RESULT_ROWS + 异常时 ss::alert_add（detail 含服务名/异常状态/检测时间）
_evaluate_service() {
    local name="$1"
    local upper var val units procs ports
    upper="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"

    _ss_service_builtin "$name"
    units="$_SVC_UNITS"
    procs="$_SVC_PROCS"
    ports="$_SVC_PORTS"
    var="SERVICE_${upper}_UNIT"
    val="${!var:-}"
    if [ -n "$val" ]; then units="$val"; fi
    var="SERVICE_${upper}_PROCESS"
    val="${!var:-}"
    if [ -n "$val" ]; then procs="$val"; fi
    var="SERVICE_${upper}_PORT"
    val="${!var:-}"
    if [ -n "$val" ]; then ports="$val"; fi
    ports="$(printf '%s' "$ports" | tr ',' ' ')"
    # none 大小写不敏感：显式跳过端口检测
    case "$(printf '%s' "$ports" | tr '[:upper:]' '[:lower:]')" in
    none) ports="" ;;
    esac
    # 仅保留数字端口 token：丢弃配置手误产生的非法值（如 6379x），
    # 避免其进入判定后稳定产出「端口 xx(未监听)」的误导 critical；
    # set -f 防止含 * ? [ 的 token 被 glob 展开
    if [ -n "$ports" ]; then
        local _ports_clean="" _pp
        set -f
        for _pp in $ports; do
            case "$_pp" in
            *[!0-9]*) ;;
            *) _ports_clean="${_ports_clean}${_ports_clean:+ }$_pp" ;;
            esac
        done
        set +f
        ports="$_ports_clean"
    fi

    # --- systemd 信号：候选 unit 逐个查快照，优先取 active 命中 ---
    local unit_state="" matched_unit="" u st
    if [ "$SYSTEMD_OK" = true ] && [ -n "$units" ]; then
        for u in $units; do
            # awk 提前 exit 可能使上游 printf 收到 SIGPIPE，pipefail 下需 || true 兜底
            st="$(_ss_unit_state "$u" || true)"
            if [ -n "$st" ]; then
                if [ -z "$matched_unit" ]; then
                    matched_unit="$u"
                    unit_state="${st%% *}"
                fi
                if [ "${st%% *}" = "active" ]; then
                    matched_unit="$u"
                    unit_state="active"
                    break
                fi
            fi
        done
    fi

    # --- 进程信号 ---
    local proc_found=""
    if [ -n "$procs" ]; then
        proc_found="$(_ss_proc_match "$procs" || true)"
    fi

    # --- 端口信号 ---
    local ports_up=0 ports_down_list="" ports_up_list="" p
    if [ -n "$ports" ]; then
        for p in $ports; do
            if _ss_port_listening "$p"; then
                ports_up=$((ports_up + 1))
                ports_up_list="${ports_up_list}${ports_up_list:+ }${p}"
            else
                ports_down_list="${ports_down_list}${ports_down_list:+ }${p}"
            fi
        done
    fi

    # --- 判定矩阵 ---
    local verdict="ok" value="ok" reason="" sugg=""
    if [ -n "$unit_state" ]; then
        if [ "$unit_state" = "active" ]; then
            if [ -n "$ports" ] && [ "$ports_up" -eq 0 ]; then
                verdict="warning"
                value="port_closed"
                reason="$(ss::msgf MSG_SERVICE_REASON_PORT_DOWN_UNIT_ACTIVE "$ports_down_list")"
                sugg="$(ss::msg MSG_SERVICE_SUGG_PORT)"
            fi
        elif [ -n "$proc_found" ]; then
            # unit 非 active 但进程命中：按非 systemd 方式运行，正常判定
            if [ -n "$ports" ] && [ "$ports_up" -eq 0 ]; then
                verdict="warning"
                value="port_closed"
                reason="$(ss::msgf MSG_SERVICE_REASON_PORT_DOWN_PROC_UP "$ports_down_list")"
                sugg="$(ss::msg MSG_SERVICE_SUGG_PORT)"
            fi
        else
            if [ -n "$ports" ] && [ "$ports_up" -gt 0 ]; then
                verdict="warning"
                value="proc_unseen"
                reason="$(ss::msgf MSG_SERVICE_REASON_PORT_UP_PROC_UNSEEN "$ports_up_list")"
                sugg="$(ss::msg MSG_SERVICE_SUGG_CHECK_PROC)"
            else
                verdict="critical"
                value="$unit_state"
                reason="$(ss::msgf MSG_SERVICE_REASON_UNIT_DOWN "$matched_unit" "$unit_state")"
                sugg="$(ss::msgf MSG_SERVICE_SUGG_RESTART "$matched_unit" "$matched_unit")"
            fi
        fi
    else
        # 无 systemd 信号（macOS / unit 未安装 / 名称不匹配）
        if [ -n "$proc_found" ]; then
            if [ -n "$ports" ] && [ "$ports_up" -eq 0 ]; then
                verdict="warning"
                value="port_closed"
                reason="$(ss::msgf MSG_SERVICE_REASON_PORT_DOWN_PROC_UP "$ports_down_list")"
                sugg="$(ss::msg MSG_SERVICE_SUGG_PORT)"
            fi
        elif [ -n "$ports" ]; then
            if [ "$ports_up" -gt 0 ]; then
                verdict="ok"
            else
                verdict="critical"
                value="not_running"
                reason="$(ss::msgf MSG_SERVICE_REASON_PROC_MISSING_PORT_DOWN "$ports_down_list")"
                sugg="$(ss::msg MSG_SERVICE_SUGG_CHECK_PROC)"
            fi
        else
            if [ "$CAN_SEE_ALL_PROCS" = "true" ]; then
                verdict="critical"
                value="not_running"
                reason="$(ss::msg MSG_SERVICE_REASON_PROC_MISSING)"
                sugg="$(ss::msg MSG_SERVICE_SUGG_CHECK_PROC)"
            else
                # 进程不可见且无端口佐证：降级为警告，避免误报
                verdict="warning"
                value="unknown"
                reason="$(ss::msg MSG_SERVICE_REASON_PROC_UNSEEN)"
                sugg="$(ss::msg MSG_SERVICE_SUGG_CHECK_PROC)"
            fi
        fi
    fi

    # --- 展示列 ---
    local method_key="MSG_SERVICE_METHOD_PROC"
    if [ -n "$unit_state" ] && [ -n "$ports" ]; then
        method_key="MSG_SERVICE_METHOD_SYSTEMD_PROC_PORT"
    elif [ -n "$unit_state" ]; then
        method_key="MSG_SERVICE_METHOD_SYSTEMD_PROC"
    elif [ -n "$ports" ]; then
        method_key="MSG_SERVICE_METHOD_PROC_PORT"
    fi

    local unit_disp
    if [ "$SYSTEMD_OK" != true ]; then
        unit_disp="$(ss::msg MSG_SERVICE_UNIT_NA)"
    elif [ -z "$unit_state" ]; then
        unit_disp="$(ss::msg MSG_SERVICE_UNIT_UNKNOWN)"
    else
        unit_disp="$unit_state"
    fi

    local proc_disp
    if [ -n "$proc_found" ]; then
        proc_disp="$proc_found"
    else
        proc_disp="$(ss::msg MSG_SERVICE_PROC_NOT_FOUND)"
    fi

    local port_disp=""
    if [ -n "$ports" ]; then
        for p in $ports; do
            if _ss_port_listening "$p"; then
                port_disp="${port_disp}${port_disp:+ }$(ss::msgf MSG_SERVICE_PORT_UP "$p")"
            else
                port_disp="${port_disp}${port_disp:+ }$(ss::msgf MSG_SERVICE_PORT_DOWN "$p")"
            fi
        done
    else
        port_disp="$(ss::msg MSG_SERVICE_PORT_NA)"
    fi

    local status_disp
    case "$verdict" in
    ok)
        status_disp="$(ss::msg MSG_SERVICE_STATUS_OK)"
        ;;
    warning)
        status_disp="$(ss::msg MSG_SERVICE_STATUS_WARN)"
        ;;
    *)
        status_disp="$(ss::msg MSG_SERVICE_STATUS_CRIT)"
        ;;
    esac

    RESULT_ROWS+=("${name}|$(ss::msg "$method_key")|${unit_disp}|${proc_disp}|${port_disp}|${verdict}|${status_disp}")

    case "$verdict" in
    critical | warning)
        local detail
        if [ "$verdict" = "critical" ]; then
            detail="$(ss::msgf MSG_SERVICE_DETAIL_CRITICAL "$name" "$reason" "$SCAN_TS")"
        else
            detail="$(ss::msgf MSG_SERVICE_DETAIL_WARNING "$name" "$reason" "$SCAN_TS")"
        fi
        ss::alert_add "$verdict" \
            "$(ss::msg MSG_SERVICE_DIM_SERVICE)" \
            "$(ss::msg MSG_SERVICE_METRIC_STATUS)" \
            "$name" "$value" \
            "$(ss::msg MSG_SERVICE_THRESH_RUNNING)" \
            "$detail" "$sugg"
        _record_abnormal "$name"
        ;;
    esac
    return 0
}

# ==============================================================================
# 执行扫描（单次，不循环）
# ==============================================================================
_total=${#SERVICE_TARGETS[@]}

# 报告文件路径：配置指定优先，否则用默认产物目录 output/service/
if [ -z "$REPORT_PATH" ]; then
    REPORT_PATH="$(ss::default_report_path service)"
fi
_JSON_PATH="${REPORT_PATH%.md}.json"
# 确保输出目录存在（报告与告警 JSON 同目录）
mkdir -p "$(dirname "$REPORT_PATH")" 2>/dev/null || true

# 获取系统信息（跨平台）
OS_NAME="$(uname -s)"
OS_VERSION="$(uname -r)"
if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="macOS"
    OS_VERSION="$(sw_vers -productVersion 2>/dev/null || uname -r)"
elif [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-Linux}")"
fi

# 报告开始（3 个章节：检测结果/判定规则/结论）
ss::report_begin "$(ss::msg MSG_SERVICE_REPORT_TITLE)" 3

# ==============================================================================
# Markdown 报告头
# ==============================================================================
echo "# $(ss::msg MSG_SERVICE_TITLE)"
echo ""
echo "> **$(ss::msg MSG_COMMON_HOSTNAME):** $(hostname)  "
echo "> **$(ss::msg MSG_COMMON_COLLECT_TIME):** ${SCAN_TS}  "
echo "> **$(ss::msg MSG_COMMON_REPORT_FILE):** \`$REPORT_PATH\`  "
echo "> **$(ss::msg MSG_COMMON_OS):** ${OS_NAME} ${OS_VERSION}  "
echo "> **$(ss::msg MSG_SERVICE_LABEL_SYSTEMD):** $(
    if [ "$SYSTEMD_OK" = true ]; then
        ss::msg MSG_SERVICE_INFO_SYSTEMD_YES
    else
        ss::msg MSG_SERVICE_INFO_SYSTEMD_NO
    fi
)  "
echo "> **$(ss::msg MSG_SERVICE_TARGET_COUNT):** ${_total}  "
if [ "$CAN_SEE_ALL_PROCS" = "false" ]; then
    echo "> ⚠️ $(ss::msg MSG_SERVICE_INFO_PROC_LIMITED)  "
fi
echo ""
echo "---"
echo ""

# ==============================================================================
# 1. 服务检测结果
# ==============================================================================
ss::progress 1 3 "$(ss::msg MSG_SERVICE_SECTION_RESULT)"
echo "## 1. $(ss::msg MSG_SERVICE_SECTION_RESULT)"
echo ""

if [ "$NO_TARGETS" = "true" ]; then
    echo "> $(ss::msg MSG_SERVICE_NO_TARGETS)"
    echo ""
else
    for _name in "${SERVICE_TARGETS[@]}"; do
        _evaluate_service "$_name"
    done

    if [ ${#RESULT_ROWS[@]} -gt 1 ]; then
        printf '| %-16s %-14s %-10s %-20s %-28s %s\n' \
            "$(ss::msg MSG_SERVICE_COL_SERVICE)" \
            "$(ss::msg MSG_SERVICE_COL_METHOD)" \
            "$(ss::msg MSG_SERVICE_COL_UNIT)" \
            "$(ss::msg MSG_SERVICE_COL_PROCESS)" \
            "$(ss::msg MSG_SERVICE_COL_PORT)" \
            "$(ss::msg MSG_SERVICE_COL_STATUS)"
        printf '|%s|%s|%s|%s|%s|%s\n' \
            "------------------" "----------------" "------------" \
            "----------------------" "------------------------------" "----------"
        for _row in "${RESULT_ROWS[@]:1}"; do
            IFS='|' read -r _f1 _f2 _f3 _f4 _f5 _verdict _f6 <<<"$_row"
            _icon="✅"
            case "$_verdict" in
            warning) _icon="🟡" ;;
            critical) _icon="🔴" ;;
            esac
            printf '| %-16s %-14s %-10s %-20s %-28s %s %s\n' \
                "$_f1" "$_f2" "$_f3" "$_f4" "$_f5" "$_icon" "$_f6"
        done
    fi
    echo ""
fi

# ==============================================================================
# 2. 判定规则
# ==============================================================================
ss::progress 2 3 "$(ss::msg MSG_SERVICE_SECTION_RULES)"
echo "## 2. $(ss::msg MSG_SERVICE_SECTION_RULES)"
echo ""
printf '| %-46s %-10s %s\n' \
    "$(ss::msg MSG_SERVICE_RULE_COL_SIGNAL)" \
    "$(ss::msg MSG_SERVICE_RULE_COL_VERDICT)" \
    "$(ss::msg MSG_SERVICE_RULE_COL_DESC)"
printf '|%s|%s|%s\n' \
    "------------------------------------------------" "------------" "------------------------------"
_row_rule() {
    printf '| %-46s %-10s %s\n' "$1" "$2" "$3"
}
_row_rule "$(ss::msg MSG_SERVICE_RULE_ACTIVE)" "✅ $(ss::msg MSG_SERVICE_STATUS_OK)" "$(ss::msg MSG_SERVICE_RULE_ACTIVE_DESC)"
_row_rule "$(ss::msg MSG_SERVICE_RULE_PROC_UP)" "✅ $(ss::msg MSG_SERVICE_STATUS_OK)" "$(ss::msg MSG_SERVICE_RULE_PROC_UP_DESC)"
_row_rule "$(ss::msg MSG_SERVICE_RULE_PORT_ALL_DOWN)" "🟡 $(ss::msg MSG_SERVICE_STATUS_WARN)" "$(ss::msg MSG_SERVICE_RULE_PORT_ALL_DOWN_DESC)"
_row_rule "$(ss::msg MSG_SERVICE_RULE_PORT_UP_PROC_UNSEEN)" "🟡 $(ss::msg MSG_SERVICE_STATUS_WARN)" "$(ss::msg MSG_SERVICE_RULE_PORT_UP_PROC_UNSEEN_DESC)"
_row_rule "$(ss::msg MSG_SERVICE_RULE_UNIT_DOWN)" "🔴 $(ss::msg MSG_SERVICE_STATUS_CRIT)" "$(ss::msg MSG_SERVICE_RULE_UNIT_DOWN_DESC)"
_row_rule "$(ss::msg MSG_SERVICE_RULE_PROC_MISSING)" "🔴 $(ss::msg MSG_SERVICE_STATUS_CRIT)" "$(ss::msg MSG_SERVICE_RULE_PROC_MISSING_DESC)"
_row_rule "$(ss::msg MSG_SERVICE_RULE_UNSEEN)" "🟡 $(ss::msg MSG_SERVICE_STATUS_WARN)" "$(ss::msg MSG_SERVICE_RULE_UNSEEN_DESC)"
echo ""
echo "> $(ss::msg MSG_SERVICE_RULE_NOTE)"
echo ""

# ==============================================================================
# 3. 结论
# ==============================================================================
ss::progress 3 3 "$(ss::msg MSG_SERVICE_SECTION_CONCLUSION)"
_normal=$((_total - _abnormal))
echo "## 3. $(ss::msg MSG_SERVICE_CONCLUSION_TITLE)"
echo ""
if [ "$NO_TARGETS" = "true" ]; then
    echo "> $(ss::msg MSG_SERVICE_CONCLUSION_NO_TARGETS)"
elif [ "$_abnormal" -eq 0 ]; then
    echo "> $(ss::msgf MSG_SERVICE_CONCLUSION_OK "$_total")"
else
    echo "> $(ss::msgf MSG_SERVICE_CONCLUSION_ALERT "$_total" "$_normal" "$_abnormal")"
    echo "> $(ss::msg MSG_SERVICE_CONCLUSION_HINT)"
fi
echo "> 📄 $(ss::msg MSG_COMMON_REPORT_SAVED): \`$REPORT_PATH\`"
echo ""

ss::report_end "$REPORT_PATH"

# 告警 JSON（供外部系统解析 / 告警通知正文构建）
ss::alerts_write_json "$_JSON_PATH" "service_monitor.sh" "$REPORT_PATH"

# 构建摘要文本
_summary=""
if [ "$NO_TARGETS" = "true" ]; then
    _summary="$(ss::msg MSG_SERVICE_SUMMARY_NO_TARGETS)"
elif [ "$_abnormal" -eq 0 ]; then
    _summary="$(ss::msgf MSG_SERVICE_SUMMARY_OK "$_total")"
else
    _summary="$(ss::msgf MSG_SERVICE_SUMMARY_ALERT "$_total" "$_normal" "$_abnormal")"
fi

# --json 模式：输出结构化元数据（summary 字段为告警通知正文摘要）
if [ "$JSON_OUTPUT" = "true" ]; then
    ss::print_json_metadata "success" "$REPORT_PATH" "service_monitor.sh" 0 "$_summary" "${_abnormal_list%;}"
fi

# 发送告警通知（飞书 webhook + 可选签名）
# 是否发送由统一配置 NOTIFY_ON_ALERT_ONLY 决定（true 仅异常推送，false 正常也推），
# 与 disk/cpu 等扫描器语义一致；推送失败不影响主流程
ss::notify_send "$(ss::msg MSG_SERVICE_REPORT_TITLE)" "$REPORT_PATH" "$_summary" || true

# 退出码: 0=正常 1=存在告警
if [ "$(ss::alerts_count)" -gt 0 ]; then
    exit 1
fi
exit 0
