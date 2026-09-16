package com.lobster.input.keyboard.pinyin

/**
 * 模糊音 + 容错纠错(引擎层无状态工具)。
 *
 * 设计对齐 RIME/搜狗:模糊音与纠错分两层、各自可控。
 *  - 模糊音:把一个合法音节派生出"等价音节集合"(平翘舌、前后鼻音、边鼻音…),按开关启用。
 *  - 纠错:对单个音节做编辑距离≤1(替换/插入/删除/邻键)还原成合法音节,仅在精确/模糊不足时兜底。
 *
 * 注意:模糊音派生只对"合法音节"做,声母/韵母规则覆盖 i/u 介音变体
 *  (an/ang 规则天然覆盖 ian/iang、uan/uang;故无需单列)。
 */
object PinyinFuzzy {

    /** 模糊音开关集合(默认全关,由用户在设置页逐项开启)。 */
    data class Settings(
        val zZh: Boolean = false,   // z ↔ zh
        val cCh: Boolean = false,   // c ↔ ch
        val sSh: Boolean = false,   // s ↔ sh
        val lN: Boolean = false,    // l ↔ n
        val fH: Boolean = false,    // f ↔ h
        val rL: Boolean = false,    // r ↔ l
        val anAng: Boolean = false, // an ↔ ang (含 ian/iang、uan/uang)
        val enEng: Boolean = false, // en ↔ eng
        val inIng: Boolean = false, // in ↔ ing
        val correction: Boolean = false // 容错纠错(编辑距离≤1)
    ) {
        val anyInitial get() = zZh || cCh || sSh || lN || fH || rL
        val anyFinal get() = anAng || enEng || inIng
        val anyFuzzy get() = anyInitial || anyFinal
    }

    /** 邻键表(QWERTY),用于纠错的邻键替换。 */
    private val neighbors = mapOf(
        'q' to "wa", 'w' to "qes", 'e' to "wrd", 'r' to "etf", 't' to "ryg",
        'y' to "tuh", 'u' to "yij", 'i' to "uok", 'o' to "ipl", 'p' to "ol",
        'a' to "qsz", 's' to "awdz x", 'd' to "serfcx", 'f' to "drtgvc",
        'g' to "ftyhbv", 'h' to "gyujnb", 'j' to "huikmn", 'k' to "jiolm",
        'l' to "kop", 'z' to "asx", 'x' to "zsdc", 'c' to "xdfv",
        'v' to "cfgb", 'b' to "vghn", 'n' to "bhjm", 'm' to "njk"
    )

    /**
     * 把一个合法音节派生出模糊等价音节集合(含自身)。
     * 仅用于在候选查词时扩展;调用方需对模糊命中做降权。
     */
    fun variants(syllable: String, s: Settings): Set<String> {
        if (!s.anyFuzzy || syllable.isEmpty()) return setOf(syllable)
        var set = linkedSetOf(syllable)
        // ---- 声母 ----
        if (s.anyInitial) {
            val add = LinkedHashSet<String>()
            for (v in set) {
                // 双向:对每个开启的对,长前缀优先判定
                if (s.zZh) { if (v.startsWith("zh")) add.add("z" + v.substring(2)) else if (v.startsWith("z")) add.add("zh" + v.substring(1)) }
                if (s.cCh) { if (v.startsWith("ch")) add.add("c" + v.substring(2)) else if (v.startsWith("c")) add.add("ch" + v.substring(1)) }
                if (s.sSh) { if (v.startsWith("sh")) add.add("s" + v.substring(2)) else if (v.startsWith("s")) add.add("sh" + v.substring(1)) }
                if (s.lN) { if (v.startsWith("l")) add.add("n" + v.substring(1)) else if (v.startsWith("n")) add.add("l" + v.substring(1)) }
                if (s.fH) { if (v.startsWith("f")) add.add("h" + v.substring(1)) else if (v.startsWith("h")) add.add("f" + v.substring(1)) }
                if (s.rL) { if (v.startsWith("r")) add.add("l" + v.substring(1)) else if (v.startsWith("l")) add.add("r" + v.substring(1)) }
            }
            set.addAll(add)
        }
        // ---- 韵母(前后鼻音) ----
        if (s.anyFinal) {
            val add = LinkedHashSet<String>()
            for (v in set) {
                if (s.anAng) { if (v.endsWith("ang")) add.add(v.dropLast(3) + "an") else if (v.endsWith("an")) add.add(v.dropLast(2) + "ang") }
                if (s.enEng) { if (v.endsWith("eng")) add.add(v.dropLast(3) + "en") else if (v.endsWith("en")) add.add(v.dropLast(2) + "eng") }
                if (s.inIng) { if (v.endsWith("ing")) add.add(v.dropLast(3) + "in") else if (v.endsWith("in")) add.add(v.dropLast(2) + "ing") }
            }
            set.addAll(add)
        }
        return set
    }

    /**
     * 对一个"非法音节"做编辑距离≤1 纠错,返回可能的合法音节(由 isSyllable 校验)。
     * 仅覆盖:邻键替换、漏字母(插入)、多字母(删除)。结果上限 8。
     */
    fun corrections(token: String, isSyllable: (String) -> Boolean): List<String> {
        if (token.length !in 2..6) return emptyList()
        val out = LinkedHashSet<String>()
        val letters = "abcdefghijklmnopqrstuvwxyz"
        // 删除一个字母
        for (i in token.indices) {
            val c = token.removeRange(i, i + 1)
            if (c.length >= 1 && isSyllable(c)) out.add(c)
        }
        // 替换为邻键
        for (i in token.indices) {
            for (n in neighbors[token[i]].orEmpty()) {
                if (n == ' ') continue
                val c = token.substring(0, i) + n + token.substring(i + 1)
                if (isSyllable(c)) out.add(c)
            }
            if (out.size >= 8) return out.toList()
        }
        // 插入一个字母
        for (i in 0..token.length) {
            for (ch in letters) {
                val c = token.substring(0, i) + ch + token.substring(i)
                if (isSyllable(c)) out.add(c)
                if (out.size >= 8) return out.toList()
            }
        }
        return out.toList()
    }
}
