import AppKit

struct PasteboardSnapshot: Sendable {
    private let items: [[String: Data]]?

    nonisolated init(pasteboard: NSPasteboard = .general) {
        items = pasteboard.pasteboardItems?.compactMap { item -> [String: Data]? in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict.isEmpty ? nil : dict
        }
    }

    @discardableResult
    nonisolated func restoreIfUnchanged(
        to pasteboard: NSPasteboard = .general,
        expectedChangeCount: Int,
        expectedString: String? = nil
    ) -> Bool {
        if pasteboard.changeCount != expectedChangeCount {
            if let expectedString,
               pasteboard.string(forType: .string) == expectedString {
                restore(to: pasteboard)
                return true
            }
            return false
        }

        restore(to: pasteboard)
        return true
    }

    nonisolated func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard let items else { return }

        for dict in items {
            let item = NSPasteboardItem()
            for (typeStr, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
            pasteboard.writeObjects([item])
        }
    }
}
