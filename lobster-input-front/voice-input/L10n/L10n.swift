/// L10n.swift
/// 国际化文案统一访问入口。根据 LanguageManager.shared.current 返回对应语言文案。
import Foundation

enum L10n {
    private static var lang: AppLanguage { LanguageManager.shared.current }
    private static var s: AppStrings {
        switch lang {
        case .zh:     return Strings_zh()
        case .zhHant: return Strings_zhHant()
        case .yue:    return Strings_yue()
        case .en:     return Strings_en()
        case .ru:     return Strings_ru()
        case .ko:     return Strings_ko()
        }
    }

    // MARK: - Sidebar
    static var sidebarHome: String { s.sidebarHome }
    static var sidebarDict: String { s.sidebarDict }
    static var sidebarPersona: String { s.sidebarPersona }
    static var sidebarHistory: String { s.sidebarHistory }
    static var sidebarSettings: String { s.sidebarSettings }
    static var appNameShort: String { s.appNameShort }
    static var appNameFull: String { s.appNameFull }
    static var notLoggedIn: String { s.notLoggedIn }
    static var logout: String { s.logout }
    static var permManage: String { s.permManage }
    static var permUnauthorized: String { s.permUnauthorized }

    // MARK: - Home
    static var systemReady: String { s.systemReady }
    static var recording: String { s.recording }
    static var processing: String { s.processing }
    static var subtitleIdle: String { s.subtitleIdle }
    static var subtitleRecording: String { s.subtitleRecording }
    static var subtitleProcessing: String { s.subtitleProcessing }
    static var hotkeyTranscribe: String { s.hotkeyTranscribe }
    static var hotkeyRewrite: String { s.hotkeyRewrite }
    static var hotkeyAgent: String { s.hotkeyAgent }
    static var recognizing: String { s.recognizing }
    static var recognizeFailed: String { s.recognizeFailed }

    // MARK: - Auth
    static var authSubtitle: String { s.authSubtitle }
    static var emailPlaceholder: String { s.emailPlaceholder }
    static var codePlaceholder: String { s.codePlaceholder }
    static var resendCode: String { s.resendCode }
    static var sendCode: String { s.sendCode }
    static var verifyAccess: String { s.verifyAccess }
    static var enterEmail: String { s.enterEmail }
    static var enterCode: String { s.enterCode }

    // MARK: - Dictionary
    static var dictDesc: String { s.dictDesc }
    static var dictEmpty: String { s.dictEmpty }
    static var dictNoResult: String { s.dictNoResult }
    static var dictSearchPlaceholder: String { s.dictSearchPlaceholder }
    static var dictStandardWord: String { s.dictStandardWord }
    static var dictPlaceholder: String { s.dictPlaceholder }
    static var editHotword: String { s.editHotword }
    static var newHotword: String { s.newHotword }
    static func dictPageInfo(_ cur: Int, _ total: Int) -> String { s.dictPageInfo(cur, total) }

    // MARK: - Persona
    static var personaPageDesc: String { s.personaPageDesc }
    static var personaNewPersona: String { s.personaNewPersona }
    static var personaNameLabel: String { s.personaNameLabel }
    static var personaNamePlaceholder: String { s.personaNamePlaceholder }
    static var personaDescLabel: String { s.personaDescLabel }
    static var personaDescPlaceholder: String { s.personaDescPlaceholder }
    static var personaActivated: String { s.personaActivated }
    static var personaNotActivated: String { s.personaNotActivated }
    static var personaActivateBtn: String { s.personaActivateBtn }
    static var menuPersona: String { s.menuPersona }
    static var personaMenuNone: String { s.personaMenuNone }
    static var personaMenuEmpty: String { s.personaMenuEmpty }
    static var personaDeactivateBtn: String { s.personaDeactivateBtn }
    static func personaCountHint(_ count: Int, _ max: Int) -> String {
        String(format: s.personaCountHint, count, max)
    }
    static func personaLimitReached(_ max: Int) -> String {
        String(format: s.personaLimitReached, max)
    }
    static var personaTranscribeTitle: String { s.personaTranscribeTitle }
    static var personaTranscribeDesc: String { s.personaTranscribeDesc }
    static var personaTranscribePlaceholder: String { s.personaTranscribePlaceholder }
    static var personaRewriteTitle: String { s.personaRewriteTitle }
    static var personaRewriteDesc: String { s.personaRewriteDesc }
    static var personaRewritePlaceholder: String { s.personaRewritePlaceholder }
    static var personaIntentTitle: String { s.personaIntentTitle }
    static var personaIntentDesc: String { s.personaIntentDesc }
    static var personaIntentPlaceholder: String { s.personaIntentPlaceholder }
    static var personaCustomized: String { s.personaCustomized }
    static var personaUsingBuiltin: String { s.personaUsingBuiltin }
    static var personaClearToBuiltin: String { s.personaClearToBuiltin }
    static var personaReset: String { s.personaReset }
    static var personaActive: String { s.personaActive }
    static var personaEnableHint: String { s.personaEnableHint }
    static var personaDisableHint: String { s.personaDisableHint }

    // MARK: - History
    static var noRecords: String { s.noRecords }
    static var noResult: String { s.noResult }
    static var deleteConfirm: String { s.deleteConfirm }
    static var deleteRecordAndAudio: String { s.deleteRecordAndAudio }
    static var deleteRecordOnly: String { s.deleteRecordOnly }
    static var opTranscribe: String { s.opTranscribe }
    static var opRewrite: String { s.opRewrite }
    static var opAgent: String { s.opAgent }
    static var historySaveTitle: String { s.historySaveTitle }
    static var historySaveSubtitle: String { s.historySaveSubtitle }
    static var historyPrivacyTitle: String { s.historyPrivacyTitle }
    static var historyPrivacySubtitle: String { s.historyPrivacySubtitle }
    static var historyRetentionForever: String { s.historyRetentionForever }
    static var historyRetention30Days: String { s.historyRetention30Days }
    static var historyRetention7Days: String { s.historyRetention7Days }
    static var historyRetention1Day: String { s.historyRetention1Day }
    static var historyRetentionNever: String { s.historyRetentionNever }

    // MARK: - Account Panel
    static var accountTitle: String { s.accountTitle }
    static var accountEmail: String { s.accountEmail }
    static var accountTier: String { s.accountTier }
    static var tierTrial: String { s.tierTrial }
    static var planTrial: String { s.planTrial }
    static var planFree: String { s.planFree }
    static var planWeekly: String { s.planWeekly }
    static var planMonthly: String { s.planMonthly }
    static var planYearly: String { s.planYearly }
    static var planLite: String { s.planLite }
    static var planStandard: String { s.planStandard }
    static var planPro: String { s.planPro }
    static var tierNone: String { s.tierNone }
    static var accountCredits: String { s.accountCredits }
    static var accountCreditsReset: String { s.accountCreditsReset }
    static var accountCreditsUsed: String { s.accountCreditsUsed }
    static var accountCreditsDetailsShow: String { s.accountCreditsDetailsShow }
    static var accountCreditsDetailsHide: String { s.accountCreditsDetailsHide }
    static var creditItemBonus: String { s.creditItemBonus }
    static var creditItemPaidTopup: String { s.creditItemPaidTopup }
    static var creditItemNoExpiry: String { s.creditItemNoExpiry }
    static func creditItemExpires(_ date: String) -> String { s.creditItemExpires(date) }
    static func creditsResetDateLabel(_ date: String) -> String { s.creditsResetDateLabel(date) }

    // MARK: - Settings
    static var hotkeyVoiceInput: String { s.hotkeyVoiceInput }
    static var hotkeyVoiceInputDesc: String { s.hotkeyVoiceInputDesc }
    static var hotkeyRewriteTitle: String { s.hotkeyRewriteTitle }
    static var hotkeyRewriteDesc: String { s.hotkeyRewriteDesc }
    static var hotkeyAgentTitle: String { s.hotkeyAgentTitle }
    static var hotkeyAgentDesc: String { s.hotkeyAgentDesc }
    static var hotkeyScreenshotTitle: String { s.hotkeyScreenshotTitle }
    static var hotkeyScreenshotDesc: String { s.hotkeyScreenshotDesc }
    static var transcribeFastModeTitle: String { s.transcribeFastModeTitle }
    static var transcribeFastModeDesc: String { s.transcribeFastModeDesc }
    static var realtimeRecognitionTitle: String { s.realtimeRecognitionTitle }
    static var realtimeRecognitionDesc: String { s.realtimeRecognitionDesc }
    static var screenshotConfirmationTitle: String { s.screenshotConfirmationTitle }
    static var screenshotConfirmationDesc: String { s.screenshotConfirmationDesc }
    static var pressHotkeyHint: String { s.pressHotkeyHint }
    static var pressNewHotkey: String { s.pressNewHotkey }
    static var hotkeyNotSet: String { s.hotkeyNotSet }
    static var hotkeyConflictDuplicate: String { s.hotkeyConflictDuplicate }
    static var hotkeyConflictSystemReserved: String { s.hotkeyConflictSystemReserved }
    static var hotkeyConflictSystemWarning: String { s.hotkeyConflictSystemWarning }
    static var settingsMicrophoneSection: String { s.settingsMicrophoneSection }
    static var microphoneInputTitle: String { s.microphoneInputTitle }
    static var microphoneInputDesc: String { s.microphoneInputDesc }
    static var microphoneMenuTitle: String { s.microphoneMenuTitle }
    static var microphoneCurrentDefaultSuffix: String { s.microphoneCurrentDefaultSuffix }
    static var microphoneRefreshDevices: String { s.microphoneRefreshDevices }
    static func microphoneAutoDetect(_ name: String) -> String { s.microphoneAutoDetect(name) }
    static var settingsSystemSection: String { s.settingsSystemSection }
    static var launchAtLoginTitle: String { s.launchAtLoginTitle }
    static var launchAtLoginDesc: String { s.launchAtLoginDesc }
    static var launchAtLoginError: String { s.launchAtLoginError }
    static var settingsSoftwareUpdateSection: String { s.settingsSoftwareUpdateSection }
    static var settingsCheckUpdate: String { s.settingsCheckUpdate }
    static var settingsUpdateChecking: String { s.settingsUpdateChecking }
    static var settingsUpdateNoUpdate: String { s.settingsUpdateNoUpdate }
    static var settingsUpdateFound: String { s.settingsUpdateFound }
    static var settingsUpdateError: String { s.settingsUpdateError }
    static var settingsUpdateDevBuild: String { s.settingsUpdateDevBuild }
    static func settingsCurrentVersion(_ version: String, _ build: String) -> String { s.settingsCurrentVersion(version, build) }
    static var settingsFeedbackSection: String { s.settingsFeedbackSection }
    static var settingsTutorialSection: String { s.settingsTutorialSection }
    static var tutorialReplayTitle: String { s.tutorialReplayTitle }
    static var tutorialReplayDesc: String { s.tutorialReplayDesc }
    static var feedbackTitle: String { s.feedbackTitle }
    static var feedbackSettingsDesc: String { s.feedbackSettingsDesc }
    static var feedbackWindowDesc: String { s.feedbackWindowDesc }
    static var feedbackPlaceholder: String { s.feedbackPlaceholder }
    static var feedbackPhonePlaceholder: String { s.feedbackPhonePlaceholder }
    static var feedbackEmailPlaceholder: String { s.feedbackEmailPlaceholder }
    static var feedbackSubmitting: String { s.feedbackSubmitting }
    static var feedbackSubmit: String { s.feedbackSubmit }
    static var feedbackSuccess: String { s.feedbackSuccess }
    static var feedbackFailure: String { s.feedbackFailure }
    static var subscriptionSettingsSection: String { s.subscriptionSettingsSection }
    static var subscriptionEntryTitle: String { s.subscriptionEntryTitle }
    static var subscriptionEntryDesc: String { s.subscriptionEntryDesc }
    static var subscriptionPageTitle: String { s.subscriptionPageTitle }
    static var subscriptionPageSubtitle: String { s.subscriptionPageSubtitle }
    static var subscriptionCurrentPlan: String { s.subscriptionCurrentPlan }
    static var subscriptionAvailablePlans: String { s.subscriptionAvailablePlans }
    static var subscriptionBillingMonthly: String { s.subscriptionBillingMonthly }
    static var subscriptionSubscribe: String { s.subscriptionSubscribe }
    static var subscriptionCurrentPlanAction: String { s.subscriptionCurrentPlanAction }
    static var subscriptionLowerPlanAction: String { s.subscriptionLowerPlanAction }
    static var subscriptionUpgradeAction: String { s.subscriptionUpgradeAction }
    static var subscriptionUpgradeCreditNote: String { s.subscriptionUpgradeCreditNote }
    static var subscriptionTopupTitle: String { s.subscriptionTopupTitle }
    static var subscriptionTopupDesc: String { s.subscriptionTopupDesc }
    static var subscriptionTopupAction: String { s.subscriptionTopupAction }
    static var subscriptionTopupUnavailable: String { s.subscriptionTopupUnavailable }
    static var subscriptionLoading: String { s.subscriptionLoading }
    static var subscriptionLoadFailed: String { s.subscriptionLoadFailed }
    static var subscriptionCheckoutFailed: String { s.subscriptionCheckoutFailed }
    static func subscriptionCredits(_ count: Int) -> String { s.subscriptionCredits(count) }
    static func subscriptionPriceMonthly(_ price: String) -> String { s.subscriptionPriceMonthly(price) }
    static func subscriptionAutoRenewOn(_ date: String) -> String { s.subscriptionAutoRenewOn(date) }
    static var subscriptionAutoRenewManaged: String { s.subscriptionAutoRenewManaged }
    static var subscriptionCancelRenewalAction: String { s.subscriptionCancelRenewalAction }
    static var subscriptionCancelRenewalConfirmTitle: String { s.subscriptionCancelRenewalConfirmTitle }
    static func subscriptionCancelRenewalConfirmMessage(_ date: String) -> String { s.subscriptionCancelRenewalConfirmMessage(date) }
    static var subscriptionCancelRenewalConfirm: String { s.subscriptionCancelRenewalConfirm }
    static var subscriptionCancelRenewalKeep: String { s.subscriptionCancelRenewalKeep }
    static var subscriptionCancelRenewalFailed: String { s.subscriptionCancelRenewalFailed }

    // MARK: - Permissions
    static var permFullyAuthorized: String { s.permFullyAuthorized }
    static var permPartialAuth: String { s.permPartialAuth }
    static var permAllOk: String { s.permAllOk }
    static var permSomeMissing: String { s.permSomeMissing }
    static var permMicrophone: String { s.permMicrophone }
    static var permMicrophoneDesc: String { s.permMicrophoneDesc }
    static var permAccessibility: String { s.permAccessibility }
    static var permAccessibilityDesc: String { s.permAccessibilityDesc }
    static var permScreenCapture: String { s.permScreenCapture }
    static var permScreenCaptureDesc: String { s.permScreenCaptureDesc }
    static var permissionOptional: String { s.permissionOptional }
    static var permGoAuth: String { s.permGoAuth }

    // MARK: - Overlay
    static var overlayRecording: String { s.overlayRecording }
    static var overlayRecognizing: String { s.overlayRecognizing }
    static var overlayRealtimeListening: String { s.overlayRealtimeListening }
    static var overlayClarifyTitle: String { s.overlayClarifyTitle }
    static var overlayClarifyFallback: String { s.overlayClarifyFallback }
    static var overlayResultTitle: String { s.overlayResultTitle }
    static var overlaySearchTitle: String { s.overlaySearchTitle }
    static var historySearchResultHint: String { s.historySearchResultHint }
    static var btnViewInOverlay: String { s.btnViewInOverlay }
    static var badgeBeta: String { s.badgeBeta }
    static var badgeOfficial: String { s.badgeOfficial }
    /// 环境徽章：由 APIConfig.environment 派生，禁止在 UI 写死
    /// preview/dev → 内测版；uat/prod → 正式版
    static var envBadge: String {
        switch APIConfig.environment {
        case .preview, .dev: return s.badgeBeta
        case .uat, .prod:    return s.badgeOfficial
        }
    }
    static var overlayResultPinned: String { s.overlayResultPinned }
    static var btnPin: String { s.btnPin }
    static var btnUnpin: String { s.btnUnpin }
    static var screenshotCopied: String { s.screenshotCopied }
    static var screenshotCancelled: String { s.screenshotCancelled }
    static var screenshotFailed: String { s.screenshotFailed }
    static var screenshotNoImage: String { s.screenshotNoImage }
    static var screenshotPermissionRequired: String { s.screenshotPermissionRequired }
    static var screenshotScrollingTitle: String { s.screenshotScrollingTitle }
    static var screenshotScrollingDesc: String { s.screenshotScrollingDesc }
    static var screenshotScrollHint: String { s.screenshotScrollHint }
    static var screenshotScrollTooFast: String { s.screenshotScrollTooFast }
    static var screenshotScrollLimit: String { s.screenshotScrollLimit }
    static var screenshotScrollDone: String { s.screenshotScrollDone }
    static var screenshotScrollCancel: String { s.screenshotScrollCancel }

    // MARK: - Page Titles
    static var pageHome: String { s.pageHome }
    static var pageDict: String { s.pageDict }
    static var pagePersona: String { s.pagePersona }
    static var pageHistory: String { s.pageHistory }
    static var pageSettings: String { s.pageSettings }

    // MARK: - Section Labels
    static var sectionHotkeys: String { s.sectionHotkeys }
    static var sectionLatest: String { s.sectionLatest }
    static var sectionPermissions: String { s.sectionPermissions }
    static var sectionPrivacy: String { s.sectionPrivacy }
    static var labelTranscript: String { s.labelTranscript }
    static var labelResult: String { s.labelResult }

    // MARK: - Status Labels
    static var statusIdle: String { s.statusIdle }
    static var statusRec: String { s.statusRec }
    static var statusProc: String { s.statusProc }
    static var statusWait: String { s.statusWait }
    static var statusOk: String { s.statusOk }
    static var statusFail: String { s.statusFail }
    static var statusFailed: String { s.statusFailed }
    static var statusDenied: String { s.statusDenied }
    static var statusPending: String { s.statusPending }

    // MARK: - Buttons
    static var btnRefresh: String { s.btnRefresh }
    static var btnDone: String { s.btnDone }
    static var btnActivate: String { s.btnActivate }
    static var btnClone: String { s.btnClone }
    static var btnCopy: String { s.btnCopy }
    static var btnCopied: String { s.btnCopied }
    static var btnDelAudio: String { s.btnDelAudio }
    static var btnWarn: String { s.btnWarn }

    // MARK: - Form Labels
    static var labelName: String { s.labelName }
    static var labelPrompt: String { s.labelPrompt }

    // MARK: - Language
    static var languageLabel: String { s.languageLabel }
    static var themeSwitch: String { s.themeSwitch }
    static var themeLight: String { s.themeLight }
    static var themeDark: String { s.themeDark }
    static var themeAccent: String { s.themeAccent }

    // MARK: - Common
    static var cancel: String { s.cancel }
    static var delete: String { s.delete }
    static var save: String { s.save }
    static var add: String { s.add }
    static var manage: String { s.manage }
    static var loading: String { s.loading }
    static var loadMore: String { s.loadMore }
    static var retry: String { s.retry }
    static var crashUploadLoginRequired: String { s.crashUploadLoginRequired }

    static func confirmDeleteHotword(_ word: String) -> String { s.confirmDeleteHotword(word) }
    static func moreCount(_ n: Int) -> String { s.moreCount(n) }
    static func recCount(_ n: Int) -> String { s.recCount(n) }
    static func charCount(_ cur: Int, _ max: Int) -> String { s.charCount(cur, max) }
    static func crashUploadSuccess(_ count: Int) -> String { s.crashUploadSuccess(count) }
    static func crashUploadFailed(_ count: Int) -> String { s.crashUploadFailed(count) }
    static func crashUploadPartial(_ ok: Int, _ failed: Int) -> String { s.crashUploadPartial(ok, failed) }

    // MARK: - Error Messages
    static var errorUnknown: String { s.errorUnknown }
    static var errorDecode: String { s.errorDecode }
    static var errorNetwork: String { s.errorNetwork }
    static var errorUnauthorized: String { s.errorUnauthorized }
    static var errorUserCancelled: String { s.errorUserCancelled }
    static var errorInvalidAudio: String { s.errorInvalidAudio }
    static var errorCreditsExhausted: String { s.errorCreditsExhausted }
    static var errorUserBanned: String { s.errorUserBanned }

    // MARK: - Onboarding
    static var onboardingBack: String { s.onboardingBack }
    static var onboardingNext: String { s.onboardingNext }
    static var onboardingStart: String { s.onboardingStart }
    static var onboardingGrantFirst: String { s.onboardingGrantFirst }
    static var onboardingTryFirst: String { s.onboardingTryFirst }
    static var onboardingSkip: String { s.onboardingSkip }
    static var onboardingStepDone: String { s.onboardingStepDone }
    static var onboardingStepWaiting: String { s.onboardingStepWaiting }
    static var onboardingHowToUse: String { s.onboardingHowToUse }
    static var onboardingTips: String { s.onboardingTips }
    static var onboardingWelcomeTitle: String { s.onboardingWelcomeTitle }
    static var onboardingWelcomeDesc: String { s.onboardingWelcomeDesc }
    static var onboardingFeature1Title: String { s.onboardingFeature1Title }
    static var onboardingFeature1Desc: String { s.onboardingFeature1Desc }
    static var onboardingFeature2Title: String { s.onboardingFeature2Title }
    static var onboardingFeature2Desc: String { s.onboardingFeature2Desc }
    static var onboardingFeature3Title: String { s.onboardingFeature3Title }
    static var onboardingFeature3Desc: String { s.onboardingFeature3Desc }
    static var onboardingPermTitle: String { s.onboardingPermTitle }
    static var onboardingPermDesc: String { s.onboardingPermDesc }
    static var onboardingPermMicDesc: String { s.onboardingPermMicDesc }
    static var onboardingPermAXDesc: String { s.onboardingPermAXDesc }
    static var onboardingPermAllDone: String { s.onboardingPermAllDone }
    static var onboardingPermRefresh: String { s.onboardingPermRefresh }
    static var obTriFillTitle: String { s.obTriFillTitle }
    static var obTriFillSub: String { s.obTriFillSub }
    static var obTriFillFieldLabel: String { s.obTriFillFieldLabel }
    static var obTriFillPlaceholder: String { s.obTriFillPlaceholder }
    static var obTriFillI1: String { s.obTriFillI1 }
    static var obTriFillI2: String { s.obTriFillI2 }
    static var obTriFillI3: String { s.obTriFillI3 }
    static var obRwGenTitle: String { s.obRwGenTitle }
    static var obRwGenSub: String { s.obRwGenSub }
    static var obRwGenFieldLabel: String { s.obRwGenFieldLabel }
    static var obRwGenPlaceholder: String { s.obRwGenPlaceholder }
    static var obRwGenI1: String { s.obRwGenI1 }
    static var obRwGenI2: String { s.obRwGenI2 }
    static var obRwGenI3: String { s.obRwGenI3 }
    static var obRwRoTitle: String { s.obRwRoTitle }
    static var obRwRoSub: String { s.obRwRoSub }
    static var obRwRoSelectHint: String { s.obRwRoSelectHint }
    static var obRwRoSampleText: String { s.obRwRoSampleText }
    static var obRwRoI1: String { s.obRwRoI1 }
    static var obRwRoI2: String { s.obRwRoI2 }
    static var obRwRoI3: String { s.obRwRoI3 }
    static var obRwEdTitle: String { s.obRwEdTitle }
    static var obRwEdSub: String { s.obRwEdSub }
    static var obRwEdFieldLabel: String { s.obRwEdFieldLabel }
    static var obRwEdDefaultText: String { s.obRwEdDefaultText }
    static var obRwEdI1: String { s.obRwEdI1 }
    static var obRwEdI2: String { s.obRwEdI2 }
    static var obRwEdI3: String { s.obRwEdI3 }
    static var obAgSearchTitle: String { s.obAgSearchTitle }
    static var obAgSearchSub: String { s.obAgSearchSub }
    static var obAgSearchExampleLabel: String { s.obAgSearchExampleLabel }
    static var obAgSearchEx1: String { s.obAgSearchEx1 }
    static var obAgSearchEx2: String { s.obAgSearchEx2 }
    static var obAgSearchEx3: String { s.obAgSearchEx3 }
    static var obAgSearchI1: String { s.obAgSearchI1 }
    static var obAgSearchI2: String { s.obAgSearchI2 }
    static var obAgSearchI3: String { s.obAgSearchI3 }
    // Onboarding — screenshot OCR
    static var obScrTitle: String { s.obScrTitle }
    static var obScrSub: String { s.obScrSub }
    static var obScrSelectHint: String { s.obScrSelectHint }
    static var obScrSampleText: String { s.obScrSampleText }
    static var obScrPlaceholder: String { s.obScrPlaceholder }
    static func obScrI1(_ screenshotHotkey: String) -> String { s.obScrI1(screenshotHotkey) }
    static func obScrI2(_ rewriteHotkey: String) -> String { s.obScrI2(rewriteHotkey) }
    static var obScrI3: String { s.obScrI3 }
    static func obScrI4(_ rewriteHotkey: String) -> String { s.obScrI4(rewriteHotkey) }
    static func examplePhraseFormat(_ text: String) -> String { s.examplePhraseFormat(text) }
    static var onboardingCompleteTitle: String { s.onboardingCompleteTitle }
    static var onboardingCompleteDesc: String { s.onboardingCompleteDesc }

    // Invite code
    static var invitePageTitle: String { s.invitePageTitle }
    static var invitePageSubtitle: String { s.invitePageSubtitle }
    static var inviteWelcomeHeading: String { s.inviteWelcomeHeading }
    static var inviteBodyLine1: String { s.inviteBodyLine1 }
    static var inviteBodyLine2: String { s.inviteBodyLine2 }
    static var inviteCodePlaceholder: String { s.inviteCodePlaceholder }
    static var inviteSubmitBtn: String { s.inviteSubmitBtn }
    static var inviteBackBtn: String { s.inviteBackBtn }
    static var inviteSuccessHint: String { s.inviteSuccessHint }
    static var myInviteCodesTitle: String { s.myInviteCodesTitle }
    static var myInviteCodesDesc: String { s.myInviteCodesDesc }
    static var myInviteCodeUsed: String { s.myInviteCodeUsed }
    static var myInviteCodeUnused: String { s.myInviteCodeUnused }
    static var myInviteCodeUsedBy: String { s.myInviteCodeUsedBy }
    static var myInviteCodeCopied: String { s.myInviteCodeCopied }
    static var myInviteCodesBtn: String { s.myInviteCodesBtn }
    static var errorInvalidInviteCode: String { s.errorInvalidInviteCode }
    static var errorInviteSessionExpired: String { s.errorInviteSessionExpired }
    static var errorDeviceLimitReached: String { s.errorDeviceLimitReached }
    static var errorIpLimitReached: String { s.errorIpLimitReached }
    static var errorDisposableEmail: String { s.errorDisposableEmail }
    static var errorSendCodeTooFrequent: String { s.errorSendCodeTooFrequent }
    static var errorRegistrationDisabled: String { s.errorRegistrationDisabled }

    // MARK: - OpenClaw Integration
    static var openclawPromoTitle: String { s.openclawPromoTitle }
    static var openclawPromoDesc: String { s.openclawPromoDesc }
    static var openclawInstallBtn: String { s.openclawInstallBtn }
    static var openclawInstalledTitle: String { s.openclawInstalledTitle }
    static var openclawInstalledDesc: String { s.openclawInstalledDesc }
    static var openclawServiceDownTitle: String { s.openclawServiceDownTitle }
    static var openclawServiceDownDesc: String { s.openclawServiceDownDesc }
    static var openclawStartBtn: String { s.openclawStartBtn }
    static var openclawStartingGateway: String { s.openclawStartingGateway }
    static var openclawProcessing: String { s.openclawProcessing }
    static var openclawStopBtn: String { s.openclawStopBtn }
    static var openclawTipNotInstalled: String { s.openclawTipNotInstalled }
    static var openclawTipServiceDown: String { s.openclawTipServiceDown }
    static var openclawTipSessionStarted: String { s.openclawTipSessionStarted }
    static var openclawTipSessionEnded: String { s.openclawTipSessionEnded }
    static var openclawTipAlreadyActive: String { s.openclawTipAlreadyActive }
    static var openclawTipNewSessionStarted: String { s.openclawTipNewSessionStarted }
    static var openclawMinVersion: String { s.openclawMinVersion }
    static var openclawUninstallBtn: String { s.openclawUninstallBtn }

    // MARK: - Privacy / Clipboard
    static var clipboardAccessTitle: String { s.clipboardAccessTitle }
    static var clipboardAccessDesc: String { s.clipboardAccessDesc }

    // MARK: - Legal Agreements
    static var continueToAgree: String { s.continueToAgree }
    static var agreementTerms: String { s.agreementTerms }
    static var agreementPrivacy: String { s.agreementPrivacy }
    static var agreementAnd: String { s.agreementAnd }
    static var agreementLoading: String { s.agreementLoading }
    static var agreementLoadFailed: String { s.agreementLoadFailed }
    static var agreementClose: String { s.agreementClose }

    /// 将后端 tip action 返回的 code 码映射为国际化提示文案
    static func tipForCode(_ code: String) -> String {
        switch code {
        case "OPENCLAW_NOT_INSTALLED":  return s.openclawTipNotInstalled
        case "OPENCLAW_SERVICE_DOWN":   return s.openclawTipServiceDown
        case "OPENCLAW_SESSION_STARTED":return s.openclawTipSessionStarted
        case "OPENCLAW_SESSION_ENDED":  return s.openclawTipSessionEnded
        case "OPENCLAW_ALREADY_ACTIVE": return s.openclawTipAlreadyActive
        case "OPENCLAW_NEW_SESSION_STARTED": return s.openclawTipNewSessionStarted
        default:                        return code
        }
    }

    // MARK: - Menu Bar
    static var menuShowMain: String { s.menuShowMain }
    static var menuQuit: String { s.menuQuit }
    static var menuPermissions: String { s.menuPermissions }
    static var menuCheckUpdate: String { s.menuCheckUpdate }
    static var menuChecking: String { s.menuChecking }
    static var menuDownloading: String { s.menuDownloading }
    static var menuCrashUploading: String { s.menuCrashUploading }
    static var menuCrashNoLog: String { s.menuCrashNoLog }
    static func menuCrashUpload(_ count: Int) -> String { s.menuCrashUpload(count) }

    static func errorForCode(_ code: String) -> String {
        switch code {
        case "UNAUTHORIZED":          return s.errorUnauthorized
        case "INVALID_AUDIO":         return s.errorInvalidAudio
        case "DURATION_EXCEEDED":     return s.errorDurationExceeded
        case "UNSUPPORTED_OPERATION": return s.errorUnsupportedOp
        case "PROVIDER_ERROR":        return s.errorProviderError
        case "INVALID_CODE":          return s.errorInvalidCode
        case "HOTWORD_DUPLICATE":     return s.errorHotwordDuplicate
        case "HOTWORD_NOT_FOUND":     return s.errorHotwordNotFound
        case "HOTWORD_LIMIT_REACHED": return s.errorHotwordLimit
        case "SHORTCUT_NOT_FOUND":    return s.errorShortcutNotFound
        case "USER_CANCELLED":        return s.errorUserCancelled
        case "INVALID_INVITE_CODE":   return s.errorInvalidInviteCode
        case "INVITE_SESSION_EXPIRED": return s.errorInviteSessionExpired
        case "DEVICE_LIMIT_REACHED":  return s.errorDeviceLimitReached
        case "IP_LIMIT_REACHED", "REG_LIMIT_REACHED": return s.errorIpLimitReached
        case "DISPOSABLE_EMAIL":      return s.errorDisposableEmail
        case "SEND_CODE_TOO_FREQUENT": return s.errorSendCodeTooFrequent
        case "REGISTRATION_DISABLED": return s.errorRegistrationDisabled
        case "REGISTRATION_CLOSED":   return s.errorRegistrationClosed
        case "OPENCLAW_NOT_INSTALLED":return s.openclawTipNotInstalled
        case "OPENCLAW_SERVICE_DOWN": return s.openclawTipServiceDown
        case "CREDITS_EXHAUSTED":     return s.errorCreditsExhausted
        case "SERVICE_TEMPORARILY_UNAVAILABLE": return s.errorProviderError
        case "USER_BANNED":           return s.errorUserBanned
        default:                      return s.errorUnknown
        }
    }
}
