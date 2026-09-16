package com.lobster.input.core.network

import org.junit.Assert.assertEquals
import org.junit.Test

class RealtimeResumeTest {

    @Test
    fun `空前缀直接返回续传文本`() {
        assertEquals("你好世界", RealtimeResume.mergeWithOverlap("", "你好世界"))
    }

    @Test
    fun `空续传文本直接返回前缀`() {
        assertEquals("你好世界", RealtimeResume.mergeWithOverlap("你好世界", ""))
    }

    @Test
    fun `尾巴重放的重叠被裁剪`() {
        // 断连前缀止于"今天天气不错",重放尾巴让新会话重复识别出"天气不错"
        assertEquals(
            "今天天气不错，我们下午一起去公园",
            RealtimeResume.mergeWithOverlap("今天天气不错", "天气不错，我们下午一起去公园")
        )
    }

    @Test
    fun `标点差异不影响重叠匹配`() {
        // 前缀带句读、续传段不带(或反之),归一化后仍能对齐;
        // 重叠之后 tail 自带的标点属于新识别内容,保留
        assertEquals(
            "今天天气不错，我们，下午一起去公园",
            RealtimeResume.mergeWithOverlap("今天天气不错，我们", "不错我们，下午一起去公园")
        )
    }

    @Test
    fun `续传文本完全被前缀覆盖时不重复`() {
        assertEquals("今天天气不错", RealtimeResume.mergeWithOverlap("今天天气不错", "天气不错"))
    }

    @Test
    fun `无重叠时直接拼接`() {
        assertEquals(
            "今天天气不错去公园散步",
            RealtimeResume.mergeWithOverlap("今天天气不错", "去公园散步")
        )
    }

    @Test
    fun `英文与数字同样参与归一化匹配`() {
        assertEquals(
            "meet at 3pm tomorrow ok",
            RealtimeResume.mergeWithOverlap("meet at 3pm", " 3pm tomorrow ok")
        )
    }
}
