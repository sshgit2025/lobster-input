<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { Document } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface AgreementRow {
  type: string; lang: string; content?: string; updated_at?: string
}

const TYPE_LABEL: Record<string, string> = { terms: '用户协议', privacy: '隐私政策' }
const LANG_LABEL: Record<string, string> = {
  zh: '简体中文', 'zh-Hant': '繁體中文', yue: '粵語',
  en: 'English', ru: 'Русский', ko: '한국어',
}

const items = ref<AgreementRow[]>([])
const editorVisible = ref(false)
const editKey = ref<{ type: string; lang: string } | null>(null)
const form = ref({ type: 'terms', lang: 'zh', content: '' })
const previewHtml = ref('<span style="color:var(--text-muted);font-size:12px">预览区</span>')

function simpleMarkdown(md: string): string {
  return md
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/^### (.+)$/gm, '<h3 style="color:#4ade80;margin:10px 0 4px">$1</h3>')
    .replace(/^## (.+)$/gm, '<h2 style="color:#22d3ee;margin:12px 0 6px">$1</h2>')
    .replace(/^# (.+)$/gm, '<h1 style="color:#22d3ee;margin:14px 0 8px">$1</h1>')
    .replace(/^---+$/gm, '<hr style="border-color:#333;margin:8px 0">')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.+?)\*/g, '<em style="color:#aaa">$1</em>')
    .replace(/`([^`]+)`/g, '<code style="background:#111;padding:2px 5px;border-radius:3px;color:#4ade80">$1</code>')
    .replace(/\[(.+?)\]\((.+?)\)/g, '<a href="$2" style="color:#22d3ee">$1</a>')
    .replace(/\n/g, '<br>')
}

function renderPreview() {
  previewHtml.value = form.value.content ? simpleMarkdown(form.value.content) : '<span style="color:var(--text-muted);font-size:12px">预览区</span>'
}

const editorTitle = ref('新增协议')

function openEditor(item: AgreementRow | null) {
  editKey.value = item ? { type: item.type, lang: item.lang } : null
  editorTitle.value = item ? `编辑协议 ${item.type}/${item.lang}` : '新增协议'
  form.value = { type: item?.type || 'terms', lang: item?.lang || 'zh', content: item?.content || '' }
  renderPreview()
  editorVisible.value = true
}

async function loadAgreements() {
  try {
    items.value = await api<AgreementRow[]>('GET', '/api/v1/agreements')
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
    items.value = []
  }
}

async function loadAndEdit(type: string, lang: string) {
  try {
    const data = await api<AgreementRow>('GET', `/api/v1/agreements/content?type=${encodeURIComponent(type)}&lang=${encodeURIComponent(lang)}`)
    openEditor(data)
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

async function doSaveAgreement() {
  const { type, lang, content } = form.value
  if (!content.trim()) return showToast('协议内容不能为空', 'error')
  try {
    await api('POST', '/api/v1/agreements', { type, lang, content: content.trim() })
    showToast('保存成功')
    editorVisible.value = false
    loadAgreements()
  } catch (e) {
    showToast(e instanceof Error ? e.message : '保存失败', 'error')
  }
}

async function doDelete(type: string, lang: string) {
  try {
    await ElMessageBox.confirm(`确认删除协议 ${type}/${lang}？`, '确认')
    await api('DELETE', `/api/v1/agreements/${encodeURIComponent(type)}/${encodeURIComponent(lang)}`)
    showToast('已删除')
    loadAgreements()
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? e.message : '删除失败', 'error')
  }
}

onMounted(() => loadAgreements())
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">协议管理</div>
      <div class="page-subtitle">维护用户协议与隐私政策的多语言 Markdown 文本，支持实时预览，保存后客户端按界面语言拉取。</div>
    </div>
    <div class="ph-actions">
      <el-button type="primary" @click="openEditor(null)">新增协议</el-button>
    </div>
  </div>
  <div class="card">
    <div class="card-title"><el-icon><Document /></el-icon>协议列表</div>
    <div style="font-size:12px;color:var(--text-muted);margin-bottom:14px">
      支持类型：<code>terms</code>（用户协议）、<code>privacy</code>（隐私政策）；
      支持语言：zh / zh-Hant / yue / en / ru / ko
    </div>

    <el-table :data="items" stripe>
      <template #empty>
        <div class="empty-state">
          <div class="empty-title">暂无协议</div>
          <div class="empty-hint">点击右上角「新增协议」创建首份用户协议或隐私政策。</div>
        </div>
      </template>
      <el-table-column label="协议类型" width="120">
        <template #default="{ row }"><el-tag size="small">{{ TYPE_LABEL[row.type] || row.type }}</el-tag></template>
      </el-table-column>
      <el-table-column label="语言" width="120"><template #default="{ row }">{{ LANG_LABEL[row.lang] || row.lang }}</template></el-table-column>
      <el-table-column label="内容预览" min-width="240">
        <template #default="{ row }">
          <span style="max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text-muted);font-size:12px;display:inline-block">
            {{ (row.content || '').substring(0, 80) }}{{ (row.content || '').length > 80 ? '…' : '' }}
          </span>
        </template>
      </el-table-column>
      <el-table-column label="最后更新" width="170"><template #default="{ row }">{{ fmtTime(row.updated_at) }}</template></el-table-column>
      <el-table-column label="操作" width="150">
        <template #default="{ row }">
          <el-button size="small" @click="loadAndEdit(row.type, row.lang)">编辑</el-button>
          <el-button size="small" type="danger" @click="doDelete(row.type, row.lang)">删除</el-button>
        </template>
      </el-table-column>
    </el-table>
  </div>

  <el-dialog v-model="editorVisible" :title="editorTitle" width="900px">
    <el-form label-width="80px">
      <el-row :gutter="16">
        <el-col :span="12">
          <el-form-item label="协议类型">
            <el-select v-model="form.type" style="width:100%">
              <el-option label="terms（用户协议）" value="terms" />
              <el-option label="privacy（隐私政策）" value="privacy" />
            </el-select>
          </el-form-item>
        </el-col>
        <el-col :span="12">
          <el-form-item label="语言">
            <el-select v-model="form.lang" style="width:100%">
              <el-option label="zh — 简体中文" value="zh" />
              <el-option label="zh-Hant — 繁體中文" value="zh-Hant" />
              <el-option label="yue — 粵語" value="yue" />
              <el-option label="en — English" value="en" />
              <el-option label="ru — Русский" value="ru" />
              <el-option label="ko — 한국어" value="ko" />
            </el-select>
          </el-form-item>
        </el-col>
      </el-row>
      <el-form-item label="协议内容">
        <div class="modal-split-pane">
          <el-input
            v-model="form.content"
            type="textarea"
            :rows="14"
            placeholder="# 用户协议&#10;&#10;请在此输入 Markdown 格式协议内容..."
            style="font-family:monospace;font-size:13px"
            @input="renderPreview"
          />
          <div class="preview-pane" v-html="previewHtml" />
        </div>
      </el-form-item>
    </el-form>
    <template #footer>
      <el-button @click="editorVisible = false">取消</el-button>
      <el-button type="primary" @click="doSaveAgreement">保存</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.modal-split-pane {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
  width: 100%;
}
.preview-pane {
  min-height: 320px;
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 14px;
  overflow-y: auto;
  font-size: 13px;
  line-height: 1.7;
  background: var(--bg-card);
}
</style>
