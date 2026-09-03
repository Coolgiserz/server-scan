#!/bin/bash
# shellcheck disable=SC2034
# ==============================================================================
# lib/notify.sh - server-scan 扫描结果通知推送（Channel）
# ==============================================================================
# 将扫描报告推送到外部 Channel（当前支持飞书自定义机器人）
#
# 使用方法: source "$SCRIPT_DIR/lib/notify.sh"
#
# 配置优先级（高 -> 低）:
#   1. 命令行参数    --notify / --notify-channel / --webhook
#   2. 环境变量      NOTIFY_ENABLED / NOTIFY_WEBHOOK / ...
#   3. 配置文件      通过 NOTIFY_CONFIG 指定，或按默认路径查找
#
# 配置文件查找顺序（找到第一个存在的文件即停止）:
#   1. $NOTIFY_CONFIG
#   2. $SCRIPT_DIR/notify.conf
#   3. $HOME/.server-scan/notify.conf
#   4. /etc/server-scan/notify.conf
# ==============================================================================

# ------------------------------------------------------------------------------
# 默认配置（只在未设置时才初始化，避免覆盖环境变量/命令行传入的值）
# ------------------------------------------------------------------------------
NOTIFY_ENABLED="${NOTIFY_ENABLED:-false}"            # 是否启用通知推送
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-feishu}"           # 通知渠道: feishu
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"                 # Webhook 地址
NOTIFY_SECRET="${NOTIFY_SECRET:-}"                   # 签名密钥（飞书安全设置，可选）
NOTIFY_MSG_TYPE="${NOTIFY_MSG_TYPE:-text}"           # 消息类型: text | card
NOTIFY_MODE="${NOTIFY_MODE:-summary}"                # 内容模式: summary(摘要) | full(全文)
NOTIFY_MAX_BYTES="${NOTIFY_MAX_BYTES:-20000}"        # 全文模式下正文最大字节数
NOTIFY_TIMEOUT="${NOTIFY_TIMEOUT:-10}"               # HTTP 请求超时（秒）
NOTIFY_ON_ALERT_ONLY="${NOTIFY_ON_ALERT_ONLY:-false}" # 仅在检测到告警时发送
NOTIFY_MENTION_ALL="${NOTIFY_MENTION_ALL:-false}"    # 是否 @所有人（飞书）
NOTIFY_MENTION_IDS="${NOTIFY_MENTION_IDS:-}"         # @指定用户 ID，逗号分隔（飞书）
NOTIFY_SUMMARY_LINES="${NOTIFY_SUMMARY_LINES:-20}"   # 摘要模式提取的告警行上限
# 表格呈现方式（飞书 text 与卡片 lark_md 均不支持 Markdown 表格）:
#   kv   - 转为 "🔴 **维度**: 说明" 列表，两种消息类型下都美观（默认）
#   code - 保留表格并包裹代码块，卡片下等宽对齐
#   raw  - 不做转换
NOTIFY_TABLE_STYLE="${NOTIFY_TABLE_STYLE:-kv}"

# ------------------------------------------------------------------------------
# 内部日志（写 stderr，避免污染 stdout 与 JSON 输出）
# 注意: ss::report_end 之后 fd3 已关闭，不能使用 ss::log_info
# ------------------------------------------------------------------------------
_ss_notify_log() {
    [ "$QUIET" = "true" ] && return 0
    printf '📢 %s\n' "$1" >&2
}

# ------------------------------------------------------------------------------
# Webhook 脱敏（日志中隐藏敏感后缀）
# ------------------------------------------------------------------------------
_ss_notify_mask() {
    local url="$1"
    local len=${#url}
    if [ "$len" -le 24 ]; then
        printf '%s' "***"
        return
    fi
    # 只保留协议与域名部分，路径（含 token）全部打码
    printf '%s***' "${url:0:24}"
}

# ------------------------------------------------------------------------------
# 通知配置初始化
# 由 ss::parse_common_args 在解析完命令行参数后自动调用，脚本无需手动调用
# ------------------------------------------------------------------------------
ss::notify_init() {
    # 保存命令行传入的值（用于覆盖配置文件）
    local cli_enabled="${SS_CLI_NOTIFY_ENABLED:-}"
    local cli_channel="${SS_CLI_NOTIFY_CHANNEL:-}"
    local cli_webhook="${SS_CLI_WEBHOOK:-}"

    # 配置文件查找
    # NOTIFY_CONFIG 与脚本 -c/--config 指定的配置文件优先于默认路径，
    # 因为显式指定代表用户明确意图
    local candidates=()
    [ -n "${NOTIFY_CONFIG:-}" ] && candidates+=("$NOTIFY_CONFIG")
    [ -n "${CONFIG_FILE:-}" ] && candidates+=("$CONFIG_FILE")
    candidates+=("$SCRIPT_DIR/notify.conf")
    candidates+=("$HOME/.server-scan/notify.conf")
    candidates+=("/etc/server-scan/notify.conf")

    NOTIFY_CONFIG_FILE=""
    for conf in "${candidates[@]}"; do
        [ -z "$conf" ] && continue
        if [ -f "$conf" ]; then
            ss::load_config "$conf" NOTIFY_
            NOTIFY_CONFIG_FILE="$conf"
            break
        fi
    done

    # 命令行参数优先级最高
    [ "$cli_enabled" = "true" ] && NOTIFY_ENABLED="true"
    [ -n "$cli_channel" ] && NOTIFY_CHANNEL="$cli_channel"
    [ -n "$cli_webhook" ] && NOTIFY_WEBHOOK="$cli_webhook"

    # 布尔值归一化，容忍 True/TRUE/1/yes
    case "$NOTIFY_ENABLED" in
    true | TRUE | True | 1 | yes | YES) NOTIFY_ENABLED="true" ;;
    *) NOTIFY_ENABLED="false" ;;
    esac
    case "$NOTIFY_ON_ALERT_ONLY" in
    true | TRUE | True | 1 | yes | YES) NOTIFY_ON_ALERT_ONLY="true" ;;
    *) NOTIFY_ON_ALERT_ONLY="false" ;;
    esac
    case "$NOTIFY_MENTION_ALL" in
    true | TRUE | True | 1 | yes | YES) NOTIFY_MENTION_ALL="true" ;;
    *) NOTIFY_MENTION_ALL="false" ;;
    esac

    # 渠道归一化（lark 为飞书海外版别名）
    case "$NOTIFY_CHANNEL" in
    feishu | FeiShu | FEISHU | lark | Lark) NOTIFY_CHANNEL="feishu" ;;
    esac

    # 数值型配置兜底：非法值会导致算术展开失败，使推送以晦涩错误告终
    case "$NOTIFY_TIMEOUT" in
    '' | *[!0-9]*) NOTIFY_TIMEOUT=10 ;;
    esac
    case "$NOTIFY_MAX_BYTES" in
    '' | *[!0-9]*) NOTIFY_MAX_BYTES=20000 ;;
    esac
    case "$NOTIFY_SUMMARY_LINES" in
    '' | *[!0-9]*) NOTIFY_SUMMARY_LINES=20 ;;
    esac

    # 配置文件权限检查（含密钥时不应对其他用户可读）
    if [ -n "$NOTIFY_CONFIG_FILE" ] && [ -n "$NOTIFY_SECRET" ]; then
        if [ -r "$NOTIFY_CONFIG_FILE" ]; then
            local perm
            # macOS: stat -f '%Lp'；Linux: stat -c '%a'，均返回三位八进制如 644
            perm=$(stat -f '%Lp' "$NOTIFY_CONFIG_FILE" 2>/dev/null ||
                stat -c '%a' "$NOTIFY_CONFIG_FILE" 2>/dev/null)
            # 末位为 other 权限位，非 0 表示其他用户可读/写/执行
            case "$perm" in
            *[1-7])
                _ss_notify_log "$(ss::msgf MSG_NOTIFY_INSECURE_PERM "$NOTIFY_CONFIG_FILE")"
                ;;
            esac
        fi
    fi
}

# ------------------------------------------------------------------------------
# 检测报告中是否包含告警项（🔴 / 🟡 为各分析脚本统一的告警标记）
# ------------------------------------------------------------------------------
_ss_notify_has_alert() {
    local report_path="$1"
    [ -f "$report_path" ] || return 1
    grep -qE '🔴|🟡' "$report_path" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 提取摘要: 优先使用脚本传入的 summary，再附加报告中的告警行
# ------------------------------------------------------------------------------
_ss_notify_extract_summary() {
    local report_path="$1"
    local summary="$2"
    local out=""

    if [ -n "$summary" ]; then
        out="$summary"
    fi

    if [ -f "$report_path" ]; then
        local alerts
        # keep_first=1: 这些是从报告中筛出的零散数据行，首行不是表头
        alerts=$(grep -E '🔴|🟡' "$report_path" 2>/dev/null |
            sed 's/^[[:space:]]*//' |
            grep -v '^$' |
            sort -u |
            head -n "$NOTIFY_SUMMARY_LINES" |
            _ss_notify_format_tables 1)
        if [ -n "$alerts" ]; then
            if [ -n "$out" ]; then
                out="${out}"$'\n'"$(ss::msg MSG_NOTIFY_SECTION_ALERTS)"$'\n'"${alerts}"
            else
                out="$(ss::msg MSG_NOTIFY_SECTION_ALERTS)"$'\n'"${alerts}"
            fi
        fi
    fi

    if [ -z "$out" ]; then
        out="$(ss::msg MSG_NOTIFY_NO_ALERT)"
    fi

    printf '%s' "$out"
}

# ------------------------------------------------------------------------------
# Markdown 表格格式化
# 飞书 text 与卡片 lark_md 均不支持 Markdown 表格，裸竖线可读性很差，
# 因此按 NOTIFY_TABLE_STYLE 统一转换为飞书友好的呈现方式
# ------------------------------------------------------------------------------
_ss_notify_format_tables() {
    # $1=keep_first: 1 表示首行按数据处理（用于已提取的零散告警行，无表头）
    local keep_first="${1:-0}"
    case "$NOTIFY_TABLE_STYLE" in
    raw)
        cat
        ;;
    code)
        awk '
        BEGIN { in_tbl = 0 }
        {
            if ($0 ~ /^\|/) {
                if (!in_tbl) { print "```"; in_tbl = 1 }
                print
                next
            }
            if (in_tbl) { print "```"; print ""; in_tbl = 0 }
            print
        }
        END { if (in_tbl) print "```" }
        '
        ;;
    kv | *)
        awk -v keep_first="$keep_first" '
        BEGIN { in_tbl = 0; icons = "🔴🟡🟢⚪✅❌⚠️ℹ️" }
        {
            if ($0 ~ /^\|/) {
                # 分隔行 (|---|:---:|) 去掉 | - : 后为空
                tmp = $0
                gsub(/[|: -]/, "", tmp)
                if (tmp == "") next
                # 表格首行为表头，其列名与数据行语义重复，丢弃
                # keep_first=1 时首行即数据（已提取的零散行），不丢弃
                if (!in_tbl) {
                    in_tbl = 1
                    if (!keep_first) next
                }

                s = $0
                sub(/^\|/, "", s)
                sub(/\|$/, "", s)
                n = split(s, cols, "|")

                # 收集非空的列
                cnt = 0
                for (i = 1; i <= n; i++) {
                    gsub(/^ +| +$/, "", cols[i])
                    if (cols[i] == "" || cols[i] == "-") continue
                    vals[++cnt] = cols[i]
                }
                if (cnt == 0) next

                # 首列若为状态图标，则作为前缀，key 顺延到第二列
                prefix = ""
                k = 1
                if (cnt > 1 && index(icons, vals[1]) > 0) {
                    prefix = vals[1] " "
                    k = 2
                }

                key = vals[k]
                vs = ""
                for (i = k + 1; i <= cnt; i++) {
                    vs = (vs == "") ? vals[i] : vs "   " vals[i]
                }
                # 超长值（如深层文件路径）会撑宽卡片，做截断
                if (length(vs) > 100) vs = substr(vs, 1, 97) "..."
                if (vs != "") print prefix "**" key "**: " vs
                else print prefix "**" key "**"
                next
            }
            if (in_tbl) { in_tbl = 0; print "" }
            print
        }
        '
        ;;
    esac
}

# ------------------------------------------------------------------------------
# 全文模式: 读取报告、格式化表格后截断到 MAX_BYTES（避免超出飞书 30KB 限制）
# 使用 iconv -c 丢弃截断产生的不完整 UTF-8 字节
# ------------------------------------------------------------------------------
_ss_notify_read_full() {
    local report_path="$1"
    local content
    content=$(_ss_notify_format_tables <"$report_path" 2>/dev/null)

    local out
    out=$(printf '%s' "$content" | head -c "$NOTIFY_MAX_BYTES" 2>/dev/null |
        iconv -f utf-8 -t utf-8 -c 2>/dev/null)
    if [ -z "$out" ]; then
        out=$(printf '%s' "$content" | head -c "$NOTIFY_MAX_BYTES" 2>/dev/null)
    fi

    local size
    size=$(printf '%s' "$content" | wc -c 2>/dev/null | tr -d ' ' | tr -d '\n')
    if [ -n "$size" ] && [ "$size" -gt "$NOTIFY_MAX_BYTES" ] 2>/dev/null; then
        out="${out}"$'\n'"..."$'\n'"$(ss::msgf MSG_NOTIFY_TRUNCATED "$report_path")"
    fi
    printf '%s' "$out"
}

# ------------------------------------------------------------------------------
# 构建消息正文
# ------------------------------------------------------------------------------
_ss_notify_build_content() {
    local title="$1"
    local report_path="$2"
    local summary="$3"
    local body

    if [ "$NOTIFY_MODE" = "full" ] && [ -f "$report_path" ]; then
        body=$(_ss_notify_read_full "$report_path")
    else
        body=$(_ss_notify_extract_summary "$report_path" "$summary")
    fi

    local text
    text=$(printf '%s\n%s\n%s\n%s\n\n%s' \
        "$(ss::msgf MSG_NOTIFY_HEADER_TITLE "$title")" \
        "$(ss::msgf MSG_NOTIFY_HEADER_HOST "$(hostname)")" \
        "$(ss::msgf MSG_NOTIFY_HEADER_TIME "$(date '+%Y-%m-%d %H:%M:%S')")" \
        "$(ss::msgf MSG_NOTIFY_HEADER_REPORT "$report_path")" \
        "$body")

    # 追加 @提及（飞书语法）
    local mention
    mention=$(_ss_feishu_mention)
    if [ -n "$mention" ]; then
        text="${text}"$'\n'"${mention}"
    fi

    printf '%s' "$text"
}

# ------------------------------------------------------------------------------
# 对外主入口: 发送通知
# 用法: ss::notify_send <标题> <报告路径> [摘要]
# 未启用时静默返回 0；失败返回 1（不影响脚本主流程的退出码）
# ------------------------------------------------------------------------------
ss::notify_send() {
    local title="$1"
    local report_path="${2:-}"
    local summary="${3:-}"

    # 未启用则静默跳过
    if [ "$NOTIFY_ENABLED" != "true" ]; then
        return 0
    fi

    # 校验 webhook
    if [ -z "$NOTIFY_WEBHOOK" ]; then
        _ss_notify_log "$(ss::msg MSG_NOTIFY_NO_WEBHOOK)"
        return 1
    fi

    # 校验 curl
    if ! command -v curl >/dev/null 2>&1; then
        _ss_notify_log "$(ss::msg MSG_NOTIFY_NO_CURL)"
        return 1
    fi

    # 仅在有告警时发送
    # 以报告中的 🔴/🟡 标记为准，与各分析脚本的告警语义保持一致
    if [ "$NOTIFY_ON_ALERT_ONLY" = "true" ]; then
        if ! _ss_notify_has_alert "$report_path"; then
            _ss_notify_log "$(ss::msg MSG_NOTIFY_SKIP_NO_ALERT)"
            return 0
        fi
    fi

    local content
    content=$(_ss_notify_build_content "$title" "$report_path" "$summary")

    _ss_notify_log "$(ss::msgf MSG_NOTIFY_SENDING "$NOTIFY_CHANNEL")"

    local ret=0
    case "$NOTIFY_CHANNEL" in
    feishu)
        _ss_feishu_send "$title" "$content" || ret=1
        ;;
    *)
        _ss_notify_log "$(ss::msgf MSG_NOTIFY_UNSUPPORTED_CHANNEL "$NOTIFY_CHANNEL")"
        ret=1
        ;;
    esac

    return $ret
}

# ------------------------------------------------------------------------------
# 飞书: 签名计算
# 算法: key = "${timestamp}\n${secret}"，message 为空，HMAC-SHA256 后 Base64
# 注意: 此用法与多数平台相反（飞书以拼接串作为 key、空串作为 message）
# ------------------------------------------------------------------------------
_ss_feishu_sign() {
    local timestamp="$1"
    local secret="$2"

    if ! command -v openssl >/dev/null 2>&1; then
        return 1
    fi

    printf '' | openssl dgst -sha256 -hmac "${timestamp}"$'\n'"${secret}" -binary 2>/dev/null |
        base64 | tr -d '\n'
}

# ------------------------------------------------------------------------------
# 飞书: 构造 @提及片段
# ------------------------------------------------------------------------------
_ss_feishu_mention() {
    local parts=""

    if [ "$NOTIFY_MENTION_ALL" = "true" ]; then
        parts='<at user_id="all">所有人</at>'
    fi

    if [ -n "$NOTIFY_MENTION_IDS" ]; then
        local old_ifs="$IFS"
        IFS=','
        # shellcheck disable=SC2086
        set -- ${NOTIFY_MENTION_IDS}
        IFS="$old_ifs"
        for uid in "$@"; do
            uid=$(echo "$uid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$uid" ] && continue
            if [ -n "$parts" ]; then
                parts="${parts} "
            fi
            parts="${parts}<at user_id=\"${uid}\">${uid}</at>"
        done
    fi

    printf '%s' "$parts"
}

# ------------------------------------------------------------------------------
# 飞书: text 类型消息体
# ------------------------------------------------------------------------------
_ss_feishu_text_payload() {
    local content="$1"
    local timestamp="$2"
    local sign="$3"

    local head=""
    if [ -n "$sign" ]; then
        head="\"timestamp\":\"$(ss::json_escape "$timestamp")\",\"sign\":\"$(ss::json_escape "$sign")\","
    fi

    # head 自带前导引号与结尾逗号（为空时直接拼接 "msg_type"）
    printf '{%s"msg_type":"text","content":{"text":"%s"}}' \
        "$head" "$(ss::json_escape "$content")"
}

# ------------------------------------------------------------------------------
# 飞书: interactive 卡片消息体
# header 颜色根据告警级别自适应: 有 🔴 为 red，有 🟡 为 orange，否则 green
# ------------------------------------------------------------------------------
_ss_feishu_card_payload() {
    local title="$1"
    local content="$2"
    local timestamp="$3"
    local sign="$4"

    local template="green"
    if printf '%s' "$content" | grep -q '🔴'; then
        template="red"
    elif printf '%s' "$content" | grep -q '🟡'; then
        template="orange"
    fi

    local head=""
    if [ -n "$sign" ]; then
        head="\"timestamp\":\"$(ss::json_escape "$timestamp")\",\"sign\":\"$(ss::json_escape "$sign")\","
    fi

    printf '{%s"msg_type":"interactive","card":{"config":{"wide_screen_mode":true},"header":{"title":{"tag":"plain_text","content":"%s"},"template":"%s"},"elements":[{"tag":"div","text":{"tag":"lark_md","content":"%s"}},{"tag":"hr"},{"tag":"note","elements":[{"tag":"plain_text","content":"%s"}]}]}}' \
        "$head" \
        "$(ss::json_escape "$title")" \
        "$template" \
        "$(ss::json_escape "$content")" \
        "$(ss::json_escape "$(ss::msg MSG_NOTIFY_CARD_FOOTER)")"
}

# ------------------------------------------------------------------------------
# 飞书: 发送消息
# ------------------------------------------------------------------------------
_ss_feishu_send() {
    local title="$1"
    local content="$2"

    # 签名（可选）
    local timestamp=""
    local sign=""
    if [ -n "$NOTIFY_SECRET" ]; then
        timestamp=$(date +%s)
        sign=$(_ss_feishu_sign "$timestamp" "$NOTIFY_SECRET")
        if [ -z "$sign" ]; then
            _ss_notify_log "$(ss::msg MSG_NOTIFY_SIGN_FAIL)"
            return 1
        fi
    fi

    # 构造消息体
    local payload
    if [ "$NOTIFY_MSG_TYPE" = "card" ]; then
        payload=$(_ss_feishu_card_payload "$title" "$content" "$timestamp" "$sign")
    else
        payload=$(_ss_feishu_text_payload "$content" "$timestamp" "$sign")
    fi

    # 发送（curl --max-time 控制单次超时，run_with_timeout 兜底防挂起）
    # 不重试：请求可能已到达飞书但响应超时，重试会造成群内重复消息；
    # 定时巡检场景下，下一次周期执行即可补偿偶发失败
    local response
    response=$(ss::run_with_timeout "$((NOTIFY_TIMEOUT + 5))" \
        curl -sS -X POST \
        -H 'Content-Type: application/json' \
        --max-time "$NOTIFY_TIMEOUT" \
        -d "$payload" \
        "$NOTIFY_WEBHOOK" 2>&1)
    local curl_ret=$?

    if [ "$curl_ret" -ne 0 ]; then
        _ss_notify_log "$(ss::msgf MSG_NOTIFY_FAIL "$(ss::msg MSG_NOTIFY_ERR_NETWORK)")"
        return 1
    fi

    # 判定结果: 飞书成功返回 StatusCode:0 / code:0 / "msg":"success"
    if printf '%s' "$response" | grep -qE '"StatusCode":0|"code":0|"msg":"success"|"StatusMessage":"success"'; then
        _ss_notify_log "$(ss::msg MSG_NOTIFY_SUCCESS)"
        return 0
    fi

    local reason
    reason=$(printf '%s' "$response" | tr -d '\n' | cut -c1-200)
    [ -z "$reason" ] && reason="$(ss::msg MSG_NOTIFY_ERR_EMPTY)"
    _ss_notify_log "$(ss::msgf MSG_NOTIFY_FAIL "$reason")"
    return 1
}

# ------------------------------------------------------------------------------
# 测试通知连通性（供 --notify-test 使用）
# 用法: ss::notify_test [渠道]
# ------------------------------------------------------------------------------
ss::notify_test() {
    local channel="${1:-$NOTIFY_CHANNEL}"

    if [ -z "$NOTIFY_WEBHOOK" ]; then
        _ss_notify_log "$(ss::msg MSG_NOTIFY_NO_WEBHOOK)"
        return 1
    fi

    _ss_notify_log "$(ss::msgf MSG_NOTIFY_TESTING "$channel")"
    _ss_notify_log "$(ss::msgf MSG_NOTIFY_TEST_WEBHOOK "$(_ss_notify_mask "$NOTIFY_WEBHOOK")")"

    local content
    content=$(printf '%s\n%s\n%s' \
        "$(ss::msgf MSG_NOTIFY_TEST_TITLE "$(hostname)")" \
        "$(ss::msgf MSG_NOTIFY_HEADER_TIME "$(date '+%Y-%m-%d %H:%M:%S')")" \
        "$(ss::msg MSG_NOTIFY_TEST_BODY)")

    local ret=0
    case "$channel" in
    feishu)
        _ss_feishu_send "$(ss::msg MSG_NOTIFY_TEST_TITLE_SHORT)" "$content" || ret=1
        ;;
    *)
        _ss_notify_log "$(ss::msgf MSG_NOTIFY_UNSUPPORTED_CHANNEL "$channel")"
        ret=1
        ;;
    esac
    return $ret
}
