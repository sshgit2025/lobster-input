# 龙虾输入法 HarmonyOS 移植公约

本项目是 lobster-input-android(Kotlin) 的 HarmonyOS NEXT(ArkTS) 完整移植。
安卓源码位置: `../lobster-input-android/app/src/main/java/com/lobster/input/`

## 铁律

1. **完全复刻业务逻辑**:算法、状态机、协议字段、边界条件逐行对齐 Kotlin 源码,不允许"顺手优化"或删减功能。
2. **一对一文件映射**:一个 `.kt` 文件对应一个 `.ets` 文件,类名/方法名/字段名与 Kotlin 保持一致(驼峰不变)。
3. **import 全部置于文件顶部**,禁止局部 import。
4. **注释使用中文**,关键业务逻辑处保留与安卓源码等价的注释。

## 目录映射

Android `com/lobster/input/X/Y.kt` → `entry/src/main/ets/X/Y.ets`,例:

| Android | HarmonyOS |
|---|---|
| `core/network/ApiService.kt` | `ets/core/network/ApiService.ets` |
| `keyboard/pinyin/PinyinEngine.kt` | `ets/keyboard/pinyin/PinyinEngine.ets` |
| `data/model/ApiModels.kt` | `ets/data/model/ApiModels.ets` |
| `keyboard/LobsterIME.kt` | `ets/ime/LobsterImeService.ets`(+`LobsterImeAbility.ets`) |
| Compose UI `ui/**` | `ets/pages/**` (ArkUI) |
| 键盘自绘 View `keyboard/typing/*View.kt` | `ets/ime/view/*.ets` (ArkUI @Component) |
| `assets/*.txt` 词库 | `resources/rawfile/dict/*.txt` |

## Android API → HarmonyOS API 对照

| 用途 | Android | HarmonyOS (API 12) |
|---|---|---|
| 输入法服务 | InputMethodService | `@kit.IMEKit` `InputMethodExtensionAbility` + `inputMethodEngine` |
| 文本提交/删除 | InputConnection | `inputMethodEngine.InputClient` (insertText/deleteForward/deleteBackward/getForward/getBackward/moveCursor/sendKeyFunction) |
| 录音 | AudioRecord | `@kit.AudioKit` `audio.AudioCapturer` (16kHz/单声道/SAMPLE_S16LE, SOURCE_TYPE_MIC) |
| HTTP | Retrofit/OkHttp | `@kit.NetworkKit` `http.createHttp()` (封装在 core/network/HttpClient.ets) |
| WebSocket | OkHttp WS | `@kit.NetworkKit` `webSocket.createWebSocket()` (支持 ArrayBuffer 二进制帧) |
| JSON | Gson | `JSON.parse`/`JSON.stringify` + 手写 typed 转换(见 ApiModels 约定) |
| 键值存储 | DataStore/SharedPreferences | `@kit.ArkData` `preferences` (封装在 data/local/AppPreferences.ets) |
| Token 加密存储 | Android Keystore | `@kit.AssetStoreKit` `asset` (封装在 core/security/SecureTokenStore.ets,失败时降级 preferences) |
| 历史记录 | 文件/Room | `@kit.ArkData` preferences 或应用文件目录(对齐安卓实现方式) |
| 剪贴板 | ClipboardManager | `@kit.BasicServicesKit` `pasteboard` |
| 震动反馈 | Vibrator | `@kit.SensorServiceKit` `vibrator.startVibration` |
| 设备标识 | ANDROID_ID | `@ohos.deviceInfo` ODID/随机UUID持久化(对齐 DeviceIdentity.kt 逻辑) |
| 日志 | android.util.Log/FileLog | `@kit.PerformanceAnalysisKit` `hilog` + 应用文件目录写文件(core/log/FileLog.ets) |
| APK 侧载 OTA | AndroidUpdateManager | **不移植**(鸿蒙走应用市场);保留版本检查接口调用,UI 提示"请前往应用市场更新" |
| Toast | Toast | `@kit.ArkUI` `promptAction.showToast` |

## ArkTS 严格模式禁令(编译会挂,务必遵守)

- 禁 `any`/`unknown`;所有对象必须有 interface/class 类型。
- 禁解构声明 `const {a,b} = obj`、禁对象字面量无类型直接传参 → 先定义 interface。
- 禁 `Function` 裸类型 → 用具体签名 `(x: number) => void`。
- 禁在对象上用字符串索引 `obj['key']`(除 Record/Map) → 用 Map 或显式字段。
- `JSON.parse` 返回值先转 `object` 再 `as` 到目标 interface;数值字段注意 undefined 兜底。
- 类字段必须显式初始化或在构造器赋值。
- 不支持 namespace 合并、不支持 `export default` 匿名对象以外的复杂形态。
- @Component struct 内不能定义嵌套 class;工具类放独立 .ets。
- 定时器用 `setTimeout/setInterval`(全局可用),句柄类型 `number`。

## 公共基础设施契约(基础层 agent 产出,他人直接 import)

- `ets/core/log/Logger.ets`: `Logger.d/i/w/e(tag: string, msg: string)` 静态方法,内部走 hilog。
- `ets/core/network/ApiConfig.ets`: `ApiConfig.BASE_URL`(= https://api.example.com/lobster/,与安卓一致)、`ApiConfig.wsUrl(path: string): string`。
- `ets/core/network/HttpClient.ets`: `HttpClient.getJson(path, token?)` / `postJson(path, bodyObj, token?)` / `postBinary(path, buf, contentType, token?)`,返回 `Promise<string>`(响应原文,由调用方 parse)。
- `ets/core/network/ApiService.ets`: 与 ApiService.kt 端点一一对应的方法,方法名一致,返回 Promise<对应Model>。
- `ets/data/model/ApiModels.ets`: 全部 DTO interface + `parseXxx(json: string)` 工厂函数。
- `ets/data/local/AppPreferences.ets`: `getString/putString/getBoolean/putBoolean/getNumber/putNumber/remove`,async,单例 `AppPreferences.getInstance(context)`。
- `ets/core/security/SecureTokenStore.ets`: `save(token)/load()/clear()`,async。
- `ets/core/locale/MobileStrings.ets`: 与 MobileStrings.kt 相同的 key 与多语言分支结构,`MobileStrings.t(key)` 或与 Kotlin 相同的访问形态。
- 上下文获取:UI 侧用 `getContext(this)`;服务侧从 Ability 传入。所有需要 context 的单例统一提供 `init(context: common.Context)`。

## 版本与构建

- bundleName `com.lobster.input`,versionName 1.0.89 / versionCode 93(与安卓对齐)。
- compatibleSdkVersion `5.0.0(12)`,只用 API 12 已有能力。
- 编译: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug`。
