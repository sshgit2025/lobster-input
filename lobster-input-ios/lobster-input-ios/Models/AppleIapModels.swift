import Foundation

// MARK: - Apple IAP(应用内购买)

/// 后端下发的内购商品映射(Apple 商品 ID ↔ 套餐/积分加购)。
struct AppleIapProduct: Decodable, Identifiable {
    let appleProductId: String
    let type: String            // subscription / credits_topup
    let name: String
    let sortOrder: Int
    let planCode: String?
    let billingCycle: String?   // monthly / quarterly / yearly
    let planName: String?
    let planCredits: Int?
    let planRank: Int?
    let topupCredits: Int?

    var id: String { appleProductId }
    var isSubscription: Bool { type == "subscription" }

    enum CodingKeys: String, CodingKey {
        case appleProductId = "apple_product_id"
        case type
        case name
        case sortOrder      = "sort_order"
        case planCode       = "plan_code"
        case billingCycle   = "billing_cycle"
        case planName       = "plan_name"
        case planCredits    = "plan_credits"
        case planRank       = "plan_rank"
        case topupCredits   = "topup_credits"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appleProductId = (try? c.decode(String.self, forKey: .appleProductId)) ?? ""
        type           = (try? c.decode(String.self, forKey: .type)) ?? ""
        name           = (try? c.decode(String.self, forKey: .name)) ?? ""
        sortOrder      = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
        planCode       = try? c.decode(String.self, forKey: .planCode)
        billingCycle   = try? c.decode(String.self, forKey: .billingCycle)
        planName       = try? c.decode(String.self, forKey: .planName)
        planCredits    = try? c.decode(Int.self, forKey: .planCredits)
        planRank       = try? c.decode(Int.self, forKey: .planRank)
        topupCredits   = try? c.decode(Int.self, forKey: .topupCredits)
    }
}

struct AppleIapProductsResponse: Decodable {
    let enabled: Bool
    let products: [AppleIapProduct]
    let appAccountToken: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case products
        case appAccountToken = "app_account_token"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled         = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        products        = (try? c.decode([AppleIapProduct].self, forKey: .products)) ?? []
        appAccountToken = (try? c.decode(String.self, forKey: .appAccountToken)) ?? ""
    }
}

struct AppleVerifyRequestBody: Encodable {
    let signedTransaction: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case signedTransaction = "signed_transaction"
        case source
    }
}

struct AppleRestoreRequestBody: Encodable {
    let signedTransactions: [String]

    enum CodingKeys: String, CodingKey {
        case signedTransactions = "signed_transactions"
    }
}

struct AppleVerifyResult: Decodable {
    let status: String?
    let reason: String?
}

struct AppleVerifyResponse: Decodable {
    let result: AppleVerifyResult?
    let plan: UserPlanInfo?
}

struct AppleRestoreResponse: Decodable {
    let results: [AppleVerifyResult]?
    let plan: UserPlanInfo?
}
