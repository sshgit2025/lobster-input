# ASR 用户词典纠偏方案

后端已废弃公共大词库召回，纠偏链路只使用用户手工配置的词典，并结合 ASR provider 的热词/context biasing 和 LLM 后处理。

## 设计原则

- 用户词典是最高优先级参考，但不是强制替换表。
- 纠偏只在 ASR 文本疑似音近误识别时提供候选 hints。
- 公共大词库不参与在线请求，避免额外模型调用、存储 IO 和误召回。
- 多语言纠偏按 adapter 分流：中文使用拼音和技术词音译，英文/拉丁文字使用 phonetic code 与技术上下文门控，其他脚本只做保守文本近似。
- LLM 只消费少量高质量候选，不负责从海量公共词库中盲猜。

## 数据存储

用户词典存储在 MongoDB `hotwords` 集合：

| 字段 | 含义 |
|---|---|
| `id` | 词条 ID |
| `user_email` | 用户邮箱 |
| `word` | 用户配置的标准词 |
| `created_at` | 创建时间 |

唯一索引：`(user_email, word)`。

## 执行链路

### V1 文件 ASR

1. 后端读取用户词典。
2. 将系统默认热词和用户词典合并到 ASR prompt / provider vocab。
3. ASR 返回最终文本。
4. `ASRCorrectionService.run()` 根据 ASR language 和文本脚本选择 adapter。
5. 中文 adapter 生成拼音 key 和技术词音译 key，例如 `癌症特 -> Agent`。
6. 拉丁/英文 adapter 使用 Metaphone、Soundex、NYSIIS 和上下文门控，例如在 `git status` 场景允许 `get -> Git`，但普通 `get latest report` 不产生候选。
7. 非中英文脚本默认保守处理，避免在缺少可靠 G2P 的语言上误纠。
8. RapidFuzz 计算相似度，生成少量 `[User Dictionary Correction Hints]`。
9. LLM 根据上下文决定是否采用候选。

### V2 实时 ASR

1. WebSocket 建连时，实时 ASR provider 读取用户词典并注入 provider hotwords/corpus。
2. provider 返回 final text。
3. v2 文本管线复用同一套用户词典发音召回和 LLM 后处理。

## 性能边界

用户词典默认上限由 `HOTWORD_MAX_COUNT` 控制。纠偏阶段只处理最长 500 字 ASR 文本、最多 100 个 token、最多输出 8 组候选 hints。无用户词典时直接返回。用户词典和 adapter 索引在进程内短 TTL 缓存，词典 CRUD 会主动失效当前进程缓存。

本地评测脚本：

```bash
cd /opt/lobster-backend
PYTHONPATH=/opt/lobster-backend \
  /opt/lobster-backend/venv/bin/python3.12 scripts/evaluate_asr_correction_retrieval.py
```

## 运维说明

- `.env` 只需要 `ASR_CORRECTION_ENABLED=true/false` 控制后处理开关。
- 不再需要公共词库导入、公共索引预热或独立纠偏模型节点。
- 管理端只保留“用户词典”审计和删除页面，公共词库页面已移除。
