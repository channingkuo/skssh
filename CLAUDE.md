# CLAUDE.md — skssh

> 项目专属配置。全局规范见 `~/.claude/CLAUDE.md`，已自动加载，无需重复。

---

## 项目信息

**目标**：开发一个 Emacs 插件，让用户可以在 Emacs 中方便地管理 SSH 连接（增删改查主机配置、一键连接、管理密钥等）
**技术栈**：Emacs Lisp
**项目阶段**：MVP 开发
**初始化**：2026-04-21

---

## 快速命令

```bash
# 在 Emacs 中加载插件（开发调试）
# M-x load-file RET skssh.el RET

# 运行测试（ERT）
emacs -batch -l ert -l skssh.el -l skssh-test.el -f ert-run-tests-batch-and-exit

# 字节编译
emacs -batch -f batch-byte-compile skssh.el

# 生成 autoloads
emacs -batch --eval "(update-file-autoloads \"skssh.el\" t \"skssh-autoloads.el\")"
```

---

## 架构概览

```
skssh/
├── skssh.el              ← 主入口，autoload 定义，用户命令
├── skssh-core.el         ← 核心逻辑（连接管理、配置读写）
├── skssh-ui.el           ← UI 层（tabulated-list, transient 菜单等）
├── skssh-config.el       ← 配置文件解析（~/.ssh/config 兼容）
├── skssh-test.el         ← ERT 单元测试
├── skssh-pkg.el          ← MELPA 包描述
└── README.org            ← 文档（MELPA 规范，org 格式）
```

**数据流**：用户命令 → skssh.el → skssh-core.el → SSH 进程 / ~/.ssh/config

---

## 关键约定（项目特有）

- 所有公开命令以 `skssh-` 为前缀，内部函数以 `skssh--` 为前缀
- 配置存储在 `~/.emacs.d/skssh/` 或遵循 `user-emacs-directory`
- 兼容 Emacs 27.1+，不使用 28+ 独有 API 除非有兼容层
- 依赖尽量精简：优先使用 Emacs 内置库（`comint`、`term`、`tramp`）
- 连接底层优先使用 TRAMP，避免重造轮子

---

## 重要决策记录

| 决策 | 选择 | 放弃的方案 | 原因 |
|------|------|-----------|------|
| SSH 连接后端 | TRAMP | 自定义 process | TRAMP 已内置、功能完整 |
| UI 框架 | tabulated-list-mode | magit-section | 更轻量，内置 |
| 配置格式 | ~/.ssh/config 兼容 | 独立 JSON/YAML | 复用现有配置，零迁移成本 |

---

## 禁止事项

- 不直接 shell-command 调用 ssh，统一走 TRAMP 或 process-based API
- 不在 global-map 上绑定快捷键，只在 skssh-mode-map 内绑定
- 不引入需要编译的外部 C 扩展

---

## Memory 位置

| 文件 | 内容 | 更新方式 |
|------|------|----------|
| `.claude/docs/progress.md` | 当前快照 | `/checkpoint` 覆盖更新 |
| `.claude/docs/memory/YYYY-MM-DD.md` | 工作日志 | `/checkpoint` 追加 |
| `.claude/docs/postmortem/` | 复盘记录 | `/postmortem` 写入 |
| `~/.claude/projects/skssh/memory/` | auto memory | Claude 自动维护 |

---

## superpowers skill 文档位置

| skill | 文档 | 保存路径 |
|-------|------|----------|
| `superpowers:brainstorming` | 设计文档 (spec document) | `.claude/docs/superpowers/specs/` |
| `superpowers:writing-plans` | 实现计划文档 | `.claude/docs/superpowers/plans/` |

---

## git

在一次大任务中可能有许多小任务，不要在完成一个小任务后就要求 `git add <files>` 和 `git commit -m <message>`。要在当前大任务全部完成后再一次性提交，而且需要把相关的 `.claude/docs` 中的文件一起提交。如果有一些单次任务完成后比较独立的可以询问是否要提交 git。

---

## plan 计划文件保存位置

每次生成 plan 时，把 plan 文件保存到 `.claude/plan/` 下面。方便直接在项目目录中查看计划。

*由 `/init-project` 生成于 2026-04-21。*
