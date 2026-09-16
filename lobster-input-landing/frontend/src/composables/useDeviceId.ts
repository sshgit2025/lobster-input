/** 浏览器设备标识：注册风控用（对齐 Mac 端 device_id 语义）。
 *  生成一个持久化的 64 位十六进制串存 localStorage；网页无硬件指纹，hardware_fingerprint 留空。 */
const KEY = 'lobster_landing_device_id'

function randomHex(length: number): string {
  const bytes = new Uint8Array(length / 2)
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
    crypto.getRandomValues(bytes)
  } else {
    for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
  }
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
}

export function getDeviceId(): string {
  let id = ''
  try {
    id = localStorage.getItem(KEY) || ''
  } catch {
    id = ''
  }
  if (!id || id.length !== 64) {
    id = randomHex(64)
    try {
      localStorage.setItem(KEY, id)
    } catch {
      /* ignore */
    }
  }
  return id
}
