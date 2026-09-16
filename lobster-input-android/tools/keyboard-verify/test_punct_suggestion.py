# -*- coding: utf-8 -*-
"""候选栏标点联想 v2(2026-07-23,上下文感知模型,可执行规格)。

产品定义(见 lobster-input-android/docs/keyboard/候选栏标点联想设计方案.md §3):
  中文上屏词/句后(联想态),候选栏联想流 = 标点候选(1~2,头部) + emoji + 词语联想(顺序不变)。

  设计哲学(证据驱动:语燕输入法开源实现 + 聊天标点用户研究):
    - 逗号是默认主力,句号永不占首位(聊天句号有"冷漠/生气"语义)
    - ?/! 按句型置顶,第二槽给逗号("你好吗,我很好"式续句)
    - 规则小而硬编码:词法信号(疑问/感叹/连词) + 上下文统计(句长/逗号数/刚打标点)

  规则表(按序首个命中):
    0 抑制: beforeText 以句读标点结尾 / 单字中性组词中途 → []
    1 疑问 → [？, ，]: 尾 吗/嘛/呢;含 什么/怎么/为什么/谁/哪/何时/多少/多久/几点/难道/岂不/是否/能否/可否/可不可以/有没有/行不行/好不好/是不是/对不对
    2 感叹 → [！, ，]: 尾 啊/呀/啦/哇/呐/噢/呗/哟;尾情绪词(笑死/气死/救命/绝了/好家伙/哈哈/累死/馋死/爱死/吓死/羡慕死);
                       尾致谢(谢谢/感谢/恭喜/祝贺/加油/辛苦);太…了
    3 连词 → [，]: 精确命中 但是/可是/不过/然而/然后/接着/而且/并且/所以/因此/因为/如果/要是/既然/
                     虽然/尽管/即使/哪怕/除非/由于/或者/还有/另外/首先/其次/比如/特别是/尤其是/对了/话说/顺便/总之/反正/其实
    4 中性-发展中(逗号数≥1 或 句长≥12) → [，, 。]
    5 中性-新开句 → [，]

  抑制实现:控制器读宿主 textBeforeCursor(64) 实时判定(替代 v1 手动标志位),
           闭合括号()"》」』】] 不算"刚打过标点"。
"""

QUESTION_TAILS = ("吗", "嘛", "呢")
QUESTION_CONTAINS = ("什么", "怎么", "为什么", "谁", "哪里", "哪个", "哪儿", "哪些", "哪天",
                     "何时", "多少", "多久", "几点",
                     "难道", "岂不", "是否", "能否", "可否", "可不可以", "有没有",
                     "行不行", "好不好", "是不是", "对不对")
EXCLAIM_TAILS = ("啊", "呀", "啦", "哇", "呐", "噢", "呗", "哟")
# 情绪词用包含匹配("笑死我了"式后缀);致谢类除"加油"外同(加油站误伤→加油用尾部匹配)
EXCLAIM_CONTAINS = ("笑死", "气死", "救命", "绝了", "好家伙", "哈哈", "累死", "馋死",
                    "爱死", "吓死", "羡慕死",
                    "谢谢", "感谢", "恭喜", "祝贺", "辛苦")
EXCLAIM_WORD_TAILS = ("加油",)
CONNECTIVES = ("但是", "可是", "不过", "然而", "然后", "接着", "而且", "并且", "所以",
               "因此", "因为", "如果", "要是", "既然", "虽然", "尽管", "即使", "哪怕",
               "除非", "由于", "或者", "还有", "另外", "首先", "其次", "比如", "特别是",
               "尤其是", "对了", "话说", "顺便", "总之", "反正", "其实")

# 句读标点:光标前文本以这些结尾 → 刚打过标点,抑制(等下一个词)
MID_PUNCTS = set("，。！？、～…：；,.!?;:")
# 句末终止符:切句边界
SENTENCE_ENDS = set("。？！!?…～\n")
# 中性长句阈值
CLAUSE_LEN_END = 12


def _clause(before_text):
    """光标前文本 → 当前句片段(自最近句末符之后,截尾空白)。"""
    t = before_text.rstrip()
    cut = 0
    for i, ch in enumerate(t):
        if ch in SENTENCE_ENDS:
            cut = i + 1
    return t[cut:]


def punct_suggestions(last_word, before_text=""):
    """镜像三端 PunctuationSuggestion.suggestions(lastWord, beforeText)。返回 0~2 个有序标点。"""
    if not last_word:
        return []
    tail = before_text.rstrip()
    if tail and tail[-1] in MID_PUNCTS:
        return []  # 刚打过标点(含语音上屏),等下一个词
    # 1 疑问
    if last_word.endswith(QUESTION_TAILS) or any(k in last_word for k in QUESTION_CONTAINS):
        return ["？", "，"]
    # 2 感叹
    if (last_word.endswith(EXCLAIM_TAILS) or last_word.endswith(EXCLAIM_WORD_TAILS)
            or any(k in last_word for k in EXCLAIM_CONTAINS)
            or ("太" in last_word and last_word.endswith("了"))):
        return ["！", "，"]
    # 单字中性 = 组词中途,不出标点(放在语义判定后:吗/啊等单字语气词不受影响)
    if len(last_word) == 1:
        return []
    # 3 连词
    if last_word in CONNECTIVES:
        return ["，"]
    # 4/5 中性:逗号主力;发展中句子再给句号第二槽
    clause = _clause(before_text)
    commas = clause.count("，") + clause.count(",")
    if commas >= 1 or len(clause) >= CLAUSE_LEN_END:
        return ["，", "。"]
    return ["，"]


class MiniHost:
    """模拟宿主输入框:before + 光标 + after。"""

    def __init__(self, before="", after=""):
        self.before = before
        self.after = after

    def commit(self, s):
        self.before += s

    def backspace(self):
        if self.before:
            self.before = self.before[:-1]

    def text_before_cursor(self, n=64):
        return self.before[-n:]

    def text(self):
        return self.before + "|" + self.after


class MiniController:
    """镜像三端 KeyboardController 联想态相关切片(v2)。"""

    def __init__(self, host, chinese=True, password=False):
        self.host = host
        self.chinese = chinese
        self.password = password
        self.composing = ""
        self.sym_candidate_mode = False
        self.last_word = None
        self.punct_consumed_for = None
        self.learned = []  # 学习记录,验证"点标点不学习"

    def candidates(self):
        """镜像 refreshCandidates 联想分支:v2 = 标点(头部) + 词语联想(顺序不变)。"""
        if self.composing:
            return ["<拼音候选>"]
        if self.sym_candidate_mode:
            return ["<1键符号>"]
        if not (self.chinese and self.last_word and not self.password):
            return []
        puncts = []
        bt = self.host.text_before_cursor()
        if bt:
            # 有上下文:文本判定是唯一事实源(退格/外部编辑自然生效)
            puncts = punct_suggestions(self.last_word, bt)
        elif self.punct_consumed_for != self.last_word:
            # 取不到上文(iOS 少数 App):词法规则 + punctConsumedFor 兜底防重复
            puncts = punct_suggestions(self.last_word, "")
        return puncts + self.assoc_words(self.last_word)

    @staticmethod
    def assoc_words(prev):
        # 词语联想占位:顺序即契约(用户 bigram 优先于内置)
        table = {"你好吗": ["我很好", "挺好的"], "今天": ["天气", "晚上"], "谢谢": ["你", "大家"]}
        return list(table.get(prev, ["<联想词>"]))

    def commit_word(self, word):
        """选词上屏(普通候选/联想词)。"""
        self.host.commit(word)
        self.learned.append((self.last_word, word))
        self.last_word = word

    def select_punct(self, p):
        """点选标点候选:直接上屏、不学习、保 lastWord、同词兜底抑制。"""
        self.host.commit(p)
        self.punct_consumed_for = self.last_word

    def commit_sym_char(self, ch):
        """键盘标点键/语音上屏文本(不走候选)。"""
        self.host.commit(ch)


def bar_collapsed(composing_display, first_is_symbol):
    """镜像三端 CandidateBarView 收起条件(2026-07-12 契约,本特性零改动)。"""
    return len(composing_display) > 0 or first_is_symbol


fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
    if not cond:
        fails.append(name)


def run():
    # ===== 1. 疑问规则表 =====
    for w in ("你好吗", "好吗", "在吗", "走嘛", "什么呢", "什么", "怎么", "怎么样", "为什么",
              "谁", "哪里", "哪个", "何时", "多少", "多久", "几点", "难道", "岂不", "是否",
              "能否", "可不可以", "有没有", "行不行", "好不好", "是不是", "对不对"):
        got = punct_suggestions(w, w)
        check(f"疑问[{w}]→？头，次", got == ["？", "，"], f"{got}")
    # 歧义词不进疑问表
    for w in ("走吧", "好的吧", "哦", "茶几", "窗明几净"):
        got = punct_suggestions(w, w)
        check(f"歧义词[{w}]不推问号", "？" not in got, f"{got}")

    # ===== 2. 感叹规则表 =====
    for w in ("真好啊", "是呀", "太棒啦", "哇", "呐", "噢", "呗", "哟",
              "笑死", "气死我了", "救命", "绝了", "好家伙", "哈哈", "累死", "爱死",
              "谢谢", "感谢你", "恭喜", "祝贺你", "加油", "辛苦了"):
        got = punct_suggestions(w, w)
        check(f"感叹[{w}]→！头，次", got == ["！", "，"], f"{got}")
    for w in ("太好了", "太棒了", "太离谱了"):
        got = punct_suggestions(w, w)
        check(f"太…了[{w}]→！头，次", got == ["！", "，"], f"{got}")
    # 误伤面:包含但不结尾/陈述句
    for w in ("加油站", "太", "真", "星光啊 resolution"):
        got = punct_suggestions(w, w)
        check(f"非感叹[{w}]不推叹号", "！" not in got, f"{got}")

    # ===== 3. 连词规则表 =====
    for w in ("但是", "可是", "不过", "然而", "然后", "接着", "而且", "并且", "所以",
              "因此", "因为", "如果", "要是", "既然", "虽然", "尽管", "即使", "哪怕",
              "除非", "由于", "或者", "还有", "另外", "首先", "其次", "比如", "特别是",
              "尤其是", "对了", "话说", "顺便", "总之", "反正", "其实"):
        got = punct_suggestions(w, w)
        check(f"连词[{w}]→单逗号", got == ["，"], f"{got}")

    # ===== 4. 中性两档(上下文统计) =====
    # 新开短句 → 单逗号(句号不强推)
    for w, ctx in (("今天天气不错", "今天天气不错"), ("今天", "今天"), ("我去", "我去")):
        got = punct_suggestions(w, ctx)
        check(f"中性短句[{w}]→单逗号", got == ["，"], f"{got}")
    # 发展中(已有逗号)→ 逗号+句号
    got = punct_suggestions("我心情很好", "今天天气不错，我心情很好")
    check("已有逗号→[，。]", got == ["，", "。"], f"{got}")
    # 发展中(句长≥12,无逗号)→ 逗号+句号
    got = punct_suggestions("好", "今天天气真的是特别特别的")  # 单字被拦,换个
    got = punct_suggestions("非常好", "今天天气真的是特别非常好")
    check("长句(≥12字)→[，。]", got == ["，", "。"], f"{got}")
    # 句号永不占首位(全规则面抽查)
    for w in ("你好吗", "太好了", "但是", "今天", "我心情很好"):
        got = punct_suggestions(w, "前文，" + w if w == "我心情很好" else w)
        if "。" in got:
            check(f"[{w}]句号不占首位", got[0] != "。", f"{got}")

    # ===== 5. 抑制条件 =====
    # 5a. 光标前文本以句读标点结尾 → 抑制(覆盖手动打标点/语音上屏)
    for p in ("，", "。", "？", "！", "、", "～", "…", "：", "；", ",", ".", "!", "?", ";", ":"):
        got = punct_suggestions("我很好", f"你好吗{p}")
        check(f"刚打[{p}]→抑制", got == [], f"{got}")
    # 5b. 闭合括号不算"刚打过标点":（测试）后推荐逗号是合理续写
    got = punct_suggestions("测试", "（测试）")
    check("闭合括号后仍推荐", got == ["，"], f"{got}")
    got = punct_suggestions("测试", "《测试》")
    check("书名号闭合后仍推荐", got == ["，"], f"{got}")
    # 5c. 单字中性 = 组词中途抑制
    for w in ("我", "好", "吃", "在"):
        got = punct_suggestions(w, w)
        check(f"单字中性[{w}]→抑制", got == [], f"{got}")
    # 5d. 单字语气词不受单字抑制(吗/啊是语义单字)
    check("单字[吗]→疑问", punct_suggestions("吗", "你好 吗".replace(" ", "")) == ["？", "，"], "")
    check("单字[啊]→感叹", punct_suggestions("啊", "真好 啊".replace(" ", "")) == ["！", "，"], "")
    # 5e. 空 lastWord
    check("空 lastWord 不推荐", punct_suggestions(None, "x") == [] and punct_suggestions("", "x") == [], "")
    # 5f. 句末符切句:上一句的逗号不影响新句子统计
    got = punct_suggestions("今天", "昨天很累。今天")
    check("切句后新短句→单逗号", got == ["，"], f"{got}")
    got = punct_suggestions("今天", "昨天很累，很想休息。今天")
    check("上句逗号不带入新句", got == ["，"], f"{got}")

    # ===== 6. 位置与联想词共存(控制器模型) =====
    c = MiniController(MiniHost())
    c.commit_word("你好吗")
    check("你好吗→[？，]+联想词序保持",
          c.candidates() == ["？", "，", "我很好", "挺好的"], f"{c.candidates()}")
    c = MiniController(MiniHost())
    c.commit_word("今天")
    check("今天→[，]+联想词", c.candidates() == ["，", "天气", "晚上"], f"{c.candidates()}")

    # ===== 7. 点选行为 =====
    c = MiniController(MiniHost())
    c.commit_word("你好吗")
    n_learned = len(c.learned)
    c.select_punct("？")
    check("点？直接上屏", c.host.text() == "你好吗？|", c.host.text())
    check("点标点不学习", len(c.learned) == n_learned, "")
    check("点标点保 lastWord", c.last_word == "你好吗", "")
    check("点后文本以标点结尾→自然抑制(联想词继续)",
          c.candidates() == ["我很好", "挺好的"], f"{c.candidates()}")
    # 退格删掉标点后恢复推荐
    c.host.backspace()
    check("退格删标点→恢复推荐", c.candidates()[:2] == ["？", "，"], f"{c.candidates()}")

    # ===== 8. 真实人类打字路径场景剧本 =====
    # 剧本1:分句推进写复合句(最典型聊天路径)
    c = MiniController(MiniHost())
    c.commit_word("今天天气不错")
    check("剧本1-短句开场→逗号", c.candidates()[0] == "，", f"{c.candidates()}")
    c.select_punct("，")
    check("剧本1-点逗号后抑制", all(p not in c.candidates() for p in "，。？！"), f"{c.candidates()}")
    c.commit_word("我想出去走走")
    check("剧本1-第二分句(已有逗号)→[，。]",
          c.candidates()[:2] == ["，", "。"], f"{c.candidates()}")
    c.select_punct("。")
    c.commit_word("你呢")
    check("剧本1-新句疑问→？头", c.candidates()[:2] == ["？", "，"], f"{c.candidates()}")
    # 剧本2:连词复合句
    c = MiniController(MiniHost())
    c.commit_word("今天下雨了")
    c.select_punct("，")
    c.commit_word("但是")
    check("剧本2-连词→单逗号", c.candidates()[0] == "，" and "。" not in c.candidates()[:1], f"{c.candidates()}")
    c.select_punct("，")
    c.commit_word("我带了伞")
    check("剧本2-长句收尾→[，。]",
          c.candidates()[:2] == ["，", "。"], f"{c.candidates()}")
    # 剧本3:情绪对话
    c = MiniController(MiniHost())
    c.commit_word("太好了")
    check("剧本3-感叹→！头", c.candidates()[:2] == ["！", "，"], f"{c.candidates()}")
    c.select_punct("！")
    c.commit_word("谢谢")
    check("剧本3-致谢→！头(新句感叹不带上句)",
          c.candidates()[:2] == ["！", "，"], f"{c.candidates()}")
    # 剧本4:逐字组词(9宫格逐字点选)不出标点,组完后出
    c = MiniController(MiniHost())
    c.commit_word("今")
    check("剧本4-单字组词中途→无标点",
          all(p not in c.candidates() for p in "，。？！"), f"{c.candidates()}")
    c.commit_word("今天")
    check("剧本4-组成词后→逗号", c.candidates()[0] == "，", f"{c.candidates()}")
    # 剧本5:语音上屏后(文本含标点,非键盘候选路径)
    c = MiniController(MiniHost(before="今天天气真好。"))
    c.last_word = "真好"
    check("剧本5-语音句末标点后→抑制", all(p not in c.candidates() for p in "，。？！"), f"{c.candidates()}")
    c = MiniController(MiniHost(before="今天天气真好"))
    c.last_word = "真好"
    check("剧本5-语音无标点→正常推荐", "，" in c.candidates(), f"{c.candidates()}")

    # ===== 9. 结构性门禁 =====
    c = MiniController(MiniHost(), password=True)
    c.commit_word("你好吗")
    check("密码框不推荐", c.candidates() == [], "")
    c = MiniController(MiniHost(), chinese=False)
    c.commit_word("hello")
    check("非中文(英文)无此待遇", c.candidates() == [], "")
    c = MiniController(MiniHost())
    c.commit_word("你好吗")
    c.composing = "ni"
    check("打字态无标点候选", c.candidates() == ["<拼音候选>"], "")
    c = MiniController(MiniHost())
    c.commit_word("你好吗")
    c.sym_candidate_mode = True
    check("1键符号态优先(互斥)", c.candidates() == ["<1键符号>"], "")

    # ===== 10. 收起契约不受影响 =====
    check("打字态仍收起两侧", bar_collapsed("nihao", False), "")
    check("1键符号态仍收起两侧", bar_collapsed("", True), "")
    check("标点联想态(isPunct非isSymbol)不收起", not bar_collapsed("", False), "")

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("候选栏标点联想 v2 模型全部通过")


if __name__ == "__main__":
    run()
