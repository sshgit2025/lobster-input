package com.lobster.input.core.audio

import kotlin.random.Random

/**
 * 与 Mac / Windows / iOS 桌面端一致的滚动音浪采样。
 */
class AudioWaveformEngine(barCount: Int = 10, initialLevel: Float = 0.08f) {

    private val barCount = barCount.coerceAtLeast(1)
    val levels: MutableList<Float> = MutableList(barCount) { initialLevel }

    fun reset(initialLevel: Float = 0.08f) {
        levels.indices.forEach { levels[it] = initialLevel }
    }

    fun push(inputLevel: Float) {
        val input = inputLevel.coerceIn(0f, 1f)
        val idle = Random.nextFloat() * 0.12f + 0.08f
        val reactive = input * (Random.nextFloat() * 0.23f + 0.72f)
        shift(maxOf(0.05f, minOf(1f, maxOf(idle, reactive))))
    }

    private fun shift(value: Float) {
        if (levels.isEmpty()) return
        levels.removeAt(0)
        levels.add(value)
    }

    fun nextProcessingPhase(phase: Int): Int = (phase + 1) % barCount
}
