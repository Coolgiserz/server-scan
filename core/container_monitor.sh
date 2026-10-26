#!/bin/bash
# ==============================================================================
# 脚本名称: container_monitor.sh
# 功能描述: 监控指定 Docker 容器/镜像的运行状态与健康状态，异常（停止/退出/
#           不健康/镜像无运行中容器/守护进程不可达）时收集告警并经 notify 推送。
#           通知头部由 notify 库统一附带主机名，与磁盘等扫描器一致；是否发送
#           由统一配置 NOTIFY_ON_ALERT_ONLY 决定（true 仅异常推送，false 正常也推）。
#           单次扫描模型，扫描间隔由外部 crontab 负责。
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL) / macOS (Intel/Apple Silicon)
# 依赖工具: docker CLI（需在运行容器的主机上可用）
# 使用方法: ./container_monitor.sh [--container NAME]... [--image REF]... [--no-health]
# 输出文件: 默认 $OUTPUT_DIR/container/container_<ts>.md 及同名 .json
# ==============================================================================

set -euo pipefail

# --- 配置区域 ---
REPORT_PATH="${REPORT_PATH:-}"

# 容器监控默认配置（可由配置文件 CONTAINER_* 或命令行覆盖）
CONTAINER_NAMES="${CONTAINER_NAMES:-}"
CONTAINER_IMAGES="${CONTAINER_IMAGES:-}"
CONTAINER_DOCKER_TIMEOUT="${CONTAINER_DOCKER_TIMEOUT:-10}"
CONTAINER_CHECK_HEALTH="${CONTAINER_CHECK_HEALTH:-true}"

# 定位项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载共享库
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../lib/cli.sh
source "$SCRIPT_DIR/lib/cli.sh"

# 固定调用顺序：声明前缀 -> 解析公共参数（含 --lang/-c）-> 重载配置
ss::config_init CONTAINER_
ss::parse_common_args "$@"
ss::config_reload

# 脚本特有参数（命令行目标，追加到配置目标之后）
_CLI_CONTAINERS=()
_CLI_IMAGES=()
_NO_HEALTH_CLI="false"

# 帮助文本（脚本特有选项）
_SS_CONTAINER_OPTIONS_HELP="  --container NAME     $(ss::msg MSG_CONTAINER_HELP_CONTAINER)
  --image REF          $(ss::msg MSG_CONTAINER_HELP_IMAGE)
  --no-health          $(ss::msg MSG_CONTAINER_HELP_NO_HEALTH)"

# 解析脚本特有参数（公共参数已在 ss::parse_common_args 中处理）
# 空数组在 bash 3.2 + set -u 下直接展开会报未绑定，故按计数保护
if [ ${#SCRIPT_ARGS[@]} -gt 0 ]; then
    set -- "${SCRIPT_ARGS[@]}"
else
    set --
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
    --container)
        if [[ -n "${2:-}" && "$2" != -* ]]; then
            _CLI_CONTAINERS+=("$2")
            shift 2
        else
            ss::log_error "$(ss::msg MSG_CONTAINER_ERR_CONTAINER_ARG)"
            exit 2
        fi
        ;;
    --image)
        if [[ -n "${2:-}" && "$2" != -* ]]; then
            _CLI_IMAGES+=("$2")
            shift 2
        else
            ss::log_error "$(ss::msg MSG_CONTAINER_ERR_IMAGE_ARG)"
            exit 2
        fi
        ;;
    --no-health)
        _NO_HEALTH_CLI="true"
        shift
        ;;
    -h | --help)
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_CONTAINER_HELP_DESC)" "$_SS_CONTAINER_OPTIONS_HELP"
        exit 0
        ;;
    *)
        ss::log_error "$(ss::msgf MSG_ERROR_UNKNOWN_ARG "$1")"
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_CONTAINER_HELP_DESC)" "$_SS_CONTAINER_OPTIONS_HELP"
        exit 2
        ;;
    esac
done

# --no-health 覆盖配置
if [ "$_NO_HEALTH_CLI" = "true" ]; then
    CONTAINER_CHECK_HEALTH="false"
fi

# 默认产物路径
if [ -z "$REPORT_PATH" ]; then
    REPORT_PATH="$(ss::default_report_path container)"
fi

# ==============================================================================
# 目标列表构建（配置 + 命令行，去重；空格/逗号混合分隔）
# ==============================================================================
CONTAINER_TARGETS=()
IMAGE_TARGETS=()

_container_raw="$(printf '%s' "$CONTAINER_NAMES" | tr ',' ' ')"
if [ ${#_CLI_CONTAINERS[@]} -gt 0 ]; then
    _container_raw="$_container_raw ${_CLI_CONTAINERS[*]}"
fi
for _t in $(printf '%s' "$_container_raw" | tr ' \t' '\n\n' | sed '/^$/d' | awk 'NF && !seen[$0]++'); do
    CONTAINER_TARGETS+=("$_t")
done

_image_raw="$(printf '%s' "$CONTAINER_IMAGES" | tr ',' ' ')"
if [ ${#_CLI_IMAGES[@]} -gt 0 ]; then
    _image_raw="$_image_raw ${_CLI_IMAGES[*]}"
fi
for _t in $(printf '%s' "$_image_raw" | tr ' \t' '\n\n' | sed '/^$/d' | awk 'NF && !seen[$0]++'); do
    IMAGE_TARGETS+=("$_t")
done

_n_containers=${#CONTAINER_TARGETS[@]}
_n_images=${#IMAGE_TARGETS[@]}
_total_targets=$((_n_containers + _n_images))

# ==============================================================================
# Docker 环境前置探测
# ==============================================================================
DOCKER_AVAILABLE="false"
DAEMON_OK="false"
DOCKER_VERSION=""
NO_TARGETS="false"
SKIP_TARGETS="false"

if command -v docker >/dev/null 2>&1; then
    DOCKER_AVAILABLE="true"
    if _ver=$(ss::run_with_timeout "$CONTAINER_DOCKER_TIMEOUT" docker info --format '{{.ServerVersion}}' 2>/dev/null); then
        DAEMON_OK="true"
        DOCKER_VERSION="${_ver:-unknown}"
    fi
fi

# 判定运行模式：无目标 / docker 缺失 / 守护进程不可达
if [ "$_total_targets" -eq 0 ]; then
    NO_TARGETS="true"
elif [ "$DOCKER_AVAILABLE" = "false" ]; then
    # 已配置目标但 docker CLI 缺失：无法监控，记为致命告警
    SKIP_TARGETS="true"
    ss::alert_add "critical" \
        "$(ss::msg MSG_CONTAINER_DIM_ENV)" \
        "$(ss::msg MSG_CONTAINER_METRIC_ENV)" \
        "docker" "missing" \
        "$(ss::msg MSG_CONTAINER_THRESH_DAEMON_OK)" \
        "$(ss::msg MSG_CONTAINER_DETAIL_DOCKER_MISSING)" \
        "$(ss::msg MSG_CONTAINER_SUGG_DOCKER_MISSING)"
elif [ "$DAEMON_OK" = "false" ]; then
    # 已配置目标但守护进程不可达（未运行/无权限/超时）：无法逐个判定，记为致命告警
    SKIP_TARGETS="true"
    ss::alert_add "critical" \
        "$(ss::msg MSG_CONTAINER_DIM_ENV)" \
        "$(ss::msg MSG_CONTAINER_METRIC_ENV)" \
        "docker-daemon" "unreachable" \
        "$(ss::msg MSG_CONTAINER_THRESH_DAEMON_OK)" \
        "$(ss::msg MSG_CONTAINER_DETAIL_DAEMON_DOWN)" \
        "$(ss::msg MSG_CONTAINER_SUGG_DAEMON_DOWN)"
fi

# OS 名称（复用统一探测逻辑）
OS_NAME="Unknown"
if [ -f /etc/os-release ]; then
    OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
fi

# ==============================================================================
# 采集状态（全局）
# ==============================================================================
RESULT_ROWS=()
_abnormal=0
_abnormal_list=""

# 追加一条容器/镜像告警并计入异常统计
_record_abnormal() {
    # $1=对象名
    _abnormal=$((_abnormal + 1))
    _abnormal_list="${_abnormal_list}${1};"
}

# 判定单个容器（按名称）
_evaluate_container() {
    local name="$1"
    local info state health restart exitcode verdict detail sugg value metric threshold health_disp
    info=$(ss::run_with_timeout "$CONTAINER_DOCKER_TIMEOUT" docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.ExitCode}}' "$name" 2>/dev/null) || info=""

    if [ -z "$info" ]; then
        RESULT_ROWS+=("${name}|$(ss::msg MSG_CONTAINER_TYPE_CONTAINER)|missing|-|-|critical")
        ss::alert_add "critical" \
            "$(ss::msg MSG_CONTAINER_DIM_CONTAINER)" \
            "$(ss::msg MSG_CONTAINER_METRIC_STATE)" \
            "$name" "missing" \
            "$(ss::msg MSG_CONTAINER_THRESH_RUNNING)" \
            "$(ss::msgf MSG_CONTAINER_DETAIL_MISSING "$name")" \
            "$(ss::msg MSG_CONTAINER_SUGG_MISSING)"
        _record_abnormal "$name"
        return
    fi

    IFS='|' read -r state health restart exitcode <<<"$info"
    verdict="ok"
    detail=""
    sugg=""
    value="$state"
    metric="$(ss::msg MSG_CONTAINER_METRIC_STATE)"
    threshold="$(ss::msg MSG_CONTAINER_THRESH_RUNNING_HEALTHY)"

    case "$state" in
    running)
        if [ "$CONTAINER_CHECK_HEALTH" = "true" ] && [ "$health" = "unhealthy" ]; then
            verdict="critical"
            metric="$(ss::msg MSG_CONTAINER_METRIC_HEALTH)"
            value="unhealthy"
            detail="$(ss::msgf MSG_CONTAINER_DETAIL_UNHEALTHY "$name")"
            sugg="$(ss::msgf MSG_CONTAINER_SUGG_UNHEALTHY "$name" "$name")"
        elif [ "$CONTAINER_CHECK_HEALTH" = "true" ] && [ "$health" = "starting" ]; then
            verdict="starting"
        else
            verdict="ok"
        fi
        ;;
    restarting)
        verdict="critical"
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_RESTARTING "$name" "$restart")"
        sugg="$(ss::msgf MSG_CONTAINER_SUGG_RESTARTING "$name")"
        ;;
    exited)
        verdict="critical"
        value="exited(${exitcode})"
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_EXITED "$name" "$exitcode")"
        sugg="$(ss::msgf MSG_CONTAINER_SUGG_EXITED "$name" "$name")"
        ;;
    dead)
        verdict="critical"
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_DEAD "$name")"
        sugg="$(ss::msgf MSG_CONTAINER_SUGG_STOPPED "$name" "$name")"
        ;;
    created)
        verdict="critical"
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_CREATED "$name")"
        sugg="$(ss::msgf MSG_CONTAINER_SUGG_STOPPED "$name" "$name")"
        ;;
    removing)
        verdict="critical"
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_REMOVING "$name")"
        sugg="$(ss::msgf MSG_CONTAINER_SUGG_STOPPED "$name" "$name")"
        ;;
    paused)
        verdict="warning"
        threshold="$(ss::msg MSG_CONTAINER_THRESH_RUNNING)"
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_PAUSED "$name")"
        sugg="$(ss::msgf MSG_CONTAINER_SUGG_PAUSED "$name")"
        ;;
    *)
        verdict="critical"
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_UNKNOWN_STATE "$name" "$state")"
        sugg="$(ss::msgf MSG_CONTAINER_SUGG_STOPPED "$name" "$name")"
        ;;
    esac

    health_disp="$health"
    [ "$health" = "none" ] && health_disp="-"
    RESULT_ROWS+=("${name}|$(ss::msg MSG_CONTAINER_TYPE_CONTAINER)|${state}|${health_disp}|${restart}|${verdict}")

    case "$verdict" in
    critical | warning)
        ss::alert_add "$verdict" \
            "$(ss::msg MSG_CONTAINER_DIM_CONTAINER)" \
            "$metric" \
            "$name" "$value" \
            "$threshold" \
            "$detail" "$sugg"
        _record_abnormal "$name"
        ;;
    esac
}

# 判定单个镜像（「至少一个运行中容器」语义）
_evaluate_image() {
    local ref="$1"
    local running_ids total_ids running_count total_count detail
    running_ids=$(ss::run_with_timeout "$CONTAINER_DOCKER_TIMEOUT" docker ps -q --filter "ancestor=$ref" 2>/dev/null) || running_ids=""
    running_count=$(printf '%s\n' "$running_ids" | grep -c . || true)

    if [ "$running_count" -ge 1 ]; then
        RESULT_ROWS+=("${ref}|$(ss::msg MSG_CONTAINER_TYPE_IMAGE)|$(ss::msgf MSG_CONTAINER_IMAGE_RUNNING_FMT "$running_count")|-|-|ok")
        return
    fi

    total_ids=$(ss::run_with_timeout "$CONTAINER_DOCKER_TIMEOUT" docker ps -aq --filter "ancestor=$ref" 2>/dev/null) || total_ids=""
    total_count=$(printf '%s\n' "$total_ids" | grep -c . || true)
    if [ "$total_count" -gt 0 ]; then
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_IMAGE_STOPPED "$ref" "$total_count")"
    else
        detail="$(ss::msgf MSG_CONTAINER_DETAIL_IMAGE_NONE "$ref")"
    fi

    RESULT_ROWS+=("${ref}|$(ss::msg MSG_CONTAINER_TYPE_IMAGE)|$(ss::msgf MSG_CONTAINER_IMAGE_RUNNING_FMT "0")|-|-|critical")
    ss::alert_add "critical" \
        "$(ss::msg MSG_CONTAINER_DIM_IMAGE)" \
        "$(ss::msg MSG_CONTAINER_METRIC_RUNNING)" \
        "$ref" "0" \
        "$(ss::msg MSG_CONTAINER_THRESH_IMAGE)" \
        "$detail" \
        "$(ss::msg MSG_CONTAINER_SUGG_IMAGE)"
    _record_abnormal "$ref"
}

# ==============================================================================
# 报告生成（3 个章节）
# ==============================================================================
ss::report_begin "$(ss::msg MSG_CONTAINER_REPORT_TITLE)" 3

echo "# $(ss::msg MSG_CONTAINER_TITLE)"
echo ""
echo "> **$(ss::msg MSG_COMMON_HOSTNAME):** $(hostname)  "
echo "> **$(ss::msg MSG_COMMON_COLLECT_TIME):** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **$(ss::msg MSG_COMMON_REPORT_FILE):** \`$REPORT_PATH\`  "
echo "> **$(ss::msg MSG_COMMON_OS):** ${OS_NAME}  "
echo "> **$(ss::msg MSG_COMMON_KERNEL):** $(uname -r)  "
if [ "$DOCKER_AVAILABLE" = "false" ]; then
    echo "> **$(ss::msg MSG_CONTAINER_DOCKER):** $(ss::msg MSG_CONTAINER_DOCKER_MISSING_SHORT)  "
elif [ "$DAEMON_OK" = "false" ]; then
    echo "> **$(ss::msg MSG_CONTAINER_DOCKER):** $(ss::msg MSG_CONTAINER_DAEMON_DOWN_SHORT)  "
else
    echo "> **$(ss::msg MSG_CONTAINER_DOCKER):** $(ss::msgf MSG_CONTAINER_DOCKER_VERSION "$DOCKER_VERSION")  "
fi
echo "> **$(ss::msg MSG_CONTAINER_TARGET_COUNT):** ${_total_targets}（$(ss::msg MSG_CONTAINER_TYPE_CONTAINER) ${_n_containers} / $(ss::msg MSG_CONTAINER_TYPE_IMAGE) ${_n_images}）  "
echo ""
echo "---"
echo ""

# 第 1 节：检测结果
ss::progress 1 3 "$(ss::msg MSG_CONTAINER_SECTION_RESULT)"
echo "## 1. $(ss::msg MSG_CONTAINER_SECTION_RESULT)"
echo ""

# 仅在环境可用且有目标时逐个判定
if [ "$SKIP_TARGETS" != "true" ] && [ "$NO_TARGETS" != "true" ]; then
    if [ ${#CONTAINER_TARGETS[@]} -gt 0 ]; then
        for _name in "${CONTAINER_TARGETS[@]}"; do
            _evaluate_container "$_name"
        done
    fi
    if [ ${#IMAGE_TARGETS[@]} -gt 0 ]; then
        for _ref in "${IMAGE_TARGETS[@]}"; do
            _evaluate_image "$_ref"
        done
    fi
fi

if [ "$NO_TARGETS" = "true" ]; then
    echo "> $(ss::msg MSG_CONTAINER_NO_TARGETS)"
    echo ""
elif [ "$SKIP_TARGETS" = "true" ]; then
    echo "> 🔴 $(ss::msg MSG_CONTAINER_ENV_FAIL_HINT)"
    echo ""
else
    echo "| $(ss::msg MSG_CONTAINER_COL_TARGET) | $(ss::msg MSG_CONTAINER_COL_TYPE) | $(ss::msg MSG_CONTAINER_COL_STATE) | $(ss::msg MSG_CONTAINER_COL_HEALTH) | $(ss::msg MSG_CONTAINER_COL_RESTART) | $(ss::msg MSG_CONTAINER_COL_VERDICT) |"
    echo "| --- | --- | --- | --- | --- | --- |"
    # 汇总各目标状态行，供「全部正常 + 主动通知」时摘要携带清单
    _status_lines=""
    if [ ${#RESULT_ROWS[@]} -gt 0 ]; then
        for _row in "${RESULT_ROWS[@]}"; do
            IFS='|' read -r _c_target _c_type _c_state _c_health _c_restart _c_verdict <<<"$_row"
            case "$_c_verdict" in
            ok)
                _c_icon="✅"
                _c_text="$(ss::msg MSG_CONTAINER_VERDICT_OK)"
                ;;
            starting)
                _c_icon="⏳"
                _c_text="$(ss::msg MSG_CONTAINER_VERDICT_STARTING)"
                ;;
            warning)
                _c_icon="🟡"
                _c_text="$(ss::msg MSG_CONTAINER_VERDICT_WARNING)"
                ;;
            *)
                _c_icon="🔴"
                _c_text="$(ss::msg MSG_CONTAINER_VERDICT_CRITICAL)"
                ;;
            esac
            printf '| %s | %s | %s | %s | %s | %s %s |\n' \
                "$_c_target" "$_c_type" "$_c_state" "$_c_health" "$_c_restart" "$_c_icon" "$_c_text"
            _status_line="${_c_icon} ${_c_target}: ${_c_state}"
            if [ "$_c_health" != "-" ]; then
                _status_line="${_status_line}(${_c_health})"
            fi
            _status_lines="${_status_lines}${_status_lines:+$'\n'}${_status_line}"
        done
    fi
    echo ""
fi

# 第 2 节：判定规则说明
ss::progress 2 3 "$(ss::msg MSG_CONTAINER_SECTION_RULES)"
echo "## 2. $(ss::msg MSG_CONTAINER_SECTION_RULES)"
echo ""
echo "| $(ss::msg MSG_CONTAINER_RULE_COL_STATE) | $(ss::msg MSG_CONTAINER_RULE_COL_VERDICT) | $(ss::msg MSG_CONTAINER_RULE_COL_DESC) |"
echo "| --- | --- | --- |"
printf '| %s | ✅ %s | %s |\n' "$(ss::msg MSG_CONTAINER_RULE_RUNNING_HEALTHY)" "$(ss::msg MSG_CONTAINER_VERDICT_OK)" "$(ss::msg MSG_CONTAINER_RULE_RUNNING_HEALTHY_DESC)"
printf '| %s | ⏳ %s | %s |\n' "$(ss::msg MSG_CONTAINER_RULE_STARTING)" "$(ss::msg MSG_CONTAINER_VERDICT_STARTING)" "$(ss::msg MSG_CONTAINER_RULE_STARTING_DESC)"
printf '| %s | 🔴 %s | %s |\n' "$(ss::msg MSG_CONTAINER_RULE_UNHEALTHY)" "$(ss::msg MSG_CONTAINER_VERDICT_CRITICAL)" "$(ss::msg MSG_CONTAINER_RULE_UNHEALTHY_DESC)"
printf '| %s | 🔴 %s | %s |\n' "$(ss::msg MSG_CONTAINER_RULE_STOPPED)" "$(ss::msg MSG_CONTAINER_VERDICT_CRITICAL)" "$(ss::msg MSG_CONTAINER_RULE_STOPPED_DESC)"
printf '| %s | 🟡 %s | %s |\n' "$(ss::msg MSG_CONTAINER_RULE_PAUSED)" "$(ss::msg MSG_CONTAINER_VERDICT_WARNING)" "$(ss::msg MSG_CONTAINER_RULE_PAUSED_DESC)"
printf '| %s | 🔴 %s | %s |\n' "$(ss::msg MSG_CONTAINER_RULE_MISSING)" "$(ss::msg MSG_CONTAINER_VERDICT_CRITICAL)" "$(ss::msg MSG_CONTAINER_RULE_MISSING_DESC)"
printf '| %s | 🔴 %s | %s |\n' "$(ss::msg MSG_CONTAINER_RULE_IMAGE)" "$(ss::msg MSG_CONTAINER_VERDICT_CRITICAL)" "$(ss::msg MSG_CONTAINER_RULE_IMAGE_DESC)"
echo ""
if [ "$CONTAINER_CHECK_HEALTH" != "true" ]; then
    echo "> $(ss::msg MSG_CONTAINER_HEALTH_DISABLED_NOTE)"
    echo ""
fi

# 第 3 节：结论
ss::progress 3 3 "$(ss::msg MSG_CONTAINER_SECTION_CONCLUSION)"
echo "## 3. $(ss::msg MSG_CONTAINER_SECTION_CONCLUSION)"
echo ""
_normal=$((_total_targets - _abnormal))
if [ "$NO_TARGETS" = "true" ]; then
    echo "> ℹ️ $(ss::msg MSG_CONTAINER_CONCLUSION_NO_TARGETS)"
elif [ "$SKIP_TARGETS" = "true" ]; then
    echo "> 🔴 $(ss::msg MSG_CONTAINER_CONCLUSION_ENV_FAIL)"
elif [ "$_abnormal" -eq 0 ]; then
    echo "> $(ss::msgf MSG_CONTAINER_CONCLUSION_OK "$_total_targets")"
else
    echo "> $(ss::msgf MSG_CONTAINER_CONCLUSION_ALERT "$_total_targets" "$_normal" "$_abnormal")"
    echo "> $(ss::msg MSG_CONTAINER_CONCLUSION_ALERT_HINT)"
fi
echo ""
echo "> 📄 $(ss::msg MSG_COMMON_REPORT_SAVED): $REPORT_PATH"

ss::report_end "$REPORT_PATH"

# --- 写入告警 JSON（供 notify summary 模式与 --json 消费）---
_JSON_PATH="${REPORT_PATH%.md}.json"
ss::alerts_write_json "$_JSON_PATH" "container_monitor.sh" "$REPORT_PATH"

# --- 汇总文案（通知 / JSON 复用）---
if [ "$NO_TARGETS" = "true" ]; then
    _summary="$(ss::msg MSG_CONTAINER_SUMMARY_NO_TARGETS)"
elif [ "$SKIP_TARGETS" = "true" ]; then
    _summary="$(ss::msg MSG_CONTAINER_SUMMARY_ENV_FAIL)"
elif [ "$_abnormal" -eq 0 ]; then
    _summary="$(ss::msgf MSG_CONTAINER_SUMMARY_OK "$_total_targets")"
    # 全部正常时摘要附各目标状态清单，供「主动通知」场景直接阅读服务及状态
    if [ -n "${_status_lines:-}" ]; then
        _summary="${_summary}"$'\n'"$(ss::msg MSG_CONTAINER_SUMMARY_STATUS_LIST)"$'\n'"${_status_lines}"
    fi
else
    _summary="$(ss::msgf MSG_CONTAINER_SUMMARY_ALERT "$_total_targets" "$_normal" "$_abnormal")"
fi

# --- 可选：机器可读的 JSON 元数据输出 ---
if [ "$JSON_OUTPUT" = "true" ]; then
    ss::print_json_metadata "success" "$REPORT_PATH" "container_monitor.sh" 0 "$_summary" "${_abnormal_list%;}"
fi

# --- 可选：通知推送（飞书）---
# 通知头部由 notify 库统一附带主机名（与磁盘等扫描器一致）。
# 是否发送完全由统一的 NOTIFY_ON_ALERT_ONLY 决定：true 时仅异常推送，
# false 时正常也会推送；与 disk/cpu 等扫描器语义一致，不做模块级特殊覆盖
_alert_total=$(ss::alerts_count)
ss::notify_send "$(ss::msg MSG_CONTAINER_REPORT_TITLE)" "$REPORT_PATH" "$_summary" || true

# --- 退出码：0 正常 / 1 有告警 / 2 参数错误 ---
if [ "$_alert_total" -gt 0 ]; then
    exit 1
fi
exit 0
