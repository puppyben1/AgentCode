# MewCode

终端 AI 编程助手 — 支持多 Provider、多 Agent、MCP 协议、会话持久化与记忆分层。

## 功能特性

- **多 AI Provider** — 支持 Anthropic、OpenAI 及兼容协议，可自由切换模型
- **Agent 系统** — 内置多 Agent 协作（Fork、Verification、Task Manager），支持自定义 Agent
- **MCP 协议** — 完整支持 Model Context Protocol，可接入外部工具与数据源
- **记忆分层架构** — 指令注入 → 自动记忆提取 → 按需召回 → 会话回放，四层记忆管理
- **TUI 终端界面** — 基于 Textual 框架，交互流畅
- **会话持久化** — 对话自动落盘为 JSONL，支持断点恢复 (resume)
- **Slash 命令系统** — 可扩展的命令注册与解析
- **上下文窗口管理** — 四层 fallback 自动解析 context window，兼容主流模型

## 技术栈

- **语言** — Python 3.11+
- **TUI** — Textual
- **AI SDK** — Anthropic + OpenAI
- **配置** — YAML
- **包管理** — uv + Hatchling

## 快速开始

### 安装

```bash
# 安装依赖
uv sync
```

### 配置

在 `~/.mewcode/config.yaml` 或项目目录 `.mewcode/config.yaml` 中配置 AI Provider：

```yaml
providers:
  - name: default
    protocol: anthropic
    base_url: https://api.anthropic.com
    model: claude-sonnet-4-5-20250929
    api_key: ${ANTHROPIC_API_KEY}
```

### 运行

```bash
python -m mewcode
# 或通过入口脚本
./mewcode.cmd
```

## 项目结构

```
mewcode/
├── mewcode/               # 主包
│   ├── agent.py           # Agent 主循环
│   ├── agents/            # Agent 子系统（fork、loader、parser、trace 等）
│   ├── commands/          # Slash 命令系统
│   ├── config.py          # 配置加载与校验
│   ├── context/           # 上下文管理器
│   ├── memory/            # 记忆系统（session、recall、auto memory）
│   ├── client.py          # AI Provider 客户端
│   └── app.py             # TUI 应用入口
├── tests/                 # 测试
├── pyproject.toml         # 项目配置
├── index.html             # 官网介绍页
└── uv.lock                # 依赖锁文件
```

## 开发

```bash
# 运行测试
uv run pytest
```
