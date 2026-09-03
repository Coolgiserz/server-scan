#!/bin/bash
# ==============================================================================
# 脚本名称: cron_setup.sh
# 功能说明: 交互式管理 server-scan 的 crontab 定时任务
#             支持添加 / 查看 / 删除，写入前预览确认并自动备份
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL) / macOS（需支持 crontab）
# 依赖工具: crontab
# 使用方法:
#   交互菜单: ./server-scan cron
#   直接子命令: ./server-scan cron add | list | remove
# 安全说明:
#   - 只操作带 "# server-scan:" 标记的条目，不会影响用户的其他定时任务
#   - 每次写入前自动备份原 crontab 到 ~/.server-scan/
# ==============================================================================

# 获取项目根目录（脚本位于 core/ 子目录，根目录为其上一级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载共享库（含 i18n）
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cli.sh"

# 定时任务标记：用于在 crontab 中识别并隔离 server-scan 条目
CRON_MARK="# server-scan:"

# 入口脚本绝对路径（cron 环境 PATH 与终端不同，必须使用绝对路径）
SERVER_SCAN_BIN="$SCRIPT_DIR/server-scan"

# cron 环境下补全 PATH，避免 /usr/sbin 下的 iostat、smartctl 等找不到
CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ------------------------------------------------------------------------------
# 基础检查
# ------------------------------------------------------------------------------
_ss_cron_check() {
    if ! command -v crontab >/dev/null 2>&1; then
        ss::log_error "$(ss::msg MSG_CRON_ERR_NO_CRONTAB)"
        exit 1
    fi
}

# 交互环境检查（管道/重定向调用时无法进行菜单交互）
_ss_require_interactive() {
    if [ ! -t 0 ]; then
        ss::log_error "$(ss::msg MSG_CRON_ERR_NONINTERACTIVE)"
        exit 2
    fi
}

# ------------------------------------------------------------------------------
# 读取输入（带默认值）
# ------------------------------------------------------------------------------
_ss_ask() {
    local prompt="$1"
    local default="${2:-}"
    local answer=""
    # 提示语必须走 stderr：本函数通过命令替换调用，
    # 若提示语进 stdout 会与答案一起被捕获，导致答案变成 "提示语+输入"
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    read -r answer
    printf '%s' "${answer:-$default}"
}

# 是/否确认
_ss_confirm() {
    local prompt="$1"
    local answer=""
    printf '%s ' "$prompt" >&2
    read -r answer
    case "$answer" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# 备份当前 crontab
# ------------------------------------------------------------------------------
_ss_cron_backup() {
    local backup_dir="$HOME/.server-scan"
    local backup_file
    backup_file="${backup_dir}/crontab.backup.$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$backup_dir" 2>/dev/null
    crontab -l 2>/dev/null >"$backup_file"
    printf '%s' "$backup_file"
}

# ------------------------------------------------------------------------------
# 列出已有的 server-scan 定时任务
# ------------------------------------------------------------------------------
_ss_cron_list() {
    _ss_cron_check

    local current
    current=$(crontab -l 2>/dev/null)

    local tags
    tags=$(printf '%s\n' "$current" | grep "^$CRON_MARK" 2>/dev/null)

    if [ -z "$tags" ]; then
        echo "> $(ss::msg MSG_CRON_NO_TASKS)"
        return 0
    fi

    echo "### $(ss::msg MSG_CRON_EXISTING)"
    echo ""
    local idx=0
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        idx=$((idx + 1))
        echo "$idx) ${line#"$CRON_MARK"}"
    done <<<"$tags"
    echo ""
    return 0
}

# ------------------------------------------------------------------------------
# 构造 cron 表达式
# 用法: _ss_cron_build_expr <频率>  -> 输出到 stdout
# ------------------------------------------------------------------------------
_ss_cron_build_expr() {
    local freq="$1"
    local minute hour dow dom expr

    case "$freq" in
    hourly)
        minute=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_MINUTE)" "0")
        # 校验 0-59（允许 09 这类前导零写法）：
        # 越界值会生成 99 * * * * 这类永不触发的非法表达式
        if ! printf '%s' "$minute" | grep -Eq '^([0-9]|[0-5][0-9])$'; then
            ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_CHOICE)"
            return 1
        fi
        expr="$((10#$minute)) * * * *"
        ;;
    daily)
        local hm
        hm=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_TIME)" "02:00")
        if ! printf '%s' "$hm" | grep -Eq '^([0-1][0-9]|2[0-3]):[0-5][0-9]$'; then
            ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_TIME)"
            return 1
        fi
        hour="${hm%%:*}"
        minute="${hm##*:}"
        # 去掉可能的前导 0（cron 对 08 这类值在某些实现下会报错）
        hour=$((10#$hour))
        minute=$((10#$minute))
        expr="$minute $hour * * *"
        ;;
    weekly)
        local hm2
        hm2=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_TIME)" "03:00")
        if ! printf '%s' "$hm2" | grep -Eq '^([0-1][0-9]|2[0-3]):[0-5][0-9]$'; then
            ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_TIME)"
            return 1
        fi
        hour="${hm2%%:*}"
        minute="${hm2##*:}"
        hour=$((10#$hour))
        minute=$((10#$minute))
        dow=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_WEEKDAY)" "0")
        case "$dow" in
        '' | *[!0-6]*) ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_CHOICE)"; return 1 ;;
        esac
        expr="$minute $hour * * $dow"
        ;;
    monthly)
        local hm3
        hm3=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_TIME)" "04:00")
        if ! printf '%s' "$hm3" | grep -Eq '^([0-1][0-9]|2[0-3]):[0-5][0-9]$'; then
            ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_TIME)"
            return 1
        fi
        hour="${hm3%%:*}"
        minute="${hm3##*:}"
        hour=$((10#$hour))
        minute=$((10#$minute))
        dom=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_DAY)" "1")
        case "$dom" in
        '' | *[!0-9]*) ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_CHOICE)"; return 1 ;;
        esac
        expr="$minute $hour $dom * *"
        ;;
    custom)
        expr=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_CRON)")
        # 校验 5 个字段
        local fields
        fields=$(printf '%s' "$expr" | awk '{print NF}')
        if [ "$fields" != "5" ]; then
            ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_CRON)"
            return 1
        fi
        ;;
    *)
        return 1
        ;;
    esac

    printf '%s' "$expr"
}

# ------------------------------------------------------------------------------
# 交互式添加定时任务
# ------------------------------------------------------------------------------
_ss_cron_add() {
    _ss_cron_check
    _ss_require_interactive

    # --- 1. 选择扫描任务 ---
    local -a subs=("overview" "cpu-mem" "disk" "network" "security" "all")
    local -a descs=(
        "$(ss::msg MSG_SCAN_SUBCMD_OVERVIEW)"
        "$(ss::msg MSG_SCAN_SUBCMD_CPUMEM)"
        "$(ss::msg MSG_SCAN_SUBCMD_DISK)"
        "$(ss::msg MSG_SCAN_SUBCMD_NETWORK)"
        "$(ss::msg MSG_SCAN_SUBCMD_SECURITY)"
        "$(ss::msg MSG_SCAN_SUBCMD_ALL)"
    )

    echo ""
    echo "### $(ss::msg MSG_CRON_SELECT_SCRIPT)"
    echo ""
    local i
    for i in "${!subs[@]}"; do
        printf '  %d) %-10s - %s\n' "$((i + 1))" "${subs[$i]}" "${descs[$i]}"
    done
    echo ""

    local pick
    pick=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_CHOICE)" "1")
    if ! printf '%s' "$pick" | grep -Eq '^[1-6]$'; then
        ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_CHOICE)"
        return 1
    fi
    local sub="${subs[$((pick - 1))]}"

    # --- 2. 选择频率 ---
    echo ""
    echo "### $(ss::msg MSG_CRON_SELECT_FREQ)"
    echo ""
    echo "  1) $(ss::msg MSG_CRON_FREQ_HOURLY)"
    echo "  2) $(ss::msg MSG_CRON_FREQ_DAILY)"
    echo "  3) $(ss::msg MSG_CRON_FREQ_WEEKLY)"
    echo "  4) $(ss::msg MSG_CRON_FREQ_MONTHLY)"
    echo "  5) $(ss::msg MSG_CRON_FREQ_CUSTOM)"
    echo ""

    local fpick freq
    fpick=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_CHOICE)" "2")
    case "$fpick" in
    1) freq="hourly" ;;
    2) freq="daily" ;;
    3) freq="weekly" ;;
    4) freq="monthly" ;;
    5) freq="custom" ;;
    *)
        ss::log_error "$(ss::msg MSG_CRON_ERR_INVALID_CHOICE)"
        return 1
        ;;
    esac

    local expr
    expr=$(_ss_cron_build_expr "$freq") || return 1

    # --- 3. 输出目录与附加参数 ---
    echo ""
    local out_dir
    out_dir=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_OUTPUT)" "/var/log/server-scan")

    # 立即尝试创建输出目录；权限不足时提示（不阻断，cron 侧还有 mkdir 兜底）
    if [ ! -d "$out_dir" ]; then
        if mkdir -p "$out_dir" 2>/dev/null; then
            echo "> ✅ 已创建输出目录: $out_dir"
        else
            echo "> ⚠️ 无法创建输出目录（权限不足?）: $out_dir"
        fi
    fi

    echo ""
    local extra
    extra=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_ARGS)" "")

    # --- 4. 通知选项 ---
    local notify_env=""
    local notify_arg=""
    echo ""
    if _ss_confirm "$(ss::msg MSG_CRON_PROMPT_NOTIFY)"; then
        notify_arg=" --notify"
        if _ss_confirm "$(ss::msg MSG_CRON_PROMPT_ALERT_ONLY)"; then
            notify_env="NOTIFY_ON_ALERT_ONLY=true "
        fi
    fi

    # --- 5. 构造命令行 ---
    # crontab 中 % 必须转义为 \%，否则其后内容会被当作标准输入
    local date_expr='$(date +\%Y\%m\%d_\%H\%M\%S)'
    local report_file="${out_dir}/${sub}_${date_expr}.md"
    # mkdir -p 兜底：目录不存在时 tee 写入失败，而分析脚本仍以 0 退出，
    # 会造成"任务执行成功却无报告"的静默故障
    local cmd="${notify_env}PATH=${CRON_PATH} mkdir -p \"${out_dir}\" && ${SERVER_SCAN_BIN} ${sub} -o \"${report_file}\"${notify_arg}"
    if [ -n "$extra" ]; then
        cmd="${cmd} ${extra}"
    fi

    # --- 6. 预览并确认 ---
    echo ""
    echo "### $(ss::msg MSG_CRON_PREVIEW)"
    echo ""
    echo '```'
    echo "${CRON_MARK}${sub}"
    echo "${expr} ${cmd}"
    echo '```'
    echo ""
    echo "> ℹ️ $(ss::msg MSG_CRON_NOTE_ABSOLUTE)"
    echo "> ℹ️ $(ss::msg MSG_CRON_NOTE_LOG)"
    echo ""

    if ! _ss_confirm "$(ss::msg MSG_CRON_CONFIRM)"; then
        echo "> $(ss::msg MSG_CRON_CANCELLED)"
        return 0
    fi

    # --- 7. 备份并写入 ---
    local backup current
    backup=$(_ss_cron_backup)
    current=$(crontab -l 2>/dev/null)

    {
        if [ -n "$current" ]; then
            printf '%s\n' "$current"
            printf '\n'
        fi
        printf '%s%s\n' "$CRON_MARK" "$sub"
        printf '%s %s\n' "$expr" "$cmd"
    } | crontab -

    if [ $? -ne 0 ]; then
        ss::log_error "$(ss::msg MSG_CRON_ERR_NO_CRONTAB)"
        return 1
    fi

    echo ""
    echo "> $(ss::msg MSG_CRON_ADDED)"
    echo "> $(ss::msgf MSG_CRON_BACKUP "$backup")"
    return 0
}

# ------------------------------------------------------------------------------
# 交互式删除定时任务
# ------------------------------------------------------------------------------
_ss_cron_remove() {
    _ss_cron_check
    _ss_require_interactive

    local current
    current=$(crontab -l 2>/dev/null)

    local tags
    tags=$(printf '%s\n' "$current" | grep "^$CRON_MARK" 2>/dev/null)

    if [ -z "$tags" ]; then
        echo "> $(ss::msg MSG_CRON_NO_TASKS)"
        return 0
    fi

    echo ""
    echo "### $(ss::msg MSG_CRON_EXISTING)"
    echo ""
    local idx=0
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        idx=$((idx + 1))
        echo "$idx) ${line#"$CRON_MARK"}"
    done <<<"$tags"
    echo ""

    local pick
    pick=$(_ss_ask "$(ss::msg MSG_CRON_SELECT_REMOVE)" "")
    local total=$idx
    if ! printf '%s' "$pick" | grep -Eq "^[0-9]+$" ||
        [ "$pick" -lt 1 ] || [ "$pick" -gt "$total" ]; then
        ss::log_error "$(ss::msg MSG_CRON_ERR_NO_SUCH_TASK)"
        return 1
    fi

    # 预览将被删除的条目
    echo ""
    echo "### $(ss::msg MSG_CRON_PREVIEW)"
    echo ""
    echo '```'
    printf '%s\n' "$current" | awk -v mark="$CRON_MARK" -v target="$pick" -v bin="$SERVER_SCAN_BIN" '
    BEGIN { n = 0; pending = 0 }
    {
        if (index($0, mark) == 1) {
            n++
            if (n == target) { pending = 1; print; next }
        }
        if (pending) {
            pending = 0
            # 仅显示确实属于 server-scan 的命令，避免预览到他人条目
            if (index($0, bin) > 0) { print }
            next
        }
    }
    '
    echo '```'
    echo ""

    if ! _ss_confirm "$(ss::msg MSG_CRON_CONFIRM)"; then
        echo "> $(ss::msg MSG_CRON_CANCELLED)"
        return 0
    fi

    local backup
    backup=$(_ss_cron_backup)

    # 删除目标条目的标记行与其后的命令行
    printf '%s\n' "$current" | awk -v mark="$CRON_MARK" -v target="$pick" -v bin="$SERVER_SCAN_BIN" '
    BEGIN { n = 0; pending = 0 }
    {
        # 命中目标标记行则删除，并置 pending
        if (index($0, mark) == 1) {
            n++
            if (n == target) { pending = 1; next }
        }
        # 仅当下一行确实属于 server-scan 时才连带删除，
        # 避免标记行位于末尾或紧邻他人任务时误删
        if (pending) {
            pending = 0
            if (index($0, bin) > 0) next
        }
        print
    }
    ' | crontab -

    echo ""
    echo "> $(ss::msg MSG_CRON_REMOVED)"
    echo "> $(ss::msgf MSG_CRON_BACKUP "$backup")"
    return 0
}

# ------------------------------------------------------------------------------
# 交互菜单
# ------------------------------------------------------------------------------
_ss_cron_menu() {
    _ss_cron_check
    _ss_require_interactive

    while true; do
        echo ""
        echo "=== $(ss::msg MSG_CRON_TITLE) ==="
        echo ""
        echo "  1) $(ss::msg MSG_CRON_MENU_LIST)"
        echo "  2) $(ss::msg MSG_CRON_MENU_ADD)"
        echo "  3) $(ss::msg MSG_CRON_MENU_REMOVE)"
        echo "  0) $(ss::msg MSG_CRON_MENU_EXIT)"
        echo ""
        local choice
        choice=$(_ss_ask "$(ss::msg MSG_CRON_PROMPT_CHOICE)" "1")
        case "$choice" in
        1) _ss_cron_list ;;
        2) _ss_cron_add ;;
        3) _ss_cron_remove ;;
        0)
            echo "> $(ss::msg MSG_CRON_CANCELLED)"
            return 0
            ;;
        *) echo "> $(ss::msg MSG_CRON_ERR_INVALID_CHOICE)" ;;
        esac
    done
}

# ==============================================================================
# 主入口（仅在直接执行时运行，便于被 source 后单独测试内部函数）
# ==============================================================================
_ss_cron_main() {
    case "${1:-}" in
    list | ls)
        _ss_cron_list
        ;;
    add)
        _ss_cron_add
        ;;
    remove | rm)
        _ss_cron_remove
        ;;
    -h | --help)
        echo "$(ss::msg MSG_CRON_TITLE)"
        echo ""
        echo "$(ss::msg MSG_HELP_USAGE): server-scan cron [add|list|remove]"
        echo ""
        echo "  add     $(ss::msg MSG_CRON_MENU_ADD)"
        echo "  list    $(ss::msg MSG_CRON_MENU_LIST)"
        echo "  remove  $(ss::msg MSG_CRON_MENU_REMOVE)"
        echo ""
        echo "$(ss::msg MSG_HELP_EXAMPLES):"
        echo "  ./server-scan cron          # $(ss::msg MSG_CRON_MENU)"
        echo "  ./server-scan cron list"
        echo "  ./server-scan cron add"
        echo "  ./server-scan cron remove"
        exit 0
        ;;
    "")
        _ss_cron_menu
        ;;
    *)
        ss::log_error "$(ss::msgf MSG_ERROR_UNKNOWN_ARG "$1")"
        exit 2
        ;;
    esac
}

# 注意: exit 必须包含在上面的判断内，否则被 source 测试时会直接退出调用方 shell
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _ss_cron_main "$@"
    exit $?
fi

# ==============================================================================
# 使用说明:
# 1. 交互菜单: ./server-scan cron
# 2. 查看任务: ./server-scan cron list
# 3. 添加任务: ./server-scan cron add
# 4. 删除任务: ./server-scan cron remove
# 5. 生成的条目示例:
#      # server-scan:overview
#      0 2 * * * PATH=/usr/local/sbin:... /path/to/server-scan overview \
#        -o "/var/log/server-scan/overview_$(date +\%Y\%m\%d_\%H\%M\%S).md" --notify
# 6. 安全说明: 只操作带 "# server-scan:" 标记的条目，写入前自动备份到
#    ~/.server-scan/crontab.backup.<时间戳>
# ==============================================================================
