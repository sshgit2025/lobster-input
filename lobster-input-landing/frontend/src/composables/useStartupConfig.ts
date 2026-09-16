/** 启动配置（注册/邀请码/人数上限开关）：登录注册前拉取，决定界面交互。
 *  模块级单例缓存，避免重复请求。 */
import { ref } from 'vue'
import { fetchStartupConfig, type StartupConfig } from '@/api/config'

const config = ref<StartupConfig | null>(null)
const loading = ref(false)

async function load(force = false): Promise<StartupConfig | null> {
  if (config.value && !force) return config.value
  if (loading.value) return config.value
  loading.value = true
  try {
    config.value = await fetchStartupConfig()
  } catch {
    config.value = null
  } finally {
    loading.value = false
  }
  return config.value
}

export function useStartupConfig() {
  return { config, loading, load }
}
