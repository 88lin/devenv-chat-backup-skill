
## 坑 15：restore 时跳过数据库导致会话标题丢失（最严重）

**现象**：容器重建后，DevEnv 界面里所有会话只显示 ID（如 `01KZY1TGE2HW8Q2N51FHJT966W`），
看不到中文标题，无法辨认哪个会话是哪个。几千个会话根本没法选。

**根因**：会话标题存在 `memory.db` 的 `sessions` 表的 `title` 字段里，不在 `.jsonl` 文件里。
DevEnv 界面从数据库读标题。但 restore 时检测到 AI 进程在运行就**直接跳过了数据库恢复**，
只恢复了 `.jsonl` 文件。容器重建后数据库是空的，所以界面只能显示文件名（即会话 ID）。

**解决方案**：不跳过，改为**安全合并**。用 SQLite 的 `ATTACH DATABASE` + `INSERT OR REPLACE`
把备份的 `sessions` 和 `messages` 表合并到当前数据库。这是增量操作，不会覆盖活跃数据，
AI 运行时也能安全执行。

```bash
# 核心合并逻辑
ATTACH DATABASE '/tmp/backup.db' AS bk;
INSERT OR REPLACE INTO sessions SELECT * FROM bk.sessions;        -- 含标题
INSERT OR IGNORE INTO messages (...) SELECT ... FROM bk.messages;  -- 含消息
DETACH DATABASE bk;
```

**教训**：跳过（skip）是最简单的安全策略，但会导致数据丢失。合并（merge）才是正确的策略，
既安全又不丢数据。

## 坑 4：sessions.title 有标题但界面仍显示 ID（messages 表为空）

**现象**：容器重建后，`sessions` 表的 `title` 字段明明有中文标题（通过 `merge_session_db` 合并了），
但 DevEnv 界面仍然显示会话 ID，不显示标题。

**根因**：DevEnv 界面**不是从 `sessions.title` 读显示名**，而是从 `messages` 表的第一条 `role='user'` 
消息的 `content_json` 中提取显示名。容器重建后 `messages` 表为空（备份时只有活跃会话的消息在 
`messages` 表里），所以界面找不到显示名，回退为显示 session ID。

**调查过程**：
1. 查 `sessions.title` → 10/12 有标题 ✅
2. 查 `messages` 表 → 只有 2 个会话有消息 ❌
3. 查备份数据库的 `messages` 表 → 也只有 2 个会话 → **备份时就不全**
4. 查 `.jsonl` 文件 → 所有会话都有完整消息 ✅

**解决方案**：新增 `import_messages_from_jsonl()` 函数，在 restore 时从 `.jsonl` 文件补充 
`messages` 表。对每个没有 messages 的会话，读取 `.jsonl` 文件，转换格式后插入 `messages` 表。

```python
# .jsonl 格式：{"TurnId":..., "Role":0, "Content":"用户消息", ...}
# messages 表格式：content_json = {"ID":..., "Role":"user", "Parts":[{"Text":{"Text":"用户消息"}}], ...}
```

**关键教训**：
- DevEnv 的数据存储是**双轨制**：`.jsonl` 文件（完整）+ `messages` 表（可能不全）
- 界面读 `messages` 表，不读 `.jsonl` 文件
- 只合并 `sessions` 表不够，必须同时确保 `messages` 表有数据
- `.jsonl` 文件是消息的**权威来源**，`messages` 表是索引/缓存
