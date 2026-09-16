import { ElMessage } from 'element-plus'

export function showToast(msg: string, type: 'success' | 'error' = 'success'): void {
  ElMessage({ message: msg, type: type === 'error' ? 'error' : 'success', duration: 3000 })
}
