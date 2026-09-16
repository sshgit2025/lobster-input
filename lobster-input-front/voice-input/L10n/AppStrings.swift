/// AppStrings.swift
/// 文案协议，所有语言文件必须实现此协议。
import Foundation

protocol AppStrings {
    // Sidebar
    var sidebarHome: String { get }
    var sidebarDict: String { get }
    var sidebarPersona: String { get }
    var sidebarHistory: String { get }
    var sidebarSettings: String { get }
    var appNameShort: String { get }
    var appNameFull: String { get }
    var notLoggedIn: String { get }
    var logout: String { get }
    var permManage: String { get }
    var permUnauthorized: String { get }

    // Home
    var systemReady: String { get }
    var recording: String { get }
    var processing: String { get }
    var subtitleIdle: String { get }
    var subtitleRecording: String { get }
    var subtitleProcessing: String { get }
    var hotkeyTranscribe: String { get }
    var hotkeyRewrite: String { get }
    var hotkeyAgent: String { get }
    var recognizing: String { get }
    var recognizeFailed: String { get }

    // Auth
    var authSubtitle: String { get }
    var emailPlaceholder: String { get }
    var codePlaceholder: String { get }
    var resendCode: String { get }
    var sendCode: String { get }
    var verifyAccess: String { get }
    var enterEmail: String { get }
    var enterCode: String { get }

    // Dictionary
    var dictDesc: String { get }
    var dictEmpty: String { get }
    var dictNoResult: String { get }
    var dictSearchPlaceholder: String { get }
    var dictStandardWord: String { get }
    var dictPlaceholder: String { get }
    var editHotword: String { get }
    var newHotword: String { get }
    func dictPageInfo(_ cur: Int, _ total: Int) -> String

    // Persona
    var personaPageDesc: String { get }
    var personaNewPersona: String { get }
    var personaNameLabel: String { get }
    var personaNamePlaceholder: String { get }
    var personaDescLabel: String { get }
    var personaDescPlaceholder: String { get }
    var personaActivated: String { get }
    var personaNotActivated: String { get }
    var personaActivateBtn: String { get }
    var menuPersona: String { get }
    var personaMenuNone: String { get }
    var personaMenuEmpty: String { get }
    var personaDeactivateBtn: String { get }
    var personaCountHint: String { get }
    var personaLimitReached: String { get }
    var personaTranscribeTitle: String { get }
    var personaTranscribeDesc: String { get }
    var personaTranscribePlaceholder: String { get }
    var personaRewriteTitle: String { get }
    var personaRewriteDesc: String { get }
    var personaRewritePlaceholder: String { get }
    var personaIntentTitle: String { get }
    var personaIntentDesc: String { get }
    var personaIntentPlaceholder: String { get }
    var personaCustomized: String { get }
    var personaUsingBuiltin: String { get }
    var personaClearToBuiltin: String { get }
    var personaReset: String { get }
    var personaActive: String { get }
    var personaEnableHint: String { get }
    var personaDisableHint: String { get }

    // History
    var noRecords: String { get }
    var noResult: String { get }
    var deleteConfirm: String { get }
    var deleteRecordAndAudio: String { get }
    var deleteRecordOnly: String { get }
    var opTranscribe: String { get }
    var opRewrite: String { get }
    var opAgent: String { get }
    var historySaveTitle: String { get }
    var historySaveSubtitle: String { get }
    var historyPrivacyTitle: String { get }
    var historyPrivacySubtitle: String { get }
    var historyRetentionForever: String { get }
    var historyRetention30Days: String { get }
    var historyRetention7Days: String { get }
    var historyRetention1Day: String { get }
    var historyRetentionNever: String { get }

    // Account Panel
    var accountTitle: String { get }
    var accountEmail: String { get }
    var accountTier: String { get }
    var tierTrial: String { get }
    var planTrial: String { get }
    var planFree: String { get }
    var planWeekly: String { get }
    var planMonthly: String { get }
    var planYearly: String { get }
    var planLite: String { get }
    var planStandard: String { get }
    var planPro: String { get }
    var tierNone: String { get }
    var accountCredits: String { get }
    var accountCreditsReset: String { get }
    var accountCreditsUsed: String { get }
    var accountCreditsDetailsShow: String { get }
    var accountCreditsDetailsHide: String { get }
    var creditItemBonus: String { get }
    var creditItemPaidTopup: String { get }
    var creditItemNoExpiry: String { get }
    func creditItemExpires(_ date: String) -> String
    func creditsResetDateLabel(_ date: String) -> String
    var errorRegistrationClosed: String { get }

    // Settings
    var hotkeyVoiceInput: String { get }
    var hotkeyVoiceInputDesc: String { get }
    var hotkeyRewriteTitle: String { get }
    var hotkeyRewriteDesc: String { get }
    var hotkeyAgentTitle: String { get }
    var hotkeyAgentDesc: String { get }
    var hotkeyScreenshotTitle: String { get }
    var hotkeyScreenshotDesc: String { get }
    var transcribeFastModeTitle: String { get }
    var transcribeFastModeDesc: String { get }
    var realtimeRecognitionTitle: String { get }
    var realtimeRecognitionDesc: String { get }
    var screenshotConfirmationTitle: String { get }
    var screenshotConfirmationDesc: String { get }
    var pressHotkeyHint: String { get }
    var pressNewHotkey: String { get }
    var hotkeyNotSet: String { get }
    var hotkeyConflictDuplicate: String { get }
    var hotkeyConflictSystemReserved: String { get }
    var hotkeyConflictSystemWarning: String { get }
    var settingsMicrophoneSection: String { get }
    var microphoneInputTitle: String { get }
    var microphoneInputDesc: String { get }
    var microphoneMenuTitle: String { get }
    var microphoneCurrentDefaultSuffix: String { get }
    var microphoneRefreshDevices: String { get }
    func microphoneAutoDetect(_ name: String) -> String
    var settingsSystemSection: String { get }
    var launchAtLoginTitle: String { get }
    var launchAtLoginDesc: String { get }
    var launchAtLoginError: String { get }
    var settingsSoftwareUpdateSection: String { get }
    var settingsCheckUpdate: String { get }
    var settingsUpdateChecking: String { get }
    var settingsUpdateNoUpdate: String { get }
    var settingsUpdateFound: String { get }
    var settingsUpdateError: String { get }
    var settingsUpdateDevBuild: String { get }
    func settingsCurrentVersion(_ version: String, _ build: String) -> String
    var settingsFeedbackSection: String { get }
    var settingsTutorialSection: String { get }
    var tutorialReplayTitle: String { get }
    var tutorialReplayDesc: String { get }
    var feedbackTitle: String { get }
    var feedbackSettingsDesc: String { get }
    var feedbackWindowDesc: String { get }
    var feedbackPlaceholder: String { get }
    var feedbackPhonePlaceholder: String { get }
    var feedbackEmailPlaceholder: String { get }
    var feedbackSubmitting: String { get }
    var feedbackSubmit: String { get }
    var feedbackSuccess: String { get }
    var feedbackFailure: String { get }
    var subscriptionSettingsSection: String { get }
    var subscriptionEntryTitle: String { get }
    var subscriptionEntryDesc: String { get }
    var subscriptionPageTitle: String { get }
    var subscriptionPageSubtitle: String { get }
    var subscriptionCurrentPlan: String { get }
    var subscriptionAvailablePlans: String { get }
    var subscriptionBillingMonthly: String { get }
    var subscriptionSubscribe: String { get }
    var subscriptionCurrentPlanAction: String { get }
    var subscriptionLowerPlanAction: String { get }
    var subscriptionUpgradeAction: String { get }
    var subscriptionUpgradeCreditNote: String { get }
    var subscriptionTopupTitle: String { get }
    var subscriptionTopupDesc: String { get }
    var subscriptionTopupAction: String { get }
    var subscriptionTopupUnavailable: String { get }
    var subscriptionLoading: String { get }
    var subscriptionLoadFailed: String { get }
    var subscriptionCheckoutFailed: String { get }
    func subscriptionCredits(_ count: Int) -> String
    func subscriptionPriceMonthly(_ price: String) -> String
    func subscriptionAutoRenewOn(_ date: String) -> String
    var subscriptionAutoRenewManaged: String { get }
    var subscriptionCancelRenewalAction: String { get }
    var subscriptionCancelRenewalConfirmTitle: String { get }
    func subscriptionCancelRenewalConfirmMessage(_ date: String) -> String
    var subscriptionCancelRenewalConfirm: String { get }
    var subscriptionCancelRenewalKeep: String { get }
    var subscriptionCancelRenewalFailed: String { get }

    // Permissions
    var permFullyAuthorized: String { get }
    var permPartialAuth: String { get }
    var permAllOk: String { get }
    var permSomeMissing: String { get }
    var permMicrophone: String { get }
    var permMicrophoneDesc: String { get }
    var permAccessibility: String { get }
    var permAccessibilityDesc: String { get }
    var permScreenCapture: String { get }
    var permScreenCaptureDesc: String { get }
    var permissionOptional: String { get }
    var permGoAuth: String { get }

    // Overlay
    var overlayRecording: String { get }
    var overlayRecognizing: String { get }
    var overlayRealtimeListening: String { get }
    var overlayClarifyTitle: String { get }    // clarify 浮窗标题
    var overlayClarifyFallback: String { get } // 无 clarify_question 时的默认提示文案
    var overlayResultTitle: String { get }     // 结果展示浮窗标题
    var overlaySearchTitle: String { get }     // 搜索结果浮窗标题
    var historySearchResultHint: String { get } // 历史记录中搜索结果折叠提示
    var btnViewInOverlay: String { get }        // 在浮窗中查看按钮
    var badgeBeta: String { get }              // 环境徽章：内测版（preview 环境）
    var badgeOfficial: String { get }          // 环境徽章：正式版（uat 环境）
    var overlayResultPinned: String { get }    // 已常驻提示文字
    var btnPin: String { get }                 // 常驻按钮（取消自动关闭）
    var btnUnpin: String { get }               // 取消常驻按钮
    var screenshotCopied: String { get }
    var screenshotCancelled: String { get }
    var screenshotFailed: String { get }
    var screenshotNoImage: String { get }
    var screenshotPermissionRequired: String { get }
    var screenshotScrollingTitle: String { get }
    var screenshotScrollingDesc: String { get }
    var screenshotScrollHint: String { get }
    var screenshotScrollTooFast: String { get }
    var screenshotScrollLimit: String { get }
    var screenshotScrollDone: String { get }
    var screenshotScrollCancel: String { get }

    // Page Titles
    var pageHome: String { get }
    var pageDict: String { get }
    var pagePersona: String { get }
    var pageHistory: String { get }
    var pageSettings: String { get }

    // Section Labels
    var sectionHotkeys: String { get }
    var sectionLatest: String { get }
    var sectionPermissions: String { get }
    var sectionPrivacy: String { get }
    var labelTranscript: String { get }
    var labelResult: String { get }

    // Status Labels
    var statusIdle: String { get }
    var statusRec: String { get }
    var statusProc: String { get }
    var statusWait: String { get }
    var statusOk: String { get }
    var statusFail: String { get }
    var statusFailed: String { get }
    var statusDenied: String { get }
    var statusPending: String { get }

    // Buttons
    var btnRefresh: String { get }
    var btnDone: String { get }
    var btnActivate: String { get }
    var btnClone: String { get }
    var btnCopy: String { get }
    var btnCopied: String { get }
    var btnDelAudio: String { get }
    var btnWarn: String { get }

    // Persona Labels (removed - legacy)

    // Form Labels
    var labelName: String { get }
    var labelPrompt: String { get }

    // Language
    var languageLabel: String { get }
    var themeSwitch: String { get }
    var themeLight: String { get }
    var themeDark: String { get }
    var themeAccent: String { get }

    // Common
    var cancel: String { get }
    var delete: String { get }
    var save: String { get }
    var add: String { get }
    var manage: String { get }
    var loading: String { get }
    var loadMore: String { get }
    var retry: String { get }
    var crashUploadLoginRequired: String { get }

    func confirmDeleteHotword(_ word: String) -> String
    func moreCount(_ n: Int) -> String
    func recCount(_ n: Int) -> String
    func charCount(_ cur: Int, _ max: Int) -> String
    func crashUploadSuccess(_ count: Int) -> String
    func crashUploadFailed(_ count: Int) -> String
    func crashUploadPartial(_ ok: Int, _ failed: Int) -> String

    // Error Messages (mapped from backend error codes)
    var errorUnknown: String { get }
    var errorDecode: String { get }
    var errorNetwork: String { get }
    var errorUnauthorized: String { get }
    var errorUserCancelled: String { get }
    var errorInvalidAudio: String { get }
    var errorDurationExceeded: String { get }
    var errorUnsupportedOp: String { get }
    var errorProviderError: String { get }
    var errorInvalidCode: String { get }
    var errorHotwordDuplicate: String { get }
    var errorHotwordNotFound: String { get }
    var errorHotwordLimit: String { get }
    var errorShortcutNotFound: String { get }
    var errorCreditsExhausted: String { get }
    var errorUserBanned: String { get }

    // Onboarding — common
    var onboardingBack: String { get }
    var onboardingNext: String { get }
    var onboardingStart: String { get }
    var onboardingGrantFirst: String { get }
    var onboardingTryFirst: String { get }
    var onboardingSkip: String { get }
    var onboardingStepDone: String { get }
    var onboardingStepWaiting: String { get }
    var onboardingHowToUse: String { get }
    var onboardingTips: String { get }
    // Onboarding — welcome
    var onboardingWelcomeTitle: String { get }
    var onboardingWelcomeDesc: String { get }
    var onboardingFeature1Title: String { get }
    var onboardingFeature1Desc: String { get }
    var onboardingFeature2Title: String { get }
    var onboardingFeature2Desc: String { get }
    var onboardingFeature3Title: String { get }
    var onboardingFeature3Desc: String { get }
    // Onboarding — permissions
    var onboardingPermTitle: String { get }
    var onboardingPermDesc: String { get }
    var onboardingPermMicDesc: String { get }
    var onboardingPermAXDesc: String { get }
    var onboardingPermAllDone: String { get }
    var onboardingPermRefresh: String { get }
    // Onboarding — transcribe fill (inline field)
    var obTriFillTitle: String { get }
    var obTriFillSub: String { get }
    var obTriFillFieldLabel: String { get }
    var obTriFillPlaceholder: String { get }
    var obTriFillI1: String { get }
    var obTriFillI2: String { get }
    var obTriFillI3: String { get }
    // Onboarding — rewrite generate (inline field)
    var obRwGenTitle: String { get }
    var obRwGenSub: String { get }
    var obRwGenFieldLabel: String { get }
    var obRwGenPlaceholder: String { get }
    var obRwGenI1: String { get }
    var obRwGenI2: String { get }
    var obRwGenI3: String { get }
    // Onboarding — rewrite readonly (inline readonly sample)
    var obRwRoTitle: String { get }
    var obRwRoSub: String { get }
    var obRwRoSelectHint: String { get }
    var obRwRoSampleText: String { get }
    var obRwRoI1: String { get }
    var obRwRoI2: String { get }
    var obRwRoI3: String { get }
    // Onboarding — rewrite editable (inline editable field with default text)
    var obRwEdTitle: String { get }
    var obRwEdSub: String { get }
    var obRwEdFieldLabel: String { get }
    var obRwEdDefaultText: String { get }
    var obRwEdI1: String { get }
    var obRwEdI2: String { get }
    var obRwEdI3: String { get }
    // Onboarding — agent search (example phrases)
    var obAgSearchTitle: String { get }
    var obAgSearchSub: String { get }
    var obAgSearchExampleLabel: String { get }
    var obAgSearchEx1: String { get }
    var obAgSearchEx2: String { get }
    var obAgSearchEx3: String { get }
    var obAgSearchI1: String { get }
    var obAgSearchI2: String { get }
    var obAgSearchI3: String { get }
    // Onboarding — screenshot OCR
    var obScrTitle: String { get }
    var obScrSub: String { get }
    var obScrSelectHint: String { get }
    var obScrSampleText: String { get }
    var obScrPlaceholder: String { get }
    func obScrI1(_ screenshotHotkey: String) -> String
    func obScrI2(_ rewriteHotkey: String) -> String
    var obScrI3: String { get }
    func obScrI4(_ rewriteHotkey: String) -> String
    func examplePhraseFormat(_ text: String) -> String
    // Onboarding — complete
    var onboardingCompleteTitle: String { get }
    var onboardingCompleteDesc: String { get }

    var errorInvalidInviteCode: String { get }
    var errorInviteSessionExpired: String { get }
    var errorDeviceLimitReached: String { get }
    var errorIpLimitReached: String { get }
    var errorDisposableEmail: String { get }
    var errorSendCodeTooFrequent: String { get }
    var errorRegistrationDisabled: String { get }

    // Invite Code (temporary beta access control)
    var invitePageTitle: String { get }
    var invitePageSubtitle: String { get }
    var inviteWelcomeHeading: String { get }
    var inviteBodyLine1: String { get }
    var inviteBodyLine2: String { get }
    var inviteCodePlaceholder: String { get }
    var inviteSubmitBtn: String { get }
    var inviteBackBtn: String { get }
    var inviteSuccessHint: String { get }

    // My Invite Codes panel
    var myInviteCodesTitle: String { get }
    var myInviteCodesDesc: String { get }
    var myInviteCodeUsed: String { get }
    var myInviteCodeUnused: String { get }
    var myInviteCodeUsedBy: String { get }
    var myInviteCodeCopied: String { get }
    var myInviteCodesBtn: String { get }

    // Menu Bar
    var menuShowMain: String { get }
    var menuQuit: String { get }
    var menuPermissions: String { get }
    var menuCheckUpdate: String { get }
    var menuChecking: String { get }
    var menuDownloading: String { get }
    var menuCrashUploading: String { get }
    var menuCrashNoLog: String { get }
    func menuCrashUpload(_ count: Int) -> String

    // OpenClaw Integration
    var openclawPromoTitle: String { get }
    var openclawPromoDesc: String { get }
    var openclawInstallBtn: String { get }
    var openclawInstalledTitle: String { get }
    var openclawInstalledDesc: String { get }
    var openclawServiceDownTitle: String { get }
    var openclawServiceDownDesc: String { get }
    var openclawStartBtn: String { get }
    var openclawStartingGateway: String { get }
    var openclawProcessing: String { get }
    var openclawStopBtn: String { get }
    var openclawTipNotInstalled: String { get }
    var openclawTipServiceDown: String { get }
    var openclawTipSessionStarted: String { get }
    var openclawTipSessionEnded: String { get }
    var openclawTipAlreadyActive: String { get }
    var openclawTipNewSessionStarted: String { get }
    var openclawMinVersion: String { get }
    var openclawUninstallBtn: String { get }

    // Privacy / Clipboard
    var clipboardAccessTitle: String { get }
    var clipboardAccessDesc: String { get }

    // Legal Agreements
    var continueToAgree: String { get }
    var agreementTerms: String { get }
    var agreementPrivacy: String { get }
    var agreementAnd: String { get }
    var agreementLoading: String { get }
    var agreementLoadFailed: String { get }
    var agreementClose: String { get }
}
