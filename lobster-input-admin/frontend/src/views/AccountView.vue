<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { Lock } from '@element-plus/icons-vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

const router = useRouter()
const oldPwd = ref('')
const newPwd = ref('')
const confirmPwd = ref('')

async function doChangePwd() {
  if (!oldPwd.value || !newPwd.value) { showToast('请填写完整', 'error'); return }
  if (newPwd.value !== confirmPwd.value) { showToast('两次密码不一致', 'error'); return }
  if (newPwd.value.length < 8) { showToast('新密码至少8位', 'error'); return }
  try {
    await api('POST', '/api/v1/auth/change-password', { old_password: oldPwd.value, new_password: newPwd.value })
    showToast('密码修改成功，请重新登录')
    setTimeout(() => router.push('/login'), 1500)
  } catch (e) {
    showToast(e instanceof Error ? e.message : '修改失败', 'error')
  }
}
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">账号安全</div>
      <div class="page-subtitle">管理你的管理员登录密码。修改成功后需重新登录以确保账号安全。</div>
    </div>
  </div>
  <div class="card" style="max-width:420px;margin:0 auto">
    <div class="card-title">
      <el-icon><Lock /></el-icon>
      修改密码
    </div>
    <div class="form-group">
      <label class="form-label">当前密码</label>
      <input v-model="oldPwd" class="form-input" type="password" placeholder="请输入当前密码">
    </div>
    <div class="form-group">
      <label class="form-label">新密码</label>
      <input v-model="newPwd" class="form-input" type="password" placeholder="至少8位，包含字母和数字">
    </div>
    <div class="form-group">
      <label class="form-label">确认新密码</label>
      <input v-model="confirmPwd" class="form-input" type="password" placeholder="再次输入新密码">
    </div>
    <el-button type="primary" style="width:100%" @click="doChangePwd">修改密码</el-button>
  </div>
</template>
