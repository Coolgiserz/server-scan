#!/bin/bash
# ==============================================================================
# 脚本名称: config_manager.sh
# 功能说明: 配置文件迁移与升级管理
#   配置文件会随版本演进（文件更名、新增配置项、废弃配置项），
#   此处提供自动迁移/升级能力，避免每次变更都要人工复制粘贴
#
# 子命令:
#   migrate   旧版 disk_analyzer.conf -> 统一 server-scan.conf（旧文件改名备份）
#   upgrade   用 server-scan.conf.example 中的新增项补齐当前配置
#             （保留已有值、保留注释，改动前自动备份）
#   check     检查生效配置文件、未知项（拼写错误/已废弃）、缺失的新增项
#   show      显示当前生效的配置文件路径与内容
#
# 使用方法: ./server-scan config <migrate|upgrade|check|show>
# ==============================================================================

# 获取项目根目录（脚本位于 core/ 子目录，根目录为其上一级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载共享库（提供 ss::msg / ss::msgf / ss::log_error）
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_EXAMPLE="$SCRIPT_DIR/server-scan.conf.example"
LEGACY_CONF="$SCRIPT_DIR/disk_analyzer.conf"
UNIFIED_CONF="$SCRIPT_DIR/server-scan.conf"

# ------------------------------------------------------------------------------
# 提取配置文件中的键名（跳过注释、空行与非法键名）
# 与 ss::load_config 的键名校验规则保持一致
# ------------------------------------------------------------------------------
_ss_conf_keys() {
    local file="$1"
    [ -f "$file" ] || return 0
    local key
    while IFS='=' read -r key _rest; do
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$key" ] && continue
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        printf '%s\n' "$key"
    done <"$file"
}

# ------------------------------------------------------------------------------
# 取出指定键在文件中的原始行（保留行内注释）
# ------------------------------------------------------------------------------
_ss_conf_line() {
    local file="$1" want="$2"
    grep -E "^[[:space:]]*${want}=" "$file" 2>/dev/null | head -1
}

# ------------------------------------------------------------------------------
# 取出键在示例中的「说明注释 + 键值」整块
# 注释独占一行、位于变量上方，因此补齐时能把说明一并写入
# ------------------------------------------------------------------------------
_ss_conf_block() {
    local file="$1" want="$2"
    awk -v k="$want" '
    function is_sep(l) { return (l ~ /^[[:space:]]*#[[:space:]]*(=====|-----)/) }
    {
        if (is_sep($0)) { buf = ""; next }
        if ($0 ~ /^[[:space:]]*#/) { buf = buf $0 "\n"; next }
        if ($0 ~ "^[[:space:]]*" k "=") { printf "%s%s\n", buf, $0; exit }
        buf = ""
    }
    ' "$file"
}

# ------------------------------------------------------------------------------
# 统计「注释与变量同行」的行数（约定上应为 0）
# 引号内的 # 不算注释
# ------------------------------------------------------------------------------
_ss_conf_inline_comment_count() {
    local file="$1"
    [ -f "$file" ] || {
        printf '0'
        return 0
    }
    # 注意: awk 程序由单引号包裹，内部不能出现字面量单引号，
    # 因此用字符码构造引号字符再比较
    awk '
    BEGIN { DQ = sprintf("%c", 34); SQ = sprintf("%c", 39) }
    {
        line = $0
        if (line ~ /^[[:space:]]*(#|$)/) next
        idx = index(line, "=")
        if (idx == 0) next
        rest = substr(line, idx + 1)
        sub(/^[[:space:]]+/, "", rest)
        q = substr(rest, 1, 1)
        if (q == DQ || q == SQ) {
            c = index(substr(rest, 2), q)
            if (c == 0) next
            tailv = substr(rest, c + 2)
        } else {
            pos = match(rest, /[[:space:]]#/)
            if (pos == 0) next
            tailv = substr(rest, pos + 1)
        }
        sub(/^[[:space:]]+/, "", tailv)
        if (tailv ~ /^#/) n++
    }
    END { print n + 0 }
    ' "$file"
}

# ------------------------------------------------------------------------------
# 将行内注释改写为「注释独占一行、置于变量上方」
# 例: KEY=80   # 警告阈值   ->   # 警告阈值
#                                 KEY=80
# ------------------------------------------------------------------------------
_ss_conf_normalize_inline() {
    local file="$1"
    local tmp="${file}.norm.$$"
    # 同样避免 awk 程序中出现字面量单引号
    awk '
    BEGIN { DQ = sprintf("%c", 34); SQ = sprintf("%c", 39) }
    {
        line = $0
        if (line ~ /^[[:space:]]*(#|$)/) { print; next }
        idx = index(line, "=")
        if (idx == 0) { print; next }
        key = substr(line, 1, idx - 1)
        gsub(/[[:space:]]+$/, "", key)
        rest = substr(line, idx + 1)
        sub(/^[[:space:]]+/, "", rest)

        value = ""; comment = ""
        q = substr(rest, 1, 1)
        if (q == DQ || q == SQ) {
            c = index(substr(rest, 2), q)
            if (c == 0) { print; next }
            value = substr(rest, 1, c + 1)
            comment = substr(rest, c + 2)
        } else {
            pos = match(rest, /[[:space:]]#/)
            if (pos == 0) { print; next }
            value = substr(rest, 1, pos - 1)
            comment = substr(rest, pos + 1)
        }
        sub(/[[:space:]]+$/, "", value)
        sub(/^[[:space:]]+/, "", comment)
        if (comment == "") { print; next }
        if (comment !~ /^#/) { comment = "# " comment }
        print comment
        print key "=" value
    }
    ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# ------------------------------------------------------------------------------
# 确定当前生效的配置文件及其来源
# 结果写入 SS_EFFECTIVE_CONF / SS_EFFECTIVE_SRC
# ------------------------------------------------------------------------------
_ss_config_effective() {
    SS_EFFECTIVE_CONF=""
    SS_EFFECTIVE_SRC="none"

    if [ -n "${CONFIG_FILE:-}" ]; then
        SS_EFFECTIVE_CONF="$CONFIG_FILE"
        SS_EFFECTIVE_SRC="env"
        return 0
    fi
    if [ -f "$UNIFIED_CONF" ]; then
        SS_EFFECTIVE_CONF="$UNIFIED_CONF"
        SS_EFFECTIVE_SRC="unified"
        return 0
    fi
    if [ -f "$LEGACY_CONF" ]; then
        SS_EFFECTIVE_CONF="$LEGACY_CONF"
        SS_EFFECTIVE_SRC="legacy"
        return 0
    fi
    SS_EFFECTIVE_CONF="$UNIFIED_CONF"
    return 0
}

_ss_config_src_label() {
    case "$1" in
    env) ss::msg MSG_CONFIG_SRC_ENV ;;
    unified) ss::msg MSG_CONFIG_SRC_UNIFIED ;;
    legacy) ss::msg MSG_CONFIG_SRC_LEGACY ;;
    *) ss::msg MSG_CONFIG_SRC_NONE ;;
    esac
}

_ss_config_help() {
    cat <<EOF
$(ss::msg MSG_HELP_USAGE): server-scan config <migrate|upgrade|check|show>

$(ss::msg MSG_CONFIG_HELP_DESC)

$(ss::msg MSG_CONFIG_HELP_ACTIONS)
EOF
}

# ------------------------------------------------------------------------------
# 读取指定键的纯值（去掉 key= 前缀、行内注释、首尾空格与引号）
# 用于判断"统一配置里当前是示例默认值，还是用户自定义值"
# ------------------------------------------------------------------------------
_ss_conf_value() {
    local file="$1" key="$2"
    local line
    line="$(_ss_conf_line "$file" "$key")"
    [ -z "$line" ] && return 0
    line="${line#*=}"
    # 仅剥离以空白分隔的行内注释，避免误伤值本身包含的 #
    line="${line%%[[:space:]]#*}"
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    line=$(printf '%s' "$line" | sed 's/^["'\'']//;s/["'\'']$//')
    printf '%s' "$line"
}

# ------------------------------------------------------------------------------
# 就地更新指定键的值，保留原行的行内注释
# ------------------------------------------------------------------------------
_ss_conf_set_value() {
    local file="$1" key="$2" val="$3"
    local comment tmp
    comment="$(_ss_conf_line "$file" "$key" | sed -n 's/^[^#]*[[:space:]]*\(#.*\)$/\1/p')"
    tmp="${file}.tmp.$$"
    awk -v k="$key" -v v="$val" -v c="$comment" '
        $0 ~ "^[[:space:]]*" k "=" {
            if (c != "") { print k "=" v "   " c } else { print k "=" v }
            next
        }
        { print }
    ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# ------------------------------------------------------------------------------
# migrate: 旧版配置 -> 统一配置
# 统一配置不存在时以旧文件为基础生成；已存在时仅补入旧文件中独有的键，
# 不覆盖现有值。旧文件改名为 .bak 保留（不删除，可恢复）
# ------------------------------------------------------------------------------
_ss_config_migrate() {
    if [ ! -f "$LEGACY_CONF" ]; then
        echo "> $(ss::msg MSG_CONFIG_MIGRATE_NONE)"
        return 0
    fi

    local merged=0
    local conflicted=""
    if [ ! -f "$UNIFIED_CONF" ]; then
        {
            echo "# server-scan 统一配置文件"
            echo "# 由 server-scan config migrate 从 disk_analyzer.conf 自动迁移生成"
            echo "# 可配置项与说明见 server-scan.conf.example"
            echo ""
            cat "$LEGACY_CONF"
        } >"$UNIFIED_CONF" || return 1
        merged=$(_ss_conf_keys "$LEGACY_CONF" | grep -c .)
    else
        # 统一配置已存在时必须比对「值」而非仅比对「键」:
        # 若统一配置中仍是示例默认值（多由 config upgrade 自动补齐），
        # 必须用旧配置的真实值覆盖，否则就是「只迁了 key 没迁值」
        local k line legacy_val unified_val example_val
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            legacy_val="$(_ss_conf_value "$LEGACY_CONF" "$k")"
            # 空值不迁移，避免把已有配置清空
            [ -z "$legacy_val" ] && continue

            if [ -z "$(_ss_conf_line "$UNIFIED_CONF" "$k")" ]; then
                line="$(_ss_conf_line "$LEGACY_CONF" "$k")"
                [ -z "$line" ] && continue
                printf '%s\n' "$line" >>"$UNIFIED_CONF"
                merged=$((merged + 1))
                continue
            fi

            unified_val="$(_ss_conf_value "$UNIFIED_CONF" "$k")"
            example_val="$(_ss_conf_value "$CONFIG_EXAMPLE" "$k")"
            if [ "$unified_val" = "$example_val" ]; then
                # 仍是示例默认值 -> 覆盖为旧配置的真实值
                _ss_conf_set_value "$UNIFIED_CONF" "$k" "$legacy_val"
                merged=$((merged + 1))
            else
                # 用户已在统一配置中自定义过 -> 保留其新值，单独列出
                conflicted="${conflicted}${k} "
            fi
        done < <(_ss_conf_keys "$LEGACY_CONF")
    fi

    local backup="${LEGACY_CONF}.bak"
    mv "$LEGACY_CONF" "$backup" || return 1

    echo "> $(ss::msgf MSG_CONFIG_MIGRATE_DONE "$LEGACY_CONF" "$UNIFIED_CONF")"
    echo "> $(ss::msgf MSG_CONFIG_MIGRATE_BACKUP "$backup")"
    if [ "$merged" -gt 0 ]; then
        echo "> $(ss::msgf MSG_CONFIG_MIGRATE_ADDED "$merged")"
    fi
    if [ -n "$conflicted" ]; then
        echo "> $(ss::msgf MSG_CONFIG_MIGRATE_CONFLICT \
            "$(printf '%s' "$conflicted" | sed 's/[[:space:]]*$//')")"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# upgrade: 用示例配置补齐新增项
# 保留已有配置项与注释；新增项以独立区块追加（避免破坏用户原有分组）
# ------------------------------------------------------------------------------
_ss_config_upgrade() {
    if [ ! -f "$CONFIG_EXAMPLE" ]; then
        ss::log_error "$(ss::msgf MSG_CONFIG_ERR_NO_EXAMPLE "$CONFIG_EXAMPLE")"
        return 1
    fi

    _ss_config_effective
    local target="$SS_EFFECTIVE_CONF"

    # 尚无配置文件：直接以示例为模板生成，保留完整注释与分组
    if [ ! -f "$target" ]; then
        cp "$CONFIG_EXAMPLE" "$target" || return 1
        echo "> $(ss::msgf MSG_CONFIG_EFFECTIVE "$target")"
        echo "> $(ss::msgf MSG_CONFIG_UPGRADE_DONE "$(_ss_conf_keys "$CONFIG_EXAMPLE" | grep -c .)")"
        return 0
    fi

    # 1) 先把行内注释整理为独占一行（约定: 注释不与变量同行），
    #    否则值中含 # 时存在被误判为注释的歧义
    local normalized=0 before after
    before=$(_ss_conf_inline_comment_count "$target")
    if [ "${before:-0}" -gt 0 ]; then
        _ss_conf_normalize_inline "$target"
        after=$(_ss_conf_inline_comment_count "$target")
        normalized=$((before - after))
        echo "> $(ss::msgf MSG_CONFIG_NORMALIZED "$normalized")"
    fi

    # 2) 差集: 示例中有、当前配置中没有的键
    local missing
    missing=$(comm -13 \
        <(_ss_conf_keys "$target" | sort -u) \
        <(_ss_conf_keys "$CONFIG_EXAMPLE" | sort -u))

    if [ -z "$missing" ]; then
        if [ "$normalized" -eq 0 ]; then
            echo "> $(ss::msg MSG_CONFIG_UPGRADE_NONE)"
        fi
        return 0
    fi

    local backup="${target}.bak"
    cp "$target" "$backup" || return 1

    local n=0 k block
    {
        echo ""
        echo "# ------------------------------------------------------------------------------"
        echo "# 以下配置项由 server-scan config upgrade 于 $(date '+%Y-%m-%d %H:%M:%S') 自动补齐"
        echo "# 取自 server-scan.conf.example 的默认值，可按实际环境修改"
        echo "# ------------------------------------------------------------------------------"
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            # 连同示例中的说明注释一起写入（注释独占一行、位于变量上方）
            block="$(_ss_conf_block "$CONFIG_EXAMPLE" "$k")"
            [ -z "$block" ] && block="$(_ss_conf_line "$CONFIG_EXAMPLE" "$k")"
            [ -z "$block" ] && continue
            printf '%s\n' "$block"
            n=$((n + 1))
        done <<<"$missing"
    } >>"$target"

    echo "> $(ss::msgf MSG_CONFIG_UPGRADE_DONE "$n")"
    echo "> $(ss::msgf MSG_CONFIG_UPGRADE_BACKUP "$backup")"
    return 0
}

# ------------------------------------------------------------------------------
# check: 检查配置状态
# 退出码 0 表示无需处理；1 表示存在待处理项（旧版配置/未知项/缺失新增项）
# ------------------------------------------------------------------------------
_ss_config_check() {
    _ss_config_effective
    echo "> $(ss::msgf MSG_CONFIG_EFFECTIVE "$SS_EFFECTIVE_CONF")"
    echo "> $(ss::msgf MSG_CONFIG_SOURCE "$(_ss_config_src_label "$SS_EFFECTIVE_SRC")")"

    if [ ! -f "$SS_EFFECTIVE_CONF" ]; then
        echo "> $(ss::msg MSG_CONFIG_SRC_NONE)"
        return 0
    fi

    if [ ! -f "$CONFIG_EXAMPLE" ]; then
        ss::log_error "$(ss::msgf MSG_CONFIG_ERR_NO_EXAMPLE "$CONFIG_EXAMPLE")"
        return 1
    fi

    local ret=0
    local unknown missing n

    # 只在当前配置中的键：可能是拼写错误或已被废弃
    unknown=$(comm -13 \
        <(_ss_conf_keys "$CONFIG_EXAMPLE" | sort -u) \
        <(_ss_conf_keys "$SS_EFFECTIVE_CONF" | sort -u))
    # 只在示例中的键：尚未写入的新增项（使用内置默认值，补齐后可显式调整）
    missing=$(comm -23 \
        <(_ss_conf_keys "$CONFIG_EXAMPLE" | sort -u) \
        <(_ss_conf_keys "$SS_EFFECTIVE_CONF" | sort -u))

    if [ -n "$unknown" ]; then
        echo "> ⚠️ $(ss::msgf MSG_CONFIG_UNKNOWN "$(printf '%s' "$unknown" | tr '\n' ' ' | sed 's/[[:space:]]*$//')")"
        ret=1
    fi
    if [ -n "$missing" ]; then
        n=$(printf '%s\n' "$missing" | grep -c .)
        echo "> $(ss::msgf MSG_CONFIG_MISSING "$n")"
        ret=1
    fi
    # 注释与变量同行会导致「值含 # 被误判」的歧义，约定上应整理为独占一行
    n=$(_ss_conf_inline_comment_count "$SS_EFFECTIVE_CONF")
    if [ "${n:-0}" -gt 0 ]; then
        echo "> ⚠️ $(ss::msgf MSG_CONFIG_INLINE_COMMENT "$n")"
        ret=1
    fi
    if [ "$ret" -eq 0 ]; then
        echo "> ✅ $(ss::msg MSG_CONFIG_CLEAN)"
    fi
    return $ret
}

# ------------------------------------------------------------------------------
# show: 显示当前生效配置
# ------------------------------------------------------------------------------
_ss_config_show() {
    _ss_config_effective
    echo "> $(ss::msgf MSG_CONFIG_EFFECTIVE "$SS_EFFECTIVE_CONF")"
    echo "> $(ss::msgf MSG_CONFIG_SOURCE "$(_ss_config_src_label "$SS_EFFECTIVE_SRC")")"
    echo ""
    if [ -f "$SS_EFFECTIVE_CONF" ]; then
        cat "$SS_EFFECTIVE_CONF"
    else
        echo "$(ss::msg MSG_CONFIG_SRC_NONE)"
    fi
    return 0
}

# ==============================================================================
# 主入口
# ==============================================================================
ACTION="${1:-}"
case "$ACTION" in
migrate)
    _ss_config_migrate
    ;;
upgrade)
    _ss_config_upgrade
    ;;
check)
    _ss_config_check
    ;;
show)
    _ss_config_show
    ;;
-h | --help)
    _ss_config_help
    exit 0
    ;;
"")
    ss::log_error "$(ss::msg MSG_CONFIG_ERR_ACTION_ARG)"
    echo ""
    _ss_config_help
    exit 2
    ;;
*)
    ss::log_error "$(ss::msgf MSG_CONFIG_ERR_UNKNOWN_ACTION "$ACTION")"
    _ss_config_help
    exit 2
    ;;
esac

exit $?
