#!/bin/bash
# ==============================================================================
# 脚本名称: disk_analyzer.sh
# 功能说明: 磁盘专项深度分析，采集空间、I/O、inode、大文件、Docker 空间占用、健康状态
#             默认跳过实时 I/O 负载快照，输出标准 Markdown 报告文件
# 适用系统: Linux (CentOS/Ubuntu/Debian/RHEL)
# 依赖工具: sysstat(iostat), smartmontools(smartctl), bc, lsblk, find, du
# 安装依赖:
#   CentOS: yum install -y sysstat smartmontools bc
#   Ubuntu: apt install -y sysstat smartmontools bc
# 使用方法: chmod +x disk_analyzer.sh && ./disk_analyzer.sh
# 输出文件: 默认生成 /tmp/disk_report.md（可修改 REPORT_PATH 变量）
# ==============================================================================

# --- 配置区 ---
# 报告输出路径，可自定义为 /var/log/disk_report.md 等
# 文件名自动附带时间戳，避免多次执行覆盖历史报告
REPORT_PATH="/tmp/disk_report_$(date '+%Y%m%d_%H%M%S').md"

# 大文件扫描超时（秒），防止从根目录扫描耗时过长
LARGE_FILE_SCAN_TIMEOUT=30

# 人类可读大小转换（兼容无 GNU sort -h 的系统）
hr_kb() {
    local kb=$1
    if [ -z "$kb" ] || [ "$kb" = "0" ]; then echo "0KB"; return; fi
    local units=("KB" "MB" "GB" "TB")
    local unit_idx=0
    local value=$kb
    while awk "BEGIN {exit !($value >= 1024)}" 2>/dev/null && [ $unit_idx -lt 3 ]; do
        value=$(awk "BEGIN {printf \"%.2f\", $value/1024}")
        unit_idx=$((unit_idx + 1))
    done
    echo "${value}${units[$unit_idx]}"
}

# 是否启用实时 I/O 负载快照（需要采集 2 秒，默认关闭以加快执行）
# 设为 "true" 可开启第 10 节实时 I/O 瞬时速率分析
ENABLE_REALTIME_IO="false"

# 颜色开关：输出到 Markdown 文件时无需颜色，终端预览时可开启
# 本脚本默认关闭颜色，保证 Markdown 纯净
# shellcheck disable=SC2034
COLOR_OUTPUT="false"

# 检测操作系统
OS_TYPE=$(uname -s)

# ==============================================================================
# 按系统选择命令 / 工具探测
# 集中定义平台相关命令，后续统一引用，避免散落的裸调用跨平台失效
# ==============================================================================

# ------------------------------------------------------------------------------
# 跨平台超时封装 run_with_timeout <秒> <命令...>
# GNU timeout 优先；macOS 装了 coreutils 则有 gtimeout；都没有则用后台进程+kill 自实现
# ------------------------------------------------------------------------------
if command -v timeout >/dev/null 2>&1; then
    run_with_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
    run_with_timeout() { gtimeout "$@"; }
else
    run_with_timeout() {
        local secs="$1"; shift
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
if [ "$OS_TYPE" = "Darwin" ]; then
    # --- macOS: diskutil / df / mount / du ---
    : # macOS 专有命令在各章节内通过 command -v / OS_TYPE 判定选用
elif [ "$OS_TYPE" = "Linux" ]; then
    # --- Linux: lsblk / blkid / df / smartctl / iostat ---
    : # Linux 专有命令在各章节内通过 command -v / OS_TYPE 判定选用
else
    echo "> ⚠️ 当前系统 ($OS_TYPE) 不是受支持的 Linux/macOS，部分功能可能不可用。" >&3
fi

# 使用临时文件收集报告，避免进程替换的异步/交错问题
TMP_REPORT=$(mktemp)

# 保存原始 stdout，用于末尾恢复并显示报告
exec 3>&1

# 将后续所有输出重定向到临时 Markdown 文件
exec > "$TMP_REPORT"

# ------------------------------------------------------------------------------
# 实时进度提示：打印到 fd3（终端），不进入报告文件
# ------------------------------------------------------------------------------
progress() {
    # $1=当前章节序号 $2=总章节数 $3=章节名
    printf '\r\033[K🔄 [%s/%s] %s ...\n' "$1" "$2" "$3" >&3
}

# 启动横幅（实时打印到终端，不进报告文件）
printf '\n\033[1;32m🚀 磁盘 分析开始\033[0m (共 10 个章节，执行期间会逐章显示进度)\n' >&3

# ==============================================================================
# Markdown 报告头
# ==============================================================================
echo "# 磁盘深度分析报告"
echo ""
if [ "$OS_TYPE" = "Darwin" ]; then
    OS_NAME="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
else
    OS_NAME="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
fi
echo "> **主机名:** $(hostname)  "
echo "> **采集时间:** $(date '+%Y-%m-%d %H:%M:%S')  "
echo "> **报告文件:** \`$REPORT_PATH\`  "
echo "> **操作系统:** ${OS_NAME}  "
echo "> **内核版本:** $(uname -r)  "
echo ""
echo "---"
echo ""

# ==============================================================================
# 1. 磁盘基础信息
# ==============================================================================
progress 1 10 "磁盘基础信息"
echo "## 1. 磁盘基础信息"
echo ""

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS 使用 diskutil list 获取磁盘概览
    echo "### 块设备列表 (diskutil)"
    echo ""
    echo "| 设备 | 类型 | 大小 | 说明 |"
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
        echo "> ⚠️ 无法获取 macOS 块设备列表（diskutil 不可用）"
    fi
    echo ""
    echo "> ℹ️ macOS 不暴露 /sys/block，无法读取 I/O 调度器"
    echo ""
else
    # Linux: lsblk 列出所有块设备，-d 不显示从属关系，-o 指定输出列
    # 关键信息: 设备名、大小、类型(disk/part/lvm)、挂载点、模型
    echo "### 块设备列表"
    echo ""
    echo "| 设备名 | 容量 | 类型 | 旋转介质 | 型号 | 挂载点 |"
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
    echo "### I/O 调度器"
    echo ""
    echo "| 设备 | 当前调度器 |"
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
progress 2 10 "磁盘空间使用情况"
echo "## 2. 磁盘空间使用情况"
echo ""
echo "> **评估标准:** 使用率 < 80% 健康，80%~90% 警告，> 90% 危险"
echo ""
# 告警阈值: >80% 警告，>90% 危险
echo "| 文件系统 | 类型 | 总量 | 已用 | 可用 | 使用率 | 挂载点 | 状态 |"
echo "|----------|------|------|------|------|--------|--------|------|"
if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS df -h 格式: Filesystem Size Used Avail Capacity iused ifree %iused Mounted on
    # 第1列=FS, 第2列=Size, 第3列=Used, 第4列=Avail, 第5列=Capacity, 第9列=Mounted on
    df -h 2>/dev/null | grep -E '^/dev/' | while read -r fs size used avail capacity iused ifree ipct mount; do
        use_num=$(echo "$capacity" | sed 's/%//')
        if [ "$use_num" -ge 90 ]; then status="🔴 危险"
        elif [ "$use_num" -ge 80 ]; then status="🟡 警告"
        else status="🟢 健康"
        fi
        # 用 mount 命令补全文件系统类型（macOS 格式：$4 = (apfs,）
        fstype=$(mount | awk -v dev="$fs" -v mnt="$mount" '$1==dev && $3==mnt {gsub(/^\(/,"",$4); gsub(/,$/,"",$4); print $4}')
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "${fstype:--}" "$size" "$used" "$avail" "$capacity" "$mount" "$status"
    done
else
    # Linux df -hT 格式: FS Type Size Used Avail Use% Mounted on
    df -hT 2>/dev/null | grep -E '^/dev/' | while read -r fs type size used avail use mount; do
        use_num=$(echo "$use" | sed 's/%//')
        if [ "$use_num" -ge 90 ]; then status="🔴 危险"
        elif [ "$use_num" -ge 80 ]; then status="🟡 警告"
        else status="🟢 健康"
        fi
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "$type" "$size" "$used" "$avail" "$use" "$mount" "$status"
    done
fi
echo ""

# ==============================================================================
# 3. inode 使用情况（关键！小文件过多会导致 inode 耗尽）
# ==============================================================================
progress 3 10 "inode 使用情况"
echo "## 3. inode 使用情况"
echo ""
echo "> **评估标准:** inode 使用率 < 70% 健康，70%~90% 警告，> 90% 危险"
echo "> **说明:** inode 是文件系统的元数据结构，即使磁盘空间未满，inode 耗尽也会导致无法创建新文件。"
echo ""
echo "| 文件系统 | inode 总量 | 已用 | 可用 | 使用率 | 挂载点 | 状态 |"
echo "|----------|------------|------|------|--------|--------|------|"
if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS df -i 格式: Filesystem 512-blocks Used Available Capacity iused ifree %iused Mounted on
    # 第1列=FS, 第6列=iused, 第7列=ifree, 第8列=%iused, 第9列=Mounted on
    # 总量近似为 iused + ifree
    # shellcheck disable=SC2034
    df -i 2>/dev/null | grep -E '^/dev/' | while read -r fs blocks used avail capacity iused ifree ipct mount; do
        use_num=$(echo "$ipct" | sed 's/%//')
        if [ "$use_num" -ge 90 ]; then status="🔴 危险"
        elif [ "$use_num" -ge 70 ]; then status="🟡 警告"
        else status="🟢 健康"
        fi
        # 计算 inode 总量
        itotal=$((iused + ifree))
        printf "| %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "$itotal" "$iused" "$ifree" "$ipct" "$mount" "$status"
    done
else
    df -i 2>/dev/null | grep -E '^/dev/' | while read -r fs itotal iused iavail iuse mount; do
        use_num=$(echo "$iuse" | sed 's/%//')
        if [ "$use_num" -ge 90 ]; then status="🔴 危险"
        elif [ "$use_num" -ge 70 ]; then status="🟡 警告"
        else status="🟢 健康"
        fi
        printf "| %s | %s | %s | %s | %s | %s | %s |\n" "$fs" "$itotal" "$iused" "$iavail" "$iuse" "$mount" "$status"
    done
fi
echo ""

# ==============================================================================
# 4. 磁盘 I/O 性能采样
# ==============================================================================
progress 4 10 "磁盘 I/O 性能采样"
echo "## 4. 磁盘 I/O 性能采样"
echo ""
# 检查 iostat 是否可用
if ! command -v iostat &> /dev/null; then
    echo "> ⚠️ **未安装 sysstat 包**，无法采集 I/O 数据。"
    echo "> 安装命令: \`yum install -y sysstat\` 或 \`apt install -y sysstat\`"
    echo ""
elif [ "$OS_TYPE" = "Darwin" ]; then
    # macOS iostat 格式不同，输出 tps 和 MB/s 近似指标
    echo "> **评估标准:** macOS iostat 仅提供 KB/t、tps、MB/s，无法直接获取 await/%util"
    echo "> **说明:** tps > 1000 表示高 IOPS，MB/s 持续高位表示高吞吐"
    echo ""
    echo "| 设备 | KB/t(平均) | tps(平均) | MB/s(平均) | 评估 |"
    echo "|------|------------|-----------|------------|------|"
    # iostat -d -w 1 -c 6: 1秒间隔采样6次；解析 macOS 多设备并列格式
    # 第一行为设备名，第二行为表头，后续每行按每设备3列分组
    iostat -d -w 1 -c 6 2>/dev/null | awk '
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
                if (avg_tps > 1000) eval = "🟡 高 IOPS"
                else if (avg_mbs > 100) eval = "🟡 高吞吐"
                else eval = "✅ 正常"
                printf "| %s | %.2f | %.1f | %.2f | %s |\n", d, avg_kbt, avg_tps, avg_mbs, eval
            }
        }
    '
    echo ""
else
    echo "> **评估标准:** await < 10ms 优秀，10~20ms 正常，20~50ms 缓慢，> 50ms 严重瓶颈"
    echo "> **%util:** < 60% 健康，60%~80% 繁忙，> 80% 饱和"
    echo ""
    # iostat -x 1 6: 每秒采样一次，共采样 6 次（持续 6 秒），取最后平均值
    # 关键指标说明:
    #   r/s, w/s: 每秒读写次数 (IOPS)
    #   rkB/s, wkB/s: 每秒读写吞吐量 (带宽)
    #   await: 平均 I/O 等待时间(ms)
    #   %util: 磁盘利用率，接近 100% 表示磁盘忙不过来
    echo "| 设备 | r/s | w/s | rkB/s | wkB/s | await | %util | 评估 |"
    echo "|------|-----|-----|-------|-------|-------|-------|------|"
    iostat -x 1 6 2>/dev/null | tail -n +4 | awk '
        /^Device/ { next }
        /^[a-z]/ {
            eval = ""
            if ($10 > 50) eval = "🔴 IO极慢"
            else if ($10 > 20) eval = "🟡 IO较慢"
            else if ($10 > 10) eval = "🟢 正常"
            else eval = "✅ 优秀"

            if ($11 > 80) eval = eval " 磁盘饱和"
            else if ($11 > 50) eval = eval " 磁盘繁忙"

            printf "| %s | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f%% | %s |\n",
            $1, $4, $5, $6, $7, $10, $11, eval
        }
    '
    echo ""
fi

# ==============================================================================
# 5. 大文件与目录扫描（定位空间占用大户）
# ==============================================================================
progress 5 10 "空间占用大户扫描"
echo "## 5. 空间占用大户扫描"
echo ""
# 扫描各挂载点下占用空间最大的前 10 个目录
# 注意: 会跳过 /proc /sys /dev /run 等虚拟文件系统，避免无意义扫描
echo "### 各挂载点 Top10 大目录"
echo ""
if [ "$OS_TYPE" = "Darwin" ]; then
    MOUNT_COLUMN=9
    DU_DEPTH="-d 1"
else
    MOUNT_COLUMN=6
    DU_DEPTH="--max-depth=1"
fi
for mount in $(df 2>/dev/null | grep -E '^/dev/' | awk -v col="$MOUNT_COLUMN" '{print $col}'); do
    # 跳过虚拟文件系统挂载点
    case "$mount" in
        /proc|/sys|/dev|/run|/boot/efi) continue ;;
    esac

    echo "#### 挂载点: \`$mount\`"
    echo ""
    echo "| 大小 | 目录 |"
    echo "|------|------|"
    # du -k 输出 KB 数值，sort -rn 兼容所有 POSIX sort，再由 hr_kb 转换显示
    # 2>/dev/null 忽略无权限目录的错误；run_with_timeout 避免挂载点扫描耗时过长
    du_output=""
    du_output=$(run_with_timeout 20 du -k $DU_DEPTH "$mount" 2>/dev/null | sort -rn | head -11 | tail -10)
    if [ -n "$du_output" ]; then
        echo "$du_output" | while read -r size_kb path; do
            echo "| $(hr_kb "$size_kb") | $path |"
        done
    else
        echo "> ⚠️ 挂载点 \`$mount\` 目录扫描未返回结果（可能超时或权限不足）"
    fi
    echo ""
done

# 扫描大于 1GB 的大文件，按大小降序
# 使用 timeout 限制扫描时间，maxdepth 限制深度，避免根目录扫描耗时过长
echo "### 大于 1GB 的文件 Top20"
echo ""
echo "| 大小 | 文件路径 |"
echo "|------|----------|"
# run_with_timeout 已按系统自动选择 timeout/gtimeout/自实现，macOS 也能安全限时
run_with_timeout "$LARGE_FILE_SCAN_TIMEOUT" find / -maxdepth 6 -type f -size +1G \
    -not -path "/proc/*" -not -path "/sys/*" -not -path "/dev/*" -not -path "/run/*" \
    2>/dev/null | while read -r file; do
    du -k "$file" 2>/dev/null
done | sort -rn | head -20 | while read -r size_kb path; do
    echo "| $(hr_kb "$size_kb") | $path |"
done
echo ""

# ==============================================================================
# 6. 日志文件专项扫描（日志膨胀是磁盘满的元凶之一）
# ==============================================================================
progress 6 10 "日志文件专项扫描"
echo "## 6. 日志文件专项扫描"
echo ""
echo "### 大于 100MB 的日志文件"
echo ""
echo "| 大小 | 文件路径 |"
echo "|------|----------|"
find /var/log -type f -size +100M 2>/dev/null | while read file; do
    size=$(du -h "$file" 2>/dev/null | awk '{print $1}')
    echo "| $size | $file |"
done
echo ""
echo "### 日志目录总大小"
echo ""
echo "| 路径 | 总大小 |"
echo "|------|--------|"
du -sh /var/log 2>/dev/null | awk '{printf "| %s | %s |\n", $2, $1}'
echo ""

# ==============================================================================
# 7. LVM 逻辑卷信息（如果使用 LVM）
# ==============================================================================
progress 7 10 "LVM 逻辑卷信息"
echo "## 7. LVM 逻辑卷信息"
echo ""
if command -v lvs &> /dev/null && command -v vgs &> /dev/null; then
    echo "> 检测到 LVM 环境"
    echo ""

    echo "### 物理卷 (PV)"
    echo ""
    echo "| 设备 | 卷组 | 容量 | 已用 |"
    echo "|------|------|------|------|"
    pvs 2>/dev/null | grep -v "PV" | awk '{printf "| %s | %s | %s | %s |\n", $1, $2, $5, $6}'
    echo ""

    echo "### 卷组 (VG)"
    echo ""
    echo "| 卷组 | 容量 | 可用 |"
    echo "|------|------|------|"
    vgs 2>/dev/null | grep -v "VG" | awk '{printf "| %s | %s | %s |\n", $1, $6, $7}'
    echo ""

    echo "### 逻辑卷 (LV)"
    echo ""
    echo "| 逻辑卷 | 卷组 | 容量 |"
    echo "|--------|------|------|"
    lvs 2>/dev/null | grep -v "LV" | awk '{printf "| %s | %s | %s |\n", $1, $2, $4}'
    echo ""
else
    echo "> ℹ️ 未使用 LVM 或 lvm2 工具未安装"
    echo ""
fi

# ==============================================================================
# 8. 磁盘健康状态 (SMART)
# ==============================================================================
progress 8 10 "磁盘健康状态 (SMART)"
echo "## 8. 磁盘健康状态 (SMART)"
echo ""
if ! command -v smartctl &> /dev/null; then
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo "> ⚠️ **未安装 smartmontools**，无法读取 SMART 数据。"
        echo "> macOS 安装命令: \`brew install smartmontools\`"
    else
        echo "> ⚠️ **未安装 smartmontools**，无法读取 SMART 数据。"
        echo "> 安装命令: \`yum install -y smartmontools\` 或 \`apt install -y smartmontools\`"
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
            echo "- **SMART 健康状态:** $health"
        else
            echo "- **SMART 健康状态:** 无法读取 (可能是虚拟磁盘/RAID/容器环境/权限不足)"
        fi

        # 读取关键 SMART 属性（温度、重映射扇区、通电时间等）
        # 使用 -A 获取属性表，过滤关键行；使用 $NF 获取最后一列（Raw_Value），
        # 避免不同厂商输出列数不一致导致取值错误
        echo ""
        echo "| 属性 | 原始值 |"
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
progress 9 10 "挂载参数与文件系统特性"
echo "## 9. 挂载参数与文件系统特性"
echo ""
echo "| 设备 | 挂载点 | 类型 | 参数 |"
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
progress 10 10 "Docker 空间占用专项扫描"
echo "## 10. Docker 空间占用专项扫描"
echo ""
if ! command -v docker &> /dev/null; then
    echo "> ℹ️ 未安装 Docker，跳过本节。"
    echo ""
else
    # --- 10.1 Docker 总体空间概览 ---
    echo "### 10.1 Docker 总体空间概览"
    echo ""
    echo "> **说明:** 展示 Docker 镜像、容器、卷、构建缓存的总占用及可回收空间"
    echo ""
    echo "| 类型 | 总量 | 活跃 | 大小 | 可回收 |"
    echo "|------|------|------|------|--------|"
    docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}" 2>/dev/null | tail -n +2 | while IFS=$'\t' read -r type total active size reclaimable; do
        printf "| %s | %s | %s | %s | %s |\n" "$type" "$total" "$active" "$size" "$reclaimable"
    done
    echo ""

    # --- 10.2 Docker 数据目录总大小 ---
    echo "### 10.2 Docker 数据目录总大小"
    echo ""
    # Docker 默认数据目录通常为 /var/lib/docker
    DOCKER_DATA_DIR="/var/lib/docker"
    if [ -d "$DOCKER_DATA_DIR" ]; then
        docker_total=$(du -sh "$DOCKER_DATA_DIR" 2>/dev/null | awk '{print $1}')
        echo "> **Docker 数据目录 \`$DOCKER_DATA_DIR\` 总大小:** ${docker_total:-未知}"
        echo ""
        echo "| 子目录 | 大小 |"
        echo "--------|------|"
        for sub in "$DOCKER_DATA_DIR"/*/; do
            [ -d "$sub" ] || continue
            size_kb=$(du -sk "$sub" 2>/dev/null | awk '{print $1}')
            echo "${size_kb:-0}	$sub"
        done | sort -rn | while IFS=$'\t' read -r size_kb path; do
            dir_name=$(basename "$path")
            printf "| %s | %s |\n" "$dir_name" "$(hr_kb "$size_kb")"
        done
    else
        # 尝试通过 docker info 获取 Docker Root Dir
        DOCKER_ROOT=$(docker info 2>/dev/null | grep "Docker Root Dir" | awk -F': ' '{print $2}')
        if [ -n "$DOCKER_ROOT" ] && [ -d "$DOCKER_ROOT" ]; then
            docker_total=$(du -sh "$DOCKER_ROOT" 2>/dev/null | awk '{print $1}')
            echo "> **Docker 数据目录 \`$DOCKER_ROOT\` 总大小:** ${docker_total:-未知}"
            echo ""
            echo "| 子目录 | 大小 |"
            echo "|--------|------|"
            for sub in "$DOCKER_ROOT"/*/; do
                [ -d "$sub" ] || continue
                size_kb=$(du -sk "$sub" 2>/dev/null | awk '{print $1}')
                echo "${size_kb:-0}	$sub"
            done | sort -rn | while IFS=$'\t' read -r size_kb path; do
                dir_name=$(basename "$path")
                printf "| %s | %s |\n" "$dir_name" "$(hr_kb "$size_kb")"
            done
        else
            echo "> ⚠️ 无法定位 Docker 数据目录（权限不足或非标准路径）"
        fi
    fi
    echo ""

    # --- 10.3 镜像详情（按大小降序 Top15）---
    echo "### 10.3 镜像占用 Top15"
    echo ""
    echo "> **说明:** 展示占用空间最大的镜像，`<none>` 为悬空镜像，可安全清理"
    echo ""
    echo "| 镜像仓库:标签 | 镜像 ID | 大小 | 创建时间 |"
    echo "|---------------|---------|------|----------|"
    docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null | tail -n +2 | head -15 | while IFS=$'\t' read -r repo id size created; do
        # 清理空白标签
        repo=$(echo "$repo" | sed 's/:<none>$/<none>/')
        printf "| %s | %s | %s | %s |\n" "$repo" "$id" "$size" "$created"
    done
    echo ""

    # 悬空镜像数量与大小
    dangling_count=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
    if [ "$dangling_count" -gt 0 ]; then
        echo "> ⚠️ **发现 ${dangling_count} 个悬空镜像（dangling images）**，可通过 \`docker image prune\` 清理"
        echo ""
    fi

    # --- 10.4 容器空间占用 Top10 ---
    echo "### 10.4 容器空间占用 Top10"
    echo ""
    echo "> **说明:** 展示可写层占用空间最大的容器，`SIZE` 列含虚拟大小和实际写入大小"
    echo ""
    echo "| 容器名 | 镜像 | 状态 | 可写层大小 |"
    echo "|--------|------|------|------------|"
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Size}}" 2>/dev/null | tail -n +2 | head -10 | while IFS=$'\t' read -r name image status size; do
        printf "| %s | %s | %s | %s |\n" "$name" "$image" "$status" "$size"
    done
    echo ""

    # --- 10.5 Volume 卷占用 Top15 ---
    echo "### 10.5 Volume 卷占用 Top15"
    echo ""
    echo "> **说明:** 大体积卷通常是数据库、日志持久化等场景，注意区分活跃卷与孤立卷"
    echo ""
    echo "| 卷名称 | 驱动 | 挂载点 |"
    echo "|--------|------|--------|"
    docker volume ls --format "table {{.Name}}\t{{.Driver}}\t{{.Mountpoint}}" 2>/dev/null | tail -n +2 | head -15 | while IFS=$'\t' read -r name driver mountpoint; do
        printf "| %s | %s | %s |\n" "$name" "$driver" "$mountpoint"
    done
    echo ""

    # 统计各卷实际大小（需遍历挂载点）
    echo "#### 卷实际磁盘占用"
    echo ""
    echo "| 大小 | 卷名称 |"
    echo "|------|--------|"
    docker volume ls -q 2>/dev/null | while read -r vol; do
        mountpoint=$(docker volume inspect --format '{{.Mountpoint}}' "$vol" 2>/dev/null)
        if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
            vol_size_kb=$(du -sk "$mountpoint" 2>/dev/null | awk '{print $1}')
            echo "${vol_size_kb:-0}	$vol"
        fi
    done | sort -rn | head -15 | while IFS=$'\t' read -r vol_size_kb vol; do
        printf "| %s | %s |\n" "$(hr_kb "$vol_size_kb")" "$vol"
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
        echo "> ⚠️ **发现 ${orphan_vols} 个孤立卷（未被任何容器引用）**，可通过 \`docker volume prune\` 清理"
        echo ""
    fi

    # --- 10.6 构建缓存 ---
    echo "### 10.6 构建缓存"
    echo ""
    echo "> **说明:** Docker BuildKit 构建缓存可能占用大量空间，可通过 \`docker builder prune\` 清理"
    echo ""
    if docker buildx du 2>/dev/null | head -1 | grep -q .; then
        echo "| 类型 | 大小 | 是否活跃 |"
        echo "|------|------|----------|"
        docker buildx du 2>/dev/null | awk 'NR>1 && NF>=3 {printf "| %s | %s | %s |\n", $1, $2, $3}' | head -15
        echo ""
        # 构建缓存总量
        build_total=$(docker buildx du 2>/dev/null | tail -1)
        echo "> **构建缓存总计:** $build_total"
    else
        # 回退到 docker system df 中的 Build Cache 行
        build_info=$(docker system df 2>/dev/null | grep "Build Cache")
        if [ -n "$build_info" ]; then
            echo "\`\`\`"
            echo "$build_info"
            echo "\`\`\`"
        else
            echo "> ℹ️ 无构建缓存数据（可能未使用 BuildKit 或无缓存）"
        fi
    fi
    echo ""

    # --- 10.7 Docker 日志文件扫描 ---
    echo "### 10.7 Docker 日志文件扫描"
    echo ""
    echo "> **说明:** 容器日志（json-file 驱动）不做轮转时会无限膨胀，是磁盘满的常见原因"
    echo ""

    # 扫描 Docker 日志目录下的大文件
    DOCKER_LOG_DIR=""
    if [ -d "/var/lib/docker/containers" ]; then
        DOCKER_LOG_DIR="/var/lib/docker/containers"
    elif [ -n "$DOCKER_ROOT" ] && [ -d "$DOCKER_ROOT/containers" ]; then
        DOCKER_LOG_DIR="$DOCKER_ROOT/containers"
    fi

    if [ -n "$DOCKER_LOG_DIR" ]; then
        echo "#### 大于 100MB 的容器日志文件"
        echo ""
        echo "| 大小 | 文件路径 |"
        echo "|------|----------|"
        find "$DOCKER_LOG_DIR" -name "*-json.log" -type f -size +100M 2>/dev/null | while read -r logfile; do
            size=$(du -h "$logfile" 2>/dev/null | awk '{print $1}')
            echo "| $size | $logfile |"
        done
        echo ""

        # 日志总大小
        log_total=$(find "$DOCKER_LOG_DIR" -name "*-json.log" -type f -exec du -ck {} + 2>/dev/null | tail -1 | awk '{print $1}')
        if [ -n "$log_total" ] && [ "$log_total" -gt 0 ]; then
            echo "> **容器日志文件总大小:** $(hr_kb "$log_total")"
            echo ""
        fi
    else
        echo "> ⚠️ 无法定位 Docker 容器日志目录（权限不足或非标准路径）"
        echo ""
    fi

    # 列出当前运行容器的日志大小 Top10
    echo "#### 运行中容器日志大小 Top10"
    echo ""
    echo "| 日志大小 | 容器名 | 容器 ID |"
    echo "|----------|--------|---------|"
    docker ps --format "{{.Names}}\t{{.ID}}" 2>/dev/null | while IFS=$'\t' read -r cname cid; do
        log_size=$(docker inspect --format='{{.LogPath}}' "$cid" 2>/dev/null)
        if [ -n "$log_size" ] && [ -f "$log_size" ]; then
            size_kb=$(du -k "$log_size" 2>/dev/null | awk '{print $1}')
            echo "${size_kb:-0}	$cname	$cid"
        fi
    done | sort -rn | head -10 | while IFS=$'\t' read -r size_kb name id; do
        printf "| %s | %s | %s |\n" "$(hr_kb "$size_kb")" "$name" "$id"
    done
    echo ""

    # --- 10.8 清理建议汇总（仅建议，不执行）---
    echo "### 10.8 清理建议（仅供参考）"
    echo ""
    echo "> ⚠️ **安全提示:** 以下命令仅为建议，本脚本**不会自动执行任何删除/清理操作**。"
    echo "> 请运维人员根据实际情况评估后手动执行，执行前务必确认目标环境。"
    echo ""
    echo "| 操作 | 命令 | 风险等级 | 说明 |"
    echo "|------|------|----------|------|"
    echo "| 清理悬空镜像 | \`docker image prune\` | 🟢 低 | 删除所有 \<none\> 标签的悬空镜像 |"
    echo "| 清理未用镜像 | \`docker image prune -a\` | 🟡 中 | 删除所有未被容器引用的镜像（**谨慎**） |"
    echo "| 清理停止的容器 | \`docker container prune\` | 🟢 低 | 删除所有已停止的容器 |"
    echo "| 清理孤立卷 | \`docker volume prune\` | 🟡 中 | 删除未被任何容器挂载的卷（**谨慎，可能丢数据**） |"
    echo "| 清理构建缓存 | \`docker builder prune\` | 🟢 低 | 删除 BuildKit 构建缓存 |"
    echo "| 一键清理全部 | \`docker system prune -a --volumes\` | 🔴 高 | 清理所有未使用资源（**高危，务必确认后执行**） |"
    echo "| 截断大日志文件 | \`truncate -s 0 /path/to/log\` | 🟢 低 | 清空指定容器日志而不删除文件 |"
    echo ""
fi

# ==============================================================================
# 11. 实时 I/O 负载快照（默认关闭）
# ==============================================================================
# 通过 ENABLE_REALTIME_IO 变量控制是否执行
# Linux: 读取两次 /proc/diskstats，间隔 2 秒，计算瞬时速率
# macOS: 无 /proc/diskstats，暂不支持
if [ "$ENABLE_REALTIME_IO" = "true" ]; then
    echo "## 11. 实时 I/O 负载快照"
    echo ""
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo "> ℹ️ macOS 暂无 /proc/diskstats 等价物，实时 I/O 快照暂不支持。"
        echo "> 建议直接使用 \`iostat -d -w 1\` 观察瞬时速率。"
    else
        echo "> **说明:** 本节通过 2 秒间隔采样 /proc/diskstats 计算瞬时速率"
        echo ""
        echo "| 设备 | 读扇区/秒 | 写扇区/秒 |"
        echo "|------|-----------|-----------|"

        # 第一次采样
        cat /proc/diskstats 2>/dev/null | awk '$3 ~ /^[a-z]/ {print}' | while read -r line; do
            dev=$(echo "$line" | awk '{print $3}')
            read1=$(echo "$line" | awk '{print $6}')
            write1=$(echo "$line" | awk '{print $10}')
            echo "$dev $read1 $write1"
        done > /tmp/diskstats_before

        sleep 2

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
                # 计算 2 秒内的速率（扇区数差 / 2秒）
                read_iops=$(( (read2 - read1) / 2 ))
                write_iops=$(( (write2 - write1) / 2 ))
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
echo "---"
echo ""
echo "## 附录：分析建议"
echo ""
echo "将此报告粘贴给大模型时，可附加以下提示词："
echo ""
echo '```'
echo "请分析以下磁盘报告，重点关注："
echo "1. 是否有挂载点使用率超过 85% 或 inode 使用率超过 80%"
echo "2. I/O await 是否超过 20ms，%util 是否接近 100%"
echo "3. 哪些目录或文件是空间占用大户，是否可以清理"
echo "4. SMART 状态是否正常，是否有坏扇区预警"
echo "5. Docker 空间占用是否合理，是否有大量悬空镜像、孤立卷或膨胀日志"
echo "6. 给出具体的清理命令或扩容建议"
echo '```'
echo ""
echo "> 📄 **报告已保存至:** \`$REPORT_PATH\`"

# ==============================================================================
# 报告尾部结束：将临时文件同时输出到终端和 REPORT_PATH
# ==============================================================================
# 恢复原始 stdout，然后将临时文件同步输出到终端和 REPORT_PATH
# 使用 cat + tee 替代异步的进程替换，避免输出交错
exec 1>&3
exec 3>&-
cat "$TMP_REPORT" | tee "$REPORT_PATH"
rm -f "$TMP_REPORT"

# 完成提示（实时打印到终端）
printf '\033[1;32m✅ 分析完成\033[0m 报告已保存至: %s\n' "$REPORT_PATH" >&3

echo ""
echo "✅ 磁盘分析报告已生成: $REPORT_PATH"

# ==============================================================================
# 使用说明:
# 1. 直接运行: ./disk_analyzer.sh
#    输出同时显示在终端并写入 Markdown 文件
# 2. 开启实时 I/O: ENABLE_REALTIME_IO=true ./disk_analyzer.sh
# 3. 修改输出路径: REPORT_PATH=/var/log/report.md ./disk_analyzer.sh
# 4. 配合 crontab 定时执行，直接生成 Markdown 供后续分析
# ==============================================================================
