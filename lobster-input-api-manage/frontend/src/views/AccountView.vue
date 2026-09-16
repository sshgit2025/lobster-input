<script setup lang="ts">
import { ref } from 'vue'
import { ElMessage } from 'element-plus'
import { Lock } from '@element-plus/icons-vue'
import { api } from '@/api'

const oldPwd = ref('')
const newPwd = ref('')
const confirmPwd = ref('')
const loading = ref(false)

async function submit() {
  if (newPwd.value !== confirmPwd.value) {
    ElMessage.error('两次密码不一致')
    return
  }
  loading.value = true
  try {
    await api('/api/v1/auth/change-password', 'POST', {
      old_password: oldPwd.value,
      new_password: newPwd.value,
    })
    ElMessage.success('密码已修改')
    oldPwd.value = ''
    newPwd.value = ''
    confirmPwd.value = ''
  } catch (e) {
    ElMessage.error(e instanceof Error ? e.message : '修改失败')
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="page-header">
    <div>
      <h1 class="page-title">账号安全</h1>
      <div class="page-subtitle">定期更换登录口令,保障号池后台访问安全。</div>
    </div>
  </div>
  <div class="card" style="max-width:480px">
    <div class="card-title"><el-icon><Lock /></el-icon> 修改密码</div>
    <form @submit.prevent="submit">
      <div class="form-group">
        <label class="form-label">当前密码</label>
        <input v-model="oldPwd" class="form-input" type="password" required>
      </div>
      <div class="form-group">
        <label class="form-label">新密码</label>
        <input v-model="newPwd" class="form-input" type="password" required minlength="6">
      </div>
      <div class="form-group">
        <label class="form-label">确认新密码</label>
        <input v-model="confirmPwd" class="form-input" type="password" required>
      </div>
      <button class="btn btn-primary" type="submit" :disabled="loading">{{ loading ? '保存中...' : '保存' }}</button>
    </form>
  </div>
</template>
