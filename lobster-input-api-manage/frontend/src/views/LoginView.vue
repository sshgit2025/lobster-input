<script setup lang="ts">
import { ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { api } from '@/api'

const router = useRouter()
const route = useRoute()
const username = ref('')
const password = ref('')
const errMsg = ref('')
const loading = ref(false)

async function doLogin() {
  const u = username.value.trim()
  const p = password.value
  if (!u || !p) {
    errMsg.value = '请输入账号和密码'
    return
  }
  loading.value = true
  errMsg.value = ''
  try {
    await api('/api/v1/auth/login', 'POST', { username: u, password: p })
    const redirect = (route.query.redirect as string) || '/dashboard'
    await router.replace(redirect)
  } catch (e) {
    errMsg.value = e instanceof Error ? e.message : '登录失败'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="login-wrap">
    <div class="login-card">
      <div class="login-brand">
        <span class="login-mark">🔑</span>
        <div>
          <div class="login-title">API Pool Manager</div>
          <div class="login-subtitle">API Key 号池管理平台</div>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label">用户名</label>
        <input v-model="username" class="form-input" type="text" autocomplete="username" @keydown.enter="doLogin">
      </div>
      <div class="form-group">
        <label class="form-label">密码</label>
        <input v-model="password" class="form-input" type="password" autocomplete="current-password" @keydown.enter="doLogin">
      </div>
      <button class="btn btn-primary" style="width:100%;justify-content:center;margin-top:8px" :disabled="loading" @click="doLogin">
        {{ loading ? '登录中...' : '登 录' }}
      </button>
      <div v-if="errMsg" style="color:var(--danger);text-align:center;margin-top:12px;font-size:13px">{{ errMsg }}</div>
    </div>
  </div>
</template>
