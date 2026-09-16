<script setup lang="ts">
import { ref, computed, onBeforeUnmount } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import 'element-plus/theme-chalk/el-message.css'
import { t } from '@/i18n'
import { sendCode, verifyCode, verifyInvite, type AuthResult } from '@/api/auth'
import { useAuthStore } from '@/stores/auth'
import { getDeviceId } from '@/composables/useDeviceId'

const route = useRoute()
const router = useRouter()
const { setEmail } = useAuthStore()

const step = ref<'email' | 'invite'>('email')
const email = ref('')
const code = ref('')
const inviteCode = ref('')
const errMsg = ref('')
const sending = ref(false)
const submitting = ref(false)
const cooldown = ref(0)
let cooldownTimer: ReturnType<typeof setInterval> | null = null

function startCooldown() {
  cooldown.value = 60
  cooldownTimer = setInterval(() => {
    cooldown.value -= 1
    if (cooldown.value <= 0 && cooldownTimer) {
      clearInterval(cooldownTimer)
      cooldownTimer = null
    }
  }, 1000)
}

const sendLabel = computed(() =>
  cooldown.value > 0 ? t('ui_resendCode').replace('{s}', String(cooldown.value)) : t('ui_sendCode'),
)

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : '请求失败'
}

async function doSendCode() {
  const mail = email.value.trim()
  if (!mail || !mail.includes('@')) {
    errMsg.value = t('ui_emailRequired')
    return
  }
  if (cooldown.value > 0 || sending.value) return
  sending.value = true
  errMsg.value = ''
  try {
    await sendCode(mail)
    ElMessage.success(t('ui_codeSent'))
    startCooldown()
  } catch (e) {
    errMsg.value = errorText(e)
  } finally {
    sending.value = false
  }
}

function applyAuth(result: AuthResult) {
  setEmail(result.email)
  const redirect = (route.query.redirect as string) || '/account'
  router.replace(redirect)
}

async function doContinue() {
  const mail = email.value.trim()
  if (!mail || !mail.includes('@')) {
    errMsg.value = t('ui_emailRequired')
    return
  }
  if (!code.value.trim()) {
    errMsg.value = t('ui_codeRequired')
    return
  }
  submitting.value = true
  errMsg.value = ''
  try {
    const result = await verifyCode({
      email: mail,
      code: code.value.trim(),
      device_id: getDeviceId(),
      hardware_fingerprint: '',
    })
    if (result.authenticated) {
      applyAuth(result)
    } else if (result.require_invite) {
      step.value = 'invite'
      errMsg.value = ''
    }
  } catch (e) {
    errMsg.value = errorText(e)
  } finally {
    submitting.value = false
  }
}

function onInviteInput(e: Event) {
  const raw = (e.target as HTMLInputElement).value.toUpperCase().replace(/[^A-Z0-9]/g, '')
  inviteCode.value = raw.slice(0, 8)
}

async function doCompleteRegister() {
  if (inviteCode.value.length < 8) {
    errMsg.value = t('ui_inviteRequired')
    return
  }
  submitting.value = true
  errMsg.value = ''
  try {
    const result = await verifyInvite({
      email: email.value.trim(),
      invite_code: inviteCode.value,
      device_id: getDeviceId(),
      hardware_fingerprint: '',
    })
    if (result.authenticated) applyAuth(result)
  } catch (e) {
    errMsg.value = errorText(e)
  } finally {
    submitting.value = false
  }
}

function backToEmail() {
  step.value = 'email'
  errMsg.value = ''
  inviteCode.value = ''
}

onBeforeUnmount(() => {
  if (cooldownTimer) clearInterval(cooldownTimer)
})
</script>

<template>
  <div class="auth-wrap">
    <div class="auth-card">
      <svg class="auth-mark"><use href="#lobster" /></svg>

      <!-- 邮箱 + 验证码 -->
      <template v-if="step === 'email'">
        <h1 class="auth-title">{{ t('ui_loginTitle') }}</h1>
        <p class="auth-sub">{{ t('ui_loginSub') }}</p>

        <div class="auth-field">
          <label class="auth-label">{{ t('ui_emailLabel') }}</label>
          <input
            v-model="email"
            class="auth-input"
            type="email"
            autocomplete="email"
            :placeholder="t('ui_emailPlaceholder')"
            @keydown.enter="doSendCode"
          />
        </div>
        <div class="auth-field">
          <label class="auth-label">{{ t('ui_codeLabel') }}</label>
          <div class="auth-code-row">
            <input
              v-model="code"
              class="auth-input"
              type="text"
              inputmode="numeric"
              maxlength="6"
              :placeholder="t('ui_codePlaceholder')"
              @keydown.enter="doContinue"
            />
            <button class="auth-code-btn" type="button" :disabled="cooldown > 0 || sending" @click="doSendCode">
              {{ sendLabel }}
            </button>
          </div>
        </div>

        <div v-if="errMsg" class="auth-error">{{ errMsg }}</div>

        <button class="btn-primary auth-submit" type="button" :disabled="submitting" @click="doContinue">
          {{ submitting ? t('ui_loggingIn') : t('ui_continue') }}
        </button>
      </template>

      <!-- 邀请码 -->
      <template v-else>
        <h1 class="auth-title">{{ t('ui_inviteTitle') }}</h1>
        <p class="auth-sub">{{ t('ui_inviteSub') }}</p>

        <div class="auth-field">
          <label class="auth-label">{{ t('ui_inviteLabel') }}</label>
          <input
            :value="inviteCode"
            class="auth-input auth-invite-fmt"
            type="text"
            maxlength="8"
            :placeholder="t('ui_invitePlaceholder')"
            @input="onInviteInput"
            @keydown.enter="doCompleteRegister"
          />
        </div>

        <div v-if="errMsg" class="auth-error">{{ errMsg }}</div>

        <button class="btn-primary auth-submit" type="button" :disabled="submitting" @click="doCompleteRegister">
          {{ submitting ? t('ui_loggingIn') : t('ui_completeRegister') }}
        </button>
        <div class="auth-back" @click="backToEmail">‹ {{ t('ui_emailLabel') }}</div>
      </template>
    </div>
  </div>
</template>
