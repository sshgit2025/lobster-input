const B = window.__BASE_URL__ || '';

async function api(path, method = 'GET', body = null) {
    const opts = {method, headers: {}};
    if (body) {
        opts.headers['Content-Type'] = 'application/json';
        opts.body = JSON.stringify(body);
    }
    const r = await fetch(`${B}${path}`, opts);
    if (r.status === 401) {
        location.href = `${B}/login`;
        return;
    }
    if (!r.ok) {
        const d = await r.json().catch(() => ({}));
        throw new Error(d.detail || `请求失败 (${r.status})`);
    }
    return r.json();
}

function showToast(msg, type = 'info') {
    const c = document.getElementById('toast-container');
    if (!c) return;
    const t = document.createElement('div');
    t.className = `toast toast-${type}`;
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => t.remove(), 3000);
}

function closeModal(id) {
    document.getElementById(id).classList.remove('show');
}

function maskKey(key) {
    if (!key) return '-';
    if (key.length <= 12) return key.slice(0, 4) + '****';
    return key.slice(0, 8) + '****' + key.slice(-4);
}

function renderPagination(containerId, total, page, size, fnName) {
    const pages = Math.ceil(total / size);
    const el = document.getElementById(containerId);
    if (!el) return;
    let html = `<span class="page-info">共 ${total} 条</span>`;
    if (page > 1) {
        html += `<button class="btn btn-ghost btn-sm" onclick="${fnName}(${page - 1})">上一页</button>`;
    }
    html += `<span class="page-info">${page} / ${pages || 1}</span>`;
    if (page < pages) {
        html += `<button class="btn btn-ghost btn-sm" onclick="${fnName}(${page + 1})">下一页</button>`;
    }
    el.innerHTML = html;
}

async function logout() {
    await fetch(`${B}/api/v1/auth/logout`, {method: 'POST'});
    location.href = `${B}/login`;
}
