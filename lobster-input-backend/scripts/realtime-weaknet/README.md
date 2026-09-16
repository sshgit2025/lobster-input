# 实时流式识别弱网复现与续传回归脚本

模拟安卓端实时识别 WebSocket 客户端与 uat 后端通信,用于弱网断连问题复现与
"静默重连续传"策略回归(2026-07 弱网 "Software caused connection abort" 排查产物)。

## 准备

```bash
python3 -m venv venv && ./venv/bin/pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org websockets
# 语料(16k 16bit mono wav)
say -o speech.wav  --data-format=LEI16@16000 "今天天气不错,我们下午一起去公园散步吧,顺便买一杯咖啡喝一喝。"
say -o speech2.wav --data-format=LEI16@16000 "这个周末我打算先去超市买一些新鲜的水果和蔬菜,然后回家给家人准备一顿丰盛的晚餐,吃完晚饭之后我们全家一起在客厅看一部很有意思的电影。"
```

登录使用 uat 固定验证码白名单账号(见服务器 `.env` 的 `AUTH_FIXED_VERIFY_CODE_*`),
token 缓存在 `token.cache`。

## repro_weaknet.py — 单场景复现

```bash
./venv/bin/python repro_weaknet.py baseline   # 正常流式识别全流程
./venv/bin/python repro_weaknet.py abort      # 中途 RST 断开(服务端日志出现 connect 无 finished 特征)
./venv/bin/python repro_weaknet.py weaknet    # 本地代理中途切断链路,观察客户端 send 原始 socket 错误
./venv/bin/python repro_weaknet.py resume     # 朴素续传(无尾巴重放,接缝会丢字,用于对照)
./venv/bin/python repro_weaknet.py resume2    # 尾巴重放 + 重叠裁剪续传(安卓端已实现方案)
```

## resume_matrix.py — 续传矩阵回归

严格同构安卓 `RealtimeResume`(前缀冻结 + 1.5s 已发送尾巴重放 + 间隙音频缓冲 +
归一化重叠裁剪拼接),跑 前/中/后段断点 × 0.3s/1.5s 间隙 × 单/双断连 × 两条语料,
每个场景与不断连基线做归一化 diff,自动检出重复/缺失/错乱:

```bash
./venv/bin/python resume_matrix.py
```

2026-07-17 首轮结果:10/10 场景 PERFECT,重连耗时 534~1424ms(3s 窗口内)。
改动安卓端 `RealtimeResume.mergeWithOverlap` 或后端 realtime bridge 后应重跑本脚本。
