import SwiftUI
import StoreKit

/// 套餐购买页(Apple IAP)。
/// 价格一律取自 StoreKit 本地化价格;权益入账以后端验签结果为准。
struct PaywallView: View {

    @StateObject private var iapManager = IAPManager.shared
    @StateObject private var authStore = AuthStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCycle: String = "monthly"
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var restoreSummary: String?
    @State private var showCancelRenewalConfirm = false
    @State private var cancellingRenewal = false

    private static let privacyURL = URL(string: "https://example.com/privacy")!
    private static let termsURL = URL(string: "https://example.com/terms")!

    var body: some View {
        NavigationStack {
            Group {
                switch iapManager.state {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable:
                    emptyState(MobileStrings.text(
                        zh: "内购暂未开放,敬请期待",
                        en: "In-app purchases are not available yet.",
                        ru: "Встроенные покупки пока недоступны.",
                        ko: "인앱 구매가 아직 제공되지 않습니다.",
                        zhHant: "內購暫未開放,敬請期待",
                        yue: "內購暫未開放,敬請期待"
                    ))
                case .failed(let message):
                    VStack(spacing: 12) {
                        emptyState(message)
                        Button(MobileStrings.text(zh: "重试", en: "Retry", ru: "Повторить", ko: "다시 시도", zhHant: "重試", yue: "重試")) {
                            Task { await iapManager.loadProducts(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .loaded:
                    content
                }
            }
            .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
            .navigationTitle(MobileStrings.text(zh: "套餐与购买", en: "Plans & Purchase", ru: "Тарифы", ko: "요금제", zhHant: "套餐與購買", yue: "套餐與購買"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LobsterWaterPalette.tertiaryColor)
                    }
                }
            }
            .alert(MobileStrings.text(zh: "提示", en: "Notice", ru: "Уведомление", ko: "알림"), isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .task {
                await iapManager.loadProducts()
                if !availableCycles.isEmpty && !availableCycles.contains(selectedCycle) {
                    selectedCycle = availableCycles[0]
                }
            }
        }
    }

    // MARK: - 主内容

    private var content: some View {
        List {
            currentPlanSection
            if !iapManager.subscriptionItems.isEmpty {
                subscriptionSection
            }
            if !iapManager.topupItems.isEmpty {
                topupSection
            }
            actionsSection
            legalSection
        }
        .scrollContentBackground(.hidden)
    }

    private var currentPlanSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MobileStrings.text(zh: "当前套餐", en: "Current plan", ru: "Текущий тариф", ko: "현재 요금제", zhHant: "當前套餐", yue: "而家嘅套餐"))
                        .font(.caption)
                        .foregroundStyle(LobsterWaterPalette.mutedColor)
                    Text(currentPlanDisplayName)
                        .font(.headline)
                        .foregroundStyle(LobsterWaterPalette.textColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(MobileStrings.text(zh: "剩余积分", en: "Credits left", ru: "Осталось кредитов", ko: "남은 크레딧", zhHant: "剩餘積分", yue: "剩返嘅積分"))
                        .font(.caption)
                        .foregroundStyle(LobsterWaterPalette.mutedColor)
                    Text("\(authStore.creditsRemaining)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(LobsterWaterPalette.textColor)
                }
            }
            if authStore.autoRenew {
                autoRenewRow
            }
        }
    }

    /// 自动续费状态行:
    /// - 可在应用内取消(renewal_cancellable)→ 展示下次续费日期 + 「取消自动续费」入口(二次确认);
    /// - 不可取消(用户在本机的 Apple 订阅)→ 仅提示已开启,取消走下方已有的「管理订阅」。
    @ViewBuilder
    private var autoRenewRow: some View {
        if authStore.renewalCancellable {
            HStack(spacing: 12) {
                Text(autoRenewStatusText)
                    .font(.subheadline)
                    .foregroundStyle(LobsterWaterPalette.mutedColor)
                Spacer()
                Button {
                    showCancelRenewalConfirm = true
                } label: {
                    if cancellingRenewal {
                        ProgressView()
                    } else {
                        Text(MobileStrings.text(zh: "取消自动续费", en: "Cancel auto-renewal", ru: "Отключить автопродление", ko: "자동 갱신 해지", zhHant: "取消自動續費", yue: "取消自動續費"))
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(cancellingRenewal)
                .alert(
                    MobileStrings.text(zh: "取消自动续费?", en: "Cancel auto-renewal?", ru: "Отключить автопродление?", ko: "자동 갱신을 해지할까요?", zhHant: "取消自動續費?", yue: "取消自動續費?"),
                    isPresented: $showCancelRenewalConfirm
                ) {
                    Button(
                        MobileStrings.text(zh: "确认取消", en: "Confirm", ru: "Отключить", ko: "해지", zhHant: "確認取消", yue: "確認取消"),
                        role: .destructive
                    ) {
                        Task { await cancelRenewal() }
                    }
                    Button(
                        MobileStrings.text(zh: "暂不取消", en: "Keep", ru: "Оставить", ko: "유지", zhHant: "暫不取消", yue: "暫時唔取消"),
                        role: .cancel
                    ) {}
                } message: {
                    Text(cancelRenewalConfirmText)
                }
            }
        } else {
            Text(MobileStrings.text(zh: "自动续费已开启", en: "Auto-renewal is on", ru: "Автопродление включено", ko: "자동 갱신이 켜져 있습니다", zhHant: "自動續費已開啟", yue: "自動續費已經開咗"))
                .font(.subheadline)
                .foregroundStyle(LobsterWaterPalette.mutedColor)
        }
    }

    private var subscriptionSection: some View {
        Section {
            if availableCycles.count > 1 {
                Picker("", selection: $selectedCycle) {
                    ForEach(availableCycles, id: \.self) { cycle in
                        Text(cycleLabel(cycle)).tag(cycle)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            ForEach(displayedSubscriptionItems) { item in
                subscriptionRow(item)
            }
        } header: {
            Text(MobileStrings.text(zh: "订阅套餐", en: "Subscriptions", ru: "Подписки", ko: "구독", zhHant: "訂閱套餐", yue: "訂閱套餐"))
        } footer: {
            Text(MobileStrings.text(
                zh: "订阅将通过您的 Apple 账户自动续期,可随时在系统设置或下方「管理订阅」中取消。",
                en: "Subscriptions auto-renew via your Apple account. Cancel anytime in Settings or via Manage Subscriptions below.",
                ru: "Подписка продлевается автоматически через ваш аккаунт Apple. Отменить можно в настройках или через «Управление подписками».",
                ko: "구독은 Apple 계정을 통해 자동 갱신됩니다. 설정 또는 아래 '구독 관리'에서 언제든지 취소할 수 있습니다.",
                zhHant: "訂閱將透過您的 Apple 帳戶自動續期,可隨時在系統設定或下方「管理訂閱」中取消。",
                yue: "訂閱會經你嘅 Apple 帳戶自動續期,隨時可以喺系統設定或者下面「管理訂閱」取消。"
            ))
        }
    }

    private func subscriptionRow(_ item: IAPManager.PaywallItem) -> some View {
        let isCurrentPlan = item.info.planCode == authStore.tier
        let blocked = isDowngradeBlocked(item)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.info.planName ?? item.info.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LobsterWaterPalette.textColor)
                    if isCurrentPlan {
                        Text(MobileStrings.text(zh: "当前", en: "Current", ru: "Текущий", ko: "현재", zhHant: "當前", yue: "而家"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LobsterWaterPalette.accentGradient, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                if let credits = item.info.planCredits, credits > 0 {
                    Text(MobileStrings.text(
                        zh: "每期 \(credits) 积分",
                        en: "\(credits) credits / period",
                        ru: "\(credits) кредитов / период",
                        ko: "기간당 \(credits) 크레딧",
                        zhHant: "每期 \(credits) 積分",
                        yue: "每期 \(credits) 積分"
                    ))
                    .font(.caption)
                    .foregroundStyle(LobsterWaterPalette.mutedColor)
                }
            }
            Spacer()
            purchaseButton(item, title: item.displayPrice, disabled: blocked)
        }
        .opacity(blocked ? 0.5 : 1)
    }

    private var topupSection: some View {
        Section {
            ForEach(iapManager.topupItems) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.info.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LobsterWaterPalette.textColor)
                        if let credits = item.info.topupCredits, credits > 0 {
                            Text(MobileStrings.text(
                                zh: "+\(credits) 积分",
                                en: "+\(credits) credits",
                                ru: "+\(credits) кредитов",
                                ko: "+\(credits) 크레딧",
                                zhHant: "+\(credits) 積分",
                                yue: "+\(credits) 積分"
                            ))
                            .font(.caption)
                            .foregroundStyle(LobsterWaterPalette.mutedColor)
                        }
                    }
                    Spacer()
                    purchaseButton(item, title: item.displayPrice, disabled: false)
                }
            }
        } header: {
            Text(MobileStrings.text(zh: "积分加购", en: "Credit top-up", ru: "Докупить кредиты", ko: "크레딧 충전", zhHant: "積分加購", yue: "積分加購"))
        } footer: {
            Text(MobileStrings.text(
                zh: "加购积分仅限付费套餐且套餐积分用尽后购买,有效期与当前订阅一致。",
                en: "Top-ups require an active paid plan with exhausted plan credits, and expire with your subscription.",
                ru: "Докупка доступна на платном тарифе после израсходования кредитов и действует до конца подписки.",
                ko: "충전은 유료 요금제에서 크레딧 소진 후 가능하며, 구독 만료 시 함께 만료됩니다.",
                zhHant: "加購積分僅限付費套餐且套餐積分用盡後購買,有效期與當前訂閱一致。",
                yue: "加購積分只限付費套餐並且用晒套餐積分之後先可以買,有效期同而家嘅訂閱一樣。"
            ))
        }
    }

    private func purchaseButton(_ item: IAPManager.PaywallItem, title: String, disabled: Bool) -> some View {
        Button {
            Task { await purchase(item) }
        } label: {
            Group {
                if iapManager.purchasingProductId == item.id {
                    ProgressView()
                } else {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                }
            }
            .frame(minWidth: 72)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled || iapManager.purchasingProductId != nil)
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await restore() }
            } label: {
                HStack {
                    Label(MobileStrings.text(zh: "恢复购买", en: "Restore Purchases", ru: "Восстановить покупки", ko: "구매 복원", zhHant: "恢復購買", yue: "恢復購買"), systemImage: "arrow.clockwise")
                        .foregroundStyle(LobsterWaterPalette.textColor)
                    Spacer()
                    if iapManager.restoring { ProgressView() }
                }
            }
            .disabled(iapManager.restoring)
            Button {
                Task { await iapManager.showManageSubscriptions() }
            } label: {
                Label(MobileStrings.text(zh: "管理订阅", en: "Manage Subscriptions", ru: "Управление подписками", ko: "구독 관리", zhHant: "管理訂閱", yue: "管理訂閱"), systemImage: "gearshape")
                    .foregroundStyle(LobsterWaterPalette.textColor)
            }
        }
    }

    private var legalSection: some View {
        Section {
            HStack(spacing: 16) {
                Link(MobileStrings.text(zh: "用户协议", en: "Terms of Use", ru: "Условия", ko: "이용약관", zhHant: "用戶協議", yue: "用戶協議"), destination: Self.termsURL)
                Link(MobileStrings.text(zh: "隐私政策", en: "Privacy Policy", ru: "Конфиденциальность", ko: "개인정보 처리방침", zhHant: "隱私政策", yue: "私隱政策"), destination: Self.privacyURL)
            }
            .font(.caption)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - 逻辑

    private var availableCycles: [String] {
        var seen: [String] = []
        for item in iapManager.subscriptionItems {
            if let cycle = item.info.billingCycle, !seen.contains(cycle) {
                seen.append(cycle)
            }
        }
        return seen
    }

    private var displayedSubscriptionItems: [IAPManager.PaywallItem] {
        let matched = iapManager.subscriptionItems.filter { $0.info.billingCycle == selectedCycle }
        return matched.isEmpty ? iapManager.subscriptionItems : matched
    }

    private var currentPlanDisplayName: String {
        if let item = iapManager.subscriptionItems.first(where: { $0.info.planCode == authStore.tier }) {
            return item.info.planName ?? authStore.tier
        }
        return authStore.tier
    }

    private var currentPlanRank: Int {
        iapManager.subscriptionItems.first(where: { $0.info.planCode == authStore.tier })?.info.planRank ?? 0
    }

    /// 有效付费套餐期间不允许购买更低等级套餐(与后端规则一致,仅做前置拦截)。
    private func isDowngradeBlocked(_ item: IAPManager.PaywallItem) -> Bool {
        guard currentPlanRank > 0 else { return false }
        return (item.info.planRank ?? 0) < currentPlanRank
    }

    private func cycleLabel(_ cycle: String) -> String {
        switch cycle {
        case "monthly":
            return MobileStrings.text(zh: "月付", en: "Monthly", ru: "Месяц", ko: "월간", zhHant: "月付", yue: "月付")
        case "quarterly":
            return MobileStrings.text(zh: "季付", en: "Quarterly", ru: "Квартал", ko: "분기", zhHant: "季付", yue: "季付")
        case "yearly":
            return MobileStrings.text(zh: "年付", en: "Yearly", ru: "Год", ko: "연간", zhHant: "年付", yue: "年付")
        default:
            return cycle
        }
    }

    /// 下次续费/到期日期(本地化年月日),优先取 next_renewal_at,回退订阅/套餐到期时间
    private var nextRenewalDisplayDate: String? {
        AuthStore.formatServerDate(authStore.nextRenewalAt) ?? authStore.formattedExpiryDate()
    }

    private var autoRenewStatusText: String {
        if let date = nextRenewalDisplayDate {
            return MobileStrings.text(
                zh: "将于 \(date) 自动续费",
                en: "Auto-renews on \(date)",
                ru: "Автопродление \(date)",
                ko: "\(date)에 자동 갱신",
                zhHant: "將於 \(date) 自動續費",
                yue: "會喺 \(date) 自動續費"
            )
        }
        return MobileStrings.text(
            zh: "自动续费已开启",
            en: "Auto-renewal is on",
            ru: "Автопродление включено",
            ko: "자동 갱신이 켜져 있습니다",
            zhHant: "自動續費已開啟",
            yue: "自動續費已經開咗"
        )
    }

    private var cancelRenewalConfirmText: String {
        if let date = nextRenewalDisplayDate {
            return MobileStrings.text(
                zh: "取消后套餐仍可使用至 \(date),到期后不再自动扣费。",
                en: "After cancelling, your plan stays active until \(date) and you won't be charged again.",
                ru: "После отключения тариф действует до \(date), дальнейших списаний не будет.",
                ko: "해지 후에도 \(date)까지 요금제를 이용할 수 있으며, 이후에는 요금이 청구되지 않습니다.",
                zhHant: "取消後套餐仍可使用至 \(date),到期後不再自動扣費。",
                yue: "取消之後套餐照用得到 \(date),到期之後唔會再自動扣錢。"
            )
        }
        return MobileStrings.text(
            zh: "取消后套餐仍可使用至本期结束,到期后不再自动扣费。",
            en: "After cancelling, your plan stays active until the end of the current period and you won't be charged again.",
            ru: "После отключения тариф действует до конца текущего периода, дальнейших списаний не будет.",
            ko: "해지 후에도 현재 기간이 끝날 때까지 요금제를 이용할 수 있으며, 이후에는 요금이 청구되지 않습니다.",
            zhHant: "取消後套餐仍可使用至本期結束,到期後不再自動扣費。",
            yue: "取消之後套餐照用到今期完,到期之後唔會再自動扣錢。"
        )
    }

    private func cancelRenewal() async {
        cancellingRenewal = true
        defer { cancellingRenewal = false }
        do {
            let resp = try await APIClient.shared.cancelSubscriptionRenewal()
            switch resp.status {
            case "cancelled", "already_cancelled":
                await authStore.refreshPlanInfo()
                if let date = AuthStore.formatServerDate(resp.effectiveUntil) ?? nextRenewalDisplayDate {
                    alertMessage = MobileStrings.text(
                        zh: "已取消自动续费,套餐仍可使用至 \(date)。",
                        en: "Auto-renewal cancelled. Your plan stays active until \(date).",
                        ru: "Автопродление отключено. Тариф действует до \(date).",
                        ko: "자동 갱신이 해지되었습니다. \(date)까지 요금제를 이용할 수 있습니다.",
                        zhHant: "已取消自動續費,套餐仍可使用至 \(date)。",
                        yue: "取消咗自動續費喇,套餐照用得到 \(date)。"
                    )
                } else {
                    alertMessage = MobileStrings.text(
                        zh: "已取消自动续费。",
                        en: "Auto-renewal cancelled.",
                        ru: "Автопродление отключено.",
                        ko: "자동 갱신이 해지되었습니다.",
                        zhHant: "已取消自動續費。",
                        yue: "取消咗自動續費喇。"
                    )
                }
                showAlert = true
            case "apple_managed":
                // 防御路径:该订阅由 App Store 管理(理论上 UI 不会走到这里)
                await authStore.refreshPlanInfo()
                alertMessage = MobileStrings.text(
                    zh: "该订阅由 App Store 管理,请通过下方「管理订阅」取消。",
                    en: "This subscription is managed by the App Store. Use Manage Subscriptions below to cancel.",
                    ru: "Эта подписка управляется через App Store. Отмените её через «Управление подписками» ниже.",
                    ko: "이 구독은 App Store에서 관리됩니다. 아래 '구독 관리'에서 해지해 주세요.",
                    zhHant: "該訂閱由 App Store 管理,請透過下方「管理訂閱」取消。",
                    yue: "呢個訂閱由 App Store 管理,請用下面「管理訂閱」取消。"
                )
                showAlert = true
            default:
                // 未知状态:刷新后按失败提示,避免误导
                await authStore.refreshPlanInfo()
                alertMessage = MobileStrings.text(
                    zh: "操作未完成,请稍后重试。",
                    en: "The operation didn't complete. Please try again later.",
                    ru: "Операция не завершена. Повторите попытку позже.",
                    ko: "작업이 완료되지 않았습니다. 나중에 다시 시도해 주세요.",
                    zhHant: "操作未完成,請稍後重試。",
                    yue: "操作未完成,遲啲再試過啦。"
                )
                showAlert = true
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func purchase(_ item: IAPManager.PaywallItem) async {
        do {
            let outcome = try await iapManager.purchase(item)
            switch outcome {
            case .success:
                alertMessage = MobileStrings.text(
                    zh: "购买成功,权益已生效",
                    en: "Purchase complete. Your plan is now active.",
                    ru: "Покупка завершена. Тариф активирован.",
                    ko: "구매가 완료되었습니다. 요금제가 활성화되었습니다.",
                    zhHant: "購買成功,權益已生效",
                    yue: "買好喇,權益已經生效"
                )
                showAlert = true
            case .pending:
                alertMessage = MobileStrings.text(
                    zh: "购买等待批准中,批准后将自动生效",
                    en: "Purchase is pending approval and will apply automatically once approved.",
                    ru: "Покупка ожидает одобрения и будет применена автоматически.",
                    ko: "구매 승인 대기 중입니다. 승인되면 자동으로 적용됩니다.",
                    zhHant: "購買等待批准中,批准後將自動生效",
                    yue: "購買等緊批准,批准之後會自動生效"
                )
                showAlert = true
            case .cancelled:
                break
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func restore() async {
        do {
            let count = try await iapManager.restorePurchases()
            alertMessage = count > 0
                ? MobileStrings.text(
                    zh: "已恢复 \(count) 笔购买",
                    en: "Restored \(count) purchase(s).",
                    ru: "Восстановлено покупок: \(count).",
                    ko: "\(count)건의 구매를 복원했습니다.",
                    zhHant: "已恢復 \(count) 筆購買",
                    yue: "恢復咗 \(count) 筆購買"
                )
                : MobileStrings.text(
                    zh: "没有可恢复的购买",
                    en: "No purchases to restore.",
                    ru: "Нет покупок для восстановления.",
                    ko: "복원할 구매가 없습니다.",
                    zhHant: "沒有可恢復的購買",
                    yue: "冇可以恢復嘅購買"
                )
            showAlert = true
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "cart")
                .font(.system(size: 36))
                .foregroundStyle(LobsterWaterPalette.tertiaryColor)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LobsterWaterPalette.mutedColor)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
