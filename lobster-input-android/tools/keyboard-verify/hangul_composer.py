# Hangul 2-set(두벌식)组字自动机参照实现(与 Kotlin/Swift 落地版逐行对齐)。
# Unicode: 音节 = 0xAC00 + (cho*21 + jung)*28 + jong
CHO = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
JUNG = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ", "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ"]
JONG = ["", "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]

# 复合中声:ㅗ+ㅏ=ㅘ ...
JUNG_COMBINE = {("ㅗ", "ㅏ"): "ㅘ", ("ㅗ", "ㅐ"): "ㅙ", ("ㅗ", "ㅣ"): "ㅚ",
                ("ㅜ", "ㅓ"): "ㅝ", ("ㅜ", "ㅔ"): "ㅞ", ("ㅜ", "ㅣ"): "ㅟ",
                ("ㅡ", "ㅣ"): "ㅢ"}
# 复合终声:ㄱ+ㅅ=ㄳ ...
JONG_COMBINE = {("ㄱ", "ㅅ"): "ㄳ", ("ㄴ", "ㅈ"): "ㄵ", ("ㄴ", "ㅎ"): "ㄶ",
                ("ㄹ", "ㄱ"): "ㄺ", ("ㄹ", "ㅁ"): "ㄻ", ("ㄹ", "ㅂ"): "ㄼ", ("ㄹ", "ㅅ"): "ㄽ",
                ("ㄹ", "ㅌ"): "ㄾ", ("ㄹ", "ㅍ"): "ㄿ", ("ㄹ", "ㅎ"): "ㅀ",
                ("ㅂ", "ㅅ"): "ㅄ"}
JUNG_SPLIT = {v: k for k, v in JUNG_COMBINE.items()}
JONG_SPLIT = {v: k for k, v in JONG_COMBINE.items()}
VOWELS = set(JUNG)


class HangulComposer:
    """状态:cho/jung/jong(compatibility jamo 字符或 None)。
    feed(jamo) -> committed(str,需上屏的定稿文本);组合中音节由 current() 给出。
    backspace() -> True 表示已在组合内消化;False 表示无组合态需删文档字符。
    flush() -> 把组合中音节定稿返回。
    """

    def __init__(self):
        self.cho = None
        self.jung = None
        self.jong = None

    def is_empty(self):
        return self.cho is None and self.jung is None and self.jong is None

    def current(self):
        """当前组合中显示的字符(未定稿)。"""
        if self.cho is not None and self.jung is not None:
            ci = CHO.index(self.cho)
            ji = JUNG.index(self.jung)
            gi = JONG.index(self.jong) if self.jong else 0
            return chr(0xAC00 + (ci * 21 + ji) * 28 + gi)
        if self.cho is not None:
            return self.cho
        if self.jung is not None:
            return self.jung
        return ""

    def _reset(self):
        self.cho = None; self.jung = None; self.jong = None

    def flush(self):
        s = self.current()
        self._reset()
        return s

    def feed(self, jamo):
        """输入一个 compatibility jamo,返回需定稿上屏的文本(可空)。"""
        if jamo in VOWELS:
            return self._feed_vowel(jamo)
        return self._feed_consonant(jamo)

    def _feed_consonant(self, c):
        if self.cho is None and self.jung is None:
            # 空态或孤立辅音? cho=None,jung=None,jong 不可能单独存在
            self.cho = c
            return ""
        if self.jung is None:
            # 只有 cho:辅音+辅音 → 前一个定稿,新辅音开始(2-set 双辅音走 shift,不自动合并)
            out = self.cho
            self._reset(); self.cho = c
            return out
        # cho+jung(+jong):尝试作终声
        if self.jong is None:
            # 【修 孤元音丢辅音】终声必须挂在完整 cho+jung 音节上;孤元音(cho=None)
            # 挂终声后 current() 渲染不出、辅音被静默吞掉(ㅏ+ㄱ 曾丢 ㄱ)。
            # 标准行为(Gboard/iOS):孤元音定稿,辅音另起新组合。
            if self.cho is not None and c in JONG:
                self.jong = c
                return ""
            # 孤元音 / 不能当终声(ㄸㅃㅉ):定稿当前,新起
            out = self.current()
            self._reset(); self.cho = c
            return out
        # 已有终声:尝试复合终声
        comb = JONG_COMBINE.get((self.jong, c))
        if comb is not None:
            self.jong = comb
            return ""
        out = self.current()
        self._reset(); self.cho = c
        return out

    def _feed_vowel(self, v):
        if self.jong is not None:
            # 终声借调:复合终声拆最后一个辅音做新 cho,单终声整个移走
            if self.jong in JONG_SPLIT:
                first, last = JONG_SPLIT[self.jong]
                self.jong = first
                out = self.current()
                self._reset(); self.cho = last; self.jung = v
                return out
            moved = self.jong
            self.jong = None
            out = self.current()
            self._reset()
            self.cho = moved if moved in CHO else None
            self.jung = v
            if self.cho is None:
                # ㄳ 类不可作 cho(已在 split 分支);单终声都在 CHO 内,保险
                out += v
                self._reset()
            return out
        if self.jung is not None:
            comb = JUNG_COMBINE.get((self.jung, v))
            if comb is not None:
                self.jung = comb
                return ""
            # 元音+不可复合元音:定稿当前,新起孤立元音
            out = self.current()
            self._reset(); self.jung = v
            return out
        if self.cho is not None:
            self.jung = v
            return ""
        self.jung = v
        return ""

    def backspace(self):
        """组合态内逐 jamo 拆解;返回 False 表示无组合态。"""
        if self.jong is not None:
            if self.jong in JONG_SPLIT:
                self.jong = JONG_SPLIT[self.jong][0]
            else:
                self.jong = None
            return True
        if self.jung is not None:
            if self.jung in JUNG_SPLIT:
                self.jung = JUNG_SPLIT[self.jung][0]
            else:
                self.jung = None
                if self.cho is None:
                    return True  # 孤立元音删完,组合态清空
            return True
        if self.cho is not None:
            self.cho = None
            return True
        return False


def type_text(seq):
    """模拟连续击键,返回最终文本(committed + current)。"""
    c = HangulComposer()
    out = ""
    for j in seq:
        out += c.feed(j)
    return out + c.flush()


if __name__ == "__main__":
    fails = []

    def check(tag, got, want):
        ok = got == want
        print(("OK " if ok else "FAIL"), tag, f"got={got!r} want={want!r}")
        if not ok:
            fails.append(tag)

    # 基础组字
    check("안", type_text("ㅇㅏㄴ"), "안")
    check("안녕", type_text("ㅇㅏㄴㄴㅕㅇ"), "안녕")
    check("안녕하세요", type_text("ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ"), "안녕하세요")
    check("한국", type_text("ㅎㅏㄴㄱㅜㄱ"), "한국")
    # 终声借调:같이 → ㄱㅏㅌㅇㅣ = 가티? 不,ㅌ 后 ㅇ 是辅音;같이 = ㄱㅏㅌ + ㅇㅣ → 갇... 实际打字 ㄱㅏㅌㅇㅣ → 같이
    check("같이", type_text("ㄱㅏㅌㅇㅣ"), "같이")
    # 复合元音
    check("과", type_text("ㄱㅗㅏ"), "과")
    check("왜", type_text("ㅇㅗㅐ"), "왜")
    check("의", type_text("ㅇㅡㅣ"), "의")
    check("워", type_text("ㅇㅜㅓ"), "워")
    # 复合终声 + 借调
    check("닭", type_text("ㄷㅏㄹㄱ"), "닭")
    check("닭이", type_text("ㄷㅏㄹㄱㅇㅣ"), "닭이")  # ㄺ 拆 ㄹ 留 ㄱ 借调
    check("없어", type_text("ㅇㅓㅂㅅㅇㅓ"), "없어")
    check("앉아", type_text("ㅇㅏㄴㅈㅇㅏ"), "앉아")
    # 双辅音(shift 直入)
    check("까", type_text("ㄲㅏ"), "까")
    check("빵", type_text("ㅃㅏㅇ"), "빵")
    check("있다", type_text("ㅇㅣㅆㄷㅏ"), "있다")
    # ㄸㅃㅉ 不能作终声
    check("바ㄸ", type_text("ㅂㅏㄸ"), "바ㄸ")  # flush 后 ㄸ 单独
    check("바따", type_text("ㅂㅏㄸㅏ"), "바따")
    # 孤立 jamo
    check("ㅏ", type_text("ㅏ"), "ㅏ")
    check("ㄱ", type_text("ㄱ"), "ㄱ")
    check("ㅏㅏ", type_text("ㅏㅏ"), "ㅏㅏ")  # 不可复合的元音连打
    check("ㅗㅏ=ㅘ", type_text("ㅗㅏ"), "ㅘ")  # 孤立也可复合
    # 辅音连打(非双辅音)
    check("ㄱㄴ", type_text("ㄱㄴ"), "ㄱㄴ")
    # 感谢
    check("감사합니다", type_text("ㄱㅏㅁㅅㅏㅎㅏㅂㄴㅣㄷㅏ"), "감사합니다")
    # 사랑해
    check("사랑해", type_text("ㅅㅏㄹㅏㅇㅎㅐ"), "사랑해")
    # 터 vs 떠
    check("떡볶이", type_text("ㄸㅓㄱㅂㅗㄲㅇㅣ"), "떡볶이")

    # 退格链:안녕 打完删 2 下 → 안ㄴ + jung 拆... 逐步验证
    c = HangulComposer()
    out = ""
    for j in "ㅇㅏㄴㄴㅕㅇ":
        out += c.feed(j)
    assert out + c.current() == "안녕", (out, c.current())
    # 退格1:녕 → 녀
    assert c.backspace() and out + c.current() == "안녀"
    # 退格2:녀 → 니? 不,ㄴ+ㅕ 删 ㅕ → ㄴ
    assert c.backspace() and out + c.current() == "안ㄴ"
    # 退格3:ㄴ → 空(out 仍是 안)
    assert c.backspace() and out + c.current() == "안"
    # 退格4:组合态空,返回 False(该删文档里的 안 了)
    assert not c.backspace()
    print("OK  退格链 안녕 → 안녀 → 안ㄴ → 안 → (doc)")

    # 复合退格:괜 → 놰? ㄱㅗㅐㄴ;删终声 ㄴ → 괘,删 ㅐ(ㅙ→ㅗ)→ 고,删 ㅗ → ㄱ
    c = HangulComposer()
    for j in "ㄱㅗㅐㄴ":
        c.feed(j)
    assert c.current() == "괜"
    c.backspace(); assert c.current() == "괘"
    c.backspace(); assert c.current() == "고"
    c.backspace(); assert c.current() == "ㄱ"
    c.backspace(); assert c.is_empty()
    print("OK  复合退格 괜 → 괘 → 고 → ㄱ → 空")

    # 复合终声退格:닭 → 달 → 다 → ㄷ
    c = HangulComposer()
    for j in "ㄷㅏㄹㄱ":
        c.feed(j)
    assert c.current() == "닭"
    c.backspace(); assert c.current() == "달"
    c.backspace(); assert c.current() == "다"
    c.backspace(); assert c.current() == "ㄷ"
    print("OK  复合终声退格 닭 → 달 → 다 → ㄷ")

    print()
    print("全部通过" if not fails else f"失败: {fails}")
