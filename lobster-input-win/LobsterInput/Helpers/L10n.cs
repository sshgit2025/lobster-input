using LobsterInput.Config;
using LobsterInput.Localization;

namespace LobsterInput.Helpers;

public static class L10n
{
    private static string Get(string key) =>
        LocalizationRegistry.Default.Get(LanguageManager.Instance.Current, key);

    // Sidebar
    public static string SidebarHome => Get("sidebarHome");
    public static string SidebarDict => Get("sidebarDict");
    public static string SidebarPersona => Get("sidebarPersona");
    public static string SidebarHistory => Get("sidebarHistory");
    public static string SidebarSettings => Get("sidebarSettings");
    public static string AppNameShort => Get("appNameShort");
    public static string AppNameFull => Get("appNameFull");

    // 环境徽章:必须由 ApiConfig.EnvName 派生,禁止写死
    public static string EnvBadgeBeta => Get("envBadgeBeta");
    public static string EnvBadgeOfficial => Get("envBadgeOfficial");
    public static string EnvBadge => ApiConfig.EnvName switch
    {
        "uat" => EnvBadgeOfficial,
        "preview" => EnvBadgeBeta,
        _ => string.Empty
    };
    public static string NotLoggedIn => Get("notLoggedIn");
    public static string Logout => Get("logout");

    // Home
    public static string SystemReady => Get("systemReady");
    public static string Recording => Get("recording");
    public static string RecordingStartFailed => Get("recordingStartFailed");
    public static string Processing => Get("processing");
    public static string SubtitleIdle => Get("subtitleIdle");
    public static string SubtitleRecording => Get("subtitleRecording");
    public static string SubtitleProcessing => Get("subtitleProcessing");
    public static string HotkeyTranscribe => Get("hotkeyTranscribe");
    public static string HotkeyRewrite => Get("hotkeyRewrite");
    public static string HotkeyAgent => Get("hotkeyAgent");
    public static string Recognizing => Get("recognizing");
    public static string RecognizeFailed => Get("recognizeFailed");

    // Auth
    public static string AuthSubtitle => Get("authSubtitle");
    public static string EmailPlaceholder => Get("emailPlaceholder");
    public static string CodePlaceholder => Get("codePlaceholder");
    public static string ResendCode => Get("resendCode");
    public static string SendCode => Get("sendCode");
    public static string VerifyAccess => Get("verifyAccess");
    public static string EnterEmail => Get("enterEmail");
    public static string EnterCode => Get("enterCode");

    // Dictionary
    public static string DictDesc => Get("dictDesc");
    public static string DictEmpty => Get("dictEmpty");
    public static string DictNoResult => Get("dictNoResult");
    public static string DictSearchPlaceholder => Get("dictSearchPlaceholder");
    public static string DictStandardWord => Get("dictStandardWord");
    public static string DictPlaceholder => Get("dictPlaceholder");
    public static string EditHotword => Get("editHotword");
    public static string NewHotword => Get("newHotword");

    // Persona
    public static string PersonaPageDesc => Get("personaPageDesc");
    public static string PersonaNewPersona => Get("personaNewPersona");
    public static string PersonaNameLabel => Get("personaNameLabel");
    public static string PersonaNamePlaceholder => Get("personaNamePlaceholder");
    public static string PersonaDescLabel => Get("personaDescLabel");
    public static string PersonaDescPlaceholder => Get("personaDescPlaceholder");
    public static string PersonaActivated => Get("personaActivated");
    public static string PersonaNotActivated => Get("personaNotActivated");
    public static string PersonaActivateBtn => Get("personaActivateBtn");
    public static string PersonaDeactivateBtn => Get("personaDeactivateBtn");
    public static string PersonaTranscribeTitle => Get("personaTranscribeTitle");
    public static string PersonaTranscribeDesc => Get("personaTranscribeDesc");
    public static string PersonaTranscribePlaceholder => Get("personaTranscribePlaceholder");
    public static string PersonaRewriteTitle => Get("personaRewriteTitle");
    public static string PersonaRewriteDesc => Get("personaRewriteDesc");
    public static string PersonaRewritePlaceholder => Get("personaRewritePlaceholder");
    public static string PersonaIntentTitle => Get("personaIntentTitle");
    public static string PersonaIntentDesc => Get("personaIntentDesc");
    public static string PersonaIntentPlaceholder => Get("personaIntentPlaceholder");
    public static string PersonaCustomized => Get("personaCustomized");
    public static string PersonaUsingBuiltin => Get("personaUsingBuiltin");
    public static string PersonaClearToBuiltin => Get("personaClearToBuiltin");
    public static string PersonaReset => Get("personaReset");
    public static string PersonaActive => Get("personaActive");
    public static string PersonaEnableHint => Get("personaEnableHint");
    public static string PersonaDisableHint => Get("personaDisableHint");

    // History
    public static string NoRecords => Get("noRecords");
    public static string NoResult => Get("noResult");
    public static string DeleteConfirm => Get("deleteConfirm");
    public static string DeleteRecordAndAudio => Get("deleteRecordAndAudio");
    public static string DeleteRecordOnly => Get("deleteRecordOnly");
    public static string OpTranscribe => Get("opTranscribe");
    public static string OpRewrite => Get("opRewrite");
    public static string OpAgent => Get("opAgent");
    public static string HistorySaveTitle => Get("historySaveTitle");
    public static string HistorySaveSubtitle => Get("historySaveSubtitle");
    public static string HistoryPrivacyTitle => Get("historyPrivacyTitle");
    public static string HistoryPrivacySubtitle => Get("historyPrivacySubtitle");
    public static string HistoryRetentionForever => Get("historyRetentionForever");
    public static string HistoryRetention30Days => Get("historyRetention30Days");
    public static string HistoryRetention7Days => Get("historyRetention7Days");
    public static string HistoryRetention1Day => Get("historyRetention1Day");
    public static string HistoryRetentionNever => Get("historyRetentionNever");

    // Account Panel
    public static string AccountTitle => Get("accountTitle");
    public static string AccountEmail => Get("accountEmail");
    public static string AccountTier => Get("accountTier");
    public static string TierTrial => Get("tierTrial");
    public static string PlanTrial => Get("planTrial");
    public static string PlanFree => Get("planFree");
    public static string PlanWeekly => Get("planWeekly");
    public static string PlanMonthly => Get("planMonthly");
    public static string PlanYearly => Get("planYearly");
    public static string TierNone => Get("tierNone");
    public static string AccountCredits => Get("accountCredits");
    public static string AccountCreditsReset => Get("accountCreditsReset");
    public static string AccountCreditsUsed => Get("accountCreditsUsed");
    public static string AccountCreditsDetailsShow => Get("accountCreditsDetailsShow");
    public static string AccountCreditsDetailsHide => Get("accountCreditsDetailsHide");
    public static string CreditItemBonus => Get("creditItemBonus");
    public static string CreditItemPaidTopup => Get("creditItemPaidTopup");
    public static string CreditItemNoExpiry => Get("creditItemNoExpiry");
    public static string ErrorRegistrationDisabled => Get("errorRegistrationDisabled");
    public static string ErrorRegistrationClosed => Get("errorRegistrationClosed");

    // Settings
    public static string HotkeyVoiceInput => Get("hotkeyVoiceInput");
    public static string HotkeyVoiceInputDesc => Get("hotkeyVoiceInputDesc");
    public static string HotkeyRewriteTitle => Get("hotkeyRewriteTitle");
    public static string HotkeyRewriteDesc => Get("hotkeyRewriteDesc");
    public static string HotkeyAgentTitle => Get("hotkeyAgentTitle");
    public static string HotkeyAgentDesc => Get("hotkeyAgentDesc");
    public static string HotkeyScreenshotTitle => Get("hotkeyScreenshotTitle");
    public static string HotkeyScreenshotDesc => Get("hotkeyScreenshotDesc");
    public static string ScreenshotConfirmationTitle => Get("screenshotConfirmationTitle");
    public static string ScreenshotConfirmationDesc => Get("screenshotConfirmationDesc");
    public static string StartupLaunchTitle => Get("startupLaunchTitle");
    public static string StartupLaunchDesc => Get("startupLaunchDesc");
    public static string ClearHotkey => Get("clearHotkey");
    public static string PressHotkeyHint => Get("pressHotkeyHint");
    public static string PressNewHotkey => Get("pressNewHotkey");
    public static string HotkeyNotSet => Get("hotkeyNotSet");
    public static string SettingsMicrophoneSection => Get("settingsMicrophoneSection");
    public static string SettingsSoftwareUpdateSection => Get("settingsSoftwareUpdateSection");
    public static string SettingsWindowsOptionsSection => Get("settingsWindowsOptionsSection");
    public static string MicrophoneInputTitle => Get("microphoneInputTitle");
    public static string MicrophoneInputDesc => Get("microphoneInputDesc");
    public static string MicrophoneMenuTitle => Get("microphoneMenuTitle");
    public static string MicrophoneCurrentDefaultSuffix => Get("microphoneCurrentDefaultSuffix");
    public static string MicrophoneRefreshDevices => Get("microphoneRefreshDevices");
    public static string SettingsFeedbackSection => Get("settingsFeedbackSection");
    public static string SettingsTutorialSection => Get("settingsTutorialSection");
    public static string TutorialReplayTitle => Get("tutorialReplayTitle");
    public static string TutorialReplayDesc => Get("tutorialReplayDesc");
    public static string SettingsAboutSection => Get("settingsAboutSection");
    public static string FeedbackSettingsDesc => Get("feedbackSettingsDesc");
    public static string FeedbackWindowDesc => Get("feedbackWindowDesc");
    public static string FeedbackPhonePlaceholder => Get("feedbackPhonePlaceholder");
    public static string FeedbackEmailPlaceholder => Get("feedbackEmailPlaceholder");
    public static string FeedbackSubmitting => Get("feedbackSubmitting");
    public static string FeedbackSuccess => Get("feedbackSuccess");
    public static string FeedbackFailure => Get("feedbackFailure");
    public static string SubscriptionSettingsSection => Get("subscriptionSettingsSection");
    public static string SubscriptionEntryTitle => Get("subscriptionEntryTitle");
    public static string SubscriptionEntryDesc => Get("subscriptionEntryDesc");
    public static string SubscriptionPageTitle => Get("subscriptionPageTitle");
    public static string SubscriptionPageSubtitle => Get("subscriptionPageSubtitle");
    public static string SubscriptionCurrentPlan => Get("subscriptionCurrentPlan");
    public static string SubscriptionAvailablePlans => Get("subscriptionAvailablePlans");
    public static string SubscriptionSubscribe => Get("subscriptionSubscribe");
    public static string SubscriptionCurrentPlanAction => Get("subscriptionCurrentPlanAction");
    public static string SubscriptionLowerPlanAction => Get("subscriptionLowerPlanAction");
    public static string SubscriptionUpgradeProrated => Get("subscriptionUpgradeProrated");
    public static string SubscriptionProratedNote => Get("subscriptionProratedNote");
    public static string SubscriptionTopupTitle => Get("subscriptionTopupTitle");
    public static string SubscriptionTopupDesc => Get("subscriptionTopupDesc");
    public static string SubscriptionTopupAction => Get("subscriptionTopupAction");
    public static string SubscriptionTopupUnavailable => Get("subscriptionTopupUnavailable");
    public static string SubscriptionLoading => Get("subscriptionLoading");
    public static string SubscriptionLoadFailed => Get("subscriptionLoadFailed");
    public static string SubscriptionCheckoutFailed => Get("subscriptionCheckoutFailed");
    public static string SubscriptionCheckoutOpened => Get("subscriptionCheckoutOpened");
    public static string SubscriptionAutoRenewOnNoDate => Get("subscriptionAutoRenewOnNoDate");
    public static string SubscriptionAutoRenewManaged => Get("subscriptionAutoRenewManaged");
    public static string SubscriptionCancelRenewal => Get("subscriptionCancelRenewal");
    public static string SubscriptionCancelRenewalConfirmNoDate => Get("subscriptionCancelRenewalConfirmNoDate");
    public static string SubscriptionCancelRenewalSuccess => Get("subscriptionCancelRenewalSuccess");
    public static string SubscriptionCancelRenewalFailed => Get("subscriptionCancelRenewalFailed");

    // Overlay
    public static string OverlayRecording => Get("overlayRecording");
    public static string OverlayRecognizing => Get("overlayRecognizing");
    public static string OverlayClarifyTitle => Get("overlayClarifyTitle");
    public static string OverlayClarifyFallback => Get("overlayClarifyFallback");
    public static string OverlayResultTitle => Get("overlayResultTitle");
    public static string OverlaySearchTitle => Get("overlaySearchTitle");
    public static string OverlayResultPinned => Get("overlayResultPinned");
    public static string BtnPin => Get("btnPin");
    public static string BtnUnpin => Get("btnUnpin");
    public static string ScreenshotCopied => Get("screenshotCopied");
    public static string ScreenshotCancelled => Get("screenshotCancelled");
    public static string ScreenshotFailed => Get("screenshotFailed");
    public static string ScreenshotNoImage => Get("screenshotNoImage");
    public static string ScreenshotScrollHint => Get("screenshotScrollHint");
    public static string ScreenshotScrollTooFast => Get("screenshotScrollTooFast");
    public static string ScreenshotScrollDone => Get("screenshotScrollDone");
    public static string ScreenshotScrollCancel => Get("screenshotScrollCancel");
    public static string LongImageModeTitle => Get("longImageModeTitle");
    public static string LongImageModeDesc => Get("longImageModeDesc");

    // Page Titles
    public static string PageHome => Get("pageHome");
    public static string PageDict => Get("pageDict");
    public static string PagePersona => Get("pagePersona");
    public static string PageHistory => Get("pageHistory");
    public static string PageSettings => Get("pageSettings");

    // Section Labels
    public static string SectionHotkeys => Get("sectionHotkeys");
    public static string SectionLatest => Get("sectionLatest");
    public static string SectionPrivacy => Get("sectionPrivacy");
    public static string LabelTranscript => Get("labelTranscript");
    public static string LabelResult => Get("labelResult");

    // Status Labels
    public static string StatusIdle => Get("statusIdle");
    public static string StatusRec => Get("statusRec");
    public static string StatusProc => Get("statusProc");
    public static string StatusWait => Get("statusWait");
    public static string StatusOk => Get("statusOk");
    public static string StatusFail => Get("statusFail");
    public static string StatusFailed => Get("statusFailed");
    public static string StatusDenied => Get("statusDenied");
    public static string StatusPending => Get("statusPending");

    // Buttons
    public static string BtnRefresh => Get("btnRefresh");
    public static string BtnDone => Get("btnDone");
    public static string BtnActivate => Get("btnActivate");
    public static string BtnClone => Get("btnClone");
    public static string BtnCopy => Get("btnCopy");
    public static string BtnCopied => Get("btnCopied");
    public static string BtnViewInOverlay => Get("btnViewInOverlay");
    public static string BtnDelAudio => Get("btnDelAudio");
    public static string BtnPlayAudio => Get("btnPlayAudio");
    public static string BtnWarn => Get("btnWarn");

    // Form Labels
    public static string LabelName => Get("labelName");
    public static string LabelPrompt => Get("labelPrompt");

    // Language
    public static string LanguageLabel => Get("languageLabel");
    public static string ThemeSwitch => Get("themeSwitch");
    public static string ThemeLight => Get("themeLight");
    public static string ThemeDark => Get("themeDark");
    public static string SettingsAppearance => Get("settingsAppearance");
    public static string SettingsTheme => Get("settingsTheme");
    public static string SettingsThemeDescription => Get("settingsThemeDescription");
    public static string SettingsAccent => Get("settingsAccent");
    public static string SettingsAccentDescription => Get("settingsAccentDescription");
    public static string AccentSand => Get("accentSand");
    public static string AccentMono => Get("accentMono");
    public static string AccentBlue => Get("accentBlue");
    public static string AccentOrange => Get("accentOrange");
    public static string AccentRed => Get("accentRed");
    public static string AccentGreen => Get("accentGreen");
    public static string AccentPurple => Get("accentPurple");

    // Common
    public static string Cancel => Get("cancel");
    public static string Delete => Get("delete");
    public static string Save => Get("save");
    public static string Add => Get("add");
    public static string Manage => Get("manage");
    public static string Loading => Get("loading");
    public static string Retry => Get("retry");
    public static string LoadMore => Get("loadMore");

    // Error Messages
    public static string ErrorUnknown => Get("errorUnknown");
    public static string ErrorDecode => Get("errorDecode");
    public static string ErrorNetwork => Get("errorNetwork");
    public static string ErrorUnauthorized => Get("errorUnauthorized");
    public static string ErrorUserCancelled => Get("errorUserCancelled");
    public static string ErrorInvalidAudio => Get("errorInvalidAudio");
    public static string ErrorDurationExceeded => Get("errorDurationExceeded");
    public static string ErrorUnsupportedOp => Get("errorUnsupportedOp");
    public static string ErrorProviderError => Get("errorProviderError");
    public static string ErrorInvalidCode => Get("errorInvalidCode");
    public static string ErrorHotwordDuplicate => Get("errorHotwordDuplicate");
    public static string ErrorHotwordNotFound => Get("errorHotwordNotFound");
    public static string ErrorHotwordLimit => Get("errorHotwordLimit");
    public static string ErrorShortcutNotFound => Get("errorShortcutNotFound");
    public static string ErrorCreditsExhausted => Get("errorCreditsExhausted");
    public static string ErrorUserBanned => Get("errorUserBanned");

    // Errors - Invite
    public static string ErrorInvalidInviteCode => Get("errorInvalidInviteCode");
    public static string ErrorInviteSessionExpired => Get("errorInviteSessionExpired");
    public static string ErrorDeviceLimitReached => Get("errorDeviceLimitReached");
    public static string ErrorIpLimitReached => Get("errorIpLimitReached");
    public static string ErrorDisposableEmail => Get("errorDisposableEmail");
    public static string ErrorSendCodeTooFrequent => Get("errorSendCodeTooFrequent");

    // Onboarding - common
    public static string OnboardingBack => Get("onboardingBack");
    public static string OnboardingNext => Get("onboardingNext");
    public static string OnboardingStart => Get("onboardingStart");
    public static string OnboardingTryFirst => Get("onboardingTryFirst");
    public static string OnboardingStepDone => Get("onboardingStepDone");
    public static string OnboardingStepWaiting => Get("onboardingStepWaiting");
    public static string OnboardingHowToUse => Get("onboardingHowToUse");
    public static string OnboardingSkip => Get("onboardingSkip");
    public static string OnboardingTips => Get("onboardingTips");
    public static string ObBadgeGuideHotkeys => Get("obBadgeGuideHotkeys");
    public static string ObBadgeHotkeyOverview => Get("obBadgeHotkeyOverview");
    public static string ObBadgeScreenshotRewrite => Get("obBadgeScreenshotRewrite");
    public static string ObBadgeCommonHotkeys => Get("obBadgeCommonHotkeys");

    // Onboarding - welcome
    public static string OnboardingWelcomeTitle => Get("onboardingWelcomeTitle");
    public static string OnboardingWelcomeDesc => Get("onboardingWelcomeDesc");
    public static string OnboardingFeature1Title => Get("onboardingFeature1Title");
    public static string OnboardingFeature1Desc => Get("onboardingFeature1Desc");
    public static string OnboardingFeature2Title => Get("onboardingFeature2Title");
    public static string OnboardingFeature2Desc => Get("onboardingFeature2Desc");
    public static string OnboardingFeature3Title => Get("onboardingFeature3Title");
    public static string OnboardingFeature3Desc => Get("onboardingFeature3Desc");

    // Onboarding - transcribe fill
    public static string ObTriFillTitle => Get("obTriFillTitle");
    public static string ObTriFillSub => Get("obTriFillSub");
    public static string ObTriFillFieldLabel => Get("obTriFillFieldLabel");
    public static string ObTriFillPlaceholder => Get("obTriFillPlaceholder");
    public static string ObTriFillI1 => Get("obTriFillI1");
    public static string ObTriFillI2 => Get("obTriFillI2");
    public static string ObTriFillI3 => Get("obTriFillI3");

    // Onboarding - rewrite generate
    public static string ObRwGenTitle => Get("obRwGenTitle");
    public static string ObRwGenSub => Get("obRwGenSub");
    public static string ObRwGenFieldLabel => Get("obRwGenFieldLabel");
    public static string ObRwGenPlaceholder => Get("obRwGenPlaceholder");
    public static string ObRwGenI1 => Get("obRwGenI1");
    public static string ObRwGenI2 => Get("obRwGenI2");
    public static string ObRwGenI3 => Get("obRwGenI3");

    // Onboarding - rewrite readonly
    public static string ObRwRoTitle => Get("obRwRoTitle");
    public static string ObRwRoSub => Get("obRwRoSub");
    public static string ObRwRoSelectHint => Get("obRwRoSelectHint");
    public static string ObRwRoSampleText => Get("obRwRoSampleText");
    public static string ObRwRoI1 => Get("obRwRoI1");
    public static string ObRwRoI2 => Get("obRwRoI2");
    public static string ObRwRoI3 => Get("obRwRoI3");

    // Onboarding - rewrite editable
    public static string ObRwEdTitle => Get("obRwEdTitle");
    public static string ObRwEdSub => Get("obRwEdSub");
    public static string ObRwEdFieldLabel => Get("obRwEdFieldLabel");
    public static string ObRwEdDefaultText => Get("obRwEdDefaultText");
    public static string ObRwEdI1 => Get("obRwEdI1");
    public static string ObRwEdI2 => Get("obRwEdI2");
    public static string ObRwEdI3 => Get("obRwEdI3");

    // Onboarding - agent search
    public static string ObAgSearchTitle => Get("obAgSearchTitle");
    public static string ObAgSearchSub => Get("obAgSearchSub");
    public static string ObAgSearchExampleLabel => Get("obAgSearchExampleLabel");
    public static string ObAgSearchEx1 => Get("obAgSearchEx1");
    public static string ObAgSearchEx2 => Get("obAgSearchEx2");
    public static string ObAgSearchEx3 => Get("obAgSearchEx3");
    public static string ObAgSearchI1 => Get("obAgSearchI1");
    public static string ObAgSearchI2 => Get("obAgSearchI2");
    public static string ObAgSearchI3 => Get("obAgSearchI3");

    // Onboarding - complete
    public static string OnboardingCompleteTitle => Get("onboardingCompleteTitle");
    public static string OnboardingCompleteDesc => Get("onboardingCompleteDesc");

    // Invite Code
    public static string InvitePageTitle => Get("invitePageTitle");
    public static string InvitePageSubtitle => Get("invitePageSubtitle");
    public static string InviteWelcomeHeading => Get("inviteWelcomeHeading");
    public static string InviteBodyLine1 => Get("inviteBodyLine1");
    public static string InviteBodyLine2 => Get("inviteBodyLine2");
    public static string InviteCodePlaceholder => Get("inviteCodePlaceholder");
    public static string InviteSubmitBtn => Get("inviteSubmitBtn");
    public static string InviteBackBtn => Get("inviteBackBtn");
    public static string InviteSuccessHint => Get("inviteSuccessHint");

    // My Invite Codes
    public static string MyInviteCodesTitle => Get("myInviteCodesTitle");
    public static string MyInviteCodesDesc => Get("myInviteCodesDesc");
    public static string MyInviteCodeUsed => Get("myInviteCodeUsed");
    public static string MyInviteCodeUnused => Get("myInviteCodeUnused");
    public static string MyInviteCodeUsedBy => Get("myInviteCodeUsedBy");
    public static string MyInviteCodeCopied => Get("myInviteCodeCopied");
    public static string MyInviteCodesBtn => Get("myInviteCodesBtn");

    // OpenClaw Integration
    public static string OpenclawPromoTitle => Get("openclawPromoTitle");
    public static string OpenclawPromoDesc => Get("openclawPromoDesc");
    public static string OpenclawInstallBtn => Get("openclawInstallBtn");
    public static string OpenclawInstalledTitle => Get("openclawInstalledTitle");
    public static string OpenclawInstalledDesc => Get("openclawInstalledDesc");
    public static string OpenclawServiceDownTitle => Get("openclawServiceDownTitle");
    public static string OpenclawServiceDownDesc => Get("openclawServiceDownDesc");
    public static string OpenclawStartBtn => Get("openclawStartBtn");
    public static string OpenclawStartingGateway => Get("openclawStartingGateway");
    public static string OpenclawProcessing => Get("openclawProcessing");
    public static string OpenclawStopBtn => Get("openclawStopBtn");
    public static string OpenclawTipNotInstalled => Get("openclawTipNotInstalled");
    public static string OpenclawTipServiceDown => Get("openclawTipServiceDown");
    public static string OpenclawTipSessionStarted => Get("openclawTipSessionStarted");
    public static string OpenclawTipSessionEnded => Get("openclawTipSessionEnded");
    public static string OpenclawTipAlreadyActive => Get("openclawTipAlreadyActive");
    public static string OpenclawTipNewSessionStarted => Get("openclawTipNewSessionStarted");
    public static string OpenclawMinVersion => Get("openclawMinVersion");
    public static string OpenclawUninstallBtn => Get("openclawUninstallBtn");
    public static string OpenclawUninstallConfirmTitle => Get("openclawUninstallConfirmTitle");
    public static string OpenclawUninstallConfirmMessage => Get("openclawUninstallConfirmMessage");

    // Onboarding — screenshot OCR
    public static string ObScrTitle => Get("obScrTitle");
    public static string ObScrSub => Get("obScrSub");
    public static string ObScrSelectHint => Get("obScrSelectHint");
    public static string ObScrSampleText => Get("obScrSampleText");
    public static string ObScrI3 => Get("obScrI3");

    public static string ObScrI1(string screenshotHotkey) =>
        string.Format(Get("obScrI1"), screenshotHotkey);

    public static string ObScrI2(string rewriteHotkey) =>
        string.Format(Get("obScrI2"), rewriteHotkey);

    public static string ObScrI4(string rewriteHotkey) =>
        string.Format(Get("obScrI4"), rewriteHotkey);

    // Onboarding — shortcut step (Windows-only)
    public static string ObShortcutTitle => Get("obShortcutTitle");
    public static string ObShortcutDesc => Get("obShortcutDesc");
    public static string ObShortcutTranscribeDesc => Get("obShortcutTranscribeDesc");
    public static string ObShortcutRewriteDesc => Get("obShortcutRewriteDesc");
    public static string ObShortcutAgentDesc => Get("obShortcutAgentDesc");
    public static string ObShortcutScreenshotDesc => Get("obShortcutScreenshotDesc");

    // Privacy / Clipboard
    public static string ClipboardAccessTitle => Get("clipboardAccessTitle");
    public static string ClipboardAccessDesc => Get("clipboardAccessDesc");
    public static string TranscribeFastModeTitle => Get("transcribeFastModeTitle");
    public static string TranscribeFastModeDesc => Get("transcribeFastModeDesc");
    public static string RealtimeRecognitionTitle => Get("realtimeRecognitionTitle");
    public static string RealtimeRecognitionDesc => Get("realtimeRecognitionDesc");
    public static string FeedbackTitle => Get("feedbackTitle");
    public static string FeedbackPlaceholder => Get("feedbackPlaceholder");
    public static string FeedbackSubmit => Get("feedbackSubmit");
    public static string ThemeSectionTitle => Get("themeSectionTitle");
    public static string ThemeTitle => Get("themeTitle");
    public static string ThemeDesc => Get("themeDesc");
    public static string ThemeSwitchToDark => Get("themeSwitchToDark");
    public static string ThemeSwitchToLight => Get("themeSwitchToLight");

    // Legal Agreements
    public static string AgreementTerms => Get("agreementTerms");
    public static string AgreementPrivacy => Get("agreementPrivacy");
    public static string AgreementAnd => Get("agreementAnd");
    public static string AgreementLoading => Get("agreementLoading");
    public static string AgreementLoadFailed => Get("agreementLoadFailed");
    public static string AgreementClose => Get("agreementClose");

    // Menu
    public static string MenuShowMain => Get("menuShowMain");
    public static string MenuOpenSettings => Get("menuOpenSettings");
    public static string MenuQuit => Get("menuQuit");
    public static string MenuMicrophone => Get("menuMicrophone");
    public static string MenuDefaultMicrophone => Get("menuDefaultMicrophone");
    public static string MenuPersona => Get("menuPersona");
    public static string MenuPersonaNone => Get("menuPersonaNone");
    public static string MenuPersonaEmpty => Get("menuPersonaEmpty");
    public static string MenuCheckUpdate => Get("menuCheckUpdate");
    public static string MenuChecking => Get("menuChecking");
    public static string MenuDownloading => Get("menuDownloading");
    public static string MenuCrashUploading => Get("menuCrashUploading");
    public static string MenuCrashNoLog => Get("menuCrashNoLog");
    public static string CrashUploadLoginRequired => Get("crashUploadLoginRequired");
    public static string UpdateNoUpdate => Get("updateNoUpdate");
    public static string UpdateUnavailableDevBuild => Get("updateUnavailableDevBuild");
    public static string UpdateNoReadyPackage => Get("updateNoReadyPackage");
    public static string UpdateUnknownError => Get("updateUnknownError");
    public static string UpdateDialogTitle => Get("updateDialogTitle");
    public static string UpdateDialogCheckingTitle => Get("updateDialogCheckingTitle");
    public static string UpdateDialogAvailableTitle => Get("updateDialogAvailableTitle");
    public static string UpdateDialogNoUpdateTitle => Get("updateDialogNoUpdateTitle");
    public static string UpdateDialogErrorTitle => Get("updateDialogErrorTitle");
    public static string UpdateDialogDownloadingTitle => Get("updateDialogDownloadingTitle");
    public static string UpdateDialogReadyTitle => Get("updateDialogReadyTitle");
    public static string UpdateDialogAvailableDesc => Get("updateDialogAvailableDesc");
    public static string UpdateDialogNoUpdateDesc => Get("updateDialogNoUpdateDesc");
    public static string UpdateDialogDownloadingDesc => Get("updateDialogDownloadingDesc");
    public static string UpdateDialogReadyDesc => Get("updateDialogReadyDesc");
    public static string UpdateDialogInstallNow => Get("updateDialogInstallNow");
    public static string UpdateDialogRestartInstall => Get("updateDialogRestartInstall");
    public static string UpdateDialogLater => Get("updateDialogLater");
    public static string UpdateDialogClose => Get("updateDialogClose");
    public static string UpdateDialogCurrentVersion => Get("updateDialogCurrentVersion");
    public static string UpdateDialogNewVersion => Get("updateDialogNewVersion");
    public static string UpdateDialogReleaseNotes => Get("updateDialogReleaseNotes");
    public static string UpdateDialogRestarting => Get("updateDialogRestarting");

    // --- Methods with parameters ---

    public static string CreditsResetDateLabel(string date) => date;

    public static string CreditItemExpires(string date) =>
        string.Format(Get("creditItemExpires"), date);

    public static string SubscriptionCredits(int count) =>
        string.Format(Get("subscriptionCredits"), count);

    public static string SubscriptionPriceMonthly(string price) =>
        string.Format(Get("subscriptionPriceMonthly"), price);

    public static string SubscriptionAutoRenewOn(string date) =>
        string.Format(Get("subscriptionAutoRenewOn"), date);

    public static string SubscriptionCancelRenewalConfirm(string date) =>
        string.Format(Get("subscriptionCancelRenewalConfirm"), date);

    public static string DictPageInfo(int cur, int total) =>
        string.Format(Get("dictPageInfo"), cur, total);

    public static string MicrophoneAutoDetect(string name) =>
        string.Format(Get("microphoneAutoDetect"), name);

    public static string CrashUploadSuccess(int count) =>
        string.Format(Get("crashUploadSuccess"), count);

    public static string CrashUploadPartial(int ok, int failed) =>
        string.Format(Get("crashUploadPartial"), ok, failed);

    public static string CrashUploadFailed(int failed) =>
        string.Format(Get("crashUploadFailed"), failed);

    public static string PersonaCountHint(int count, int max) =>
        string.Format(Get("personaCountHint"), count, max);

    public static string PersonaLimitReached(int max) =>
        string.Format(Get("personaLimitReached"), max);

    public static string ConfirmDeleteHotword(string word) =>
        string.Format(Get("confirmDeleteHotword"), word);

    public static string MoreCount(int n) =>
        string.Format(Get("moreCount"), n);

    public static string RecCount(int n) =>
        string.Format(Get("recCount"), n);

    public static string CharCount(int cur, int max) =>
        string.Format(Get("charCount"), cur, max);

    public static string MenuCrashUpload(int count) =>
        string.Format(Get("menuCrashUpload"), count);

    public static string UpdateFound(string version) =>
        string.Format(Get("updateFound"), version);

    public static string UpdateFailed(string message) =>
        string.Format(Get("updateFailed"), message);

    public static string UpdateDialogProgress(int percent) =>
        string.Format(Get("updateDialogProgress"), percent);

    // --- Error / Tip code mapping ---

    public static string ErrorForCode(string code) => code switch
    {
        "UNAUTHORIZED" => Get("errorUnauthorized"),
        "INVALID_AUDIO" => Get("errorInvalidAudio"),
        "DURATION_EXCEEDED" => Get("errorDurationExceeded"),
        "UNSUPPORTED_OPERATION" => Get("errorUnsupportedOp"),
        "PROVIDER_ERROR" => Get("errorProviderError"),
        "SERVICE_TEMPORARILY_UNAVAILABLE" => Get("errorProviderError"),
        "INVALID_CODE" => Get("errorInvalidCode"),
        "HOTWORD_DUPLICATE" => Get("errorHotwordDuplicate"),
        "HOTWORD_NOT_FOUND" => Get("errorHotwordNotFound"),
        "HOTWORD_LIMIT_REACHED" => Get("errorHotwordLimit"),
        "SHORTCUT_NOT_FOUND" => Get("errorShortcutNotFound"),
        "USER_CANCELLED" => Get("errorUserCancelled"),
        "INVALID_INVITE_CODE" => Get("errorInvalidInviteCode"),
        "INVITE_SESSION_EXPIRED" => Get("errorInviteSessionExpired"),
        "DEVICE_LIMIT_REACHED" => Get("errorDeviceLimitReached"),
        "IP_LIMIT_REACHED" or "REG_LIMIT_REACHED" => Get("errorIpLimitReached"),
        "DISPOSABLE_EMAIL" => Get("errorDisposableEmail"),
        "SEND_CODE_TOO_FREQUENT" => Get("errorSendCodeTooFrequent"),
        "REGISTRATION_DISABLED" => Get("errorRegistrationDisabled"),
        "REGISTRATION_CLOSED" => Get("errorRegistrationClosed"),
        "OPENCLAW_NOT_INSTALLED" => Get("openclawTipNotInstalled"),
        "OPENCLAW_SERVICE_DOWN" => Get("openclawTipServiceDown"),
        "CREDITS_EXHAUSTED" => Get("errorCreditsExhausted"),
        "USER_BANNED" => Get("errorUserBanned"),
        _ => Get("errorUnknown"),
    };

    public static string TipForCode(string code) => code switch
    {
        "OPENCLAW_NOT_INSTALLED" => Get("openclawTipNotInstalled"),
        "OPENCLAW_SERVICE_DOWN" => Get("openclawTipServiceDown"),
        "OPENCLAW_SESSION_STARTED" => Get("openclawTipSessionStarted"),
        "OPENCLAW_SESSION_ENDED" => Get("openclawTipSessionEnded"),
        "OPENCLAW_ALREADY_ACTIVE" => Get("openclawTipAlreadyActive"),
        "OPENCLAW_NEW_SESSION_STARTED" => Get("openclawTipNewSessionStarted"),
        _ => code,
    };

    // --- String Dictionaries (placeholder, filled below) ---

}
