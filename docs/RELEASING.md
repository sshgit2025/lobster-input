# 发布源码与应用

## 源码发布

本项目统一仓库从脱敏快照开始，不导入旧独立仓库的提交历史。旧历史、数据库备份和本机配置不得复制进本仓库。

1. 核对根目录 README、MIT 许可证、第三方许可、配置示例及受影响端文档。
2. 运行 `python3 scripts/check_public_repo.py` 检查 Git 暂存内容，再使用 Gitleaks 扫描整个待发布快照及 Git 历史。
3. 完成目标端编译/测试；未验证平台如实写入发布说明。
4. 首次发布时将维护者提供的 GitHub 地址设置为 `origin`，检查 `git remote -v` 后推送 `main`。不得使用 `--mirror` 推送旧仓库历史。
5. 在 GitHub 开启私密漏洞报告、Secret scanning、Push protection（可用时）与默认分支保护，要求 PR 检查通过。
6. 使用版本 tag 和 GitHub Releases 发布版本说明。安装包作为 Release 资产提供，不加入源码提交。

## 应用发布

- Apple：使用自己的开发团队、证书、App Store Connect 凭据和 Bundle ID。macOS Sparkle 必须重新生成自己的更新签名密钥和公钥，并配置自己的 HTTPS feed；旧应用签名不能复用。
- Android/HarmonyOS：自行生成和保管签名材料，配置自己的更新地址或商店发布信息。
- Windows：使用自己的签名证书和发布源。
- 后端：自行部署数据库与依赖服务，逐环境生成凭据，配置 HTTPS、回调入口和备份机制。备份文件放在源码仓库之外。

仓库中的历史部署说明已经脱敏，只能作为操作结构参考。实际域名、账号、服务器拓扑和密钥应放入部署环境或密钥管理系统。
