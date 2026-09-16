import SwiftUI

struct SettingsView: View {

    @StateObject private var authStore = AuthStore.shared
    @StateObject private var keyboardVoiceSession = KeyboardVoiceSessionController.shared
    @EnvironmentObject private var languageStore: MobileLanguageStore
    @State private var showLogoutConfirm = false
    @State private var showInviteCodes = false
    @State private var showPaywall = false
    @State private var keyboardDiagnostic: KeyboardRecordingDiagnostic?
    @State private var realtimeRecognitionEnabled = KeyboardRealtimeRecognitionStore.isEnabled

    var body: some View {
        NavigationStack {
            List {
                profileHeroSection
                accountSection
                languageSection
                keyboardSection
                keyboardVoiceSessionSection
                diagnosticSection
                functionsSection
                aboutSection
                logoutSection
            }
            .scrollContentBackground(.hidden)
            .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
            .navigationTitle(MobileStrings.settingsTitle())
            .alert(MobileStrings.text(zh: "确认退出", en: "Sign out?", ru: "Выйти?", ko: "로그아웃할까요?"), isPresented: $showLogoutConfirm) {
                Button(MobileStrings.text(zh: "取消", en: "Cancel", ru: "Отмена", ko: "취소"), role: .cancel) {}
                Button(MobileStrings.text(zh: "退出登录", en: "Sign out", ru: "Выйти", ko: "로그아웃"), role: .destructive) {
                    // 先在清空本地登录态之前捕获 token,fire-and-forget 通知服务端
                    // 撤销 session(接口幂等,失败不影响本地退出),再清空本地。
                    if let token = authStore.token {
                        Task { await APIClient.shared.logout(token: token) }
                    }
                    authStore.logout()
                }
            } message: {
                Text(MobileStrings.text(zh: "退出后需要重新登录", en: "You will need to sign in again.", ru: "Потребуется войти снова.", ko: "다시 로그인해야 합니다."))
            }
            .sheet(isPresented: $showInviteCodes) {
                InviteCodesView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .onAppear {
                keyboardDiagnostic = KeyboardRecordingBridge.latestDiagnostic()
            }
            .task {
                // 主动拉取最新套餐/积分，修复"打开设置页总积分一直为 0"的问题
                await authStore.refreshPlanInfo()
            }
        }
    }

    private var profileHeroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 48, height: 48)
                        Image(systemName: "person.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authStore.email ?? MobileStrings.text(zh: "未登录", en: "Not signed in", ru: "Не выполнен вход", ko: "로그인 안 됨"))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(authStore.planName.isEmpty ? MobileStrings.planName(authStore.tier) : authStore.planName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                }
                creditSummaryCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LobsterWaterPalette.accentGradient, in: RoundedRectangle(cornerRadius: LobsterMetrics.radiusCard, style: .continuous))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// 套餐积分汇总卡片：剩余/总积分 + 进度条 + 已用积分 + 重置日期 + 套餐有效期
    private var creditSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(MobileStrings.text(zh: "剩余积分", en: "Credits left", ru: "Осталось кредитов", ko: "남은 크레딧"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("\(authStore.creditsRemaining) / \(authStore.creditsTotal)")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            if authStore.creditsTotal > 0 {
                creditProgressBar
            }
            creditInfoRow(
                label: MobileStrings.text(zh: "已用积分", en: "Used", ru: "Использовано", ko: "사용됨"),
                value: "\(authStore.creditsUsed)"
            )
            if let reset = authStore.formattedResetDate() {
                creditInfoRow(
                    label: MobileStrings.text(zh: "积分重置日期", en: "Credits reset", ru: "Сброс кредитов", ko: "크레딧 초기화"),
                    value: reset
                )
            }
            creditInfoRow(
                label: MobileStrings.text(zh: "套餐有效期", en: "Plan valid until", ru: "Действует до", ko: "요금제 유효기간"),
                value: authStore.formattedExpiryDate()
                    ?? MobileStrings.text(zh: "永久有效", en: "No expiry", ru: "Бессрочно", ko: "무기한", zhHant: "永久有效", yue: "永久有效")
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var creditProgressBar: some View {
        GeometryReader { geo in
            let ratio = authStore.creditsTotal > 0
                ? max(0, min(1, Double(authStore.creditsRemaining) / Double(authStore.creditsTotal)))
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white.opacity(0.9))
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 6)
    }

    private func creditInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section(MobileStrings.text(zh: "账户", en: "Account", ru: "Аккаунт", ko: "계정")) {
            Button {
                showPaywall = true
            } label: {
                HStack {
                    Label(MobileStrings.text(zh: "套餐与购买", en: "Plans & Purchase", ru: "Тарифы и покупки", ko: "요금제 및 구매", zhHant: "套餐與購買", yue: "套餐與購買"), systemImage: "crown")
                        .foregroundStyle(LobsterWaterPalette.textColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LobsterWaterPalette.tertiaryColor)
                }
            }
            if authStore.showInviteCodesEnabled {
                Button {
                    showInviteCodes = true
                } label: {
                    HStack {
                        Label(MobileStrings.text(zh: "我的邀请码", en: "My invite codes", ru: "Мои коды", ko: "내 초대 코드"), systemImage: "gift")
                            .foregroundStyle(LobsterWaterPalette.textColor)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LobsterWaterPalette.tertiaryColor)
                    }
                }
            }
        }
    }

    private var logoutSection: some View {
        Section {
            Button(MobileStrings.text(zh: "退出登录", en: "Sign out", ru: "Выйти", ko: "로그아웃"), role: .destructive) {
                showLogoutConfirm = true
            }
            .tint(LobsterWaterPalette.dangerColor)
        }
    }

    private var languageSection: some View {
        Section(MobileStrings.languageTitle()) {
            Picker(MobileStrings.languageTitle(), selection: languageBinding) {
                ForEach(MobileLanguage.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.menu)
            Text(MobileStrings.languageHint())
                .font(.caption)
                .foregroundStyle(LobsterWaterPalette.mutedColor)
        }
    }

    private var languageBinding: Binding<MobileLanguage> {
        Binding(
            get: { languageStore.language },
            set: { languageStore.language = $0 }
        )
    }

    private var keyboardSection: some View {
        Section(MobileStrings.text(zh: "键盘设置", en: "Keyboard setup", ru: "Настройка клавиатуры", ko: "키보드 설정")) {
            VStack(alignment: .leading, spacing: 8) {
                Label(MobileStrings.text(zh: "启用 iOS 系统键盘", en: "Enable iOS keyboard", ru: "Включите клавиатуру iOS", ko: "iOS 키보드 켜기"), systemImage: "keyboard")
                    .font(.headline)
                    .foregroundStyle(LobsterWaterPalette.textColor)
                Text(MobileStrings.text(zh: "请到系统设置中添加“龙虾输入法”键盘，并开启“允许完全访问”。iOS 不允许 App 自动设为默认键盘，使用时需要在输入框里通过地球键或长按地球键切换到龙虾输入法。", en: "Add the Lobster keyboard in system settings and allow full access. iOS does not let apps become the default keyboard automatically; switch to Lobster with the globe key in a text field.", ru: "Добавьте клавиатуру Lobster и разрешите полный доступ. iOS не позволяет приложению стать клавиатурой по умолчанию автоматически; выберите Lobster через клавишу глобуса.", ko: "시스템 설정에서 랍스터 키보드를 추가하고 전체 접근을 허용하세요. iOS는 앱이 기본 키보드가 되도록 자동 설정할 수 없으므로 입력창에서 지구본 키로 전환해야 합니다."))
                    .font(.caption)
                    .foregroundStyle(LobsterWaterPalette.mutedColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(MobileStrings.text(zh: "1. 打开 设置 App", en: "1. Open Settings", ru: "1. Откройте Настройки", ko: "1. 설정 열기"))
                    Text(MobileStrings.text(zh: "2. 进入 通用 > 键盘 > 键盘", en: "2. Go to General > Keyboard > Keyboards", ru: "2. Основные > Клавиатура > Клавиатуры", ko: "2. 일반 > 키보드 > 키보드"))
                    Text(MobileStrings.text(zh: "3. 添加新键盘 > 龙虾输入法", en: "3. Add New Keyboard > Lobster Input", ru: "3. Добавьте клавиатуру Lobster", ko: "3. 새 키보드 추가 > 랍스터 입력기"))
                    Text(MobileStrings.text(zh: "4. 开启允许完全访问", en: "4. Turn on Allow Full Access", ru: "4. Разрешите полный доступ", ko: "4. 전체 접근 허용"))
                    Text(MobileStrings.text(zh: "5. 在输入框中点地球键切换到龙虾输入法", en: "5. Tap the globe key in a text field to switch to Lobster", ru: "5. Нажмите глобус в поле ввода и выберите Lobster", ko: "5. 입력창에서 지구본 키를 눌러 랍스터로 전환"))
                }
                .font(.caption)
                .foregroundStyle(LobsterWaterPalette.mutedColor)
            }
            .padding(.vertical, 4)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Label(MobileStrings.text(zh: "打开键盘设置", en: "Open keyboard settings", ru: "Открыть настройки", ko: "키보드 설정 열기"), systemImage: "keyboard")
                        .foregroundStyle(LobsterWaterPalette.accentColor)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(LobsterWaterPalette.tertiaryColor)
                }
            }
        }
    }

    private var keyboardVoiceSessionSection: some View {
        Section(MobileStrings.text(zh: "键盘语音会话", en: "Keyboard voice session", ru: "Голосовая сессия клавиатуры", ko: "키보드 음성 세션")) {
            Toggle(isOn: keyboardVoiceSessionBinding) {
                Label(
                    MobileStrings.text(zh: "保持后台麦克风会话", en: "Keep microphone session active", ru: "Держать микрофон активным", ko: "마이크 세션 유지"),
                    systemImage: "waveform.circle"
                )
            }

            Toggle(isOn: realtimeRecognitionBinding) {
                Label(
                    MobileStrings.text(zh: "流式实时识别", en: "Realtime streaming recognition", ru: "Потоковое распознавание", ko: "실시간 스트리밍 인식"),
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }

            Text(MobileStrings.text(
                zh: "开启后键盘麦克风改为长按说话，实时识别文本会先填入输入框，松开后再投递到 iOS V2 接口处理。",
                en: "When enabled, hold the keyboard mic to speak. Live ASR text is previewed in the input field, then submitted to the iOS V2 endpoint when released.",
                ru: "После включения удерживайте микрофон клавиатуры. Текст распознавания показывается в поле и отправляется в iOS V2 после отпускания.",
                ko: "켜면 키보드 마이크를 길게 눌러 말합니다. 실시간 인식 텍스트를 입력창에 미리 표시하고 손을 떼면 iOS V2로 전송합니다."
            ))
            .font(.caption)
            .foregroundStyle(LobsterWaterPalette.mutedColor)

            HStack {
                Text(MobileStrings.text(zh: "状态", en: "Status", ru: "Статус", ko: "상태"))
                Spacer()
                Text(keyboardVoiceSessionStatus)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(keyboardVoiceSession.isSessionActive ? LobsterWaterPalette.successColor : LobsterWaterPalette.mutedColor)
            }

            if let error = keyboardVoiceSession.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(LobsterWaterPalette.dangerColor)
                    .textSelection(.enabled)
            }

            Text(MobileStrings.text(
                zh: "开启后主 App 在后台保持麦克风会话，键盘可直接录音且不会跳转录音界面。状态栏橙色麦克风点为 iOS 隐私提示。若手动杀掉 App，需重新打开 App 恢复会话。",
                en: "When enabled, the main app keeps a background microphone session so the keyboard can record without opening the recording screen. The orange mic dot is the iOS privacy indicator. If you force-quit the app, reopen it to restore the session.",
                ru: "После включения клавиатура записывает без перехода в приложение. Оранжевая точка микрофона — системный индикатор iOS. Если приложение принудительно закрыто, откройте его снова.",
                ko: "켜면 앱으로 전환하지 않고 키보드에서 녹음을 시작/종료할 수 있습니다. 주황색 마이크 점은 iOS 개인정보 표시입니다. 앱을 강제 종료하면 다시 열어야 합니다."
            ))
            .font(.caption)
            .foregroundStyle(LobsterWaterPalette.mutedColor)
        }
    }

    private var keyboardVoiceSessionBinding: Binding<Bool> {
        Binding(
            get: { keyboardVoiceSession.isEnabled },
            set: { enabled in
                Task { await keyboardVoiceSession.setEnabled(enabled) }
            }
        )
    }

    private var realtimeRecognitionBinding: Binding<Bool> {
        Binding(
            get: { realtimeRecognitionEnabled },
            set: { enabled in
                realtimeRecognitionEnabled = enabled
                KeyboardRealtimeRecognitionStore.isEnabled = enabled
            }
        )
    }

    private var keyboardVoiceSessionStatus: String {
        if keyboardVoiceSession.isSessionActive {
            return MobileStrings.text(zh: "已就绪", en: "Ready", ru: "Готово", ko: "준비됨")
        }
        if keyboardVoiceSession.isEnabled {
            return MobileStrings.text(zh: "未运行", en: "Not running", ru: "Не запущено", ko: "실행 안 됨")
        }
        return MobileStrings.text(zh: "未开启", en: "Off", ru: "Выкл.", ko: "꺼짐")
    }

    private var functionsSection: some View {
        Section {
            NavigationLink {
                DictionaryView()
            } label: {
                Label(L10n.dictTitle, systemImage: "text.book.closed")
                    .foregroundStyle(LobsterWaterPalette.textColor)
            }
        }
    }

    @ViewBuilder
    private var diagnosticSection: some View {
        if let keyboardDiagnostic {
            Section(MobileStrings.text(zh: "键盘录音诊断", en: "Keyboard recording diagnostics", ru: "Диагностика записи", ko: "키보드 녹음 진단")) {
                VStack(alignment: .leading, spacing: 8) {
                    diagnosticRow(
                        MobileStrings.text(zh: "完全访问", en: "Full access", ru: "Полный доступ", ko: "전체 접근"),
                        keyboardDiagnostic.hasFullAccess
                            ? MobileStrings.text(zh: "已开启", en: "On", ru: "Вкл.", ko: "켜짐")
                            : MobileStrings.text(zh: "未开启", en: "Off", ru: "Выкл.", ko: "꺼짐")
                    )
                    diagnosticRow(
                        MobileStrings.text(zh: "麦克风授权", en: "Microphone permission", ru: "Доступ к микрофону", ko: "마이크 권한"),
                        keyboardDiagnostic.recordPermission
                    )
                    diagnosticRow(
                        MobileStrings.text(zh: "时间", en: "Time", ru: "Время", ko: "시간"),
                        Date(timeIntervalSince1970: keyboardDiagnostic.createdAt).formatted(date: .abbreviated, time: .standard)
                    )
                    Text(keyboardDiagnostic.error)
                        .font(.caption)
                        .foregroundStyle(LobsterWaterPalette.mutedColor)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)

                Button {
                    UIPasteboard.general.string = keyboardDiagnostic.error
                } label: {
                    Label(L10n.btnCopy, systemImage: "doc.on.doc")
                }
                .tint(LobsterWaterPalette.accentColor)

                Button(role: .destructive) {
                    KeyboardRecordingBridge.clearDiagnostic()
                    self.keyboardDiagnostic = nil
                } label: {
                    Label(L10n.btnDelete, systemImage: "trash")
                }
                .tint(LobsterWaterPalette.dangerColor)
            }
        }
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(LobsterWaterPalette.textColor)
            Spacer()
            Text(value)
                .foregroundStyle(LobsterWaterPalette.mutedColor)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private var aboutSection: some View {
        Section(MobileStrings.text(zh: "关于", en: "About", ru: "О приложении", ko: "정보")) {
            HStack {
                Text(MobileStrings.text(zh: "版本", en: "Version", ru: "Версия", ko: "버전"))
                    .foregroundStyle(LobsterWaterPalette.textColor)
                Spacer()
                if let badge = environmentBadge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LobsterWaterPalette.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LobsterWaterPalette.accentColor.opacity(0.12)))
                }
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LobsterWaterPalette.mutedColor)
            }
        }
    }

    /// 环境徽章:由 APIConfig.environment 动态派生,禁止写死。
    /// preview(内测环境)→ 内测版;uat(公测环境)→ 正式版;dev/prod 不显示。
    private var environmentBadge: String? {
        switch APIConfig.environment {
        case .preview:
            return MobileStrings.text(
                zh: "内测版", en: "Beta", ru: "Бета", ko: "베타",
                zhHant: "內測版", yue: "內測版"
            )
        case .uat:
            return MobileStrings.text(
                zh: "正式版", en: "Official", ru: "Релиз", ko: "정식판",
                zhHant: "正式版", yue: "正式版"
            )
        case .dev, .prod:
            return nil
        }
    }
}

struct InviteCodesView: View {
    @State private var codes: [InviteCodeItem] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    List(codes) { item in
                        HStack {
                            Text(item.code)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(LobsterWaterPalette.textColor)
                            Spacer()
                            if item.isUsed {
                                Text(MobileStrings.text(zh: "已使用", en: "Used", ru: "Использован", ko: "사용됨"))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(LobsterWaterPalette.tertiaryColor)
                            } else {
                                Button {
                                    UIPasteboard.general.string = item.code
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .tint(LobsterWaterPalette.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle(MobileStrings.text(zh: "我的邀请码", en: "My invite codes", ru: "Мои коды", ko: "내 초대 코드"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MobileStrings.text(zh: "完成", en: "Done", ru: "Готово", ko: "완료")) { dismiss() }
                }
            }
            .task {
                do {
                    codes = try await APIClient.shared.fetchMyInviteCodes()
                } catch {}
                isLoading = false
            }
        }
    }
}
