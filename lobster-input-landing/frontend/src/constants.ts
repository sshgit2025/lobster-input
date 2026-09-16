// 官网后端 API 公共前缀。前端在根路径 /，所有接口走 /lobster/site/api/v1/...
// 生产由网关 Nginx 把 /lobster/site 前缀 rewrite 掉转发到后端 8891；
// 本地预览由 vite proxy 完成同样的转发。
export const API_BASE = '/lobster/site/api'
