using System.Diagnostics;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using LobsterInput.Services;

namespace LobsterInput.Views;

internal static class MarkdownTheme
{
    public static void Apply(FlowDocument doc, FrameworkElement resourceScope, double fontSize = 13)
    {
        var palette = MarkdownPalette.From(resourceScope);

        doc.FontFamily = palette.BodyFont;
        doc.FontSize = fontSize;
        doc.Foreground = palette.Body;
        doc.Background = Brushes.Transparent;
        doc.LineHeight = fontSize * 1.58;

        ApplyToBlocks(doc.Blocks, palette, fontSize);
    }

    private static void ApplyToBlocks(BlockCollection blocks, MarkdownPalette palette, double fontSize)
    {
        foreach (var block in blocks)
        {
            var isCodeBlock = IsCodeLike(block.FontFamily) || HasVisibleBackground(block.Background);

            block.Foreground = palette.Body;
            block.FontFamily = isCodeBlock ? palette.MonoFont : palette.BodyFont;
            block.LineHeight = fontSize * 1.58;

            if (block is Paragraph paragraph)
                ApplyToParagraph(paragraph, palette, fontSize, isCodeBlock);
            else if (block is Section section)
                ApplyToSection(section, palette, fontSize);
            else if (block is System.Windows.Documents.List list)
                ApplyToList(list, palette, fontSize);
            else if (block is Table table)
                ApplyToTable(table, palette, fontSize);
        }
    }

    private static void ApplyToParagraph(Paragraph paragraph, MarkdownPalette palette, double fontSize, bool isCodeBlock)
    {
        var headingLevel = HeadingLevel(paragraph, fontSize);

        if (isCodeBlock)
        {
            paragraph.Margin = new Thickness(0, 8, 0, 12);
            paragraph.Padding = new Thickness(10, 8, 10, 8);
            paragraph.BorderBrush = palette.Line;
            paragraph.BorderThickness = new Thickness(1);
            paragraph.Background = palette.CodeBackground;
            paragraph.FontFamily = palette.MonoFont;
            paragraph.FontSize = fontSize * 0.95;
            paragraph.LineHeight = fontSize * 1.55;
            ApplyToInlines(paragraph.Inlines, palette, palette.Body, true);
            return;
        }

        if (headingLevel > 0)
        {
            paragraph.Margin = headingLevel == 1
                ? new Thickness(0, 12, 0, 10)
                : new Thickness(0, 14, 0, 8);
            paragraph.FontWeight = FontWeights.SemiBold;
            paragraph.FontSize = headingLevel switch
            {
                1 => fontSize + 5,
                2 => fontSize + 3,
                _ => fontSize + 1.5
            };
            paragraph.LineHeight = paragraph.FontSize * 1.35;
            paragraph.Foreground = headingLevel == 1 ? palette.Accent : palette.Heading;
            ApplyToInlines(paragraph.Inlines, palette, paragraph.Foreground, false);
            return;
        }

        paragraph.Margin = new Thickness(0, 0, 0, 10);
        paragraph.FontSize = fontSize;
        ApplyToInlines(paragraph.Inlines, palette, palette.Body, false);
    }

    private static void ApplyToSection(Section section, MarkdownPalette palette, double fontSize)
    {
        if (HasVisibleBorder(section.BorderThickness))
        {
            section.Margin = new Thickness(0, 8, 0, 12);
            section.Padding = new Thickness(12, 4, 0, 4);
            section.BorderBrush = palette.Accent;
            section.BorderThickness = new Thickness(2, 0, 0, 0);
            section.Background = palette.AccentSoft;
        }

        ApplyToBlocks(section.Blocks, palette, fontSize);
    }

    private static void ApplyToInlines(InlineCollection inlines, MarkdownPalette palette, Brush foreground, bool forceCode)
    {
        foreach (var inline in inlines)
        {
            var isInlineCode = forceCode || IsCodeLike(inline.FontFamily) || HasVisibleBackground(inline.Background);

            inline.Foreground = isInlineCode ? palette.Accent : foreground;
            inline.FontFamily = isInlineCode ? palette.MonoFont : palette.BodyFont;

            if (isInlineCode)
                inline.Background = palette.AccentSoft;

            if (inline is Hyperlink hyperlink)
            {
                inline.Foreground = palette.Accent;
                inline.TextDecorations = null;
                hyperlink.Cursor = Cursors.Hand;
                hyperlink.Click -= OnHyperlinkClick;
                hyperlink.Click += OnHyperlinkClick;
            }

            if (inline is Span span)
                ApplyToInlines(span.Inlines, palette, inline.Foreground, isInlineCode);
        }
    }

    private static void ApplyToList(System.Windows.Documents.List list, MarkdownPalette palette, double fontSize)
    {
        list.Foreground = palette.Body;
        list.Margin = new Thickness(18, 2, 0, 12);
        list.Padding = new Thickness(0);
        list.MarkerOffset = 12;

        foreach (ListItem item in list.ListItems)
        {
            item.Margin = new Thickness(0, 1, 0, 2);
            ApplyToBlocks(item.Blocks, palette, fontSize);
        }
    }

    private static void ApplyToTable(Table table, MarkdownPalette palette, double fontSize)
    {
        table.CellSpacing = 0;
        table.Margin = new Thickness(0, 8, 0, 14);

        foreach (var rowGroup in table.RowGroups)
        {
            foreach (var row in rowGroup.Rows)
            {
                foreach (var cell in row.Cells)
                {
                    cell.BorderBrush = palette.Line;
                    cell.BorderThickness = new Thickness(0, 0, 0, 1);
                    cell.Padding = new Thickness(8, 6, 8, 6);
                    ApplyToBlocks(cell.Blocks, palette, fontSize);
                }
            }
        }
    }

    private static int HeadingLevel(Paragraph paragraph, double fontSize)
    {
        var tag = paragraph.Tag?.ToString();
        if (!string.IsNullOrWhiteSpace(tag) &&
            tag.Length == 2 &&
            char.ToLowerInvariant(tag[0]) == 'h' &&
            char.IsDigit(tag[1]))
        {
            return Math.Clamp(tag[1] - '0', 1, 6);
        }

        if (paragraph.FontWeight.ToOpenTypeWeight() < FontWeights.SemiBold.ToOpenTypeWeight())
            return 0;

        if (paragraph.FontSize >= fontSize + 6)
            return 1;
        if (paragraph.FontSize >= fontSize + 3)
            return 2;
        if (paragraph.FontSize > fontSize + 0.5)
            return 3;

        return 0;
    }

    private static bool IsCodeLike(FontFamily? fontFamily)
    {
        var source = fontFamily?.Source;
        return !string.IsNullOrWhiteSpace(source) &&
               (source.Contains("Consolas", StringComparison.OrdinalIgnoreCase) ||
                source.Contains("Cascadia", StringComparison.OrdinalIgnoreCase) ||
                source.Contains("Courier", StringComparison.OrdinalIgnoreCase) ||
                source.Contains("Mono", StringComparison.OrdinalIgnoreCase));
    }

    private static bool HasVisibleBackground(Brush? brush) =>
        brush is SolidColorBrush { Color.A: > 0 } solid && solid.Color != Colors.Transparent;

    private static bool HasVisibleBorder(Thickness thickness) =>
        thickness.Left > 0 || thickness.Top > 0 || thickness.Right > 0 || thickness.Bottom > 0;

    private static Brush Brush(FrameworkElement scope, string key, Color fallback) =>
        scope.TryFindResource(key) as Brush ?? new SolidColorBrush(fallback);

    private static void OnHyperlinkClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Hyperlink { NavigateUri: { } uri })
            return;

        try
        {
            Process.Start(new ProcessStartInfo(uri.AbsoluteUri)
            {
                UseShellExecute = true
            });
            e.Handled = true;
        }
        catch
        {
            // Ignore shell failures; the markdown text remains selectable/readable.
        }
    }

    private sealed record MarkdownPalette(
        Brush Body,
        Brush Heading,
        Brush Accent,
        Brush AccentSoft,
        Brush CodeBackground,
        Brush Line,
        FontFamily BodyFont,
        FontFamily MonoFont)
    {
        public static MarkdownPalette From(FrameworkElement scope)
        {
            var dark = ThemeManager.Instance.Theme == AppTheme.Dark;

            return new MarkdownPalette(
                Brush(scope, "DsFgBrush", dark ? Color.FromRgb(0xF1, 0xEB, 0xE0) : Color.FromRgb(0x2C, 0x26, 0x20)),
                Brush(scope, "DsFgBrush", dark ? Color.FromRgb(0xF1, 0xEB, 0xE0) : Color.FromRgb(0x2C, 0x26, 0x20)),
                Brush(scope, "DsAccentBrush", dark ? Color.FromRgb(0xD4, 0xBA, 0x94) : Color.FromRgb(0x9C, 0x7D, 0x5B)),
                Brush(scope, "DsAccentSoftBrush", dark ? Color.FromArgb(0x1F, 0xD4, 0xBA, 0x94) : Color.FromArgb(0x1A, 0x9C, 0x7D, 0x5B)),
                Brush(scope, "DsBgSunkenBrush", dark ? Color.FromRgb(0x10, 0x0D, 0x0A) : Color.FromRgb(0xEC, 0xE5, 0xD8)),
                Brush(scope, "DsLineBrush", dark ? Color.FromArgb(0x29, 0xD4, 0xBA, 0x94) : Color.FromArgb(0x1A, 0x5C, 0x44, 0x28)),
                scope.TryFindResource("AppFont") as FontFamily ?? new FontFamily("Segoe UI, Microsoft YaHei UI"),
                scope.TryFindResource("MonoFont") as FontFamily ?? new FontFamily("Cascadia Code, Consolas"));
        }
    }
}
