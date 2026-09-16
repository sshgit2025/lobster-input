package com.lobster.input.core.locale

import android.content.Context
import com.lobster.input.core.network.ApiConfig

enum class MobileLanguage(val code: String, val label: String) {
    ZH("zh", "简体中文"),
    ZH_HANT("zh-Hant", "繁體中文"),
    YUE("yue", "粵語（廣東省版）"),
    EN("en", "English"),
    RU("ru", "Русский"),
    KO("ko", "한국어")
}

object MobileStrings {
    private const val KEY_LANGUAGE = "app_language"

    fun currentLanguage(context: Context): MobileLanguage {
        val prefs = context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val code = prefs.getString(KEY_LANGUAGE, MobileLanguage.ZH.code)
        return MobileLanguage.values().firstOrNull { it.code == code } ?: MobileLanguage.ZH
    }

    fun setLanguage(context: Context, language: MobileLanguage) {
        context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_LANGUAGE, language.code)
            .apply()
    }

    private fun lang(context: Context) = currentLanguage(context)

    fun keyboardTitle(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "龍蝦輸入法"
        MobileLanguage.EN -> "Lobster Input"
        MobileLanguage.RU -> "Лобстер Ввод"
        MobileLanguage.KO -> "랍스터 입력기"
        else -> "龙虾输入法"
    }

    fun tapToSpeak(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "點擊說話"
        MobileLanguage.YUE -> "撳一下講嘢"
        MobileLanguage.EN -> "Tap to speak"
        MobileLanguage.RU -> "Нажмите и говорите"
        MobileLanguage.KO -> "탭하여 말하기"
        else -> "点击说话"
    }

    fun holdToSpeak(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "長按說話"
        MobileLanguage.YUE -> "長按講嘢"
        MobileLanguage.EN -> "Hold to speak"
        MobileLanguage.RU -> "Удерживайте и говорите"
        MobileLanguage.KO -> "길게 눌러 말하기"
        else -> "长按说话"
    }

    /** 键盘模式:返回语音输入入口文案。 */
    fun returnVoice(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "返回語音"
        MobileLanguage.EN -> "Voice"
        MobileLanguage.RU -> "Голос"
        MobileLanguage.KO -> "음성"
        else -> "返回语音"
    }

    /** 键盘模式:空格键文案。 */
    fun spaceKey(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "space"
        MobileLanguage.RU -> "пробел"
        MobileLanguage.KO -> "스페이스"
        else -> "空格"
    }

    /** 语音面板:切换到打字键盘的模式按钮文案。 */
    fun keyboardModeLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "鍵盤"
        MobileLanguage.EN -> "Keyboard"
        MobileLanguage.RU -> "Клавиатура"
        MobileLanguage.KO -> "키보드"
        else -> "键盘"
    }

    /** 键盘布局:九宫格。 */
    fun nineGridLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "九宮格"
        MobileLanguage.EN -> "9-key"
        MobileLanguage.RU -> "9-кл."
        MobileLanguage.KO -> "9키"
        else -> "九宫格"
    }

    /** 键盘布局:26 键。 */
    fun qwertyLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "26鍵"
        MobileLanguage.EN -> "QWERTY"
        MobileLanguage.RU -> "QWERTY"
        MobileLanguage.KO -> "26키"
        else -> "26键"
    }

    fun imeChineseLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "中"
        MobileLanguage.RU -> "中"
        MobileLanguage.KO -> "中"
        else -> "中"
    }

    fun imeEnglishLabel(context: Context): String = "EN"

    fun symbolKeyLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Sym"
        MobileLanguage.RU -> "Симв"
        MobileLanguage.KO -> "기호"
        else -> "符"
    }

    fun switchQwertyLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "QWERTY"
        MobileLanguage.RU -> "QWERTY"
        MobileLanguage.KO -> "26키"
        else -> "切26"
    }

    fun pinyinKeyLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Pin"
        MobileLanguage.RU -> "Пин"
        MobileLanguage.KO -> "병음"
        else -> "拼"
    }

    /** 工具/emoji/剪贴板子页:拼音模式返回键完整文案。 */
    fun pinyinLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Pinyin"
        MobileLanguage.RU -> "Пиньинь"
        MobileLanguage.KO -> "병음"
        else -> "拼音"
    }

    fun abcKeyLabel(context: Context): String = "ABC"

    fun syllableSepKey(context: Context): String = "'"

    fun pinyinDictLoading(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "詞庫載入中…"
        MobileLanguage.EN -> "Loading dictionary..."
        MobileLanguage.RU -> "Загрузка словаря..."
        MobileLanguage.KO -> "사전 로딩 중..."
        else -> "词库加载中…"
    }

    fun pinyinDictFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "詞庫載入失敗，請重啟鍵盤"
        MobileLanguage.EN -> "Dictionary failed to load. Restart keyboard."
        MobileLanguage.RU -> "Не удалось загрузить словарь. Перезапустите клавиатуру."
        MobileLanguage.KO -> "사전 로드 실패. 키보드를 다시 시작하세요."
        else -> "词库加载失败，请重启键盘"
    }

    fun keyboardMicFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "語音輸入失敗"
        MobileLanguage.EN -> "Voice input failed"
        MobileLanguage.RU -> "Голосовой ввод не удался"
        MobileLanguage.KO -> "음성 입력 실패"
        else -> "语音输入失败"
    }

    fun typingUndone(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "已撤銷"
        MobileLanguage.EN -> "Undone"
        MobileLanguage.RU -> "Отменено"
        MobileLanguage.KO -> "실행 취소됨"
        else -> "已撤销"
    }

    fun enterNewline(context: Context): String = "↵"
    fun enterSearch(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "搜尋"
        MobileLanguage.EN -> "Search"
        MobileLanguage.RU -> "Поиск"
        MobileLanguage.KO -> "검색"
        else -> "搜索"
    }
    fun enterSend(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "傳送"
        MobileLanguage.EN -> "Send"
        MobileLanguage.RU -> "Отпр."
        MobileLanguage.KO -> "전송"
        else -> "发送"
    }
    fun enterGo(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Go"
        MobileLanguage.RU -> "Перейти"
        MobileLanguage.KO -> "이동"
        else -> "前往"
    }
    fun enterDone(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Done"
        MobileLanguage.RU -> "Готово"
        MobileLanguage.KO -> "완료"
        else -> "完成"
    }
    fun enterNext(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "下一項"
        MobileLanguage.EN -> "Next"
        MobileLanguage.RU -> "Далее"
        MobileLanguage.KO -> "다음"
        else -> "下一项"
    }
    fun enterPrevious(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "上一項"
        MobileLanguage.EN -> "Prev"
        MobileLanguage.RU -> "Назад"
        MobileLanguage.KO -> "이전"
        else -> "上一项"
    }

    fun a11yKeyLetter(context: Context, ch: String): String = ch
    fun a11yKeyT9(context: Context, label: String, digit: String): String = "$label $digit"
    fun a11yKeyDelete(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "刪除"
        MobileLanguage.EN -> "Delete"
        MobileLanguage.RU -> "Удалить"
        MobileLanguage.KO -> "삭제"
        else -> "删除"
    }
    fun a11yKeySpace(context: Context): String = spaceKey(context)
    fun a11yKeyEnter(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "輸入鍵"
        MobileLanguage.EN -> "Enter"
        MobileLanguage.RU -> "Ввод"
        MobileLanguage.KO -> "엔터"
        else -> "回车"
    }
    fun a11yKeyShift(context: Context): String = "Shift"
    fun a11yKeyShiftOn(context: Context): String = "Shift on"
    fun a11yKeyCapsLock(context: Context): String = "Caps lock"
    fun a11yKeyLang(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "切換語言"
        MobileLanguage.EN -> "Switch language"
        MobileLanguage.RU -> "Сменить язык"
        MobileLanguage.KO -> "언어 전환"
        else -> "切换语言"
    }
    fun a11yKeyLayout(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "切換佈局"
        MobileLanguage.EN -> "Switch layout"
        MobileLanguage.RU -> "Сменить раскладку"
        MobileLanguage.KO -> "배열 전환"
        else -> "切换布局"
    }
    fun a11yKeySymbols(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "符號"
        MobileLanguage.EN -> "Symbols"
        MobileLanguage.RU -> "Символы"
        MobileLanguage.KO -> "기호"
        else -> "符号"
    }
    fun a11yKeyAlpha(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Letters"
        MobileLanguage.RU -> "Буквы"
        MobileLanguage.KO -> "문자"
        else -> "字母"
    }
    fun a11yKeySymPage(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "符號頁"
        MobileLanguage.EN -> "Symbol page"
        MobileLanguage.RU -> "Страница символов"
        MobileLanguage.KO -> "기호 페이지"
        else -> "符号页"
    }
    fun a11yKeyChar(context: Context, ch: String): String = ch
    fun a11yKeyMic(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "按住說話"
        MobileLanguage.YUE -> "按住講嘢"
        MobileLanguage.EN -> "Hold to speak"
        MobileLanguage.RU -> "Удерживайте и говорите"
        MobileLanguage.KO -> "길게 눌러 말하기"
        else -> "按住说话"
    }

    fun realtimeConnecting(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "正在連線..."
        MobileLanguage.EN -> "Connecting..."
        MobileLanguage.RU -> "Подключение..."
        MobileLanguage.KO -> "연결 중..."
        else -> "正在连接..."
    }

    fun releaseToSend(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "鬆開發送"
        MobileLanguage.YUE -> "鬆手發送"
        MobileLanguage.EN -> "Release to send"
        MobileLanguage.RU -> "Отпустите для отправки"
        MobileLanguage.KO -> "놓으면 전송"
        else -> "松开发送"
    }

    fun realtimeFinishing(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "正在完成識別..."
        MobileLanguage.EN -> "Finishing recognition..."
        MobileLanguage.RU -> "Завершаем распознавание..."
        MobileLanguage.KO -> "인식 마무리 중..."
        else -> "正在完成识别..."
    }

    fun rewriteHint(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "選中文字、處理剛才輸入，或直接說新指令"
        MobileLanguage.YUE -> "揀選文字、處理啱先嘅輸入，或者直接講新指令"
        MobileLanguage.EN -> "Select text, reuse the last insert, or speak a new command"
        MobileLanguage.RU -> "Выделите текст, исправьте последний ввод или продиктуйте команду"
        MobileLanguage.KO -> "텍스트 선택, 최근 입력 수정 또는 새 명령 말하기"
        else -> "选中文本、处理刚才输入，或直接说新指令"
    }

    fun tapAgainTranscribe(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "再次點擊以完成"
        MobileLanguage.YUE -> "再撳一下完成"
        MobileLanguage.EN -> "Tap again to finish"
        MobileLanguage.RU -> "Нажмите еще раз"
        MobileLanguage.KO -> "다시 탭해 완료"
        else -> "再次点击以完成"
    }

    fun tapAgainRewrite(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "再次點擊以完成"
        MobileLanguage.YUE -> "再撳一下完成"
        MobileLanguage.EN -> "Tap again to finish"
        MobileLanguage.RU -> "Нажмите еще раз"
        MobileLanguage.KO -> "다시 탭해 완료"
        else -> "再次点击以完成"
    }

    fun remainingSeconds(context: Context, seconds: Int): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "剩餘 ${seconds} 秒"
        MobileLanguage.EN -> "${seconds}s left"
        MobileLanguage.RU -> "Осталось ${seconds}с"
        MobileLanguage.KO -> "${seconds}초 남음"
        else -> "剩余 ${seconds} 秒"
    }

    fun processing(context: Context, rewrite: Boolean): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> if (rewrite) "正在處理指令..." else "正在識別語音..."
        MobileLanguage.EN -> if (rewrite) "Processing command..." else "Recognizing voice..."
        MobileLanguage.RU -> if (rewrite) "Обработка команды..." else "Распознавание голоса..."
        MobileLanguage.KO -> if (rewrite) "명령 처리 중..." else "음성 인식 중..."
        else -> if (rewrite) "正在处理指令..." else "正在识别语音..."
    }

    fun inserted(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "已填入，可用指令修改或繼續生成"
        MobileLanguage.YUE -> "已填入，可以用指令修改或者繼續生成"
        MobileLanguage.EN -> "Inserted. Use Command to edit or continue."
        MobileLanguage.RU -> "Вставлено. Командой можно исправить или продолжить."
        MobileLanguage.KO -> "입력됨. 명령으로 수정하거나 이어갈 수 있습니다."
        else -> "已填入，可用指令修改或继续生成"
    }

    fun rewritten(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Done"
        MobileLanguage.RU -> "Готово"
        MobileLanguage.KO -> "완료"
        else -> "已完成"
    }

    fun loginRequired(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "請先在龍蝦輸入法 App 中登入"
        MobileLanguage.YUE -> "請先喺龍蝦輸入法 App 登入"
        MobileLanguage.EN -> "Please sign in from the Lobster app"
        MobileLanguage.RU -> "Войдите в приложении Lobster"
        MobileLanguage.KO -> "랍스터 앱에서 로그인하세요"
        else -> "请先在龙虾输入法 App 中登录"
    }

    fun sessionExpired(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "登入已過期，請在龍蝦輸入法 App 中重新登入"
        MobileLanguage.YUE -> "登入過咗期，請喺龍蝦輸入法 App 重新登入"
        MobileLanguage.EN -> "Session expired. Sign in again from the Lobster app."
        MobileLanguage.RU -> "Сессия истекла. Войдите снова в приложении Lobster."
        MobileLanguage.KO -> "로그인이 만료되었습니다. 랍스터 앱에서 다시 로그인하세요."
        else -> "登录已过期，请在龙虾输入法 App 中重新登录"
    }

    fun creditsExhausted(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "積分已用完"
        MobileLanguage.YUE -> "積分用晒"
        MobileLanguage.EN -> "Credits exhausted"
        MobileLanguage.RU -> "Кредиты закончились"
        MobileLanguage.KO -> "크레딧이 부족합니다"
        else -> "积分已用完"
    }

    fun checkingAccount(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "正在檢查帳戶..."
        MobileLanguage.EN -> "Checking account..."
        MobileLanguage.RU -> "Проверяем аккаунт..."
        MobileLanguage.KO -> "계정 확인 중..."
        else -> "正在检查账户..."
    }

    fun inputUnavailableTitle(context: Context, creditsExhausted: Boolean): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> if (creditsExhausted) "積分已用完" else "需要登入"
        MobileLanguage.YUE -> if (creditsExhausted) "積分用晒" else "需要登入"
        MobileLanguage.EN -> if (creditsExhausted) "Credits exhausted" else "Sign in required"
        MobileLanguage.RU -> if (creditsExhausted) "Кредиты закончились" else "Нужен вход"
        MobileLanguage.KO -> if (creditsExhausted) "크레딧 부족" else "로그인 필요"
        else -> if (creditsExhausted) "积分已用完" else "需要登录"
    }

    fun inputUnavailableBody(context: Context, creditsExhausted: Boolean): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> if (creditsExhausted) {
            "當前無法語音輸入。可先切換到其它輸入法繼續輸入，或打開 App 查看積分。"
        } else {
            "登入前無法語音輸入。可先切換到其它輸入法繼續輸入，或打開 App 登入。"
        }
        MobileLanguage.YUE -> if (creditsExhausted) {
            "而家用唔到語音輸入。可以先切換去其它輸入法繼續打字，或者打開 App 睇積分。"
        } else {
            "登入之前用唔到語音輸入。可以先切換去其它輸入法繼續打字，或者打開 App 登入。"
        }
        MobileLanguage.EN -> if (creditsExhausted) {
            "Voice input is unavailable right now. Switch keyboards to keep typing, or open the app to check credits."
        } else {
            "Voice input is unavailable before sign-in. Switch keyboards to keep typing, or open the app to sign in."
        }
        MobileLanguage.RU -> if (creditsExhausted) {
            "Голосовой ввод сейчас недоступен. Переключите клавиатуру или откройте приложение для проверки кредитов."
        } else {
            "До входа голосовой ввод недоступен. Переключите клавиатуру или откройте приложение для входа."
        }
        MobileLanguage.KO -> if (creditsExhausted) {
            "지금은 음성 입력을 사용할 수 없습니다. 다른 키보드로 전환하거나 앱에서 크레딧을 확인하세요."
        } else {
            "로그인 전에는 음성 입력을 사용할 수 없습니다. 다른 키보드로 전환하거나 앱에서 로그인하세요."
        }
        else -> if (creditsExhausted) {
            "当前无法语音输入。可先切换到其它输入法继续输入，或打开 App 查看积分。"
        } else {
            "登录前无法语音输入。可先切换到其它输入法继续输入，或打开 App 登录。"
        }
    }

    fun switchKeyboard(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "切換輸入法"
        MobileLanguage.EN -> "Keyboard"
        MobileLanguage.RU -> "Клав."
        MobileLanguage.KO -> "키보드 전환"
        else -> "切换输入法"
    }

    fun openApp(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "打開 App"
        MobileLanguage.EN -> "Open app"
        MobileLanguage.RU -> "Открыть"
        MobileLanguage.KO -> "앱 열기"
        else -> "打开 App"
    }

    fun micPermission(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "需要錄音權限"
        MobileLanguage.EN -> "Microphone permission required"
        MobileLanguage.RU -> "Нужен доступ к микрофону"
        MobileLanguage.KO -> "마이크 권한이 필요합니다"
        else -> "需要录音权限"
    }

    fun newline(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "換行"
        MobileLanguage.EN -> "Line"
        MobileLanguage.RU -> "Строка"
        MobileLanguage.KO -> "줄바꿈"
        else -> "换行"
    }

    fun undo(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Undo"
        MobileLanguage.RU -> "Отмена"
        MobileLanguage.KO -> "취소"
        else -> "撤回"
    }

    fun restoreVoice(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "還原"
        MobileLanguage.EN -> "Restore"
        MobileLanguage.RU -> "Вернуть"
        MobileLanguage.KO -> "복원"
        else -> "还原"
    }

    fun leftHand(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Left"
        MobileLanguage.RU -> "Лев"
        MobileLanguage.KO -> "왼손"
        else -> "左手"
    }

    fun rightHand(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Right"
        MobileLanguage.RU -> "Прав"
        MobileLanguage.KO -> "오른손"
        else -> "右手"
    }

    fun recordingStartFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "錄音啟動失敗"
        MobileLanguage.EN -> "Could not start recording"
        MobileLanguage.RU -> "Не удалось начать запись"
        MobileLanguage.KO -> "녹음을 시작할 수 없습니다"
        else -> "录音启动失败"
    }

    fun restoredVoice(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "已還原"
        MobileLanguage.EN -> "Restored"
        MobileLanguage.RU -> "Восстановлено"
        MobileLanguage.KO -> "복원됨"
        else -> "已还原"
    }

    fun quickFormat(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Fmt"
        MobileLanguage.RU -> "Форм."
        MobileLanguage.KO -> "정리"
        else -> "格式化"
    }

    fun quickPolish(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "潤色"
        MobileLanguage.EN -> "Polish"
        MobileLanguage.RU -> "Стиль"
        MobileLanguage.KO -> "다듬기"
        else -> "润色"
    }

    fun quickConcise(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "精簡"
        MobileLanguage.EN -> "Short"
        MobileLanguage.RU -> "Кратко"
        MobileLanguage.KO -> "줄이기"
        else -> "精简"
    }

    fun clearInput(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Clear"
        MobileLanguage.RU -> "Очист."
        MobileLanguage.KO -> "지우기"
        else -> "清空"
    }

    fun inputCleared(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Cleared"
        MobileLanguage.RU -> "Очищено"
        MobileLanguage.KO -> "지웠어요"
        else -> "已清空"
    }

    fun quickBullets(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "要點"
        MobileLanguage.EN -> "List"
        MobileLanguage.RU -> "Список"
        MobileLanguage.KO -> "요점"
        else -> "要点"
    }

    fun quickProcessing(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "正在處理文字..."
        MobileLanguage.EN -> "Processing text..."
        MobileLanguage.RU -> "Обработка текста..."
        MobileLanguage.KO -> "텍스트 처리 중..."
        else -> "正在处理文本..."
    }

    fun rewrite(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Command"
        MobileLanguage.RU -> "Команда"
        MobileLanguage.KO -> "명령"
        else -> "指令"
    }

    fun emptyRewrite(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "處理結果為空"
        MobileLanguage.EN -> "Result is empty"
        MobileLanguage.RU -> "Результат пуст"
        MobileLanguage.KO -> "결과가 비었습니다"
        else -> "处理结果为空"
    }

    fun noRewriteTarget(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "說出指令，可生成新文字或修改選中文字"
        MobileLanguage.YUE -> "講出指令，可以生成新文字或者修改揀選嘅文字"
        MobileLanguage.EN -> "Speak a command to generate text or edit selected text"
        MobileLanguage.RU -> "Продиктуйте команду для создания или правки текста"
        MobileLanguage.KO -> "명령을 말해 새 텍스트를 만들거나 선택 텍스트를 수정하세요"
        else -> "说出指令，可生成新文本或修改选中文本"
    }

    fun commandHint(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "指令可修改選區，也可直接生成"
        MobileLanguage.YUE -> "指令可以修改選區，亦可以直接生成"
        MobileLanguage.EN -> "Command can edit selected text or create new text"
        MobileLanguage.RU -> "Команда: правка выделенного или новый текст"
        MobileLanguage.KO -> "명령: 선택 수정 또는 새 텍스트"
        else -> "指令可修改选区，也可直接生成"
    }

    fun emptyTranscribe(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "沒有識別到可輸入內容"
        MobileLanguage.YUE -> "識別唔到可輸入嘅內容"
        MobileLanguage.EN -> "No text recognized"
        MobileLanguage.RU -> "Текст не распознан"
        MobileLanguage.KO -> "인식된 텍스트가 없습니다"
        else -> "没有识别到可输入内容"
    }

    fun emptyResponse(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "回應為空"
        MobileLanguage.EN -> "Empty response"
        MobileLanguage.RU -> "Пустой ответ"
        MobileLanguage.KO -> "빈 응답"
        else -> "响应为空"
    }

    fun requestFailed(context: Context, statusCode: Int): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "請求失敗($statusCode)"
        MobileLanguage.EN -> "Request failed ($statusCode)"
        MobileLanguage.RU -> "Запрос не удался ($statusCode)"
        MobileLanguage.KO -> "요청 실패 ($statusCode)"
        else -> "请求失败($statusCode)"
    }

    fun processFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "處理失敗"
        MobileLanguage.EN -> "Processing failed"
        MobileLanguage.RU -> "Обработка не удалась"
        MobileLanguage.KO -> "처리 실패"
        else -> "处理失败"
    }

    fun accountCheckFailed(context: Context, statusCode: Int? = null): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "帳戶狀態檢查失敗" + statusCode?.let { "($it)" }.orEmpty()
        MobileLanguage.EN -> "Account check failed" + statusCode?.let { " ($it)" }.orEmpty()
        MobileLanguage.RU -> "Проверка аккаунта не удалась" + statusCode?.let { " ($it)" }.orEmpty()
        MobileLanguage.KO -> "계정 확인 실패" + statusCode?.let { " ($it)" }.orEmpty()
        else -> "账户状态检查失败" + statusCode?.let { "($it)" }.orEmpty()
    }

    fun processingShort(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "處理中..."
        MobileLanguage.EN -> "Work..."
        MobileLanguage.RU -> "Ждем..."
        MobileLanguage.KO -> "처리 중..."
        else -> "处理中..."
    }

    fun symbols(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "符號"
        MobileLanguage.EN -> "Sym"
        MobileLanguage.RU -> "Симв"
        MobileLanguage.KO -> "기호"
        else -> "符号"
    }

    fun persona(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "人設"
        MobileLanguage.EN -> "Role"
        MobileLanguage.RU -> "Роль"
        MobileLanguage.KO -> "페르소나"
        else -> "人设"
    }

    fun personaHint(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "選擇語音輸入與指令處理風格"
        MobileLanguage.YUE -> "揀語音輸入同指令處理風格"
        MobileLanguage.EN -> "Choose style for dictation and commands"
        MobileLanguage.RU -> "Стиль для диктовки и команд"
        MobileLanguage.KO -> "음성 입력과 명령 결과에 사용할 페르소나 선택"
        else -> "选择语音输入与指令处理风格"
    }

    fun personaEmpty(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "暫無人設"
        MobileLanguage.EN -> "No personas yet"
        MobileLanguage.RU -> "Персон пока нет"
        MobileLanguage.KO -> "페르소나 없음"
        else -> "暂无人设"
    }

    fun active(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "已啟用"
        MobileLanguage.EN -> "Active"
        MobileLanguage.RU -> "Активно"
        MobileLanguage.KO -> "활성"
        else -> "已启用"
    }

    fun inactive(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "未啟用"
        MobileLanguage.EN -> "Inactive"
        MobileLanguage.RU -> "Неактивно"
        MobileLanguage.KO -> "비활성"
        else -> "未启用"
    }

    fun enable(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "啟用"
        MobileLanguage.EN -> "On"
        MobileLanguage.RU -> "Вкл"
        MobileLanguage.KO -> "켜기"
        else -> "启用"
    }

    fun disable(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "停用"
        MobileLanguage.EN -> "Off"
        MobileLanguage.RU -> "Выкл"
        MobileLanguage.KO -> "끄기"
        else -> "停用"
    }

    fun refresh(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "刷新"
        MobileLanguage.EN -> "Reload"
        MobileLanguage.RU -> "Обн."
        MobileLanguage.KO -> "새로고침"
        else -> "刷新"
    }

    fun back(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "返回"
        MobileLanguage.EN -> "Back"
        MobileLanguage.RU -> "Назад"
        MobileLanguage.KO -> "뒤로"
        else -> "返回"
    }

    fun personaTranscribe(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "語音輸入"
        MobileLanguage.EN -> "Voice"
        MobileLanguage.RU -> "Голос"
        MobileLanguage.KO -> "음성 입력"
        else -> "语音输入"
    }

    fun personaRewrite(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "指令"
        MobileLanguage.EN -> "Command"
        MobileLanguage.RU -> "Команда"
        MobileLanguage.KO -> "명령"
        else -> "指令"
    }

    fun personaIntent(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "意圖"
        MobileLanguage.EN -> "Intent"
        MobileLanguage.RU -> "Интент"
        MobileLanguage.KO -> "의도"
        else -> "意图"
    }

    fun personaModuleHint(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "啟用後作用於語音輸入和指令處理"
        MobileLanguage.YUE -> "啟用後會用喺語音輸入同指令處理"
        MobileLanguage.EN -> "Toggle modules for this role"
        MobileLanguage.RU -> "Модули этой роли"
        MobileLanguage.KO -> "음성 입력과 명령에 사용할 페르소나를 켜세요"
        else -> "启用后作用于语音输入和指令处理"
    }

    fun customized(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "自訂"
        MobileLanguage.EN -> "Custom"
        MobileLanguage.RU -> "Свое"
        MobileLanguage.KO -> "사용자"
        else -> "自定义"
    }

    fun builtin(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "預設"
        MobileLanguage.EN -> "Built-in"
        MobileLanguage.RU -> "База"
        MobileLanguage.KO -> "기본"
        else -> "默认"
    }

    fun fastMode(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "極速"
        MobileLanguage.EN -> "Fast"
        MobileLanguage.RU -> "Быстро"
        MobileLanguage.KO -> "빠름"
        else -> "极速"
    }

    /** 开关状态后缀(极速按钮等):开。 */
    fun stateOn(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "開"
        MobileLanguage.EN -> "ON"
        MobileLanguage.RU -> "ВКЛ"
        MobileLanguage.KO -> "켬"
        else -> "开"
    }

    /** 开关状态后缀(极速按钮等):关。 */
    fun stateOff(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "關"
        MobileLanguage.EN -> "OFF"
        MobileLanguage.RU -> "ВЫКЛ"
        MobileLanguage.KO -> "끔"
        else -> "关"
    }

    fun networkError(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "網絡連接失敗"
        MobileLanguage.EN -> "Network error"
        MobileLanguage.RU -> "Ошибка сети"
        MobileLanguage.KO -> "네트워크 연결 실패"
        else -> "网络连接失败"
    }

    fun userBanned(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "帳號已被停用"
        MobileLanguage.EN -> "Account disabled"
        MobileLanguage.RU -> "Аккаунт заблокирован"
        MobileLanguage.KO -> "계정이 비활성화되었습니다"
        else -> "账号已被禁用"
    }

    fun chineseSymbols(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "CN"
        MobileLanguage.RU -> "Кит"
        MobileLanguage.KO -> "중"
        else -> "中文"
    }

    fun englishSymbols(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "EN"
        MobileLanguage.RU -> "Анг"
        MobileLanguage.KO -> "영"
        else -> "英文"
    }

    /** 键盘工具子页:切换 26 键磁贴。 */
    fun switchTo26Keys(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "切換 26 鍵"
        MobileLanguage.EN -> "Switch to QWERTY"
        MobileLanguage.RU -> "Раскладка QWERTY"
        MobileLanguage.KO -> "26키로 전환"
        else -> "切换 26 键"
    }

    /** 键盘工具子页:切换九宫格磁贴。 */
    fun switchToNineGrid(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "切換九宮格"
        MobileLanguage.EN -> "Switch to 9-key"
        MobileLanguage.RU -> "Раскладка 9 кл."
        MobileLanguage.KO -> "9키로 전환"
        else -> "切换九宫格"
    }

    /** 键盘工具子页:表情磁贴。 */
    fun toolEmoji(context: Context): String = when (lang(context)) {
        MobileLanguage.EN -> "Emoji"
        MobileLanguage.RU -> "Эмодзи"
        MobileLanguage.KO -> "이모지"
        else -> "表情"
    }

    /** 键盘工具子页/剪贴板面板:剪贴板。 */
    fun toolClipboard(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "剪貼簿"
        MobileLanguage.EN -> "Clipboard"
        MobileLanguage.RU -> "Буфер"
        MobileLanguage.KO -> "클립보드"
        else -> "剪贴板"
    }

    /** 键盘工具子页:已在俄语键盘时的退出磁贴。 */
    fun exitRussian(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "退出俄語"
        MobileLanguage.EN -> "Exit"
        MobileLanguage.RU -> "Выход"
        MobileLanguage.KO -> "종료"
        else -> "退出俄语"
    }

    /** 键盘工具子页:已在韩语键盘时的退出磁贴。 */
    fun exitKorean(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "退出韓語"
        MobileLanguage.EN -> "Exit"
        MobileLanguage.RU -> "Выход"
        MobileLanguage.KO -> "종료"
        else -> "退出韩语"
    }

    /** 剪贴板面板:空态提示。 */
    fun clipEmptyHint(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "暫無剪貼內容，複製文字後會出現在這裡"
        MobileLanguage.YUE -> "暫時冇剪貼內容，複製文字後會喺呢度出現"
        MobileLanguage.EN -> "No clips yet — copied text shows here"
        MobileLanguage.RU -> "Пока пусто — скопированный текст появится здесь"
        MobileLanguage.KO -> "클립 없음 — 복사한 텍스트가 여기에 표시됩니다"
        else -> "暂无剪贴内容，复制文本后会出现在这里"
    }

    /** 剪贴板面板:快捷短语分组标题。 */
    fun quickPhrasesLabel(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "快捷短語"
        MobileLanguage.EN -> "Quick phrases"
        MobileLanguage.RU -> "Быстрые фразы"
        MobileLanguage.KO -> "빠른 문구"
        else -> "快捷短语"
    }

    fun sendCodeFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "發送驗證碼失敗"
        MobileLanguage.EN -> "Could not send code"
        MobileLanguage.RU -> "Код не отправлен"
        MobileLanguage.KO -> "인증 코드를 보낼 수 없습니다"
        else -> "发送验证码失败"
    }

    fun loginFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "登入失敗"
        MobileLanguage.EN -> "Sign-in failed"
        MobileLanguage.RU -> "Вход не удался"
        MobileLanguage.KO -> "로그인 실패"
        else -> "登录失败"
    }

    fun inviteVerifyFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "邀請碼驗證失敗"
        MobileLanguage.EN -> "Invite check failed"
        MobileLanguage.RU -> "Код приглашения не принят"
        MobileLanguage.KO -> "초대 코드 확인 실패"
        else -> "邀请码验证失败"
    }

    fun registrationDisabled(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "未開放註冊"
        MobileLanguage.EN -> "Registration is not open"
        MobileLanguage.RU -> "Регистрация пока закрыта"
        MobileLanguage.KO -> "현재 가입이 열려 있지 않습니다"
        else -> "未开放注册"
    }

    fun apiErrorMessage(context: Context, code: String?, fallback: String?): String {
        return when (code) {
            "REGISTRATION_DISABLED" -> registrationDisabled(context)
            else -> fallback?.takeIf { it.isNotBlank() } ?: processFailed(context)
        }
    }

    fun mainLoadPlanFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "載入帳戶資訊失敗"
        MobileLanguage.EN -> "Could not load account"
        MobileLanguage.RU -> "Аккаунт не загружен"
        MobileLanguage.KO -> "계정 정보를 불러올 수 없습니다"
        else -> "加载账户信息失败"
    }

    fun mainPaymentCheckoutOpened(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "已打開支付頁面。支付完成後回到本頁刷新狀態。"
        MobileLanguage.YUE -> "已打開支付頁面。支付完成後返嚟本頁刷新狀態。"
        MobileLanguage.EN -> "Payment page opened. Return here after payment and refresh."
        MobileLanguage.RU -> "Страница оплаты открыта. Вернитесь после оплаты и обновите."
        MobileLanguage.KO -> "결제 페이지가 열렸습니다. 결제 후 돌아와 새로고침하세요."
        else -> "已打开支付页面。支付完成后回到本页刷新状态。"
    }

    fun mainPaymentCheckoutFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "建立支付失敗"
        MobileLanguage.EN -> "Could not create payment"
        MobileLanguage.RU -> "Не удалось создать оплату"
        MobileLanguage.KO -> "결제를 생성할 수 없습니다"
        else -> "创建支付失败"
    }

    fun mainCancelRenewalSuccess(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "已取消自動續費，套餐到期後不再自動扣費。"
        MobileLanguage.YUE -> "已取消自動續費，套餐到期之後唔會再自動扣費。"
        MobileLanguage.EN -> "Auto-renewal cancelled. You won't be charged after the current period ends."
        MobileLanguage.RU -> "Автопродление отключено. После окончания периода списаний не будет."
        MobileLanguage.KO -> "자동 갱신이 해지되었습니다. 이용 기간 종료 후 더 이상 결제되지 않습니다."
        else -> "已取消自动续费，套餐到期后不再自动扣费。"
    }

    fun mainCancelRenewalFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "取消自動續費失敗"
        MobileLanguage.EN -> "Could not cancel auto-renewal"
        MobileLanguage.RU -> "Не удалось отключить автопродление"
        MobileLanguage.KO -> "자동 갱신을 해지할 수 없습니다"
        else -> "取消自动续费失败"
    }

    fun mainRenewalManagedExternally(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT -> "自動續費已開啟，可在訂閱裝置的應用商店中管理。"
        MobileLanguage.YUE -> "自動續費已開啟，可以喺訂閱嗰部裝置嘅應用商店入面管理。"
        MobileLanguage.EN -> "Auto-renewal is on. Manage it in the app store on the device where you subscribed."
        MobileLanguage.RU -> "Автопродление включено. Управляйте им в магазине приложений на устройстве, где оформлена подписка."
        MobileLanguage.KO -> "자동 갱신이 켜져 있습니다. 구독한 기기의 앱 스토어에서 관리하세요."
        else -> "自动续费已开启，可在订阅设备的应用商店中管理。"
    }

    fun mainLoadHotWordsFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "載入熱詞失敗"
        MobileLanguage.EN -> "Could not load words"
        MobileLanguage.RU -> "Слова не загружены"
        MobileLanguage.KO -> "단어를 불러올 수 없습니다"
        else -> "加载热词失败"
    }

    fun mainSaveHotWordFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "儲存熱詞失敗"
        MobileLanguage.EN -> "Could not save word"
        MobileLanguage.RU -> "Слово не сохранено"
        MobileLanguage.KO -> "단어를 저장할 수 없습니다"
        else -> "保存热词失败"
    }

    fun mainDeleteHotWordFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "刪除熱詞失敗"
        MobileLanguage.EN -> "Could not delete word"
        MobileLanguage.RU -> "Слово не удалено"
        MobileLanguage.KO -> "단어를 삭제할 수 없습니다"
        else -> "删除热词失败"
    }

    fun mainLoadPersonasFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "載入人設失敗"
        MobileLanguage.EN -> "Could not load roles"
        MobileLanguage.RU -> "Роли не загружены"
        MobileLanguage.KO -> "페르소나를 불러올 수 없습니다"
        else -> "加载人设失败"
    }

    fun mainSavePersonaFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "儲存人設失敗"
        MobileLanguage.EN -> "Could not save role"
        MobileLanguage.RU -> "Роль не сохранена"
        MobileLanguage.KO -> "페르소나를 저장할 수 없습니다"
        else -> "保存人设失败"
    }

    fun mainActivatePersonaFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "切換人設失敗"
        MobileLanguage.EN -> "Could not switch role"
        MobileLanguage.RU -> "Роль не включена"
        MobileLanguage.KO -> "페르소나를 전환할 수 없습니다"
        else -> "切换人设失败"
    }

    fun mainDeletePersonaFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "刪除人設失敗"
        MobileLanguage.EN -> "Could not delete role"
        MobileLanguage.RU -> "Роль не удалена"
        MobileLanguage.KO -> "페르소나를 삭제할 수 없습니다"
        else -> "删除人设失败"
    }

    fun mainLoadInviteCodesFailed(context: Context): String = when (lang(context)) {
        MobileLanguage.ZH_HANT, MobileLanguage.YUE -> "載入邀請碼失敗"
        MobileLanguage.EN -> "Could not load invites"
        MobileLanguage.RU -> "Коды не загружены"
        MobileLanguage.KO -> "초대 코드를 불러올 수 없습니다"
        else -> "加载邀请码失败"
    }
}
