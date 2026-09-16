# 语音识别与填充/浮窗决策技术设计

> 本文档说明客户端从快捷键触发、录音、识别到文本回填的完整链路，重点记录弱音频增强和"判定权反转"填充决策的设计原因、实现边界和维护要点。

## 目录

- [1. 总体目标](#1-总体目标)
- [2. 端到端流程](#2-端到端流程)
- [3. 语音录制设计](#3-语音录制设计)
- [4. 音频增强管线](#4-音频增强管线)
- [5. 识别请求链路](#5-识别请求链路)
- [6. 事务回填设计](#6-事务回填设计)
- [7. 维护与复刻清单](#7-维护与复刻清单)

---

## 1. 总体目标

客户端要在任意 macOS 应用中完成语音输入：用户按快捷键开始录音，再次触发后识别音频，并把结果写回原输入框。

设计重点不是追求某个单一 API，而是保证功能稳定：弱麦克风能被录到、识别请求只提交一次、识别结果最多回填一次、失败时展示结果浮窗。

关键约束：

- 不抢走宿主 App 的焦点。
- 不永久覆盖用户剪贴板。
- 不把同一识别结果写入多次。
- 明确不是输入框时不盲目粘贴。

---

## 2. 端到端流程

核心入口是 `AppHotKeyHandler`。它负责串联权限检查、目标捕获、录音、上传、历史记录和回填。

```
快捷键
  -> 捕获 targetPid + 挂载 FillVerifier / selectionSnapshot / 剪贴板上下文
  -> AudioRecorder 录制并增强音频
  -> APIClient.processAudio 上传
  -> handleAction 分发
  -> TextFillEngine 决策并填充（快探 + 盲填确认）
```

`targetPid` 必须在录音开始时捕获，因为识别返回时前台焦点可能已经变化。回填阶段应优先信任触发时的目标，而不是重新解释当前焦点。

`selectionSnapshot` 用来保存选中文本、选区范围和 AX 元素。它服务于 rewrite 上下文（选中文本随请求发给后端）和选区恢复，不参与填充写入。

---

## 3. 语音录制设计

录音由 `AudioRecorder` 管理，底层使用 `AVAudioEngine`、`AVAudioConverter` 和 `AVAudioFile`。

设计目标：

- 复用预热后的引擎，降低首次录音延迟。
- 统一输出 16kHz 单声道 PCM WAV。
- tap 回调直接写文件，避免大块内存缓存。
- 停止录音后只产生一个音频文件。

`stopRecording()` 会先把状态切为 `.processing`，再移除 tap 并返回录音文件 URL。`AppHotKeyHandler` 额外用单飞标记防止并发 stop/upload。

这个设计解决的问题是：快捷键停止、最大时长通知、浮窗状态变化可能在相近时间发生，必须保证同一段录音只进入一次上传和回填。

---

## 4. 音频增强管线

弱麦克风场景由 `AudioEnhancementPipeline` 处理。它是一个有序策略管线，在写入文件前处理每个 `AVAudioPCMBuffer`。

默认顺序：

1. `DCOffsetRemovalStrategy`
2. `SpeechClarityStrategy`
3. `AdaptiveGainStrategy`
4. `PeakLimiterStrategy`

`DCOffsetRemovalStrategy` 解决廉价麦克风常见的直流偏移问题，避免后续增益把偏移也一起放大。它使用平滑估计值从采样中扣除低频偏移。

`SpeechClarityStrategy` 使用轻量预加重增强语音清晰度。它只在 RMS 高于噪声地板时生效，避免把静音或底噪处理成“人声”。

`AdaptiveGainStrategy` 是弱音量的核心补偿。它根据原始 RMS 计算目标增益，并通过 attack/release 平滑变化，避免音量忽大忽小。

`PeakLimiterStrategy` 是最后一道保护。它在增强后限制峰值，避免过度放大导致削波，从而保护识别质量和用户听感。

注意：音频增强只改变写入文件的 buffer，不创建额外文件，不触发额外上传。因此它不应影响识别请求次数。

---

## 5. 识别请求链路

`processRecord` 负责上传音频。它校验本地音频文件存在后，调用 `APIClient.shared.processAudio`。

请求参数包括：

- `fileURL`：录音文件。
- `operation`：快捷键对应意图。
- `selectedText`：录音时选中文本。
- `clipboardHistory`：录音前剪贴板上下文。
- `fastMode`：转写加速开关。

响应中的 `actionType` 决定客户端行为。`paste` 进入 `TextFillEngine` 填充决策，`clarify`、`showMarkdown`、`tip` 和 openclaw 类动作不写入输入框。

历史记录先进入 processing，接口成功后更新 transcript/result/actionType。若用户取消 processing，本次返回会被忽略，避免取消后又回填。

---

## 6. 填充/浮窗决策设计（判定权反转）

核心需求只有一条：焦点在输入框 → 填充；否则 → 浮窗。

旧方案靠"事前求证"（ManualAX 子树遍历 + 秒级轮询 + Cmd+C 探测）推断可编辑性，慢且不稳定。新方案反转判定权：**先轻量快探，不确定时直接盲填，用 AX 通知被动确认写入结果**。

核心对象（`Core/TextFilling/`）：

- `FocusProbe`：一跳快探，只查焦点元素本身，150ms IPC 超时，常规 ~1ms。
- `FillVerifier`：AXObserver 通知确认器，录音开始挂载，兼做 Chromium/Electron AX 树预热。
- `TextFillEngine`：唯一决策与执行入口，输出 `filled` / `overlay`。

### 6.1 一跳快探（FocusProbe）

只查询目标 App 的 `AXFocusedUIElement` 一次，不遍历树、不轮询：

1. `AXValue` 可写 → `editable`，直接填充。
2. 已知非输入控件 role（按钮/列表/Group 等）且不可写 → `notEditable`，直接浮窗。
3. `noValue`（无焦点元素）、文本类 role 但不可写（Excel 单元格）、未知 role、AX 持续报错 → `undetermined`，进入盲填确认。

> ⚠️ `noValue` 不能判 `notEditable`：Chrome AX 树未激活时，网页内已聚焦的输入框
> （如 Jira 搜索栏）也返回 noValue，必须靠盲填确认区分（2026-06-11 已踩坑修复）。

回填阶段优先使用录音开始捕获的 `targetPid`，不重新信任前台 App。AX 报错时隔 50ms 重试一次，覆盖 App 切换瞬间树未就绪的场景。

### 6.2 填充手段与盲填确认

写入手段只有一条：**Cmd+V**，请求级 `PasteboardSnapshot` 保存/恢复剪贴板。有选区时粘贴天然覆盖选区，因此 transcribe / rewrite / agent 的 `paste` 动作共用同一条写入路径，行为完全一致。

> ⚠️ 禁止用 AX `kAXSelectedText` 原位替换选中文本：Chromium/Electron 对该写入返回
> success 但实际不生效，会造成"既不替换也不浮窗"的静默失败（2026-06-11 已踩坑回退）。

`undetermined` 时执行盲填确认：`FillVerifier.arm()` → Cmd+V → 等待 `AXValueChanged` / `AXSelectedTextChanged` 通知（≤600ms，实测正向延迟 ~150-220ms）。收到通知判 `filled`；超时则先做**二次快探复查**——此刻焦点元素可编辑 ⇒ 刚才的 Cmd+V 必然已写入该焦点元素 ⇒ 判 `filled`；否则恢复剪贴板判 `overlay`。

> ⚠️ 超时无通知 ≠ 未写入：浏览器 AX 树未建好时没有任何节点能发通知，盲填实际生效
> 却会被误判失败，造成"既填充又浮窗"双重输出（2026-06-11 Jira 踩坑，靠二次复查兜底）。

`FillVerifier` 在录音开始时挂载到目标 App 并预热 AX 树：

- `AXManualAccessibility=true`：Electron 响应；Chrome/访达返回错误，忽略。
- `AXEnhancedUserInterface=true`：Chrome 响应（VoiceOver 同款信号，返回 err-25208 但实际生效）。
  实测 Chrome 冷态下焦点查询永远 noValue 且单纯查询不会触发建树；设置该属性后
  Jira 等重型页面约 2.3s 建好树，录音时长天然覆盖。`detach()` 时设回 false，
  收窄对 Chrome 窗口拖拽行为的副作用窗口。

### 6.3 浮窗兜底

`TextFillEngine` 返回 `overlay` 时，`AppHotKeyHandler.attemptFillResult` 调用 `ResultOverlayWindowController.shared.show(text:)`，保证识别结果不丢失。

注意：禁止"回填后再 Cmd+C 读回验证"。该动作改变剪贴板、焦点和选区，且很多应用 AX 值读取不可靠；写入确认只信 AX 通知（被动信号），不做主动读回。

---

## 7. 维护与复刻清单

复刻到其它程序时，应优先复刻以下设计，而不是照搬某个单一策略。

- 快捷键事件必须能拦截，避免宿主 App 提前破坏选区。
- 录音开始时捕获目标 PID、挂载 `FillVerifier`、抓选区快照和剪贴板上下文。
- 录音 stop/upload 必须单飞。
- 音频增强只处理 buffer，不改变上传次数。
- 填充/浮窗判定统一走 `TextFillEngine`，禁止在其它位置各自判断可编辑性。
- Cmd+V 必须请求级保存/恢复剪贴板。
- 明确不可编辑时弹浮窗；"不确定"必须经盲填确认，不得无条件当作可填充。

常见误区：

- 回填时重新信任前台 App。识别返回时焦点可能已经变化，必须用录音时捕获的 `targetPid`。
- 把 AX value 主动读回当作写入成败依据。很多应用 AX 状态更新不可靠，只信 AX 通知。
- 用事前深度探测（树遍历/轮询/Cmd+C）推断可编辑性。慢且不稳定，已被快探+盲填确认取代。

建议诊断日志：

- 录音开始：targetPid、verifier attach 结果、snapshot source。
- 停止录音：audioURL、文件大小、enhancement summary。
- 上传完成：recordId、actionType、transcript/result 长度。
- 填充完成：probe verdict、resolution（filled/overlay + reason）。

上线前验证：

- 原生输入框可回填。
- 浏览器输入框（普通输入框/地址栏/富文本）可回填。
- Cursor/VSCode 输入框可回填。
- Excel/WPS 单元格经盲填确认可回填。
- 非输入控件（网页空白/文件列表等）会弹出结果浮窗。
- 用户剪贴板在 Cmd+V 与盲填后恢复。
- 弱麦克风输入能产生可见音量并完成识别。
- 同一次识别结果不会重复填入。
