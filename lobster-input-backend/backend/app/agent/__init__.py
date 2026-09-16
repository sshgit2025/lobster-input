"""
agent 包 — Agent 意图路由系统。

架构设计：
  IntentType     — 意图枚举（5种 + fallback）
  IntentRouter   — LLM 意图分类器，解析 LLM 输出为 IntentType
  节点模块       — 每种意图对应一个独立的处理节点（nodes/）

扩展方式：
  1. 在 IntentType 中新增枚举值
  2. 在 agent_intent.txt 中补充该意图的描述和示例
  3. 在 nodes/ 下新建对应的节点模块
  4. 在 AgentPipeline 中注册新节点
"""
