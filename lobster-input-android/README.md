# 龙虾输入法 - Android端

龙虾输入法Android客户端，提供语音输入、智能改写等功能。

## 技术栈

- **语言**: Kotlin 2.0.0
- **UI框架**: Jetpack Compose (Material 3)
- **架构模式**: MVVM + Repository
- **依赖注入**: Hilt 2.51.1
- **网络请求**: Retrofit 2.9.0 + OkHttp 4.12.0
- **本地数据库**: Room 2.6.1
- **数据存储**: DataStore Preferences
- **异步处理**: Coroutines 1.7.3 + Flow
- **图片加载**: Coil 2.5.0
- **序列化**: Kotlinx Serialization 1.6.2

## 项目结构

```
app/
├── src/
│   ├── main/
│   │   ├── java/com/lobster/input/
│   │   │   ├── LobsterInputApp.kt          # Application入口
│   │   │   ├── core/                       # 核心功能
│   │   │   │   ├── audio/                  # 音频录制
│   │   │   │   ├── network/                # 网络请求
│   │   │   │   ├── database/               # 本地数据库
│   │   │   │   ├── dictionary/             # 热词管理
│   │   │   │   ├── persona/                # 人设配置
│   │   │   │   └── history/                # 历史记录
│   │   │   ├── data/                       # 数据层
│   │   │   │   ├── model/                  # 数据模型
│   │   │   │   ├── repository/             # 仓库
│   │   │   │   └── remote/                 # API接口
│   │   │   ├── ui/                         # UI层
│   │   │   │   ├── auth/                   # 登录认证
│   │   │   │   ├── main/                   # 主界面
│   │   │   │   ├── onboarding/             # 引导页
│   │   │   │   └── theme/                  # 主题
│   │   │   ├── keyboard/                   # 输入法服务
│   │   │   │   ├── LobsterIME.kt          # 输入法Service
│   │   │   │   ├── VoiceKeyboardView.kt   # 语音键盘UI
│   │   │   │   └── AudioRecorder.kt       # 录音器
│   │   │   └── util/                       # 工具类
│   │   ├── res/                            # 资源文件
│   │   └── AndroidManifest.xml
│   └── test/                               # 单元测试
└── build.gradle.kts
```

## 功能特性

### 1. 用户认证
- 邮箱验证码登录
- 邀请码验证
- Token管理

### 2. 语音输入
- 实时录音
- 音频上传
- 语音转文字
- 智能改写

### 3. 热词管理
- 添加/编辑/删除热词
- 热词同步

### 4. 人设配置
- 多人设管理
- 转写提示词
- 改写提示词
- 意图提示

### 5. 套餐管理
- 积分查询
- 使用记录
- 套餐信息

## 开发说明

### 环境要求
- Android Studio Hedgehog | 2023.1.1+ (推荐使用最新稳定版)
- JDK 17+
- Android SDK 34
- Kotlin 2.0.0
- Gradle 8.7

### 依赖版本
- Android Gradle Plugin: 8.5.0
- Kotlin: 2.0.0
- Compose BOM: 2023.10.01
- Hilt: 2.51.1
- Room: 2.6.1
- Retrofit: 2.9.0
- OkHttp: 4.12.0
- Coroutines: 1.7.3

### 首次配置

1. 克隆项目
```bash
git clone https://example.com/your-organization/lobster-input-android.git
cd lobster-input-android
```

2. 配置Android SDK路径（如果需要）
创建 `local.properties` 文件（已在.gitignore中）：
```properties
sdk.dir=/path/to/your/Android/sdk
```

3. 配置后端API地址
编辑 `app/src/main/java/com/lobster/input/core/network/ApiConfig.kt`：
```kotlin
const val BASE_URL = "https://api.example.org/"
// 或使用本地开发环境
// const val BASE_URL = "http://10.0.2.2:8000/"  // Android模拟器
// const val BASE_URL = "http://192.168.1.100:8000/"  // 真机
```

### 构建运行
```bash
# 编译Debug版本
./gradlew assembleDebug

# 编译Release版本
./gradlew assembleRelease

# 安装到设备
./gradlew installDebug

# 运行测试
./gradlew test

# 清理构建
./gradlew clean
```

### 启用输入法
1. 安装应用后，进入系统设置
2. 系统 -> 语言和输入法 -> 虚拟键盘 -> 管理键盘
3. 启用"龙虾输入法"
4. 打开龙虾输入法App，登录账号
5. 在任意输入框长按，选择输入法，切换到龙虾输入法

### 权限说明
应用需要以下权限：
- `INTERNET`: 网络请求
- `ACCESS_NETWORK_STATE`: 检查网络状态
- `RECORD_AUDIO`: 录音功能（运行时权限）
- `WRITE_EXTERNAL_STORAGE`: 临时保存音频文件（Android 12及以下）
- `READ_EXTERNAL_STORAGE`: 读取音频文件（Android 12及以下）

## API对接

后端API地址配置在 `core/network/ApiConfig.kt`

共享后端服务：`lobster-input-backend`

## 注意事项

### 数据共享
- 输入法服务(LobsterIME)和主应用通过SharedPreferences共享登录状态
- SharedPreferences名称: `lobster_input_prefs`
- 共享的数据包括: auth_token, user_email, user_tier

### 音频录制
- 音频格式：WAV
- 采样率：16kHz
- 位深度：16bit
- 声道：Mono (单声道)
- 最大录音时长：由后端配置控制（默认60秒）

### 权限处理
- 录音权限需要在运行时动态申请
- 首次使用语音输入时会提示授权
- 如果权限被拒绝，需要引导用户到设置中手动开启

### 网络配置
- 默认使用HTTPS连接
- 开发环境可配置`usesCleartextTraffic=true`允许HTTP
- 生产环境建议移除cleartext配置

### 编译优化
- Debug版本关闭混淆以便调试
- Release版本启用ProGuard混淆和优化
- 已配置保留规则在`proguard-rules.pro`

### 已知限制
1. 当前版本音频处理为模拟实现，需要对接实际的后端API
2. 热词管理、人设配置等功能UI已实现，业务逻辑待完善
3. 应用图标使用占位符，需要替换为正式图标

## Git仓库

https://example.com/your-organization/lobster-input-android.git

## 开发路线图

### 已完成 ✅
- [x] 项目基础架构搭建
- [x] Hilt依赖注入配置
- [x] 网络层封装（Retrofit + OkHttp）
- [x] 数据模型定义
- [x] 认证流程UI（登录、邀请码验证）
- [x] 主界面框架（底部导航）
- [x] 输入法服务基础实现
- [x] 音频录制功能
- [x] Compose主题配置

### 进行中 🚧
- [ ] 音频上传和处理API对接
- [ ] 热词管理功能完善
- [ ] 人设配置功能完善
- [ ] 历史记录功能
- [ ] 套餐信息展示

### 待开发 📋
- [ ] 本地数据库实现（Room）
- [ ] 离线缓存策略
- [ ] 应用图标和启动页
- [ ] 用户引导流程
- [ ] 设置页面
- [ ] 错误日志收集
- [ ] 性能优化
- [ ] 单元测试和UI测试
- [ ] 多语言支持

## 贡献指南

### 代码规范
- 遵循Kotlin官方编码规范
- 使用有意义的变量和函数命名
- 添加必要的注释说明复杂逻辑
- 提交前运行`./gradlew ktlintCheck`检查代码风格

### 提交规范
```
feat: 新功能
fix: 修复bug
docs: 文档更新
style: 代码格式调整
refactor: 重构
test: 测试相关
chore: 构建/工具链相关
```

### 分支管理
- `main`: 主分支，保持稳定
- `develop`: 开发分支
- `feature/*`: 功能分支
- `bugfix/*`: 修复分支

## 联系方式

如有问题或建议，请提交Issue或Pull Request。
