# 贡献指南

感谢参与龙虾输入法开发。请先通过 Issue 描述问题或较大的设计变更，修复和功能开发在独立分支完成。

1. 按根目录 README 和目标端文档配置开发环境。
2. 仅修改相关组件；一个 PR 解决一个明确问题。
3. 在 PR 中说明触发场景、修改后的行为、验证方法和已知限制。
4. 执行 `python3 scripts/check_public_repo.py`，并运行受影响组件的编译或测试。macOS 客户端修改后必须运行 `bash lobster-input-front/scripts/restart.sh --build`，签名团队由 `DEVELOPMENT_TEAM` 提供。
5. 不提交 `.env`、凭据、数据库备份、录音、日志、构建产物或个人 IDE 配置。示例使用 `example.com` 域名和文档 IP；密钥在本地生成。
6. 不导入其他仓库的历史；避免引入无必要的大文件。涉及第三方资源时补充来源和许可证。

所有 import 放在文件顶部。提交信息描述实际变更；提交前检查暂存差异。可执行 `git config core.hooksPath .githooks` 启用本仓库提供的暂存内容检查。

提交贡献意味着你有权提交这些内容，并同意原创贡献按本项目 MIT 许可证分发。第三方代码保留其原始版权与许可。
