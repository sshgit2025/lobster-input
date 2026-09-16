export interface LangMeta { code: string; label: string; htmlLang: string }

export const languages: LangMeta[] = [
  { code: 'zh', label: '简体中文', htmlLang: 'zh-CN' },
  { code: 'zh-Hant', label: '繁體中文', htmlLang: 'zh-Hant' },
  { code: 'yue', label: '粵語（廣東省版）', htmlLang: 'yue-Hant' },
  { code: 'en', label: 'English', htmlLang: 'en' },
  { code: 'ru', label: 'Русский', htmlLang: 'ru-RU' },
  { code: 'ko', label: '한국어', htmlLang: 'ko-KR' },
]
