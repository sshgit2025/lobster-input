# Personal Preferences

## Language

- 总是使用中文回复用户问题

## Base Rule

- 客户端指的是lobster-input-front,后端和服务端指的是lobster-input-backend,管理端指的是lobster-input-admin,IOS端和苹果端指的是lobster-input-ios,lobster-input-landing是宣传官网,windows端和win端指的是lobster-input-win,号池端和号池管理平台指的是lobster-input-api-manage.
- 各端已合并到父目录的统一 Git 仓库；所有 Git 操作在父目录进行，不要创建嵌套仓库或导入旧私有历史
- lobster-input-api-manage是api-key号池管理平台.
- lobster-input-payment是支付平台,也可以叫做支付端.
- 开发阶段后端请使用一键启动脚本启动服务:lobster-input-backend/scripts/restart.sh
- 开发阶段客户端请使用一键启动脚本启动服务:lobster-input-front/scripts/restart.sh
- 开发阶段管理端请使用一键启动脚本编译代码和启动服务:lobster-input-admin/scripts/restart.sh
- 客户端使用Sparkle管理代码在线更新.
- macOS 客户端目录来自原 feature/standard 分支，统一仓库内只维护这套客户端代码
- 每完成修改客户端代码的任务之后都必须运行一键编译启动脚本确保修改的代码没有编译性问题.
- 后端分支唯一,两个分支的客户端共用同一套后端
- 管理端和后端以及号池平台共用数据库
- 所有的import导包操作都必须放在文件顶部,绝不允许在函数局部或者代码局部进行import导包操作.这样不规范且不易发现问题.
- IOS端分支唯一且和MAC客户端以及win端还有安卓端共享访问同一个后端

