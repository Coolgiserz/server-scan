#!/bin/bash
# ==============================================================================
# lib/common.sh - server-scan 共享函数库
# ==============================================================================
# 此文件包含所有脚本共享的函数和工具，避免代码重复
# 使用方法: source "$SCRIPT_DIR/lib/common.sh"
# ==============================================================================

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
        printf '\n\033[1;32m🚀 %s\033[0m (共 %s 个章节，执行期间会逐章显示进度)\n' "$title" "$total_sections" >&3
    fi
}

# ------------------------------------------------------------------------------
# 报告结束
# ------------------------------------------------------------------------------
ss::report_end() {
    local report_path="$1"

    # 恢复原始 stdout，然后将临时文件同步输出到终端和报告路径
    exec 1>&3

    # 使用 cat + tee 替代异步的进程替换，避免输出交错
    cat "$TMP_REPORT" | tee "$report_path"
    rm -f "$TMP_REPORT"

    # 完成提示（实时打印到终端）
    if [ "$QUIET" != "true" ]; then
        printf '\033[1;32m✅ 分析完成\033[0m 报告已保存至: %s\n' "$report_path" >&3
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
ss::load_config() {
    local config_file="$1"
    shift
    local allowed_prefixes=("$@")

    # 如果配置文件存在，则加载
    if [ -f "$config_file" ]; then
        # 加载配置文件，只加载以特定前缀开头的变量
        while IFS='=' read -r key value; do
            # 跳过注释和空行
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue

            # 去除首尾空格
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            # 去除引号
            value=$(echo "$value" | sed 's/^["'\'']//;s/["'\'']$//')

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
                eval "$key=\"$value\""
            fi
        done <"$config_file"
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
