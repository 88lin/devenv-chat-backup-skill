
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
