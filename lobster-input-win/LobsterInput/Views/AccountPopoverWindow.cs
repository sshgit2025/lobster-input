using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Shapes;
using LobsterInput.Helpers;
using LobsterInput.Stores;

namespace LobsterInput.Views;

public sealed class AccountPopoverWindow : Window
{
    private const double PopoverWidth = 320;

    private readonly Action _onLogout;
    private readonly Action _onInviteCodes;

    public AccountPopoverWindow(Action onLogout, Action onInviteCodes)
    {
        _onLogout = onLogout;
        _onInviteCodes = onInviteCodes;
        Width = PopoverWidth;
        Height = BuildHeight();
        WindowStyle = WindowStyle.None;
        AllowsTransparency = false;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Background = Brush("DsBgElevBrush");
        Foreground = Brush("DsFgBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        Topmost = true;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        WindowInteropTools.AttachWindowFramePreferences(this);
        Deactivated += (_, _) =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (IsVisible)
                    Close();
            });
        };
        Content = BuildContent();
    }

    private double BuildHeight()
    {
        var auth = AuthStore.Instance;
        var height = 236d;
        if (auth.Tier == "trial" || auth.CreditsTotal > 0)
        {
            height += 82;
            if (auth.FormattedResetDate() is not null)
                height += 22;
        }

        if (auth.ShowInviteCodesEnabled)
            height += 40;

        return height;
    }

    private UIElement BuildContent()
    {
        var shell = new Border
        {
            Width = PopoverWidth,
            Height = Height,
            Background = Brush("DsBgElevBrush"),
            BorderBrush = Brush("DsLineStrongBrush"),
            BorderThickness = new Thickness(1),
            SnapsToDevicePixels = true
        };

        var root = new Grid { Background = Brush("DsBgElevBrush") };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var body = new StackPanel { Margin = new Thickness(18, 18, 18, 14) };

        var auth = AuthStore.Instance;
        // 优先展示后端本地化套餐名(套餐文案统一后端管理);为空回退客户端本地翻译
        var tier = string.IsNullOrEmpty(auth.PlanName) ? LocalizedPlanName(auth.Tier) : auth.PlanName;

        var header = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.Children.Add(new Border
        {
            Width = 48,
            Height = 48,
            Background = Brush("DsAccentSoftBrush"),
            BorderBrush = Brush("DsAccentRingBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.FindResource("RadiusLg"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 14, 0),
            Child = new TextBlock
            {
                Text = "\uE77B",
                FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
                FontSize = 28,
                Foreground = Brush("DsAccentBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        });
        var titleStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(titleStack, 1);
        titleStack.Children.Add(new TextBlock
        {
            Text = L10n.AccountTitle,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("DsFgBrush")
        });
        titleStack.Children.Add(new Border
        {
            Style = (Style)Application.Current.FindResource("DsBadgeAccentStyle"),
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 5, 0, 0),
            Child = new TextBlock
            {
                Text = tier,
                FontSize = 11,
                Foreground = Brush("DsAccentBrush"),
                VerticalAlignment = VerticalAlignment.Center
            }
        });
        header.Children.Add(titleStack);
        body.Children.Add(header);
        body.Children.Add(Divider(new Thickness(0, 0, 0, 14)));
        body.Children.Add(InfoRow(L10n.AccountEmail, auth.Email ?? L10n.NotLoggedIn));
        body.Children.Add(InfoRow(L10n.AccountTier, tier, new Thickness(0, 0, 0, auth.Tier == "trial" || auth.CreditsTotal > 0 ? 12 : 0)));

        if (auth.Tier == "trial" || auth.CreditsTotal > 0)
            body.Children.Add(CreditsSection(auth));

        root.Children.Add(body);

        var divider = Divider(new Thickness(0));
        Grid.SetRow(divider, 1);
        root.Children.Add(divider);

        var actions = new StackPanel
        {
            MinHeight = auth.ShowInviteCodesEnabled ? 86 : 56,
            Margin = new Thickness(12, 8, 12, 10),
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        if (auth.ShowInviteCodesEnabled)
            actions.Children.Add(ActionButton("\uE72E", L10n.MyInviteCodesBtn, _onInviteCodes));

        actions.Children.Add(ActionButton("\uE7E8", L10n.Logout, _onLogout, true));
        Grid.SetRow(actions, 2);
        root.Children.Add(actions);
        shell.Child = root;
        return shell;
    }

    private UIElement CreditsSection(AuthStore auth)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 2, 0, 0) };
        stack.Children.Add(Divider(new Thickness(0, 0, 0, 12)));
        stack.Children.Add(SplitRow(
            L10n.AccountCredits,
            $"{auth.CreditsRemaining} / {auth.CreditsTotal}",
            Brush("DsFgBrush"),
            13.5,
            new Thickness(0, 0, 0, 8)));
        stack.Children.Add(InfoRow($"{L10n.AccountCreditsUsed} {auth.CreditsUsed}", "", new Thickness(0, 0, 0, 6)));
        stack.Children.Add(CreditsProgress(auth));
        if (auth.FormattedResetDate() is { } date)
            stack.Children.Add(InfoRow(L10n.AccountCreditsReset, L10n.CreditsResetDateLabel(date), new Thickness()));
        return stack;
    }

    private UIElement CreditsProgress(AuthStore auth)
    {
        var grid = new Grid
        {
            Height = 8,
            Margin = new Thickness(0, 0, 0, 10),
            ClipToBounds = true
        };

        grid.Children.Add(new Border
        {
            Background = Brush("DsBgSunkenBrush"),
            CornerRadius = new CornerRadius(4)
        });

        var fill = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Left,
            Background = Brush("DsAccentBrush"),
            CornerRadius = new CornerRadius(4),
            RenderTransformOrigin = new Point(0, 0.5),
            RenderTransform = new ScaleTransform(auth.CreditsTotal <= 0
                ? 0
                : Math.Clamp((double)auth.CreditsRemaining / auth.CreditsTotal, 0, 1), 1)
        };
        fill.SetBinding(WidthProperty, new Binding(nameof(ActualWidth)) { Source = grid });
        grid.Children.Add(fill);
        return grid;
    }

    private UIElement InfoRow(string label, string value, Thickness? margin = null)
    {
        return SplitRow(label, value, Brush("DsFgBrush"), 13, margin ?? new Thickness(0, 0, 0, 8));
    }

    private FrameworkElement SplitRow(string label, string value, Brush valueBrush, double valueSize = 13, Thickness? margin = null)
    {
        var grid = new Grid { Margin = margin ?? new Thickness(0, 0, 0, 5) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 12,
            Foreground = Brush("DsFgMutedBrush"),
            VerticalAlignment = VerticalAlignment.Center
        });
        var valueText = new TextBlock
        {
            Text = value,
            FontSize = valueSize,
            Foreground = valueBrush,
            TextAlignment = TextAlignment.Right,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(12, 0, 0, 0)
        };
        Grid.SetColumn(valueText, 1);
        grid.Children.Add(valueText);
        return grid;
    }

    private UIElement ActionButton(string icon, string text, Action action, bool danger = false)
    {
        var button = new Button
        {
            Width = danger ? 128 : PopoverWidth - 24,
            Height = danger ? 34 : 36,
            Margin = danger ? new Thickness(0, 0, 0, 0) : new Thickness(0, 0, 0, 6),
            Padding = new Thickness(12, 0, 12, 0),
            Style = (Style)Application.Current.FindResource(danger ? "DsButtonGhostDangerStyle" : "DsButtonGhostStyle"),
            HorizontalAlignment = HorizontalAlignment.Center
        };
        button.Click += (_, _) => action();

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        row.Children.Add(new TextBlock
        {
            Text = icon,
            FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
            FontSize = 13,
            LineHeight = 16,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = danger ? Brush("DsDangerBrush") : Brush("DsFgMutedBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        });
        var label = new TextBlock
        {
            Text = text,
            FontSize = 13,
            Foreground = danger ? Brush("DsDangerBrush") : Brush("DsFgBrush"),
            LineHeight = 16,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            VerticalAlignment = VerticalAlignment.Center
        };
        row.Children.Add(label);
        button.Content = row;
        return button;
    }

    private static UIElement Divider(Thickness margin)
    {
        return new Rectangle
        {
            Height = 1,
            Fill = Brush("DsLineBrush"),
            Margin = margin
        };
    }

    private static string LocalizedPlanName(string tier) => tier switch
    {
        "trial" => L10n.PlanTrial,
        "free" => L10n.PlanFree,
        "weekly" => L10n.PlanWeekly,
        "monthly" => L10n.PlanMonthly,
        "yearly" => L10n.PlanYearly,
        "none" => L10n.TierNone,
        _ => string.IsNullOrWhiteSpace(tier) ? L10n.TierNone : tier
    };

    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);
}
