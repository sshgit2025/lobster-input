# 快速开始指南

本文档帮助你快速搭建龙虾输入法Android端的开发环境并运行项目。

## 前置条件

确保你的开发环境满足以下要求：

- ✅ macOS / Windows / Linux
- ✅ JDK 17 或更高版本
- ✅ Android Studio Hedgehog (2023.1.1) 或更高版本
- ✅ Android SDK 34
- ✅ Git

## 步骤1: 安装Android Studio

1. 下载并安装 [Android Studio](https://developer.android.com/studio)
2. 启动Android Studio，完成初始配置
3. 通过SDK Manager安装以下组件：
   - Android SDK Platform 34
   - Android SDK Build-Tools 34.0.0
   - Android Emulator (如果需要使用模拟器)

## 步骤2: 克隆项目

```bash
git clone https://example.com/your-organization/lobster-input-android.git
cd lobster-input-android
```

## 步骤3: 配置项目

### 3.1 配置SDK路径（可选）

如果Android Studio没有自动检测到SDK路径，创建`local.properties`文件：

```properties
sdk.dir=/Users/你的用户名/Library/Android/sdk  # macOS
# sdk.dir=C\:\\Users\\你的用户名\\AppData\\Local\\Android\\Sdk  # Windows
```

### 3.2 配置后端API地址

编辑 `app/src/main/java/com/lobster/input/core/network/ApiConfig.kt`：

```kotlin
object ApiConfig {
    // 生产环境
    const val BASE_URL = "https://api.example.org/"
    
    // 开发环境（根据实际情况选择）
    // const val BASE_URL = "http://10.0.2.2:8000/"  // Android模拟器访问本机
    // const val BASE_URL = "http://192.168.1.100:8000/"  // 真机访问局域网
}
```

## 步骤4: 打开项目

1. 启动Android Studio
2. 选择 "Open" 打开项目
3. 选择 `lobster-input-android` 目录
4. 等待Gradle同步完成（首次可能需要几分钟下载依赖）

## 步骤5: 运行项目

### 使用Android Studio运行

1. 连接Android设备或启动模拟器
2. 点击工具栏的 "Run" 按钮（绿色三角形）
3. 选择目标设备
4. 等待应用安装并启动

### 使用命令行运行

```bash
# 编译并安装Debug版本
./gradlew installDebug

# 或者分步执行
./gradlew assembleDebug  # 编译
adb install app/build/outputs/apk/debug/app-debug.apk  # 安装
```

## 步骤6: 启用输入法

1. 打开设备的 **设置**
2. 进入 **系统** -> **语言和输入法** -> **虚拟键盘** -> **管理键盘**
3. 找到并启用 **龙虾输入法**
4. 返回龙虾输入法App，使用邮箱验证码登录
5. 在任意输入框长按，选择输入法，切换到龙虾输入法

## 步骤7: 测试功能

1. 打开任意应用的输入框（如备忘录）
2. 切换到龙虾输入法
3. 点击麦克风图标开始录音
4. 说话后点击停止
5. 查看转写和处理结果

## 常见问题

### Q1: Gradle同步失败

**解决方案：**
- 检查网络连接
- 尝试使用VPN或配置国内镜像
- 删除 `.gradle` 目录后重新同步

### Q2: SDK路径找不到

**解决方案：**
- 在Android Studio中打开 SDK Manager
- 记下SDK路径
- 创建 `local.properties` 文件并配置路径

### Q3: 编译错误：找不到符号

**解决方案：**
- 执行 `./gradlew clean`
- 重新同步Gradle
- Invalidate Caches / Restart (Android Studio菜单)

### Q4: 应用安装后找不到

**解决方案：**
- 检查应用抽屉
- 搜索"龙虾输入法"
- 确认安装成功：`adb shell pm list packages | grep lobster`

### Q5: 输入法列表中没有龙虾输入法

**解决方案：**
- 确认应用已正确安装
- 检查AndroidManifest.xml中的输入法服务配置
- 重启设备后再试

### Q6: 录音权限被拒绝

**解决方案：**
- 进入设置 -> 应用 -> 龙虾输入法 -> 权限
- 手动授予录音权限
- 重新打开输入法

## 开发技巧

### 查看日志

```bash
# 查看应用日志
adb logcat | grep "LobsterInput"

# 查看崩溃日志
adb logcat | grep "AndroidRuntime"
```

### 清除应用数据

```bash
adb shell pm clear com.lobster.input
```

### 卸载应用

```bash
adb uninstall com.lobster.input
```

### 重新安装

```bash
./gradlew clean
./gradlew installDebug
```

## 下一步

- 阅读 [README.md](README.md) 了解项目详情
- 查看 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) 了解开发计划
- 开始开发新功能或修复bug

## 需要帮助？

如果遇到问题：
1. 查看项目Issues
2. 提交新的Issue描述问题
3. 联系项目维护者

祝开发愉快！🚀
