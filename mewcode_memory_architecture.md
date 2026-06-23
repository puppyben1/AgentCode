# MewCode 记忆系统架构

## 总览

MewCode 的记忆分为四层，从短到长：

```
┌─ 每轮对话上下文 ─────────────────────────────────────────────┐
│  instructions (MEWCODE.md)    ← 启动时一次性注入              │
│  auto memories (memories.md)  ← 跨 session 持久化，LLM 自动提取│
│  recall memories (目录 .md)   ← LLM 选择器按需召回            │
│  session records (jsonl)      ← 实时落盘，可 resume            │
│  compact summary              ← 接近窗口上限时 LLM 压缩        │
└───────────────────────────────────────────────────────────────┘
```

---

## 1. 短期记忆 — Session 磁盘持久化

**代码**: `mewcode/memory/session.py`

每次对话都作为一个 **Session** 存储，数据位于 `.mewcode/sessions/` 目录。

### 文件结构

| 文件 | 用途 |
|------|------|
| `{session_id}.jsonl` | 消息记录，每行一条 JSON |
| `{session_id}.meta` | 元数据（标题、消息数、token 数、时间戳） |

### SessionRecord 类型

```python
class RecordType(str, Enum):
    SYSTEM_PROMPT   = "system_prompt"    # 系统提示（不重放）
    USER            = "user"             # 用户消息
    ASSISTANT       = "assistant"        # 助手消息（含 tool_use blocks）
    TOOL_RESULT     = "tool_result"      # 工具调用结果
    COMPRESSION     = "compression"      # 旧版压缩标记
    COMPACT_BOUNDARY = "compact_boundary" # Layer-2 压缩边界标记
```

### 关键机制

**实时落盘**
- 每轮对话即时通过 `session.append(message)` 写入 JSONL（`session.py:375-379`）
- `append()` 同步更新 meta 中的 `message_count`、`last_active`、标题

**Resume 恢复**（`session.py:498-528`）
- 下次启动读取完整 JSONL，调用 `records_to_messages()` 重建 Message 列表
- 兼容 tool_use ↔ tool_result 配对的无损往返

**Compact Boundary**（`session.py:150-195`）
- 压缩后将摘要 + 保留的尾部消息内联进一条 `compact_boundary` record
- Resume 时只从最后一个 boundary 开始重放，之前的前缀保留在磁盘上但不再发送给 LLM
- `make_compact_boundary(summary, keep_messages)` 构建
- `parse_compact_boundary(record)` 解析

**消息链校验**（`session.py:290-308`）
- `validate_message_chain()` 确保 tool_use 和 tool_result 配对完整
- 只重放到最后一个完整配对点，截断不完整的悬挂消息

---

## 2. 中期记忆 — 上下文自动压缩（Layer 2 Compact）

**代码**: `mewcode/context/manager.py`

当对话 token 数接近模型 context window 上限时自动触发。

### 常量配置

| 常量 | 值 | 含义 |
|------|----|------|
| `KEEP_RECENT_TURNS` | 10 | 保留最近 N 轮（仅裁旧工具结果时用）|
| `KEEP_RECENT_TOKENS` | 10,000 | 压缩时尾部保留的 token 预算 |
| `MIN_KEEP_MESSAGES` | 5 | 压缩时至少保留的消息数 |
| `KEEP_MAX_TOKENS` | 40,000 | 尾部保留的 token 硬上限 |
| `MIN_SUMMARIZE_PREFIX_TOKENS` | 2,000 | 前缀低于此值不值得摘要 |
| `AUTO_COMPACT_SAFETY_MARGIN` | 13,000 | 自动压缩的安全边距 |
| `MANUAL_COMPACT_SAFETY_MARGIN` | 3,000 | 手动压缩的安全边距 |

### 压缩策略

1. 前缀超出 `KEEP_RECENT_TOKENS` 且超过 `MIN_SUMMARIZE_PREFIX_TOKENS` 时触发
2. 尾部保留原文（至少 `MIN_KEEP_MESSAGES` 条，累计不超过 `KEEP_MAX_TOKENS`）
3. 前缀发送给 LLM 生成摘要
4. 产出 `CompactBoundary(summary, keep_messages)` 上交给 session 层持久化

### 工具结果裁剪（三层）

| 层级 | 阈值 | 策略 |
|------|------|------|
| Pass 1 — 单条超限 | 50,000 字符 | 完整内容落盘到 `.mewcode/session/tool-results/`，原位置替换为预览链接 |
| Pass 2 — 聚合超限 | 200,000 字符 | 按轮次均匀裁剪旧的 tool_result |
| Pass 3 — 陈旧裁剪 | 保留最近 10 轮 | 超出的轮次：结果 >2048 字符截断为 200 字符预览 |

### 触发位置

`agent.py:473-494`，每轮 `agent.run()` 的主循环中：

```python
compact_result = await auto_compact(conversation, ...)
if isinstance(compact_result, CompactEvent):
    # 重新注入 instructions 和 memories
    conversation.inject_long_term_memory(self.instructions_content, mem)
```

---

## 3. 长期记忆 — Auto Memory（`memories.md`）

**代码**: `mewcode/memory/auto_memory.py`

跨 session 持久化的自动记忆，LLM 驱动提取。

### 存储位置

| 层级 | 路径 | 内容分类 |
|------|------|----------|
| 用户级 | `~/.mewcode/memories.md` | 用户偏好、纠正反馈 |
| 项目级 | `<project>/.mewcode/memories.md` | 项目知识、参考资料 |

### 提取流程

1. **触发**: agent 每轮对话结束后异步调用 `_extract_memories()`（`agent.py:613`）
2. **增量**: 基于 `_last_extraction_msg_count` 只处理新增消息，避免重复
3. **Prompt**: 将当前 `memories.md` 完整内容 + 新增对话发送给 LLM
4. **分类**: LLM 按要求输出四类记忆（用户偏好 / 纠正反馈 / 项目知识 / 参考资料）
5. **写入**: `_write_memories()` 按分类拆分为用户级和项目级两个文件

### 记忆格式

```markdown
### 用户偏好
- 变量命名用 snake_case
- commit message 用英文

### 纠正反馈
- 项目实际是 Python 而非 Go

### 项目知识
- 使用 uv 作为包管理器

### 参考资料
- 文档地址：https://...
```

### 注入时机

- 每次 `agent.run()` 启动时（`agent.py:438-439`）
- 每次 auto_compact 后重新注入（`agent.py:491-494`）
- 作为 `<system-reminder>` 包裹注入到对话顶部

```python
conversation.inject_long_term_memory(self.instructions_content, memory_content)
```

---

## 4. 长期记忆 — Recall 选择器（目录化记忆召回）

**代码**: `mewcode/memory/recall.py`

基于目录的 `.md` 文件记忆 + LLM 选择器做 relevance 判断。

### 存储位置

| 层级 | 路径 |
|------|------|
| 用户级 | `~/.mewcode/memory/*.md` |
| 项目级 | `<project>/.mewcode/memory/*.md` |

### Frontmatter 格式

```markdown
---
name: 某某记忆
description: 简短描述
type: user  # user | feedback | project | reference
---

正文内容...
```

### 召回流程（`app.py:1166-1208`）

1. **扫描**: `scan_memory_files()` 遍历两个目录，最多 200 个 `.md` 文件（排除 `MEMORY.md`）
2. **解析**: 读每个文件的前 30 行提取 frontmatter（name/description/type）
3. **过滤**: 排除已在前几轮召回过的文件（`already_surfaced`）
4. **选择**: 将候选清单发给独立的小 LLM 调用（selector），让模型选出最多 5 个相关的
5. **注入**: `render_reminder()` 将选中文件内容拼接，以 `<system-reminder>` 注入对话
6. **保护**: 8 秒超时 + 异常兜底，失败返回空字符串不阻塞主流程

### 时效性警告

记忆超过 1 天时自动附加警告（`recall.py:91-101`）：

```
This memory is N days old. Memories are point-in-time observations, not live
state — claims about code behavior or file:line citations may be outdated.
Verify against current code before asserting as fact.
```

### 触发时机

在 `app.py:1224-1227`，用户发送消息时异步预取：

```python
prefetch_task = asyncio.create_task(
    self._prefetch_relevant_memories(text)
)
```

---

## 5. 指令层 — MEWCODE.md

**代码**: `mewcode/memory/instructions.py`

### 加载顺序

```python
paths = [
    root / "MEWCODE.md",              # 项目根目录
    root / ".mewcode" / "MEWCODE.md", # 项目配置目录
    home / ".mewcode" / "MEWCODE.md", # 用户全局配置
]
```

三个文件通过 `\n---\n` 拼接，最先找到的优先级最高。

### @include 机制

支持在 `MEWCODE.md` 中使用 `@include <relative-path>` 引用外部文件：

- 路径安全性检查：只允许项目根目录内的路径
- 最大递归深度：5 层
- 引用的文件同样支持嵌套 `@include`

### 注入方式

作为 system prompt 中的 `# mewcodeMd` 块注入，带有强烈指令：

```
Codebase and user instructions are shown below. Be sure to adhere to these
instructions. IMPORTANT: These instructions OVERRIDE any default behavior
and you MUST follow them exactly as written.
```

---

## 6. 注入到对话的完整流程

`conversation.py:154-180` (`inject_long_term_memory`)：

```python
def inject_long_term_memory(self, instructions: str, memories: str) -> None:
    sections = []
    if instructions:
        sections.append("# mewcodeMd\n" + instructions)
    if memories:
        sections.append("# autoMemory\n" + memories)
    sections.append(f"# currentDate\nToday's date is {date.today().isoformat()}.")
    body = "\n\n".join(sections)
    wrapped = (
        "<system-reminder>\n"
        "As you answer the user's questions, you can use the following context:\n"
        + body
        + "\n      IMPORTANT: this context may or may not be relevant to your tasks."
    )
```

最终注入到对话中的 `<system-reminder>` 块结构：

```
<system-reminder>
As you answer the user's questions, you can use the following context:
# mewcodeMd
...instructions...

# autoMemory
...memories...

# currentDate
Today's date is 2026-06-18.

      IMPORTANT: this context may or may not be relevant to your tasks.
</system-reminder>
```

Recall 记忆则作为独立的 `<system-reminder>` 注入，包裹 `render_reminder()` 的输出。

---

## 完整生命周期

```
启动
  │
  ├─ load_instructions(work_dir)          → MEWCODE.md 加载
  ├─ MemoryManager(work_dir)              → 初始化 auto memory
  ├─ SessionManager(work_dir)             → 创建或恢复 session
  │
  ├─ agent.run()
  │   ├─ inject_long_term_memory()        → instructions + auto memories 注入
  │   └─ 主循环每轮:
  │       ├─ 检查是否需要 auto_compact     → 前缀摘要 + 尾部保留
  │       ├─ 重新注入 long_term_memory     → 压缩后刷新
  │       └─ 异步 _extract_memories()     → 增量提取新记忆
  │
  ├─ 用户发送消息
  │   └─ _prefetch_relevant_memories()    → 异步召回相关记忆
  │
  └─ 对话中持续注入
      └─ <system-reminder>                → 每轮附带的记忆上下文
```

**一句话总结**：短期的靠 session 磁盘记录 + 实时 LLM 压缩，长期的靠 LLM 自动提取 + 按需召回，没有向量数据库，全链路基于 LLM 做 relevance 判断。
