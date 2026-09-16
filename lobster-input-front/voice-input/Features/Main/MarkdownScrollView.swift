/// MarkdownScrollView.swift
/// NSTextView 包装的 Markdown 渲染组件。
/// 特性：
///   - 解析 Markdown（标题、加粗、斜体、行内代码、链接、表格）
///   - 链接点击直接打开系统浏览器（NSTextView 原生行为）
///   - 内容区可滚动（NSScrollView 包裹）
///   - 跟随项目科技风配色（深底色 + 霓虹字体色）
///   - maxHeight 限制滚动区高度
import SwiftUI
import AppKit

struct MarkdownScrollView: NSViewRepresentable {
    let text: String
    let maxHeight: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        let textView = MarkdownTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isAutomaticLinkDetectionEnabled = true

        // 禁用自动换行宽度限制，交给 scrollView 来控制
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // 链接点击打开浏览器
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(Cyber.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        // 只在文本变化时重新渲染，避免每次重绘都抖动
        let themeID = "\(ThemeStore.shared.mode.rawValue)-\(ThemeStore.shared.accent.rawValue)"
        if context.coordinator.lastText != text || context.coordinator.lastThemeID != themeID {
            context.coordinator.lastText = text
            context.coordinator.lastThemeID = themeID
            let attributed = MarkdownRenderer.render(text)
            textView.textStorage?.setAttributedString(attributed)
            // 滚回顶部
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastText: String = ""
        var lastThemeID: String = ""
    }
}

// MARK: - MarkdownTextView（支持链接点击）

private final class MarkdownTextView: NSTextView {
    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
        } else if let str = link as? String, let url = URL(string: str) {
            NSWorkspace.shared.open(url)
        }
    }

    // 确保 borderless panel 中也能正确响应滚轮事件
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - MarkdownRenderer
//
// 完整手写解析器：逐行处理块级元素（标题、分割线、空行、普通段落），
// 行内用正则处理 **bold**、*italic*、`code`、[link](url)。
// 不依赖 AttributedString(markdown:) API，避免 CommonMark 换行折叠、
// 标题属性难以识别等问题。

enum MarkdownRenderer {

    // MARK: - Public

    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // 表格检测：当前行是表格行且下一行是分隔行
            if isTableRow(line) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                var tableLines: [String] = []
                while i < lines.count && isTableRow(lines[i]) {
                    tableLines.append(lines[i])
                    i += 1
                }
                result.append(blockTable(tableLines))
                continue
            }

            i += 1

            if line.hasPrefix("### ") {
                result.append(blockHeading(String(line.dropFirst(4)), level: 3))
            } else if line.hasPrefix("## ") {
                result.append(blockHeading(String(line.dropFirst(3)), level: 2))
            } else if line.hasPrefix("# ") {
                result.append(blockHeading(String(line.dropFirst(2)), level: 1))
            } else if isHorizontalRule(line) {
                // 纯分隔线：整行只含 -、=、空格（且至少3个 - 或 =）
                result.append(blockDivider())
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                // 无序列表项
                let content = String(line.dropFirst(2))
                result.append(blockListItem(content))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
            } else {
                result.append(inlineParsed(line))
                result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
            }
        }
        return result
    }

    /// 判断是否为 Markdown 水平分隔线（--- 或 === 独占一行，不含其他字符）
    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let dashOnly = trimmed.allSatisfy { $0 == "-" || $0 == " " }
        let eqOnly   = trimmed.allSatisfy { $0 == "=" || $0 == " " }
        return dashOnly || eqOnly
    }

    // MARK: - Table helpers

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 分隔行形如 |---|---|---| 或 |:---|:---:|---:|
        guard trimmed.contains("|") else { return false }
        let stripped = trimmed.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        return stripped.isEmpty
    }

    private static func parseTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Base attrs

    private static var baseAttrs: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(Cyber.textBright),
        ]
    }

    // MARK: - Block elements

    private static func blockHeading(_ text: String, level: Int) -> NSAttributedString {
        let size: CGFloat = level == 1 ? 17 : (level == 2 ? 15 : 13)
        let color: NSColor
        switch level {
        case 1:  color = NSColor(Cyber.accent)
        case 2:  color = NSColor(Cyber.accent)
        default: color = NSColor(Cyber.accent).withAlphaComponent(0.8)
        }
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.paragraphSpacingBefore = level == 1 ? 10 : 6
        paraStyle.paragraphSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: paraStyle,
        ]
        // 先输出内联内容（标题文字本身也可能含有 **bold** 等）
        let inner = inlineParsed(text, overrideAttrs: attrs)
        let result = NSMutableAttributedString(attributedString: inner)
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        return result
    }

    private static func blockDivider() -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 5),
            .foregroundColor: NSColor(Cyber.accent).withAlphaComponent(0.25),
        ]
        return NSAttributedString(string: "──────────────────────\n", attributes: attrs)
    }

    private static func blockTable(_ lines: [String]) -> NSAttributedString {
        let dataLines = lines.filter { !isTableSeparator($0) }
        guard !dataLines.isEmpty else { return NSAttributedString() }

        // 解析所有行的单元格
        let rows = dataLines.map { parseTableCells($0) }
        let colCount = rows.map { $0.count }.max() ?? 1

        // 建立 NSTextTable
        let table = NSTextTable()
        table.numberOfColumns = colCount
        table.setContentWidth(100, type: .percentageValueType)

        let result = NSMutableAttributedString()

        for (rowIndex, cells) in rows.enumerated() {
            let isHeader = rowIndex == 0
            for colIndex in 0 ..< colCount {
                let cell = colIndex < cells.count ? cells[colIndex] : ""

                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                            startingColumn: colIndex, columnSpan: 1)
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: NSRectEdge.minY)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: NSRectEdge.maxY)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: NSRectEdge.minX)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: NSRectEdge.maxX)

                if isHeader {
                    block.backgroundColor = NSColor(Cyber.accent).withAlphaComponent(0.08)
                } else if rowIndex % 2 == 0 {
                    block.backgroundColor = NSColor.white.withAlphaComponent(0.03)
                }

                // 段落样式（含 NSTextTableBlock）
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.textBlocks = [block]
                paraStyle.alignment = .left
                paraStyle.lineBreakMode = .byWordWrapping

                let textColor = isHeader ? NSColor(Cyber.accent) : NSColor(Cyber.textBright)
                let font: NSFont = isHeader
                    ? NSFont.boldSystemFont(ofSize: 12)
                    : NSFont.systemFont(ofSize: 12)

                let cellAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paraStyle,
                ]

                // 渲染单元格内文字（支持行内 markdown）
                let cellContent = inlineParsed(cell, overrideAttrs: cellAttrs)
                let cellStr = NSMutableAttributedString(attributedString: cellContent)
                // 补全单元格末尾换行（NSTextTable 必需）
                cellStr.append(NSAttributedString(string: "\n", attributes: cellAttrs))
                result.append(cellStr)
            }
        }

        // 表格后补一个空行
        result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
        return result
    }

    private static func blockListItem(_ content: String) -> NSAttributedString {
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.headIndent = 16
        paraStyle.firstLineHeadIndent = 0
        paraStyle.paragraphSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(Cyber.textBright),
            .paragraphStyle: paraStyle,
        ]
        let bullet = NSAttributedString(string: "  • ", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(Cyber.accent).withAlphaComponent(0.7),
        ])
        let result = NSMutableAttributedString(attributedString: bullet)
        result.append(inlineParsed(content, overrideAttrs: attrs))
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        return result
    }

    // MARK: - Inline parsing（正则版）

    /// 解析行内 Markdown：**bold**、*italic*、`code`、[text](url)
    /// overrideAttrs：继承自上层块元素的属性（如标题字号/颜色），行内装饰在此基础上叠加
    private static func inlineParsed(
        _ line: String,
        overrideAttrs: [NSAttributedString.Key: Any]? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = overrideAttrs ?? baseAttrs
        var remaining = line[line.startIndex...]

        while !remaining.isEmpty {
            // 1. [link text](url)
            if let m = linkRegex.firstMatch(in: String(remaining), range: NSRange(remaining.startIndex..., in: remaining)) {
                let fullR  = Range(m.range,          in: remaining)!
                let textR  = Range(m.range(at: 1),   in: remaining)!
                let urlR   = Range(m.range(at: 2),   in: remaining)!
                let before = String(remaining[..<fullR.lowerBound])
                if !before.isEmpty { result.append(NSAttributedString(string: before, attributes: base)) }
                let displayText = String(remaining[textR])
                let urlStr = String(remaining[urlR])
                if let url = URL(string: urlStr) {
                    var linkA = base
                    linkA[.foregroundColor] = NSColor(Cyber.accent)
                    linkA[.link] = url
                    linkA[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    result.append(NSAttributedString(string: displayText, attributes: linkA))
                } else {
                    result.append(NSAttributedString(string: displayText, attributes: base))
                }
                remaining = remaining[fullR.upperBound...]
                continue
            }

            // 2. **bold** （必须在 *italic* 前匹配）
            if let m = boldRegex.firstMatch(in: String(remaining), range: NSRange(remaining.startIndex..., in: remaining)) {
                let fullR = Range(m.range,        in: remaining)!
                let innerR = Range(m.range(at: 1), in: remaining)!
                let before = String(remaining[..<fullR.lowerBound])
                if !before.isEmpty { result.append(NSAttributedString(string: before, attributes: base)) }
                var boldA = base
                let baseFont = base[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
                boldA[.font] = NSFont.boldSystemFont(ofSize: baseFont.pointSize)
                result.append(NSAttributedString(string: String(remaining[innerR]), attributes: boldA))
                remaining = remaining[fullR.upperBound...]
                continue
            }

            // 3. *italic*
            if let m = italicRegex.firstMatch(in: String(remaining), range: NSRange(remaining.startIndex..., in: remaining)) {
                let fullR  = Range(m.range,         in: remaining)!
                let innerR = Range(m.range(at: 1),  in: remaining)!
                let before = String(remaining[..<fullR.lowerBound])
                if !before.isEmpty { result.append(NSAttributedString(string: before, attributes: base)) }
                var italicA = base
                italicA[.foregroundColor] = NSColor(Cyber.textDim)
                italicA[.obliqueness] = 0.2
                result.append(NSAttributedString(string: String(remaining[innerR]), attributes: italicA))
                remaining = remaining[fullR.upperBound...]
                continue
            }

            // 4. `code`
            if let m = codeRegex.firstMatch(in: String(remaining), range: NSRange(remaining.startIndex..., in: remaining)) {
                let fullR  = Range(m.range,         in: remaining)!
                let innerR = Range(m.range(at: 1),  in: remaining)!
                let before = String(remaining[..<fullR.lowerBound])
                if !before.isEmpty { result.append(NSAttributedString(string: before, attributes: base)) }
                let codeA: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor(Cyber.accent),
                    .backgroundColor: NSColor.black.withAlphaComponent(0.3),
                ]
                result.append(NSAttributedString(string: String(remaining[innerR]), attributes: codeA))
                remaining = remaining[fullR.upperBound...]
                continue
            }

            // 无法匹配任何标记：输出第一个字符继续
            result.append(NSAttributedString(string: String(remaining.prefix(1)), attributes: base))
            remaining = remaining.dropFirst()
        }
        return result
    }

    // MARK: - Compiled regexes（只编译一次）

    // **bold** — 不允许内部含 **，不允许开头/结尾是空格
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"\*\*([^\*\s][^\*]*?[^\*\s]|\S)\*\*"#
    )
    // *italic* — 不允许 **，不允许开头/结尾是空格
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*([^\*\s][^\*]*?[^\*\s]|\S)\*(?!\*)"#
    )
    // `code`
    private static let codeRegex = try! NSRegularExpression(
        pattern: #"`([^`]+)`"#
    )
    // [text](url)
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(([^)]+)\)"#
    )
}
