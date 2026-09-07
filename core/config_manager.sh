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
        local k line
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            # 仅补入统一配置中缺失的键，已有值保持不变
            if [ -z "$(_ss_conf_line "$UNIFIED_CONF" "$k")" ]; then
                line="$(_ss_conf_line "$LEGACY_CONF" "$k")"
                [ -z "$line" ] && continue
                printf '%s\n' "$line" >>"$UNIFIED_CONF"
                merged=$((merged + 1))
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

    # 差集: 示例中有、当前配置中没有的键
    local missing
    missing=$(comm -13 \
        <(_ss_conf_keys "$target" | sort -u) \
        <(_ss_conf_keys "$CONFIG_EXAMPLE" | sort -u))

    if [ -z "$missing" ]; then
        echo "> $(ss::msg MSG_CONFIG_UPGRADE_NONE)"
        return 0
    fi

    local backup="${target}.bak"
    cp "$target" "$backup" || return 1

    local n=0 k line
    {
        echo ""
        echo "# ------------------------------------------------------------------------------"
        echo "# 以下配置项由 server-scan config upgrade 于 $(date '+%Y-%m-%d %H:%M:%S') 自动补齐"
        echo "# 取自 server-scan.conf.example 的默认值，可按实际环境修改"
        echo "# ------------------------------------------------------------------------------"
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            line="$(_ss_conf_line "$CONFIG_EXAMPLE" "$k")"
            [ -z "$line" ] && continue
            printf '%s\n' "$line"
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
