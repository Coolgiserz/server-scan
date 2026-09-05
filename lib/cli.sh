#!/bin/bash
# ==============================================================================
# lib/cli.sh - server-scan 统一 CLI 参数解析
# ==============================================================================
# 此文件包含所有脚本共享的 CLI 参数解析逻辑
# 使用方法: source "$SCRIPT_DIR/lib/cli.sh"
# ==============================================================================

# 加载通知库（提供 ss::notify_init / ss::notify_send 等函数）
# shellcheck source=./notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

# ------------------------------------------------------------------------------
# 默认配置（只在未设置时才初始化，避免覆盖脚本的默认值）
# ------------------------------------------------------------------------------
QUIET="${QUIET:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"
NO_COLOR="${NO_COLOR:-false}"
CONFIG_FILE="${CONFIG_FILE:-}"
REPORT_PATH="${REPORT_PATH:-}"

# 命令行传入的通知参数（优先级高于配置文件，由 ss::notify_init 消费）
SS_CLI_NOTIFY_ENABLED="${SS_CLI_NOTIFY_ENABLED:-false}"
SS_CLI_NOTIFY_DISABLED="${SS_CLI_NOTIFY_DISABLED:-false}"
SS_CLI_NOTIFY_CHANNEL="${SS_CLI_NOTIFY_CHANNEL:-}"
SS_CLI_WEBHOOK="${SS_CLI_WEBHOOK:-}"
SS_CLI_NOTIFY_TEST="${SS_CLI_NOTIFY_TEST:-false}"

# ------------------------------------------------------------------------------
# 解析公共参数
# 注意：此函数必须在主shell中直接调用（不能用命令替换），否则变量赋值和exit不会生效
# 通过全局数组 SCRIPT_ARGS 返回剩余参数
# ------------------------------------------------------------------------------
ss::parse_common_args() {
    local args=("$@")
    local i=0
    SCRIPT_ARGS=()

    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
        -o | --output)
            if [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" != -* ]]; then
                REPORT_PATH="${args[$((i + 1))]}"
                i=$((i + 2))
            else
                ss::log_error "$(ss::msgf MSG_ERROR_NEED_ARG "-o/--output")"
                exit 2
            fi
            ;;
        -c | --config)
            if [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" != -* ]]; then
                CONFIG_FILE="${args[$((i + 1))]}"
                i=$((i + 2))
            else
                ss::log_error "$(ss::msgf MSG_ERROR_NEED_ARG "-c/--config")"
                exit 2
            fi
            ;;
        -q | --quiet)
            QUIET="true"
            i=$((i + 1))
            ;;
        --json)
            JSON_OUTPUT="true"
            QUIET="true" # JSON 模式隐含静默模式
            i=$((i + 1))
            ;;
        --no-color)
            NO_COLOR="true"
            i=$((i + 1))
            ;;
        --notify)
            NOTIFY_ENABLED="true"
            SS_CLI_NOTIFY_ENABLED="true"
            i=$((i + 1))
            ;;
        --no-notify)
            # 通知默认启用，此参数用于单次运行显式关闭
            NOTIFY_ENABLED="false"
            SS_CLI_NOTIFY_DISABLED="true"
            i=$((i + 1))
            ;;
        --notify-channel)
            if [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" != -* ]]; then
                NOTIFY_CHANNEL="${args[$((i + 1))]}"
                SS_CLI_NOTIFY_CHANNEL="${args[$((i + 1))]}"
                i=$((i + 2))
            else
                ss::log_error "$(ss::msgf MSG_ERROR_NEED_ARG "--notify-channel")"
                exit 2
            fi
            ;;
        --webhook)
            if [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" != -* ]]; then
                NOTIFY_WEBHOOK="${args[$((i + 1))]}"
                SS_CLI_WEBHOOK="${args[$((i + 1))]}"
                NOTIFY_ENABLED="true"
                SS_CLI_NOTIFY_ENABLED="true"
                i=$((i + 2))
            else
                ss::log_error "$(ss::msgf MSG_ERROR_NEED_ARG "--webhook")"
                exit 2
            fi
            ;;
        --notify-test)
            NOTIFY_ENABLED="true"
            SS_CLI_NOTIFY_ENABLED="true"
            SS_CLI_NOTIFY_TEST="true"
            i=$((i + 1))
            ;;
        --lang)
            if [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" != -* ]]; then
                SS_LANG="${args[$((i + 1))]}"
                # 重新加载语言文件
                _ss_lang_file="$SCRIPT_DIR/lib/i18n/${SS_LANG}.sh"
                if [ -f "$_ss_lang_file" ]; then
                    source "$_ss_lang_file"
                fi
                i=$((i + 2))
            else
                ss::log_error "$(ss::msgf MSG_ERROR_NEED_ARG "--lang")"
                exit 2
            fi
            ;;
        -h | --help)
            # 将 -h/--help 传递给脚本，让脚本在显示帮助时包含脚本特定选项
            SCRIPT_ARGS+=("${args[$i]}")
            i=$((i + 1))
            ;;
        *)
            # 脚本特有参数，保留给脚本自己解析
            SCRIPT_ARGS+=("${args[$i]}")
            i=$((i + 1))
            ;;
        esac
    done

    # --------------------------------------------------------------------------
    # 通知配置初始化
    # 必须在命令行参数解析完成后调用，以保证命令行参数优先于配置文件
    # --------------------------------------------------------------------------
    ss::notify_init

    # --notify-test: 发送一条测试消息后立即退出（不执行扫描）
    if [ "$SS_CLI_NOTIFY_TEST" = "true" ]; then
        if ss::notify_test; then
            exit 0
        fi
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 打印使用说明（模板）
# ------------------------------------------------------------------------------
ss::print_usage() {
    local script_name="$1"
    local script_description="$2"
    local script_specific_options="$3"

    cat <<EOF
$(ss::msg MSG_HELP_USAGE): $script_name [$(ss::msg MSG_HELP_OPTIONS)]

$script_description

$(ss::msg MSG_HELP_COMMON_OPTIONS):
  -o, --output PATH     $(ss::msg MSG_HELP_OUTPUT)
  -c, --config FILE     $(ss::msg MSG_HELP_CONFIG)
  -q, --quiet           $(ss::msg MSG_HELP_QUIET)
      --json            $(ss::msg MSG_HELP_JSON)
      --no-color        $(ss::msg MSG_HELP_NO_COLOR)
      --lang LANG       $(ss::msg MSG_HELP_LANG)
      --notify          $(ss::msg MSG_HELP_NOTIFY)
      --no-notify       $(ss::msg MSG_HELP_NO_NOTIFY)
      --notify-channel NAME
                        $(ss::msg MSG_HELP_NOTIFY_CHANNEL)
      --webhook URL     $(ss::msg MSG_HELP_WEBHOOK)
      --notify-test     $(ss::msg MSG_HELP_NOTIFY_TEST)
  -h, --help            $(ss::msg MSG_HELP_HELP)

$script_specific_options

$(ss::msg MSG_HELP_EXAMPLES):
  # $(ss::msg MSG_HELP_EXAMPLE_BASIC)
  $script_name

  # $(ss::msg MSG_HELP_EXAMPLE_OUTPUT)
  $script_name -o /tmp/custom_report.md

  # $(ss::msg MSG_HELP_EXAMPLE_QUIET)
  $script_name --quiet

  # $(ss::msg MSG_HELP_EXAMPLE_JSON)
  $script_name --json

  # $(ss::msg MSG_HELP_EXAMPLE_LANG)
  SS_LANG=en_US $script_name

EOF
}

# ------------------------------------------------------------------------------
# 打印 JSON 元数据
# ------------------------------------------------------------------------------
ss::print_json_metadata() {
    local status="$1"
    local report_path="$2"
    local script_name="$3"
    local duration_sec="$4"
    local summary="$5"
    local bottlenecks="$6"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hostname
    hostname=$(hostname)

    # 转义 JSON 字符串
    report_path=$(ss::json_escape "$report_path")
    script_name=$(ss::json_escape "$script_name")
    summary=$(ss::json_escape "$summary")
    bottlenecks=$(ss::json_escape "$bottlenecks")

    cat <<EOF
{
  "status": "$status",
  "report_path": "$report_path",
  "timestamp": "$timestamp",
  "hostname": "$hostname",
  "script": "$script_name",
  "duration_sec": $duration_sec,
  "summary": "$summary",
  "bottlenecks": "$bottlenecks"
}
EOF
}

# ------------------------------------------------------------------------------
# 打印脚本特定使用说明
# ------------------------------------------------------------------------------
ss::print_script_usage() {
    local script_name="$1"
    local script_description="$2"
    local script_specific_options="$3"

    ss::print_usage "$script_name" "$script_description" "$script_specific_options"
}
