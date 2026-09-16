<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Plus, FolderAdd, Key, Grid, Connection, Refresh } from '@element-plus/icons-vue'
import { api } from '@/api'
import { CATEGORY_LABELS, STATUS_LABELS } from '@/constants'

interface Platform { category: string; code: string; name?: string; default_model?: string; default_base_url?: string; description?: string; enabled?: boolean }
interface Group { group_id: string; category: string; platform_code: string; name?: string; description?: string; enabled?: boolean; active_key_count?: number; total_key_count?: number }
interface KeyItem {
  _id: string; group_id: string; group_name?: string; category: string; platform_code: string
  name?: string; api_key?: string; status: string; weight?: number; priority?: number
  total_requests?: number; proxy_config?: { enabled?: boolean; proxy_url?: string; username?: string; password?: string }
  token_quota?: { enabled?: boolean; total?: number; used?: number }
  seconds_quota?: { enabled?: boolean; total?: number; used?: number }
  requests_quota?: { enabled?: boolean; total?: number; used?: number }
  model?: string; base_url?: string; description?: string
  cooldown_seconds?: number; error_threshold?: number
}

const allCategories = ref<string[]>([])
const allPlatforms = ref<Platform[]>([])
const allGroups = ref<Group[]>([])
const keys = ref<KeyItem[]>([])
const keyTotal = ref(0)
const keyPage = ref(1)
const pageSize = 20

const filters = reactive({ category: '', platformValue: '', group_id: '', status: '' })

const platformModal = ref(false)
const groupModal = ref(false)
const keyModal = ref(false)
const keyModalTitle = ref('新增 Key')
const editingKeyId = ref('')

const platformForm = reactive({ category: 'llm_chat', code: '', name: '', default_model: '', default_base_url: '', description: '', enabled: true })
const groupForm = reactive({ category: '', platform_code: '', group_id: '', name: '', description: '', enabled: true })
const keyForm = reactive({
  group_id: '', api_key: '', name: '', description: '', model: '', base_url: '',
  weight: 10, priority: 0, cooldown_seconds: 60, error_threshold: 30,
  proxy_enabled: false, proxy_url: '', proxy_user: '', proxy_pass: '',
  q_token_enabled: false, q_token_total: 0,
  q_seconds_enabled: false, q_seconds_total: 0,
  q_requests_enabled: false, q_requests_total: 0,
})

const visiblePlatforms = computed(() => {
  const pf = parsePlatformValue(filters.platformValue)
  return allPlatforms.value.filter((p) => {
    if (filters.category && p.category !== filters.category) return false
    if (pf.platform_code && (p.category !== pf.category || p.code !== pf.platform_code)) return false
    return true
  })
})

const visibleGroups = computed(() => {
  const pf = parsePlatformValue(filters.platformValue)
  return allGroups.value.filter((g) => {
    if (filters.category && g.category !== filters.category) return false
    if (pf.platform_code && g.platform_code !== pf.platform_code) return false
    if (filters.group_id && g.group_id !== filters.group_id) return false
    return true
  })
})

const categoryOptions = computed(() =>
  [...new Set([...allCategories.value, ...allPlatforms.value.map((p) => p.category), ...allGroups.value.map((g) => g.category)])].filter(Boolean).sort(),
)

function platformValue(p: { category: string; code: string }) { return `${p.category}::${p.code}` }
function parsePlatformValue(v: string) {
  if (!v) return { category: '', platform_code: '' }
  const parts = v.split('::')
  return parts.length === 2 ? { category: parts[0], platform_code: parts[1] } : { category: '', platform_code: v }
}
function maskKey(k?: string) {
  if (!k) return '-'
  return k.length <= 12 ? k : `${k.slice(0, 6)}...${k.slice(-6)}`
}
function quotaSummary(k: KeyItem) {
  const parts: string[] = []
  if (k.token_quota?.enabled) parts.push(`T:${k.token_quota.used || 0}/${k.token_quota.total || 0}`)
  if (k.seconds_quota?.enabled) parts.push(`S:${k.seconds_quota.used || 0}/${k.seconds_quota.total || 0}`)
  if (k.requests_quota?.enabled) parts.push(`R:${k.requests_quota.used || 0}/${k.requests_quota.total || 0}`)
  return parts.join(' ') || '无限'
}
function statusType(s: string) {
  const map: Record<string, string> = { active: 'success', cooldown: 'info', exhausted: 'warning', disabled: 'info', error: 'danger', expired: 'info' }
  return map[s] || 'info'
}

async function refreshAll() {
  await loadCatalog()
  await loadKeys(1)
}

async function loadCatalog() {
  const [cats, plats, groups] = await Promise.all([
    api<string[]>('/api/v1/keys/categories'),
    api<Platform[]>('/api/v1/keys/platforms'),
    api<Group[]>('/api/v1/keys/groups'),
  ])
  allCategories.value = cats
  allPlatforms.value = plats
  allGroups.value = groups
}

async function loadKeys(p = 1) {
  keyPage.value = p
  const pf = parsePlatformValue(filters.platformValue)
  const params = new URLSearchParams({ page: String(p), page_size: String(pageSize) })
  const cat = filters.category || pf.category
  const pcode = pf.platform_code
  if (cat) params.set('category', cat)
  if (pcode) params.set('platform_code', pcode)
  if (filters.group_id) params.set('group_id', filters.group_id)
  if (filters.status) params.set('status', filters.status)
  const data = await api<{ items: KeyItem[]; total: number }>(`/api/v1/keys?${params}`)
  keys.value = data.items
  keyTotal.value = data.total
}

function openPlatformModal(p?: Platform) {
  Object.assign(platformForm, p || { category: filters.category || 'llm_chat', code: '', name: '', default_model: '', default_base_url: '', description: '', enabled: true })
  platformModal.value = true
}

async function savePlatform() {
  await api('/api/v1/keys/platforms', 'POST', { ...platformForm })
  platformModal.value = false
  ElMessage.success('平台已保存')
  await refreshAll()
}

function openGroupModal(g?: Group) {
  if (g) Object.assign(groupForm, { category: g.category, platform_code: g.platform_code, group_id: g.group_id, name: g.name || '', description: g.description || '', enabled: g.enabled !== false })
  else Object.assign(groupForm, { category: categoryOptions.value[0] || '', platform_code: '', group_id: '', name: '', description: '', enabled: true })
  groupModal.value = true
}

async function saveGroup() {
  await api('/api/v1/keys/groups', 'POST', { ...groupForm })
  groupModal.value = false
  ElMessage.success('分组已保存')
  await refreshAll()
}

function resetKeyForm() {
  editingKeyId.value = ''
  keyModalTitle.value = '新增 Key'
  Object.assign(keyForm, {
    group_id: filters.group_id || visibleGroups.value[0]?.group_id || '', api_key: '', name: '', description: '', model: '', base_url: '',
    weight: 10, priority: 0, cooldown_seconds: 60, error_threshold: 30,
    proxy_enabled: false, proxy_url: '', proxy_user: '', proxy_pass: '',
    q_token_enabled: false, q_token_total: 0, q_seconds_enabled: false, q_seconds_total: 0,
    q_requests_enabled: false, q_requests_total: 0,
  })
}

async function openKeyModal() { resetKeyForm(); keyModal.value = true }

async function editKey(id: string) {
  const k = await api<KeyItem>(`/api/v1/keys/${id}`)
  editingKeyId.value = id
  keyModalTitle.value = '编辑 Key'
  Object.assign(keyForm, {
    group_id: k.group_id, api_key: k.api_key || '', name: k.name || '', description: k.description || '',
    model: k.model || '', base_url: k.base_url || '', weight: k.weight ?? 10, priority: k.priority ?? 0,
    cooldown_seconds: k.cooldown_seconds ?? 60, error_threshold: k.error_threshold ?? 30,
    proxy_enabled: !!k.proxy_config?.enabled, proxy_url: k.proxy_config?.proxy_url || '',
    proxy_user: k.proxy_config?.username || '', proxy_pass: k.proxy_config?.password || '',
    q_token_enabled: !!k.token_quota?.enabled, q_token_total: k.token_quota?.total || 0,
    q_seconds_enabled: !!k.seconds_quota?.enabled, q_seconds_total: k.seconds_quota?.total || 0,
    q_requests_enabled: !!k.requests_quota?.enabled, q_requests_total: k.requests_quota?.total || 0,
  })
  keyModal.value = true
}

async function saveKey() {
  const body = {
    group_id: keyForm.group_id, api_key: keyForm.api_key, name: keyForm.name, description: keyForm.description,
    model: keyForm.model, base_url: keyForm.base_url, weight: keyForm.weight, priority: keyForm.priority,
    cooldown_seconds: keyForm.cooldown_seconds, error_threshold: keyForm.error_threshold,
    proxy_config: { enabled: keyForm.proxy_enabled, proxy_url: keyForm.proxy_url, username: keyForm.proxy_user, password: keyForm.proxy_pass },
    token_quota: { enabled: keyForm.q_token_enabled, total: keyForm.q_token_total, used: 0 },
    seconds_quota: { enabled: keyForm.q_seconds_enabled, total: keyForm.q_seconds_total, used: 0 },
    requests_quota: { enabled: keyForm.q_requests_enabled, total: keyForm.q_requests_total, used: 0 },
  }
  if (editingKeyId.value) await api(`/api/v1/keys/${editingKeyId.value}`, 'PUT', body)
  else await api('/api/v1/keys', 'POST', body)
  keyModal.value = false
  ElMessage.success('Key 已保存')
  await refreshAll()
}

async function deleteKey(id: string) {
  await ElMessageBox.confirm('确认删除此 Key？', '提示', { type: 'warning' })
  await api(`/api/v1/keys/${id}`, 'DELETE')
  ElMessage.success('已删除')
  await refreshAll()
}

async function quickStatus(id: string, status: string) {
  let reason = status === 'disabled' ? prompt('禁用原因：') : '手动恢复'
  if (status === 'disabled' && !reason) return
  await api(`/api/v1/keys/${id}/reset`, 'POST', { status, reason })
  ElMessage.success('状态已更新')
  await loadKeys(keyPage.value)
}

async function copyKey(id: string) {
  const k = await api<KeyItem>(`/api/v1/keys/${id}`)
  await navigator.clipboard.writeText(k.api_key || '')
  ElMessage.success('API Key 已复制')
}

const groupPlatformOptions = computed(() => allPlatforms.value.filter((p) => p.category === groupForm.category))

onMounted(refreshAll)
</script>

<template>
  <div class="page-header">
    <div>
      <h1 class="page-title" style="margin:0">平台与 Key 分组</h1>
      <div class="page-subtitle">维护 Provider 平台目录、负载均衡分组与真实 API Key,集中管控号池健康度。</div>
    </div>
    <div class="ph-actions">
      <button class="btn btn-ghost btn-sm" @click="openPlatformModal()"><el-icon><Plus /></el-icon> 新增平台</button>
      <button class="btn btn-ghost btn-sm" @click="openGroupModal()"><el-icon><FolderAdd /></el-icon> 新增分组</button>
      <button class="btn btn-primary btn-sm" @click="openKeyModal"><el-icon><Key /></el-icon> 新增 Key</button>
    </div>
  </div>

    <el-form :inline="true" style="margin-bottom: 16px">
      <el-form-item>
        <el-select v-model="filters.category" placeholder="全部分类" clearable style="width: 150px" @change="() => { filters.platformValue = ''; filters.group_id = ''; loadKeys(1) }">
          <el-option v-for="c in categoryOptions" :key="c" :label="CATEGORY_LABELS[c] || c" :value="c" />
        </el-select>
      </el-form-item>
      <el-form-item>
        <el-select v-model="filters.platformValue" placeholder="全部平台" clearable style="width: 200px" @change="loadKeys(1)">
          <el-option v-for="p in allPlatforms.filter(x => !filters.category || x.category === filters.category)" :key="platformValue(p)" :label="`${CATEGORY_LABELS[p.category] || p.category} / ${p.code}`" :value="platformValue(p)" />
        </el-select>
      </el-form-item>
      <el-form-item>
        <el-select v-model="filters.group_id" placeholder="全部分组" clearable style="width: 220px" @change="loadKeys(1)">
          <el-option v-for="g in allGroups" :key="g.group_id" :label="`${g.category}/${g.platform_code} — ${g.group_id}`" :value="g.group_id" />
        </el-select>
      </el-form-item>
      <el-form-item>
        <el-select v-model="filters.status" placeholder="全部状态" clearable style="width: 130px" @change="loadKeys(1)">
          <el-option v-for="(label, val) in STATUS_LABELS" :key="val" :label="label" :value="val" />
        </el-select>
      </el-form-item>
      <el-button :icon="Refresh" @click="refreshAll">刷新</el-button>
    </el-form>

    <div class="card">
      <div class="card-title"><el-icon><Grid /></el-icon> 平台目录</div>
      <div v-if="!visiblePlatforms.length" class="empty-state">
        <el-icon class="empty-icon"><Grid /></el-icon>
        <div class="empty-title">暂无平台</div>
        <div class="empty-hint">点击右上角“新增平台”接入 Provider。</div>
      </div>
      <el-table v-else :data="visiblePlatforms" stripe>
        <el-table-column label="分类"><template #default="{ row }">{{ CATEGORY_LABELS[row.category] || row.category }}</template></el-table-column>
        <el-table-column label="平台" prop="code" />
        <el-table-column label="名称" prop="name" />
        <el-table-column label="默认模型" prop="default_model" />
        <el-table-column label="Base URL" prop="default_base_url" show-overflow-tooltip />
        <el-table-column label="状态" width="80"><template #default="{ row }"><el-tag :type="row.enabled !== false ? 'success' : 'info'">{{ row.enabled !== false ? '启用' : '停用' }}</el-tag></template></el-table-column>
        <el-table-column label="操作" width="80"><template #default="{ row }"><el-button link type="primary" @click="openPlatformModal(row)">编辑</el-button></template></el-table-column>
      </el-table>
    </div>

    <div class="card">
      <div class="card-title"><el-icon><Connection /></el-icon> Key 负载均衡分组</div>
      <div v-if="!visibleGroups.length" class="empty-state">
        <el-icon class="empty-icon"><Connection /></el-icon>
        <div class="empty-title">暂无分组</div>
        <div class="empty-hint">点击右上角“新增分组”创建负载均衡分组。</div>
      </div>
      <el-table v-else :data="visibleGroups" stripe>
        <el-table-column label="group_id" prop="group_id" />
        <el-table-column label="分类" prop="category" />
        <el-table-column label="平台" prop="platform_code" />
        <el-table-column label="名称" prop="name" />
        <el-table-column label="Key" width="80"><template #default="{ row }">{{ row.active_key_count || 0 }}/{{ row.total_key_count || 0 }}</template></el-table-column>
        <el-table-column label="状态" width="80"><template #default="{ row }"><el-tag :type="row.enabled !== false ? 'success' : 'info'">{{ row.enabled !== false ? '启用' : '停用' }}</el-tag></template></el-table-column>
        <el-table-column label="操作" width="80"><template #default="{ row }"><el-button link type="primary" @click="openGroupModal(row)">编辑</el-button></template></el-table-column>
      </el-table>
    </div>

    <div class="card">
      <div class="card-title"><el-icon><Key /></el-icon> 真实 API Key <span style="font-size:12px;font-weight:500;color:var(--text-muted)">共 {{ keyTotal }} 条</span></div>
      <div v-if="!keys.length" class="empty-state">
        <el-icon class="empty-icon"><Key /></el-icon>
        <div class="empty-title">暂无 API Key</div>
        <div class="empty-hint">调整筛选条件,或点击右上角“新增 Key”录入。</div>
      </div>
      <el-table v-else :data="keys" stripe>
        <el-table-column label="名称" prop="name" />
        <el-table-column label="分组" width="160"><template #default="{ row }"><div>{{ row.group_id }}</div><div style="font-size: 11px; color: #999">{{ row.group_name }}</div></template></el-table-column>
        <el-table-column label="平台" width="120"><template #default="{ row }">{{ row.category }}/{{ row.platform_code }}</template></el-table-column>
        <el-table-column label="Key" width="140"><template #default="{ row }"><el-button link @click="copyKey(row._id)"><span class="key-mask">{{ maskKey(row.api_key) }}</span></el-button></template></el-table-column>
        <el-table-column label="代理" width="70"><template #default="{ row }">{{ row.proxy_config?.enabled ? '启用' : '-' }}</template></el-table-column>
        <el-table-column label="状态" width="90"><template #default="{ row }"><el-tag :type="statusType(row.status)">{{ STATUS_LABELS[row.status] || row.status }}</el-tag></template></el-table-column>
        <el-table-column label="权重/优先级" width="100"><template #default="{ row }">{{ row.weight }}/{{ row.priority }}</template></el-table-column>
        <el-table-column label="额度" width="140"><template #default="{ row }">{{ quotaSummary(row) }}</template></el-table-column>
        <el-table-column label="总请求" prop="total_requests" width="80" />
        <el-table-column label="操作" width="200" fixed="right">
          <template #default="{ row }">
            <div class="actions-cell">
              <el-button v-if="row.status === 'active'" link type="danger" @click="quickStatus(row._id, 'disabled')">禁用</el-button>
              <el-button v-else link type="success" @click="quickStatus(row._id, 'active')">启用</el-button>
              <el-button link type="primary" @click="editKey(row._id)">编辑</el-button>
              <el-button link type="danger" @click="deleteKey(row._id)">删除</el-button>
            </div>
          </template>
        </el-table-column>
      </el-table>
      <div v-if="keys.length" class="pager-row">
        <el-pagination layout="total, prev, pager, next" :total="keyTotal" :page-size="pageSize" :current-page="keyPage" @current-change="loadKeys" />
      </div>
    </div>

    <el-dialog v-model="platformModal" title="平台配置" width="560px">
      <el-form label-width="100px">
        <el-form-item label="分类"><el-input v-model="platformForm.category" /></el-form-item>
        <el-form-item label="平台 code"><el-input v-model="platformForm.code" /></el-form-item>
        <el-form-item label="名称"><el-input v-model="platformForm.name" /></el-form-item>
        <el-form-item label="默认模型"><el-input v-model="platformForm.default_model" /></el-form-item>
        <el-form-item label="Base URL"><el-input v-model="platformForm.default_base_url" /></el-form-item>
        <el-form-item label="描述"><el-input v-model="platformForm.description" /></el-form-item>
        <el-form-item><el-checkbox v-model="platformForm.enabled">启用</el-checkbox></el-form-item>
      </el-form>
      <template #footer><el-button @click="platformModal = false">取消</el-button><el-button type="primary" @click="savePlatform">保存</el-button></template>
    </el-dialog>

    <el-dialog v-model="groupModal" title="Key 分组配置" width="560px">
      <el-form label-width="100px">
        <el-form-item label="分类">
          <el-select v-model="groupForm.category" style="width: 100%"><el-option v-for="c in categoryOptions" :key="c" :label="CATEGORY_LABELS[c] || c" :value="c" /></el-select>
        </el-form-item>
        <el-form-item label="平台">
          <el-select v-model="groupForm.platform_code" style="width: 100%"><el-option v-for="p in groupPlatformOptions" :key="p.code" :label="p.code" :value="p.code" /></el-select>
        </el-form-item>
        <el-form-item label="group_id"><el-input v-model="groupForm.group_id" /></el-form-item>
        <el-form-item label="名称"><el-input v-model="groupForm.name" /></el-form-item>
        <el-form-item label="描述"><el-input v-model="groupForm.description" /></el-form-item>
        <el-form-item><el-checkbox v-model="groupForm.enabled">启用</el-checkbox></el-form-item>
      </el-form>
      <template #footer><el-button @click="groupModal = false">取消</el-button><el-button type="primary" @click="saveGroup">保存</el-button></template>
    </el-dialog>

    <el-dialog v-model="keyModal" :title="keyModalTitle" width="640px">
      <el-form label-width="110px">
        <el-form-item label="分组">
          <el-select v-model="keyForm.group_id" style="width: 100%">
            <el-option v-for="g in (visibleGroups.length ? visibleGroups : allGroups)" :key="g.group_id" :label="`${g.category}/${g.platform_code} — ${g.group_id}`" :value="g.group_id" />
          </el-select>
        </el-form-item>
        <el-form-item label="名称"><el-input v-model="keyForm.name" /></el-form-item>
        <el-form-item label="API Key"><el-input v-model="keyForm.api_key" /></el-form-item>
        <el-form-item label="模型覆盖"><el-input v-model="keyForm.model" placeholder="留空使用平台默认" /></el-form-item>
        <el-form-item label="Base URL"><el-input v-model="keyForm.base_url" placeholder="留空使用平台默认" /></el-form-item>
        <el-form-item label="权重"><el-input-number v-model="keyForm.weight" :min="0" :max="100" /></el-form-item>
        <el-form-item label="优先级"><el-input-number v-model="keyForm.priority" :min="0" :max="99" /></el-form-item>
        <el-form-item label="冷却秒数"><el-input-number v-model="keyForm.cooldown_seconds" :min="0" /></el-form-item>
        <el-form-item label="错误阈值"><el-input-number v-model="keyForm.error_threshold" :min="30" /></el-form-item>
        <el-form-item label="描述"><el-input v-model="keyForm.description" /></el-form-item>
        <el-form-item><el-checkbox v-model="keyForm.proxy_enabled">启用代理</el-checkbox></el-form-item>
        <template v-if="keyForm.proxy_enabled">
          <el-form-item label="代理地址"><el-input v-model="keyForm.proxy_url" /></el-form-item>
          <el-form-item label="用户名"><el-input v-model="keyForm.proxy_user" /></el-form-item>
          <el-form-item label="密码"><el-input v-model="keyForm.proxy_pass" type="password" /></el-form-item>
        </template>
        <el-divider>额度</el-divider>
        <el-form-item><el-checkbox v-model="keyForm.q_token_enabled">Token</el-checkbox><el-input-number v-if="keyForm.q_token_enabled" v-model="keyForm.q_token_total" :min="0" style="margin-left: 8px" /></el-form-item>
        <el-form-item><el-checkbox v-model="keyForm.q_seconds_enabled">秒数</el-checkbox><el-input-number v-if="keyForm.q_seconds_enabled" v-model="keyForm.q_seconds_total" :min="0" style="margin-left: 8px" /></el-form-item>
        <el-form-item><el-checkbox v-model="keyForm.q_requests_enabled">请求</el-checkbox><el-input-number v-if="keyForm.q_requests_enabled" v-model="keyForm.q_requests_total" :min="0" style="margin-left: 8px" /></el-form-item>
      </el-form>
      <template #footer><el-button @click="keyModal = false">取消</el-button><el-button type="primary" @click="saveKey">保存</el-button></template>
    </el-dialog>
</template>
