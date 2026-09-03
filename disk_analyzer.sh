#!/bin/bash
# ==============================================================================
# 脚本名称: disk_analyzer.sh
# 功能说明: 磁盘专项深度分析，采集空间、I/O、inode、大文件、Docker 空间占用、健康状态
#             默认跳过实时 I/O 负载快照，输出标准 Markdown 报告文件
#             支持指定目录扫描模式：只扫描指定目录，跳过全盘扫描
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL)
# 依赖工具: sysstat(iostat), smartmontools(smartctl), bc, lsblk, find, du
# 安装依赖:
#   CentOS: yum install -y sysstat smartmontools bc
#   Ubuntu: apt install -y sysstat smartmontools bc
# 使用方法:
#   全盘扫描: chmod +x disk_analyzer.sh && ./disk_analyzer.sh
#   指定目录: ./disk_analyzer.sh -d /path/to/dir [-d /path/to/dir2] [--depth 3] [--top 20]
# 输出文件: 默认生成 /tmp/disk_report.md（可修改 REPORT_PATH 变量）
# ==============================================================================

# --- 配置区 ---
# 报告输出路径，可自定义为 /var/log/disk_report.md 等
# 文件名自动附带时间戳，避免多次执行覆盖历史报告
REPORT_PATH="/tmp/disk_report_$(date '+%Y%m%d_%H%M%S').md"

# 大文件扫描超时（秒），防止从根目录扫描耗时过长
LARGE_FILE_SCAN_TIMEOUT=30

# 指定目录扫描模式配置
SCAN_DIRS=()          # 指定扫描的目录列表
SCAN_DEPTH=3          # 默认扫描深度
SCAN_TOP=20           # 默认 Top N 数量
DIR_SCAN_MODE="false" # 是否为指定目录扫描模式

# Docker 数据目录配置（可通过配置文件覆盖）
DOCKER_DATA_DIR="" # 自定义 Docker 数据目录

# ==============================================================================
# 可配置阈值（可通过配置文件覆盖）
# ==============================================================================

# 磁盘使用率阈值
DISK_USAGE_WARNING_THRESHOLD=80  # 磁盘使用率警告阈值（%）
DISK_USAGE_CRITICAL_THRESHOLD=90 # 磁盘使用率危险阈值（%）

# inode 使用率阈值
INODE_USAGE_WARNING_THRESHOLD=70  # inode 使用率警告阈值（%）
INODE_USAGE_CRITICAL_THRESHOLD=90 # inode 使用率危险阈值（%）

# I/O 性能阈值
IO_AWAIT_EXCELLENT_THRESHOLD=10 # I/O await 优秀阈值（ms）
IO_AWAIT_GOOD_THRESHOLD=20      # I/O await 正常阈值（ms）
IO_AWAIT_SLOW_THRESHOLD=50      # I/O await 缓慢阈值（ms）
IO_UTIL_HEALTHY_THRESHOLD=60    # I/O %util 健康阈值（%）
IO_UTIL_BUSY_THRESHOLD=80       # I/O %util 繁忙阈值（%）

# 大文件扫描配置
LARGE_FILE_SCAN_DEPTH=6        # 大文件扫描深度
LARGE_FILE_SIZE_THRESHOLD="1G" # 大文件大小阈值
LARGE_FILE_SCAN_TIMEOUT=30     # 大文件扫描超时时间（秒）

# 日志文件扫描配置
LOG_SCAN_DIR="/var/log"        # 日志扫描目录
LOG_FILE_SIZE_THRESHOLD="100M" # 日志文件大小阈值

# Docker 扫描配置
DOCKER_IMAGE_TOP=15              # Docker 镜像 Top N
DOCKER_CONTAINER_TOP=10          # Docker 容器 Top N
DOCKER_VOLUME_TOP=15             # Docker 卷 Top N
DOCKER_LOG_SIZE_THRESHOLD="100M" # Docker 日志文件大小阈值

# 挂载点扫描配置
MOUNT_SCAN_DEPTH=1    # 挂载点扫描深度
MOUNT_SCAN_TOP=10     # 挂载点扫描 Top N
MOUNT_SCAN_TIMEOUT=20 # 挂载点扫描超时时间（秒）

# 实时 I/O 配置
ENABLE_REALTIME_IO="false" # 是否启用实时 I/O 负载快照
REALTIME_IO_INTERVAL=2     # 实时 I/O 采样间隔（秒）

# 其他扫描配置
LARGE_FILE_TOP=20             # 大文件 Top N
DOCKER_BUILD_CACHE_TOP=15     # Docker 构建缓存 Top N
DOCKER_CONTAINER_LOG_TOP=10   # 运行中容器日志大小 Top N
MACOS_IO_TPS_THRESHOLD=1000   # macOS I/O tps 阈值
MACOS_IO_MBS_THRESHOLD=100    # macOS I/O MB/s 阈值
REPORT_DISK_USAGE_WARNING=85  # 报告建议中的磁盘使用率警告阈值（%）
REPORT_INODE_USAGE_WARNING=80 # 报告建议中的 inode 使用率警告阈值（%）
REPORT_IO_AWAIT_WARNING=20    # 报告建议中的 I/O await 警告阈值（ms）
REPORT_IO_UTIL_WARNING=100    # 报告建议中的 I/O %util 警告阈值（%）

# ==============================================================================
# 配置文件加载
# ==============================================================================
# 默认配置文件路径（当前目录下的 disk_analyzer.conf）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/disk_analyzer.conf}"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/cli.sh"

# 加载配置文件
ss::load_config "$CONFIG_FILE" DISK_ INODE_ IO_ LARGE_FILE_ LOG_ DOCKER_ MOUNT_ SCAN_ ENABLE_ REALTIME_ MACOS_ REPORT_ NOTIFY_

# 解析公共参数（必须在主shell中直接调用，不能用命令替换）
ss::parse_common_args "$@"

# 脚本特定参数解析（解析 SCRIPT_ARGS 中剩余的参数）
set -- "${SCRIPT_ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
    -d | --dir)
        if [[ -n "$2" && "$2" != -* ]]; then
            # 支持空格分隔的多个目录
            read -ra _dirs <<< "$2"
            for dir in "${_dirs[@]}"; do
                SCAN_DIRS+=("$dir")
            done
            DIR_SCAN_MODE="true"
            shift 2
        else
            ss::log_error "$(ss::msg MSG_DISK_ERR_DIR_ARG)"
            exit 2
        fi
        ;;
    --depth)
        if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
            SCAN_DEPTH="$2"
            shift 2
        else
            ss::log_error "$(ss::msg MSG_DISK_ERR_DEPTH_ARG)"
            exit 2
        fi
        ;;
    --top)
        if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
            SCAN_TOP="$2"
            shift 2
        else
            ss::log_error "$(ss::msg MSG_DISK_ERR_TOP_ARG)"
            exit 2
        fi
        ;;
    -h | --help)
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_DISK_HELP_DESC)" "  -d, --dir DIR       $(ss::msg MSG_DISK_HELP_DIR)
  --depth N           $(ss::msg MSG_DISK_HELP_DEPTH)
  --top N             $(ss::msg MSG_DISK_HELP_TOP)"
        exit 0
        ;;
    *)
        ss::log_error "$(ss::msgf MSG_ERROR_UNKNOWN_ARG "$1")"
        ss::print_usage "$(basename "$0")" "$(ss::msg MSG_DISK_HELP_DESC)" "  -d, --dir DIR       $(ss::msg MSG_DISK_HELP_DIR)
  --depth N           $(ss::msg MSG_DISK_HELP_DEPTH)
  --top N             $(ss::msg MSG_DISK_HELP_TOP)"
        exit 2
        ;;
    esac
done

# 验证指定目录模式下的目录有效性
if [ "$DIR_SCAN_MODE" = "true" ]; then
    # 检查目录是否存在
    valid_dirs=()
    for dir in "${SCAN_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            valid_dirs+=("$dir")
        else
            ss::log_warn "$(ss::msgf MSG_DISK_WARN_DIR_SKIP "$dir")"
        fi
    done

    if [ ${#valid_dirs[@]} -eq 0 ]; then
        ss::die "$(ss::msg MSG_ERROR_NO_VALID_DIR)" 2
    fi

    SCAN_DIRS=("${valid_dirs[@]}")

    # 更新报告文件名，包含目录标识
    dir_tag=$(echo "${SCAN_DIRS[0]}" | sed 's|^/||; s|/|_|g' | cut -c1-20)
    REPORT_PATH="/tmp/disk_report_${dir_tag}_$(date '+%Y%m%d_%H%M%S').md"
fi

# ==============================================================================
# 按系统选择命令 / 工具探测
# ==============================================================================
if [ "$OS_TYPE" = "Darwin" ]; then
    : # macOS 专有命令在各章节内通过 command -v / OS_TYPE 判定选用
elif [ "$OS_TYPE" = "Linux" ]; then
    : # Linux 专有命令在各章节内通过 command -v / OS_TYPE 判定选用
fi

# 报告开始（打开 fd3，重定向 stdout 到临时文件）
if [ "$DIR_SCAN_MODE" = "true" ]; then
    ss::report_begin "$(ss::msg MSG_DISK_REPORT_TITLE) - $(ss::msg MSG_DISK_SCAN_MODE_DIR)" "${#SCAN_DIRS[@]}"
else
    ss::report_begin "$(ss::msg MSG_DISK_REPORT_TITLE)" 10
fi

# ==============================================================================
# Markdown 报告头
# ==============================================================================
if [ "$DIR_SCAN_MODE" = "true" ]; then
    echo "# $(ss::msg MSG_DISK_TITLE_DIR)"
else
    echo "# $(ss::msg MSG_DISK_TITLE)"
fi
echo ""
if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
else
    OS_NAME="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
fi
echo "> **$(ss::msg MSG_COMMON_HOSTNAME):** $(hostname)  "
echo "> **$(ss::msg MSG_COMMON_COLLECT_TIME):** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **$(ss::msg MSG_COMMON_REPORT_FILE):** \`$REPORT_PATH\`  "
echo "> **$(ss::msg MSG_COMMON_OS):** ${OS_NAME}  "
echo "> **$(ss::msg MSG_COMMON_KERNEL):** $(uname -r)  "
if [ "$DIR_SCAN_MODE" = "true" ]; then
    echo "> **$(ss::msg MSG_DISK_ROW_SCAN_MODE):** $(ss::msg MSG_DISK_SCAN_MODE_DIR)  "
    echo "> **$(ss::msg MSG_DISK_ROW_TARGET_DIRS):** ${SCAN_DIRS[*]}  "
    echo "> **$(ss::msg MSG_DISK_ROW_SCAN_DEPTH):** $SCAN_DEPTH  "
    echo "> **$(ss::msg MSG_DISK_ROW_TOP_N):** $SCAN_TOP  "
else
    echo "> **$(ss::msg MSG_DISK_ROW_SCAN_MODE):** $(ss::msg MSG_DISK_SCAN_MODE_FULL)  "
fi
echo ""
echo "---"
echo ""

# ==============================================================================
# 指定目录扫描模式
# ==============================================================================
if [ "$DIR_SCAN_MODE" = "true" ]; then
    # ==============================================================================
    # 目录扫描函数
    # ==============================================================================
    scan_directory() {
        local target_dir="$1"
        local dir_index="$2"
        local total_dirs="$3"

        ss::progress "$dir_index" "$total_dirs" "$(ss::msg MSG_DISK_DIR_SCANNING): $target_dir"

        echo "## 目录: \`$target_dir\`"
        echo ""

        # 检查目录权限
        if [ ! -r "$target_dir" ]; then
            echo "> ⚠️ **$(ss::msg MSG_DISK_DIR_PERM_DENIED)**"
            echo ""
            return 1
        fi

        # 1. 目录总大小
        echo "### 1. $(ss::msg MSG_DISK_SUBSEC_TOTAL_SIZE)"
        echo ""
        local total_size_kb
        total_size_kb=$(du -sk "$target_dir" 2>/dev/null | awk '{print $1}')
        if [ -n "$total_size_kb" ]; then
            echo "> **$(ss::msg MSG_DISK_TOTAL_SIZE):** $(ss::hr_kb "$total_size_kb")"
        else
            echo "> ⚠️ $(ss::msg MSG_DISK_CANNOT_CALC_SIZE)"
        fi
        echo ""

        # 2. 子目录 Top N（按大小排序）
        echo "### 2. $(ss::msgf MSG_DISK_SUBSEC_SUBDIRS "$SCAN_TOP")"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_RANK) | $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_SUBDIR) |"
        echo "|------|------|--------|"

        local depth_arg
        if [ "$OS_TYPE" = "Darwin" ]; then
            depth_arg="-d $SCAN_DEPTH"
        else
            depth_arg="--max-depth=$SCAN_DEPTH"
        fi

        # 使用临时文件存储排序结果
        local tmp_subdirs
        tmp_subdirs=$(mktemp)

        # 扫描子目录并排序
        du -k $depth_arg "$target_dir" 2>/dev/null |
            grep -v "^$total_size_kb" |
            sort -rn |
            head -n "$SCAN_TOP" >"$tmp_subdirs"

        if [ -s "$tmp_subdirs" ]; then
            local rank=1
            while read -r size_kb path; do
                # 跳过目标目录本身
                if [ "$path" != "$target_dir" ]; then
                    echo "| $rank | $(ss::hr_kb "$size_kb") | \`$path\` |"
                    rank=$((rank + 1))
                fi
            done <"$tmp_subdirs"
        else
            echo "> ℹ️ $(ss::msg MSG_DISK_NO_SUBDIRS)"
        fi
        rm -f "$tmp_subdirs"
        echo ""

        # 3. 大文件 Top N
        echo "### 3. $(ss::msgf MSG_DISK_SUBSEC_LARGE_FILES "$SCAN_TOP")"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_RANK) | $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_FILE_PATH) |"
        echo "|------|------|----------|"

        local tmp_files
        tmp_files=$(mktemp)

        # 扫描大文件
        find "$target_dir" -type f -exec du -k {} + 2>/dev/null |
            sort -rn |
            head -n "$SCAN_TOP" >"$tmp_files"

        if [ -s "$tmp_files" ]; then
            local rank=1
            while read -r size_kb filepath; do
                echo "| $rank | $(ss::hr_kb "$size_kb") | \`$filepath\` |"
                rank=$((rank + 1))
            done <"$tmp_files"
        else
            echo "> ℹ️ $(ss::msg MSG_DISK_NO_FILES)"
        fi
        rm -f "$tmp_files"
        echo ""

        # 4. 文件类型分布统计
        echo "### 4. $(ss::msg MSG_DISK_SUBSEC_FILE_TYPES)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_EXTENSION) | $(ss::msg MSG_DISK_COL_FILE_COUNT) | $(ss::msg MSG_DISK_COL_TOTAL_SIZE) | $(ss::msg MSG_TABLE_RATIO) |"
        echo "|--------|----------|--------|------|"

        local tmp_types
        tmp_types=$(mktemp)

        # 统计文件类型
        find "$target_dir" -type f 2>/dev/null | while read -r file; do
            local ext="${file##*.}"
            # 如果没有扩展名，标记为 [无扩展名]
            if [ "$ext" = "$file" ]; then
                ext="[$(ss::msg MSG_DISK_NO_EXT)]"
            fi
            local size_kb
            size_kb=$(du -k "$file" 2>/dev/null | awk '{print $1}')
            if [ -n "$size_kb" ]; then
                echo "$ext $size_kb"
            fi
        done | awk '
            {
                ext[$1] += $2
                count[$1]++
                total += $2
            }
            END {
                for (e in ext) {
                    pct = (total > 0) ? (ext[e] / total * 100) : 0
                    printf "%s %d %d %.1f%%\n", e, count[e], ext[e], pct
                }
            }
        ' | sort -k3 -rn | head -n "$SCAN_TOP" >"$tmp_types"

        if [ -s "$tmp_types" ]; then
            while read -r ext count size_kb pct; do
                echo "| \`$ext\` | $count | $(ss::hr_kb "$size_kb") | $pct |"
            done <"$tmp_types"
        else
            echo "> ℹ️ $(ss::msg MSG_DISK_NO_FILES)"
        fi
        rm -f "$tmp_types"
        echo ""

        # 5. 深度分析（可选，显示各层级目录大小）
        echo "### 5. $(ss::msg MSG_DISK_SUBSEC_HIERARCHY)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_LEVEL) | $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_DIRECTORY) |"
        echo "|------|------|------|"

        local tmp_levels
        tmp_levels=$(mktemp)

        # 按层级统计
        du -k $depth_arg "$target_dir" 2>/dev/null | awk -v target="$target_dir" '
            {
                # 计算相对深度
                gsub(target, "", $2)
                depth = gsub(/\//, "/", $2)
                if (depth > 0) {
                    printf "%d %s %s\n", depth, $1, $2
                }
            }
        ' | sort -k1n -k2rn | head -n "$SCAN_TOP" >"$tmp_levels"

        if [ -s "$tmp_levels" ]; then
            while read -r depth size_kb path; do
                echo "| $depth | $(ss::hr_kb "$size_kb") | \`$path\` |"
            done <"$tmp_levels"
        else
            echo "> ℹ️ $(ss::msg MSG_DISK_NO_SUBDIRS)"
        fi
        rm -f "$tmp_levels"
        echo ""

        echo "---"
        echo ""
    }

    # ==============================================================================
    # 执行指定目录扫描
    # ==============================================================================
    total_dirs=${#SCAN_DIRS[@]}
    dir_index=1

    for target_dir in "${SCAN_DIRS[@]}"; do
        scan_directory "$target_dir" "$dir_index" "$total_dirs"
        dir_index=$((dir_index + 1))
    done

    # 跳转到报告尾部
    SKIP_TO_FOOTER="true"
fi

# ==============================================================================
# 全盘扫描模式（当未指定目录时执行）
# ==============================================================================
if [ "$SKIP_TO_FOOTER" != "true" ]; then

    # ==============================================================================
    # 1. 磁盘基础信息
    # ==============================================================================
    ss::progress 1 10 "$(ss::msg MSG_DISK_SECTION_BASIC)"
    echo "## 1. $(ss::msg MSG_DISK_SECTION_BASIC)"
    echo ""

    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS 使用 diskutil list 获取磁盘概览
        echo "### $(ss::msg MSG_DISK_BLOCK_DEVICE_LIST) (diskutil)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_DEVICE) | $(ss::msg MSG_DISK_COL_TYPE) | $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_DESC) |"
        echo "|------|------|------|------|"
        if command -v diskutil >/dev/null 2>&1; then
            diskutil list 2>/dev/null | awk '
            /^\// {
                gsub(/:$/, "", $1)
                dev = $1
                # 判断设备类型
                line = $0
                if (line ~ /physical/) type = "物理磁盘"
                else if (line ~ /synthesized/) type = "合成容器"
                else if (line ~ /disk image/) type = "磁盘镜像"
                else type = "块设备"
                # 提取说明
                note = ""
                if (match(line, /\([^)]+\)/)) {
                    note = substr(line, RSTART+1, RLENGTH-2)
                }
                printf "| %s | %s | - | %s |\n", dev, type, note
            }
            /^[[:space:]]+[0-9]+:/ {
                # 卷信息行：缩进编号 TYPE NAME SIZE IDENTIFIER
                sub(/^[[:space:]]*[0-9]+:[[:space:]]*/, "")
                printf "|  └─ %s | 子卷 | - | %s |\n", $NF, $0
            }
        '
        else
            echo "> ⚠️ $(ss::msg MSG_DISK_MACOS_NO_BLOCK_DEV)"
        fi
        echo ""
        echo "> ℹ️ $(ss::msg MSG_DISK_MACOS_NO_SCHEDULER)"
        echo ""
    else
        # Linux: lsblk 列出所有块设备，-d 不显示从属关系，-o 指定输出列
        # 关键信息: 设备名、大小、类型(disk/part/lvm)、挂载点、模型
        echo "### $(ss::msg MSG_DISK_BLOCK_DEVICE_LIST)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_DEVICE) | $(ss::msg MSG_DISK_COL_CAPACITY) | $(ss::msg MSG_DISK_COL_TYPE) | $(ss::msg MSG_DISK_COL_ROTATIONAL) | $(ss::msg MSG_DISK_COL_MODEL) | $(ss::msg MSG_DISK_COL_MOUNTPOINT) |"
        echo "|--------|------|------|----------|------|--------|"
        lsblk -d -o NAME,SIZE,TYPE,ROTA,MODEL,MOUNTPOINT 2>/dev/null | tail -n +2 | while read -r name size type rota model mount; do
            # 判断旋转介质: ROTA=1 为机械硬盘(HDD)，ROTA=0 为固态硬盘(SSD/NVMe)
            if [ "$rota" = "1" ]; then
                media="HDD"
            else
                media="SSD/NVMe"
            fi
            printf "| %s | %s | %s | %s | %s | %s |\n" "$name" "$size" "$type" "$media" "$model" "$mount"
        done
        echo ""

        # 显示当前 I/O 调度器，影响磁盘性能表现
        echo "### $(ss::msg MSG_DISK_IO_SCHEDULER)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_DEVICE) | $(ss::msg MSG_DISK_COL_CURRENT_SCHEDULER) |"
        echo "|------|-------------|"
        for disk in $(lsblk -d -o NAME 2>/dev/null | grep -v NAME); do
            if [ -f /sys/block/$disk/queue/scheduler ]; then
                # 提取方括号中的当前调度器名称（避免 grep -P 依赖）
                scheduler=$(cat /sys/block/$disk/queue/scheduler | grep -o '\[[^]]*\]' | tr -d '[]')
                echo "| /dev/$disk | $scheduler |"
            fi
        done
        echo ""
    fi

    # ==============================================================================
    # 2. 磁盘空间使用情况
    # ==============================================================================
    ss::progress 2 10 "$(ss::msg MSG_DISK_SECTION_USAGE)"
    echo "## 2. $(ss::msg MSG_DISK_SECTION_USAGE)"
    echo ""
    echo "> **$(ss::msg MSG_DISK_EVAL_CRITERIA):** $(ss::msgf MSG_DISK_EVAL_DISK_USAGE "$DISK_USAGE_WARNING_THRESHOLD" "$DISK_USAGE_CRITICAL_THRESHOLD")"
    echo ""
    # 告警阈值: >${DISK_USAGE_WARNING_THRESHOLD}% 警告，>${DISK_USAGE_CRITICAL_THRESHOLD}% 危险
    echo "| $(ss::msg MSG_DISK_COL_FS) | $(ss::msg MSG_DISK_COL_TYPE) | $(ss::msg MSG_DISK_COL_TOTAL) | $(ss::msg MSG_DISK_COL_USED) | $(ss::msg MSG_DISK_COL_AVAILABLE) | $(ss::msg MSG_DISK_COL_USAGE) | $(ss::msg MSG_DISK_COL_MOUNTPOINT) | $(ss::msg MSG_TABLE_STATUS) |"
    echo "|----------|------|------|------|------|--------|--------|------|"
    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS df -h 格式: Filesystem Size Used Avail Capacity iused ifree %iused Mounted on
        # 第1列=FS, 第2列=Size, 第3列=Used, 第4列=Avail, 第5列=Capacity, 第9列=Mounted on
        df -h 2>/dev/null | grep -E '^/dev/' | while read -r fs size used avail capacity iused ifree ipct mount; do
            use_num=$(echo "$capacity" | sed 's/%//')
            if [ "$use_num" -ge "$DISK_USAGE_CRITICAL_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_DANGER)"
            elif [ "$use_num" -ge "$DISK_USAGE_WARNING_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_WARNING)"
            else
                status="$(ss::msg MSG_STATUS_HEALTHY)"
            fi
            # 用 mount 命令补全文件系统类型（macOS 格式：$4 = (apfs,）
            fstype=$(mount | awk -v dev="$fs" -v mnt="$mount" '$1==dev && $3==mnt {gsub(/^\(/,"",$4); gsub(/,$/,"",$4); print $4}')
            printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "${fstype:--}" "$size" "$used" "$avail" "$capacity" "$mount" "$status"
        done
    else
        # Linux df -hT 格式: FS Type Size Used Avail Use% Mounted on
        df -hT 2>/dev/null | grep -E '^/dev/' | while read -r fs type size used avail use mount; do
            use_num=$(echo "$use" | sed 's/%//')
            if [ "$use_num" -ge "$DISK_USAGE_CRITICAL_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_DANGER)"
            elif [ "$use_num" -ge "$DISK_USAGE_WARNING_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_WARNING)"
            else
                status="$(ss::msg MSG_STATUS_HEALTHY)"
            fi
            printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "$type" "$size" "$used" "$avail" "$use" "$mount" "$status"
        done
    fi
    echo ""

    # ==============================================================================
    # 3. inode 使用情况（关键！小文件过多会导致 inode 耗尽）
    # ==============================================================================
    ss::progress 3 10 "$(ss::msg MSG_DISK_SECTION_INODE)"
    echo "## 3. $(ss::msg MSG_DISK_SECTION_INODE)"
    echo ""
    echo "> **$(ss::msg MSG_DISK_EVAL_CRITERIA):** $(ss::msgf MSG_DISK_EVAL_INODE_USAGE "$INODE_USAGE_WARNING_THRESHOLD" "$INODE_USAGE_CRITICAL_THRESHOLD")"
    echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_INODE_NOTE)"
    echo ""
    echo "| $(ss::msg MSG_DISK_COL_FS) | $(ss::msg MSG_DISK_COL_INODE_TOTAL) | $(ss::msg MSG_DISK_COL_USED) | $(ss::msg MSG_DISK_COL_AVAILABLE) | $(ss::msg MSG_DISK_COL_USAGE) | $(ss::msg MSG_DISK_COL_MOUNTPOINT) | $(ss::msg MSG_TABLE_STATUS) |"
    echo "|----------|------------|------|------|--------|--------|------|"
    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS df -i 格式: Filesystem 512-blocks Used Available Capacity iused ifree %iused Mounted on
        # 第1列=FS, 第6列=iused, 第7列=ifree, 第8列=%iused, 第9列=Mounted on
        # 总量近似为 iused + ifree
        # shellcheck disable=SC2034
        df -i 2>/dev/null | grep -E '^/dev/' | while read -r fs blocks used avail capacity iused ifree ipct mount; do
            use_num=$(echo "$ipct" | sed 's/%//')
            if [ "$use_num" -ge "$INODE_USAGE_CRITICAL_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_DANGER)"
            elif [ "$use_num" -ge "$INODE_USAGE_WARNING_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_WARNING)"
            else
                status="$(ss::msg MSG_STATUS_HEALTHY)"
            fi
            # 计算 inode 总量
            itotal=$((iused + ifree))
            printf "| %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "$itotal" "$iused" "$ifree" "$ipct" "$mount" "$status"
        done
    else
        df -i 2>/dev/null | grep -E '^/dev/' | while read -r fs itotal iused iavail iuse mount; do
            use_num=$(echo "$iuse" | sed 's/%//')
            if [ "$use_num" -ge "$INODE_USAGE_CRITICAL_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_DANGER)"
            elif [ "$use_num" -ge "$INODE_USAGE_WARNING_THRESHOLD" ]; then
                status="$(ss::msg MSG_STATUS_WARNING)"
            else
                status="$(ss::msg MSG_STATUS_HEALTHY)"
            fi
            printf "| %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "$itotal" "$iused" "$iavail" "$iuse" "$mount" "$status"
        done
    fi
    echo ""

    # ==============================================================================
    # 4. 磁盘 I/O 性能采样
    # ==============================================================================
    ss::progress 4 10 "$(ss::msg MSG_DISK_SECTION_IO)"
    echo "## 4. $(ss::msg MSG_DISK_SECTION_IO)"
    echo ""
    # 检查 iostat 是否可用
    if ! command -v iostat &>/dev/null; then
        echo "> ⚠️ **$(ss::msg MSG_DISK_IOSTAT_NOT_INSTALLED)**"
        echo "> $(ss::msg MSG_DISK_INSTALL_CMD): \`yum install -y sysstat\` / \`apt install -y sysstat\`"
        echo ""
    elif [ "$OS_TYPE" = "Darwin" ]; then
        # macOS iostat 格式不同，输出 tps 和 MB/s 近似指标
        echo "> **$(ss::msg MSG_DISK_EVAL_CRITERIA):** $(ss::msg MSG_DISK_EVAL_MACOS_IO)"
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_EVAL_MACOS_IO_NOTE)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_DEVICE) | KB/t($(ss::msg MSG_DISK_AVG)) | tps($(ss::msg MSG_DISK_AVG)) | MB/s($(ss::msg MSG_DISK_AVG)) | $(ss::msg MSG_TABLE_EVAL) |"
        echo "|------|------------|-----------|------------|------|"
        # iostat -d -w 1 -c 6: 1秒间隔采样6次；解析 macOS 多设备并列格式
        # 第一行为设备名，第二行为表头，后续每行按每设备3列分组
        iostat -d -w 1 -c 6 2>/dev/null | awk -v tps_threshold="$MACOS_IO_TPS_THRESHOLD" -v mbs_threshold="$MACOS_IO_MBS_THRESHOLD" '
        /^[[:space:]]*$/ { next }
        NR == 1 {
            # 第一行：设备名列表
            col = 1
            for (i=1; i<=NF; i++) {
                if ($i ~ /^disk/) {
                    devs[col] = $i
                    col++
                }
            }
            dev_count = col - 1
            next
        }
        $1 ~ /^(KB|tps|MB)/ { next }  # 跳过表头行
        NF >= 3 * dev_count {
            for (i=0; i<dev_count; i++) {
                dev = devs[i+1]
                kb_t[dev] += $(i*3+1)
                tps[dev] += $(i*3+2)
                mbs[dev] += $(i*3+3)
                cnt[dev]++
            }
        }
        END {
            for (i=1; i<=dev_count; i++) {
                d = devs[i]
                if (cnt[d] == 0) continue
                avg_kbt = kb_t[d] / cnt[d]
                avg_tps = tps[d] / cnt[d]
                avg_mbs = mbs[d] / cnt[d]
                eval = ""
                if (avg_tps > tps_threshold) eval = "🟡 高 IOPS"
                else if (avg_mbs > mbs_threshold) eval = "🟡 高吞吐"
                else eval = "✅ 正常"
                printf "| %s | %.2f | %.1f | %.2f | %s |\n", d, avg_kbt, avg_tps, avg_mbs, eval
            }
        }
    '
        echo ""
    else
        echo "> **$(ss::msg MSG_DISK_EVAL_CRITERIA):** $(ss::msgf MSG_DISK_EVAL_AWAIT "$IO_AWAIT_EXCELLENT_THRESHOLD" "$IO_AWAIT_EXCELLENT_THRESHOLD" "$IO_AWAIT_GOOD_THRESHOLD" "$IO_AWAIT_GOOD_THRESHOLD" "$IO_AWAIT_SLOW_THRESHOLD" "$IO_AWAIT_SLOW_THRESHOLD")"
        echo "> $(ss::msgf MSG_DISK_EVAL_UTIL "$IO_UTIL_HEALTHY_THRESHOLD" "$IO_UTIL_HEALTHY_THRESHOLD" "$IO_UTIL_BUSY_THRESHOLD" "$IO_UTIL_BUSY_THRESHOLD")"
        echo ""
        # iostat -x 1 6: 每秒采样一次，共采样 6 次（持续 6 秒），取最后平均值
        # 关键指标说明:
        #   r/s, w/s: 每秒读写次数 (IOPS)
        #   rkB/s, wkB/s: 每秒读写吞吐量 (带宽)
        #   await: 平均 I/O 等待时间(ms)
        #   %util: 磁盘利用率，接近 100% 表示磁盘忙不过来
        echo "| $(ss::msg MSG_DISK_COL_DEVICE) | r/s | w/s | rkB/s | wkB/s | await | %util | $(ss::msg MSG_TABLE_EVAL) |"
        echo "|------|-----|-----|-------|-------|-------|-------|------|"
        iostat -x 1 6 2>/dev/null | tail -n +4 | awk -v await_excellent="$IO_AWAIT_EXCELLENT_THRESHOLD" -v await_good="$IO_AWAIT_GOOD_THRESHOLD" -v await_slow="$IO_AWAIT_SLOW_THRESHOLD" -v util_healthy="$IO_UTIL_HEALTHY_THRESHOLD" -v util_busy="$IO_UTIL_BUSY_THRESHOLD" '
        /^Device/ { next }
        /^[a-z]/ {
            eval = ""
            if ($10 > await_slow) eval = "🔴 IO极慢"
            else if ($10 > await_good) eval = "🟡 IO较慢"
            else if ($10 > await_excellent) eval = "🟢 正常"
            else eval = "✅ 优秀"

            if ($11 > util_busy) eval = eval " 磁盘饱和"
            else if ($11 > util_healthy) eval = eval " 磁盘繁忙"

            printf "| %s | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f%% | %s |\n",
            $1, $4, $5, $6, $7, $10, $11, eval
        }
    '
        echo ""
    fi

    # ==============================================================================
    # 5. 大文件与目录扫描（定位空间占用大户）
    # ==============================================================================
    ss::progress 5 10 "$(ss::msg MSG_DISK_SECTION_LARGE)"
    echo "## 5. $(ss::msg MSG_DISK_SECTION_LARGE)"
    echo ""
    # 扫描各挂载点下占用空间最大的前 ${MOUNT_SCAN_TOP} 个目录
    # 注意: 会跳过 /proc /sys /dev /run 等虚拟文件系统，避免无意义扫描
    echo "### $(ss::msgf MSG_DISK_SUBSEC_MOUNT_DIRS "$MOUNT_SCAN_TOP")"
    echo ""
    if [ "$OS_TYPE" = "Darwin" ]; then
        MOUNT_COLUMN=9
        DU_DEPTH="-d $MOUNT_SCAN_DEPTH"
    else
        MOUNT_COLUMN=6
        DU_DEPTH="--max-depth=$MOUNT_SCAN_DEPTH"
    fi
    for mount in $(df 2>/dev/null | grep -E '^/dev/' | awk -v col="$MOUNT_COLUMN" '{print $col}'); do
        # 跳过虚拟文件系统挂载点
        case "$mount" in
        /proc | /sys | /dev | /run | /boot/efi) continue ;;
        esac

        echo "#### $(ss::msg MSG_DISK_MOUNT_POINT): \`$mount\`"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_DIRECTORY) |"
        echo "|------|------|"
        # du -k 输出 KB 数值，sort -rn 兼容所有 POSIX sort，再由 hr_kb 转换显示
        # 2>/dev/null 忽略无权限目录的错误；ss::run_with_timeout 避免挂载点扫描耗时过长
        du_output=""
        du_output=$(ss::run_with_timeout "$MOUNT_SCAN_TIMEOUT" du -k $DU_DEPTH "$mount" 2>/dev/null | sort -rn | head -$((MOUNT_SCAN_TOP + 1)) | tail -"$MOUNT_SCAN_TOP")
        if [ -n "$du_output" ]; then
            echo "$du_output" | while read -r size_kb path; do
                echo "| $(ss::hr_kb "$size_kb") | $path |"
            done
        else
            echo "> ⚠️ $(ss::msgf MSG_DISK_MOUNT_SCAN_FAIL "$mount")"
        fi
        echo ""
    done

    # 扫描大于 ${LARGE_FILE_SIZE_THRESHOLD} 的大文件，按大小降序
    # 使用 timeout 限制扫描时间，maxdepth 限制深度，避免根目录扫描耗时过长
    echo "### $(ss::msgf MSG_DISK_SUBSEC_LARGE_FILES_THRESHOLD "$LARGE_FILE_SIZE_THRESHOLD" "$LARGE_FILE_TOP")"
    echo ""
    echo "| $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_FILE_PATH) |"
    echo "|------|----------|"
    # ss::run_with_timeout 已按系统自动选择 timeout/gtimeout/自实现，macOS 也能安全限时
    ss::run_with_timeout "$LARGE_FILE_SCAN_TIMEOUT" find / -maxdepth "$LARGE_FILE_SCAN_DEPTH" -type f -size +"$LARGE_FILE_SIZE_THRESHOLD" \
        -not -path "/proc/*" -not -path "/sys/*" -not -path "/dev/*" -not -path "/run/*" \
        2>/dev/null | while read -r file; do
        du -k "$file" 2>/dev/null
    done | sort -rn | head -"$LARGE_FILE_TOP" | while read -r size_kb path; do
        echo "| $(ss::hr_kb "$size_kb") | $path |"
    done
    echo ""

    # ==============================================================================
    # 6. 日志文件专项扫描（日志膨胀是磁盘满的元凶之一）
    # ==============================================================================
    ss::progress 6 10 "$(ss::msg MSG_DISK_SECTION_LOG)"
    echo "## 6. $(ss::msg MSG_DISK_SECTION_LOG)"
    echo ""
    echo "### $(ss::msgf MSG_DISK_SUBSEC_LOG_LARGE "$LOG_FILE_SIZE_THRESHOLD")"
    echo ""
    echo "| $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_FILE_PATH) |"
    echo "|------|----------|"
    find "$LOG_SCAN_DIR" -type f -size +"$LOG_FILE_SIZE_THRESHOLD" 2>/dev/null | while read file; do
        size=$(du -h "$file" 2>/dev/null | awk '{print $1}')
        echo "| $size | $file |"
    done
    echo ""
    echo "### $(ss::msg MSG_DISK_SUBSEC_LOG_TOTAL)"
    echo ""
    echo "| $(ss::msg MSG_DISK_COL_PATH) | $(ss::msg MSG_DISK_TOTAL_SIZE) |"
    echo "|------|--------|"
    du -sh "$LOG_SCAN_DIR" 2>/dev/null | awk '{printf "| %s | %s |\n", $2, $1}'
    echo ""

    # ==============================================================================
    # 7. LVM 逻辑卷信息（如果使用 LVM）
    # ==============================================================================
    ss::progress 7 10 "$(ss::msg MSG_DISK_SECTION_LVM)"
    echo "## 7. $(ss::msg MSG_DISK_SECTION_LVM)"
    echo ""
    if command -v lvs &>/dev/null && command -v vgs &>/dev/null; then
        echo "> $(ss::msg MSG_DISK_LVM_DETECTED)"
        echo ""

        echo "### $(ss::msg MSG_DISK_LVM_PV)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_DEVICE) | $(ss::msg MSG_DISK_COL_VOLUME_GROUP) | $(ss::msg MSG_DISK_COL_CAPACITY) | $(ss::msg MSG_DISK_COL_USED) |"
        echo "|------|------|------|------|"
        pvs 2>/dev/null | grep -v "PV" | awk '{printf "| %s | %s | %s | %s |\n", $1, $2, $5, $6}'
        echo ""

        echo "### $(ss::msg MSG_DISK_LVM_VG)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_VOLUME_GROUP) | $(ss::msg MSG_DISK_COL_CAPACITY) | $(ss::msg MSG_DISK_COL_AVAILABLE) |"
        echo "|------|------|------|"
        vgs 2>/dev/null | grep -v "VG" | awk '{printf "| %s | %s | %s |\n", $1, $6, $7}'
        echo ""

        echo "### $(ss::msg MSG_DISK_LVM_LV)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_LOGICAL_VOLUME) | $(ss::msg MSG_DISK_COL_VOLUME_GROUP) | $(ss::msg MSG_DISK_COL_CAPACITY) |"
        echo "|--------|------|------|"
        lvs 2>/dev/null | grep -v "LV" | awk '{printf "| %s | %s | %s |\n", $1, $2, $4}'
        echo ""
    else
        echo "> ℹ️ $(ss::msg MSG_DISK_LVM_NOT_USED)"
        echo ""
    fi

    # ==============================================================================
    # 8. 磁盘健康状态 (SMART)
    # ==============================================================================
    ss::progress 8 10 "$(ss::msg MSG_DISK_SECTION_SMART)"
    echo "## 8. $(ss::msg MSG_DISK_SECTION_SMART)"
    echo ""
    if ! command -v smartctl &>/dev/null; then
        if [ "$OS_TYPE" = "Darwin" ]; then
            echo "> ⚠️ **$(ss::msg MSG_DISK_SMART_NOT_INSTALLED)**"
            echo "> $(ss::msg MSG_DISK_SMART_INSTALL_MACOS): \`brew install smartmontools\`"
        else
            echo "> ⚠️ **$(ss::msg MSG_DISK_SMART_NOT_INSTALLED)**"
            echo "> $(ss::msg MSG_DISK_SMART_INSTALL_LINUX): \`yum install -y smartmontools\` / \`apt install -y smartmontools\`"
        fi
        echo ""
    else
        # 枚举物理磁盘
        if [ "$OS_TYPE" = "Darwin" ]; then
            DISK_LIST=$(diskutil list 2>/dev/null | awk '/^\// && /physical/ {gsub(/:$/,"",$1); print $1}')
        else
            DISK_LIST=$(lsblk -d -o NAME,TYPE 2>/dev/null | grep disk | awk '{print $1}')
        fi

        # 遍历所有物理磁盘，读取 SMART 健康状态
        for disk in $DISK_LIST; do
            echo "### $disk"
            echo ""
            # -H 只输出健康状态，简洁
            health=$(smartctl -H $disk 2>/dev/null | grep "SMART overall-health" | awk -F': ' '{print $2}')
            if [ -n "$health" ]; then
                echo "- **$(ss::msg MSG_DISK_SMART_HEALTH):** $health"
            else
                echo "- **$(ss::msg MSG_DISK_SMART_HEALTH):** $(ss::msg MSG_DISK_SMART_UNREADABLE)"
            fi

            # 读取关键 SMART 属性（温度、重映射扇区、通电时间等）
            # 使用 -A 获取属性表，过滤关键行；使用 $NF 获取最后一列（Raw_Value），
            # 避免不同厂商输出列数不一致导致取值错误
            echo ""
            echo "| $(ss::msg MSG_DISK_SMART_ATTR) | $(ss::msg MSG_DISK_SMART_RAW_VALUE) |"
            echo "|------|--------|"
            smartctl -A $disk 2>/dev/null | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Temperature|Power_On_Hours|Wear_Leveling_Count|Media_Wearout_Indicator|Total_LBAs_Written" | while read -r line; do
                attr_name=$(echo "$line" | awk '{print $2}')
                raw_value=$(echo "$line" | awk '{print $NF}')
                echo "| $attr_name | $raw_value |"
            done
            echo ""
        done
    fi

    # ==============================================================================
    # 9. 挂载参数与文件系统特性
    # ==============================================================================
    ss::progress 9 10 "$(ss::msg MSG_DISK_SECTION_MOUNT)"
    echo "## 9. $(ss::msg MSG_DISK_SECTION_MOUNT)"
    echo ""
    echo "| $(ss::msg MSG_DISK_COL_DEVICE) | $(ss::msg MSG_DISK_COL_MOUNTPOINT) | $(ss::msg MSG_DISK_COL_TYPE) | $(ss::msg MSG_DISK_COL_MOUNT_OPTIONS) |"
    echo "|------|--------|------|------|"
    mount 2>/dev/null | grep -E '^/dev/' | awk '
    {
        dev = $1
        mnt = $3
        type = ""
        opts = ""
        for (i=4; i<=NF; i++) {
            if ($i ~ /^\(/) {
                # macOS 格式: "/dev/disk on / (apfs, sealed, local, ...)"
                gsub(/^\(/, "", $i)
                gsub(/,$/, "", $i)
                type = $i
                # 参数从类型字段的下一个字段开始，避免重复输出类型
                for (j=i+1; j<=NF; j++) {
                    gsub(/\)$/, "", $j)
                    gsub(/,$/, "", $j)
                    opts = opts $j " "
                }
                break
            }
            if ($i == "type") {
                # Linux 格式: "/dev/sda1 on / type ext4 (rw,...)"
                type = $(i+1)
                for (j=i+2; j<=NF; j++) opts = opts $j " "
                break
            }
        }
        printf "| %s | %s | %s | %s |\n", dev, mnt, type, opts
    }
'
    echo ""

    # ==============================================================================
    # 10. Docker 空间占用专项扫描
    # ==============================================================================
    ss::progress 10 10 "$(ss::msg MSG_DISK_SECTION_DOCKER)"
    echo "## 10. $(ss::msg MSG_DISK_SECTION_DOCKER)"
    echo ""
    if ! command -v docker &>/dev/null; then
        echo "> ℹ️ $(ss::msg MSG_DISK_DOCKER_NOT_INSTALLED)"
        echo ""
    else
        # --- 10.1 Docker 总体空间概览 ---
        echo "### 10.1 $(ss::msg MSG_DISK_DOCKER_OVERVIEW)"
        echo ""
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_DOCKER_OVERVIEW_DESC)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_TYPE) | $(ss::msg MSG_DISK_COL_TOTAL) | $(ss::msg MSG_DISK_COL_ACTIVE) | $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_RECLAIMABLE) |"
        echo "|------|------|------|------|--------|"
        docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}" 2>/dev/null | tail -n +2 | while IFS=$'\t' read -r type total active size reclaimable; do
            printf "| %s | %s | %s | %s | %s |\n" "$type" "$total" "$active" "$size" "$reclaimable"
        done
        echo ""

        # --- 10.2 Docker 数据目录总大小 ---
        echo "### 10.2 $(ss::msg MSG_DISK_DOCKER_DATA_DIR)"
        echo ""

        # 优先级：配置文件 > docker info > 默认路径
        if [ -n "$DOCKER_DATA_DIR" ] && [ -d "$DOCKER_DATA_DIR" ]; then
            # 使用配置文件中的自定义目录
            echo "> **$(ss::msg MSG_DISK_DOCKER_DATA_DIR_CONFIG):** \`$DOCKER_DATA_DIR\`"
            echo ""
            docker_total=$(du -sh "$DOCKER_DATA_DIR" 2>/dev/null | awk '{print $1}')
            echo "> **$(ss::msgf MSG_DISK_DOCKER_DATA_DIR_TOTAL "$DOCKER_DATA_DIR"):** ${docker_total:-$(ss::msg MSG_DISK_UNKNOWN)}"
            echo ""
            echo "| $(ss::msg MSG_DISK_COL_SUBDIR_NAME) | $(ss::msg MSG_DISK_COL_SIZE) |"
            echo "|--------|------|"
            for sub in "$DOCKER_DATA_DIR"/*/; do
                [ -d "$sub" ] || continue
                size_kb=$(du -sk "$sub" 2>/dev/null | awk '{print $1}')
                echo "${size_kb:-0}	$sub"
            done | sort -rn | while IFS=$'\t' read -r size_kb path; do
                dir_name=$(basename "$path")
                printf "| %s | %s |\n" "$dir_name" "$(ss::hr_kb "$size_kb")"
            done
        elif [ -d "/var/lib/docker" ]; then
            # 使用默认目录
            DOCKER_DATA_DIR="/var/lib/docker"
            docker_total=$(du -sh "$DOCKER_DATA_DIR" 2>/dev/null | awk '{print $1}')
            echo "> **$(ss::msgf MSG_DISK_DOCKER_DATA_DIR_TOTAL "$DOCKER_DATA_DIR"):** ${docker_total:-$(ss::msg MSG_DISK_UNKNOWN)}"
            echo ""
            echo "| $(ss::msg MSG_DISK_COL_SUBDIR_NAME) | $(ss::msg MSG_DISK_COL_SIZE) |"
            echo "|--------|------|"
            for sub in "$DOCKER_DATA_DIR"/*/; do
                [ -d "$sub" ] || continue
                size_kb=$(du -sk "$sub" 2>/dev/null | awk '{print $1}')
                echo "${size_kb:-0}	$sub"
            done | sort -rn | while IFS=$'\t' read -r size_kb path; do
                dir_name=$(basename "$path")
                printf "| %s | %s |\n" "$dir_name" "$(ss::hr_kb "$size_kb")"
            done
        else
            # 尝试通过 docker info 获取 Docker Root Dir
            DOCKER_ROOT=$(docker info 2>/dev/null | grep "Docker Root Dir" | awk -F': ' '{print $2}')
            if [ -n "$DOCKER_ROOT" ] && [ -d "$DOCKER_ROOT" ]; then
                DOCKER_DATA_DIR="$DOCKER_ROOT"
                docker_total=$(du -sh "$DOCKER_ROOT" 2>/dev/null | awk '{print $1}')
                echo "> **$(ss::msgf MSG_DISK_DOCKER_DATA_DIR_TOTAL "$DOCKER_ROOT"):** ${docker_total:-$(ss::msg MSG_DISK_UNKNOWN)}"
                echo ""
                echo "| $(ss::msg MSG_DISK_COL_SUBDIR_NAME) | $(ss::msg MSG_DISK_COL_SIZE) |"
                echo "|--------|------|"
                for sub in "$DOCKER_ROOT"/*/; do
                    [ -d "$sub" ] || continue
                    size_kb=$(du -sk "$sub" 2>/dev/null | awk '{print $1}')
                    echo "${size_kb:-0}	$sub"
                done | sort -rn | while IFS=$'\t' read -r size_kb path; do
                    dir_name=$(basename "$path")
                    printf "| %s | %s |\n" "$dir_name" "$(ss::hr_kb "$size_kb")"
                done
            else
                echo "> ⚠️ $(ss::msg MSG_DISK_DOCKER_CANNOT_LOCATE)"
                echo "> **$(ss::msg MSG_DISK_DOCKER_CONFIG_HINT)**"
            fi
        fi
        echo ""

        # --- 10.3 镜像详情（按大小降序 Top${DOCKER_IMAGE_TOP}）---
        echo "### 10.3 $(ss::msgf MSG_DISK_DOCKER_IMAGES "$DOCKER_IMAGE_TOP")"
        echo ""
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_DOCKER_IMAGES_DESC)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_REPO_TAG) | $(ss::msg MSG_DISK_COL_IMAGE_ID) | $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_CREATED) |"
        echo "|---------------|---------|------|----------|"
        docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null | tail -n +2 | head -"$DOCKER_IMAGE_TOP" | while IFS=$'\t' read -r repo id size created; do
            # 清理空白标签
            repo=$(echo "$repo" | sed 's/:<none>$/<none>/')
            printf "| %s | %s | %s | %s |\n" "$repo" "$id" "$size" "$created"
        done
        echo ""

        # 悬空镜像数量与大小
        dangling_count=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
        if [ "$dangling_count" -gt 0 ]; then
            echo "> ⚠️ $(ss::msgf MSG_DISK_DOCKER_DANGLING "$dangling_count")"
            echo ""
        fi

        # --- 10.4 容器空间占用 Top${DOCKER_CONTAINER_TOP} ---
        echo "### 10.4 $(ss::msgf MSG_DISK_DOCKER_CONTAINERS "$DOCKER_CONTAINER_TOP")"
        echo ""
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_DOCKER_CONTAINERS_DESC)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_CONTAINER_NAME) | $(ss::msg MSG_DISK_COL_IMAGE) | $(ss::msg MSG_DISK_COL_STATUS) | $(ss::msg MSG_DISK_COL_WRITABLE_SIZE) |"
        echo "|--------|------|------|------------|"
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Size}}" 2>/dev/null | tail -n +2 | head -"$DOCKER_CONTAINER_TOP" | while IFS=$'\t' read -r name image status size; do
            printf "| %s | %s | %s | %s |\n" "$name" "$image" "$status" "$size"
        done
        echo ""

        # --- 10.5 Volume 卷占用 Top${DOCKER_VOLUME_TOP} ---
        echo "### 10.5 $(ss::msgf MSG_DISK_DOCKER_VOLUMES "$DOCKER_VOLUME_TOP")"
        echo ""
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_DOCKER_VOLUMES_DESC)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_VOLUME_NAME) | $(ss::msg MSG_DISK_COL_DRIVER) | $(ss::msg MSG_DISK_COL_MOUNTPOINT) |"
        echo "|--------|------|--------|"
        docker volume ls --format "table {{.Name}}\t{{.Driver}}\t{{.Mountpoint}}" 2>/dev/null | tail -n +2 | head -"$DOCKER_VOLUME_TOP" | while IFS=$'\t' read -r name driver mountpoint; do
            printf "| %s | %s | %s |\n" "$name" "$driver" "$mountpoint"
        done
        echo ""

        # 统计各卷实际大小（需遍历挂载点）
        echo "#### $(ss::msg MSG_DISK_DOCKER_VOLUME_ACTUAL)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_VOLUME_NAME) |"
        echo "|------|--------|"
        docker volume ls -q 2>/dev/null | while read -r vol; do
            mountpoint=$(docker volume inspect --format '{{.Mountpoint}}' "$vol" 2>/dev/null)
            if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
                vol_size_kb=$(du -sk "$mountpoint" 2>/dev/null | awk '{print $1}')
                echo "${vol_size_kb:-0}	$vol"
            fi
        done | sort -rn | head -"$DOCKER_VOLUME_TOP" | while IFS=$'\t' read -r vol_size_kb vol; do
            printf "| %s | %s |\n" "$(ss::hr_kb "$vol_size_kb")" "$vol"
        done
        echo ""

        # 孤立卷提示
        orphan_vols=0
        for vol in $(docker volume ls -q 2>/dev/null); do
            ref=$(docker ps -a --filter volume="$vol" -q 2>/dev/null | wc -l | tr -d ' ')
            if [ "$ref" -eq 0 ]; then
                orphan_vols=$((orphan_vols + 1))
            fi
        done
        if [ "$orphan_vols" -gt 0 ]; then
            echo "> ⚠️ $(ss::msgf MSG_DISK_DOCKER_ORPHAN "$orphan_vols")"
            echo ""
        fi

        # --- 10.6 构建缓存 ---
        echo "### 10.6 $(ss::msg MSG_DISK_DOCKER_BUILD_CACHE)"
        echo ""
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_DOCKER_BUILD_CACHE_DESC)"
        echo ""
        if docker buildx du 2>/dev/null | head -1 | grep -q .; then
            echo "| $(ss::msg MSG_DISK_COL_TYPE) | $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_IS_ACTIVE) |"
            echo "|------|------|----------|"
            docker buildx du 2>/dev/null | awk 'NR>1 && NF>=3 {printf "| %s | %s | %s |\n", $1, $2, $3}' | head -"$DOCKER_BUILD_CACHE_TOP"
            echo ""
            # 构建缓存总量
            build_total=$(docker buildx du 2>/dev/null | tail -1)
            echo "> **$(ss::msg MSG_DISK_DOCKER_BUILD_TOTAL):** $build_total"
        else
            # 回退到 docker system df 中的 Build Cache 行
            build_info=$(docker system df 2>/dev/null | grep "Build Cache")
            if [ -n "$build_info" ]; then
                echo "\`\`\`"
                echo "$build_info"
                echo "\`\`\`"
            else
                echo "> ℹ️ $(ss::msg MSG_DISK_DOCKER_NO_CACHE)"
            fi
        fi
        echo ""

        # --- 10.7 Docker 日志文件扫描 ---
        echo "### 10.7 $(ss::msg MSG_DISK_DOCKER_LOG_SCAN)"
        echo ""
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msg MSG_DISK_DOCKER_LOG_DESC)"
        echo ""

        # 扫描 Docker 日志目录下的大文件
        DOCKER_LOG_DIR=""
        if [ -d "/var/lib/docker/containers" ]; then
            DOCKER_LOG_DIR="/var/lib/docker/containers"
        elif [ -n "$DOCKER_ROOT" ] && [ -d "$DOCKER_ROOT/containers" ]; then
            DOCKER_LOG_DIR="$DOCKER_ROOT/containers"
        fi

        if [ -n "$DOCKER_LOG_DIR" ]; then
            echo "#### $(ss::msgf MSG_DISK_DOCKER_LOG_LARGE "$DOCKER_LOG_SIZE_THRESHOLD")"
            echo ""
            echo "| $(ss::msg MSG_DISK_COL_SIZE) | $(ss::msg MSG_DISK_COL_FILE_PATH) |"
            echo "|------|----------|"
            find "$DOCKER_LOG_DIR" -name "*-json.log" -type f -size +"$DOCKER_LOG_SIZE_THRESHOLD" 2>/dev/null | while read -r logfile; do
                size=$(du -h "$logfile" 2>/dev/null | awk '{print $1}')
                echo "| $size | $logfile |"
            done
            echo ""

            # 日志总大小
            log_total=$(find "$DOCKER_LOG_DIR" -name "*-json.log" -type f -exec du -ck {} + 2>/dev/null | tail -1 | awk '{print $1}')
            if [ -n "$log_total" ] && [ "$log_total" -gt 0 ]; then
                echo "> **$(ss::msg MSG_DISK_DOCKER_LOG_TOTAL):** $(ss::hr_kb "$log_total")"
                echo ""
            fi
        else
            echo "> ⚠️ $(ss::msg MSG_DISK_DOCKER_LOG_CANNOT_LOCATE)"
            echo ""
        fi

        # 列出当前运行容器的日志大小 Top${DOCKER_CONTAINER_LOG_TOP}
        echo "#### $(ss::msgf MSG_DISK_DOCKER_LOG_RUNNING "$DOCKER_CONTAINER_LOG_TOP")"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_LOG_SIZE) | $(ss::msg MSG_DISK_COL_CONTAINER_NAME) | $(ss::msg MSG_DISK_COL_CONTAINER_ID) |"
        echo "|----------|--------|---------|"
        docker ps --format "{{.Names}}\t{{.ID}}" 2>/dev/null | while IFS=$'\t' read -r cname cid; do
            log_size=$(docker inspect --format='{{.LogPath}}' "$cid" 2>/dev/null)
            if [ -n "$log_size" ] && [ -f "$log_size" ]; then
                size_kb=$(du -k "$log_size" 2>/dev/null | awk '{print $1}')
                echo "${size_kb:-0}	$cname	$cid"
            fi
        done | sort -rn | head -"$DOCKER_CONTAINER_LOG_TOP" | while IFS=$'\t' read -r size_kb name id; do
            printf "| %s | %s | %s |\n" "$(ss::hr_kb "$size_kb")" "$name" "$id"
        done
        echo ""

        # --- 10.8 清理建议汇总（仅建议，不执行）---
        echo "### 10.8 $(ss::msg MSG_DISK_DOCKER_CLEANUP)"
        echo ""
        echo "> ⚠️ **$(ss::msg MSG_DISK_DOCKER_CLEANUP_WARN)**"
        echo "> $(ss::msg MSG_DISK_DOCKER_CLEANUP_HINT)"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_OPERATION) | $(ss::msg MSG_DISK_COL_COMMAND) | $(ss::msg MSG_DISK_COL_RISK) | $(ss::msg MSG_TABLE_DESC) |"
        echo "|------|------|----------|------|"
        echo "| $(ss::msg MSG_DISK_DOCKER_CLEAN_DANGLING) | \`docker image prune\` | 🟢 $(ss::msg MSG_DISK_RISK_LOW) | $(ss::msg MSG_DISK_DOCKER_CLEAN_DANGLING_DESC) |"
        echo "| $(ss::msg MSG_DISK_DOCKER_CLEAN_UNUSED) | \`docker image prune -a\` | 🟡 $(ss::msg MSG_DISK_RISK_MED) | $(ss::msg MSG_DISK_DOCKER_CLEAN_UNUSED_DESC) |"
        echo "| $(ss::msg MSG_DISK_DOCKER_CLEAN_STOPPED) | \`docker container prune\` | 🟢 $(ss::msg MSG_DISK_RISK_LOW) | $(ss::msg MSG_DISK_DOCKER_CLEAN_STOPPED_DESC) |"
        echo "| $(ss::msg MSG_DISK_DOCKER_CLEAN_ORPHAN) | \`docker volume prune\` | 🟡 $(ss::msg MSG_DISK_RISK_MED) | $(ss::msg MSG_DISK_DOCKER_CLEAN_ORPHAN_DESC) |"
        echo "| $(ss::msg MSG_DISK_DOCKER_CLEAN_BUILD) | \`docker builder prune\` | 🟢 $(ss::msg MSG_DISK_RISK_LOW) | $(ss::msg MSG_DISK_DOCKER_CLEAN_BUILD_DESC) |"
        echo "| $(ss::msg MSG_DISK_DOCKER_CLEAN_ALL) | \`docker system prune -a --volumes\` | 🔴 $(ss::msg MSG_DISK_RISK_HIGH) | $(ss::msg MSG_DISK_DOCKER_CLEAN_ALL_DESC) |"
        echo "| $(ss::msg MSG_DISK_DOCKER_CLEAN_LOG) | \`truncate -s 0 /path/to/log\` | 🟢 $(ss::msg MSG_DISK_RISK_LOW) | $(ss::msg MSG_DISK_DOCKER_CLEAN_LOG_DESC) |"
        echo ""
    fi # 结束 if ! command -v docker &> /dev/null 判断
fi     # 结束 if [ "$SKIP_TO_FOOTER" != "true" ] 判断（全盘扫描模式）

# ==============================================================================
# 11. 实时 I/O 负载快照（默认关闭）
# ==============================================================================
# 通过 ENABLE_REALTIME_IO 变量控制是否执行
# Linux: 读取两次 /proc/diskstats，间隔 2 秒，计算瞬时速率
# macOS: 无 /proc/diskstats，暂不支持
if [ "$SKIP_TO_FOOTER" != "true" ] && [ "$ENABLE_REALTIME_IO" = "true" ]; then
    echo "## 11. $(ss::msg MSG_DISK_SECTION_REALTIME_IO)"
    echo ""
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo "> ℹ️ $(ss::msg MSG_DISK_REALTIME_IO_MACOS)"
        echo "> $(ss::msg MSG_DISK_REALTIME_IO_HINT)"
    else
        echo "> **$(ss::msg MSG_TABLE_DESC):** $(ss::msgf MSG_DISK_REALTIME_IO_DESC "$REALTIME_IO_INTERVAL")"
        echo ""
        echo "| $(ss::msg MSG_DISK_COL_DEVICE) | $(ss::msg MSG_DISK_COL_READ_SECTORS) | $(ss::msg MSG_DISK_COL_WRITE_SECTORS) |"
        echo "|------|-----------|-----------|"

        # 第一次采样
        cat /proc/diskstats 2>/dev/null | awk '$3 ~ /^[a-z]/ {print}' | while read -r line; do
            dev=$(echo "$line" | awk '{print $3}')
            read1=$(echo "$line" | awk '{print $6}')
            write1=$(echo "$line" | awk '{print $10}')
            echo "$dev $read1 $write1"
        done >/tmp/diskstats_before

        sleep "$REALTIME_IO_INTERVAL"

        # 第二次采样并计算差值
        cat /proc/diskstats 2>/dev/null | awk '$3 ~ /^[a-z]/ {print}' | while read -r line; do
            dev=$(echo "$line" | awk '{print $3}')
            read2=$(echo "$line" | awk '{print $6}')
            write2=$(echo "$line" | awk '{print $10}')

            # 查找之前的数据
            before=$(grep "^$dev " /tmp/diskstats_before 2>/dev/null)
            if [ -n "$before" ]; then
                read1=$(echo "$before" | awk '{print $2}')
                write1=$(echo "$before" | awk '{print $3}')
                # 计算 ${REALTIME_IO_INTERVAL} 秒内的速率（扇区数差 / ${REALTIME_IO_INTERVAL}秒）
                read_iops=$(((read2 - read1) / REALTIME_IO_INTERVAL))
                write_iops=$(((write2 - write1) / REALTIME_IO_INTERVAL))
                echo "| /dev/$dev | $read_iops | $write_iops |"
            fi
        done

        rm -f /tmp/diskstats_before
    fi
    echo ""
fi

# ==============================================================================
# 报告尾部
# ==============================================================================
if [ "$DIR_SCAN_MODE" = "true" ]; then
    echo "---"
    echo ""
    echo "## $(ss::msg MSG_DISK_APPENDIX)"
    echo ""
    echo "$(ss::msg MSG_DISK_APPENDIX_HINT)"
    echo ""
    echo '```'
    echo "$(ss::msg MSG_DISK_APPENDIX_DIR_PROMPT)"
    echo "1. $(ss::msg MSG_DISK_APPENDIX_DIR_P1)"
    echo "2. $(ss::msg MSG_DISK_APPENDIX_DIR_P2)"
    echo "3. $(ss::msg MSG_DISK_APPENDIX_DIR_P3)"
    echo "4. $(ss::msg MSG_DISK_APPENDIX_DIR_P4)"
    echo '```'
    echo ""
    echo "> 📄 **$(ss::msg MSG_COMMON_REPORT_SAVED):** \`$REPORT_PATH\`"
else
    echo "---"
    echo ""
    echo "## $(ss::msg MSG_DISK_APPENDIX)"
    echo ""
    echo "$(ss::msg MSG_DISK_APPENDIX_HINT)"
    echo ""
    echo '```'
    echo "$(ss::msg MSG_DISK_APPENDIX_DISK_PROMPT)"
    echo "1. $(ss::msgf MSG_DISK_APPENDIX_DISK_P1 "$REPORT_DISK_USAGE_WARNING" "$REPORT_INODE_USAGE_WARNING")"
    echo "2. $(ss::msgf MSG_DISK_APPENDIX_DISK_P2 "$REPORT_IO_AWAIT_WARNING" "$REPORT_IO_UTIL_WARNING")"
    echo "3. $(ss::msg MSG_DISK_APPENDIX_DISK_P3)"
    echo "4. $(ss::msg MSG_DISK_APPENDIX_DISK_P4)"
    echo "5. $(ss::msg MSG_DISK_APPENDIX_DISK_P5)"
    echo "6. $(ss::msg MSG_DISK_APPENDIX_DISK_P6)"
    echo '```'
    echo ""
    echo "> 📄 **$(ss::msg MSG_COMMON_REPORT_SAVED):** \`$REPORT_PATH\`"
fi

# ==============================================================================
# 报告尾部结束
# ==============================================================================
ss::report_end "$REPORT_PATH"

# JSON 输出（供 Agent 程序化消费）
if [ "$JSON_OUTPUT" = "true" ]; then
    ss::print_json_metadata "success" "$REPORT_PATH" "disk_analyzer.sh" 0 "" ""
fi

# 通知推送（未启用 --notify 时静默跳过，推送失败不影响主流程）
ss::notify_send "$(ss::msg MSG_DISK_REPORT_TITLE)" "$REPORT_PATH" || true

exit 0

# ==============================================================================
# 使用说明:
# 1. 全盘扫描: ./disk_analyzer.sh
#    输出同时显示在终端并写入 Markdown 文件
# 2. 指定目录扫描: ./disk_analyzer.sh -d /path/to/dir
#    只扫描指定目录，跳过全盘扫描，支持多目录和自定义配置
#    示例:
#      ./disk_analyzer.sh -d /var/log
#      ./disk_analyzer.sh -d /var/log -d /home/user
#      ./disk_analyzer.sh -d "/var/log /home/user" --depth 5 --top 30
# 3. 开启实时 I/O: ENABLE_REALTIME_IO=true ./disk_analyzer.sh
# 4. 修改输出路径: REPORT_PATH=/var/log/report.md ./disk_analyzer.sh
# 5. 配合 crontab 定时执行，直接生成 Markdown 供后续分析
# 6. 配置文件: 在当前目录创建 disk_analyzer.conf 文件，可自定义以下配置:
#    磁盘使用率阈值:
#      - DISK_USAGE_WARNING_THRESHOLD: 磁盘使用率警告阈值（%，默认: 80）
#      - DISK_USAGE_CRITICAL_THRESHOLD: 磁盘使用率危险阈值（%，默认: 90）
#    inode 使用率阈值:
#      - INODE_USAGE_WARNING_THRESHOLD: inode 使用率警告阈值（%，默认: 70）
#      - INODE_USAGE_CRITICAL_THRESHOLD: inode 使用率危险阈值（%，默认: 90）
#    I/O 性能阈值:
#      - IO_AWAIT_EXCELLENT_THRESHOLD: I/O await 优秀阈值（ms，默认: 10）
#      - IO_AWAIT_GOOD_THRESHOLD: I/O await 正常阈值（ms，默认: 20）
#      - IO_AWAIT_SLOW_THRESHOLD: I/O await 缓慢阈值（ms，默认: 50）
#      - IO_UTIL_HEALTHY_THRESHOLD: I/O %util 健康阈值（%，默认: 60）
#      - IO_UTIL_BUSY_THRESHOLD: I/O %util 繁忙阈值（%，默认: 80）
#    大文件扫描配置:
#      - LARGE_FILE_SCAN_DEPTH: 大文件扫描深度（默认: 6）
#      - LARGE_FILE_SIZE_THRESHOLD: 大文件大小阈值（默认: 1G）
#      - LARGE_FILE_SCAN_TIMEOUT: 大文件扫描超时时间（秒，默认: 30）
#    日志文件扫描配置:
#      - LOG_SCAN_DIR: 日志扫描目录（默认: /var/log）
#      - LOG_FILE_SIZE_THRESHOLD: 日志文件大小阈值（默认: 100M）
#    Docker 扫描配置:
#      - DOCKER_DATA_DIR: 自定义 Docker 数据目录路径
#      - DOCKER_IMAGE_TOP: Docker 镜像 Top N（默认: 15）
#      - DOCKER_CONTAINER_TOP: Docker 容器 Top N（默认: 10）
#      - DOCKER_VOLUME_TOP: Docker 卷 Top N（默认: 15）
#      - DOCKER_LOG_SIZE_THRESHOLD: Docker 日志文件大小阈值（默认: 100M）
#    挂载点扫描配置:
#      - MOUNT_SCAN_DEPTH: 挂载点扫描深度（默认: 1）
#      - MOUNT_SCAN_TOP: 挂载点扫描 Top N（默认: 10）
#      - MOUNT_SCAN_TIMEOUT: 挂载点扫描超时时间（秒，默认: 20）
#    指定目录扫描模式配置:
#      - SCAN_DEPTH: 指定目录扫描深度（默认: 3）
#      - SCAN_TOP: 指定目录扫描 Top N（默认: 20）
#    实时 I/O 配置:
#      - ENABLE_REALTIME_IO: 是否启用实时 I/O 负载快照（true/false，默认: false）
#      - REALTIME_IO_INTERVAL: 实时 I/O 采样间隔（秒，默认: 2）
#    其他扫描配置:
#      - LARGE_FILE_TOP: 大文件 Top N（默认: 20）
#      - DOCKER_BUILD_CACHE_TOP: Docker 构建缓存 Top N（默认: 15）
#      - DOCKER_CONTAINER_LOG_TOP: 运行中容器日志大小 Top N（默认: 10）
#      - MACOS_IO_TPS_THRESHOLD: macOS I/O tps 阈值（默认: 1000）
#      - MACOS_IO_MBS_THRESHOLD: macOS I/O MB/s 阈值（默认: 100）
#      - REPORT_DISK_USAGE_WARNING: 报告建议中的磁盘使用率警告阈值（%，默认: 85）
#      - REPORT_INODE_USAGE_WARNING: 报告建议中的 inode 使用率警告阈值（%，默认: 80）
#      - REPORT_IO_AWAIT_WARNING: 报告建议中的 I/O await 警告阈值（ms，默认: 20）
#      - REPORT_IO_UTIL_WARNING: 报告建议中的 I/O %util 警告阈值（%，默认: 100）
#    示例配置文件: disk_analyzer.conf.example
# ==============================================================================
