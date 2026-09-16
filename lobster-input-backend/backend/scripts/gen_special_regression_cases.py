"""
专项回归 case 生成器。

为 transcribe 后处理生成 7 大专项语料（每专项 500+ 起步），输出 jsonl 到
tests/prompt_regression/special/ 下，由 scripts/prompt_regression.py 的
--cases-file 参数消费。生成逻辑全部确定性，可反复执行覆盖更新。

专项清单：
  zh_url_identifier     网址/邮箱/路径/命令口语转标准格式
  zh_public_correction  公共常识纠偏（品牌/专有名词，含不可替换的反例）
  zh_semantic_cleanup   口水词清理/值类与动作类改口/感叹词保留/疑问保留
  zh_numbers            阿拉伯数字与汉字数字边界（含成语反例）
  zh_user_dict_hints    用户词典候选采用与忽略（含同音称谓）
  zh_multilingual_mix   中文与多语种混合保留
  zh_long_structure     长文本结构化整理
  en_special / ko_special / ru_special  各语种新规则抽查
"""
from __future__ import annotations

import json
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parents[1] / "tests" / "prompt_regression" / "special"

FILLERS = ["嗯", "呃", "就是说", "我的意思是说", "我想说的是", "对吧", "对不对", "你明白吧"]


def case(cid: str, category: str, text: str, *, hints: str = "", contains=(), not_contains=(),
         regex=(), not_regex=(), note: str = "") -> dict:
    return {
        "id": cid,
        "category": category,
        "text": text,
        "correction_hints": hints,
        "contains": list(contains),
        "not_contains": list(not_contains),
        "regex": list(regex),
        "not_regex": list(not_regex),
        "note": note,
    }


# ──────────────────────────────────────────────────────────────────────
# 专项 1：网址 / 邮箱 / 路径 / 命令
# ──────────────────────────────────────────────────────────────────────

def gen_url_identifier() -> list[dict]:
    cases: list[dict] = []
    idx = 0

    sites = [
        ("百度", "baidu"), ("淘宝", "taobao"), ("谷歌", "google"), ("知乎", "zhihu"),
        ("微博", "weibo"), ("哔哩哔哩", "bilibili"), ("豆瓣", "douban"), ("京东", "jd"),
        ("优酷", "youku"), ("阿里巴巴", "alibaba"),
    ]
    www_forms = [
        "三达不溜点{s}点com", "三个达不溜点{s}点com", "达不溜达不溜达不溜点{s}点com", "www点{s}点com",
        # 字母 W 的计数口语形态：易残留“三/个”计数词，必须一并展开为 www
        "三个W点{s}点com", "三W点{s}点com", "W点W点W点{s}点com", "双W点{s}点com",
    ]
    frames = ["{u}", "帮我打开{u}", "在浏览器里输入{u}", "把{u}发给客户", "官网地址是{u}", "记一下网址{u}"]
    for cn, domain in sites:
        for form in www_forms:
            spoken = form.format(s=cn)
            frame = frames[idx % len(frames)]
            idx += 1
            cases.append(case(
                f"url_{idx:04d}", "url_www", frame.format(u=spoken),
                contains=(f"www.{domain}.com",),
                not_contains=("达不溜", "点com", cn + "点", "三个", "个W", "三W"),
            ))
        # 无 www 前缀
        frame = frames[idx % len(frames)]
        idx += 1
        cases.append(case(
            f"url_{idx:04d}", "url_bare", frame.format(u=f"{cn}点com"),
            contains=(f"{domain}.com",),
            not_contains=("点com",),
        ))

    # 子域名网址：英文子域名原样保留 + 已知中文站名转官方拉丁域名，不得当成邮箱、不得替换成 www
    sub_sites = [
        ("百度", "baidu"), ("淘宝", "taobao"), ("新浪", "sina"), ("谷歌", "google"),
        ("豆瓣", "douban"), ("网易", "163"), ("搜狐", "sohu"),
    ]
    subdomains = ["map", "mail", "news", "m", "blog", "api", "image", "video"]
    sub_frames = ["{u}", "帮我打开{u}", "在浏览器里输入{u}", "网址是{u}", "记一下{u}", "打开{u}看一下"]
    sidx = 0
    for cn, domain in sub_sites:
        for sub in subdomains:
            frame = sub_frames[sidx % len(sub_frames)]
            sidx += 1
            idx += 1
            cases.append(case(
                f"url_{idx:04d}", "url_subdomain", frame.format(u=f"{sub}点{cn}点com"),
                contains=(f"{sub}.{domain}.com",),
                not_contains=("点com", cn + "点", f"www.{domain}", f"{sub}@"),
            ))
    # 中文子域名：转拉丁（拼音或语义均可），核心是网址里不残留中文、站名转对
    cn_sub = [("地图", "百度", "baidu"), ("新闻", "新浪", "sina"), ("邮件", "网易", "163")]
    for sub_cn, cn, domain in cn_sub:
        idx += 1
        cases.append(case(
            f"url_{idx:04d}", "url_subdomain_cn", f"打开{sub_cn}点{cn}点com看一下",
            contains=(f"{domain}.com",),
            not_contains=("点com", sub_cn, cn),
        ))

    surnames = [("王", "wang"), ("李", "li"), ("张", "zhang"), ("刘", "liu"), ("陈", "chen"),
                ("杨", "yang"), ("赵", "zhao"), ("周", "zhou"), ("吴", "wu"), ("徐", "xu"),
                ("孙", "sun"), ("马", "ma"), ("朱", "zhu"), ("胡", "hu"), ("林", "lin")]
    given = [("丽娜", "lina"), ("伟强", "weiqiang"), ("明杰", "mingjie"), ("海涛", "haitao"),
             ("春梅", "chunmei"), ("建军", "jianjun"), ("晓东", "xiaodong"), ("志强", "zhiqiang"),
             ("文静", "wenjing"), ("雪梅", "xuemei")]
    domains = ["gmail", "outlook", "qq", "163"]
    eidx = 0
    for i, ((s_cn, s_py), (g_cn, g_py)) in enumerate(
            [(s, g) for s in surnames for g in given]):
        dom = domains[i % len(domains)]
        for style in (i % 3, (i + 1) % 3):
            eidx += 1
            if style == 0:
                text = f"邮箱是{g_cn}点{s_cn}艾特{dom}点com"
                expect = f"{g_py}.{s_py}@{dom}.com"
            elif style == 1:
                text = f"账号是{g_cn}下划线{s_cn}艾特{dom}点com"
                expect = f"{g_py}_{s_py}@{dom}.com"
            else:
                text = f"把报告发到{g_cn}点{s_cn}艾特{dom}点com这个邮箱"
                expect = f"{g_py}.{s_py}@{dom}.com"
            cases.append(case(
                f"email_{eidx:04d}", "url_email", text,
                contains=(expect,),
                not_contains=("艾特", "下划线", "点com"),
            ))

    words = ["hotkey", "login", "update", "search", "export", "billing", "history", "replay",
             "upload", "voice", "backup", "metrics", "invoice", "profile", "session",
             "webhook", "payment", "report", "filter", "preview"]
    for i, w in enumerate(words):
        cases.append(case(
            f"cmd_{i*3+1:04d}", "url_command", f"命令是git checkout杠b feature斜杠{w}",
            contains=(f"git checkout -b feature/{w}",),
            not_contains=("斜杠", "杠b"),
        ))
        cases.append(case(
            f"cmd_{i*3+2:04d}", "url_command", f"接口路径是api斜杠v一斜杠{w}",
            contains=(f"api/v1/{w}",),
            not_contains=("斜杠",),
        ))
        cases.append(case(
            f"cmd_{i*3+3:04d}", "url_command", f"变量名是user下划线{w}",
            contains=(f"user_{w}",),
            not_contains=("下划线",),
        ))
        cases.append(case(
            f"file_{i*2+1:04d}", "url_file", f"文件名是deploy下划线{w}点sh",
            contains=(f"deploy_{w}.sh",),
            not_contains=("下划线", "点sh"),
        ))
        cases.append(case(
            f"file_{i*2+2:04d}", "url_file", f"页面地址是lobster input点com斜杠{w}点html",
            contains=(f"example.org/{w}.html",),
            not_contains=("斜杠", "点com"),
        ))
    return cases


# ──────────────────────────────────────────────────────────────────────
# 专项 2：公共常识纠偏
# ──────────────────────────────────────────────────────────────────────

def gen_public_correction() -> list[dict]:
    cases: list[dict] = []
    brands = [
        ("deep sick", "DeepSeek"), ("deep seek", "DeepSeek"), ("deepseek", "DeepSeek"),
        ("chat gpt", "ChatGPT"), ("open ai", "OpenAI"), ("git hub", "GitHub"),
        ("gitlab", "GitLab"), ("java script", "JavaScript"), ("type script", "TypeScript"),
        ("web socket", "WebSocket"), ("fast api", "FastAPI"), ("mongo db", "MongoDB"),
        ("my sql", "MySQL"), ("postgre sql", "PostgreSQL"), ("redis", "Redis"),
        ("docker", "Docker"), ("kubernetes", "Kubernetes"), ("qwen", "Qwen"),
        ("hugging face", "Hugging Face"), ("cloud flare", "Cloudflare"),
        ("tensor flow", "TensorFlow"), ("pycharm", "PyCharm"),
    ]
    contexts = [
        "帮我查一下{b}的最新版本", "我想知道{b}的API定价", "今天{b}发布新功能了",
        "把{b}的文档链接发我一下", "{b}的部署教程在哪里", "我们项目准备接入{b}",
        "对比一下{b}和别的方案的优缺点", "升级到{b}最新版试试看", "看看{b}的开源仓库",
        "{b}的token限制是多少", "用{b}写个demo验证一下", "{b}今天是不是服务挂了",
        "公司内网能不能访问{b}", "把{b}集成到我们的后端服务", "{b}的免费额度已经用完了",
        "调研一下{b}的私有化部署方案", "面试的时候被问到{b}的原理", "给新人培训一下{b}的基础用法",
        "线上日志里{b}的报错变多了", "下个迭代把{b}的SDK升级一下", "客户问{b}支不支持国产化环境",
        "晚上写篇关于{b}的技术分享", "评估一下迁移到{b}的成本", "提工单问问{b}官方的技术支持",
    ]
    idx = 0
    for spoken, standard in brands:
        if spoken == standard:
            continue
        for ctx in contexts:
            idx += 1
            spoken_c = spoken.replace(" ", "").lower()
            standard_c = standard.replace(" ", "").lower()
            if spoken_c != standard_c:
                nc = [spoken]
            elif " " in spoken and " " not in standard:
                nc = [spoken]
            else:
                nc = []
            cases.append(case(
                f"brand_{idx:04d}", "public_brand", ctx.format(b=spoken),
                contains=(standard,),
                not_contains=tuple(nc),
            ))
    # 大小写品牌（spoken == standard 小写形式）
    for spoken, standard in [("redis", "Redis"), ("docker", "Docker"), ("kubernetes", "Kubernetes"),
                             ("qwen", "Qwen"), ("gitlab", "GitLab"), ("pycharm", "PyCharm")]:
        for ctx in contexts[:10]:
            idx += 1
            cases.append(case(
                f"brand_{idx:04d}", "public_brand_case", ctx.format(b=spoken),
                contains=(standard,),
            ))
    # 版本号
    versions = [("gpt五", "GPT-5"), ("gpt四", "GPT-4"), ("V三", "V3"), ("V四", "V4"), ("V五", "V5")]
    vctx = ["最新版本是{v}吗", "我们现在用的是{v}", "下个月升级到{v}", "{v}的效果比之前好",
            "文档里写的支持{v}", "帮我确认一下是不是{v}"]
    for spoken, standard in versions:
        for ctx in vctx:
            idx += 1
            cases.append(case(
                f"version_{idx:04d}", "public_version", ctx.format(v=spoken),
                contains=(standard,),
            ))
    # 反例：字面义成立，禁止替换
    literal_cases = [
        ("deep sick的意思是一种很严重的疾病", ("deep sick",), ("DeepSeek",)),
        ("这个词组deep sick直译过来就是病得很重", ("deep sick",), ("DeepSeek",)),
        ("英语里说deep sick表示病入膏肓", ("deep sick",), ("DeepSeek",)),
        ("他在作文里用了deep sick这个表达来形容重病", ("deep sick",), ("DeepSeek",)),
        ("老师说deep sick不是地道的英文表达", ("deep sick",), ("DeepSeek",)),
        ("我需要三个方案不是3.0版本", ("三个方案", "3.0版本"), ()),
        ("我们家的路由器牌子就叫小米不要改", ("小米",), ()),
        ("苹果今天打折五块钱一斤", ("苹果",), ("Apple",)),
        ("他姓马不是马云的那个马戏团", ("姓马",), ()),
        ("这道菜叫开水白菜不是白开水", ("开水白菜",), ()),
    ]
    for i, (text, c, nc) in enumerate(literal_cases, 1):
        for j, frame in enumerate(["{t}", "我想说的是{t}", "嗯{t}"], 1):
            idx += 1
            cases.append(case(
                f"literal_{idx:04d}", "public_literal_keep", frame.format(t=text),
                contains=c, not_contains=tuple(nc) + ("我想说的是",),
            ))
    return cases


# ──────────────────────────────────────────────────────────────────────
# 专项 3：语义整理
# ──────────────────────────────────────────────────────────────────────

def gen_semantic_cleanup() -> list[dict]:
    cases: list[dict] = []
    idx = 0

    # 值类改口：旧值必须消失
    value_pairs = [("三", "四"), ("两", "三"), ("九", "十"), ("一", "两")]
    events = ["咱们开个会", "跟客户对一下需求", "评审这个方案", "联调一下接口", "同步一下进度",
              "做产品演示", "过一遍测试用例", "讨论发布计划", "复盘线上问题", "对齐验收标准",
              "排查告警原因", "梳理依赖关系"]
    openers = ["emm呃那个", "嗯那个", "就是说", "呃", "我想说的是", ""]
    digit = {"一": "1", "两": "2", "三": "3", "四": "4", "九": "9", "十": "10"}
    for a, b in value_pairs:
        for ev in events:
            for op in openers[:4]:
                idx += 1
                cases.append(case(
                    f"sem_{idx:04d}", "value_self_correction",
                    f"{op}下午{a}点啊不对是{b}点{ev}",
                    contains=(f"下午{digit[b]}点",),
                    not_contains=(f"{a}点", f"{digit[a]}点", "不对", "那个", "就是说"),
                ))
    # 数量值改口
    qty_pairs = [("三", "五", "个测试账号"), ("两", "四", "台压测机器"), ("十", "二十", "条样例数据")]
    qty_digit = {"五": "5", "四": "4", "二十": "20"}
    for a, b, obj in qty_pairs:
        for op in openers:
            idx += 1
            cases.append(case(
                f"sem_{idx:04d}", "value_self_correction",
                f"{op}给我准备{a}{obj[0]}啊不对是{b}{obj[0]}{obj[1:]}",
                regex=(rf"({b}|{qty_digit[b]}){obj}",),
                not_contains=(f"准备{a}{obj[0]}", "不对"),
            ))

    # 感叹词保留
    emo_cases = [
        ("啊，这里真美", ("啊", "真美")),
        ("啊，这个夕阳也太好看了", ("啊", "夕阳")),
        ("哇，这个界面做得真漂亮", ("哇", "界面")),
        ("哇，性能提升了这么多", ("哇", "性能")),
        ("哎呀，这个bug太难搞了", ("哎呀", "难搞")),
        ("哎呀，又要返工了", ("哎呀", "返工")),
        ("唉，今天又得加班了", ("唉", "加班")),
        ("唉，这个需求改了三遍了", ("唉", "三遍")),
        ("天哪，数据库居然被清空了", ("天哪", "数据库")),
        ("我的天，这个延迟降到十毫秒了", ("延迟",)),
        ("哇，新版启动速度快了一倍", ("哇", "启动速度")),
        ("啊，这个海边日出太震撼了", ("啊", "日出")),
        ("哎呀，密钥又过期了", ("哎呀", "密钥")),
        ("唉，客户又改需求了", ("唉", "需求")),
        ("天哪，转化率翻了一倍", ("天哪", "转化率")),
        ("哇，这个动画效果丝滑得不行", ("哇", "动画")),
        ("啊，樱花开得真好看", ("啊", "樱花")),
        ("哎呀，会议室又被占了", ("哎呀", "会议室")),
        ("唉，这周第三次回滚了", ("唉", "回滚")),
        ("哇，压测一次就过了", ("哇", "压测")),
    ]
    frames = ["{t}", "{t}，记录一下", "{t}，发给群里"]
    for text, c in emo_cases:
        for fr in frames:
            idx += 1
            cases.append(case(
                f"sem_{idx:04d}", "interjection_keep", fr.format(t=text),
                contains=c,
            ))
    # 感叹词混合：开头犹豫删、情绪叹保留
    idx += 1
    cases.append(case(
        f"sem_{idx:04d}", "interjection_keep",
        "啊，那我想想先，呃，行吧，哎呀太难搞了",
        contains=("我想想", "行吧", "哎呀", "难搞"),
        not_contains=("呃",),
        note="句首犹豫啊删除，哎呀情绪保留",
    ))

    # 口水词矩阵
    topics = ["登录接口", "支付回调", "消息推送", "数据看板", "权限配置", "导出功能", "搜索排序",
              "缓存刷新", "灰度开关", "告警规则", "审批流程", "工单系统", "上传组件", "日志采集",
              "定时任务", "短信通道", "充值入口", "邀请活动", "签到模块", "榜单刷新"]
    problems = ["偶发超时", "重复触发", "数据不一致", "加载很慢", "样式错乱", "丢消息",
                "权限不生效", "返回乱码"]
    templates = [
        ("嗯就是帮我看一下{t}为什么{p}啊", ("帮我看", "为什么")),
        ("我的意思是说{t}吧就是{p}了对吧", ()),
        ("那个{t}有点{p}你明白吧帮我排查一下", ("排查",)),
        ("呃这个{t}就是说经常{p}需要处理一下", ("处理",)),
        ("就是说{t}今天又{p}了对不对要不要回滚", ("回滚",)),
    ]
    for t in topics:
        for p in problems:
            tpl, extra = templates[idx % len(templates)]
            idx += 1
            cases.append(case(
                f"sem_{idx:04d}", "filler_matrix", tpl.format(t=t, p=p),
                contains=(t, p) + tuple(extra),
                not_contains=tuple(FILLERS),
            ))

    # 句尾语气词删除但不吞实词
    actions = ["执行下一步", "先合并代码", "重启服务", "更新依赖", "清理缓存", "提交工单",
               "通知运营", "锁定版本", "同步会议纪要", "刷新配置中心", "暂停灰度放量",
               "校验签名逻辑", "归档历史数据", "扩容消息队列", "切换备用线路", "导出审计日志"]
    for a in actions:
        for tail in ["啊", "呀", "嘛"]:
            idx += 1
            cases.append(case(
                f"sem_{idx:04d}", "tail_particle", f"{a}{tail}",
                contains=(a,),
                not_regex=(rf"{tail}[。！!]?$",),
            ))

    # 疑问语气必须保留问号
    questions = [
        "这个改动会不会影响线上数据", "新方案能不能兼容老版本", "为什么这个接口偶尔返回空",
        "是不是应该先做风险评估", "要不要把这个配置加到灰度里", "这个报错到底怎么解决",
        "有没有更轻量的实现方式", "可不可以把发布推迟到周五", "哪里可以看到完整的调用链",
        "怎么样才能复现这个崩溃", "如何评估这次迁移的风险", "要不要先在测试环境演练一遍",
        "是不是漏掉了边界条件", "能不能给前端留一个降级开关", "有没有人在跟进这个工单",
        "为什么凌晨的任务总是失败",
    ]
    qframes = ["{q}", "你帮我看看{q}", "嗯那个{q}呀", "我想确认一下{q}呢"]
    for q in questions:
        for fr in qframes:
            idx += 1
            cases.append(case(
                f"sem_{idx:04d}", "question_keep", fr.format(q=q),
                contains=(q[:6],),
                regex=(r"[？?]",),
                not_contains=("嗯", "那个"),
            ))
    return cases


# ──────────────────────────────────────────────────────────────────────
# 专项 4：数字格式
# ──────────────────────────────────────────────────────────────────────

def gen_numbers() -> list[dict]:
    cases: list[dict] = []
    idx = 0
    digit_map = {"零": "0", "一": "1", "二": "2", "三": "3", "四": "4", "五": "5",
                 "六": "6", "七": "7", "八": "8", "九": "9"}

    def spell(num: str) -> str:
        return "".join({v: k for k, v in digit_map.items()}[ch] for ch in num)

    codes = ["1234", "5678", "9012", "2468", "1357", "8642", "7531", "4096", "1024", "6080",
             "3927", "5061", "7408", "9183", "2750", "6314", "8527", "1936", "4072", "5690"]
    for c in codes:
        idx += 1
        cases.append(case(f"num_{idx:04d}", "num_code", f"验证码是{spell(c)}", contains=(c,)))
        idx += 1
        cases.append(case(f"num_{idx:04d}", "num_code", f"短信验证码{spell(c)}有效期五分钟",
                          contains=(c,)))

    phones = ["13935273333", "18612345678", "13800138000", "15966668888", "17712340987",
              "13577778888", "18899990000", "15123456789", "13612345670", "18923456781",
              "15734567892", "13845678903", "18656789014", "15967890125", "17778901236",
              "13989012347"]
    for p in phones:
        idx += 1
        cases.append(case(f"num_{idx:04d}", "num_phone", f"手机号是{spell(p)}", contains=(p,)))
        idx += 1
        cases.append(case(f"num_{idx:04d}", "num_phone", f"联系电话{spell(p)}找李经理", contains=(p,)))

    percents = ["五", "十", "十五", "二十", "二十五", "三十", "五十", "八十", "九十九"]
    pvals = ["5%", "10%", "15%", "20%", "25%", "30%", "50%", "80%", "99%"]
    pctx = ["折扣是百分之{x}", "毛利率大概百分之{x}", "覆盖率要到百分之{x}", "失败率降到百分之{x}以下",
            "增长了百分之{x}", "预算砍了百分之{x}"]
    for sp, val in zip(percents, pvals):
        for ctx in pctx:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_percent", ctx.format(x=sp), contains=(val,)))

    times = [("下午三点", "下午3点"), ("早上九点", "早上9点"), ("晚上八点半", "晚上8点半"),
             ("下午四点十五", "下午4点15"), ("中午十二点", "中午12点"), ("凌晨两点", "凌晨2点"),
             ("上午十点", "上午10点"), ("下午五点四十", "下午5点40"), ("晚上九点", "晚上9点"),
             ("早上七点半", "早上7点半")]
    tctx = ["{t}开会", "会议改到{t}", "{t}之前交付", "提醒我{t}打电话", "面试安排在{t}"]
    for sp, val in times:
        for ctx in tctx:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_time", ctx.format(t=sp), contains=(val,)))

    idioms = ["一心一意", "三心二意", "五湖四海", "七上八下", "九牛一毛", "万无一失",
              "一目了然", "四面八方", "千军万马", "十全十美", "百发百中", "一举两得",
              "三言两语", "五花八门", "六神无主", "一丝不苟", "两全其美", "四平八稳",
              "千载难逢", "万众一心"]
    ictx = ["做事要{i}", "他这个人{i}", "这次方案必须{i}", "改起来不可能{i}", "客户希望{i}"]
    for it in idioms:
        for ctx in ictx:
            idx += 1
            cases.append(case(
                f"num_{idx:04d}", "num_idiom", ctx.format(i=it),
                contains=(it,),
                not_regex=(r"\d",),
            ))

    naturals = [("三个方案", "3个方案"), ("两个客户", "2个客户"), ("五个需求", "5个需求"),
                ("四名同事", "4名同事"), ("两次评审", "2次评审"), ("三轮测试", "3轮测试"),
                ("五个兄弟姐妹", "5个兄弟姐妹"), ("两位老师", "2位老师"), ("三件事情", "3件事情"),
                ("四个环节", "4个环节"), ("两种思路", "2种思路"), ("三家供应商", "3家供应商")]
    nctx = ["这次一共有{n}", "需要准备{n}", "{n}都要覆盖到", "先处理{n}再说"]
    for keep, avoid in naturals:
        for ctx in nctx:
            idx += 1
            cases.append(case(
                f"num_{idx:04d}", "num_natural", ctx.format(n=keep),
                contains=(keep,),
                not_contains=(avoid,),
            ))

    amounts = [("一千二百三十四", "1234"), ("八百八十八", "888"), ("两万五千", "25000"),
               ("三千六百", "3600"), ("九千九百九十九", "9999"), ("四万八千", "48000"),
               ("六百五十", "650"), ("一万零五百", "10500"), ("七千二百", "7200"),
               ("五万六千", "56000")]
    actx = ["金额是{a}块", "发票开{a}元", "报价{a}元含税", "这单收了{a}块"]
    for sp, val in amounts:
        for ctx in actx:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_amount", ctx.format(a=sp), contains=(val,)))

    dates = [("二零二六年五月七号", "2026年5月7"), ("二零二五年十二月一号", "2025年12月1"),
             ("二零二六年一月十五号", "2026年1月15"), ("二零二六年三月八号", "2026年3月8"),
             ("二零二六年十月二十号", "2026年10月20"), ("二零二七年六月三十号", "2027年6月30")]
    dctx = ["{d}上线", "{d}之前完成验收", "合同签署日期是{d}", "{d}下午三点开会"]
    for sp, val in dates:
        for ctx in dctx:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_date", ctx.format(d=sp), contains=(val,)))

    versions = [("V四", "V4"), ("V五", "V5"), ("三点零版本", "3.0版本"), ("二点一版本", "2.1版本"),
                ("V二", "V2"), ("V六", "V6"), ("一点五版本", "1.5版本"), ("四点二版本", "4.2版本")]
    vctx = ["升级到{v}", "线上跑的是{v}", "{v}有兼容问题", "回滚到{v}", "发布说明里写清楚{v}"]
    for sp, val in versions:
        for ctx in vctx:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_version", ctx.format(v=sp), contains=(val,)))

    latencies = [("二百", "200"), ("五十", "50"), ("三百", "300"), ("一百二十", "120"),
                 ("八十", "80"), ("六百", "600"), ("一千五百", "1500"), ("四百", "400"),
                 ("九十", "90"), ("两千", "2000"), ("三十五", "35"), ("七百", "700")]
    lctx = ["API延迟大概{x}毫秒", "接口耗时降到{x}毫秒", "超时阈值设成{x}毫秒"]
    for sp, val in latencies:
        for ctx in lctx:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_latency", ctx.format(x=sp),
                              contains=(f"{val}毫秒",)))

    orders = ["20260507001", "20251201088", "20260115233", "20260308456", "20261020789",
              "20270630012", "20260218345", "20250909678", "20261111900", "20260404567",
              "20260606234", "20260808890"]
    octx = ["订单号是{o}", "工单编号{o}麻烦跟进一下"]
    for o in orders:
        for ctx in octx:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_order", ctx.format(o=spell(o)),
                              contains=(o,)))

    decimals = [("十二点五", "12.5"), ("三点一四", "3.14"), ("零点八", "0.8"),
                ("九十九点九", "99.9"), ("六点六", "6.6")]
    dctx2 = ["CPU占用率是{x}", "这个指标涨到{x}", "汇率是{x}", "平均分{x}"]
    for sp, val in decimals:
        for ctx in dctx2:
            idx += 1
            cases.append(case(f"num_{idx:04d}", "num_decimal", ctx.format(x=sp),
                              contains=(val,)))
    return cases


# ──────────────────────────────────────────────────────────────────────
# 专项 5：用户词典候选
# ──────────────────────────────────────────────────────────────────────

def gen_user_dict_hints() -> list[dict]:
    cases: list[dict] = []
    idx = 0

    name_pairs = [
        ("陆姐", "露姐"), ("小静", "小婧"), ("丽丽", "莉莉"), ("军哥", "君哥"),
        ("浩哥", "昊哥"), ("老王", "老汪"), ("晓东", "晓冬"), ("阿明", "阿铭"),
        ("小薇", "小葳"), ("燕子", "嬿子"), ("小杰", "小劼"), ("琳琳", "霖霖"),
        ("芳姐", "方姐"), ("涛哥", "弢哥"), ("小宇", "小禹"),
        # 看起来是完整正式人名（姓+名）被直呼的难场景：仍应采用词典写法把联系人名字写对
        ("陆杰", "露姐"), ("张伟", "张玮"), ("刘洋", "刘扬"), ("陈涛", "陈韬"),
        ("赵敏", "赵闵"), ("孙磊", "孙蕾"), ("李娜", "丽娜"), ("王强", "王锖"),
    ]
    name_frames = [
        "{n}，你好", "{n}，今天的需求文档我发你了", "麻烦{n}帮我看一下这个问题",
        "下午跟{n}对一下排期", "把这个任务交给{n}处理", "{n}说今天不发版",
        "刚才{n}在群里@你了", "等{n}回来再做决定", "这个客户是{n}对接的",
        "{n}下周休假记得提前同步", "让{n}把测试报告发出来", "今晚和{n}一起值班",
        "提醒{n}明天的评审会", "{n}负责这次的发布检查", "周报里记得提一下{n}的贡献",
        "{n}刚才电话里说服务器有告警", "这个权限要找{n}审批", "{n}建议先回滚再排查",
    ]
    for src, dst in name_pairs:
        for fr in name_frames:
            idx += 1
            cases.append(case(
                f"hint_{idx:04d}", "hint_apply_name", fr.format(n=src),
                hints=f"- {src} -> {dst}",
                contains=(dst,),
                not_contains=(src,),
            ))

    term_pairs = [
        ("剪切板", "剪贴板"), ("状态吗", "状态码"), ("命中绿", "命中率"),
        ("开机紫气", "开机自启"), ("号池平太", "号池平台"), ("灰度开观", "灰度开关"),
        ("回归侧试", "回归测试"), ("竞品分晰", "竞品分析"), ("流量峰直", "流量峰值"),
        ("日志澄级", "日志等级"), ("熔断阀值", "熔断阈值"), ("限流测略", "限流策略"),
        ("压侧报告", "压测报告"), ("链路追宗", "链路追踪"), ("消息对列", "消息队列"),
    ]
    term_frames = [
        "这个{w}的逻辑需要再确认", "把{w}相关的文档更新一下",
        "线上{w}出问题了赶紧看看", "明天评审{w}的改造方案", "{w}的数据要同步给运营",
        "新人不太了解{w}的流程", "这次迭代重点优化{w}", "监控里{w}的指标异常",
        "周会上同步一下{w}的进展", "客户反馈{w}有异常",
    ]
    verb_frames = ["今天要重新{w}一下preview环境", "明天统一{w}到正式环境"]
    for vsrc, vdst in [("布署", "部署")]:
        for fr in verb_frames:
            idx += 1
            cases.append(case(
                f"hint_{idx:04d}", "hint_apply_term", fr.format(w=vsrc),
                hints=f"- {vsrc} -> {vdst}",
                contains=(vdst,), not_contains=(vsrc,),
            ))
    for src, dst in term_pairs:
        for fr in term_frames:
            idx += 1
            cases.append(case(
                f"hint_{idx:04d}", "hint_apply_term", fr.format(w=src),
                hints=f"- {src} -> {dst}",
                contains=(dst,),
                not_contains=(src,),
            ))

    bad_pairs = [
        ("银行", "营养"), ("额度", "恶毒"), ("预算", "预览"), ("周期", "周琪"),
        ("血压", "雪鸭"), ("老师", "老实"), ("客户", "克服"), ("方案", "放暗"),
        ("会议", "汇艺"), ("报销", "爆笑"), ("年假", "黏价"), ("绩效", "记孝"),
        ("合同", "河童"), ("发票", "发飘"), ("库存", "酷寸"), ("物流", "雾流"),
    ]
    bad_frames = [
        "这个{w}下周再确认", "把{w}的材料准备好",
        "{w}的事情已经处理完了", "领导让我跟进{w}的进展", "{w}相关的问题明天讨论",
        "先把{w}的数据整理出来", "这次{w}安排得比较紧", "{w}的结果出来记得告诉我",
        "下午开会要讨论{w}的事", "关于{w}的讨论明天继续",
    ]
    for src, dst in bad_pairs:
        for fr in bad_frames:
            idx += 1
            cases.append(case(
                f"hint_{idx:04d}", "hint_ignore_bad", fr.format(w=src),
                hints=f"- {src} -> {dst}",
                contains=(src,),
                not_contains=(dst,),
            ))

    # 多候选：选择最贴语境的一个
    multi = [
        ("癌症特", "帮我查一下癌症特的最新技术文档", "- 癌症特 -> Agent / 安正特", "Agent", "癌症特"),
        ("可色", "把可色的光标移动到行首", "- 可色 -> Cursor / 可塞", "Cursor", "可色"),
        ("扣问", "用扣问大模型跑一遍测试", "- 扣问 -> Qwen / 叩问", "Qwen", "扣问"),
        ("瑞迪斯", "瑞迪斯缓存需要扩容了", "- 瑞迪斯 -> Redis / 锐迪思", "Redis", "瑞迪斯"),
    ]
    extra_frames = ["{t}", "嗯那个{t}", "就是说{t}麻烦尽快"]
    for src, text, hints, good, orig in multi:
        for fr in extra_frames:
            idx += 1
            cases.append(case(
                f"hint_{idx:04d}", "hint_multi_candidate", fr.format(t=text),
                hints=hints,
                contains=(good,),
                not_contains=(orig, "嗯", "那个", "就是说"),
            ))
    return cases


# ──────────────────────────────────────────────────────────────────────
# 专项 6：多语种混合
# ──────────────────────────────────────────────────────────────────────

def gen_multilingual_mix() -> list[dict]:
    cases: list[dict] = []
    idx = 0
    en_phrases = ["login API", "cache hit rate", "rate limiter", "websocket connection",
                  "release checklist", "privacy policy", "code review", "feature flag",
                  "load balancer", "session token", "health check", "message queue",
                  "retry policy", "circuit breaker", "dark launch", "schema migration"]
    zh_frames = [
        "帮我看一下{f}为什么不稳定", "这个{f}的配置需要更新", "把{f}的文档翻出来对一下",
        "今天{f}又报警了", "新人问{f}是干什么的", "下个版本要重构{f}",
        "测试环境的{f}和线上不一致", "把{f}加到监控里", "评审的时候重点讲{f}",
        "客户对{f}的实现有疑问", "值班手册里补充{f}的处理步骤", "故障演练要覆盖{f}",
        "On call群里有人问{f}的报警怎么处理",
    ]
    for ph in en_phrases:
        for fr in zh_frames:
            idx += 1
            cases.append(case(
                f"mix_{idx:04d}", "mix_zh_en", fr.format(f=ph),
                contains=(ph,),
            ))

    foreign_tokens = [
        ("오늘", "今天"), ("회의", "会议"), ("감사합니다", "谢谢"),
        ("ありがとう", "谢谢"), ("明日の予定", "明天的安排"), ("お疲れ様", "辛苦了"),
        ("привет", "你好"), ("спасибо", "谢谢"), ("хорошо", "好的"),
        ("merci", "谢谢"), ("bonjour", "你好"), ("danke", "谢谢"),
        ("schön", "漂亮"), ("gracias", "谢谢"), ("hola", "你好"),
        ("수고하셨습니다", "辛苦了"), ("すみません", "不好意思"), ("до свидания", "再见"),
        ("guten Morgen", "早上好"), ("au revoir", "再见"),
    ]
    keep_frames = [
        "客户消息里有一句{f}保持原样别翻译", "把{f}这个词原文记录下来", "界面上要显示{f}这个问候语",
        "翻译表里{f}对应的中文先空着", "测试文案里加一条{f}", "这个{f}是韩语还是日语帮我标注一下",
        "用户昵称就叫{f}不要动", "搜索关键词是{f}", "邮件开头写{f}然后接中文正文",
        "语料库里{f}出现了三次",
    ]
    for f_tok, zh_trans in foreign_tokens:
        for fr in keep_frames:
            idx += 1
            nc = (zh_trans,) if zh_trans not in fr.format(f=f_tok) else ()
            cases.append(case(
                f"mix_{idx:04d}", "mix_keep_foreign", fr.format(f=f_tok),
                contains=(f_tok,),
                not_contains=nc,
            ))

    code_switch = [
        ("please check 这个接口为什么 timeout", ("please check", "timeout"), ()),
        ("明日のmeetingは十点开始记得提前进会议室", ("明日のmeeting", "10点"), ("明天的meeting",)),
        ("오늘 standup 改到下午两点", ("오늘", "standup", "下午2点"), ("今天",)),
        ("сравни 一下两个方案的 latency", ("сравни", "latency"), ()),
        ("这个 wording 需要 révise 一下", ("wording", "révise"), ()),
        ("preview环境和prod环境的配置diff一下", ("preview", "prod", "diff"), ()),
        ("把这段 docstring 翻译成中文注释", ("docstring",), ()),
        ("Das ist 一个已知问题下个版本修", ("Das ist", "已知问题"), ()),
        ("用户说 deadline 是周五 EOD", ("deadline", "EOD"), ()),
        ("把 README 里的 quick start 部分补全", ("README", "quick start"), ()),
        ("오늘 회의 결论先发邮件 follow up 一下", ("오늘", "follow up"), ()),
        ("merci 这位客户很满意下次继续合作", ("merci",), ()),
        ("这个 issue 标记成 wontfix 然后关闭", ("issue", "wontfix"), ()),
        ("спасибо 收到反馈了我们尽快修复", ("спасибо",), ()),
        ("把 onboarding 文档里的 FAQ 更新一下", ("onboarding", "FAQ"), ()),
    ]
    cs_frames = ["{t}", "嗯{t}", "就是说{t}", "那个{t}对吧", "我的意思是说{t}"]
    for text, c, nc in code_switch:
        for fr in cs_frames:
            idx += 1
            cases.append(case(
                f"mix_{idx:04d}", "mix_code_switch", fr.format(t=text),
                contains=c,
                not_contains=tuple(nc) + ("就是说", "我的意思是说", "对吧"),
            ))
    return cases


# ──────────────────────────────────────────────────────────────────────
# 专项 7：长文本结构化
# ──────────────────────────────────────────────────────────────────────

def gen_long_structure() -> list[dict]:
    cases: list[dict] = []
    idx = 0
    openers = ["嗯今天说一下", "那个我整理一下", "就是说汇报一下", "呃复盘一下",
               "我的意思是说总结一下", "嗯那个先同步一下", "就是说先过一遍", "呃简单讲一下"]

    meeting_topics = [
        ("用户增长", "注册转化率", "渠道投放", "留存率"),
        ("性能优化", "接口耗时", "数据库索引", "缓存命中率"),
        ("安全加固", "登录风控", "数据加密", "审计日志"),
        ("客服体系", "工单响应", "知识库", "满意度"),
        ("发布流程", "灰度策略", "回滚预案", "监控告警"),
        ("成本治理", "云资源", "闲置实例", "预算分摊"),
        ("数据质量", "口径对齐", "校验规则", "异常报表"),
        ("团队协作", "需求评审", "排期冲突", "跨组依赖"),
    ]
    for topic, p1, p2, p3 in meeting_topics:
        for op in openers:
            idx += 1
            text = (
                f"{op}{topic}这个专项嗯首先是{p1}的问题就是说现在数据不太理想需要先把口径统一然后再看趋势"
                f"其次是{p2}这块呃我们排查了一下发现主要瓶颈在配置上需要下周出一个优化方案"
                f"第三是{p3}的事情那个目前缺一个负责人建议从平台组抽一个人专门跟进"
                f"最后强调一下所有结论都要有数据支撑不要拍脑袋对吧大家如果有不同意见会后单独找我聊"
            )
            cases.append(case(
                f"long_{idx:04d}", "long_meeting", text,
                contains=(topic, p1, p2, p3, "数据支撑"),
                not_contains=("嗯", "就是说", "呃", "对吧", "拍脑袋啊"),
                not_regex=(r"(?s)^1[.、].*\n2[.、].*\n3[.、].*\n4[.、].*\n5[.、].*\n6[.、].*\n7[.、]",),
            ))

    plan_topics = [
        ("语音输入法", "实时转写", "词典纠偏", "多语言支持", "离线模式"),
        ("数据平台", "埋点采集", "实时计算", "可视化看板", "权限隔离"),
        ("电商后台", "库存同步", "订单拆分", "物流对接", "对账系统"),
        ("在线教育", "直播互动", "课件管理", "作业批改", "学情报告"),
        ("智能客服", "意图识别", "知识检索", "多轮对话", "人工接管"),
        ("出行平台", "司机调度", "动态计价", "安全风控", "客诉处理"),
        ("内容社区", "推荐算法", "审核机制", "创作者激励", "广告变现"),
        ("企业网盘", "增量同步", "版本管理", "外链分享", "容量计费"),
    ]
    for prod, f1, f2, f3, f4 in plan_topics:
        for op in openers:
            idx += 1
            text = (
                f"{op}{prod}下个季度的规划嗯第一个重点是{f1}就是说目前用户反馈最多的就是这块要优先做"
                f"第二个是{f2}呃这个依赖算法团队的排期需要提前协调资源"
                f"第三个是{f3}那个竞品已经上线了我们不能落后太多"
                f"第四个是{f4}这个属于长期投入可以放到季度末启动"
                f"另外提醒一下所有功能上线前必须过安全评审和性能压测一个都不能少"
            )
            cases.append(case(
                f"long_{idx:04d}", "long_plan", text,
                contains=(prod, f1, f2, f3, f4, "安全评审"),
                not_contains=("嗯", "就是说", "呃"),
            ))

    debug_topics = [
        ("支付回调丢失", "网络抖动", "幂等键", "补偿任务"),
        ("内存持续上涨", "对象泄漏", "缓存上限", "定时重启"),
        ("消息积压", "消费速率", "分区扩容", "降级开关"),
        ("登录态失效", "时钟偏移", "刷新逻辑", "兜底重登"),
        ("图片加载慢", "CDN命中", "压缩参数", "懒加载"),
        ("搜索结果为空", "分词词典", "索引重建", "兜底召回"),
        ("推送延迟高", "通道拥塞", "优先级队列", "厂商通道"),
        ("账单金额不平", "汇率精度", "四舍五入", "对账脚本"),
    ]
    for issue, c1, c2, c3 in debug_topics:
        for op in openers:
            idx += 1
            text = (
                f"{op}{issue}这个故障的排查结论嗯现象是凌晨两点到三点之间出现了大概十五分钟的异常"
                f"根因初步定位是{c1}导致的就是说还需要再压测一轮确认"
                f"临时措施是调整了{c2}相关的配置呃目前观察了二十四小时没有复发"
                f"长期方案是把{c3}做成自动化下个迭代排期"
                f"这次暴露的问题是告警阈值设置得太宽松需要整体审视一遍"
            )
            cases.append(case(
                f"long_{idx:04d}", "long_debug", text,
                contains=(issue, c1, c2, c3, "告警阈值"),
                not_contains=("嗯", "就是说", "呃"),
                regex=(r"(15|十五)分钟", r"(24|二十四)小时"),
            ))

    note_topics = [
        ("分布式事务", "两阶段提交", "TCC", "本地消息表"),
        ("向量检索", "倒排索引", "HNSW", "召回率"),
        ("容器编排", "调度策略", "亲和性", "弹性伸缩"),
        ("前端性能", "首屏时间", "代码分割", "预加载"),
        ("数据一致性", "主从延迟", "读写分离", "最终一致"),
        ("服务网格", "流量劫持", "熔断降级", "可观测性"),
        ("权限模型", "RBAC", "属性控制", "最小权限"),
        ("缓存设计", "穿透", "雪崩", "布隆过滤器"),
    ]
    for subject, k1, k2, k3 in note_topics:
        for op in openers:
            idx += 1
            text = (
                f"{op}今天学习{subject}的笔记嗯核心概念有三个第一个是{k1}就是说它解决的是基础场景的问题"
                f"第二个是{k2}呃适合对性能要求高的场景但是实现复杂度也高"
                f"第三个是{k3}那个是工程上最常用的折中方案"
                f"我的理解是选型要看业务的容忍度不要为了技术而技术后面找个小项目实践一下"
            )
            cases.append(case(
                f"long_{idx:04d}", "long_note", text,
                contains=(subject, k1, k2, k3),
                not_contains=("嗯", "就是说", "呃", "那个是工程"),
            ))
    return cases


# ──────────────────────────────────────────────────────────────────────
# 其它语种新规则抽查
# ──────────────────────────────────────────────────────────────────────

def gen_en_special() -> list[dict]:
    cases: list[dict] = []
    idx = 0
    url_sites = ["google", "github", "openai", "amazon", "reddit", "youtube", "wikipedia",
                 "stackoverflow", "dropbox", "notion", "figma", "slack"]
    url_forms = ["triple w dot {s} dot com", "double u double u double u dot {s} dot com",
                 "www dot {s} dot com"]
    url_frames = ["open {u} in the browser", "the address is {u}", "send {u} to the client",
                  "bookmark {u} please"]
    for s in url_sites:
        for form in url_forms:
            idx += 1
            cases.append(case(
                f"en_sp_{idx:04d}", "en_url", url_frames[idx % len(url_frames)].format(u=form.format(s=s)),
                contains=(f"www.{s}.com",),
                not_contains=("triple w", "double u", " dot "),
            ))
    first = ["john", "alice", "david", "maria", "kevin", "sarah", "peter", "linda", "tom", "emma"]
    last = ["smith", "brown", "wilson", "miller", "davis"]
    for i, f in enumerate(first):
        for j, l in enumerate(last):
            idx += 1
            dom = ["gmail", "outlook", "yahoo"][(i + j) % 3]
            cases.append(case(
                f"en_sp_{idx:04d}", "en_email",
                f"my email is {f} dot {l} at {dom} dot com",
                contains=(f"{f}.{l}@{dom}.com",),
                not_contains=(" at ", " dot "),
            ))
    brands = [("deep sick", "DeepSeek"), ("chat gpt", "ChatGPT"), ("git hub", "GitHub"),
              ("java script", "JavaScript"), ("type script", "TypeScript"), ("open ai", "OpenAI"),
              ("web socket", "WebSocket"), ("mongo db", "MongoDB"), ("my sql", "MySQL"),
              ("fast api", "FastAPI"), ("cloud flare", "Cloudflare"), ("hugging face", "Hugging Face")]
    bctx = ["what is the latest {b} version", "check the {b} docs for me",
            "we should integrate {b} next sprint", "the {b} api pricing changed",
            "um I think the {b} sdk needs an upgrade", "is {b} down right now",
            "write a short summary about {b}", "our backend depends on {b}",
            "the {b} migration is scheduled for friday", "ask the vendor about {b} support"]
    for spoken, standard in brands:
        for ctx in bctx:
            idx += 1
            cases.append(case(
                f"en_sp_{idx:04d}", "en_brand", ctx.format(b=spoken),
                contains=(standard,),
                not_contains=("um ",),
            ))
    literal = [
        ("deep sick means being seriously ill in casual English", ("deep sick",), ("DeepSeek",)),
        ("the phrase deep sick describes a severe illness", ("deep sick",), ("DeepSeek",)),
        ("my teacher said deep sick is not idiomatic English", ("deep sick",), ("DeepSeek",)),
    ]
    for text, c, nc in literal:
        for fr in ["{t}", "I mean {t}", "you know {t}"]:
            idx += 1
            cases.append(case(
                f"en_sp_{idx:04d}", "en_literal", fr.format(t=text),
                contains=c, not_contains=tuple(nc) + ("I mean", "you know"),
            ))
    emotions = [
        ("wow this view is absolutely beautiful", ("wow", "beautiful")),
        ("oh no the database is down again", ("oh no", "database")),
        ("ouch that deploy broke the login page", ("ouch", "login page")),
        ("wow the new build starts twice as fast", ("wow", "build")),
        ("oh no we missed the release window", ("oh no", "release window")),
        ("phew the rollback actually worked", ("rollback",)),
    ]
    for text, c in emotions:
        for fr in ["{t}", "{t} please note it down", "{t} tell the team"]:
            idx += 1
            cases.append(case(f"en_sp_{idx:04d}", "en_interjection", fr.format(t=text), contains=c))
    topics = ["the export job", "the cache layer", "the retry logic", "the billing service",
              "the search index", "the push gateway", "the audit log", "the rate limiter",
              "the onboarding flow", "the websocket bridge"]
    problems = ["keeps timing out", "returns stale data", "is way too slow", "crashes on weekends",
                "drops messages", "ignores the config"]
    ftpl = [("um please check why {t} {p}", ("check",), ("um ",)),
            ("you know {t} {p} again", (), ("you know",)),
            ("I mean {t} basically {p}", (), ("I mean",)),
            ("so like {t} {p} can you take a look", ("take a look",), ("so like",))]
    for t in topics:
        for pb in problems:
            tpl, c_extra, nc = ftpl[idx % len(ftpl)]
            idx += 1
            cases.append(case(
                f"en_sp_{idx:04d}", "en_filler", tpl.format(t=t, p=pb),
                contains=(t.replace("the ", ""), ) + tuple(c_extra),
                not_contains=nc,
            ))
    questions = [
        "can we postpone the release to friday", "why does the login api return 500",
        "should we enable the feature flag now", "is the staging database in sync",
        "do we need another round of load testing", "could you double check the ssl renewal",
        "are the metrics dashboards up to date", "does the new sdk break old clients",
        "is it safe to delete the legacy bucket", "can the mobile team ship this week",
        "why is the queue backing up at midnight", "should we rotate the api keys today",
    ]
    for q in questions:
        for fr in ["{q}", "um {q}", "you know {q}"]:
            idx += 1
            cases.append(case(
                f"en_sp_{idx:04d}", "en_question", fr.format(q=q),
                contains=(q.split()[2],),
                regex=(r"\?",),
                not_contains=("um ", "you know"),
            ))
    corrections = [("three", "four", "move the meeting to {x} pm", r"(?i)(4\s*pm|four pm)"),
                   ("two", "five", "we need {x} more servers", r"(?i)(five|5) (more )?servers"),
                   ("ten", "twenty", "set the timeout to {x} seconds", r"(?i)(twenty|20) seconds"),
                   ("monday", "tuesday", "ship it on {x}", r"(?i)tuesday")]
    for a, b, tpl, expect_re in corrections:
        for fr in ["{s} no wait {t}", "{s} sorry I mean {t}", "{s} actually make that {t}"]:
            idx += 1
            sent = fr.format(s=tpl.format(x=a), t=b)
            cases.append(case(
                f"en_sp_{idx:04d}", "en_self_correction", sent,
                regex=(expect_re,),
                not_contains=("no wait", "sorry I mean", "make that"),
            ))
    percents = [("fifteen percent", "15%"), ("five percent", "5%"), ("eighty percent", "80%"),
                ("ninety nine percent", "99%"), ("twenty five percent", "25%")]
    nctx = ["the discount is {x}", "coverage must reach {x}", "error rate dropped below {x}",
            "traffic grew by {x}"]
    for sp, val in percents:
        for ctx in nctx:
            idx += 1
            cases.append(case(f"en_sp_{idx:04d}", "en_number", ctx.format(x=sp), contains=(val,)))
    return cases


def gen_ko_special() -> list[dict]:
    cases: list[dict] = []
    idx = 0
    sites = ["naver", "google", "github", "kakao", "daum", "coupang", "baemin", "toss"]
    for s in sites:
        for form in ["더블유 더블유 더블유 점 {s} 점 com", "www 점 {s} 점 com", "더블유 세 번 점 {s} 점 com"]:
            for fr in ["브라우저에서 {u} 열어 주세요", "주소는 {u} 입니다", "{u} 즐겨찾기에 추가해 주세요"]:
                idx += 1
                cases.append(case(
                    f"ko_sp_{idx:04d}", "ko_url", fr.format(u=form.format(s=s)),
                    contains=(f"www.{s}.com",),
                    not_contains=("더블유", " 점 "),
                ))
    first = ["john", "alice", "david", "maria", "kevin", "sarah"]
    last = ["smith", "brown", "wilson", "miller"]
    for i, f in enumerate(first):
        for j, l in enumerate(last):
            idx += 1
            dom = ["gmail", "naver", "kakao"][(i + j) % 3]
            cases.append(case(
                f"ko_sp_{idx:04d}", "ko_email",
                f"이메일은 {f} 점 {l} 골뱅이 {dom} 점 com 입니다",
                contains=(f"{f}.{l}@{dom}.com",),
                not_contains=("골뱅이", " 점 "),
            ))
    brands = [("deep sick", "DeepSeek"), ("chat gpt", "ChatGPT"), ("git hub", "GitHub"),
              ("open ai", "OpenAI"), ("java script", "JavaScript"), ("web socket", "WebSocket"),
              ("mongo db", "MongoDB"), ("fast api", "FastAPI")]
    bctx = ["{b} 최신 버전이 뭔지 확인해 주세요", "{b} 문서 링크 공유해 주세요",
            "다음 분기에 {b} 연동을 검토합니다", "음 {b} SDK 업그레이드가 필요해요",
            "{b} 요금제가 바뀌었대요", "신입에게 {b} 기초를 알려 주세요",
            "{b} 장애 공지 봤어요?", "우리 백엔드는 {b}에 의존해요"]
    for spoken, standard in brands:
        for ctx in bctx:
            idx += 1
            cases.append(case(
                f"ko_sp_{idx:04d}", "ko_brand", ctx.format(b=spoken),
                contains=(standard,),
            ))
    emotions = [
        ("와 이번 성능 개선 정말 대단하네요", ("와",)),
        ("아이고 배포가 또 실패했어요", ("아이고",)),
        ("어머 데이터가 다 날아갔어요", ("어머",)),
        ("와 새 디자인 진짜 예쁘네요", ("와",)),
        ("아이고 회의실이 또 꽉 찼네요", ("아이고",)),
        ("헐 트래픽이 두 배가 됐어요", ("트래픽",)),
    ]
    for text, c in emotions:
        for fr in ["{t}", "{t} 기록해 주세요", "{t} 팀에 공유해 주세요"]:
            idx += 1
            cases.append(case(f"ko_sp_{idx:04d}", "ko_interjection", fr.format(t=text), contains=c))
    topics = ["로그인 API", "결제 모듈", "푸시 알림", "검색 인덱스", "캐시 설정", "감사 로그",
              "업로드 기능", "회원 가입 플로우", "정산 배치", "알림 센터"]
    problems = ["왜 느린지", "왜 실패하는지", "왜 중복 호출되는지", "왜 데이터가 어긋나는지"]
    ftpl = [("음 {t}가 {p} 확인해 주세요", ("확인",), ("음 ",)),
            ("그러니까 {t}가 {p} 봐 주세요", (), ("그러니까",)),
            ("어 {t}가 {p} 급하게 봐야 해요", (), ("어 ",)),
            ("저기 {t}가 {p} 오늘 안에 알려 주세요", ("오늘",), ("저기",))]
    for t in topics:
        for pb in problems:
            tpl, c_extra, nc = ftpl[idx % len(ftpl)]
            idx += 1
            cases.append(case(
                f"ko_sp_{idx:04d}", "ko_filler", tpl.format(t=t, p=pb),
                contains=(t,) + tuple(c_extra),
                not_contains=nc,
            ))
    questions = [
        ("이 설정이 운영 환경에 영향을 주나요", "영향"),
        ("배포를 금요일로 미뤄도 되나요", "금요일"),
        ("지금 인증서를 갱신해야 하나요", "인증서"),
        ("테스트를 한 번 더 돌려야 할까요", "테스트"),
        ("이 버그가 구버전에서도 재현되나요", "재현"),
        ("모바일 팀이 이번 주에 출시할 수 있나요", "출시"),
        ("왜 새벽 배치가 계속 실패하나요", "배치"),
        ("API 키를 오늘 교체해야 하나요", "API"),
    ]
    for q, kw in questions:
        for fr in ["{q}", "음 {q}", "그러니까 {q}"]:
            idx += 1
            cases.append(case(
                f"ko_sp_{idx:04d}", "ko_question", fr.format(q=q),
                contains=(kw,), regex=(r"\?",), not_contains=("음 ", "그러니까"),
            ))
    corrections = [("3시", "4시", "회의를 {x}로 옮겨 주세요"),
                   ("두 대", "다섯 대", "서버를 {x} 더 늘려 주세요"),
                   ("월요일", "화요일", "{x}에 배포합시다")]
    for a, b, tpl in corrections:
        for fr in ["{s} 아 아니다 {t}", "{s} 아니 {t}", "{s} 죄송해요 {t}"]:
            idx += 1
            sent = fr.format(s=tpl.format(x=a), t=tpl.format(x=b))
            cases.append(case(
                f"ko_sp_{idx:04d}", "ko_self_correction", sent,
                contains=(b,), not_contains=(a, "아니다", "죄송해요"),
            ))
    keep = [("오늘 privacy policy 문구를 검토해 주세요", ("privacy policy",)),
            ("release checklist는 영어 그대로 둡니다", ("release checklist",)),
            ("이 단어 привет는 번역하지 마세요", ("привет",)),
            ("중국어 인사말 你好는 원문 유지", ("你好",)),
            ("일본어 ありがとう는 그대로 기록", ("ありがとう",)),
            ("preview 환경과 prod 환경 설정을 비교해 주세요", ("preview", "prod")),
            ("login API 응답이 느려요", ("login API",)),
            ("feature flag를 켜 주세요", ("feature flag",))]
    for text, c in keep:
        for fr in ["{t}", "음 {t}", "그 {t}"]:
            idx += 1
            cases.append(case(
                f"ko_sp_{idx:04d}", "ko_keep_foreign", fr.format(t=text),
                contains=c, not_contains=("음 ",),
            ))
    return cases


def gen_ru_special() -> list[dict]:
    cases: list[dict] = []
    idx = 0
    sites = ["yandex", "google", "github", "gitlab", "habr", "ozon", "avito", "vk"]
    tld = {"yandex": "ru", "habr": "com", "google": "com", "github": "com", "gitlab": "com",
           "ozon": "ru", "avito": "ru", "vk": "com"}
    for s in sites:
        for form in ["дабл-ю дабл-ю дабл-ю точка {s} точка {t}", "www точка {s} точка {t}",
                     "три дабл-ю точка {s} точка {t}"]:
            for fr in ["открой {u} в браузере", "адрес сайта {u}", "добавь {u} в закладки"]:
                idx += 1
                cases.append(case(
                    f"ru_sp_{idx:04d}", "ru_url", fr.format(u=form.format(s=s, t=tld[s])),
                    contains=(f"www.{s}.{tld[s]}",),
                    not_contains=("дабл-ю", " точка "),
                ))
    first = ["john", "alice", "david", "maria", "kevin", "sarah"]
    last = ["smith", "brown", "wilson", "miller"]
    for i, f in enumerate(first):
        for j, l in enumerate(last):
            idx += 1
            dom = ["gmail", "yandex", "mail"][(i + j) % 3]
            zone = "ru" if dom in ("yandex", "mail") else "com"
            cases.append(case(
                f"ru_sp_{idx:04d}", "ru_email",
                f"моя почта {f} точка {l} собака {dom} точка {zone}",
                contains=(f"{f}.{l}@{dom}.{zone}",),
                not_contains=("собака", " точка "),
            ))
    brands = [("deep sick", "DeepSeek"), ("chat gpt", "ChatGPT"), ("git hub", "GitHub"),
              ("open ai", "OpenAI"), ("java script", "JavaScript"), ("web socket", "WebSocket"),
              ("mongo db", "MongoDB"), ("fast api", "FastAPI")]
    bctx = ["проверь последнюю версию {b}", "скинь документацию по {b}",
            "ну надо интегрировать {b} в следующем спринте", "эм {b} SDK пора обновить",
            "тарифы {b} изменились", "расскажи новичку про {b}",
            "видел статус {b}? кажется упал", "наш бэкенд зависит от {b}"]
    for spoken, standard in brands:
        for ctx in bctx:
            idx += 1
            cases.append(case(
                f"ru_sp_{idx:04d}", "ru_brand", ctx.format(b=spoken),
                contains=(standard,),
            ))
    emotions = [
        ("ух ты этот закат просто потрясающий", ("ух ты",)),
        ("ох опять деплой упал", ("ох",)),
        ("ну и ну база данных снова легла", ("ну и ну",)),
        ("ух ты новый билд стартует вдвое быстрее", ("ух ты",)),
        ("ох сертификат опять истёк", ("ох", "сертификат")),
        ("вот это да конверсия выросла вдвое", ("конверсия",)),
    ]
    for text, c in emotions:
        for fr in ["{t}", "{t} запиши это", "{t} скажи команде"]:
            idx += 1
            cases.append(case(f"ru_sp_{idx:04d}", "ru_interjection", fr.format(t=text), contains=c))
    topics = [("логин апи", r"(?i)(логин|login)"), ("платёжный модуль", r"(?i)платёжн"),
              ("пуш уведомления", r"(?i)(пуш|push)"), ("поисковый индекс", r"(?i)поисков"),
              ("настройки кэша", r"(?i)кэш"), ("журнал аудита", r"(?i)аудит"),
              ("загрузка файлов", r"(?i)загрузк"), ("регистрация", r"(?i)регистрац"),
              ("ночной батч", r"(?i)батч"), ("центр уведомлений", r"(?i)уведомлен")]
    problems = ["почему тормозит", "почему падает", "почему дублирует запросы",
                "почему данные расходятся"]
    ftpl = [("эм проверь {t} {p}", r"(?i)проверь", ("эм ",)),
            ("ну короче глянь {t} {p}", r"(?i)глянь", ("короче",)),
            ("типа посмотри {t} {p}", r"(?i)посмотри", ("типа",)),
            ("значит надо разобраться {t} {p}", r"(?i)разобраться", ("значит",))]
    for t, t_re in topics:
        for pb in problems:
            tpl, c_re, nc = ftpl[idx % len(ftpl)]
            idx += 1
            cases.append(case(
                f"ru_sp_{idx:04d}", "ru_filler", tpl.format(t=t, p=pb),
                regex=(t_re, c_re),
                not_contains=nc,
            ))
    questions = [
        ("можно ли перенести релиз на понедельник", "релиз"),
        ("надо ли обновлять сертификаты сейчас", "сертификат"),
        ("почему очередь забивается по ночам", "очередь"),
        ("стоит ли включать фичефлаг сегодня", "сегодня"),
        ("безопасно ли удалять старый бакет", "бакет"),
        ("успеет ли мобильная команда к пятнице", "пятниц"),
        ("нужен ли ещё один круг нагрузочного тестирования", "тестирования"),
        ("совместим ли новый SDK со старыми клиентами", "SDK"),
    ]
    for q, kw in questions:
        for fr in ["{q}", "эм {q}", "ну {q}"]:
            idx += 1
            cases.append(case(
                f"ru_sp_{idx:04d}", "ru_question", fr.format(q=q),
                contains=(kw,), regex=(r"\?",), not_contains=("эм ",),
            ))
    corrections = [("три", "четыре", "перенеси встречу на {x} часа дня"),
                   ("два", "пять", "нам нужно ещё {x} сервера"),
                   ("понедельник", "вторник", "релиз в {x}")]
    for a, b, tpl in corrections:
        for fr in ["{s} нет подожди {t}", "{s} ой то есть {t}", "{s} вернее {t}"]:
            idx += 1
            sent = fr.format(s=tpl.format(x=a), t=tpl.format(x=b))
            cases.append(case(
                f"ru_sp_{idx:04d}", "ru_self_correction", sent,
                contains=(b,), not_contains=("подожди", "то есть", "вернее"),
            ))
    keep = [("термин privacy policy оставь на английском", ("privacy policy",)),
            ("release checklist не переводи", ("release checklist",)),
            ("корейское слово 오늘 оставь как есть", ("오늘",)),
            ("китайское приветствие 你好 сохрани в оригинале", ("你好",)),
            ("японское ありがとう запиши как есть", ("ありがとう",)),
            ("сравни конфиги preview и prod", ("preview", "prod")),
            ("login API отвечает медленно", ("login API",)),
            ("включи feature flag на проде", ("feature flag",))]
    for text, c in keep:
        for fr in ["{t}", "эм {t}", "ну так вот {t}"]:
            idx += 1
            cases.append(case(
                f"ru_sp_{idx:04d}", "ru_keep_foreign", fr.format(t=text),
                contains=c, not_contains=("эм ",),
            ))
    return cases


GENERATORS = {
    "zh_url_identifier": gen_url_identifier,
    "zh_public_correction": gen_public_correction,
    "zh_semantic_cleanup": gen_semantic_cleanup,
    "zh_numbers": gen_numbers,
    "zh_user_dict_hints": gen_user_dict_hints,
    "zh_multilingual_mix": gen_multilingual_mix,
    "zh_long_structure": gen_long_structure,
    "en_special": gen_en_special,
    "ko_special": gen_ko_special,
    "ru_special": gen_ru_special,
}


MIN_CASES_PER_FILE = 500

_PAD_TAILS = {
    "zh": ["，记录一下", "，同步给团队", "，今天之内确认"],
    "en": [" thanks", " please note it down", " and tell the team"],
    "ko": [" 기록해 주세요", " 팀에 공유해 주세요", " 오늘 안에 확인 부탁해요"],
    "ru": [" запиши это", " передай команде", " подтверди сегодня"],
}


def _pad_to_min(name: str, rows: list[dict]) -> list[dict]:
    """对无正则约束的 case 追加语言安全尾缀生成变体，把专项补足到 MIN_CASES_PER_FILE。"""
    lang = name.split("_", 1)[0]
    tails = _PAD_TAILS.get(lang, _PAD_TAILS["en"])
    padded = list(rows)
    cursor = 0
    tail_round = 0
    while len(padded) < MIN_CASES_PER_FILE:
        if cursor >= len(rows):
            cursor = 0
            tail_round += 1
            if tail_round >= len(tails):
                break
        base = rows[cursor]
        cursor += 1
        if base["regex"] or base["not_regex"]:
            continue
        tail = tails[tail_round]
        if any(part.strip() and part.strip() in tail for part in base["not_contains"]):
            continue
        variant = dict(base)
        variant["id"] = f"{base['id']}_v{tail_round + 1}"
        variant["text"] = base["text"] + tail
        variant["note"] = (base.get("note") or "") + " [padded variant]"
        padded.append(variant)
    return padded


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total = 0
    for name, gen in GENERATORS.items():
        rows = _pad_to_min(name, gen())
        path = OUT_DIR / f"{name}.jsonl"
        with path.open("w", encoding="utf-8") as fh:
            for row in rows:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        total += len(rows)
        print(f"{name}: {len(rows)} cases -> {path}")
    print(f"TOTAL: {total}")


if __name__ == "__main__":
    main()
