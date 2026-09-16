from app.services.audio.asr_correction.spoken_identifier import normalize_spoken_identifiers


def test_email_dot_pattern():
    assert normalize_spoken_identifiers("邮箱是晓东点王艾特qq点com") == "邮箱是xiaodong.wang@qq.com"


def test_email_underscore_pattern():
    assert normalize_spoken_identifiers("账号是丽娜下划线王艾特gmail点com") == "账号是lina_wang@gmail.com"


def test_email_in_sentence_keeps_prefix_words():
    out = normalize_spoken_identifiers("把报告发到春梅点李艾特163点com这个邮箱")
    assert out == "把报告发到chunmei.li@163.com这个邮箱"


def test_double_mention_only_email_converted():
    out = normalize_spoken_identifiers("账号是邵华点孙邮箱是邵华点孙艾特gmail点com")
    assert "shaohua.sun@gmail.com" in out
    assert "箱是" in out  # 前文不被吞进名字


def test_path_pattern():
    out = normalize_spoken_identifiers("路径是user斜杠邵华下划线孙杠test变量名是user下划线id")
    assert "user/shaohua_sun-test" in out


def test_non_chinese_language_passthrough():
    text = "my email is john dot smith at gmail dot com"
    assert normalize_spoken_identifiers(text, "en") == text


def test_plain_sentence_untouched():
    text = "我说的点不对，请帮我看一下艾特功能"
    assert normalize_spoken_identifiers(text) == text


def test_restore_email_tokens_underscore_to_dot():
    from app.services.audio.asr_correction.spoken_identifier import restore_email_tokens
    out = restore_email_tokens("账号是chunmei.wang@gmail.com", ["chunmei_wang@gmail.com"])
    assert out == "账号是chunmei_wang@gmail.com"


def test_restore_email_tokens_dot_to_underscore():
    from app.services.audio.asr_correction.spoken_identifier import restore_email_tokens
    out = restore_email_tokens("发到lina_wang@qq.com", ["lina.wang@qq.com"])
    assert out == "发到lina.wang@qq.com"


def test_restore_email_tokens_untouched_when_correct():
    from app.services.audio.asr_correction.spoken_identifier import restore_email_tokens
    text = "账号是chunmei_wang@gmail.com"
    assert restore_email_tokens(text, ["chunmei_wang@gmail.com"]) == text
