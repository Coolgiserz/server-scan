# 贡献指南

感谢参与 server-scan 的改进！本工具是纯 Bash 实现，没有第三方运行时依赖，但提交前需要完成代码质量检查。

## 开发环境

```bash
# 1. Fork 并克隆
git clone https://github.com/Coolgiserz/server-scan.git
cd server-scan

# 2. 安装 pre-commit（用于本地自动跑代码质量检查）
pip install pre-commit
pre-commit install

# 3. 安装 Shell 静态检查与格式化工具（CI 与本地一致）
#    CentOS/RHEL:
yum install -y ShellCheck shfmt        # 或先 yum install -y epel-release
#    Ubuntu/Debian:
apt install -y shellcheck shfmt
#    macOS:
brew install shellcheck shfmt
```

## 质量检查

每次提交前，pre-commit 会自动运行以下检查（亦可在 CI 中复现）：

```bash
# 全量检查（推荐）
pre-commit run --all-files

# 或逐项手动验证
bash -n server-scan && for f in core/*.sh lib/*.sh lib/i18n/*.sh; do bash -n "$f" || exit 1; done
shellcheck --severity=warning server-scan core/*.sh lib/*.sh
shfmt -i 4 -d server-scan core/*.sh lib/*.sh     # -d 仅显示差异；shfmt -i 4 -w 可自动格式化
./server-scan config check                        # 配置文件规范校验（违规 exit 1）
```

- 缩进统一为 4 空格（`shfmt -i 4`）；不得使用 Tab
- 提交前 pre-commit 钩子会执行 ShellCheck（warning 级）+ shfmt + 通用检查（行尾空格、文件末尾换行、YAML 语法、大文件、合并冲突、换行符）。**正常情况下不应使用 `--no-verify` 跳过钩子**
- 敏感文件 `server-scan.conf`、`notify.conf`、`*.conf.bak`、`output/`、`.codebuddy/` 已在 `.gitignore` 中，切勿提交真实配置或密钥

## 编码约定

详见项目根目录的 [`AGENTS.md`](AGENTS.md)（项目的权威约定说明），要点：

- 所有用户可见文本必须走 i18n：新增消息在 `lib/i18n/zh_CN.sh` 与 `en_US.sh` 同步添加键，代码用 `ss::msg KEY` / `ss::msgf KEY args...`，不硬编码字符串
- 新增/修改配置项时，`server-scan.conf.example` 同步补充，且**注释必须独占一行写在变量上方**（禁止行内注释）
- 配置文件解析是引号感知的安全解析器，拒绝含 `` ` $ ( ) ; `` 的值
- 单引号包裹的 awk 程序内不能出现字面量单引号，需要时用 `sprintf("%c", 39)` 构造

## 提交信息规范

采用中文 Conventional Commits 风格：`type(scope): 中文描述`

| type | 用途 |
|------|------|
| feat | 新功能 / 新增能力 |
| fix  | 缺陷修复 |
| refactor | 重构（不改变外部行为） |
| perf | 性能优化 |
| docs | 文档（README、AGENTS.md 等） |
| test | 测试 |
| ci   | CI/工作流（.github/workflows） |
| chore | 杂项维护 |

- scope（可选）取模块名：`disk` / `cpu-mem` / `network` / `security` / `overview` / `container` / `service` / `notify` / `config` / `cron` / `cli` / `alerts` / `common` / `i18n` / `ci`
- 主题行：中文、动词开头、结尾不加句号，建议 ≤ 50 字符
- 破坏性变更：type 后加 `!` 并在正文说明迁移方式
- 联动要求：新增用户可见文本 / 配置项 / 子命令时，对应的 i18n 键、示例配置、入口注册与文档必须放进**同一个提交**，保证提交自洽可运行

## 测试方式

仓库没有单元测试框架，验证方式为实际运行子命令并观察产物：

```bash
# 各子命令可正常生成报告
./server-scan overview
./server-scan disk
./server-scan container --container <名称>

# 用 --json 检查结构化元数据输出
./server-scan overview --json
```

## Pull Request 流程

1. 基于 `main` 创建特性分支：`git checkout -b fix/<短横线描述>` 或 `feat/<短横线描述>`
2. 本地完成修改并通过上方质量检查
3. 提交并推送分支，发起 PR 到 `main`
4. **PR 会触发 `.github/workflows/ci.yml` 的 lint 门禁，必须通过才能合并**
5. 合并进 `main` 后，`.github/workflows/release.yml` 会**自动**基于日期生成版本号并发布 GitHub Release

> ⚠️ 注意：**合入 `main` 即触发公开发布（新 Release）**。若本次改动涉及破坏性变更、配置兼容或大范围重构，请在 PR 描述中说明影响面，并在合并前与相关维护者协调，避免不经意的版本发布。如需仅提交但不发版，可在合并提交信息以 `chore(release)` 开头（CI 会跳过发版）——但常规开发不应依赖此机制。
