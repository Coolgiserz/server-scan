#!/usr/bin/env bash
#
# server-scan 一键安装 / 卸载脚本
#
# 用法:
#   ./install.sh                安装到 /usr/local/bin（默认）
#   ./install.sh --prefix DIR   安装到指定目录
#   ./install.sh --uninstall    卸载（仅删除本工具安装的文件）
#   ./install.sh --help         查看帮助
#
# 退出码: 0=成功  1=参数错误  2=权限/写入失败
set -euo pipefail

PREFIX="/usr/local/bin"
MODE="install"

while [ $# -gt 0 ]; do
    case "$1" in
    --prefix)
        PREFIX="${2:-}"
        shift 2
        ;;
    --uninstall)
        MODE="uninstall"
        shift
        ;;
    --help | -h)
        sed -n '2,11p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    *)
        echo "未知参数: $1（用 --help 查看用法）" >&2
        exit 1
        ;;
    esac
done

if [ -z "$PREFIX" ]; then
    echo "错误: --prefix 需要一个目录参数" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 本工具安装到 PREFIX 的文件集合：
# - 扁平安装：入口 server-scan 与全部 core 脚本（按文件名落到 PREFIX 根）
# - 子树安装：lib/ 共享库（保持 lib/... 相对结构，运行时经 SCRIPT_DIR/lib 加载）
# 不递归拷贝无关文件、不修改 PATH 文件；uninstall 仅删除这些已知文件
FLAT_FILES=("server-scan")
for f in core/*.sh; do
    [ -e "$f" ] || continue
    FLAT_FILES+=("$f")
done
LIB_FILES=()
while IFS= read -r f; do
    [ -n "$f" ] && LIB_FILES+=("$f")
done < <(find lib -type f 2>/dev/null || true)

_install_one() {
    # $1=源相对路径 $2=目标路径；内容一致则跳过（幂等），否则复制并赋可执行
    local src="$SCRIPT_DIR/$1" dst="$2"
    [ -f "$src" ] || {
        echo "错误: 源文件缺失 $src" >&2
        exit 2
    }
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "  已是最新，跳过 $(basename "$dst")"
        return 0
    fi
    cp "$src" "$dst" 2>/dev/null && chmod +x "$dst" 2>/dev/null
}

if [ "$MODE" = "uninstall" ]; then
    echo "正在从 $PREFIX 卸载 server-scan ..."
    rc=0
    for f in "${FLAT_FILES[@]}"; do
        target="$PREFIX/$(basename "$f")"
        if [ -e "$target" ] && ! rm -f "$target" 2>/dev/null; then
            echo "  无法删除 $target（权限不足？）" >&2
            rc=2
        fi
    done
    for f in "${LIB_FILES[@]}"; do
        target="$PREFIX/$f"
        if [ -e "$target" ] && ! rm -f "$target" 2>/dev/null; then
            echo "  无法删除 $target（权限不足？）" >&2
            rc=2
        fi
    done
    # 清除可能由系统产生的隐藏残留（如 macOS 的 .DS_Store / ._ 资源叉文件），
    # 再删除已空的 lib 子目录（不影响其他内容）
    find "$PREFIX/lib" -mindepth 1 \( -name '.DS_Store' -o -name '._*' \) -delete 2>/dev/null
    rmdir "$PREFIX/lib/i18n" "$PREFIX/lib" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        echo "卸载完成"
    else
        echo "卸载出现错误" >&2
        exit $rc
    fi
    exit 0
fi

echo "正在安装 server-scan 到 $PREFIX ..."
if [ ! -d "$PREFIX" ]; then
    if mkdir -p "$PREFIX" 2>/dev/null; then
        echo "  已创建目录 $PREFIX"
    else
        echo "错误: 无法创建 $PREFIX（请检查权限，或改用 --prefix 指定可写目录）" >&2
        exit 2
    fi
fi
if [ ! -w "$PREFIX" ]; then
    echo "错误: 目录 $PREFIX 不可写（可加 sudo，或改用 --prefix 指定可写目录）" >&2
    exit 2
fi

rc=0
for f in "${FLAT_FILES[@]}"; do
    target="$PREFIX/$(basename "$f")"
    if ! _install_one "$f" "$target"; then
        echo "  无法写入 $target（权限不足？）" >&2
        rc=2
    else
        echo "  已安装 $(basename "$f")"
    fi
done
for f in "${LIB_FILES[@]}"; do
    target="$PREFIX/$f"
    mkdir -p "$(dirname "$target")" 2>/dev/null || true
    # lib 为被 source 的共享库，无需可执行位；_install_one 仍会 chmod +x（无害）
    if ! _install_one "$f" "$target"; then
        echo "  无法写入 $target（权限不足？）" >&2
        rc=2
    else
        echo "  已安装 $f"
    fi
done

if [ "$rc" -eq 0 ]; then
    echo "安装完成。运行 'server-scan --help' 验证（若 $PREFIX 不在 PATH，请把其加入 PATH）。"
else
    echo "安装出现错误" >&2
    exit $rc
fi
