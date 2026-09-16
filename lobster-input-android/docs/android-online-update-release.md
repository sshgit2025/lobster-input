# Android 在线更新发布流程(索引)

本文档已按环境拆分,两环境内容绝不混在同一文件:

- **uat(公测环境,api.example.com,存量老用户所在环境)**:见 [android-online-update-release-uat.md](android-online-update-release-uat.md)
  - 含“老用户迁移桥”章节:旧 feed `android/preview/update.json` 只镜像 uat 内容。
- **preview(内测环境,api.example.net,新建)**:见 [android-online-update-release-preview.md](android-online-update-release-preview.md)

发布脚本统一为 `tools/release/r2_publish.py --env uat|preview`。prod 为未来正式环境占位,尚未部署。
