<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { Connection, Cpu, Grid } from '@element-plus/icons-vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

const CATEGORY_LABELS: Record<string, string> = {
  asr: 'ASR 语音识别',
  asr_realtime: '实时 ASR',
  llm_chat: 'LLM 文本对话',
  web_search: '联网搜索',
  embedding: '向量 Embedding',
  tts: '音频合成',
}

interface PoolGroup {
  group_id: string
  category: string
  platform_code: string
  active_key_count?: number
  total_key_count?: number
  enabled?: boolean
}

interface Provider {
  provider_id: string
  name?: string
  category: string
  implementation: string
  pool_group_id: string
  enabled?: boolean
  config?: Record<string, unknown>
}

interface Node {
  node_id: string
  name?: string
  category: string
  provider_id: string
  enabled?: boolean
  input_schema?: Record<string, unknown>
  output_schema?: Record<string, unknown>
}

interface Runtime {
  providers: Record<string, Provider>
  nodes: Record<string, Node>
}

interface Catalog {
  categories?: string[]
  platforms?: string[]
  groups?: PoolGroup[]
  warning?: string
}

const runtime = ref<Runtime>({ providers: {}, nodes: {} })
const catalog = ref<Catalog>({ categories: [], platforms: [], groups: [] })
const providerModalVisible = ref(false)

const providerForm = ref({
  originalId: '',
  provider_id: '',
  name: '',
  category: '',
  implementation: '',
  pool_group_id: '',
  enabled: true,
  configJson: '{}',
})

const providerCategories = computed(() =>
  [...new Set([
    ...(catalog.value.categories || []),
    ...Object.values(runtime.value.providers).map((p) => p.category),
  ])].filter(Boolean).sort(),
)

const groupsForCategory = computed(() =>
  (catalog.value.groups || []).filter((g) => g.category === providerForm.value.category && g.enabled !== false),
)

function schemaText(obj?: Record<string, unknown>): string {
  return Object.keys(obj || {}).map((k) => `${k}:${obj![k]}`).join(', ') || '-'
}

function groupById(groupId: string): PoolGroup | undefined {
  return (catalog.value.groups || []).find((g) => g.group_id === groupId)
}

function groupKeyText(group?: PoolGroup): string {
  return `${group?.active_key_count || 0}/${group?.total_key_count || 0} active`
}

function providersForCategory(category: string): Provider[] {
  return Object.values(runtime.value.providers).filter((p) => p.category === category)
}

function providerOptionSuffix(p: Provider): string {
  const group = groupById(p.pool_group_id)
  const active = Number(group?.active_key_count || 0)
  if (p.enabled === false) return ' - 已停用'
  if (!group) return ' - 分组不存在'
  if (group.enabled === false) return ' - 分组停用'
  if (active <= 0) return ' - 无有效 Key'
  return ''
}

async function loadAll() {
  runtime.value = await api<Runtime>('GET', '/api/v1/provider-config/runtime')
  catalog.value = await api<Catalog>('GET', '/api/v1/provider-config/pool-catalog')
}

function openProviderModal() {
  const cats = providerCategories.value
  providerForm.value = {
    originalId: '',
    provider_id: '',
    name: '',
    category: cats[0] || '',
    implementation: '',
    pool_group_id: '',
    enabled: true,
    configJson: '{}',
  }
  providerModalVisible.value = true
}

function editProvider(pid: string) {
  const p = runtime.value.providers[pid]
  if (!p) return
  providerForm.value = {
    originalId: pid,
    provider_id: p.provider_id,
    name: p.name || '',
    category: p.category,
    implementation: p.implementation || '',
    pool_group_id: p.pool_group_id,
    enabled: p.enabled !== false,
    configJson: JSON.stringify(p.config || {}, null, 2),
  }
  providerModalVisible.value = true
}

function saveProviderModal() {
  const original = providerForm.value.originalId
  const provider_id = providerForm.value.provider_id.trim().toLowerCase().replace(/\s+/g, '_')
  if (!provider_id) { showToast('Provider ID 不能为空', 'error'); return }
  const implementation = providerForm.value.implementation.trim().toLowerCase()
  const pool_group_id = providerForm.value.pool_group_id
  if (!implementation) { showToast('Provider 实现不能为空', 'error'); return }
  if (!pool_group_id) { showToast('请选择号池分组', 'error'); return }
  let cfg: Record<string, unknown> = {}
  try {
    cfg = JSON.parse(providerForm.value.configJson || '{}')
  } catch {
    showToast('附加配置不是合法 JSON', 'error')
    return
  }
  if (original && original !== provider_id) delete runtime.value.providers[original]
  runtime.value.providers[provider_id] = {
    provider_id,
    name: providerForm.value.name.trim() || provider_id,
    category: providerForm.value.category,
    implementation,
    pool_group_id,
    enabled: providerForm.value.enabled,
    config: cfg,
  }
  providerModalVisible.value = false
}

function readRuntimeFromDom(): Runtime {
  return { providers: runtime.value.providers, nodes: runtime.value.nodes }
}

async function saveRuntime() {
  try {
    runtime.value = await api<Runtime>('POST', '/api/v1/provider-config/runtime', readRuntimeFromDom())
    showToast('配置已保存，后端缓存已清理')
  } catch (e) {
    showToast(e instanceof Error ? e.message : '保存失败', 'error')
  }
}

onMounted(() => {
  loadAll().catch((e) => showToast(e instanceof Error ? e.message : '加载失败', 'error'))
})
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">Provider 配置</div>
      <div class="page-subtitle">为每个业务节点绑定服务商与号池分组，管理端只负责映射关系，Key 调度与额度由号池端兜底。</div>
    </div>
    <div class="ph-actions">
      <el-button size="small" @click="openProviderModal">新增 Provider</el-button>
      <el-button type="primary" @click="saveRuntime">保存并清缓存</el-button>
    </div>
  </div>

  <div class="card">
    <div class="card-title"><el-icon><Cpu /></el-icon>业务节点</div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>节点</th><th>分类</th><th>Provider</th><th>启用</th><th>输入</th><th>输出</th></tr></thead>
        <tbody>
          <tr v-if="!Object.keys(runtime.nodes).length">
            <td colspan="6" style="text-align:center;color:var(--text-muted);padding:20px">暂无业务节点</td>
          </tr>
          <tr v-for="n in Object.values(runtime.nodes)" :key="n.node_id">
            <td><code>{{ n.node_id }}</code><div style="font-size:12px;color:var(--text-muted)">{{ n.name }}</div></td>
            <td>{{ CATEGORY_LABELS[n.category] || n.category }}</td>
            <td>
              <select v-model="n.provider_id" class="form-select">
                <option
                  v-for="p in providersForCategory(n.category)"
                  :key="p.provider_id"
                  :value="p.provider_id"
                >{{ p.name }} ({{ p.provider_id }}){{ providerOptionSuffix(p) }}</option>
              </select>
            </td>
            <td><el-checkbox :model-value="n.enabled !== false" @update:model-value="(v: boolean) => n.enabled = v" /></td>
            <td style="font-size:12px;color:var(--text-muted)">{{ schemaText(n.input_schema) }}</td>
            <td style="font-size:12px;color:var(--text-muted)">{{ schemaText(n.output_schema) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="card">
    <div class="card-title"><el-icon><Connection /></el-icon>Provider 与号池分组绑定</div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Provider</th><th>分类</th><th>实现</th><th>号池分组</th><th>启用</th><th>操作</th></tr></thead>
        <tbody>
          <tr v-if="!Object.keys(runtime.providers).length">
            <td colspan="6" style="text-align:center;color:var(--text-muted);padding:20px">暂无 Provider，点击「新增 Provider」添加</td>
          </tr>
          <tr v-for="p in Object.values(runtime.providers)" :key="p.provider_id">
            <td><code>{{ p.provider_id }}</code><div style="font-size:12px;color:var(--text-muted)">{{ p.name }}</div></td>
            <td>{{ CATEGORY_LABELS[p.category] || p.category }}</td>
            <td><code>{{ p.implementation }}</code></td>
            <td>
              <code>{{ p.pool_group_id }}</code>
              <template v-if="!groupById(p.pool_group_id)">
                <div style="font-size:12px;color:var(--danger)">分组不存在</div>
              </template>
              <template v-else>
                <div style="display:flex;gap:6px;align-items:center;margin-top:4px;font-size:12px;color:var(--text-muted)">
                  <span
                    v-if="groupById(p.pool_group_id)!.enabled !== false && Number(groupById(p.pool_group_id)!.active_key_count || 0) > 0"
                    class="badge badge-success"
                  >可用</span>
                  <span
                    v-else
                    :class="['badge', groupById(p.pool_group_id)!.enabled === false ? 'badge-warning' : 'badge-danger']"
                  >{{ groupById(p.pool_group_id)!.enabled === false ? '分组停用' : '无有效 Key' }}</span>
                  <span>{{ groupKeyText(groupById(p.pool_group_id)) }}</span>
                </div>
              </template>
            </td>
            <td>
              <span :class="p.enabled ? 'badge badge-success' : 'badge badge-info'">{{ p.enabled ? '启用' : '停用' }}</span>
            </td>
            <td><el-button size="small" @click="editProvider(p.provider_id)">编辑</el-button></td>
          </tr>
        </tbody>
      </table>
    </div>
    <div style="font-size:12px;color:var(--text-muted);margin-top:8px">管理端只绑定号池 group_id；同组多 Key 的负载均衡、额度、冷却和错误摘除由号池端负责。</div>
  </div>

  <div class="card">
    <div class="card-title"><el-icon><Grid /></el-icon>号池实时目录</div>
    <div v-if="catalog.warning" style="font-size:12px;color:var(--text-muted);margin-bottom:10px">{{ catalog.warning }}</div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>分类</th><th>平台</th><th>分组</th><th>Key</th><th>状态</th></tr></thead>
        <tbody>
          <tr v-if="!(catalog.groups || []).length">
            <td colspan="5" style="text-align:center;color:var(--text-muted)">暂无号池分组</td>
          </tr>
          <tr v-for="g in catalog.groups" :key="g.group_id">
            <td>{{ CATEGORY_LABELS[g.category] || g.category }}</td>
            <td>{{ g.platform_code }}</td>
            <td><code>{{ g.group_id }}</code></td>
            <td>{{ g.active_key_count || 0 }}/{{ g.total_key_count || 0 }}</td>
            <td>
              <span :class="g.enabled ? 'badge badge-success' : 'badge badge-muted'">{{ g.enabled ? '启用' : '停用' }}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <el-dialog v-model="providerModalVisible" title="Provider 配置" width="520px" destroy-on-close>
    <div class="form-row" style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
      <div class="form-group">
        <label class="form-label">Provider ID</label>
        <input v-model="providerForm.provider_id" class="form-input" placeholder="llm_aliyun">
      </div>
      <div class="form-group">
        <label class="form-label">名称</label>
        <input v-model="providerForm.name" class="form-input">
      </div>
    </div>
    <div class="form-row" style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
      <div class="form-group">
        <label class="form-label">分类</label>
        <select v-model="providerForm.category" class="form-select">
          <option v-for="c in providerCategories" :key="c" :value="c">{{ CATEGORY_LABELS[c] || c }}</option>
        </select>
      </div>
      <div class="form-group">
        <label class="form-label">实现</label>
        <input v-model="providerForm.implementation" class="form-input" placeholder="aliyun / dashscope_web_search">
      </div>
    </div>
    <div class="form-group">
      <label class="form-label">号池分组</label>
      <select v-model="providerForm.pool_group_id" class="form-select">
        <option v-for="g in groupsForCategory" :key="g.group_id" :value="g.group_id">
          {{ g.platform_code }} — {{ g.group_id }} ({{ g.active_key_count || 0 }}/{{ g.total_key_count || 0 }} active)
        </option>
      </select>
    </div>
    <label style="display:flex;gap:8px;align-items:center;margin-bottom:16px">
      <input v-model="providerForm.enabled" type="checkbox"> 启用
    </label>
    <div class="form-group">
      <label class="form-label">附加配置 JSON</label>
      <textarea v-model="providerForm.configJson" class="form-input" rows="5" placeholder='{"search_strategy":"agent"}' />
    </div>
    <template #footer>
      <el-button @click="providerModalVisible = false">取消</el-button>
      <el-button type="primary" @click="saveProviderModal">确定</el-button>
    </template>
  </el-dialog>
</template>
