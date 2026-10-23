# AGENTS.md

server-scan 是一个纯 Bash 的服务器健康巡检/诊断工具集，运行于 Linux (CentOS/Ubuntu/Debian/RHEL) 与 macOS，自动生成 Markdown 报告与告警 JSON，并支持飞书 webhook 推送。无任何第三方运行时依赖（仅用系统自带 bash/awk/sed/grep 等；shellcheck/shfmt 仅用于 pre-commit）。

## 常用命令

```bash
./server-scan --help            # 帮助
./server-scan overview          # 系统瓶颈总览
./server-scan cpu-mem           # CPU/内存深度分析
./server-scan disk              # 磁盘空间/IO/健康分析
./server-scan network           # 网络专项排查
./server-scan security          # 杀毒/HIDS/EDR 部署检测
./server-scan container         # 容器/镜像健康监控（需显式配置目标，不纳入 all）
./server-scan all               # 依次运行 overview~security 5 个扫描（不含 container）
./server-scan cron              # 交互式配置 crontab 定时巡检
./server-scan config <migrate|upgrade|check|show>   # 配置迁移/升级/校验/查看

# 公共选项（所有扫描子命令通用，由 lib/cli.sh 统一解析）
#   -o/--output PATH   -c/--config FILE   -q/--quiet   --json（隐含 quiet）
#   --no-color         --lang LANG        --notify / --no-notify
#   --notify-channel   --webhook URL      --notify-test

# 语法检查（改动任何 .sh 后必做）
bash -n server-scan && for f in core/*.sh lib/*.sh lib/i18n/*.sh; do bash -n "$f" || exit 1; done
shellcheck --severity=warning server-scan core/*.sh lib/*.sh   # 如已安装
shfmt -i 4 -d server-scan core/*.sh lib/*.sh                    # 如已安装
./server-scan config check                                      # 配置文件规范校验（违规 exit 1）
```

没有单元测试框架；验证方式为实际运行子命令（可加 `--json` 检查 JSON 输出结构）与 `bash -n`/shellcheck。

## 架构

- `server-scan` — 唯一入口，按子命令 `exec` 到 `core/*.sh`；根目录不放其他可执行文件。
- `core/` — 各专项分析器（`sys_overview.sh`、`cpu_mem_analyzer.sh`、`disk_analyzer.sh`、`network_analyzer.sh`、`security_scanner.sh`、`container_monitor.sh`）、定时任务（`cron_setup.sh`）、配置管理（`config_manager.sh`）。每个脚本通过 `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` 定位项目根。
- `lib/` — 共享库，所有函数以 `ss::` 为公开前缀、`_ss_` 为私有前缀：
  - `common.sh` — i18n 加载、`ss::msg`/`ss::msgf`、报告框架（`ss::report_begin/end`、`ss::progress`）、日志（`ss::log_*`/`ss::die`）、`ss::json_escape`、配置加载（`ss::load_config`/`ss::config_init`/`ss::config_reload`）。
  - `cli.sh` — `ss::parse_common_args` 统一解析公共选项。
  - `alerts.sh` — 结构化告警收集与 JSON 读写（`ss::alert_add`、`ss::alerts_write_json`）。
  - `notify.sh` — 飞书推送（`ss::notify_init`/`ss::notify_send`/`ss::notify_test`）。
  - `i18n/zh_CN.sh`、`i18n/en_US.sh` — 消息目录，键名规范 `MSG_<模块>_<类别>_<名称>`；语言解析顺序 `SS_LANG > LANG > zh_CN`，缺失回退中文。
- `output/` — 运行产物（报告 + 告警 JSON），按脚本标识分子目录，不入库（已 gitignore）。
- 配置文件：`server-scan.conf`（统一配置，gitignore）、`notify.conf`（含密钥，chmod 600，gitignore）、`*.conf.example`（入库的示例）。

### 配置体系（重要）

- 所有扫描脚本共用一份 `server-scan.conf`，各脚本按「前缀」取自己关心的键（如 `DISK_`、`INODE_`、`CONTAINER_`）。
- 分析脚本中的固定调用顺序（不可颠倒）：
  1. `ss::config_init DISK_ INODE_ ...`（解析命令行前）
  2. `ss::parse_common_args "$@"`
  3. `ss::config_reload`（使 `-c/--config` 生效）
- `ss::load_config` 是引号感知的安全解析器：只接受 `^[A-Z][A-Z0-9_]*$` 键名；拒绝含 `` ` $ ( ) ; `` 的值；用 `printf -v` 赋值而非 `eval`。
- 通知配置独立于统一配置：`ss::notify_init` 按 `NOTIFY_CONFIG` → `$CONFIG_FILE` → `notify.conf` → `~/.server-scan/` → `/etc/` 顺序找候选文件，且**候选文件必须实际包含 `NOTIFY_` 开头的键**才会被接受（防止统一配置劫持查找）。
- `config upgrade` 会先把「注释与变量同行」的旧格式规范化为注释独占一行，再用 example 中的「注释块 + 键值」补齐缺失键；改动前自动备份为 `*.conf.bak`。

## 约定与坑（本项目特有）

1. **配置文件注释必须独占一行，写在变量上方**。禁止 `KEY=value # comment` 行内注释；值本身含 `#` 时必须加引号（如 `KEY="a #b"`）。`config check` 会检测违规。
2. **单引号包裹的 awk 程序内不能出现字面量单引号**（会提前截断 awk 程序，且 `bash -n` 检查不出来）。需要引号字符时用 `sprintf("%c", 34)`（双引号）/ `sprintf("%c", 39)`（单引号）构造，参见 `core/config_manager.sh` 中 `_ss_conf_inline_comment_count`。
3. **所有用户可见文本必须走 i18n**：新增消息时在 `lib/i18n/zh_CN.sh` 与 `en_US.sh` 同步添加键，代码中用 `ss::msg KEY` / `ss::msgf KEY args...`，不要硬编码字符串。
4. `set -euo pipefail` 是默认严格模式；新增管道/命令时注意失败分支（惯用 `|| true` 或显式判断）。
5. `ss::config_init` 内部经命令替换赋值 `CONFIG_FILE`，子 shell 中的变量赋值不会传出——依赖旧配置回退提示等逻辑必须写在函数本体（现有代码已如此，勿改坏）。
6. 报告输出经 `exec 3>&1` 重定向（`ss::report_begin` 建立 fd3）；在报告流程建立前（如 `ss::config_init` 阶段）不能用依赖 fd3 的 `ss::log_warn`，需直接写 stderr。
7. 缩进 4 空格（shfmt `-i 4`）；提交前 pre-commit 会跑 shellcheck（warning 级）+ shfmt + 通用检查。历史上存在用 `--no-verify` 跳钩子的提交，正常流程不应跳过。
8. 敏感文件不入库：`server-scan.conf`、`notify.conf`、`*.conf.bak`、`output/` 均在 `.gitignore`；不要把真实 webhook/密钥写进任何入库文件。
9. 新增分析器时：脚本放 `core/`，入口 `server-scan` 的 `case` 中注册子命令，产物路径用 `ss::default_report_path <标识>`，告警用 `ss::alert_add` 收集，帮助文本键加入两个语言包。
10. 推送 main 分支会触发 GitHub Actions 自动生成日期版本号 Release（`vYYYY.MM.DD-N`），无需手动打 tag。

## Git

- 提交信息用中文、简明描述改动（仓库历史如「注释独占一行约定 + 解析器修复」风格）。
- 仅在用户明确要求时提交/推送。
