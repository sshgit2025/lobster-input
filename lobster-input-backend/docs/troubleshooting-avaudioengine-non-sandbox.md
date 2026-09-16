# AVAudioEngine 非沙盒环境录音问题排查手册

> 本文档记录了龙虾输入法（voice-input）在 macOS 非沙盒环境下使用 AVAudioEngine 进行麦克风录音时遇到的系列问题、根因分析和最终解决方案。适用于未来排查类似问题时参考。

## 目录

- [1. 背景与前提](#1-背景与前提)
- [2. 为什么不能使用沙盒](#2-为什么不能使用沙盒)
- [3. 核心问题：iounit 配置变更导致录音失败](#3-核心问题iounit-配置变更导致录音失败)
- [4. 问题演进时间线](#4-问题演进时间线)
- [5. 关键日志与诊断方法](#5-关键日志与诊断方法)
- [6. 最终解决方案](#6-最终解决方案)
- [7. entitlements 配置要点](#7-entitlements-配置要点)
- [8. 权限管理要点](#8-权限管理要点)
- [9. 常见故障速查表](#9-常见故障速查表)
- [10. 开发/测试/上线环境一致性](#10-开发测试上线环境一致性)

---

## 1. 背景与前提

- **项目**：龙虾输入法（voice-input），macOS 原生 SwiftUI 应用
- **功能**：通过全局快捷键触发麦克风录音，录制 16kHz 单声道 AAC 音频，上传后端进行 Whisper 语音识别
- **音频框架**：AVAudioEngine + AVAudioConverter
- **签名方式**：Apple 开发者证书自动签名（TeamID: YOUR_TEAM_ID）
- **运行环境**：非沙盒（ENABLE_APP_SANDBOX = NO）

---

## 2. 为什么不能使用沙盒

本应用需要以下三项 macOS 系统权限：

| 权限 | 用途 | 沙盒下是否可用 |
|------|------|---------------|
| 麦克风（Microphone） | 录音 | ✅ 可用 |
| 输入监控（Input Monitoring / CGEventTap） | 全局快捷键监听 | ❌ 不可用 |
| 辅助功能（Accessibility） | 读取选中文本、模拟 Cmd+V 粘贴 | ❌ 不可用 |

**结论**：App Sandbox 与 CGEventTap 和 Accessibility API 根本不兼容。必须关闭沙盒。

### 沙盒残留的隐患

即使将 `com.apple.security.app-sandbox` 设为 `false`，**这个 key 的存在本身**可能影响系统对 App 的行为判断。正确做法是**彻底删除该 key**，entitlements 文件保持空 dict：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

---

## 3. 核心问题：iounit 配置变更导致录音失败

### 3.1 现象

- 按快捷键触发录音，悬浮窗正常弹出
- 音浪动画完全不动（audioLevel 始终为 0）
- 停止录音后上传的文件为 0 字节
- 后端报错 `Audio file is too short`

### 3.2 根因

非沙盒 App 首次创建 `AVAudioEngine` 并访问 `inputNode` 时，系统需要与硬件协商音频格式。这个协商是**异步的**，经历多次格式变更：

```
时序 1: 创建 AVAudioEngine，访问 inputNode
时序 2: inputNode.inputFormat(forBus: 0) 返回 0 ch, 0 Hz（无效）
时序 3: 系统开始协商，中间状态 48000 Hz
时序 4: installTap 使用 48000 Hz 格式
时序 5: engine.start() 成功
时序 6: 系统最终确定硬件格式为 24000 Hz（麦克风真实采样率）
时序 7: 系统检测到 tap 格式(48000) ≠ 硬件格式(24000)
时序 8: 系统触发 "iounit configuration changed"，强制停掉 engine
时序 9: 发送 AVAudioEngineConfigurationChange 通知
```

**关键差异**：沙盒模式下系统自动处理格式协商，App 无感知。非沙盒模式下必须手动处理。

### 3.3 为什么在旧 engine 上重装 tap 不行

配置变更后，旧 engine 对象内部的 audio graph 仍缓存了错误的格式信息。即使 `removeTap` → `installTap`（用新格式），engine 内部 `Initialize` 仍用缓存的旧格式校验：

```
Error, formats don't match!
Input HW format: <AVAudioFormat: 1 ch, 24000 Hz, Float32>
tap format: <AVAudioFormat: 1 ch, 48000 Hz, Float32>
```

**必须销毁旧 engine，创建全新实例。**

---

## 4. 问题演进时间线

| 阶段 | 症状 | 尝试的修复 | 结果 |
|------|------|-----------|------|
| 1. 沙盒开启 | 辅助功能和输入监控无法工作 | 关闭 App Sandbox | 权限恢复，但录音出问题 |
| 2. 关闭沙盒后 | 录音无声音，0 字节文件 | `engine.prepare()` 后再读 `outputFormat` | 仍然失败 |
| 3. 格式不匹配 | `formats don't match` 错误 | `installTap` 传 `format: nil` | 首次可能成功，但 engine 被停后无法恢复 |
| 4. 配置变更 | engine 启动后立即被系统停掉 | 监听通知后在旧 engine 上重装 tap | 旧 engine 缓存了错误格式，仍然失败 |
| 5. **最终方案** | — | 等待配置变更 → 销毁旧 engine → 创建新 engine | **成功** |

---

## 5. 关键日志与诊断方法

### 5.1 查看 AVAudioEngine 相关日志

```bash
# 查看最近 5 分钟的 engine 日志
/usr/bin/log show --predicate 'process contains "voice-input" AND (
  eventMessage contains "Engine" OR
  eventMessage contains "config change" OR
  eventMessage contains "format" OR
  eventMessage contains "tap" OR
  eventMessage contains "error"
)' --last 5m
```

### 5.2 关键日志模式识别

**正常启动**（应该看到的日志）：
```
Attempt 1: touched inputNode, waiting for format negotiation...
Attempt 1: config change received, rebuilding engine...
HW inputFormat: sr=24000.0, ch=1
Engine started OK, isRunning=true, hwSR=24000.0
```

**格式不匹配**（故障标志）：
```
Error, formats don't match!
Input HW format: <AVAudioFormat: 1 ch, 24000 Hz, Float32>
tap format: <AVAudioFormat: 1 ch, 48000 Hz, Float32>
```

**无效格式**（首次访问 inputNode 时可能出现）：
```
Input render format: 0 ch, 0 Hz, lpcm 32-bit
```

### 5.3 查看 CoreAudio 格式协商过程

```bash
/usr/bin/log show --predicate 'process contains "voice-input" AND
  eventMessage contains "UpdateStreamFormats"' --last 5m
```

正常情况下会看到格式从 `48000 Hz` 逐步变为麦克风真实采样率（如 `24000 Hz`）。

---

## 6. 最终解决方案

### 6.1 核心策略：等待 → 销毁 → 重建

```
startRecording()
  │
  ├─ 创建 engine A
  ├─ 触摸 engine A 的 inputNode（触发系统格式协商）
  ├─ 等待最多 1 秒，监听 AVAudioEngineConfigurationChange 通知
  │
  ├─ [收到通知] ──→ 销毁 engine A
  │                  创建 engine B（全新实例）
  │                  读取 inputNode.inputFormat（此时格式已稳定）
  │                  用正确格式 installTap + start
  │                  ✅ 录音成功
  │
  └─ [超时未收到] ──→ 直接在 engine A 上 installTap + start
                      （格式可能已经稳定，无需等待）
                      ✅ 录音成功
```

### 6.2 关键代码要点

**1. 显式传递硬件格式给 installTap**

```swift
let hwFormat = inputNode.inputFormat(forBus: 0)
// 用确认的硬件格式，不传 nil
inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { ... }
```

**2. 格式有效性校验**

```swift
guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
    // 格式无效，不能继续
    return false
}
```

**3. AVAudioConverter 使用硬件格式作为源格式**

```swift
let conv = AVAudioConverter(from: hwFormat, to: targetFormat)
```

**4. tap 回调中用 buffer.format 计算转换比率**

```swift
inputNode.installTap(...) { buffer, _ in
    let bufferFormat = buffer.format
    let ratio = targetFormat.sampleRate / bufferFormat.sampleRate
    // ...
}
```

**5. 录音期间配置变更时也要重建 engine**

```swift
// 监听录音期间的配置变更（如插拔耳机）
NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange, ...
) { _ in
    // 销毁旧 engine，创建新 engine，重新 installTap + start
}
```

---

## 7. entitlements 配置要点

### 正确配置

```xml
<!-- voice-input.entitlements -->
<plist version="1.0">
<dict/>
</plist>
```

### Xcode 项目配置

```
ENABLE_APP_SANDBOX = NO    （Debug + Release 都要设置）
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

### 绝对不要做的事

- ❌ 不要保留 `com.apple.security.app-sandbox` key（即使值为 false）
- ❌ 不要保留沙盒相关的子权限 key（如 `com.apple.security.network.client`）
- ❌ 不要使用 `codesign --force --sign -`（ad-hoc 签名会改变 cdhash，导致权限丢失）
- ❌ 不要设置 `ENABLE_USER_SCRIPT_SANDBOXING = NO`（这是 Xcode 构建脚本沙盒，与 App 沙盒无关，保持默认 YES）

---

## 8. 权限管理要点

### 8.1 三项权限的正确请求方式

| 权限 | API | 检查方式 | 请求方式 |
|------|-----|---------|---------|
| 麦克风 | AVCaptureDevice | `AVCaptureDevice.authorizationStatus(for: .audio)` | `AVCaptureDevice.requestAccess(for: .audio)` |
| 输入监控 | CGEventTap | `CGPreflightListenEventAccess()` | `CGRequestListenEventAccess()` |
| 辅助功能 | Accessibility | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): true])` |

### 8.2 权限丢失的常见原因

1. **Ad-hoc 签名**：`codesign --force --sign -` 会改变 cdhash，系统认为是不同的 App
2. **重新编译后 cdhash 变化**：使用 Apple 开发者证书可保持 cdhash 稳定
3. **沙盒开关切换**：从沙盒切到非沙盒或反之，可能需要重新授权

### 8.3 重置权限的命令

```bash
# 重置输入监控
tccutil reset ListenEvent ssh2026.voice-input

# 重置麦克风
tccutil reset Microphone ssh2026.voice-input

# 重置辅助功能（需要管理员密码）
sudo tccutil reset Accessibility ssh2026.voice-input
```

---

## 9. 常见故障速查表

| 症状 | 可能原因 | 排查方法 | 解决方案 |
|------|---------|---------|---------|
| 录音无声音，0 字节文件 | iounit 配置变更停掉了 engine | 查日志是否有 `configuration changed > stopping` | 确认使用了"等待→销毁→重建"策略 |
| `formats don't match` 错误 | tap 格式与硬件格式不一致 | 查日志中 `Input HW format` 和 `tap format` | 配置变更后必须创建全新 engine |
| `inputFormat` 返回 0 Hz | 首次访问 inputNode 时格式未就绪 | 正常现象 | 等待配置变更通知后再读取格式 |
| 权限丢失，App 不在授权列表 | cdhash 变化（ad-hoc 签名） | `codesign -dvvv` 检查签名 | 使用 Apple 开发者证书签名 |
| 辅助功能列表看不到 App | 沙盒开启或 entitlements 残留 | 检查 entitlements 文件 | 删除所有 sandbox 相关 key |
| 快捷键无响应 | 输入监控权限未授权 | `CGPreflightListenEventAccess()` | 引导用户到系统偏好设置授权 |
| 第二次录音失败 | engine 未正确释放 | 查日志 `releaseEngine` 是否执行 | 确认 `stopRecording` 调用了 `releaseEngine` |
| App 崩溃（EXC_BAD_ACCESS） | AVAudioEngine 生命周期管理错误 | 查崩溃日志 | 避免在 engine 运行时直接 dealloc |
| engine.start() 抛出 error -10868 | audio graph 初始化失败 | 查日志 `AUGraphParser::Initialize` | 格式不匹配，需要重建 engine |
| 录音中途断开 | 音频设备切换（插拔耳机） | 查日志 `Runtime config change` | 确认有运行时配置变更监听和自动重建 |

---

## 10. 开发/测试/上线环境一致性

### 推荐的统一环境配置

| 配置项 | 值 | 说明 |
|--------|-----|------|
| App Sandbox | **OFF** | 必须关闭 |
| Hardened Runtime | **ON** | 安全加固，公证必需 |
| 签名方式 | Apple 开发者证书 | 保持 cdhash 稳定 |
| entitlements | 空 dict | 不含任何 sandbox key |
| 分发方式 | Developer ID + Notarization | 不走 Mac App Store |

### 开发流程

1. Xcode 中 `ENABLE_APP_SANDBOX = NO`（Debug + Release）
2. 使用 `scripts/dev-restart.sh --build` 编译重启
3. 首次运行需授权三项权限（后续编译不会丢失，因为 cdhash 稳定）
4. 上线前使用 `Developer ID Application` 证书签名 + `xcrun notarytool` 公证

### 注意事项

- 不要在开发过程中来回切换沙盒开关，会导致权限状态混乱
- 如果权限异常，先用 `tccutil reset` 清除再重新授权
- 切换签名方式后需要清除 DerivedData 全量重编译

---

> **文档版本**：2026-03-09  
> **适用范围**：macOS 13+ / Xcode 15+ / Swift 5.9+  
> **相关文件**：`voice-input/Core/Audio/AudioRecorder.swift`
