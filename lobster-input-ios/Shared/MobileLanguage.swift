import Combine
import Foundation

enum MobileLanguage: String, CaseIterable, Identifiable {
    case zh
    case zhHant = "zh-Hant"
    case yue
    case en
    case ru
    case ko

    var id: String { rawValue }
    var label: String {
        switch self {
        case .zh: return "简体中文"
        case .zhHant: return "繁體中文"
        case .yue: return "粵語（廣東省版）"
        case .en: return "English"
        case .ru: return "Русский"
        case .ko: return "한국어"
        }
    }
}

@MainActor
final class MobileLanguageStore: ObservableObject {
    static let shared = MobileLanguageStore()

    @Published var language: MobileLanguage {
        didSet { MobileStrings.language = language }
    }

    private init() {
        language = MobileStrings.language
    }
}

enum MobileStrings {
    private static let key = "app_language"
    private static let defaults = UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard

    static var language: MobileLanguage {
        get { MobileLanguage(rawValue: defaults.string(forKey: key) ?? "zh") ?? .zh }
        set {
            defaults.set(newValue.rawValue, forKey: key)
            defaults.synchronize()
        }
    }

    static func text(
        zh: String,
        en: String,
        ru: String,
        ko: String,
        zhHant: String? = nil,
        yue: String? = nil
    ) -> String {
        switch language {
        case .en: return en
        case .ru: return ru
        case .ko: return ko
        case .zhHant: return zhHant ?? zh
        case .yue: return yue ?? zh
        default: return zh
        }
    }

    static func keyboardTitle() -> String {
        text(zh: "龙虾输入法", en: "Lobster Input", ru: "Лобстер Ввод", ko: "랍스터 입력기")
    }

    /// 将套餐 code（tier / plan_code）映射为本地化的套餐显示名。
    static func planName(_ code: String) -> String {
        switch code {
        case "trial":
            return text(zh: "免费试用", en: "Free Trial", ru: "Пробный", ko: "무료 체험", zhHant: "免費試用", yue: "免費試用")
        case "free":
            return text(zh: "免费版", en: "Free", ru: "Бесплатный", ko: "무료", zhHant: "免費版", yue: "免費版")
        case "weekly":
            return text(zh: "周套餐", en: "Weekly", ru: "Недельный", ko: "주간", zhHant: "週套餐", yue: "週套餐")
        case "monthly":
            return text(zh: "月套餐", en: "Monthly", ru: "Месячный", ko: "월간", zhHant: "月套餐", yue: "月套餐")
        case "yearly":
            return text(zh: "年套餐", en: "Yearly", ru: "Годовой", ko: "연간", zhHant: "年套餐", yue: "年套餐")
        case "lite":
            return text(zh: "轻量套餐", en: "Lite", ru: "Лайт", ko: "라이트", zhHant: "輕量套餐", yue: "輕量套餐")
        case "standard":
            return text(zh: "标准套餐", en: "Standard", ru: "Стандарт", ko: "스탠다드", zhHant: "標準套餐", yue: "標準套餐")
        case "pro":
            return text(zh: "专业套餐", en: "Pro", ru: "Про", ko: "프로", zhHant: "專業套餐", yue: "專業套餐")
        case "none", "":
            return text(zh: "无套餐", en: "No Plan", ru: "Нет тарифа", ko: "요금제 없음", zhHant: "無套餐", yue: "無套餐")
        default:
            return code.uppercased()
        }
    }

    /// 打字键盘:返回语音输入入口文案(国际化)。
    static func returnVoice() -> String {
        text(zh: "返回语音", en: "Voice", ru: "Голос", ko: "음성")
    }

    /// 打字键盘:空格键文案(国际化)。
    static func spaceKey() -> String {
        text(zh: "空格", en: "space", ru: "пробел", ko: "스페이스")
    }

    /// 打字键盘:中文输入标识(行业惯例,走国际化通道便于后续调整)。
    static func imeChineseLabel() -> String {
        text(zh: "中", en: "中", ru: "中", ko: "中")
    }

    /// 打字键盘:英文输入标识。
    static func imeEnglishLabel() -> String {
        text(zh: "EN", en: "EN", ru: "EN", ko: "EN")
    }

    /// 语音面板:切换到打字键盘的模式按钮文案。
    static func keyboardModeLabel() -> String {
        text(zh: "键盘", en: "Keyboard", ru: "Клавиатура", ko: "키보드")
    }

    /// 键盘布局:九宫格。
    static func nineGridLabel() -> String {
        text(zh: "九宫格", en: "9-key", ru: "9-кл.", ko: "9키")
    }

    /// 键盘布局:26 键。
    static func qwertyLabel() -> String {
        text(zh: "26键", en: "QWERTY", ru: "QWERTY", ko: "26키")
    }

    static func symbolKeyLabel() -> String {
        text(zh: "符", en: "?123", ru: "Симв", ko: "기호")
    }

    static func switchQwertyLabel() -> String {
        text(zh: "切26", en: "QWERTY", ru: "26", ko: "26키")
    }

    static func pinyinKeyLabel() -> String {
        text(zh: "拼", en: "拼", ru: "拼", ko: "拼")
    }

    static func abcKeyLabel() -> String {
        text(zh: "ABC", en: "ABC", ru: "ABC", ko: "ABC")
    }

    static func syllableSepKey() -> String {
        text(zh: "分词", en: "'", ru: "'", ko: "'")
    }

    static func pinyinDictLoading() -> String {
        text(zh: "词库加载中...", en: "Loading dictionary...", ru: "Загрузка словаря...", ko: "사전 로딩 중...")
    }

    static func pinyinDictFailed() -> String {
        text(zh: "词库加载失败", en: "Dictionary failed to load", ru: "Не удалось загрузить словарь", ko: "사전 로딩 실패")
    }

    static func typingUndone() -> String {
        text(zh: "已撤销上屏", en: "Last input undone", ru: "Последний ввод отменён", ko: "마지막 입력 취소됨")
    }

    static func keyboardMicFailed() -> String {
        text(zh: "键盘麦克风失败", en: "Keyboard mic failed", ru: "Ошибка микрофона", ko: "키보드 마이크 실패")
    }

    static func enterSearch() -> String {
        text(zh: "搜索", en: "Search", ru: "Поиск", ko: "검색")
    }

    static func enterSend() -> String {
        text(zh: "发送", en: "Send", ru: "Отпр.", ko: "전송")
    }

    static func enterGo() -> String {
        text(zh: "前往", en: "Go", ru: "Перейти", ko: "이동")
    }

    static func enterDone() -> String {
        text(zh: "完成", en: "Done", ru: "Готово", ko: "완료")
    }

    static func enterNext() -> String {
        text(zh: "下一项", en: "Next", ru: "Далее", ko: "다음")
    }

    static func enterPrevious() -> String {
        text(zh: "上一项", en: "Previous", ru: "Назад", ko: "이전")
    }

    static func enterNewline() -> String {
        text(zh: "换行", en: "Return", ru: "Ввод", ko: "줄바꿈")
    }

    static func a11yKeyLetter(_ ch: String) -> String {
        text(zh: "字母 \(ch)", en: "Letter \(ch)", ru: "Буква \(ch)", ko: "글자 \(ch)")
    }

    static func a11yKeyT9(main: String, sub: String) -> String {
        text(zh: "九宫格 \(main) 数字 \(sub)", en: "Key \(main), digit \(sub)", ru: "Клавиша \(main), цифра \(sub)", ko: "키 \(main), 숫자 \(sub)")
    }

    static func a11yKeyDelete() -> String {
        text(zh: "删除", en: "Delete", ru: "Удалить", ko: "삭제")
    }

    static func a11yKeySpace() -> String {
        text(zh: "空格", en: "Space", ru: "Пробел", ko: "스페이스")
    }

    static func a11yKeyEnter() -> String {
        text(zh: "回车", en: "Return", ru: "Ввод", ko: "리턴")
    }

    static func a11yKeyShift() -> String {
        text(zh: "Shift", en: "Shift", ru: "Shift", ko: "Shift")
    }

    static func a11yKeyShiftOn() -> String {
        text(zh: "Shift 已开启", en: "Shift on", ru: "Shift вкл.", ko: "Shift 켬")
    }

    static func a11yKeyCapsLock() -> String {
        text(zh: "大写锁定", en: "Caps lock", ru: "Caps Lock", ko: "Caps Lock")
    }

    static func a11yKeyLang() -> String {
        text(zh: "切换语言", en: "Switch language", ru: "Сменить язык", ko: "언어 전환")
    }

    static func a11yKeyLayout() -> String {
        text(zh: "切换布局", en: "Switch layout", ru: "Сменить раскладку", ko: "레이아웃 전환")
    }

    static func a11yKeySymbols() -> String {
        text(zh: "符号与数字", en: "Symbols and numbers", ru: "Символы и цифры", ko: "기호 및 숫자")
    }

    static func a11yKeyAlpha() -> String {
        text(zh: "返回字母", en: "Back to letters", ru: "К буквам", ko: "문자로")
    }

    static func a11yKeySymPage() -> String {
        text(zh: "符号翻页", en: "Symbol page", ru: "Страница символов", ko: "기호 페이지")
    }

    static func a11yKeyChar(_ ch: String) -> String {
        text(zh: "字符 \(ch)", en: "Character \(ch)", ru: "Символ \(ch)", ko: "문자 \(ch)")
    }

    static func a11yKeyMic() -> String {
        text(zh: "键盘麦克风", en: "Keyboard microphone", ru: "Микрофон клавиатуры", ko: "키보드 마이크")
    }

    static func tapToSpeak() -> String {
        switch language {
        case .en: return "Tap to speak"
        case .ru: return "Нажмите и говорите"
        case .ko: return "탭하여 말하기"
        default: return "点击说话"
        }
    }

    static func holdToSpeak() -> String {
        switch language {
        case .en: return "Hold to speak"
        case .ru: return "Удерживайте и говорите"
        case .ko: return "길게 눌러 말하기"
        default: return "长按说话"
        }
    }

    static func releaseToSend() -> String {
        switch language {
        case .en: return "Release to send"
        case .ru: return "Отпустите для отправки"
        case .ko: return "손을 떼면 전송"
        default: return "松开发送"
        }
    }

    static func realtimeConnecting() -> String {
        text(zh: "正在连接实时识别...", en: "Connecting realtime ASR...", ru: "Подключаем распознавание...", ko: "실시간 인식 연결 중...")
    }

    static func realtimeFinishing() -> String {
        text(zh: "正在处理实时识别...", en: "Processing realtime ASR...", ru: "Обрабатываем распознавание...", ko: "실시간 인식 처리 중...")
    }

    static func tapAgain(_ rewrite: Bool) -> String {
        switch language {
        case .en: return "Tap again to finish"
        case .ru: return "Нажмите еще раз"
        case .ko: return "다시 탭해 완료"
        default: return "再次点击以完成"
        }
    }

    static func processing(_ rewrite: Bool) -> String {
        switch language {
        case .en: return rewrite ? "Processing command..." : "Recognizing voice..."
        case .ru: return rewrite ? "Обработка команды..." : "Распознавание голоса..."
        case .ko: return rewrite ? "명령 처리 중..." : "음성 인식 중..."
        default: return rewrite ? "正在处理指令..." : "正在识别语音..."
        }
    }

    static func inserted() -> String {
        switch language {
        case .en: return "Inserted. Use Command to edit or continue."
        case .ru: return "Вставлено. Командой можно исправить или продолжить."
        case .ko: return "입력됨. 명령으로 수정하거나 이어갈 수 있습니다."
        default: return "已填入，可用指令修改或继续生成"
        }
    }

    static func loginRequired() -> String {
        switch language {
        case .en: return "Please sign in from the Lobster app"
        case .ru: return "Войдите в приложении Lobster"
        case .ko: return "랍스터 앱에서 로그인하세요"
        default: return "请在龙虾输入法 App 中登录"
        }
    }

    static func settingsTitle() -> String {
        switch language {
        case .en: return "Settings"
        case .ru: return "Настройки"
        case .ko: return "설정"
        default: return "设置"
        }
    }

    static func languageTitle() -> String {
        switch language {
        case .en: return "Language"
        case .ru: return "Язык"
        case .ko: return "언어"
        default: return "语言"
        }
    }

    static func languageHint() -> String {
        switch language {
        case .en: return "The app settings and voice keyboard panel will use this language."
        case .ru: return "Настройки приложения и панель ввода используют этот язык."
        case .ko: return "앱 설정과 음성 입력 패널이 이 언어를 사용합니다."
        default: return "切换后，App 设置页和语音输入法面板都会使用该语言。"
        }
    }

    static func newline() -> String {
        text(zh: "换行", en: "New line", ru: "Новая строка", ko: "줄바꿈")
    }

    static func rewrite() -> String {
        text(zh: "指令", en: "Command", ru: "Команда", ko: "명령")
    }

    static func symbols() -> String {
        text(zh: "符号", en: "Symbols", ru: "Символы", ko: "기호")
    }

    static func back() -> String {
        text(
            zh: "返回",
            en: "Back",
            ru: "Назад",
            ko: "뒤로",
            zhHant: "返回",
            yue: "返回"
        )
    }

    static func fastMode() -> String {
        text(zh: "极速", en: "Fast", ru: "Быстро", ko: "빠름")
    }

    /// 开关状态后缀(极速按钮等):开。
    static func stateOn() -> String {
        text(zh: "开", en: "ON", ru: "ВКЛ", ko: "켬", zhHant: "開", yue: "開")
    }

    /// 开关状态后缀(极速按钮等):关。
    static func stateOff() -> String {
        text(zh: "关", en: "OFF", ru: "ВЫКЛ", ko: "끔", zhHant: "關", yue: "關")
    }

    static func chineseSymbols() -> String {
        text(zh: "中文", en: "CN", ru: "Кит", ko: "중")
    }

    static func englishSymbols() -> String {
        text(zh: "英文", en: "EN", ru: "Анг", ko: "영")
    }

    static func rewriteHint() -> String {
        switch language {
        case .en: return "Select text, reuse the last insert, or speak a new command"
        case .ru: return "Выделите текст, исправьте последний ввод или продиктуйте команду"
        case .ko: return "텍스트 선택, 최근 입력 수정 또는 새 명령 말하기"
        default: return "选中文本、处理刚才输入，或直接说新指令"
        }
    }

    static func remainingSeconds(_ seconds: Int) -> String {
        switch language {
        case .en: return "\(seconds)s left"
        case .ru: return "Осталось \(seconds)с"
        case .ko: return "\(seconds)초 남음"
        default: return "剩余 \(seconds) 秒"
        }
    }

    static func recordingCountdown(_ remainingSec: Int) -> String {
        let minutes = max(0, remainingSec) / 60
        let seconds = max(0, remainingSec) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func tapAgainRecording(_ isRewrite: Bool) -> String {
        switch language {
        case .en: return isRewrite ? "Tap to finish rewrite" : "Tap to finish"
        case .ru: return isRewrite ? "Нажмите, чтобы завершить" : "Нажмите, чтобы остановить"
        case .ko: return isRewrite ? "탭하여 수정 완료" : "탭하여 종료"
        default: return isRewrite ? "点击完成改写" : "点击结束录音"
        }
    }

    static func rewritten() -> String {
        text(zh: "已完成", en: "Done", ru: "Готово", ko: "완료")
    }

    static func sessionExpired() -> String {
        switch language {
        case .en: return "Session expired. Sign in again from the Lobster app."
        case .ru: return "Сессия истекла. Войдите снова в приложении Lobster."
        case .ko: return "로그인이 만료되었습니다. 랍스터 앱에서 다시 로그인하세요."
        default: return "登录已过期，请在龙虾输入法 App 中重新登录"
        }
    }

    static func creditsExhausted() -> String {
        text(zh: "积分已用完", en: "Credits exhausted", ru: "Кредиты закончились", ko: "크레딧이 부족합니다")
    }

    static func checkingAccount() -> String {
        text(zh: "正在检查账户...", en: "Checking account...", ru: "Проверяем аккаунт...", ko: "계정 확인 중...")
    }

    static func inputUnavailableTitle(creditsExhausted: Bool) -> String {
        switch language {
        case .en: return creditsExhausted ? "Credits exhausted" : "Sign in required"
        case .ru: return creditsExhausted ? "Кредиты закончились" : "Нужен вход"
        case .ko: return creditsExhausted ? "크레딧 부족" : "로그인 필요"
        default: return creditsExhausted ? "积分已用完" : "需要登录"
        }
    }

    static func inputUnavailableBody(creditsExhausted: Bool) -> String {
        switch language {
        case .en:
            return creditsExhausted
                ? "Voice input is unavailable right now. Switch keyboards to keep typing, or open the Lobster app to check credits."
                : "Voice input is unavailable before sign-in. Switch keyboards to keep typing, or open the Lobster app to sign in."
        case .ru:
            return creditsExhausted
                ? "Голосовой ввод сейчас недоступен. Переключите клавиатуру или откройте Lobster для проверки кредитов."
                : "До входа голосовой ввод недоступен. Переключите клавиатуру или откройте Lobster для входа."
        case .ko:
            return creditsExhausted
                ? "지금은 음성 입력을 사용할 수 없습니다. 다른 키보드로 전환하거나 랍스터 앱에서 크레딧을 확인하세요."
                : "로그인 전에는 음성 입력을 사용할 수 없습니다. 다른 키보드로 전환하거나 랍스터 앱에서 로그인하세요."
        default:
            return creditsExhausted
                ? "当前无法语音输入。可先切换到其它输入法继续输入，或打开 App 查看积分。"
                : "登录前无法语音输入。可先切换到其它输入法继续输入，或打开 App 登录。"
        }
    }

    static func switchKeyboard() -> String {
        text(zh: "切换", en: "Keyboard", ru: "Клав.", ko: "키보드")
    }

    static func openApp() -> String {
        text(zh: "打开 App", en: "Open app", ru: "Открыть", ko: "앱 열기")
    }

    static func micPermission() -> String {
        text(zh: "需要录音权限", en: "Microphone permission required", ru: "Нужен доступ к микрофону", ko: "마이크 권한이 필요합니다")
    }

    static func fullAccessTitle() -> String {
        text(
            zh: "允许完全访问",
            en: "Allow Full Access",
            ru: "Разрешите полный доступ",
            ko: "전체 접근 허용",
            zhHant: "允許完整取用",
            yue: "允許完整取用"
        )
    }

    static func fullAccessBody() -> String {
        text(
            zh: "请在系统设置中开启键盘“允许完全访问”，否则无法联网转写或读取登录状态。",
            en: "Turn on Allow Full Access for this keyboard in Settings, otherwise it cannot transcribe online or read your sign-in state.",
            ru: "В настройках включите полный доступ для клавиатуры, иначе она не сможет распознавать онлайн и читать вход.",
            ko: "설정에서 이 키보드의 전체 접근을 허용해야 온라인 전사와 로그인 상태 확인이 가능합니다.",
            zhHant: "請在系統設定中開啟鍵盤「允許完整取用」，否則無法連線轉寫或讀取登入狀態。",
            yue: "請喺系統設定開啟鍵盤「允許完整取用」，否則無法連線轉寫或者讀取登入狀態。"
        )
    }

    static func undo() -> String {
        text(zh: "撤回", en: "Undo", ru: "Отмена", ko: "취소")
    }

    static func restoreVoice() -> String {
        text(zh: "还原", en: "Restore", ru: "Вернуть", ko: "복원")
    }

    static func restoredVoice() -> String {
        text(zh: "已还原", en: "Restored", ru: "Восстановлено", ko: "복원됨")
    }

    static func leftHand() -> String {
        text(zh: "左手", en: "Left", ru: "Лев", ko: "왼손")
    }

    static func rightHand() -> String {
        text(zh: "右手", en: "Right", ru: "Прав", ko: "오른손")
    }

    static func recordingStartFailed() -> String {
        text(zh: "录音启动失败", en: "Could not start recording", ru: "Не удалось начать запись", ko: "녹음을 시작할 수 없습니다")
    }

    static func recordingUnavailable() -> String {
        text(
            zh: "录音暂时无法启动，请重新切换输入法或关闭占用麦克风的 App 后重试",
            en: "Recording cannot start. Switch keyboards again or close apps using the microphone, then retry.",
            ru: "Запись не запускается. Переключите клавиатуру или закройте приложения с микрофоном и повторите.",
            ko: "녹음을 시작할 수 없습니다. 키보드를 다시 전환하거나 마이크를 사용하는 앱을 닫고 다시 시도하세요.",
            zhHant: "錄音暫時無法啟動，請重新切換輸入法或關閉佔用麥克風的 App 後重試",
            yue: "錄音暫時啟動唔到，請重新切換輸入法或者關閉佔用咪高峰嘅 App 後再試"
        )
    }

    static func voiceSessionNotReady() -> String {
        text(
            zh: "键盘录音未就绪。请打开龙虾输入法 App 并保持在前台几秒，然后返回继续；无需跳转录音界面。",
            en: "Keyboard recording is not ready. Open the Lobster Input app, keep it in the foreground for a few seconds, then return. No recording screen is required.",
            ru: "Запись с клавиатуры не готова. Откройте приложение Lobster Input, подержите его на переднем плане несколько секунд и вернитесь.",
            ko: "키보드 녹음이 준비되지 않았습니다. Lobster Input 앱을 열어 몇 초간 전면에 두었다가 돌아오세요.",
            zhHant: "鍵盤錄音未就緒。請開啟龍蝦輸入法 App 並保持在前台數秒後返回；無需跳轉錄音介面。",
            yue: "鍵盤錄音未就緒。請打開龍蝦輸入法 App 並保持喺前台幾秒，然後返回；唔使跳去錄音畫面。"
        )
    }

    static func voiceSessionWakeAppHint() -> String {
        text(
            zh: "正在唤起龙虾输入法…\n请稍候或手动打开 App 后返回",
            en: "Launching Lobster Input…\nOpen the app manually if needed, then return here.",
            ru: "Запуск Lobster Input…\nПри необходимости откройте приложение и вернитесь.",
            ko: "Lobster Input 실행 중…\n필요하면 앱을 연 뒤 키보드로 돌아오세요.",
            zhHant: "正在喚起龍蝦輸入法…\n請稍候或手動開啟 App 後返回",
            yue: "正在喚起龍蝦輸入法…\n請稍候或者手動打開 App 之後返嚟"
        )
    }

    static func voiceSessionConnecting() -> String {
        text(
            zh: "正在连接麦克风服务…",
            en: "Connecting microphone service…",
            ru: "Подключение микрофона…",
            ko: "마이크 서비스 연결 중…",
            zhHant: "正在連接麥克風服務…",
            yue: "正在連接咪高峰服務…"
        )
    }

    static func voiceSessionReadyBadge() -> String {
        text(
            zh: "麦克风已就绪",
            en: "Mic ready",
            ru: "Микрофон готов",
            ko: "마이크 준비됨",
            zhHant: "麥克風已就緒",
            yue: "咪高峰已就緒"
        )
    }

    static func voiceSessionNeedsAppBadge() -> String {
        text(
            zh: "需打开 App 激活",
            en: "Open app to activate",
            ru: "Откройте приложение",
            ko: "앱에서 활성화",
            zhHant: "需開啟 App 啟用",
            yue: "要打開 App 啟動"
        )
    }

    static func voiceSessionRecording() -> String {
        text(
            zh: "正在通过后台麦克风录音…",
            en: "Recording via background microphone…",
            ru: "Запись через фоновый микрофон…",
            ko: "백그라운드 마이크로 녹음 중…",
            zhHant: "正在透過背景麥克風錄音…",
            yue: "正透過後台咪高峰錄音…"
        )
    }

    static func keyboardHandoffStarting() -> String {
        text(
            zh: "正在录音",
            en: "Recording",
            ru: "Запись",
            ko: "녹음 중"
        )
    }

    static func keyboardHandoffReady() -> String {
        text(
            zh: "已从 App 带回结果",
            en: "Result returned from app",
            ru: "Результат получен из приложения",
            ko: "앱 결과를 가져왔습니다"
        )
    }

    static func appKeyboardRequestTitle() -> String {
        text(
            zh: "来自键盘的语音输入",
            en: "Voice input from keyboard",
            ru: "Голосовой ввод с клавиатуры",
            ko: "키보드 음성 입력"
        )
    }

    static func appKeyboardRequestHint() -> String {
        text(
            zh: "录音和识别完成后，返回刚才的 App，龙虾键盘会自动插入结果。",
            en: "After recognition finishes, return to the previous app and Lobster will insert the result.",
            ru: "После распознавания вернитесь в предыдущее приложение, и Lobster вставит результат.",
            ko: "인식이 끝나면 이전 앱으로 돌아가세요. 랍스터가 결과를 입력합니다."
        )
    }

    static func quickFormat() -> String {
        text(zh: "格式化", en: "Fmt", ru: "Форм.", ko: "정리")
    }

    static func quickPolish() -> String {
        text(zh: "润色", en: "Polish", ru: "Стиль", ko: "다듬기")
    }

    static func quickConcise() -> String {
        text(zh: "精简", en: "Short", ru: "Кратко", ko: "줄이기")
    }

    static func clearInput() -> String {
        text(zh: "清空", en: "Clear", ru: "Очист.", ko: "지우기", zhHant: "清空", yue: "清空")
    }

    static func inputCleared() -> String {
        text(zh: "已清空", en: "Cleared", ru: "Очищено", ko: "지웠어요", zhHant: "已清空", yue: "已清空")
    }

    static func quickBullets() -> String {
        text(zh: "要点", en: "List", ru: "Список", ko: "요점")
    }

    static func quickProcessing() -> String {
        text(zh: "正在处理文本...", en: "Processing text...", ru: "Обработка текста...", ko: "텍스트 처리 중...")
    }

    static func noRewriteTarget() -> String {
        switch language {
        case .en: return "Speak a command to generate text or edit selected text"
        case .ru: return "Продиктуйте команду для создания или правки текста"
        case .ko: return "명령을 말해 새 텍스트를 만들거나 선택 텍스트를 수정하세요"
        default: return "说出指令，可生成新文本或修改选中文本"
        }
    }

    static func commandHint() -> String {
        switch language {
        case .en: return "Command can edit selected text or create new text"
        case .ru: return "Команда: правка выделенного или новый текст"
        case .ko: return "명령: 선택 수정 또는 새 텍스트"
        default: return "指令可修改选区，也可直接生成"
        }
    }

    static func emptyRewrite() -> String {
        text(zh: "处理结果为空", en: "Result is empty", ru: "Результат пуст", ko: "결과가 비었습니다")
    }

    static func emptyTranscribe() -> String {
        text(zh: "没有识别到可输入内容", en: "No text recognized", ru: "Текст не распознан", ko: "인식된 텍스트가 없습니다")
    }

    static func emptyResponse() -> String {
        text(zh: "响应为空", en: "Empty response", ru: "Пустой ответ", ko: "빈 응답")
    }

    static func requestFailed(_ statusCode: Int) -> String {
        switch language {
        case .en: return "Request failed (\(statusCode))"
        case .ru: return "Запрос не удался (\(statusCode))"
        case .ko: return "요청 실패 (\(statusCode))"
        default: return "请求失败(\(statusCode))"
        }
    }

    static func processFailed() -> String {
        text(zh: "处理失败", en: "Processing failed", ru: "Обработка не удалась", ko: "처리 실패")
    }

    static func accountCheckFailed(_ statusCode: Int? = nil) -> String {
        switch language {
        case .en: return "Account check failed" + statusCode.map { " (\($0))" }.orEmpty
        case .ru: return "Проверка аккаунта не удалась" + statusCode.map { " (\($0))" }.orEmpty
        case .ko: return "계정 확인 실패" + statusCode.map { " (\($0))" }.orEmpty
        default: return "账户状态检查失败" + statusCode.map { "(\($0))" }.orEmpty
        }
    }

    static func processingShort() -> String {
        text(zh: "处理中...", en: "Work...", ru: "Ждем...", ko: "처리 중...")
    }

    static func persona() -> String {
        switch language {
        case .en: return "Role"
        case .ru: return "Роль"
        case .ko: return "페르소나"
        case .zhHant, .yue: return "人設"
        default: return "人设"
        }
    }

    static func personaHint() -> String {
        switch language {
        case .en: return "Choose style for dictation and commands"
        case .ru: return "Стиль для диктовки и команд"
        case .ko: return "음성 입력과 명령 결과에 사용할 페르소나 선택"
        case .zhHant: return "選擇語音輸入與指令處理風格"
        case .yue: return "揀語音輸入同指令處理風格"
        default: return "选择语音输入与指令处理风格"
        }
    }

    static func personaEmpty() -> String {
        switch language {
        case .en: return "No personas yet"
        case .ru: return "Персон пока нет"
        case .ko: return "페르소나 없음"
        case .zhHant, .yue: return "暫無人設"
        default: return "暂无人设"
        }
    }

    static func active() -> String {
        switch language {
        case .en: return "Active"
        case .ru: return "Активно"
        case .ko: return "활성"
        case .zhHant, .yue: return "已啟用"
        default: return "已启用"
        }
    }

    static func inactive() -> String {
        switch language {
        case .en: return "Inactive"
        case .ru: return "Неактивно"
        case .ko: return "비활성"
        case .zhHant, .yue: return "未啟用"
        default: return "未启用"
        }
    }

    static func enable() -> String {
        switch language {
        case .en: return "On"
        case .ru: return "Вкл"
        case .ko: return "켜기"
        case .zhHant, .yue: return "啟用"
        default: return "启用"
        }
    }

    static func disable() -> String {
        switch language {
        case .en: return "Off"
        case .ru: return "Выкл"
        case .ko: return "끄기"
        case .zhHant, .yue: return "停用"
        default: return "停用"
        }
    }

    static func refresh() -> String {
        switch language {
        case .en: return "Reload"
        case .ru: return "Обн."
        case .ko: return "새로고침"
        case .zhHant, .yue: return "刷新"
        default: return "刷新"
        }
    }

    static func personaTranscribe() -> String {
        switch language {
        case .en: return "Voice"
        case .ru: return "Голос"
        case .ko: return "음성 입력"
        case .zhHant, .yue: return "語音輸入"
        default: return "语音输入"
        }
    }

    static func personaRewrite() -> String {
        switch language {
        case .en: return "Command"
        case .ru: return "Команда"
        case .ko: return "명령"
        case .zhHant, .yue: return "指令"
        default: return "指令"
        }
    }

    static func personaModuleHint() -> String {
        switch language {
        case .en: return "Toggle modules for this role"
        case .ru: return "Модули этой роли"
        case .ko: return "음성 입력과 명령에 사용할 페르소나를 켜세요"
        case .zhHant: return "啟用後作用於語音輸入和指令處理"
        case .yue: return "啟用後會用喺語音輸入同指令處理"
        default: return "启用后作用于语音输入和指令处理"
        }
    }

    static func builtin() -> String {
        switch language {
        case .en: return "Built-in"
        case .ru: return "База"
        case .ko: return "기본"
        case .zhHant, .yue: return "預設"
        default: return "默认"
        }
    }

    static func custom() -> String {
        switch language {
        case .en: return "Custom"
        case .ru: return "Своя"
        case .ko: return "사용자"
        case .zhHant, .yue: return "自訂"
        default: return "自定义"
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
