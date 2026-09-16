// Toast 通知
function showToast(msg, type = "success") {
  const c = document.getElementById("toast-container") || (() => {
    const el = document.createElement("div");
    el.id = "toast-container";
    document.body.appendChild(el);
    return el;
  })();
  const t = document.createElement("div");
  t.className = `toast toast-${type}`;
  t.textContent = msg;
  c.appendChild(t);
  setTimeout(() => t.remove(), 3000);
}

// 全局 API 前缀（由 base.html 注入，部署时可通过 .env BASE_URL 配置）
const BASE_URL = (window.__BASE_URL__ || "").replace(/\/+$/, "");

// 通用 API 请求
async function api(method, url, body) {
  const fullUrl = BASE_URL + url;
  const opts = {
    method,
    credentials: "include",
    headers: { "Content-Type": "application/json" },
  };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(fullUrl, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    let message = data.detail || data.message || "请求失败";
    if (Array.isArray(message)) {
      message = message.map(item => item.msg || item.message || JSON.stringify(item)).join("\n");
    } else if (message && typeof message === "object") {
      message = message.message || JSON.stringify(message);
    }
    throw new Error(message);
  }
  return data;
}

// 退出登录
async function logout() {
  await fetch(BASE_URL + "/api/v1/auth/logout", { method: "POST", credentials: "include" });
  window.location.href = BASE_URL + "/login";
}

// 分页状态
const pager = {
  page: 1,
  pageSize: 20,
  total: 0,
  render(containerId, onPageChange) {
    const el = document.getElementById(containerId);
    if (!el) return;
    const totalPages = Math.ceil(this.total / this.pageSize) || 1;
    el.innerHTML = `
      <span class="page-info">共 ${this.total} 条，第 ${this.page}/${totalPages} 页</span>
      <button class="btn btn-ghost btn-sm" onclick="(${onPageChange})(${this.page - 1})" ${this.page <= 1 ? "disabled" : ""}>上一页</button>
      <button class="btn btn-ghost btn-sm" onclick="(${onPageChange})(${this.page + 1})" ${this.page >= totalPages ? "disabled" : ""}>下一页</button>
    `;
  }
};

// 格式化时间
function fmtTime(ts) {
  if (!ts) return "-";
  return new Date(ts).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" });
}

// 格式化数字
function fmtNum(n) {
  if (n === undefined || n === null) return "0";
  return Number(n).toLocaleString();
}
