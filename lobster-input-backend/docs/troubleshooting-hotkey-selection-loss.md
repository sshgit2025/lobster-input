# 全局快捷键触发时文本选区丢失问题排查手册

> 本文档记录了龙虾输入法（voice-input）在 macOS 上使用全局快捷键触发录音时，宿主应用中已选中文本被自动取消的问题、排查过程和最终解决方案。

## 目录

- [1. 问题描述](#1-问题描述)
- [2. 排查过程与错误方向](#2-排查过程与错误方向)
- [3. 根因分析](#3-根因分析)
- [4. 解决方案](#4-解决方案)
- [5. 关键代码变更](#5-关键代码变更)
- [6. 权限要求](#6-权限要求)
- [7. 经验总结与设计原则](#7-经验总结与设计原则)

---

## 1. 问题描述

- **场景**：用户在任意应用（如 Cursor、VSCode、Safari）中选中一段文本，然后按全局快捷键（如 `Option + E`）触发录音
- **期望行为**：录音浮窗弹出，选中文本保持不变，录音结束后可基于选中文本进行 rewrite 操作
- **实际行为**：按下快捷键的瞬间，选中文本被取消，光标坍缩到选区末尾
- **影响**：rewrite 功能无法获取选中文本，核心业务流程断裂

---

## 2. 排查过程与错误方向

### 2.1 最初怀疑：浮窗抢焦点

最初认为是录音浮窗（`NSPanel`）弹出时抢走了宿主应用的焦点，导致选区丢失。

**尝试的修复**：
- 使用 `NSPanel` + `.nonactivatingPanel` 样式
- 设置 `isFloatingPanel = true`、`becomesKeyOnlyIfNeeded = true`
- App 激活策略设为 `.prohibited` / `.accessory`

**结果**：焦点不再丢失（光标留在宿主应用），但选区仍然被取消。

### 2.2 第二个方向：Accessibility API 恢复选区

既然选区会丢失，尝试在丢失前保存快照，丢失后通过 AX API 恢复。

**尝试的修复**：
- 创建 `SelectionSnapshot` 结构体保存选中文本、`CFRange`、`AXUIElement`
- 在录音开始前调用 `SelectedTextReader.snapshot()` 保存
- 浮窗弹出后调用 `SelectedTextRestorer.restore()` 恢复
- 添加多次延迟探针（20ms/80ms/180ms/350ms）反复尝试恢复

**结果**：`snapshot()` 在快捷键触发后立即调用时，已经拿不到选区了——选区在我们的代码执行之前就已经丢失。

### 2.3 关键发现：问题不在我们的程序

通过 `DebugTrace` 文件日志发现：
- 快捷键被 `HotKeyManager` 正确识别
- 但 `SelectedTextReader.snapshot()` 报告 "no focused element"
- 宿主应用仍然是 `frontmostApplication`，但选区已经消失

用户进一步验证：**随便按任何不属于我们配置的组合键，都会导致选中文本被取消**。这是 macOS 系统的默认行为——键盘事件传递到宿主应用后，应用会处理这些按键并坍缩选区。

---

## 3. 根因分析

### 事件传递链

```
用户按下 Option+E
    ↓
macOS WindowServer 生成 CGEvent (keyDown)
    ↓
CGEventTap 回调（我们的 HotKeyManager）
    ↓  ← 如果是 .listenOnly，事件继续传递
    ↓
宿主应用收到 keyDown 事件
    ↓
宿主应用处理按键 → 选区坍缩（Option+E 是 macOS 死键，输入 ´ 字符）
```

### 根因

`CGEventTap` 使用 `.listenOnly` 选项时，只能**旁听**事件，不能阻止事件传递给宿主应用。快捷键事件（如 `Option+E`）被原封不动地传递给前台应用，导致：

1. `Option+E` 触发 macOS 死键输入（accent ´），选区被替换为字符
2. 其他组合键也会被宿主应用解释为编辑操作，导致选区坍缩

**这不是我们程序的 bug，而是 macOS 事件传递机制的正常行为。** 保持选区需要在事件链中**拦截并吞掉**匹配的快捷键事件。

---

## 4. 解决方案

将 `CGEventTap` 从 `.listenOnly`（被动旁听）改为 `.defaultTap`（主动过滤），在回调中**同步判断**是否命中已配置快捷键：

- **命中** → 返回 `nil`（吞掉事件，宿主应用不会收到）
- **未命中** → 返回原事件（放行，不影响正常按键）

```
用户按下 Option+E
    ↓
macOS WindowServer 生成 CGEvent (keyDown)
    ↓
CGEventTap 回调（defaultTap 模式）
    ↓  命中快捷键 → 返回 nil → 事件被吞掉
    ↓  宿主应用完全不知道这个按键发生过
    ↓
我们的 handler 异步触发 → 录音开始 → 选区完好无损
```

---

## 5. 关键代码变更

### 5.1 HotKeyManager.swift — 核心改动

**文件**：`voice-input/Core/HotKey/HotKeyManager.swift`

#### a) CGEventTap 选项

```swift
// 之前（被动旁听，无法拦截）
options: .listenOnly

// 之后（主动过滤，可返回 nil 吞掉事件）
options: activeFilter ? .defaultTap : .listenOnly
```

#### b) 回调改为同步判断

```swift
// 之前：异步到主线程判断（太晚了，事件已经传递给宿主应用）
callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
    let mgr = ...
    DispatchQueue.main.async { mgr.handleCGEvent(...) }
    return Unmanaged.passUnretained(event)  // 总是放行
}

// 之后：同步判断，命中则吞掉
callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
    let mgr = ...
    return mgr.handleCGEventSync(type: type, event: event)
    // 命中返回 nil，未命中返回 passUnretained(event)
}
```

#### c) 线程安全的配置读取

CGEventTap 回调在非主线程执行，但配置存储在 `@MainActor` 隔离的属性中。引入 `ConfigStore`（`nonisolated` + `NSLock`）实现线程安全的配置快照：

```swift
nonisolated private final class ConfigStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [HotKeyCombo: HotKeyConfig] = [:]
    nonisolated func update(_ configs: [HotKeyCombo: HotKeyConfig]) { ... }
    nonisolated func read() -> [HotKeyCombo: HotKeyConfig] { ... }
}
```

#### d) keyDown + keyUp 配套吞掉

吞掉 `keyDown` 时必须同时吞掉对应的 `keyUp`，否则宿主应用会收到一个孤立的 keyUp 事件。

#### e) flagsChanged 谨慎处理

修饰键的 `flagsChanged` 事件不能随意吞掉，否则宿主应用的 Option/Shift 等状态会卡住。只在"单独修饰键释放且命中快捷键"时才吞掉。

#### f) 优雅降级

如果 `.defaultTap` 创建失败（权限不足），自动回退到 `.listenOnly`：

```swift
if installCGEventTap(activeFilter: true) { ... return }
// 降级
if installCGEventTap(activeFilter: false) { ... return }
```

---

## 6. 权限要求

| 模式 | 所需权限 | 说明 |
|------|---------|------|
| `.listenOnly` | 输入监控（Input Monitoring） | 只能旁听，不能拦截 |
| `.defaultTap` | 辅助功能（Accessibility） | 可拦截/修改/吞掉事件 |

- 检查辅助功能权限：`AXIsProcessTrusted()`
- 检查输入监控权限：`CGPreflightListenEventAccess()`
- `.defaultTap` 失败时的常见原因：未在 **系统设置 → 隐私与安全 → 辅助功能** 中授权
- 使用 Apple 开发者证书签名后，cdhash 稳定，权限只需授权一次

---

## 7. 经验总结与设计原则

### 7.1 核心教训

> **全局快捷键应用必须拦截事件，而不仅仅是监听。**
>
> `.listenOnly` 模式下，快捷键事件会同时被我们的程序和宿主应用处理，导致不可预期的副作用（选区丢失、死键输入、快捷键冲突等）。

### 7.2 排查方法论

1. **先确认问题边界**：是我们的代码导致的，还是系统行为？用户通过"按任意组合键都会丢失选区"这一实验，快速定位到系统层面
2. **文件日志优于系统日志**：macOS 的 `os.log` / `log stream` 在高频事件场景下不可靠，自定义文件日志（`DebugTrace`）更稳定
3. **CGEventTap 回调必须同步返回**：不能用 `DispatchQueue.main.async` 延迟决定是否吞掉事件，必须在回调中同步完成判断

### 7.3 设计检查清单

- [ ] CGEventTap 使用 `.defaultTap` 而非 `.listenOnly`
- [ ] 回调中同步判断是否命中，命中返回 `nil`
- [ ] `keyDown` 和 `keyUp` 配套吞掉
- [ ] `flagsChanged` 只在必要时吞掉（避免修饰键状态卡住）
- [ ] 配置读取线程安全（CGEventTap 回调在非主线程）
- [ ] `.defaultTap` 失败时优雅降级到 `.listenOnly`
- [ ] 启动日志确认 `"defaultTap installed OK"`






