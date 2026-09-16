import Combine
import Foundation
import StoreKit
import UIKit

/// StoreKit 2 内购管理器。
///
/// 安全模型:客户端本地不发放任何权益。购买/续订/恢复得到的 JWS(signedTransaction)
/// 一律提交给后端验签入账,入账成功后才 finish 交易;失败则保留交易,
/// 由 `Transaction.updates` 监听在后续启动时自动补偿重试,保证不丢单。
@MainActor
final class IAPManager: ObservableObject {

    static let shared = IAPManager()

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable      // 服务端未启用或无商品
        case failed(String)
    }

    /// 后端映射 + StoreKit 商品合并后的可购买项。
    struct PaywallItem: Identifiable {
        let info: AppleIapProduct
        let product: Product

        var id: String { info.appleProductId }
        var displayPrice: String { product.displayPrice }
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var subscriptionItems: [PaywallItem] = []
    @Published private(set) var topupItems: [PaywallItem] = []
    @Published private(set) var purchasingProductId: String?
    @Published private(set) var restoring = false

    private var appAccountToken: UUID?
    private var updatesTask: Task<Void, Never>?

    private init() {
        startTransactionListener()
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - 商品加载

    func loadProducts(force: Bool = false) async {
        if state == .loading { return }
        if state == .loaded && !force { return }
        guard AuthStore.shared.isLoggedIn else {
            state = .unavailable
            return
        }
        state = .loading
        do {
            let response = try await APIClient.shared.fetchAppleIapProducts()
            guard response.enabled, !response.products.isEmpty else {
                subscriptionItems = []
                topupItems = []
                state = .unavailable
                return
            }
            appAccountToken = UUID(uuidString: response.appAccountToken)
            let ids = response.products.map(\.appleProductId)
            let storeProducts = try await Product.products(for: ids)
            let productsById = Dictionary(uniqueKeysWithValues: storeProducts.map { ($0.id, $0) })
            var subscriptions: [PaywallItem] = []
            var topups: [PaywallItem] = []
            for info in response.products.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard let product = productsById[info.appleProductId] else { continue }
                let item = PaywallItem(info: info, product: product)
                if info.isSubscription {
                    subscriptions.append(item)
                } else {
                    topups.append(item)
                }
            }
            subscriptionItems = subscriptions
            topupItems = topups
            state = (subscriptions.isEmpty && topups.isEmpty) ? .unavailable : .loaded
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    // MARK: - 购买

    enum PurchaseOutcome {
        case success
        case pending          // 家长审批(Ask to Buy)等待中
        case cancelled
    }

    func purchase(_ item: PaywallItem) async throws -> PurchaseOutcome {
        guard purchasingProductId == nil else { return .cancelled }
        purchasingProductId = item.id
        defer { purchasingProductId = nil }

        var options: Set<Product.PurchaseOption> = []
        if let token = appAccountToken {
            options.insert(.appAccountToken(token))
        }
        let result = try await item.product.purchase(options: options)
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw IAPError.unverifiedTransaction
            }
            try await submitToBackend(jws: verification.jwsRepresentation, source: "purchase")
            await transaction.finish()
            return .success
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    // MARK: - 恢复购买

    func restorePurchases() async throws -> Int {
        guard !restoring else { return 0 }
        restoring = true
        defer { restoring = false }

        try? await AppStore.sync()
        var payloads: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified = result {
                payloads.append(result.jwsRepresentation)
            }
        }
        guard !payloads.isEmpty else { return 0 }
        let response = try await APIClient.shared.restoreApplePurchases(signedTransactions: payloads)
        if let plan = response.plan {
            AuthStore.shared.updatePlan(plan)
        }
        let applied = (response.results ?? []).filter { $0.status == "applied" || $0.status == "duplicate" }
        return applied.count
    }

    // MARK: - 交易监听(续订、Ask to Buy 通过、离线补偿)

    private func startTransactionListener() {
        updatesTask = Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                await self?.handleTransactionUpdate(result)
            }
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        guard AuthStore.shared.isLoggedIn else { return }
        do {
            try await submitToBackend(jws: result.jwsRepresentation, source: "listener")
            await transaction.finish()
        } catch {
            // 不 finish,交易保留在队列中,下次启动会再次收到并重试
        }
    }

    // MARK: - 后端入账

    private func submitToBackend(jws: String, source: String) async throws {
        let response = try await APIClient.shared.verifyAppleTransaction(signedTransaction: jws, source: source)
        if let plan = response.plan {
            AuthStore.shared.updatePlan(plan)
        }
        let status = response.result?.status ?? ""
        // applied=已入账 duplicate=幂等重放 ignored=过期/撤销等确定性终态,均视为可 finish
        guard ["applied", "duplicate", "ignored"].contains(status) else {
            throw IAPError.backendRejected(status.isEmpty ? "unknown" : status)
        }
    }

    // MARK: - 订阅管理

    func showManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
    }

    // MARK: - 错误

    enum IAPError: LocalizedError {
        case unverifiedTransaction
        case backendRejected(String)

        var errorDescription: String? {
            switch self {
            case .unverifiedTransaction:
                return MobileStrings.text(
                    zh: "交易校验失败,请稍后重试",
                    en: "Transaction verification failed. Please try again.",
                    ru: "Не удалось проверить транзакцию. Повторите попытку.",
                    ko: "거래 검증에 실패했습니다. 다시 시도해 주세요.",
                    zhHant: "交易校驗失敗,請稍後重試",
                    yue: "交易校驗失敗,請遲啲再試"
                )
            case .backendRejected(let status):
                return MobileStrings.text(
                    zh: "购买入账失败(\(status)),请稍后在设置中恢复购买",
                    en: "Purchase could not be applied (\(status)). Try Restore Purchases later.",
                    ru: "Не удалось применить покупку (\(status)). Попробуйте восстановить покупки позже.",
                    ko: "구매 반영에 실패했습니다(\(status)). 나중에 구매 복원을 시도해 주세요.",
                    zhHant: "購買入賬失敗(\(status)),請稍後在設定中恢復購買",
                    yue: "購買入賬失敗(\(status)),請遲啲喺設定度恢復購買"
                )
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }
}
