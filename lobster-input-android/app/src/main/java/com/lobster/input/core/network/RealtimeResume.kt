package com.lobster.input.core.network

/**
 * 弱网断连"静默重连续传"的共享参数与文本拼接工具。
 *
 * 上游火山 sauc 协议不支持会话级断线续传(连接断开只能新建会话重新发起),
 * 因此续传由客户端编排:
 *  1. 平时维护"最近已发送音频"的尾巴环形缓冲(partial 滞后于音频,断连瞬间
 *     已发送但未出字的音频会丢,重放尾巴可补回);
 *  2. 断连时冻结当前整句为前缀,新建会话先重放尾巴、再续传断连期间缓冲的音频;
 *  3. 新会话文本与前缀做归一化重叠裁剪后拼接,消除接缝处的丢字/重字;
 *  4. RECONNECT_WINDOW_MS 内未能就绪则放弃,降级为既有的纯文本兜底投递。
 */
object RealtimeResume {
    /** 断连后静默重连的时限;超时降级为纯文本兜底投递 */
    const val RECONNECT_WINDOW_MS = 3_000L

    /** 单次会话内最多自动重连次数,防止弱网抖动下无限循环 */
    const val MAX_RECONNECT_ATTEMPTS = 2

    /** 已发送音频尾巴环形缓冲上限:1.5s @ 16kHz 16bit mono */
    const val SENT_TAIL_LIMIT_BYTES = 48_000

    /**
     * 前缀与续传文本的重叠合并:归一化(仅保留字母数字)后找「前缀后缀 == 续传前缀」
     * 的最长重叠并从续传文本中裁掉,再拼接。无重叠时直接拼接。
     */
    fun mergeWithOverlap(prefix: String, tail: String): String {
        if (prefix.isEmpty()) return tail
        if (tail.isEmpty()) return prefix
        val normalizedPrefix = normalize(prefix)
        val normalizedTail = normalize(tail)
        var overlap = 0
        var k = minOf(normalizedPrefix.length, normalizedTail.length)
        while (k > 0) {
            if (normalizedPrefix.endsWith(normalizedTail.substring(0, k))) {
                overlap = k
                break
            }
            k--
        }
        if (overlap == 0) return prefix + tail
        var count = 0
        var cut = tail.length
        for (i in tail.indices) {
            if (tail[i].isLetterOrDigit()) count++
            if (count >= overlap) {
                cut = i + 1
                break
            }
        }
        return prefix + tail.substring(cut)
    }

    private fun normalize(s: String): String = buildString(s.length) {
        for (ch in s) if (ch.isLetterOrDigit()) append(ch)
    }
}
