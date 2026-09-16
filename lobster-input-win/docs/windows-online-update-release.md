# Windows 在线更新与发布流程(索引)

本文件已按环境拆分为独立文档,两环境内容绝不混在同一文件:

- **uat(公测环境,对外发布,徽章"正式版")**:[windows-online-update-release-uat.md](windows-online-update-release-uat.md)
  - 后端 API `https://api.example.com/lobster`,更新目录 `uat/windows`
- **preview(内测环境,徽章"内测版")**:[windows-online-update-release-preview.md](windows-online-update-release-preview.md)
  - 后端 API `https://api.example.net/lobster`,更新目录 `preview/windows`
- **prod**:未来正式环境,尚未部署,仅在代码中保留占位(`LOBSTER_PROD` / `prod/windows`),暂无发布文档。

历史说明:环境体系正名后,原"preview"即现在的 uat;旧 R2 前缀 `windows/preview`、`windows/prod`(平台在前的旧布局)已弃用。发布脚本用法、R2 配置、版本递增规范和验证步骤都在各自环境文档内自洽,请勿交叉引用。
