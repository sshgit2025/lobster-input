# Windows 端识别结果"填充输入框 / 浮窗展示"决策机制

本文档记录 transcribe / rewrite 识别结束后，判定"当前焦点是否可编辑输入框"并决定
回填还是浮窗的最终机制。设计对齐 Mac 端已验证的 `TextFillEngine`（"判定权反转"）：
**放弃事前遍历求证，改为轻量快探三态；不确定就盲填，用系统被动通知确认写入是否落地，
超时再做一次事后复查兜底。**

## 为什么不做"事前遍历判断"

Electron / Chromium 系应用（Cursor、Codex、浏览器）的无障碍树是**懒激活 + 异步构建**的：
应用刚启动或首次被查询时 UIA 只能拿到空树或容器节点（Pane/Window/Group），
焦点元素、ValuePattern 全都探不出来。任何"遍历元素找输入框"的方案在这类目标上
必然时好时坏。Mac 端曾用同思路（AX 树遍历 + 轮询 + 分 App 特判）反复打补丁失败，
最终整体废弃（见 lobster-input-front `docs/voice-recognition-transaction-fill.md`）。

## 决策流程

入口：`RecordingWorkflow.HandlePasteActionAsync` → `TextTargetService.CommitTextAsync`
→ `SelectedTextService.PasteText`。

1. **入口闸门**（`RecordingWorkflow.ShouldAttemptSystemPaste`）：
   只有录音时上下文快照给出**可靠的"不可编辑"**（`IsEditable == false`）才直接浮窗；
   快照缺失 / 不确定一律进入填充尝试。
2. **确定性快路径**（PasteText 内，按序）：
   - 自身进程 WPF 焦点 → 直接写控件；
   - 终端目标（Windows Terminal / cmd / VSCode 内嵌 xterm 等）→ 终端粘贴通道；
   - 经典 Win32 Edit/RichEdit 且有选区快照 → `EM_REPLACESEL` 原位替换（可同步验证）；
   - 只读目标（`ES_READONLY` / ValuePattern.IsReadOnly / 只读选区快照）→ 直接浮窗。
3. **快探三态**（`ProbeKeyboardCommit`）：
   - 可编辑（快照可编辑 / 原生 Edit / 有系统插入符 / UIA ValuePattern 可写）→
     粘贴送达即信任（`CanAssumeCommitted`，对齐 Mac editable 快路径，不等确认）；
   - 可靠不可编辑（ValuePattern 只读 / 明确交互控件类型）→ 浮窗；
   - **不确定 → 盲填 + 被动确认**。
4. **盲填确认**（三层，任一命中即判填充成功）：
   1. `FillVerifier` 被动事件（600ms 窗口）：UIA Name/Value 属性变化 + TextChanged
      事件（子树范围），以及 WinEvent `EVENT_OBJECT_VALUECHANGE` /
      `EVENT_OBJECT_TEXTSELECTIONCHANGED` / 插入符 `LOCATIONCHANGE(OBJID_CARET)`
      （进程 + 同根窗口双重过滤；经典 Win32 控件的插入符事件无需无障碍激活即可触发）；
   2. UIA 回读文本包含刚写入的前缀（needle）；
   3. **事后复查**：以上都未命中时重新快探一次焦点，若此刻焦点已可编辑，
      则刚送达的 Ctrl+V 必然已被消费，判成功（Mac commit f646837 同款防
      "填充成功又弹浮窗"兜底——冷 Chromium 树粘贴成功也可能不发任何事件）。
5. 仍未确认 → 返回 false → 浮窗展示。**返回值必须与真实结果一致：
   决不"送达即成功"地猜测未知目标，也决不在确认成功后再弹浮窗。**

## 关键工程约束（改动前务必理解）

- **FillVerifier 的 WinEvent 钩子必须挂在专用泵消息线程上**
  （`EnsurePumpDispatcher`）。`WINEVENT_OUTOFCONTEXT` 回调经由挂钩线程的消息队列
  派发；粘贴流程所在的 STA 工作线程在等待确认时 `Thread.Sleep`，钩子若挂在该线程，
  确认窗口内回调永远送不达（这曾是"填了还弹浮窗"的主因之一）。
- **无障碍树预热**：录音开始即 `FillVerifier.Attach(targetWindow)`。
  `AutomationElement.FromHandle` + 事件注册会触发 Chromium 按需激活无障碍
  （WM_GETOBJECT），录音时长天然覆盖树构建时间——等价于 Mac 端设
  `AXEnhancedUserInterface` 预热。scope 元素拿不到时降级为仅 WinEvent，不放弃。
- **`SendInput` 不会重置键盘状态**（MSDN 明确）：默认热键 Alt+Q/W/E，实时模式下
  用户按 Alt 停止后常未松开，注入的 Ctrl+V 会被污染成 Ctrl+Alt+V。
  `SendKeyCombo` 先等修饰键物理松开（≤600ms），再在同一批 SendInput 内
  强制补发遗留修饰键的 KEYUP；组合键的 Ctrl 先按下，掩护裸 Alt/Win 弹起
  不触发菜单/开始菜单（AutoHotkey 掩码键同款技巧）。
- **Pane/Window/Group 不得视为可靠"不可编辑"**：Electron 冷树时焦点就报成这些
  容器类型，真实焦点可能是输入框，必须交给盲填确认。
- **WinEvent 确认只认文本写入的直接迹象**（值变化/选区变化/插入符移动），
  不认 NAMECHANGE/LIVEREGION——聊天页、动态页的无关更新会造成"误判成功"，
  而误判成功（漏浮窗）没有兜底；误判失败（多浮窗）有三层兜底。
  事件还需通过**同根窗口过滤**，防止 explorer 任务栏时钟这类同进程杂音。
- **剪贴板条件恢复**：`RestoreClipboardEventually` 校验序列号/内容仅在
  "仍是我们写入的文本"时才恢复备份，避免覆盖期间用户新复制的内容。

## 曾踩过的坑（不要回退）

- 靠 `snapshot == null → 浮窗` 的入口闸门：Electron 冷树常态就是拿不到快照，
  导致明明聚焦输入框却弹浮窗。
- "送达即成功"（assume committed）+ "验证失败即失败"并存的启发式矩阵：
  前者在未知目标上造成该弹不弹，后者在事件缺失时造成填了还弹（双重输出）。
- 调研结论（2026-07）：Windows 无官方跨进程"焦点是否可编辑"API；
  剪贴板延迟渲染（WM_RENDERFORMAT）确认粘贴被 Win10/11 剪贴板历史
  （cbdhsvc / TextInputHost 立即强制渲染、一次性通知被抢占）证伪，勿再尝试；
  长期最优解是注册 TSF TIP（Win+H 同款机制），工程量大，留作二期。
