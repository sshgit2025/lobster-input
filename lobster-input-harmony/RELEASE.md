# 鸿蒙端发布文档(索引)

发布文档按环境拆分独立维护,两环境内容不混在同一文件:

| 环境 | 文档 | 说明 |
|---|---|---|
| uat(公测环境,正式版) | [RELEASE-uat.md](RELEASE-uat.md) | .com 域名,历史上曾叫 "preview",已正名 uat |
| preview(内测环境) | [RELEASE-preview.md](RELEASE-preview.md) | .cn 域名,新建内测环境 |

一键打包入口(脚本按环境切换 ACTIVE_ENV 与版本号,构建后自动恢复):

```bash
scripts/release.sh uat       # 公测正式版包
scripts/release.sh preview   # 内测版包(默认)
```

版本号规范:`versionCode` 全局单调递增,跨环境不复用同一个号(详见各环境文档)。

## 日常开发构建(非发布,与环境无关)

```bash
export DEVECO_SDK_HOME=~/harmonyos/command-line-tools/sdk
export PATH=~/harmonyos/command-line-tools/bin:~/harmonyos/command-line-tools/tool/node/bin:$PATH
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`(未签名,仅验证编译;真机调试需调试证书+设备 UDID,当前未配)。

日常开发默认环境为 preview(`ApiConfig.ets` 的 `ACTIVE_ENV = 'preview'`),勿在源码里长期写死 uat。
