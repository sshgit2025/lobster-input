// 移植自 Android: core/locale/MobileStrings.kt(1041 行,全部 key 全部语言逐条搬运,不得遗漏)。
// 差异说明:
// - 安卓每个方法带 Context 参数用于读 SharedPreferences;鸿蒙端 AppPreferences 为全局单例,
//   因此方法不再需要 context 参数,签名为 MobileStrings.xxx()。
// - 语言存取仍走同一 preferences 文件(ApiConfig.PREFS_NAME)的 app_language key,与安卓一致。
import { AppPreferences } from '../../data/local/AppPreferences';

/** 对应 Kotlin enum MobileLanguage(code, label)。 */
export class MobileLanguage {
  static readonly ZH: MobileLanguage = new MobileLanguage('zh', '简体中文');
  static readonly ZH_HANT: MobileLanguage = new MobileLanguage('zh-Hant', '繁體中文');
  static readonly YUE: MobileLanguage = new MobileLanguage('yue', '粵語（廣東省版）');
  static readonly EN: MobileLanguage = new MobileLanguage('en', 'English');
  static readonly RU: MobileLanguage = new MobileLanguage('ru', 'Русский');
  static readonly KO: MobileLanguage = new MobileLanguage('ko', '한국어');

  readonly code: string;
  readonly label: string;

  private constructor(code: string, label: string) {
    this.code = code;
    this.label = label;
  }

  static values(): MobileLanguage[] {
    return [
      MobileLanguage.ZH,
      MobileLanguage.ZH_HANT,
      MobileLanguage.YUE,
      MobileLanguage.EN,
      MobileLanguage.RU,
      MobileLanguage.KO,
    ];
  }
}

const KEY_LANGUAGE: string = 'app_language';

export class MobileStrings {
  static currentLanguage(): MobileLanguage {
    const code = AppPreferences.getInstance().getStringSync(KEY_LANGUAGE, MobileLanguage.ZH.code);
    const all = MobileLanguage.values();
    for (let i = 0; i < all.length; i++) {
      if (all[i].code === code) {
        return all[i];
      }
    }
    return MobileLanguage.ZH;
  }

  static setLanguage(language: MobileLanguage): void {
    AppPreferences.getInstance().putStringSync(KEY_LANGUAGE, language.code);
  }

  /** 当前语言 code,内部 switch 分支用。 */
  private static lang(): string {
    return MobileStrings.currentLanguage().code;
  }

  static keyboardTitle(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '龍蝦輸入法';
      case 'en':
        return 'Lobster Input';
      case 'ru':
        return 'Лобстер Ввод';
      case 'ko':
        return '랍스터 입력기';
      default:
        return '龙虾输入法';
    }
  }

  static tapToSpeak(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '點擊說話';
      case 'yue':
        return '撳一下講嘢';
      case 'en':
        return 'Tap to speak';
      case 'ru':
        return 'Нажмите и говорите';
      case 'ko':
        return '탭하여 말하기';
      default:
        return '点击说话';
    }
  }

  static holdToSpeak(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '長按說話';
      case 'yue':
        return '長按講嘢';
      case 'en':
        return 'Hold to speak';
      case 'ru':
        return 'Удерживайте и говорите';
      case 'ko':
        return '길게 눌러 말하기';
      default:
        return '长按说话';
    }
  }

  /** 键盘模式:返回语音输入入口文案。 */
  static returnVoice(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '返回語音';
      case 'en':
        return 'Voice';
      case 'ru':
        return 'Голос';
      case 'ko':
        return '음성';
      default:
        return '返回语音';
    }
  }

  /** 键盘模式:空格键文案。 */
  static spaceKey(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'space';
      case 'ru':
        return 'пробел';
      case 'ko':
        return '스페이스';
      default:
        return '空格';
    }
  }

  /** 语音面板:切换到打字键盘的模式按钮文案。 */
  static keyboardModeLabel(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '鍵盤';
      case 'en':
        return 'Keyboard';
      case 'ru':
        return 'Клавиатура';
      case 'ko':
        return '키보드';
      default:
        return '键盘';
    }
  }

  /** 键盘布局:九宫格。 */
  static nineGridLabel(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '九宮格';
      case 'en':
        return '9-key';
      case 'ru':
        return '9-кл.';
      case 'ko':
        return '9키';
      default:
        return '九宫格';
    }
  }

  /** 键盘布局:26 键。 */
  static qwertyLabel(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '26鍵';
      case 'en':
        return 'QWERTY';
      case 'ru':
        return 'QWERTY';
      case 'ko':
        return '26키';
      default:
        return '26键';
    }
  }

  static imeChineseLabel(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return '中';
      case 'ru':
        return '中';
      case 'ko':
        return '中';
      default:
        return '中';
    }
  }

  static imeEnglishLabel(): string {
    return 'EN';
  }

  static symbolKeyLabel(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Sym';
      case 'ru':
        return 'Симв';
      case 'ko':
        return '기호';
      default:
        return '符';
    }
  }

  static switchQwertyLabel(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'QWERTY';
      case 'ru':
        return 'QWERTY';
      case 'ko':
        return '26키';
      default:
        return '切26';
    }
  }

  static pinyinKeyLabel(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Pin';
      case 'ru':
        return 'Пин';
      case 'ko':
        return '병음';
      default:
        return '拼';
    }
  }

  /** 工具/emoji/剪贴板子页:拼音模式返回键完整文案。 */
  static pinyinLabel(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Pinyin';
      case 'ru':
        return 'Пиньинь';
      case 'ko':
        return '병음';
      default:
        return '拼音';
    }
  }

  static abcKeyLabel(): string {
    return 'ABC';
  }

  static syllableSepKey(): string {
    return "'";
  }

  static pinyinDictLoading(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '詞庫載入中…';
      case 'en':
        return 'Loading dictionary...';
      case 'ru':
        return 'Загрузка словаря...';
      case 'ko':
        return '사전 로딩 중...';
      default:
        return '词库加载中…';
    }
  }

  static pinyinDictFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '詞庫載入失敗，請重啟鍵盤';
      case 'en':
        return 'Dictionary failed to load. Restart keyboard.';
      case 'ru':
        return 'Не удалось загрузить словарь. Перезапустите клавиатуру.';
      case 'ko':
        return '사전 로드 실패. 키보드를 다시 시작하세요.';
      default:
        return '词库加载失败，请重启键盘';
    }
  }

  static keyboardMicFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '語音輸入失敗';
      case 'en':
        return 'Voice input failed';
      case 'ru':
        return 'Голосовой ввод не удался';
      case 'ko':
        return '음성 입력 실패';
      default:
        return '语音输入失败';
    }
  }

  static typingUndone(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '已撤銷';
      case 'en':
        return 'Undone';
      case 'ru':
        return 'Отменено';
      case 'ko':
        return '실행 취소됨';
      default:
        return '已撤销';
    }
  }

  static enterNewline(): string {
    return '↵';
  }

  static enterSearch(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '搜尋';
      case 'en':
        return 'Search';
      case 'ru':
        return 'Поиск';
      case 'ko':
        return '검색';
      default:
        return '搜索';
    }
  }

  static enterSend(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '傳送';
      case 'en':
        return 'Send';
      case 'ru':
        return 'Отпр.';
      case 'ko':
        return '전송';
      default:
        return '发送';
    }
  }

  static enterGo(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Go';
      case 'ru':
        return 'Перейти';
      case 'ko':
        return '이동';
      default:
        return '前往';
    }
  }

  static enterDone(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Done';
      case 'ru':
        return 'Готово';
      case 'ko':
        return '완료';
      default:
        return '完成';
    }
  }

  static enterNext(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '下一項';
      case 'en':
        return 'Next';
      case 'ru':
        return 'Далее';
      case 'ko':
        return '다음';
      default:
        return '下一项';
    }
  }

  static enterPrevious(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '上一項';
      case 'en':
        return 'Prev';
      case 'ru':
        return 'Назад';
      case 'ko':
        return '이전';
      default:
        return '上一项';
    }
  }

  static a11yKeyLetter(ch: string): string {
    return ch;
  }

  static a11yKeyT9(label: string, digit: string): string {
    return `${label} ${digit}`;
  }

  static a11yKeyDelete(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '刪除';
      case 'en':
        return 'Delete';
      case 'ru':
        return 'Удалить';
      case 'ko':
        return '삭제';
      default:
        return '删除';
    }
  }

  static a11yKeySpace(): string {
    return MobileStrings.spaceKey();
  }

  static a11yKeyEnter(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '輸入鍵';
      case 'en':
        return 'Enter';
      case 'ru':
        return 'Ввод';
      case 'ko':
        return '엔터';
      default:
        return '回车';
    }
  }

  static a11yKeyShift(): string {
    return 'Shift';
  }

  static a11yKeyShiftOn(): string {
    return 'Shift on';
  }

  static a11yKeyCapsLock(): string {
    return 'Caps lock';
  }

  static a11yKeyLang(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '切換語言';
      case 'en':
        return 'Switch language';
      case 'ru':
        return 'Сменить язык';
      case 'ko':
        return '언어 전환';
      default:
        return '切换语言';
    }
  }

  static a11yKeyLayout(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '切換佈局';
      case 'en':
        return 'Switch layout';
      case 'ru':
        return 'Сменить раскладку';
      case 'ko':
        return '배열 전환';
      default:
        return '切换布局';
    }
  }

  static a11yKeySymbols(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '符號';
      case 'en':
        return 'Symbols';
      case 'ru':
        return 'Символы';
      case 'ko':
        return '기호';
      default:
        return '符号';
    }
  }

  static a11yKeyAlpha(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Letters';
      case 'ru':
        return 'Буквы';
      case 'ko':
        return '문자';
      default:
        return '字母';
    }
  }

  static a11yKeySymPage(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '符號頁';
      case 'en':
        return 'Symbol page';
      case 'ru':
        return 'Страница символов';
      case 'ko':
        return '기호 페이지';
      default:
        return '符号页';
    }
  }

  static a11yKeyChar(ch: string): string {
    return ch;
  }

  static a11yKeyMic(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '按住說話';
      case 'yue':
        return '按住講嘢';
      case 'en':
        return 'Hold to speak';
      case 'ru':
        return 'Удерживайте и говорите';
      case 'ko':
        return '길게 눌러 말하기';
      default:
        return '按住说话';
    }
  }

  static realtimeConnecting(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '正在連線...';
      case 'en':
        return 'Connecting...';
      case 'ru':
        return 'Подключение...';
      case 'ko':
        return '연결 중...';
      default:
        return '正在连接...';
    }
  }

  static releaseToSend(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '鬆開發送';
      case 'yue':
        return '鬆手發送';
      case 'en':
        return 'Release to send';
      case 'ru':
        return 'Отпустите для отправки';
      case 'ko':
        return '놓으면 전송';
      default:
        return '松开发送';
    }
  }

  static realtimeFinishing(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '正在完成識別...';
      case 'en':
        return 'Finishing recognition...';
      case 'ru':
        return 'Завершаем распознавание...';
      case 'ko':
        return '인식 마무리 중...';
      default:
        return '正在完成识别...';
    }
  }

  static rewriteHint(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '選中文字、處理剛才輸入，或直接說新指令';
      case 'yue':
        return '揀選文字、處理啱先嘅輸入，或者直接講新指令';
      case 'en':
        return 'Select text, reuse the last insert, or speak a new command';
      case 'ru':
        return 'Выделите текст, исправьте последний ввод или продиктуйте команду';
      case 'ko':
        return '텍스트 선택, 최근 입력 수정 또는 새 명령 말하기';
      default:
        return '选中文本、处理刚才输入，或直接说新指令';
    }
  }

  static tapAgainTranscribe(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '再次點擊以完成';
      case 'yue':
        return '再撳一下完成';
      case 'en':
        return 'Tap again to finish';
      case 'ru':
        return 'Нажмите еще раз';
      case 'ko':
        return '다시 탭해 완료';
      default:
        return '再次点击以完成';
    }
  }

  static tapAgainRewrite(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '再次點擊以完成';
      case 'yue':
        return '再撳一下完成';
      case 'en':
        return 'Tap again to finish';
      case 'ru':
        return 'Нажмите еще раз';
      case 'ko':
        return '다시 탭해 완료';
      default:
        return '再次点击以完成';
    }
  }

  static remainingSeconds(seconds: number): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return `剩餘 ${seconds} 秒`;
      case 'en':
        return `${seconds}s left`;
      case 'ru':
        return `Осталось ${seconds}с`;
      case 'ko':
        return `${seconds}초 남음`;
      default:
        return `剩余 ${seconds} 秒`;
    }
  }

  static processing(rewrite: boolean): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return rewrite ? '正在處理指令...' : '正在識別語音...';
      case 'en':
        return rewrite ? 'Processing command...' : 'Recognizing voice...';
      case 'ru':
        return rewrite ? 'Обработка команды...' : 'Распознавание голоса...';
      case 'ko':
        return rewrite ? '명령 처리 중...' : '음성 인식 중...';
      default:
        return rewrite ? '正在处理指令...' : '正在识别语音...';
    }
  }

  static inserted(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '已填入，可用指令修改或繼續生成';
      case 'yue':
        return '已填入，可以用指令修改或者繼續生成';
      case 'en':
        return 'Inserted. Use Command to edit or continue.';
      case 'ru':
        return 'Вставлено. Командой можно исправить или продолжить.';
      case 'ko':
        return '입력됨. 명령으로 수정하거나 이어갈 수 있습니다.';
      default:
        return '已填入，可用指令修改或继续生成';
    }
  }

  static rewritten(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Done';
      case 'ru':
        return 'Готово';
      case 'ko':
        return '완료';
      default:
        return '已完成';
    }
  }

  static loginRequired(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '請先在龍蝦輸入法 App 中登入';
      case 'yue':
        return '請先喺龍蝦輸入法 App 登入';
      case 'en':
        return 'Please sign in from the Lobster app';
      case 'ru':
        return 'Войдите в приложении Lobster';
      case 'ko':
        return '랍스터 앱에서 로그인하세요';
      default:
        return '请先在龙虾输入法 App 中登录';
    }
  }

  static sessionExpired(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '登入已過期，請在龍蝦輸入法 App 中重新登入';
      case 'yue':
        return '登入過咗期，請喺龍蝦輸入法 App 重新登入';
      case 'en':
        return 'Session expired. Sign in again from the Lobster app.';
      case 'ru':
        return 'Сессия истекла. Войдите снова в приложении Lobster.';
      case 'ko':
        return '로그인이 만료되었습니다. 랍스터 앱에서 다시 로그인하세요.';
      default:
        return '登录已过期，请在龙虾输入法 App 中重新登录';
    }
  }

  static creditsExhausted(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '積分已用完';
      case 'yue':
        return '積分用晒';
      case 'en':
        return 'Credits exhausted';
      case 'ru':
        return 'Кредиты закончились';
      case 'ko':
        return '크레딧이 부족합니다';
      default:
        return '积分已用完';
    }
  }

  static checkingAccount(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '正在檢查帳戶...';
      case 'en':
        return 'Checking account...';
      case 'ru':
        return 'Проверяем аккаунт...';
      case 'ko':
        return '계정 확인 중...';
      default:
        return '正在检查账户...';
    }
  }

  static inputUnavailableTitle(creditsExhausted: boolean): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return creditsExhausted ? '積分已用完' : '需要登入';
      case 'yue':
        return creditsExhausted ? '積分用晒' : '需要登入';
      case 'en':
        return creditsExhausted ? 'Credits exhausted' : 'Sign in required';
      case 'ru':
        return creditsExhausted ? 'Кредиты закончились' : 'Нужен вход';
      case 'ko':
        return creditsExhausted ? '크레딧 부족' : '로그인 필요';
      default:
        return creditsExhausted ? '积分已用完' : '需要登录';
    }
  }

  static inputUnavailableBody(creditsExhausted: boolean): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return creditsExhausted
          ? '當前無法語音輸入。可先切換到其它輸入法繼續輸入，或打開 App 查看積分。'
          : '登入前無法語音輸入。可先切換到其它輸入法繼續輸入，或打開 App 登入。';
      case 'yue':
        return creditsExhausted
          ? '而家用唔到語音輸入。可以先切換去其它輸入法繼續打字，或者打開 App 睇積分。'
          : '登入之前用唔到語音輸入。可以先切換去其它輸入法繼續打字，或者打開 App 登入。';
      case 'en':
        return creditsExhausted
          ? 'Voice input is unavailable right now. Switch keyboards to keep typing, or open the app to check credits.'
          : 'Voice input is unavailable before sign-in. Switch keyboards to keep typing, or open the app to sign in.';
      case 'ru':
        return creditsExhausted
          ? 'Голосовой ввод сейчас недоступен. Переключите клавиатуру или откройте приложение для проверки кредитов.'
          : 'До входа голосовой ввод недоступен. Переключите клавиатуру или откройте приложение для входа.';
      case 'ko':
        return creditsExhausted
          ? '지금은 음성 입력을 사용할 수 없습니다. 다른 키보드로 전환하거나 앱에서 크레딧을 확인하세요.'
          : '로그인 전에는 음성 입력을 사용할 수 없습니다. 다른 키보드로 전환하거나 앱에서 로그인하세요.';
      default:
        return creditsExhausted
          ? '当前无法语音输入。可先切换到其它输入法继续输入，或打开 App 查看积分。'
          : '登录前无法语音输入。可先切换到其它输入法继续输入，或打开 App 登录。';
    }
  }

  static switchKeyboard(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '切換輸入法';
      case 'en':
        return 'Keyboard';
      case 'ru':
        return 'Клав.';
      case 'ko':
        return '키보드 전환';
      default:
        return '切换输入法';
    }
  }

  static openApp(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '打開 App';
      case 'en':
        return 'Open app';
      case 'ru':
        return 'Открыть';
      case 'ko':
        return '앱 열기';
      default:
        return '打开 App';
    }
  }

  static micPermission(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '需要錄音權限';
      case 'en':
        return 'Microphone permission required';
      case 'ru':
        return 'Нужен доступ к микрофону';
      case 'ko':
        return '마이크 권한이 필요합니다';
      default:
        return '需要录音权限';
    }
  }

  static newline(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '換行';
      case 'en':
        return 'Line';
      case 'ru':
        return 'Строка';
      case 'ko':
        return '줄바꿈';
      default:
        return '换行';
    }
  }

  static undo(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Undo';
      case 'ru':
        return 'Отмена';
      case 'ko':
        return '취소';
      default:
        return '撤回';
    }
  }

  static restoreVoice(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '還原';
      case 'en':
        return 'Restore';
      case 'ru':
        return 'Вернуть';
      case 'ko':
        return '복원';
      default:
        return '还原';
    }
  }

  static leftHand(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Left';
      case 'ru':
        return 'Лев';
      case 'ko':
        return '왼손';
      default:
        return '左手';
    }
  }

  static rightHand(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Right';
      case 'ru':
        return 'Прав';
      case 'ko':
        return '오른손';
      default:
        return '右手';
    }
  }

  static recordingStartFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '錄音啟動失敗';
      case 'en':
        return 'Could not start recording';
      case 'ru':
        return 'Не удалось начать запись';
      case 'ko':
        return '녹음을 시작할 수 없습니다';
      default:
        return '录音启动失败';
    }
  }

  static restoredVoice(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '已還原';
      case 'en':
        return 'Restored';
      case 'ru':
        return 'Восстановлено';
      case 'ko':
        return '복원됨';
      default:
        return '已还原';
    }
  }

  static quickFormat(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Fmt';
      case 'ru':
        return 'Форм.';
      case 'ko':
        return '정리';
      default:
        return '格式化';
    }
  }

  static quickPolish(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '潤色';
      case 'en':
        return 'Polish';
      case 'ru':
        return 'Стиль';
      case 'ko':
        return '다듬기';
      default:
        return '润色';
    }
  }

  static quickConcise(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '精簡';
      case 'en':
        return 'Short';
      case 'ru':
        return 'Кратко';
      case 'ko':
        return '줄이기';
      default:
        return '精简';
    }
  }

  static clearInput(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Clear';
      case 'ru':
        return 'Очист.';
      case 'ko':
        return '지우기';
      default:
        return '清空';
    }
  }

  static inputCleared(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Cleared';
      case 'ru':
        return 'Очищено';
      case 'ko':
        return '지웠어요';
      default:
        return '已清空';
    }
  }

  static quickBullets(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '要點';
      case 'en':
        return 'List';
      case 'ru':
        return 'Список';
      case 'ko':
        return '요점';
      default:
        return '要点';
    }
  }

  static quickProcessing(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '正在處理文字...';
      case 'en':
        return 'Processing text...';
      case 'ru':
        return 'Обработка текста...';
      case 'ko':
        return '텍스트 처리 중...';
      default:
        return '正在处理文本...';
    }
  }

  static rewrite(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Command';
      case 'ru':
        return 'Команда';
      case 'ko':
        return '명령';
      default:
        return '指令';
    }
  }

  static emptyRewrite(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '處理結果為空';
      case 'en':
        return 'Result is empty';
      case 'ru':
        return 'Результат пуст';
      case 'ko':
        return '결과가 비었습니다';
      default:
        return '处理结果为空';
    }
  }

  static noRewriteTarget(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '說出指令，可生成新文字或修改選中文字';
      case 'yue':
        return '講出指令，可以生成新文字或者修改揀選嘅文字';
      case 'en':
        return 'Speak a command to generate text or edit selected text';
      case 'ru':
        return 'Продиктуйте команду для создания или правки текста';
      case 'ko':
        return '명령을 말해 새 텍스트를 만들거나 선택 텍스트를 수정하세요';
      default:
        return '说出指令，可生成新文本或修改选中文本';
    }
  }

  static commandHint(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '指令可修改選區，也可直接生成';
      case 'yue':
        return '指令可以修改選區，亦可以直接生成';
      case 'en':
        return 'Command can edit selected text or create new text';
      case 'ru':
        return 'Команда: правка выделенного или новый текст';
      case 'ko':
        return '명령: 선택 수정 또는 새 텍스트';
      default:
        return '指令可修改选区，也可直接生成';
    }
  }

  static emptyTranscribe(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '沒有識別到可輸入內容';
      case 'yue':
        return '識別唔到可輸入嘅內容';
      case 'en':
        return 'No text recognized';
      case 'ru':
        return 'Текст не распознан';
      case 'ko':
        return '인식된 텍스트가 없습니다';
      default:
        return '没有识别到可输入内容';
    }
  }

  static emptyResponse(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '回應為空';
      case 'en':
        return 'Empty response';
      case 'ru':
        return 'Пустой ответ';
      case 'ko':
        return '빈 응답';
      default:
        return '响应为空';
    }
  }

  static requestFailed(statusCode: number): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return `請求失敗(${statusCode})`;
      case 'en':
        return `Request failed (${statusCode})`;
      case 'ru':
        return `Запрос не удался (${statusCode})`;
      case 'ko':
        return `요청 실패 (${statusCode})`;
      default:
        return `请求失败(${statusCode})`;
    }
  }

  static processFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '處理失敗';
      case 'en':
        return 'Processing failed';
      case 'ru':
        return 'Обработка не удалась';
      case 'ko':
        return '처리 실패';
      default:
        return '处理失败';
    }
  }

  static accountCheckFailed(statusCode: number | null = null): string {
    const zhSuffix: string = statusCode !== null ? `(${statusCode})` : '';
    const enSuffix: string = statusCode !== null ? ` (${statusCode})` : '';
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return `帳戶狀態檢查失敗${zhSuffix}`;
      case 'en':
        return `Account check failed${enSuffix}`;
      case 'ru':
        return `Проверка аккаунта не удалась${enSuffix}`;
      case 'ko':
        return `계정 확인 실패${enSuffix}`;
      default:
        return `账户状态检查失败${zhSuffix}`;
    }
  }

  static processingShort(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '處理中...';
      case 'en':
        return 'Work...';
      case 'ru':
        return 'Ждем...';
      case 'ko':
        return '처리 중...';
      default:
        return '处理中...';
    }
  }

  static symbols(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '符號';
      case 'en':
        return 'Sym';
      case 'ru':
        return 'Симв';
      case 'ko':
        return '기호';
      default:
        return '符号';
    }
  }

  static persona(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '人設';
      case 'en':
        return 'Role';
      case 'ru':
        return 'Роль';
      case 'ko':
        return '페르소나';
      default:
        return '人设';
    }
  }

  static personaHint(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '選擇語音輸入與指令處理風格';
      case 'yue':
        return '揀語音輸入同指令處理風格';
      case 'en':
        return 'Choose style for dictation and commands';
      case 'ru':
        return 'Стиль для диктовки и команд';
      case 'ko':
        return '음성 입력과 명령 결과에 사용할 페르소나 선택';
      default:
        return '选择语音输入与指令处理风格';
    }
  }

  static personaEmpty(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '暫無人設';
      case 'en':
        return 'No personas yet';
      case 'ru':
        return 'Персон пока нет';
      case 'ko':
        return '페르소나 없음';
      default:
        return '暂无人设';
    }
  }

  static active(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '已啟用';
      case 'en':
        return 'Active';
      case 'ru':
        return 'Активно';
      case 'ko':
        return '활성';
      default:
        return '已启用';
    }
  }

  static inactive(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '未啟用';
      case 'en':
        return 'Inactive';
      case 'ru':
        return 'Неактивно';
      case 'ko':
        return '비활성';
      default:
        return '未启用';
    }
  }

  static enable(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '啟用';
      case 'en':
        return 'On';
      case 'ru':
        return 'Вкл';
      case 'ko':
        return '켜기';
      default:
        return '启用';
    }
  }

  static disable(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '停用';
      case 'en':
        return 'Off';
      case 'ru':
        return 'Выкл';
      case 'ko':
        return '끄기';
      default:
        return '停用';
    }
  }

  static refresh(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '刷新';
      case 'en':
        return 'Reload';
      case 'ru':
        return 'Обн.';
      case 'ko':
        return '새로고침';
      default:
        return '刷新';
    }
  }

  static back(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '返回';
      case 'en':
        return 'Back';
      case 'ru':
        return 'Назад';
      case 'ko':
        return '뒤로';
      default:
        return '返回';
    }
  }

  static personaTranscribe(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '語音輸入';
      case 'en':
        return 'Voice';
      case 'ru':
        return 'Голос';
      case 'ko':
        return '음성 입력';
      default:
        return '语音输入';
    }
  }

  static personaRewrite(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '指令';
      case 'en':
        return 'Command';
      case 'ru':
        return 'Команда';
      case 'ko':
        return '명령';
      default:
        return '指令';
    }
  }

  static personaIntent(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '意圖';
      case 'en':
        return 'Intent';
      case 'ru':
        return 'Интент';
      case 'ko':
        return '의도';
      default:
        return '意图';
    }
  }

  static personaModuleHint(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '啟用後作用於語音輸入和指令處理';
      case 'yue':
        return '啟用後會用喺語音輸入同指令處理';
      case 'en':
        return 'Toggle modules for this role';
      case 'ru':
        return 'Модули этой роли';
      case 'ko':
        return '음성 입력과 명령에 사용할 페르소나를 켜세요';
      default:
        return '启用后作用于语音输入和指令处理';
    }
  }

  static customized(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '自訂';
      case 'en':
        return 'Custom';
      case 'ru':
        return 'Свое';
      case 'ko':
        return '사용자';
      default:
        return '自定义';
    }
  }

  static builtin(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '預設';
      case 'en':
        return 'Built-in';
      case 'ru':
        return 'База';
      case 'ko':
        return '기본';
      default:
        return '默认';
    }
  }

  static fastMode(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '極速';
      case 'en':
        return 'Fast';
      case 'ru':
        return 'Быстро';
      case 'ko':
        return '빠름';
      default:
        return '极速';
    }
  }

  /** 开关状态后缀(极速按钮等):开。 */
  static stateOn(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '開';
      case 'en':
        return 'ON';
      case 'ru':
        return 'ВКЛ';
      case 'ko':
        return '켬';
      default:
        return '开';
    }
  }

  /** 开关状态后缀(极速按钮等):关。 */
  static stateOff(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '關';
      case 'en':
        return 'OFF';
      case 'ru':
        return 'ВЫКЛ';
      case 'ko':
        return '끔';
      default:
        return '关';
    }
  }

  static networkError(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '網絡連接失敗';
      case 'en':
        return 'Network error';
      case 'ru':
        return 'Ошибка сети';
      case 'ko':
        return '네트워크 연결 실패';
      default:
        return '网络连接失败';
    }
  }

  static userBanned(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '帳號已被停用';
      case 'en':
        return 'Account disabled';
      case 'ru':
        return 'Аккаунт заблокирован';
      case 'ko':
        return '계정이 비활성화되었습니다';
      default:
        return '账号已被禁用';
    }
  }

  static chineseSymbols(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'CN';
      case 'ru':
        return 'Кит';
      case 'ko':
        return '중';
      default:
        return '中文';
    }
  }

  static englishSymbols(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'EN';
      case 'ru':
        return 'Анг';
      case 'ko':
        return '영';
      default:
        return '英文';
    }
  }

  /** 键盘工具子页:切换 26 键磁贴。 */
  static switchTo26Keys(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '切換 26 鍵';
      case 'en':
        return 'Switch to QWERTY';
      case 'ru':
        return 'Раскладка QWERTY';
      case 'ko':
        return '26키로 전환';
      default:
        return '切换 26 键';
    }
  }

  /** 键盘工具子页:切换九宫格磁贴。 */
  static switchToNineGrid(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '切換九宮格';
      case 'en':
        return 'Switch to 9-key';
      case 'ru':
        return 'Раскладка 9 кл.';
      case 'ko':
        return '9키로 전환';
      default:
        return '切换九宫格';
    }
  }

  /** 键盘工具子页:表情磁贴。 */
  static toolEmoji(): string {
    switch (MobileStrings.lang()) {
      case 'en':
        return 'Emoji';
      case 'ru':
        return 'Эмодзи';
      case 'ko':
        return '이모지';
      default:
        return '表情';
    }
  }

  /** 键盘工具子页/剪贴板面板:剪贴板。 */
  static toolClipboard(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '剪貼簿';
      case 'en':
        return 'Clipboard';
      case 'ru':
        return 'Буфер';
      case 'ko':
        return '클립보드';
      default:
        return '剪贴板';
    }
  }

  /** 键盘工具子页:已在俄语键盘时的退出磁贴。 */
  static exitRussian(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '退出俄語';
      case 'en':
        return 'Exit';
      case 'ru':
        return 'Выход';
      case 'ko':
        return '종료';
      default:
        return '退出俄语';
    }
  }

  /** 键盘工具子页:已在韩语键盘时的退出磁贴。 */
  static exitKorean(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '退出韓語';
      case 'en':
        return 'Exit';
      case 'ru':
        return 'Выход';
      case 'ko':
        return '종료';
      default:
        return '退出韩语';
    }
  }

  /** 剪贴板面板:空态提示。 */
  static clipEmptyHint(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '暫無剪貼內容，複製文字後會出現在這裡';
      case 'yue':
        return '暫時冇剪貼內容，複製文字後會喺呢度出現';
      case 'en':
        return 'No clips yet — copied text shows here';
      case 'ru':
        return 'Пока пусто — скопированный текст появится здесь';
      case 'ko':
        return '클립 없음 — 복사한 텍스트가 여기에 표시됩니다';
      default:
        return '暂无剪贴内容，复制文本后会出现在这里';
    }
  }

  /** 剪贴板面板:快捷短语分组标题。 */
  static quickPhrasesLabel(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '快捷短語';
      case 'en':
        return 'Quick phrases';
      case 'ru':
        return 'Быстрые фразы';
      case 'ko':
        return '빠른 문구';
      default:
        return '快捷短语';
    }
  }

  static sendCodeFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '發送驗證碼失敗';
      case 'en':
        return 'Could not send code';
      case 'ru':
        return 'Код не отправлен';
      case 'ko':
        return '인증 코드를 보낼 수 없습니다';
      default:
        return '发送验证码失败';
    }
  }

  static loginFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '登入失敗';
      case 'en':
        return 'Sign-in failed';
      case 'ru':
        return 'Вход не удался';
      case 'ko':
        return '로그인 실패';
      default:
        return '登录失败';
    }
  }

  static inviteVerifyFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '邀請碼驗證失敗';
      case 'en':
        return 'Invite check failed';
      case 'ru':
        return 'Код приглашения не принят';
      case 'ko':
        return '초대 코드 확인 실패';
      default:
        return '邀请码验证失败';
    }
  }

  static registrationDisabled(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '未開放註冊';
      case 'en':
        return 'Registration is not open';
      case 'ru':
        return 'Регистрация пока закрыта';
      case 'ko':
        return '현재 가입이 열려 있지 않습니다';
      default:
        return '未开放注册';
    }
  }

  static apiErrorMessage(code: string | null, fallback: string | null): string {
    if (code === 'REGISTRATION_DISABLED') {
      return MobileStrings.registrationDisabled();
    }
    if (fallback !== null && fallback.trim().length > 0) {
      return fallback;
    }
    return MobileStrings.processFailed();
  }

  static mainLoadPlanFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '載入帳戶資訊失敗';
      case 'en':
        return 'Could not load account';
      case 'ru':
        return 'Аккаунт не загружен';
      case 'ko':
        return '계정 정보를 불러올 수 없습니다';
      default:
        return '加载账户信息失败';
    }
  }

  static mainPaymentCheckoutOpened(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '已打開支付頁面。支付完成後回到本頁刷新狀態。';
      case 'yue':
        return '已打開支付頁面。支付完成後返嚟本頁刷新狀態。';
      case 'en':
        return 'Payment page opened. Return here after payment and refresh.';
      case 'ru':
        return 'Страница оплаты открыта. Вернитесь после оплаты и обновите.';
      case 'ko':
        return '결제 페이지가 열렸습니다. 결제 후 돌아와 새로고침하세요.';
      default:
        return '已打开支付页面。支付完成后回到本页刷新状态。';
    }
  }

  static mainPaymentCheckoutFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '建立支付失敗';
      case 'en':
        return 'Could not create payment';
      case 'ru':
        return 'Не удалось создать оплату';
      case 'ko':
        return '결제를 생성할 수 없습니다';
      default:
        return '创建支付失败';
    }
  }

  static mainCancelRenewalSuccess(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '已取消自動續費，到期後不再自動扣費。';
      case 'yue':
        return '已取消自動續費，到期之後唔會再自動扣費。';
      case 'en':
        return 'Auto-renewal cancelled. You will not be charged again.';
      case 'ru':
        return 'Автопродление отменено. Списаний больше не будет.';
      case 'ko':
        return '자동 갱신이 취소되었습니다. 더 이상 자동 결제되지 않습니다.';
      default:
        return '已取消自动续费，到期后不再自动扣费。';
    }
  }

  static mainCancelRenewalFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '取消自動續費失敗';
      case 'en':
        return 'Could not cancel auto-renewal';
      case 'ru':
        return 'Не удалось отменить автопродление';
      case 'ko':
        return '자동 갱신을 취소할 수 없습니다';
      default:
        return '取消自动续费失败';
    }
  }

  static mainRenewalStoreManaged(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
        return '自動續費已開啟，可在訂閱裝置的應用商店中管理';
      case 'yue':
        return '自動續費已開啟，可以喺訂閱嗰部裝置嘅應用商店入面管理';
      case 'en':
        return 'Auto-renewal is on. Manage it in the app store on the device you subscribed with.';
      case 'ru':
        return 'Автопродление включено. Управляйте им в магазине приложений на устройстве с подпиской.';
      case 'ko':
        return '자동 갱신이 켜져 있습니다. 구독한 기기의 앱 스토어에서 관리할 수 있습니다.';
      default:
        return '自动续费已开启，可在订阅设备的应用商店中管理';
    }
  }

  static mainLoadHotWordsFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '載入熱詞失敗';
      case 'en':
        return 'Could not load words';
      case 'ru':
        return 'Слова не загружены';
      case 'ko':
        return '단어를 불러올 수 없습니다';
      default:
        return '加载热词失败';
    }
  }

  static mainSaveHotWordFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '儲存熱詞失敗';
      case 'en':
        return 'Could not save word';
      case 'ru':
        return 'Слово не сохранено';
      case 'ko':
        return '단어를 저장할 수 없습니다';
      default:
        return '保存热词失败';
    }
  }

  static mainDeleteHotWordFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '刪除熱詞失敗';
      case 'en':
        return 'Could not delete word';
      case 'ru':
        return 'Слово не удалено';
      case 'ko':
        return '단어를 삭제할 수 없습니다';
      default:
        return '删除热词失败';
    }
  }

  static mainLoadPersonasFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '載入人設失敗';
      case 'en':
        return 'Could not load roles';
      case 'ru':
        return 'Роли не загружены';
      case 'ko':
        return '페르소나를 불러올 수 없습니다';
      default:
        return '加载人设失败';
    }
  }

  static mainSavePersonaFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '儲存人設失敗';
      case 'en':
        return 'Could not save role';
      case 'ru':
        return 'Роль не сохранена';
      case 'ko':
        return '페르소나를 저장할 수 없습니다';
      default:
        return '保存人设失败';
    }
  }

  static mainActivatePersonaFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '切換人設失敗';
      case 'en':
        return 'Could not switch role';
      case 'ru':
        return 'Роль не включена';
      case 'ko':
        return '페르소나를 전환할 수 없습니다';
      default:
        return '切换人设失败';
    }
  }

  static mainDeletePersonaFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '刪除人設失敗';
      case 'en':
        return 'Could not delete role';
      case 'ru':
        return 'Роль не удалена';
      case 'ko':
        return '페르소나를 삭제할 수 없습니다';
      default:
        return '删除人设失败';
    }
  }

  static mainLoadInviteCodesFailed(): string {
    switch (MobileStrings.lang()) {
      case 'zh-Hant':
      case 'yue':
        return '載入邀請碼失敗';
      case 'en':
        return 'Could not load invites';
      case 'ru':
        return 'Коды не загружены';
      case 'ko':
        return '초대 코드를 불러올 수 없습니다';
      default:
        return '加载邀请码失败';
    }
  }
}
