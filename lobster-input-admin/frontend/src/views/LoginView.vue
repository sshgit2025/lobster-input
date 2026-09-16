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
    await api('POST', '/api/v1/auth/login', { username: u, password: p })
    sessionStorage.setItem('admin_username', u)
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
        <span class="login-mark">🦞</span>
        <div>
          <div class="login-title">Lobster 管理后台</div>
          <div class="login-subtitle">运营、计费与系统配置控制台</div>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label">管理员账号</label>
        <input v-model="username" class="form-input" type="text" placeholder="请输入账号" autocomplete="username" @keydown.enter="doLogin">
      </div>
      <div class="form-group">
        <label class="form-label">密码</label>
        <input v-model="password" class="form-input" type="password" placeholder="请输入密码" autocomplete="current-password" @keydown.enter="doLogin">
      </div>
      <el-button type="primary" style="width:100%;margin-top:8px" :loading="loading" @click="doLogin">登 录</el-button>
      <div v-if="errMsg" style="color:var(--danger);text-align:center;margin-top:12px;font-size:13px">{{ errMsg }}</div>
    </div>
  </div>
</template>
