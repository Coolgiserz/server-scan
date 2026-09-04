#!/bin/bash
# shellcheck disable=SC2034
# ==============================================================================
# lib/alerts.sh - 结构化告警收集与 JSON 输出
# ==============================================================================
# 设计原则: 告警以结构化数组作为唯一事实来源，
#   既可渲染进 Markdown 报告供人阅读，也输出机器可读的 JSON 供 notify 直接消费，
#   从而避免从 Markdown 文本里反向解析告警（格式耦合、易丢失结构与严重等级）。
#
# 用法:
#   ss::alert_add <level> <dimension> <metric> <object> <value> <threshold> <detail> [suggestion]
#   ss::alerts_write_json <json_path> <script_name> <report_path>
#   ss::alerts_count [level]
#
# level 取值: critical(严重) | warning(警告) | info(提示)
#
# JSON 结构说明:
#   每个 alert 对象压缩为单行，便于 notify 用 grep/sed 逐行解析，
#   不引入 jq 依赖；整体仍是合法 JSON，可被任意 JSON 解析器消费。
# ==============================================================================

# 告警集合（元素为单行 JSON 对象）
SS_ALERTS=()

# ------------------------------------------------------------------------------
# 添加一条告警
# ------------------------------------------------------------------------------
ss::alert_add() {
    local level="$1"
    local dimension="$2"
    local metric="$3"
    local object="$4"
    local value="$5"
    local threshold="$6"
    local detail="$7"
    local suggestion="${8:-}"

    SS_ALERTS+=("$(_ss_alert_line "$level" "$dimension" "$metric" \
        "$object" "$value" "$threshold" "$detail" "$suggestion")")
}

# ------------------------------------------------------------------------------
# 构造单行 JSON 对象
# ------------------------------------------------------------------------------
_ss_alert_line() {
    printf '{"level":"%s","dimension":"%s","metric":"%s","object":"%s","value":"%s","threshold":"%s","detail":"%s","suggestion":"%s"}' \
        "$(ss::json_escape "$1")" \
        "$(ss::json_escape "$2")" \
        "$(ss::json_escape "$3")" \
        "$(ss::json_escape "$4")" \
        "$(ss::json_escape "$5")" \
        "$(ss::json_escape "$6")" \
        "$(ss::json_escape "$7")" \
        "$(ss::json_escape "$8")"
}

# ------------------------------------------------------------------------------
# 统计告警数量（不传 level 则返回总数）
# ------------------------------------------------------------------------------
ss::alerts_count() {
    local level="${1:-}"
    local n=0
    local item
    for item in "${SS_ALERTS[@]}"; do
        [ -z "$item" ] && continue
        if [ -z "$level" ]; then
            n=$((n + 1))
        elif printf '%s' "$item" | grep -q "\"level\":\"${level}\""; then
            n=$((n + 1))
        fi
    done
    printf '%s' "$n"
}

# ------------------------------------------------------------------------------
# 输出告警 JSON
# 用法: ss::alerts_write_json <json_path> <script_name> <report_path>
# ------------------------------------------------------------------------------
ss::alerts_write_json() {
    local json_path="$1"
    local script_name="$2"
    local report_path="$3"

    ss::ensure_output_dir "$json_path" || return 1

    local total critical warning info
    total=$(ss::alerts_count)
    critical=$(ss::alerts_count critical)
    warning=$(ss::alerts_count warning)
    info=$(ss::alerts_count info)

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    {
        printf '{\n'
        printf '  "schema_version": "1.0",\n'
        printf '  "script": "%s",\n' "$(ss::json_escape "$script_name")"
        printf '  "hostname": "%s",\n' "$(ss::json_escape "$(hostname)")"
        printf '  "timestamp": "%s",\n' "$ts"
        printf '  "report_path": "%s",\n' "$(ss::json_escape "$report_path")"
        printf '  "summary": {"total": %s, "critical": %s, "warning": %s, "info": %s},\n' \
            "$total" "$critical" "$warning" "$info"
        printf '  "alerts": [\n'
        local i=0
        local item
        for item in "${SS_ALERTS[@]}"; do
            [ -z "$item" ] && continue
            printf '    %s' "$item"
            i=$((i + 1))
            if [ "$i" -lt "$total" ]; then
                printf ','
            fi
            printf '\n'
        done
        printf '  ]\n'
        printf '}\n'
    } >"$json_path"
}

# ------------------------------------------------------------------------------
# 从告警 JSON 中逐行读取 alert 对象（供 notify 消费，零依赖）
# 输出: 每行一个 alert 的单行 JSON 对象
# ------------------------------------------------------------------------------
ss::alerts_read_json() {
    local json_path="$1"
    [ -f "$json_path" ] || return 1
    grep -oE '\{"level":"[^}]*\}' "$json_path" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 从单行 alert JSON 中提取指定字段的值
# 用法: ss::alert_field <json_line> <字段名>
# ------------------------------------------------------------------------------
ss::alert_field() {
    local line="$1"
    local field="$2"
    printf '%s' "$line" | sed -n "s/.*\"${field}\":\"\([^\"]*\)\".*/\1/p"
}
