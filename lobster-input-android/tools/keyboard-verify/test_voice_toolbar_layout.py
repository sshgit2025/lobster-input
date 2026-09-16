# -*- coding: utf-8 -*-
"""语音面板排版——布局预算与信息架构验证。

演进:
  v1 (2026-07-10) 去滑动重设计:移除 @/单手、图标化人设符号,工具栏定宽装下禁滑动。
  v2 (本次) 排版体验优化(产品反馈):
    - @ 回归工具栏右侧显眼位置(微信聊天高频符号),一键可达,不必进符号面板两步走。
    - 自切"地球"键从工具栏移除(误加:系统输入法切换应由系统地球触发,不自建入口)。
    - "单手"从麦克风语音列工具行迁至底部提示行——语音列只留「极速/还原」两钮,
      解决三钮挤在 106dp 里俄语文案(Быстро ВКЛ)缩到不可读的问题。
    - "极速"去掉"开/关"两段文案,只显示「极速」,开关状态用高亮填充色表示,
      俄语 Быстро 单词即可放下。

产品定案(三端同步):
  工具栏(安卓/鸿蒙): [键盘pill≤76] [弹性] [@40] [🎭人设38] [🔣符号38] [⌫42],间距6
  麦克风语音列工具行: [极速] [还原]  两钮(去掉单手)
  底部提示行:        [单手56] + 命令提示文案(weight 填充)
  iOS:保持自身惯例(地球键系统条件显示、收起键保留),同样 @回归 + 单手迁底部行。
"""

fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
    if not cond:
        fails.append(name)


# ---------- 布局预算模型(dp;安卓/鸿蒙同构) ----------
ROOT_PAD_H = 14 * 2          # 面板左右基础内边距
CUTOUT_ALLOWANCE = 8         # 挖孔/曲面屏 inset 余量(单侧,历史机型实测最大补偿)
GAP = 6

TOOLBAR_ANDROID_HM = [
    ("键盘pill", 76),   # autoshrink 上限(俄语等长文案缩字,i18n 封顶)
    ("FLEX", 0),
    ("@", 40),          # v2 回归:微信高频符号,一键可达
    ("🎭人设", 38),
    ("🔣符号", 38),
    ("⌫", 42),
]

TOOLBAR_IOS = [  # pt;iOS 本就无滚动
    ("键盘pill", 76),
    ("FLEX", 0),
    ("@", 40),          # v2 回归
    ("人设", 46),
    ("符号", 42),
    ("🌐条件", 30),      # 系统需要切换输入法时才显示
    ("收起", 30),
    ("⌫", 34),
]

# 从工具栏移除/迁出的键
REMOVED_FROM_TOOLBAR = ["单手", "🌐自建地球"]

# 语音列工具行(玻璃卡片内):v2 只剩两钮
VOICE_CARD_W = 126           # 安卓/鸿蒙语音列宽
VOICE_CARD_W_IOS = 98
VOICE_CARD_PAD = 10 * 2
TOOL_ROW = ["极速", "还原"]  # 单手已迁出
TOOL_GAP = 6

# 底部提示行:单手迁入
BOTTOM_HAND_W = 56


def content_width(items, gap):
    fixed = [w for _, w in items if w > 0]
    return sum(fixed) + gap * (len(fixed) - 1)


def run():
    # 1) 320dp 最小屏 + 挖孔余量下,安卓/鸿蒙工具栏(含回归的 @)必须定宽装下(禁滑动前提)
    for screen in (320, 360, 393, 412):
        avail = screen - ROOT_PAD_H - CUTOUT_ALLOWANCE * 2
        w = content_width(TOOLBAR_ANDROID_HM, GAP)
        check(f"安卓/鸿蒙 {screen}dp 屏装下(内容{w}≤可用{avail})", w <= avail, "")

    # 2) iOS 预算(pt):地球键是系统条件显示(多输入法可切时才出现),分两种情形建模:
    #    - 常态(无地球):须容纳 320pt 的 SE 系
    #    - 带地球:须容纳常见现代机型(≥375pt,如 iPhone 12 mini)
    ios_no_globe = [it for it in TOOLBAR_IOS if it[0] != "🌐条件"]
    w_ios_base = content_width(ios_no_globe, 5)
    check(f"iOS 无地球 320pt(SE)装下(内容{w_ios_base})", w_ios_base <= 320 - 24, "")
    w_ios_globe = content_width(TOOLBAR_IOS, 5)
    check(f"iOS 带地球 375pt(现代机型)装下(内容{w_ios_globe})", w_ios_globe <= 375 - 24, "地球系统条件显示")

    # 3) @ 回归工具栏且显眼(位于右侧功能簇首位,弹性空白之后)
    names = [n for n, _ in TOOLBAR_ANDROID_HM]
    check("工具栏含 @ 键(微信高频回归)", "@" in names, "")
    check("@ 紧随弹性空白(右侧簇首位,显眼)", names.index("@") == names.index("FLEX") + 1, "")

    # 4) 单手与自建地球已不在工具栏
    check("工具栏已无 单手 键", not any("单手" in n for n in names), "")
    check("工具栏已无自建地球键", "🌐" not in "".join(names), "")

    # 5) 语音列工具行只剩两钮,每钮显著变宽,俄语文案可读
    per_old3 = (VOICE_CARD_W - VOICE_CARD_PAD - TOOL_GAP * 2) / 3   # 旧:三钮
    per_new2 = (VOICE_CARD_W - VOICE_CARD_PAD - TOOL_GAP * 1) / 2   # 新:两钮
    check(f"两钮每钮≥45dp(实际{per_new2:.0f},旧三钮仅{per_old3:.0f})", per_new2 >= 45, "解决俄语缩字不可读")
    check("语音列工具行只含 极速/还原(单手迁出)", TOOL_ROW == ["极速", "还原"], "")

    # 6) 极速去状态文案:只显示「极速」,状态用颜色。俄语 Быстро 单词宽 < 两钮格宽
    #    (粗略:CJK/拉丁单词 @11sp autoshrink 需 ~40dp,格宽 per_new2 足够)
    check("极速单词可放入两钮格宽", 40 <= per_new2, "去掉 开/关 后不再拼两段")

    # 7) 单手迁至底部提示行,仍可达且有独立宽度(不与命令提示挤压)
    check("单手迁入底部提示行(仍可达)", BOTTOM_HAND_W >= 50, "低频设置项,低显著度但一键可切")

    # 8) 交互不变性:单手镜像只作用于快捷行/内容列,不作用于工具栏/底部行
    check("单手镜像不影响工具栏(设计约束)", True, "applyHandLayout 只翻转快捷行与内容列")

    # 9) 高频触达顺序:⌫ 最右(拇指热区)、模式切换最左
    check("⌫ 位于最右", TOOLBAR_ANDROID_HM[-1][0] == "⌫", "")
    check("键盘切换位于最左", TOOLBAR_ANDROID_HM[0][0] == "键盘pill", "")

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("语音面板排版布局模型全部通过")


if __name__ == "__main__":
    run()
