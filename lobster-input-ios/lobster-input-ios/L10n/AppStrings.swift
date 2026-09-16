import Foundation

enum L10n {
    private static func t(
        _ zh: String,
        _ en: String,
        _ ru: String,
        _ ko: String,
        zhHant: String? = nil,
        yue: String? = nil
    ) -> String {
        MobileStrings.text(zh: zh, en: en, ru: ru, ko: ko, zhHant: zhHant, yue: yue)
    }

    static var appName: String { t("龙虾输入法", "Lobster Input", "Лобстер Ввод", "랍스터 입력기", zhHant: "龍蝦輸入法", yue: "龍蝦輸入法") }
    static var appNameFull: String { t("龙虾输入法 iOS", "Lobster Input iOS", "Лобстер Ввод iOS", "랍스터 입력기 iOS", zhHant: "龍蝦輸入法 iOS", yue: "龍蝦輸入法 iOS") }
    static var appTagline: String { t("AI 语音输入法", "AI voice keyboard", "AI голосовая клавиатура", "AI 음성 입력기", zhHant: "AI 語音輸入法", yue: "AI 語音輸入法") }

    // Auth
    static var authTitle: String { t("登录 / 注册", "Sign in / Register", "Вход / Регистрация", "로그인 / 가입", zhHant: "登入 / 註冊", yue: "登入 / 註冊") }
    static var authEmailPlaceholder: String { t("请输入邮箱地址", "Email address", "Введите email", "이메일 주소", zhHant: "請輸入電郵地址", yue: "請輸入電郵地址") }
    static var authCodePlaceholder: String { t("请输入验证码", "Verification code", "Код подтверждения", "인증 코드", zhHant: "請輸入驗證碼", yue: "請輸入驗證碼") }
    static var authSendCode: String { t("发送验证码", "Send code", "Отправить код", "코드 보내기", zhHant: "發送驗證碼", yue: "發送驗證碼") }
    static var authLogin: String { t("登录", "Sign in", "Войти", "로그인", zhHant: "登入", yue: "登入") }
    static var authCodeSent: String { t("验证码已发送", "Code sent", "Код отправлен", "코드를 보냈습니다", zhHant: "驗證碼已發送", yue: "驗證碼已發送") }
    static var authInviteTitle: String { t("输入邀请码", "Enter invite code", "Введите код приглашения", "초대 코드 입력", zhHant: "輸入邀請碼", yue: "輸入邀請碼") }
    static var authInvitePlaceholder: String { t("请输入邀请码", "Invite code", "Код приглашения", "초대 코드", zhHant: "請輸入邀請碼", yue: "請輸入邀請碼") }
    static var authInviteSubmit: String { t("提交", "Submit", "Отправить", "제출", zhHant: "提交", yue: "提交") }
    static var authAlertTitle: String { t("提示", "Notice", "Уведомление", "알림", zhHant: "提示", yue: "提示") }

    // Home
    static var homeTitle: String { t("语音输入", "Voice input", "Голосовой ввод", "음성 입력", zhHant: "語音輸入", yue: "語音輸入") }
    static var homeHoldToSpeak: String { t("按住说话", "Hold to speak", "Удерживайте и говорите", "길게 눌러 말하기", zhHant: "按住說話", yue: "撳住講嘢") }
    static var homeReleaseToStop: String { t("松开结束", "Release to stop", "Отпустите для остановки", "놓으면 종료", zhHant: "鬆開結束", yue: "放手結束") }
    static var homeRecording: String { t("录音中...", "Recording...", "Запись...", "녹음 중...", zhHant: "錄音中...", yue: "錄音中...") }
    static var homeRecognizing: String { t("识别中...", "Recognizing...", "Распознаем...", "인식 중...", zhHant: "識別中...", yue: "識別中...") }
    static var homeReady: String { t("准备就绪", "Ready", "Готово", "준비됨", zhHant: "準備就緒", yue: "準備好") }
    static var homeResultPlaceholder: String { t("转写结果将在这里显示", "Transcription results appear here", "Результат появится здесь", "전사 결과가 여기에 표시됩니다", zhHant: "轉寫結果會在這裡顯示", yue: "轉寫結果會喺呢度顯示") }
    static var homeRewrite: String { t("改写", "Rewrite", "Правка", "수정", zhHant: "改寫", yue: "改寫") }
    static var homeRewriteHint: String { t("对上方结果进行语音改写", "Rewrite the result above by voice", "Исправьте результат выше голосом", "위 결과를 음성으로 수정", zhHant: "對上方結果進行語音改寫", yue: "用語音改寫上面結果") }
    static var homeTranscript: String { t("原文", "Original", "Оригинал", "원문", zhHant: "原文", yue: "原文") }
    static var homeRecordStart: String { t("开始录音", "Start recording", "Начать запись", "녹음 시작", zhHant: "開始錄音", yue: "開始錄音") }
    static var homeRecordStop: String { t("停止录音", "Stop recording", "Остановить запись", "녹음 중지", zhHant: "停止錄音", yue: "停止錄音") }

    // Actions
    static var btnCopy: String { t("复制", "Copy", "Копировать", "복사", zhHant: "複製", yue: "複製") }
    static var btnCopied: String { t("已复制", "Copied", "Скопировано", "복사됨", zhHant: "已複製", yue: "已複製") }
    static var btnInsert: String { t("插入", "Insert", "Вставить", "삽입", zhHant: "插入", yue: "插入") }
    static var btnClear: String { t("清空", "Clear", "Очистить", "지우기", zhHant: "清空", yue: "清空") }
    static var btnRetry: String { t("重试", "Retry", "Повторить", "다시 시도", zhHant: "重試", yue: "重試") }
    static var btnCancel: String { t("取消", "Cancel", "Отмена", "취소", zhHant: "取消", yue: "取消") }
    static var btnDone: String { t("确定", "OK", "ОК", "확인", zhHant: "確定", yue: "確定") }
    static var btnSave: String { t("保存", "Save", "Сохранить", "저장", zhHant: "儲存", yue: "儲存") }
    static var btnDelete: String { t("删除", "Delete", "Удалить", "삭제", zhHant: "刪除", yue: "刪除") }
    static var btnEdit: String { t("编辑", "Edit", "Править", "편집", zhHant: "編輯", yue: "編輯") }
    static var btnAdd: String { t("添加", "Add", "Добавить", "추가", zhHant: "新增", yue: "新增") }
    static var btnNext: String { t("下一步", "Next", "Далее", "다음", zhHant: "下一步", yue: "下一步") }
    static var btnBack: String { t("返回", "Back", "Назад", "뒤로", zhHant: "返回", yue: "返回") }

    // Settings
    static var settingsTitle: String { MobileStrings.settingsTitle() }
    static var settingsAccount: String { t("账号", "Account", "Аккаунт", "계정", zhHant: "帳號", yue: "帳號") }
    static var settingsCredits: String { t("积分", "Credits", "Кредиты", "크레딧", zhHant: "積分", yue: "積分") }
    static var settingsLanguage: String { MobileStrings.languageTitle() }
    static var settingsKeyboard: String { t("键盘设置", "Keyboard setup", "Настройка клавиатуры", "키보드 설정", zhHant: "鍵盤設定", yue: "鍵盤設定") }
    static var settingsKeyboardGuide: String { t("前往系统设置开启龙虾键盘", "Open Settings to enable the Lobster keyboard", "Откройте настройки и включите Lobster", "설정에서 랍스터 키보드를 켜세요", zhHant: "前往系統設定開啟龍蝦鍵盤", yue: "去系統設定開啟龍蝦鍵盤") }
    static var settingsAbout: String { t("关于", "About", "О приложении", "정보", zhHant: "關於", yue: "關於") }
    static var settingsLogout: String { t("退出登录", "Sign out", "Выйти", "로그아웃", zhHant: "登出", yue: "登出") }
    static var settingsInviteCodes: String { t("我的邀请码", "My invite codes", "Мои коды", "내 초대 코드", zhHant: "我的邀請碼", yue: "我嘅邀請碼") }

    // Tabs
    static var tabHome: String { t("首页", "Home", "Главная", "홈", zhHant: "首頁", yue: "首頁") }
    static var tabHistory: String { t("历史", "History", "История", "기록", zhHant: "歷史", yue: "歷史") }
    static var tabPersona: String { MobileStrings.persona() }
    static var tabSettings: String { MobileStrings.settingsTitle() }

    // History
    static var historyTitle: String { t("历史记录", "History", "История", "기록", zhHant: "歷史記錄", yue: "歷史記錄") }
    static var historyEmpty: String { t("暂无历史记录", "No history yet", "Истории пока нет", "기록 없음", zhHant: "暫無歷史記錄", yue: "暫無歷史記錄") }
    static var historyEmptyDesc: String { t("使用输入法完成语音输入或指令处理后，记录会显示在这里。", "Voice input and command results will appear here.", "Результаты голосового ввода и команд появятся здесь.", "음성 입력과 명령 결과가 여기에 표시됩니다.", zhHant: "使用輸入法完成語音輸入或指令處理後，記錄會顯示在這裡。", yue: "使用輸入法完成語音輸入或者指令處理後，記錄會喺呢度顯示。") }
    static var historyClearAll: String { t("清空全部", "Clear all", "Очистить все", "전체 삭제", zhHant: "清空全部", yue: "清空全部") }
    static var historyOperationVoiceInput: String { t("语音输入", "Voice input", "Голосовой ввод", "음성 입력", zhHant: "語音輸入", yue: "語音輸入") }
    static var historyOperationCommand: String { t("指令", "Command", "Команда", "명령", zhHant: "指令", yue: "指令") }
    static var historyOperationQuickAction: String { t("快捷处理", "Quick action", "Быстро", "빠른 처리", zhHant: "快捷處理", yue: "快捷處理") }

    // Persona
    static var personaTitle: String { t("人设配置", "Persona setup", "Настройка персоны", "페르소나 설정", zhHant: "人設設定", yue: "人設設定") }
    static var personaEmpty: String { t("暂无人设", "No personas yet", "Персон пока нет", "페르소나 없음", zhHant: "暫無人設", yue: "暫無人設") }
    static var personaEmptyDesc: String { t("创建不同场景的语音输入和指令处理提示词，启用后会影响输入法输出效果。", "Create prompts for voice input and command output.", "Создайте подсказки для голосового ввода и команд.", "음성 입력과 명령 결과용 프롬프트를 만들 수 있습니다.", zhHant: "建立不同場景的語音輸入和指令處理提示詞，啟用後會影響輸入法輸出效果。", yue: "建立唔同場景嘅語音輸入同指令處理提示詞，啟用後會影響輸入法輸出效果。") }
    static var personaName: String { t("名称", "Name", "Имя", "이름", zhHant: "名稱", yue: "名稱") }
    static var personaDesc: String { t("描述（选填）", "Description (optional)", "Описание (необязательно)", "설명(선택)", zhHant: "描述（選填）", yue: "描述（選填）") }
    static var personaTranscribe: String { t("语音输入提示词", "Voice input prompt", "Промпт голосового ввода", "음성 입력 프롬프트", zhHant: "語音輸入提示詞", yue: "語音輸入提示詞") }
    static var personaRewrite: String { t("指令提示词", "Command prompt", "Промпт команды", "명령 프롬프트", zhHant: "指令提示詞", yue: "指令提示詞") }
    static var personaIntent: String { t("意图补充", "Intent hint", "Подсказка намерения", "의도 힌트", zhHant: "意圖補充", yue: "意圖補充") }
    static var personaActivate: String { t("启用", "Enable", "Включить", "켜기", zhHant: "啟用", yue: "啟用") }
    static var personaDeactivate: String { t("停用", "Disable", "Выключить", "끄기", zhHant: "停用", yue: "停用") }
    static var personaActive: String { t("使用中", "Active", "Активна", "사용 중", zhHant: "使用中", yue: "使用中") }
    static var personaBuiltin: String { MobileStrings.builtin() }
    static var personaCustom: String { MobileStrings.custom() }
    static var personaCreateTitle: String { t("新建人设", "New persona", "Новая персона", "새 페르소나", zhHant: "新增人設", yue: "新增人設") }
    static var personaEditTitle: String { t("编辑人设", "Edit persona", "Правка персоны", "페르소나 편집", zhHant: "編輯人設", yue: "編輯人設") }
    static var personaMobileHint: String { t("手机端仅管理语音输入和指令提示词。", "Mobile only edits voice input and command prompts.", "На телефоне редактируются только голосовой ввод и команды.", "모바일에서는 음성 입력과 명령 프롬프트만 수정합니다.", zhHant: "手機端僅管理語音輸入和指令提示詞。", yue: "手機端只管理語音輸入同指令提示詞。") }
    static var personaPrompt: String { t("提示词", "Prompt", "Промпт", "프롬프트", zhHant: "提示詞", yue: "提示詞") }
    static var personaNoPrompt: String { t("未配置提示词", "No prompt configured", "Промпт не задан", "프롬프트 없음", zhHant: "未設定提示詞", yue: "未設定提示詞") }

    // Dictionary
    static var dictTitle: String { t("热词词典", "Hotword dictionary", "Словарь слов", "핫워드 사전", zhHant: "熱詞詞典", yue: "熱詞詞典") }
    static var dictEmpty: String { t("暂无热词", "No hotwords yet", "Слов пока нет", "핫워드 없음", zhHant: "暫無熱詞", yue: "暫無熱詞") }
    static var dictPlaceholder: String { t("输入热词", "Enter a hotword", "Введите слово", "핫워드 입력", zhHant: "輸入熱詞", yue: "輸入熱詞") }

    // Errors
    static var errorNetwork: String { t("网络连接失败，请检查网络", "Network failed. Check your connection.", "Ошибка сети. Проверьте подключение.", "네트워크 연결을 확인하세요.", zhHant: "網絡連線失敗，請檢查網絡", yue: "網絡連線失敗，請檢查網絡") }
    static var errorUnauthorized: String { t("登录已过期，请重新登录", "Session expired. Sign in again.", "Сессия истекла. Войдите снова.", "로그인이 만료되었습니다. 다시 로그인하세요.", zhHant: "登入已過期，請重新登入", yue: "登入已過期，請重新登入") }
    static var errorCreditsExhausted: String { t("积分已用尽", "Credits exhausted", "Кредиты закончились", "크레딧이 부족합니다", zhHant: "積分已用盡", yue: "積分已用盡") }
    static var errorUnknown: String { t("未知错误", "Unknown error", "Неизвестная ошибка", "알 수 없는 오류", zhHant: "未知錯誤", yue: "未知錯誤") }
    static var errorInvalidAudio: String { t("音频文件无效", "Invalid audio file", "Некорректный аудиофайл", "유효하지 않은 오디오 파일", zhHant: "音訊檔無效", yue: "音訊檔無效") }
    static var errorMicPermission: String { t("请在设置中允许麦克风权限", "Allow microphone access in Settings", "Разрешите микрофон в настройках", "설정에서 마이크 권한을 허용하세요", zhHant: "請在設定中允許麥克風權限", yue: "請喺設定允許咪高峰權限") }
    static var errorFullAccess: String { t("请在系统设置中开启键盘\"完全访问\"权限", "Turn on Allow Full Access for the keyboard in Settings", "Включите полный доступ для клавиатуры", "설정에서 키보드 전체 접근을 허용하세요", zhHant: "請在系統設定中開啟鍵盤「完整取用」權限", yue: "請喺系統設定開啟鍵盤「完整取用」權限") }
    static var errorDecoding: String { t("数据解析失败", "Failed to parse data", "Не удалось разобрать данные", "데이터를 읽을 수 없습니다", zhHant: "資料解析失敗", yue: "資料解析失敗") }
    static var errorUserBanned: String { t("账号已被禁用", "Account disabled", "Аккаунт отключен", "계정이 비활성화되었습니다", zhHant: "帳號已被停用", yue: "帳號已被停用") }
    static var errorNotLoggedIn: String { t("请先登录", "Please sign in first", "Сначала войдите", "먼저 로그인하세요", zhHant: "請先登入", yue: "請先登入") }
    static var errorRegistrationDisabled: String { t("未开放注册", "Registration is not open", "Регистрация пока закрыта", "현재 가입이 열려 있지 않습니다", zhHant: "暫未開放註冊", yue: "暫未開放註冊") }

    static func errorForCode(_ code: String) -> String? {
        switch code {
        case "REGISTRATION_DISABLED": return errorRegistrationDisabled
        default: return nil
        }
    }

    // Onboarding
    static var onboardingWelcome: String { t("欢迎使用龙虾输入法", "Welcome to Lobster Input", "Добро пожаловать в Lobster", "랍스터 입력기에 오신 것을 환영합니다", zhHant: "歡迎使用龍蝦輸入法", yue: "歡迎使用龍蝦輸入法") }
    static var onboardingVoiceTitle: String { t("语音录入", "Voice capture", "Голосовой ввод", "음성 입력", zhHant: "語音錄入", yue: "語音錄入") }
    static var onboardingPolishTitle: String { t("AI 纠偏整理", "AI cleanup", "AI исправление", "AI 정리", zhHant: "AI 糾偏整理", yue: "AI 糾偏整理") }
    static var onboardingRewriteTitle: String { t("追加改写", "Rewrite follow-ups", "Доправка", "추가 수정", zhHant: "追加改寫", yue: "追加改寫") }
    static var onboardingStep1: String { t("按住按钮，对着手机说话", "Hold the button and speak to your phone", "Удерживайте кнопку и говорите", "버튼을 누른 채 말하세요", zhHant: "按住按鈕，對著手機說話", yue: "撳住按鈕，對住手機講嘢") }
    static var onboardingStep2: String { t("AI 自动纠偏整理，输出高质量文本", "AI cleans up speech into polished text", "AI очищает речь в качественный текст", "AI가 말한 내용을 정리합니다", zhHant: "AI 自動糾偏整理，輸出高品質文字", yue: "AI 自動糾偏整理，輸出高質文字") }
    static var onboardingStep3: String { t("支持追加改写，精准修改结果", "Use follow-up commands to edit precisely", "Исправляйте результат дополнительными командами", "추가 명령으로 결과를 수정하세요", zhHant: "支援追加改寫，精準修改結果", yue: "支援追加改寫，精準修改結果") }
    static var onboardingStart: String { t("开始使用", "Get started", "Начать", "시작하기", zhHant: "開始使用", yue: "開始使用") }

    // Keyboard
    static var kbSpeak: String { t("说话", "Speak", "Говорите", "말하기", zhHant: "說話", yue: "講嘢") }
    static var kbSpeaking: String { t("说话中...", "Speaking...", "Говорите...", "말하는 중...", zhHant: "說話中...", yue: "講緊...") }
    static var kbProcessing: String { t("识别中...", "Recognizing...", "Распознаем...", "인식 중...", zhHant: "識別中...", yue: "識別中...") }
    static var kbInsert: String { t("插入", "Insert", "Вставить", "삽입", zhHant: "插入", yue: "插入") }
    static var kbRewrite: String { t("改写", "Rewrite", "Правка", "수정", zhHant: "改寫", yue: "改寫") }
    static var kbNoLogin: String { t("请在龙虾输入法App中登录", "Sign in from the Lobster app", "Войдите в приложении Lobster", "랍스터 앱에서 로그인하세요", zhHant: "請在龍蝦輸入法 App 中登入", yue: "請喺龍蝦輸入法 App 登入") }

    // Agreements
    static var agreementTitle: String { t("用户协议", "User agreement", "Пользовательское соглашение", "사용자 약관", zhHant: "用戶協議", yue: "用戶協議") }
    static var agreementEmpty: String { t("暂无协议内容", "No agreement content", "Соглашений пока нет", "약관 내용 없음", zhHant: "暫無協議內容", yue: "暫無協議內容") }
}
