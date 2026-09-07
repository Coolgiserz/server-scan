#!/bin/bash
# shellcheck disable=SC1090
# ==============================================================================
# lib/common.sh - server-scan 共享函数库
# ==============================================================================
# 此文件包含所有脚本共享的函数和工具，避免代码重复
# 使用方法: source "$SCRIPT_DIR/lib/common.sh"
# ==============================================================================

# ------------------------------------------------------------------------------
# 国际化 (i18n) 支持
# ------------------------------------------------------------------------------
# 语言检测：SS_LANG > LANG > zh_CN
SS_LANG="${SS_LANG:-${LANG:-zh_CN}}"
SS_LANG="${SS_LANG%%.*}"   # 移除 .UTF-8 等后缀: en_US.UTF-8 -> en_US
SS_LANG="${SS_LANG//-/_}"  # 连字符转下划线: zh-CN -> zh_CN

# 加载语言文件
_ss_lang_file="$SCRIPT_DIR/lib/i18n/${SS_LANG}.sh"
if [ -f "$_ss_lang_file" ]; then
    source "$_ss_lang_file"
else
    # 回退到中文
    source "$SCRIPT_DIR/lib/i18n/zh_CN.sh" 2>/dev/null || true
fi

# 消息查找函数
ss::msg() {
    local key="$1"
    local fallback="${2:-$key}"
    echo "${!key:-$fallback}"
}

# 带格式化的消息查找
ss::msgf() {
    local key="$1"
    shift
    local template
    template=$(ss::msg "$key" "$key")
    printf "$template" "$@"
}

# ------------------------------------------------------------------------------
# 产物目录（报告与告警 JSON）
# ------------------------------------------------------------------------------
# 默认在项目根目录下的 output/，按脚本标识分目录存放，便于归档与清理。
# 可用 OUTPUT_DIR 环境变量覆盖（如 /var/log/server-scan）。
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR:-.}/output}"

# 生成默认产物路径
# 用法: ss::default_report_path <脚本标识> [扩展名]
# 示例: sys_overview -> <OUTPUT_DIR>/sys_overview/sys_overview_20260904_092232.md
ss::default_report_path() {
    local name="$1"
    local ext="${2:-md}"
    printf '%s/%s/%s_%s.%s' \
        "$OUTPUT_DIR" "$name" "$name" "$(date '+%Y%m%d_%H%M%S')" "$ext"
}

# 确保目标文件所在目录存在
# 用法: ss::ensure_output_dir <文件路径>
ss::ensure_output_dir() {
    local dir
    dir="$(dirname "$1")"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null || return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 操作系统检测
# ------------------------------------------------------------------------------
ss::detect_os() {
    OS_TYPE=$(uname -s)
    export OS_TYPE
}

# ------------------------------------------------------------------------------
# 人类可读大小转换（字节）
# ------------------------------------------------------------------------------
ss::hr_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0B"
        return
    fi
    local units=("B" "KB" "MB" "GB" "TB")
    local unit_idx=0
    local value=$bytes
    while awk "BEGIN {exit !($value >= 1024)}" 2>/dev/null && [ $unit_idx -lt 4 ]; do
        value=$(awk "BEGIN {printf \"%.2f\", $value/1024}")
        unit_idx=$((unit_idx + 1))
    done
    echo "${value}${units[$unit_idx]}"
}

# ------------------------------------------------------------------------------
# 人类可读大小转换（KB）
# ------------------------------------------------------------------------------
ss::hr_kb() {
    local kb=$1
    if [ -z "$kb" ] || [ "$kb" = "0" ]; then
        echo "0KB"
        return
    fi
    local units=("KB" "MB" "GB" "TB")
    local unit_idx=0
    local value=$kb
    while awk "BEGIN {exit !($value >= 1024)}" 2>/dev/null && [ $unit_idx -lt 3 ]; do
        value=$(awk "BEGIN {printf \"%.2f\", $value/1024}")
        unit_idx=$((unit_idx + 1))
    done
    echo "${value}${units[$unit_idx]}"
}

# ------------------------------------------------------------------------------
# 读取 sysctl 值（跨平台）
# ------------------------------------------------------------------------------
ss::read_sysctl() {
    local key=$1
    if [ "$OS_TYPE" = "Darwin" ]; then
        sysctl -n "$key" 2>/dev/null || echo ""
    else
        cat "/proc/sys/$key" 2>/dev/null || echo ""
    fi
}

# ------------------------------------------------------------------------------
# 跨平台超时封装
# ------------------------------------------------------------------------------
if command -v timeout >/dev/null 2>&1; then
    ss::run_with_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
    ss::run_with_timeout() { gtimeout "$@"; }
else
    ss::run_with_timeout() {
        local secs="$1"
        shift
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

# ------------------------------------------------------------------------------
# 报告开始
# ------------------------------------------------------------------------------
ss::report_begin() {
    local title="$1"
    local total_sections="$2"

    # 使用临时文件收集报告，避免进程替换的异步/交错问题
    TMP_REPORT=$(mktemp)

    # 保存原始 stdout，用于末尾恢复并显示报告
    exec 3>&1

    # 将后续所有输出重定向到临时 Markdown 文件
    exec >"$TMP_REPORT"

    # 启动横幅（实时打印到终端，不进报告文件）
    if [ "$QUIET" != "true" ]; then
        printf '\n\033[1;32m🚀 %s\033[0m (%s %s %s)\n' \
            "$title" \
            "$(ss::msg MSG_COMMON_TOTAL)" \
            "$total_sections" \
            "$(ss::msg MSG_COMMON_SECTIONS)" >&3
    fi
}

# ------------------------------------------------------------------------------
# 报告结束
# ------------------------------------------------------------------------------
ss::report_end() {
    local report_path="$1"

    # 恢复原始 stdout，然后将临时文件同步输出到终端和报告路径
    exec 1>&3

    # 确保产物目录存在：默认路径为 $OUTPUT_DIR/<脚本>/，首次运行时目录尚不存在。
    # 若目录创建失败，tee 会静默失败（脚本仍以 0 退出），因此这里必须显式报错
    if ! ss::ensure_output_dir "$report_path"; then
        ss::log_error "$(ss::msgf MSG_COMMON_OUTPUT_DIR_FAIL "$report_path")"
        return 1
    fi

    # 使用 cat + tee 替代异步的进程替换，避免输出交错
    cat "$TMP_REPORT" | tee "$report_path"
    rm -f "$TMP_REPORT"

    # 完成提示（实时打印到终端）
    if [ "$QUIET" != "true" ]; then
        printf '\033[1;32m✅ %s\033[0m %s: %s\n' \
            "$(ss::msg MSG_COMMON_ANALYSIS_COMPLETE)" \
            "$(ss::msg MSG_COMMON_REPORT_SAVED)" \
            "$report_path" >&3
    fi

    # 关闭 fd3
    exec 3>&-
}

# ------------------------------------------------------------------------------
# 进度提示
# ------------------------------------------------------------------------------
ss::progress() {
    # $1=当前章节序号 $2=总章节数 $3=章节名
    if [ "$QUIET" != "true" ]; then
        printf '\r\033[K🔄 [%s/%s] %s ...\n' "$1" "$2" "$3" >&3
    fi
}

# ------------------------------------------------------------------------------
# 配置加载
# ------------------------------------------------------------------------------
# 解析规则（注释处理是重点，注释只作说明、绝不参与取值）:
#   1. 整行注释（首个非空白字符为 #）整行跳过
#   2. 取值采用「引号感知」: 值若以引号开头，则取到配对的闭合引号为止，
#      引号内的 # 属于值本身（如 "p@ss#word"、"/data/#tmp"）；
#      闭合引号之后的内容必须是空或注释
#   3. 未加引号的值沿用 shell 语义: 只有「空白之后的 #」才视为注释起点，
#      因此 abc#def 中的 # 会被保留
#   4. 必须先正确取值再谈校验: 否则 "30   # 大文件 Top N" 会被整个当成值，
#      导致数值阈值比较失效、路径尾部引号残留、甚至因注释含 $ ( ) ; 而被整条丢弃
ss::load_config() {
    local config_file="$1"
    shift
    local allowed_prefixes=("$@")

    # 如果配置文件存在，则加载
    if [ -f "$config_file" ]; then
        local line key value raw tail
        # || [ -n "$line" ] 用于处理末尾无换行的文件
        while IFS= read -r line || [ -n "$line" ]; do
            # 兼容 CRLF 换行
            line="${line%$'\r'}"

            # 去除首尾空白
            line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

            # 跳过空行与整行注释
            [ -z "$line" ] && continue
            [[ "$line" == \#* ]] && continue

            # 必须是键值对
            [[ "$line" != *=* ]] && continue
            key="${line%%=*}"
            raw="${line#*=}"

            # 去除 key 首尾空格、value 前导空格
            key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//')"

            # 引号感知取值：引号内的 # 保留，未加引号时按 shell 语义剥离注释
            tail=""
            case "$raw" in
            \"*)
                value="$(printf '%s' "$raw" | sed -n 's/^"\([^"]*\)".*$/\1/p')"
                tail="$(printf '%s' "$raw" | sed -n 's/^"[^"]*"[[:space:]]*//p')"
                ;;
            \'*)
                value="$(printf '%s' "$raw" | sed -n "s/^'\([^']*\)'.*\$/\1/p")"
                tail="$(printf '%s' "$raw" | sed -n "s/^'[^']*'[[:space:]]*//p")"
                ;;
            *)
                # 未加引号：剥离「空白之后的 #」起的注释，再去掉尾部空白
                value="$(printf '%s' "$raw" | sed 's/[[:space:]]#.*$//;s/[[:space:]]*$//')"
                ;;
            esac

            # 闭合引号之后若还有非注释内容，属格式异常，跳过以免误解析
            if [ -n "$tail" ] && [[ "$tail" != \#* ]]; then
                continue
            fi

            # 严格校验 key 格式
            if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
                continue
            fi

            # 严格校验 value，拒绝危险字符
            if [[ "$value" =~ [\`\$\(\)\;] ]]; then
                continue
            fi

            # 检查是否匹配允许的前缀
            local matched=false
            for prefix in "${allowed_prefixes[@]}"; do
                if [[ "$key" == "$prefix"* ]]; then
                    matched=true
                    break
                fi
            done

            if [ "$matched" = "true" ]; then
                # 使用 printf -v 替代 eval，避免 value 经过 shell 命令解析器
                printf -v "$key" '%s' "$value"
            fi
        done <"$config_file"
    fi
}

# ------------------------------------------------------------------------------
# 统一配置文件加载（所有扫描脚本共用一份 server-scan.conf）
# ------------------------------------------------------------------------------
# 设计: 每个脚本各自维护一份 conf 会产生多个配置文件、难以维护，
# 因此统一为单一入口 server-scan.conf。各脚本按「前缀」取用自己关心的键，
# 同一份文件即可同时服务 disk / cpu_mem 等脚本，互不干扰。
#
# 例外: 通知配置（含 webhook 与签名密钥）因安全原因独立为 notify.conf，
# 避免把密钥混进需要 chmod 644 的普通配置文件。
#
# 用法（顺序不可颠倒）:
#   ss::config_init DISK_ INODE_ ...   # ss::parse_common_args 之前调用
#   ss::parse_common_args "$@"
#   ss::config_reload                  # 之后调用，使 -c/--config 生效
# ------------------------------------------------------------------------------
SS_CONFIG_PREFIXES=()
SS_CONFIG_LOADED=""

# 解析配置文件路径: 环境变量/脚本已指定 > server-scan.conf > 旧版 disk_analyzer.conf
ss::config_path() {
    if [ -n "${CONFIG_FILE:-}" ]; then
        printf '%s' "$CONFIG_FILE"
        return 0
    fi
    if [ -f "$SCRIPT_DIR/server-scan.conf" ]; then
        printf '%s' "$SCRIPT_DIR/server-scan.conf"
        return 0
    fi
    # 兼容既有部署：旧的 disk_analyzer.conf 仍可继续生效
    if [ -f "$SCRIPT_DIR/disk_analyzer.conf" ]; then
        printf '%s' "$SCRIPT_DIR/disk_analyzer.conf"
        return 0
    fi
    printf '%s' "$SCRIPT_DIR/server-scan.conf"
}

# 初始加载（在解析命令行参数之前）
ss::config_init() {
    SS_CONFIG_PREFIXES=("$@")
    local preset="${CONFIG_FILE:-}"
    CONFIG_FILE="$(ss::config_path)"

    # 旧版配置回退提示。两点注意:
    # 1) 必须在此处判断: CONFIG_FILE 由命令替换赋值，
    #    其内部的变量赋值不会传出子 shell
    # 2) 此时尚未进入报告流程（exec 3>&1 在 ss::report_begin 中执行），
    #    fd3 未建立，不能复用 ss::log_warn，需直接写 stderr
    if [ -z "$preset" ] && [ ! -f "$SCRIPT_DIR/server-scan.conf" ] &&
        [ -f "$SCRIPT_DIR/disk_analyzer.conf" ] && [ "$QUIET" != "true" ]; then
        printf '\033[1;33m⚠️  %s\033[0m\n' "$(ss::msg MSG_CONFIG_WARN_LEGACY)" >&2
    fi

    ss::load_config "$CONFIG_FILE" "${SS_CONFIG_PREFIXES[@]}" NOTIFY_
    SS_CONFIG_LOADED="$CONFIG_FILE"
}

# 补加载（在 ss::parse_common_args 之后）
# -c/--config 在解析过程中才确定，需重新加载一次否则会被忽略。
# 排除 NOTIFY_: 通知配置由 notify_init 在解析后加载，须保持命令行参数优先
ss::config_reload() {
    if [ -n "${CONFIG_FILE:-}" ] && [ "$CONFIG_FILE" != "$SS_CONFIG_LOADED" ]; then
        ss::load_config "$CONFIG_FILE" "${SS_CONFIG_PREFIXES[@]}"
        SS_CONFIG_LOADED="$CONFIG_FILE"
    fi
}

# ------------------------------------------------------------------------------
# 日志输出
# ------------------------------------------------------------------------------
ss::log_info() {
    if [ "$QUIET" != "true" ]; then
        printf '\033[1;34mℹ️  %s\033[0m\n' "$1" >&3
    fi
}

ss::log_warn() {
    if [ "$QUIET" != "true" ]; then
        printf '\033[1;33m⚠️  %s\033[0m\n' "$1" >&3
    fi
}

ss::log_error() {
    printf '\033[1;31m❌ %s\033[0m\n' "$1" >&2
}

# ------------------------------------------------------------------------------
# 错误退出
# ------------------------------------------------------------------------------
ss::die() {
    ss::log_error "$1"
    exit "${2:-1}"
}

# ------------------------------------------------------------------------------
# JSON 字符串转义
# ------------------------------------------------------------------------------
ss::json_escape() {
    local string="$1"
    # 转义反斜杠、双引号、换行符、制表符、回车符
    string="${string//\\/\\\\}"
    string="${string//\"/\\\"}"
    string="${string//$'\n'/\\n}"
    string="${string//$'\t'/\\t}"
    string="${string//$'\r'/\\r}"
    echo "$string"
}

# ------------------------------------------------------------------------------
# 初始化
# ------------------------------------------------------------------------------
ss::detect_os

# 加载结构化告警库（提供 ss::alert_add / ss::alerts_write_json 等）
# shellcheck source=./alerts.sh
source "$SCRIPT_DIR/lib/alerts.sh"
