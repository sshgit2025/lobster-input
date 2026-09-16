<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { Avatar } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

const languages = [
  ['zh', '简体中文', true],
  ['zh-Hant', '繁體中文', false],
  ['yue', '粵語', false],
  ['en', 'English', false],
  ['ru', 'Русский', false],
  ['ko', '한국어', false],
] as const

interface PersonaPrompts {
  transcribe_enabled?: boolean
  rewrite_enabled?: boolean
  intent_enabled?: boolean
  transcribe_prompt?: string
  rewrite_prompt?: string
  intent_hint?: string
}

interface Persona {
  id: string
  name: string
  description?: string
  is_enabled: boolean
  localized_names?: Record<string, string>
  localized_descriptions?: Record<string, string>
  prompts?: PersonaPrompts
  updated_at?: string
  created_at?: string
}

const items = ref<Persona[]>([])
const modalVisible = ref(false)
const editingId = ref<string | null>(null)

const i18nNames = reactive<Record<string, string>>({})
const i18nDescs = reactive<Record<string, string>>({})
const transcribePrompt = ref('')
const rewritePrompt = ref('')
const intentHint = ref('')

function moduleText(p?: PersonaPrompts): string {
  const out: string[] = []
  if (p?.transcribe_enabled) out.push('语音转文字')
  if (p?.rewrite_enabled) out.push('改写/生成')
  if (p?.intent_enabled) out.push('意图识别')
  return out.length ? out.join('、') : '未启用'
}

function i18nCoverage(item: Persona): string {
  const names = item.localized_names || {}
  return languages
    .filter(([code]) => names[code])
    .map(([, label]) => label)
    .join('、') || '未配置'
}

function resetForm() {
  languages.forEach(([code]) => {
    i18nNames[code] = ''
    i18nDescs[code] = ''
  })
  transcribePrompt.value = ''
  rewritePrompt.value = ''
  intentHint.value = ''
}

function openEditor(item: Persona | null) {
  resetForm()
  editingId.value = item?.id || null
  const names = item?.localized_names || {}
  const descs = item?.localized_descriptions || {}
  languages.forEach(([code]) => {
    i18nNames[code] = names[code] || ''
    i18nDescs[code] = descs[code] || ''
  })
  const p = item?.prompts || {}
  transcribePrompt.value = p.transcribe_prompt || ''
  rewritePrompt.value = p.rewrite_prompt || ''
  intentHint.value = p.intent_hint || ''
  modalVisible.value = true
}

async function loadPersonas() {
  const data = await api<{ personas?: Persona[] }>('GET', '/api/v1/personas/builtin')
  items.value = data.personas || []
}

async function savePersona() {
  const localized_names: Record<string, string> = {}
  const localized_descriptions: Record<string, string> = {}
  languages.forEach(([code]) => {
    const name = (i18nNames[code] || '').trim()
    const desc = (i18nDescs[code] || '').trim()
    if (name) localized_names[code] = name
    if (desc) localized_descriptions[code] = desc
  })
  if (!localized_names.zh) {
    showToast('请输入简体中文标题', 'error')
    return
  }
  const body = {
    localized_names,
    localized_descriptions,
    prompts: {
      transcribe_prompt: transcribePrompt.value,
      transcribe_enabled: true,
      rewrite_prompt: rewritePrompt.value,
      rewrite_enabled: true,
      intent_hint: intentHint.value,
      intent_enabled: true,
    },
  }
  try {
    if (editingId.value) {
      await api('PUT', `/api/v1/personas/builtin/${editingId.value}`, body)
    } else {
      await api('POST', '/api/v1/personas/builtin', body)
    }
    modalVisible.value = false
    showToast('保存成功')
    await loadPersonas()
  } catch (e) {
    showToast(e instanceof Error ? e.message : '保存失败', 'error')
  }
}

async function togglePersona(id: string, nextEnabled: boolean) {
  const message = nextEnabled
    ? '确认启用这个内置人设？启用后各客户端可在刷新人设列表后看到并使用。'
    : '确认关闭这个内置人设？关闭后各客户端不再展示；已激活该人设的用户会在下次语音请求或刷新列表时自动回退到无激活人设状态。'
  try {
    await ElMessageBox.confirm(message, '确认', { type: 'warning' })
    await api('PATCH', `/api/v1/personas/builtin/${id}/enabled`, { is_enabled: nextEnabled })
    await loadPersonas()
    showToast(nextEnabled ? '已启用' : '已关闭')
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? e.message : '操作失败', 'error')
  }
}

async function deletePersona(id: string) {
  try {
    await ElMessageBox.confirm('确认删除这个内置人设？已启用该人设的用户会自动回退到无激活人设。', '确认', { type: 'warning' })
    await api('DELETE', `/api/v1/personas/builtin/${id}`)
    await loadPersonas()
    showToast('已删除')
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? e.message : '删除失败', 'error')
  }
}

onMounted(() => {
  loadPersonas().catch((e) => showToast(e instanceof Error ? e.message : '加载失败', 'error'))
})
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">内置人设</div>
      <div class="page-subtitle">维护全端共享的官方人设，支持多语言标题描述与三段提示词，启用后下发至所有客户端。</div>
    </div>
    <div class="ph-actions">
      <el-button type="primary" @click="openEditor(null)">新增内置人设</el-button>
    </div>
  </div>
  <div class="card">
    <div class="card-title"><el-icon><Avatar /></el-icon>公共内置人设</div>
    <div style="font-size:12px;color:var(--text-muted);margin-bottom:14px">
      内置人设不计入用户 10 个自定义人设额度。客户端只能启用或取消启用，只展示对应界面语言的标题和描述，不展示提示词内容。
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>中文名称</th><th>中文描述</th><th>状态</th><th>国际化</th><th>启用模块</th><th>最后更新</th><th>操作</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="items.length === 0">
            <td colspan="7">
              <div class="empty-state">
                <div class="empty-title">暂无内置人设</div>
                <div class="empty-hint">点击右上角「新增内置人设」创建首个官方人设。</div>
              </div>
            </td>
          </tr>
          <tr v-for="item in items" :key="item.id">
            <td>{{ item.name }}</td>
            <td>{{ item.description || '' }}</td>
            <td>
              <span :class="item.is_enabled ? 'badge badge-success' : 'badge badge-danger'">
                {{ item.is_enabled ? '已启用' : '已关闭' }}
              </span>
            </td>
            <td>{{ i18nCoverage(item) }}</td>
            <td>{{ moduleText(item.prompts) }}</td>
            <td>{{ fmtTime(item.updated_at || item.created_at) }}</td>
            <td style="display:flex;gap:6px;flex-wrap:wrap">
              <el-button
                size="small"
                :type="item.is_enabled ? undefined : 'primary'"
                @click="togglePersona(item.id, !item.is_enabled)"
              >{{ item.is_enabled ? '关闭' : '启用' }}</el-button>
              <el-button size="small" @click="openEditor(item)">编辑</el-button>
              <el-button type="danger" size="small" @click="deletePersona(item.id)">删除</el-button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <el-dialog
    v-model="modalVisible"
    :title="editingId ? '编辑内置人设' : '新增内置人设'"
    width="860px"
    destroy-on-close
  >
    <div class="modal-help">
      标题和描述按客户端界面语言展示。简体中文标题必填，其它语种为空时客户端按后端兜底规则回退。
    </div>
    <div class="modal-grid" style="margin-bottom:14px">
      <template v-for="[code, label, required] in languages" :key="code">
        <div class="form-group" style="margin:0">
          <label class="form-label">{{ label }}标题{{ required ? ' *' : '' }}</label>
          <input v-model="i18nNames[code]" class="form-input" maxlength="60" :placeholder="required ? '例如：会议纪要助手' : '为空则回退'">
        </div>
        <div class="form-group" style="margin:0">
          <label class="form-label">{{ label }}描述</label>
          <input v-model="i18nDescs[code]" class="form-input" maxlength="200" placeholder="客户端列表展示文案，可为空">
        </div>
      </template>
    </div>
    <div class="form-group">
      <label class="form-label">语音转文字提示词（非空即启用）</label>
      <textarea v-model="transcribePrompt" class="form-input" maxlength="4000" style="height:120px;resize:vertical;font-family:monospace" />
    </div>
    <div class="form-group">
      <label class="form-label">改写 / 生成提示词（非空即启用）</label>
      <textarea v-model="rewritePrompt" class="form-input" maxlength="4000" style="height:120px;resize:vertical;font-family:monospace" />
    </div>
    <div class="form-group">
      <label class="form-label">Agent 意图识别补充（非空即启用）</label>
      <textarea v-model="intentHint" class="form-input" maxlength="4000" style="height:100px;resize:vertical;font-family:monospace" />
    </div>
    <template #footer>
      <el-button @click="modalVisible = false">取消</el-button>
      <el-button type="primary" @click="savePersona">保存</el-button>
    </template>
  </el-dialog>
</template>
