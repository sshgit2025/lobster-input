"""
nodes 包 — Agent 各意图处理节点。

每个节点对应一种 IntentType，接收 PipelineContext 执行相应业务逻辑，
并直接修改 ctx 的 result / action_type 字段，供 AgentPipeline 后续组装响应。

节点列表：
  TranscribeNode  — 语音转文字（复用第1种快捷键流程逻辑）
  RewriteNode     — 改写选中文本（复用第2种快捷键流程逻辑）
  SearchNode      — 联网搜索查询 + Markdown 格式化
  OpenClawOnNode  — 开启 OpenClaw 会话标记
  OpenClawOffNode — 关闭 OpenClaw 会话标记
  OpenClawNewSessionNode — 开启新的 OpenClaw 客户端会话
"""
