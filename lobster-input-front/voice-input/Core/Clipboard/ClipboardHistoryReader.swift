/// ClipboardHistoryReader.swift
/// 系统剪贴板内容读取工具。
/// 录音开始前调用，将剪贴板最近内容作为 LLM 上下文发送给后端。
/// 读取行为受用户设置中的"剪贴板读取"开关控制，默认关闭。
import AppKit

struct ClipboardContextItem: Codable, Sendable {
    let kind: String
    let mimeType: String?
    let text: String?
    let dataUrl: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case mimeType = "mime_type"
        case text
        case dataUrl = "data_url"
    }
}

enum ContextCaptureWorker {
    nonisolated private static let queue = DispatchQueue(label: "ssh2026.voice-input.context-capture", qos: .utility)

    nonisolated static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}

struct ClipboardHistoryReader {

    nonisolated private static let enabledKey = "settings_clipboard_access_enabled"
    nonisolated private static let compressionDataURLThresholdBytes = 300_000
    nonisolated private static let maxDataURLBytes = 5_000_000

    private enum RawClipboardItem: Sendable {
        case text(String)
        case imageData(mimeType: String, Data)
        case tiffData(Data)
    }

    /// 是否允许读取剪贴板（本地配置，默认关闭）
    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 读取系统剪贴板当前内容（最多 maxItems 条）
    /// 若用户未开启剪贴板读取权限，直接返回空数组，不访问剪贴板。
    /// macOS 通用剪贴板只保留最新一条；多条来自 pasteboardItems
    nonisolated static func read(maxItems: Int = 5) -> [String] {
        return readTextOnly(maxItems: maxItems)
    }

    nonisolated static func readTextOnly(maxItems: Int = 5) -> [String] {
        guard isEnabled else { return [] }

        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return [] }

        return items.prefix(maxItems).compactMap { item in
            guard let text = item.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return text
        }
    }

    nonisolated static func readTextOnlyAsync(maxItems: Int = 5) async -> [String] {
        await ContextCaptureWorker.run {
            readTextOnly(maxItems: maxItems)
        }
    }

    nonisolated static func readItems(maxItems: Int = 5) -> [ClipboardContextItem] {
        guard isEnabled else { return [] }

        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return [] }

        var results: [ClipboardContextItem] = []
        for item in items.prefix(maxItems) {
            if let text = item.string(forType: .string),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(ClipboardContextItem(kind: "text", mimeType: nil, text: text, dataUrl: nil))
            } else if let image = imageContextItem(from: item) {
                results.append(image)
            }
        }
        logItems(results, source: "readItems")
        return results
    }

    nonisolated static func readItemsNonBlocking(maxItems: Int = 5) async -> [ClipboardContextItem] {
        await ContextCaptureWorker.run {
            guard isEnabled else { return [] }

            let pb = NSPasteboard.general
            guard let items = pb.pasteboardItems else { return [] }

            var rawItems: [RawClipboardItem] = []
            for item in items.prefix(maxItems) {
                if let text = item.string(forType: .string),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rawItems.append(.text(text))
                } else if let data = item.data(forType: .png) {
                    rawItems.append(.imageData(mimeType: "image/png", data))
                } else if let data = item.data(forType: .tiff) {
                    rawItems.append(.tiffData(data))
                }
            }

            let results = rawItems.compactMap { raw in
                contextItem(from: raw)
            }
            logItems(results, source: "readItemsNonBlocking")
            return results
        }
    }

    nonisolated private static func contextItem(from raw: RawClipboardItem) -> ClipboardContextItem? {
        switch raw {
        case .text(let text):
            return ClipboardContextItem(kind: "text", mimeType: nil, text: text, dataUrl: nil)
        case .imageData(let mimeType, let data):
            return imageContextItem(from: data, originalMimeType: mimeType)
        case .tiffData(let data):
            return imageContextItem(from: data, originalMimeType: "image/tiff")
        }
    }

    nonisolated private static func imageContextItem(from item: NSPasteboardItem) -> ClipboardContextItem? {
        if let data = item.data(forType: .png),
           let result = imageContextItem(from: data, originalMimeType: "image/png") {
            return result
        }
        guard let tiff = item.data(forType: .tiff) else {
            return nil
        }
        return imageContextItem(from: tiff, originalMimeType: "image/tiff")
    }

    nonisolated private static func imageContextItem(
        from data: Data,
        originalMimeType: String
    ) -> ClipboardContextItem? {
        if originalMimeType == "image/png",
           let dataURL = makeDataURL(mimeType: "image/png", data: data),
           dataURL.utf8.count <= compressionDataURLThresholdBytes {
            return ClipboardContextItem(kind: "image", mimeType: "image/png", text: nil, dataUrl: dataURL)
        }

        guard let image = NSImage(data: data),
              let jpeg = compressedJPEGData(from: image),
              let dataURL = makeDataURL(mimeType: "image/jpeg", data: jpeg),
              dataURL.utf8.count < maxDataURLBytes else {
            DebugTrace.log("Clipboard: image skipped because compressed data exceeds limit originalMime=\(originalMimeType) rawBytes=\(data.count)")
            return nil
        }
        return ClipboardContextItem(kind: "image", mimeType: "image/jpeg", text: nil, dataUrl: dataURL)
    }

    nonisolated private static func compressedJPEGData(from image: NSImage) -> Data? {
        let qualities: [CGFloat] = [0.86, 0.74, 0.62, 0.5, 0.38, 0.28, 0.2]
        guard let rep = bitmapRepresentation(from: image) else { return nil }
        var smallestAcceptable: Data?
        var smallestLength = Int.max

        for quality in qualities {
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                continue
            }
            guard let dataURL = makeDataURL(mimeType: "image/jpeg", data: data) else { continue }
            let dataURLLength = dataURL.utf8.count
            guard dataURLLength < maxDataURLBytes else { continue }
            if dataURLLength < smallestLength {
                smallestLength = dataURLLength
                smallestAcceptable = data
            }
            if dataURLLength <= compressionDataURLThresholdBytes {
                return data
            }
        }
        return smallestAcceptable
    }

    nonisolated private static func bitmapRepresentation(
        from image: NSImage
    ) -> NSBitmapImageRep? {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let targetSize = NSSize(
            width: max(1, floor(originalSize.width)),
            height: max(1, floor(originalSize.height))
        )

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else { return nil }
        bitmap.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmap
    }

    nonisolated private static func makeDataURL(mimeType: String, data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    nonisolated private static func logItems(_ items: [ClipboardContextItem], source: String) {
        let textCount = items.filter { $0.kind == "text" }.count
        let imageSummaries = items
            .filter { $0.kind == "image" }
            .map { item -> String in
                let mime = item.mimeType ?? "unknown"
                let bytes = item.dataUrl?.utf8.count ?? 0
                return "\(mime):\(bytes)"
            }
            .joined(separator: ",")
        DebugTrace.log("Clipboard: \(source) enabled=\(isEnabled) textCount=\(textCount) imageItems=[\(imageSummaries)]")
    }
}
