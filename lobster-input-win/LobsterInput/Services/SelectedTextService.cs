using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using LobsterInput.Helpers;
using LobsterInput.Services.TextTargets;

namespace LobsterInput.Services;

public class SelectionSnapshot
{
    public string Text { get; set; } = "";
    public bool? IsEditable { get; set; }
    public IntPtr TargetWindow { get; set; }
    public AutomationElement? FocusedElement { get; set; }
    public IntPtr FocusedElementNativeHandle { get; set; }
    public string Source { get; set; } = "";
}

public static class SelectedTextService
{
    private readonly record struct KeyboardCommitProbe(
        bool CanAttempt,
        bool CanAssumeCommitted,
        string Reason);

    public static IntPtr GetFocusedWindow() => TextTargetWin32.FocusedWindow;

    public static SelectionSnapshot? TakeSnapshot(
        IntPtr? targetWindow = null,
        bool includeCommandCopyProbe = true)
    {
        try
        {
            var hwnd = targetWindow.GetValueOrDefault();
            if (hwnd == IntPtr.Zero)
                hwnd = TextTargetWin32.FocusedWindow;
            if (hwnd == IntPtr.Zero) return null;

            var snapshot = new SelectionSnapshot { TargetWindow = hwnd };

            var currentProcessSnapshot = TryReadCurrentProcessSelection(hwnd);
            if (currentProcessSnapshot != null)
                return currentProcessSnapshot;

            var win32Snapshot = TryReadWin32Selection(hwnd);
            if (win32Snapshot != null)
                return win32Snapshot;

            var commandCopyAttempted = false;
            if (includeCommandCopyProbe)
            {
                commandCopyAttempted = true;
                var copiedSelection = TryReadSelectionByCommandCopy(hwnd, null);
                if (copiedSelection != null)
                    return copiedSelection;
            }

            var uiaResult = TryReadViaUiAutomation(hwnd);
            SelectionSnapshot? editableCandidate = null;
            SelectionSnapshot? focusedTextCandidate = null;
            if (uiaResult != null)
            {
                snapshot.Text = uiaResult.Value.text;
                snapshot.IsEditable = uiaResult.Value.editable;
                snapshot.FocusedElement = uiaResult.Value.focusedElement;
                snapshot.FocusedElementNativeHandle = uiaResult.Value.nativeHandle;
                snapshot.Source = "UIAutomation";
                DebugTrace.Log(
                    "SelectedText",
                    $"snapshot source={snapshot.Source}, editable={snapshot.IsEditable?.ToString() ?? "unknown"}, text={snapshot.Text.Length}, target=0x{snapshot.TargetWindow.ToInt64():X}");

                if (!string.IsNullOrEmpty(snapshot.Text))
                    return snapshot;

                if (snapshot.IsEditable == true)
                    editableCandidate = snapshot;
                else if (IsKeyboardFocusedTextElement(snapshot.FocusedElement))
                {
                    snapshot.IsEditable = null;
                    snapshot.Source = "UIAutomationFocus";
                    focusedTextCandidate = snapshot;
                }
                else if (snapshot.IsEditable == false)
                {
                    return snapshot;
                }
            }

            if (includeCommandCopyProbe && !commandCopyAttempted)
            {
                var copiedSelection = TryReadSelectionByCommandCopy(hwnd, editableCandidate);
                if (copiedSelection != null)
                    return copiedSelection;
            }

            if (editableCandidate != null)
                return editableCandidate;

            if (focusedTextCandidate != null)
            {
                DebugTrace.Log("SelectedText", $"snapshot source={focusedTextCandidate.Source}, editable=unknown, text=0, target=0x{focusedTextCandidate.TargetWindow.ToInt64():X}");
                return focusedTextCandidate;
            }

            var terminalCandidate = TryCreateEmbeddedTerminalSnapshot(hwnd);
            if (terminalCandidate != null)
                return terminalCandidate;

            DebugTrace.Log("SelectedText", $"snapshot none target=0x{hwnd.ToInt64():X}");
            return null;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SelectedText] TakeSnapshot error: {ex.Message}");
            DebugTrace.LogError("SelectedText.TakeSnapshot", ex);
            return null;
        }
    }

    public static string? ReadSelectedText()
    {
        var snapshot = TakeSnapshot();
        return snapshot?.Text;
    }

    public static bool PasteText(
        string text,
        IntPtr? targetWindow = null,
        SelectionSnapshot? snapshot = null,
        SelectionSnapshot? contextSnapshot = null)
    {
        if (string.IsNullOrEmpty(text)) return false;

        try
        {
            var hwnd = targetWindow ?? TextTargetWin32.FocusedWindow;
            if (hwnd == IntPtr.Zero) return false;
            if (!TextTargetWin32.IsKnownWindow(hwnd)) return false;

            if (IsCurrentProcessWindow(hwnd) && TryPasteIntoCurrentWpfFocus(text))
                return true;

            if (snapshot != null)
                TryFocusSnapshotElement(snapshot);

            if (targetWindow.HasValue && !TextTargetWin32.IsForegroundWindow(hwnd) && !FocusWindowForInput(hwnd, snapshot))
                return false;

            snapshot ??= TakeSnapshot(hwnd, includeCommandCopyProbe: false);
            if (IsKnownReadOnlySnapshot(snapshot))
                return false;

            if (IsTerminalPasteTarget(hwnd, snapshot, contextSnapshot))
                return TryCommitViaTerminalInput(text, hwnd, snapshot, contextSnapshot);

            EnsureFillVerifierAttached(hwnd, contextSnapshot ?? snapshot);

            if (TryReplaceNativeEditSelection(text, snapshot))
                return true;

            var keyboardCommit = ProbeKeyboardCommit(hwnd, snapshot);
            if (!keyboardCommit.CanAttempt)
            {
                DebugTrace.Log("SelectedText", $"paste skipped reason={keyboardCommit.Reason}");
                return false;
            }

            DebugTrace.Log(
                "SelectedText",
                $"keyboard commit probe reason={keyboardCommit.Reason}, assume={keyboardCommit.CanAssumeCommitted}");

            var verificationBefore = keyboardCommit.CanAssumeCommitted
                ? null
                : ReadVerificationText(snapshot);
            var backup = ClipboardService.BackupClipboard();

            if (!SetClipboardTextSafe(text))
            {
                DebugTrace.Log("SelectedText", "paste failed because clipboard text could not be prepared");
                return false;
            }
            var pasteClipboardSequence = ClipboardService.GetSequenceNumber();

            Thread.Sleep(50);

            if (TextTargetWin32.IsTerminalInputWindow(hwnd))
                Thread.Sleep(80);

            FillVerifier.Instance.Arm();

            var delivered = TextTargetWin32.SendPasteShortcut();
            var committed = false;
            var confirmation = "";
            if (delivered && keyboardCommit.CanAssumeCommitted)
            {
                // 填充前刚确认过焦点可编辑，Ctrl+V 已送达即可信（对齐 Mac editable 快路径）。
                committed = true;
                confirmation = "editable-delivery";
            }
            else if (delivered)
            {
                if (FillVerifier.Instance.WaitForChange(TimeSpan.FromMilliseconds(600)))
                {
                    committed = true;
                    confirmation = $"event:{FillVerifier.Instance.LastChangeSource}";
                }
                else if (VerifyInsertedText(text, snapshot, verificationBefore))
                {
                    committed = true;
                    confirmation = "text-readback";
                }
                else if (IsFocusedTargetEditableNow(hwnd))
                {
                    // 冷 Chromium 树粘贴成功也可能发不出任何事件（Mac f646837 同款双重输出坑）：
                    // 事后焦点若已可编辑，说明刚送达的 Ctrl+V 必然已被该输入框消费。
                    committed = true;
                    confirmation = "post-paste-probe";
                }
            }

            var restoreDelay = committed
                ? Math.Clamp(900 + (text.Length / 4), 1200, 6000)
                : Math.Clamp(450 + (text.Length / 8), 700, 2500);
            ClipboardService.RestoreClipboardEventually(
                backup,
                restoreDelay,
                expectedText: text,
                expectedSequenceNumber: pasteClipboardSequence);

            DebugTrace.Log(
                "SelectedText",
                committed
                    ? $"paste committed confirmation={confirmation}, probe={keyboardCommit.Reason}, text={text.Length}"
                    : $"paste not confirmed; falling back to result overlay delivered={delivered}, probe={keyboardCommit.Reason}");
            return committed;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SelectedText] Paste error: {ex.Message}");
            DebugTrace.LogError("SelectedText.Paste", ex);
            return false;
        }
    }

    public static bool IsCurrentProcessWindow(IntPtr hwnd)
    {
        try
        {
            TextTargetWin32.TryGetWindowProcessId(hwnd, out var processId);
            return processId == Environment.ProcessId;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryPasteIntoCurrentWpfFocus(string text)
    {
        try
        {
            if (Application.Current?.Dispatcher.CheckAccess() != true)
                return false;

            if (Keyboard.FocusedElement is TextBox textBox)
            {
                if (textBox.IsReadOnly)
                    return false;

                var caret = textBox.SelectionStart;
                textBox.SelectedText = text;
                textBox.CaretIndex = caret + text.Length;
                DebugTrace.Log("SelectedText", "paste committed via current WPF TextBox");
                return true;
            }

            if (Keyboard.FocusedElement is RichTextBox richTextBox)
            {
                if (richTextBox.IsReadOnly)
                    return false;

                richTextBox.Selection.Text = text;
                richTextBox.CaretPosition = richTextBox.Selection.End;
                DebugTrace.Log("SelectedText", "paste committed via current WPF RichTextBox");
                return true;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.WpfPaste", ex);
        }

        return false;
    }

    private static SelectionSnapshot? TryReadCurrentProcessSelection(IntPtr hwnd)
    {
        if (!IsCurrentProcessWindow(hwnd))
            return null;

        try
        {
            return Application.Current?.Dispatcher.Invoke(() =>
            {
                if (Keyboard.FocusedElement is TextBox textBox)
                {
                    var selected = textBox.SelectedText ?? "";
                    var snapshot = new SelectionSnapshot
                    {
                        Text = selected,
                        IsEditable = !textBox.IsReadOnly,
                        TargetWindow = hwnd,
                        Source = "WPF"
                    };
                    DebugTrace.Log("SelectedText", $"snapshot source=WPF, editable={snapshot.IsEditable}, text={snapshot.Text.Length}, target=0x{hwnd.ToInt64():X}");
                    return snapshot;
                }

                if (Keyboard.FocusedElement is RichTextBox richTextBox)
                {
                    var selected = richTextBox.Selection.Text ?? "";
                    var snapshot = new SelectionSnapshot
                    {
                        Text = selected,
                        IsEditable = !richTextBox.IsReadOnly,
                        TargetWindow = hwnd,
                        Source = "WPF"
                    };
                    DebugTrace.Log("SelectedText", $"snapshot source=WPF, editable={snapshot.IsEditable}, text={snapshot.Text.Length}, target=0x{hwnd.ToInt64():X}");
                    return snapshot;
                }

                return null;
            });
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.WpfSnapshot", ex);
            return null;
        }
    }

    private static SelectionSnapshot? TryReadWin32Selection(IntPtr hwnd)
    {
        try
        {
            if (!TextTargetWin32.TryGetFocusedChildWindow(hwnd, out var focusHwnd))
                return null;

            if (!TextTargetWin32.IsNativeEditControl(focusHwnd))
                return null;

            if (!TextTargetWin32.TryGetEditSelection(focusHwnd, out var start, out var end))
                return null;

            if (end <= start)
            {
                var editable = !TextTargetWin32.IsNativeEditReadOnly(focusHwnd);
                DebugTrace.Log("SelectedText", $"snapshot source=Win32Edit, editable={editable}, text=0, target=0x{hwnd.ToInt64():X}, focus=0x{focusHwnd.ToInt64():X}");
                return new SelectionSnapshot
                {
                    Text = "",
                    IsEditable = editable,
                    TargetWindow = hwnd,
                    FocusedElementNativeHandle = focusHwnd,
                    Source = "Win32Edit"
                };
            }

            var fullText = TextTargetWin32.GetWindowTextSafe(focusHwnd);
            if (string.IsNullOrEmpty(fullText))
                return null;

            start = Math.Clamp(start, 0, fullText.Length);
            end = Math.Clamp(end, start, fullText.Length);
            var selected = fullText[start..end];

            var snapshot = new SelectionSnapshot
            {
                Text = selected,
                IsEditable = !TextTargetWin32.IsNativeEditReadOnly(focusHwnd),
                TargetWindow = hwnd,
                FocusedElementNativeHandle = focusHwnd,
                Source = "Win32Edit"
            };
            DebugTrace.Log("SelectedText", $"snapshot source=Win32Edit, editable={snapshot.IsEditable}, text={snapshot.Text.Length}, target=0x{hwnd.ToInt64():X}, focus=0x{focusHwnd.ToInt64():X}");
            return snapshot;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.Win32Snapshot", ex);
            return null;
        }
    }

    private static (string text, bool editable, AutomationElement focusedElement, IntPtr nativeHandle)? TryReadViaUiAutomation(IntPtr hwnd)
    {
        try
        {
            var focusedElement = GetFocusedUiElement(hwnd);
            if (focusedElement == null) return null;

            var editable = false;
            var editableKnown = false;

            var hasValuePattern = focusedElement.TryGetCurrentPattern(ValuePattern.Pattern, out var valObj);
            if (hasValuePattern)
            {
                var valPattern = (ValuePattern)valObj;
                editable = !valPattern.Current.IsReadOnly;
                editableKnown = true;
            }

            var nativeHandle = IntPtr.Zero;
            try { nativeHandle = new IntPtr(focusedElement.Current.NativeWindowHandle); } catch { }

            var hasTextPattern = focusedElement.TryGetCurrentPattern(TextPattern.Pattern, out var txtObj);
            if (hasTextPattern)
            {
                var textPattern = (TextPattern)txtObj;
                var selections = textPattern.GetSelection();
                if (selections.Length > 0)
                {
                    var selectedText = selections[0].GetText(-1);
                    return (selectedText, editable, focusedElement, nativeHandle);
                }
            }

            if (!editableKnown)
                editable = IsLikelyEditableUiAutomationElement(focusedElement, hwnd);

            if (editable)
                return ("", editable, focusedElement, nativeHandle);

            if (IsKnownNonEditableUiAutomationElement(focusedElement))
                return ("", false, focusedElement, nativeHandle);

            return null;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SelectedText] UI Automation failed: {ex.Message}");
            return null;
        }
    }

    private static SelectionSnapshot? TryReadSelectionByCommandCopy(
        IntPtr hwnd,
        SelectionSnapshot? editableCandidate)
    {
        return ClipboardService.RunExclusive(() =>
            TryReadSelectionByCommandCopyExclusive(hwnd, editableCandidate));
    }

    private static SelectionSnapshot? TryReadSelectionByCommandCopyExclusive(
        IntPtr hwnd,
        SelectionSnapshot? editableCandidate)
    {
        if (hwnd == IntPtr.Zero || !TextTargetWin32.IsKnownWindow(hwnd))
            return null;

        string? copied = null;
        var originalText = ClipboardService.GetText();
        var beforeSequence = ClipboardService.GetSequenceNumber();
        var clipboardChanged = false;

        try
        {
            if (!TextTargetWin32.IsForegroundWindow(hwnd))
                TextTargetWin32.FocusWindowForInput(hwnd, () => TryFocusSnapshotElement(editableCandidate));

            if (!TextTargetWin32.SendCopyShortcut())
            {
                DebugTrace.Log("SelectedText", "selection command-copy probe shortcut was not delivered");
                return null;
            }

            for (var i = 0; i < 14; i++)
            {
                Thread.Sleep(45);
                if (ClipboardService.GetSequenceNumber() == beforeSequence)
                    continue;

                clipboardChanged = true;
                copied = ClipboardService.GetText();
                break;
            }

            if (!clipboardChanged)
            {
                Thread.Sleep(120);
                copied = ClipboardService.GetText();
                if (!string.Equals(copied, originalText, StringComparison.Ordinal))
                    clipboardChanged = true;
                else
                    copied = null;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.CommandCopyProbe", ex);
            return null;
        }
        finally
        {
            if (clipboardChanged)
            {
                if (originalText != null)
                    _ = ClipboardService.TrySetTextSilently(originalText);
                else
                    _ = ClipboardService.TryClearSilently();
            }
        }

        if (!clipboardChanged)
        {
            DebugTrace.Log("SelectedText", $"selection command-copy probe found no clipboard change target=0x{hwnd.ToInt64():X}");
            return null;
        }

        if (string.IsNullOrWhiteSpace(copied) || ClipboardSentinel.IsInternal(copied))
        {
            DebugTrace.Log("SelectedText", $"selection command-copy probe found no selected text target=0x{hwnd.ToInt64():X}");
            return null;
        }

        var snapshot = new SelectionSnapshot
        {
            Text = copied,
            IsEditable = editableCandidate?.IsEditable,
            TargetWindow = hwnd,
            FocusedElement = editableCandidate?.FocusedElement,
            FocusedElementNativeHandle = editableCandidate?.FocusedElementNativeHandle ?? IntPtr.Zero,
            Source = "CommandCopySelection"
        };

        DebugTrace.Log("SelectedText", $"snapshot source=CommandCopySelection, editable={snapshot.IsEditable?.ToString() ?? "unknown"}, text={snapshot.Text.Length}, target=0x{hwnd.ToInt64():X}");
        return snapshot;
    }

    private static KeyboardCommitProbe ProbeKeyboardCommit(IntPtr hwnd, SelectionSnapshot? snapshot)
    {
        if (IsKnownReadOnlySnapshot(snapshot))
            return CommitProbe(false, "selected-noneditable");
        if (snapshot?.IsEditable == true)
            return CommitProbe(true, "snapshot-editable");

        try
        {
            if (TextTargetWin32.TryGetFocusedChildWindow(hwnd, out var focusedChild) &&
                TextTargetWin32.IsNativeEditControl(focusedChild))
            {
                return !TextTargetWin32.IsNativeEditReadOnly(focusedChild)
                    ? CommitProbe(true, "native-edit")
                    : CommitProbe(false, "native-edit-readonly");
            }

            if (TextTargetWin32.TryGetCaretWindow(hwnd, out _))
                return CommitProbe(true, "caret");

            var element = snapshot?.FocusedElement ?? GetFocusedUiElement(hwnd);
            if (IsLikelyEditableUiAutomationElement(element, hwnd))
                return CommitProbe(true, "uia-editable");

            if (snapshot?.IsEditable == false)
                return CommitProbe(false, "uia-noneditable");

            // 判定权反转（对齐 Mac TextFillEngine）：探不出可靠结论时不再拒绝，
            // 而是盲填后靠被动事件确认 + 事后复查决定填充还是浮窗。
            return BlindPasteProbe("undetermined-surface");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EditableProbe", ex);
            return BlindPasteProbe("probe-error");
        }
    }

    private static KeyboardCommitProbe CommitProbe(
        bool confirmed,
        string reason) =>
        new(
            confirmed,
            confirmed,
            reason);

    private static KeyboardCommitProbe BlindPasteProbe(string reason) =>
        new(
            true,
            false,
            reason);

    private static bool IsKeyboardFocusedTextElement(AutomationElement? element)
    {
        if (element == null)
            return false;

        try
        {
            if (!element.Current.HasKeyboardFocus)
                return false;

            return element.TryGetCurrentPattern(TextPattern.Pattern, out _) ||
                element.TryGetCurrentPattern(ValuePattern.Pattern, out _);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.UiFocusedTextProbe", ex);
            return false;
        }
    }

    private static bool IsKnownReadOnlySnapshot(SelectionSnapshot? snapshot)
    {
        if (snapshot?.IsEditable != false || string.IsNullOrEmpty(snapshot.Text))
            return false;

        if (snapshot.Source == "UIAutomation" &&
            IsKeyboardFocusedTextElement(snapshot.FocusedElement))
        {
            return false;
        }

        return true;
    }

    private static bool IsLikelyEditableUiAutomationElement(AutomationElement? element, IntPtr hwnd)
    {
        if (element == null)
            return false;

        try
        {
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valObj))
                return !((ValuePattern)valObj).Current.IsReadOnly;

            var nativeHandle = IntPtr.Zero;
            try { nativeHandle = new IntPtr(element.Current.NativeWindowHandle); } catch { }
            if (nativeHandle != IntPtr.Zero &&
                TextTargetWin32.IsNativeEditControl(nativeHandle))
            {
                return !TextTargetWin32.IsNativeEditReadOnly(nativeHandle);
            }

            var controlType = element.Current.ControlType;
            if (controlType == ControlType.Edit ||
                controlType == ControlType.ComboBox)
            {
                return true;
            }

            if (controlType == ControlType.Document &&
                TextTargetWin32.TryGetCaretWindow(hwnd, out _))
            {
                return true;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.UiEditableProbe", ex);
        }

        return false;
    }

    private static bool FocusWindowForInput(IntPtr hwnd, SelectionSnapshot? snapshot = null)
    {
        if (!TextTargetWin32.IsKnownWindow(hwnd)) return false;

        var focused = TextTargetWin32.FocusWindowForInput(
            hwnd,
            () =>
            {
                TryFocusSnapshotElement(snapshot);
            });

        if (!focused)
            return false;

        Thread.Sleep(80);
        return TextTargetWin32.IsForegroundWindow(hwnd) || TryFocusSnapshotElement(snapshot);
    }

    private static bool TryFocusSnapshotElement(SelectionSnapshot? snapshot)
    {
        if (snapshot == null) return false;

        try
        {
            AutomationElement? element = snapshot.FocusedElement;

            if (element == null && snapshot.FocusedElementNativeHandle != IntPtr.Zero)
            {
                try { element = AutomationElement.FromHandle(snapshot.FocusedElementNativeHandle); }
                catch { element = null; }
            }

            if (element == null) return false;
            if (!element.Current.IsKeyboardFocusable) return false;

            element.SetFocus();
            Thread.Sleep(30);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SelectedText] Focus snapshot element failed: {ex.Message}");
            return false;
        }
    }


    private static bool IsFocusedTargetEditableNow(IntPtr hwnd)
    {
        try
        {
            if (TextTargetWin32.TryGetFocusedChildWindow(hwnd, out var focusedChild) &&
                TextTargetWin32.IsNativeEditControl(focusedChild) &&
                !TextTargetWin32.IsNativeEditReadOnly(focusedChild))
            {
                return true;
            }

            var element = GetFocusedUiElement(hwnd);
            return IsLikelyEditableUiAutomationElement(element, hwnd);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.PostPasteProbe", ex);
            return false;
        }
    }

    private static AutomationElement? GetFocusedUiElement(IntPtr hwnd)
    {
        return TextTargetWin32.AttachToWindowThread(
            hwnd,
            () => AutomationElement.FocusedElement,
            out var element)
            ? element
            : null;
    }

    private static bool VerifyInsertedText(string text, SelectionSnapshot? snapshot, string? beforeText)
    {
        var needle = BuildVerificationNeedle(text);
        if (string.IsNullOrEmpty(needle)) return false;

        var afterText = ReadVerificationText(snapshot);
        if (afterText == null)
        {
            DebugTrace.Log("SelectedText", "paste verification unavailable");
            return false;
        }

        if (!afterText.Contains(needle, StringComparison.Ordinal))
        {
            DebugTrace.Log("SelectedText", "paste not verified");
            return false;
        }

        if (beforeText == null ||
            !beforeText.Contains(needle, StringComparison.Ordinal) ||
            !string.Equals(beforeText, afterText, StringComparison.Ordinal))
        {
            DebugTrace.Log("SelectedText", "paste verified via observable text change");
            return true;
        }

        DebugTrace.Log("SelectedText", "paste verification unchanged");
        return false;
    }

    private static string? ReadVerificationText(SelectionSnapshot? snapshot)
    {
        if (snapshot == null)
            return null;

        if (snapshot.FocusedElementNativeHandle != IntPtr.Zero &&
            TextTargetWin32.IsNativeEditControl(snapshot.FocusedElementNativeHandle))
        {
            var nativeText = TextTargetWin32.GetWindowTextSafe(snapshot.FocusedElementNativeHandle);
            if (!string.IsNullOrEmpty(nativeText))
                return nativeText;
        }

        if (snapshot.FocusedElement == null) return null;

        try
        {
            var element = snapshot.FocusedElement;
            var parts = new List<string>();

            if (element.TryGetCurrentPattern(TextPattern.Pattern, out var textObj))
            {
                var pattern = (TextPattern)textObj;
                var current = pattern.DocumentRange.GetText(-1) ?? "";
                if (!string.IsNullOrEmpty(current))
                    parts.Add(current);
            }

            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valueObj))
            {
                var current = ((ValuePattern)valueObj).Current.Value ?? "";
                if (!string.IsNullOrEmpty(current))
                    parts.Add(current);
            }

            if (parts.Count > 0)
                return string.Join("\n", parts);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.Verify", ex);
        }

        return null;
    }

    private static bool TryCommitViaTerminalInput(
        string text,
        IntPtr hwnd,
        SelectionSnapshot? snapshot,
        SelectionSnapshot? contextSnapshot)
    {
        var element = ResolveEmbeddedTerminalElement(hwnd, snapshot, contextSnapshot);
        if (element == null && !TextTargetWin32.IsTerminalInputWindow(hwnd))
            return false;

        var rootHwnd = TextTargetWin32.GetRootWindow(hwnd);
        if (rootHwnd == IntPtr.Zero)
            rootHwnd = hwnd;

        try
        {
            var backup = ClipboardService.BackupClipboard();
            if (!SetClipboardTextSafe(text))
            {
                DebugTrace.Log("SelectedText", "terminal paste failed preparing clipboard");
                return false;
            }

            var pasteClipboardSequence = ClipboardService.GetSequenceNumber();
            Thread.Sleep(20);

            var delivered = TryDeliverTerminalInput(
                rootHwnd,
                element,
                () => TextTargetWin32.SendPasteShortcut());
            if (!delivered)
            {
                delivered = TryDeliverTerminalInput(
                    rootHwnd,
                    element,
                    () => TextTargetWin32.SendPasteViaSendKeys());
            }

            if (!delivered)
            {
                DebugTrace.Log("SelectedText", "terminal paste shortcut was not delivered");
                return false;
            }

            ClipboardService.RestoreClipboardEventually(
                backup,
                Math.Clamp(900 + (text.Length / 4), 1200, 6000),
                expectedText: text,
                expectedSequenceNumber: pasteClipboardSequence);

            DebugTrace.Log(
                "SelectedText",
                $"terminal paste delivered and trusted class={DescribeAutomationClass(element)}");
            return true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.TerminalInput", ex);
            return false;
        }
    }

    private static bool IsKnownNonEditableUiAutomationElement(AutomationElement? element)
    {
        if (element == null)
            return false;

        try
        {
            // Pane/Window/Group 不能算可靠的"不可编辑"：Chromium/Electron 无障碍树
            // 未激活（懒构建）时焦点会落在这些容器上，此时真实焦点可能是输入框，
            // 必须交给盲填确认而不是直接浮窗。
            var controlType = element.Current.ControlType;
            return controlType == ControlType.Button ||
                controlType == ControlType.Calendar ||
                controlType == ControlType.CheckBox ||
                controlType == ControlType.DataGrid ||
                controlType == ControlType.DataItem ||
                controlType == ControlType.Header ||
                controlType == ControlType.HeaderItem ||
                controlType == ControlType.Hyperlink ||
                controlType == ControlType.Image ||
                controlType == ControlType.List ||
                controlType == ControlType.ListItem ||
                controlType == ControlType.Menu ||
                controlType == ControlType.MenuBar ||
                controlType == ControlType.MenuItem ||
                controlType == ControlType.ProgressBar ||
                controlType == ControlType.RadioButton ||
                controlType == ControlType.ScrollBar ||
                controlType == ControlType.Separator ||
                controlType == ControlType.Slider ||
                controlType == ControlType.Spinner ||
                controlType == ControlType.SplitButton ||
                controlType == ControlType.StatusBar ||
                controlType == ControlType.Tab ||
                controlType == ControlType.TabItem ||
                controlType == ControlType.Table ||
                controlType == ControlType.Text ||
                controlType == ControlType.Thumb ||
                controlType == ControlType.TitleBar ||
                controlType == ControlType.ToolBar ||
                controlType == ControlType.ToolTip ||
                controlType == ControlType.Tree ||
                controlType == ControlType.TreeItem;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.UiNonEditableProbe", ex);
            return false;
        }
    }

    private static void EnsureFillVerifierAttached(IntPtr hwnd, SelectionSnapshot? snapshot)
    {
        FillVerifier.Instance.Attach(hwnd, snapshot?.FocusedElement);
    }

    private static void EnsureFillVerifierAttached(IntPtr hwnd, AutomationElement? focusedElement)
    {
        FillVerifier.Instance.Attach(hwnd, focusedElement);
    }

    private static bool ConfirmEmbeddedTerminalInput(
        AutomationElement element,
        string text,
        string beforeValue,
        string channel)
    {
        if (FillVerifier.Instance.WaitForChange(TimeSpan.FromMilliseconds(250)))
        {
            DebugTrace.Log(
                "SelectedText",
                $"embedded terminal verified via accessibility event ({channel}) source={FillVerifier.Instance.LastChangeSource}");
            return true;
        }

        return VerifyEmbeddedTerminalInput(element, text, beforeValue, channel);
    }

    private static string ReadEmbeddedTerminalValue(AutomationElement element)
    {
        try
        {
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var patternObj))
                return ((ValuePattern)patternObj).Current.Value ?? "";
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalValueRead", ex);
        }

        return "";
    }

    private static bool VerifyEmbeddedTerminalInput(
        AutomationElement element,
        string text,
        string beforeValue,
        string channel)
    {
        var needle = BuildVerificationNeedle(text);

        for (var attempt = 0; attempt < 2; attempt++)
        {
            Thread.Sleep(attempt == 0 ? 80 : 45);
            var afterValue = ReadEmbeddedTerminalValue(element);

            if (!string.IsNullOrEmpty(needle) &&
                afterValue.Contains(needle, StringComparison.Ordinal))
            {
                DebugTrace.Log("SelectedText", $"embedded terminal verified via value ({channel})");
                return true;
            }

            if (!string.IsNullOrEmpty(beforeValue) &&
                string.IsNullOrEmpty(afterValue) &&
                !string.Equals(beforeValue, afterValue, StringComparison.Ordinal))
            {
                DebugTrace.Log("SelectedText", $"embedded terminal verified via helper consumption ({channel})");
                return true;
            }

            try
            {
                var name = element.Current.Name ?? "";
                if (!string.IsNullOrEmpty(needle) &&
                    name.Contains(needle, StringComparison.Ordinal))
                {
                    DebugTrace.Log("SelectedText", $"embedded terminal verified via accessibility name ({channel})");
                    return true;
                }
            }
            catch (Exception ex)
            {
                DebugTrace.LogError("SelectedText.EmbeddedTerminalNameRead", ex);
            }
        }

        var finalValue = ReadEmbeddedTerminalValue(element);
        DebugTrace.Log(
            "SelectedText",
            $"embedded terminal verify failed ({channel}) beforeLen={beforeValue.Length} afterLen={finalValue.Length}");
        return false;
    }

    private static bool TryDeliverTerminalInput(
        IntPtr rootHwnd,
        AutomationElement? element,
        Func<bool> sendInput)
    {
        return TextTargetWin32.TryRunAttachedInput(
            rootHwnd,
            () =>
            {
                if (element != null)
                    TryFocusEmbeddedTerminalElement(element);
            },
            sendInput,
            out var sent) && sent;
    }

    private static void TryFocusEmbeddedTerminalElement(AutomationElement element)
    {
        try
        {
            var clickTarget = ResolveEmbeddedTerminalClickTarget(element);
            TextTargetWin32.TryClickAutomationElement(clickTarget);
            element.SetFocus();
            Thread.Sleep(40);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalFocus", ex);
        }
    }

    private static AutomationElement ResolveEmbeddedTerminalClickTarget(AutomationElement element)
    {
        try
        {
            var rect = element.Current.BoundingRectangle;
            if (!rect.IsEmpty && rect.Width >= 8 && rect.Height >= 8)
                return element;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalClickTarget", ex);
        }

        try
        {
            for (var current = element; current != null; current = TreeWalker.ControlViewWalker.GetParent(current))
            {
                var className = current.Current.ClassName ?? "";
                if (!className.Contains("terminal xterm focus", StringComparison.OrdinalIgnoreCase) &&
                    !className.Contains("terminal-wrapper", StringComparison.OrdinalIgnoreCase) &&
                    !className.Contains("xterm-screen", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var rect = current.Current.BoundingRectangle;
                if (!rect.IsEmpty && rect.Width >= 32 && rect.Height >= 16)
                    return current;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalClickTargetWalk", ex);
        }

        return element;
    }

    private static AutomationElement? ResolveEmbeddedTerminalElement(
        IntPtr hwnd,
        SelectionSnapshot? snapshot,
        SelectionSnapshot? contextSnapshot)
    {
        if (IsEmbeddedTerminalElement(snapshot?.FocusedElement))
            return snapshot!.FocusedElement;

        if (contextSnapshot?.TargetWindow == hwnd &&
            IsEmbeddedTerminalElement(contextSnapshot.FocusedElement))
            return contextSnapshot.FocusedElement;

        var live = GetFocusedUiElement(hwnd);
        if (IsEmbeddedTerminalElement(live))
            return live;

        if (snapshot?.Source == "EmbeddedTerminal")
            return FindEmbeddedTerminalElement(hwnd, requireFocusOrPointer: false);

        if (contextSnapshot?.TargetWindow == hwnd &&
            contextSnapshot.Source == "EmbeddedTerminal")
        {
            return FindEmbeddedTerminalElement(hwnd, requireFocusOrPointer: false);
        }

        var activeCandidate = FindEmbeddedTerminalElement(hwnd, requireFocusOrPointer: true);
        if (activeCandidate != null)
            return activeCandidate;

        return null;
    }

    private static bool IsTerminalPasteTarget(
        IntPtr hwnd,
        SelectionSnapshot? snapshot,
        SelectionSnapshot? contextSnapshot) =>
        ResolveEmbeddedTerminalElement(hwnd, snapshot, contextSnapshot) != null ||
        TextTargetWin32.IsTerminalInputWindow(hwnd);

    private static bool IsEmbeddedTerminalElement(AutomationElement? element)
    {
        if (element == null)
            return false;

        try
        {
            var focusedClass = element.Current.ClassName ?? "";
            if (focusedClass.Contains("xterm-helper-textarea", StringComparison.OrdinalIgnoreCase))
                return true;

            for (var current = element; current != null; current = TreeWalker.ControlViewWalker.GetParent(current))
            {
                var className = current.Current.ClassName ?? "";
                if (className.Contains("xterm-helper-textarea", StringComparison.OrdinalIgnoreCase))
                    return true;

                if (className.Contains("xterm-screen", StringComparison.OrdinalIgnoreCase) ||
                    className.Contains("terminal xterm", StringComparison.OrdinalIgnoreCase) ||
                    className.Contains("terminal-wrapper", StringComparison.OrdinalIgnoreCase))
                {
                    return element.Current.ControlType == ControlType.Edit ||
                        element.TryGetCurrentPattern(ValuePattern.Pattern, out _);
                }
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalProbe", ex);
        }

        return false;
    }

    private static SelectionSnapshot? TryCreateEmbeddedTerminalSnapshot(IntPtr hwnd)
    {
        var element = FindEmbeddedTerminalElement(hwnd, requireFocusOrPointer: true);
        if (element == null)
            return null;

        var snapshot = new SelectionSnapshot
        {
            Text = "",
            IsEditable = true,
            TargetWindow = hwnd,
            FocusedElement = element,
            FocusedElementNativeHandle = SafeNativeHandle(element),
            Source = "EmbeddedTerminal"
        };

        DebugTrace.Log(
            "SelectedText",
            $"snapshot source={snapshot.Source}, editable=True, text=0, target=0x{hwnd.ToInt64():X}, class={DescribeAutomationClass(element)}");
        return snapshot;
    }

    private static AutomationElement? FindEmbeddedTerminalElement(IntPtr hwnd, bool requireFocusOrPointer)
    {
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            if (root == null)
                return null;

            AutomationElement? terminalEdit = null;
            AutomationElement? terminalScope = null;
            var descendants = root.FindAll(TreeScope.Subtree, System.Windows.Automation.Condition.TrueCondition);
            for (var i = 0; i < descendants.Count; i++)
            {
                var element = descendants[i];
                var className = SafeClassName(element);
                if (IsEmbeddedTerminalEditClass(className))
                {
                    terminalEdit = element;
                    break;
                }

                if (terminalScope == null && IsEmbeddedTerminalScopeClass(className))
                    terminalScope = element;
            }

            var candidate = terminalEdit ?? terminalScope;
            if (candidate == null)
                return null;

            if (!requireFocusOrPointer)
                return candidate;

            if (IsEmbeddedTerminalActive(candidate))
                return candidate;

            if (terminalScope != null &&
                !ReferenceEquals(candidate, terminalScope) &&
                IsEmbeddedTerminalActive(terminalScope))
            {
                return candidate;
            }

            return null;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalFind", ex);
            return null;
        }
    }

    private static bool IsEmbeddedTerminalActive(AutomationElement element)
    {
        try
        {
            if (element.Current.HasKeyboardFocus)
                return true;

            for (var current = element; current != null; current = TreeWalker.ControlViewWalker.GetParent(current))
            {
                var className = SafeClassName(current);
                if (className.Contains("terminal xterm focus", StringComparison.OrdinalIgnoreCase))
                    return true;
            }

            if (!TextTargetWin32.TryGetCursorPosition(out var cursor))
                return false;

            for (var current = element; current != null; current = TreeWalker.ControlViewWalker.GetParent(current))
            {
                var className = SafeClassName(current);
                if (!IsEmbeddedTerminalScopeClass(className) && !IsEmbeddedTerminalEditClass(className))
                    continue;

                var rect = current.Current.BoundingRectangle;
                if (!rect.IsEmpty && rect.Width >= 32 && rect.Height >= 16 && rect.Contains(cursor))
                    return true;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalActive", ex);
        }

        return false;
    }

    private static bool IsEmbeddedTerminalEditClass(string className) =>
        className.Contains("xterm-helper-textarea", StringComparison.OrdinalIgnoreCase);

    private static bool IsEmbeddedTerminalScopeClass(string className) =>
        className.Contains("xterm-screen", StringComparison.OrdinalIgnoreCase) ||
        className.Contains("terminal xterm", StringComparison.OrdinalIgnoreCase) ||
        className.Contains("terminal-wrapper", StringComparison.OrdinalIgnoreCase);

    private static string SafeClassName(AutomationElement element)
    {
        try { return element.Current.ClassName ?? ""; }
        catch { return ""; }
    }

    private static IntPtr SafeNativeHandle(AutomationElement element)
    {
        try { return new IntPtr(element.Current.NativeWindowHandle); }
        catch { return IntPtr.Zero; }
    }

    private static string DescribeAutomationClass(AutomationElement? element)
    {
        if (element == null)
            return "";

        try { return element.Current.ClassName ?? ""; }
        catch { return ""; }
    }

    private static bool TryReplaceNativeEditSelection(string text, SelectionSnapshot? snapshot)
    {
        if (snapshot?.Source != "Win32Edit" ||
            snapshot.FocusedElementNativeHandle == IntPtr.Zero)
            return false;

        var committed = TextTargetWin32.TryReplaceEditSelection(
            snapshot.FocusedElementNativeHandle,
            text,
            BuildVerificationNeedle(text));

        if (committed)
            DebugTrace.Log("SelectedText", "paste committed via Win32 EM_REPLACESEL");

        return committed;
    }

    private static string BuildVerificationNeedle(string text)
    {
        var normalized = text.Trim();
        if (normalized.Length <= 64)
            return normalized;
        return normalized[..64];
    }

    private static bool SetClipboardTextSafe(string text)
    {
        return ClipboardService.TrySetTextSilently(text);
    }

}
