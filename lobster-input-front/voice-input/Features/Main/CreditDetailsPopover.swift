import SwiftUI

struct CreditDetailsPopover: View {
    @ObservedObject private var authStore = AuthStore.shared
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.accountCreditsDetailsShow)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
            ForEach(authStore.creditItems) { item in
                creditItemRow(item)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Cyber.panelBg)
    }

    private func creditItemRow(_ item: CreditBalanceItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(creditItemName(item))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textDim)
                Spacer()
                Text("\(item.creditsRemaining) / \(item.creditsTotal)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
            }
            HStack {
                Text("\(L10n.accountCreditsUsed) \(item.creditsUsed)")
                Spacer()
                Text(expiryText(item.expiresAt))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Cyber.textGhost)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Cyber.sidebarBg)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Cyber.accent)
                        .frame(width: geo.size.width * creditRatio(item), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Cyber.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Cyber.accent.opacity(0.14), lineWidth: 0.6))
    }

    private func creditRatio(_ item: CreditBalanceItem) -> CGFloat {
        guard item.creditsTotal > 0 else { return 0 }
        return min(1.0, CGFloat(max(item.creditsRemaining, 0)) / CGFloat(item.creditsTotal))
    }

    private func creditItemName(_ item: CreditBalanceItem) -> String {
        switch item.type {
        case "plan": return localizedPlanName(item.source)
        case "bonus": return L10n.creditItemBonus
        case "paid_topup": return L10n.creditItemPaidTopup
        default: return item.label.isEmpty ? item.source : item.label
        }
    }

    private func expiryText(_ raw: String?) -> String {
        guard let raw, let date = formatCreditDate(raw) else { return L10n.creditItemNoExpiry }
        return L10n.creditItemExpires(date)
    }

    private func formatCreditDate(_ raw: String) -> String? {
        guard let date = parseServerDate(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = lang.current.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func parseServerDate(_ raw: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: raw) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
