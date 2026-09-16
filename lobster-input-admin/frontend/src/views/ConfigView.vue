<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

interface SettingDef {
  key: string
  label: string
  description?: string
  type: string
  default?: number | boolean
  min?: number
  max?: number
}

const settingDefs = ref<SettingDef[]>([])
const settingValues = ref<Record<string, number | boolean>>({})

async function loadPage() {
  const settings = await api<{ definitions?: SettingDef[]; values?: Record<string, number | boolean> }>('GET', '/api/v1/config/system-settings')
  settingDefs.value = settings.definitions || []
  settingValues.value = settings.values || {}
  settingDefs.value.forEach((def) => {
    if (settingValues.value[def.key] === undefined) {
      settingValues.value[def.key] = def.default ?? (def.type === 'bool' ? false : 0)
    }
  })
}

function readSettings(): Record<string, number | boolean> {
  const settings: Record<string, number | boolean> = {}
  settingDefs.value.forEach((def) => {
    settings[def.key] = settingValues.value[def.key] ?? def.default ?? (def.type === 'bool' ? false : 0)
  })
  return settings
}

async function saveSettings() {
  try {
    await api('POST', '/api/v1/config/system-settings', { settings: readSettings() })
    showToast('系统配置已保存')
    await loadPage()
  } catch (e) {
    showToast(e instanceof Error ? e.message : '保存失败', 'error')
  }
}

async function cleanupObsolete() {
  try {
    const res = await api<{ deleted?: number }>('POST', '/api/v1/config/cleanup-obsolete', {})
    showToast(`已清理 ${res.deleted || 0} 个废弃配置`)
  } catch (e) {
    showToast(e instanceof Error ? e.message : '清理失败', 'error')
  }
}

onMounted(() => {
  loadPage().catch((e) => showToast(e instanceof Error ? e.message : '加载失败', 'error'))
})
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">系统配置</div>
      <div class="page-subtitle">集中维护注册风控开关，保存后实时下发至全端。节点扣费规则请在「计费经济性」页管理。</div>
    </div>
  </div>

  <div class="card">
    <div class="card-title">注册与风控</div>
    <div class="settings-grid">
      <div v-for="def in settingDefs" :key="def.key" class="setting-item">
        <label class="form-label">{{ def.label }}</label>
        <div style="margin:8px 0">
          <el-switch v-if="def.type === 'bool'" v-model="settingValues[def.key] as boolean" />
          <input
            v-else
            v-model.number="settingValues[def.key]"
            class="form-input"
            type="number"
            :min="def.min ?? 0"
            :max="def.max"
          >
        </div>
        <div class="setting-desc">{{ def.description || '' }}</div>
      </div>
    </div>
    <div style="margin-top:16px">
      <el-button type="primary" @click="saveSettings">保存系统配置</el-button>
      <el-button @click="cleanupObsolete">清理废弃配置</el-button>
    </div>
  </div>
</template>

<style scoped>
.settings-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 16px;
}
.setting-item {
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 14px;
  background: rgba(255, 255, 255, 0.02);
}
.setting-desc {
  font-size: 12px;
  color: var(--text-muted);
  line-height: 1.5;
}
</style>
