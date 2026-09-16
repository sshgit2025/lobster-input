using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;

namespace LobsterInput.Views;

public sealed class PaymentSubscriptionWindow : Window
{
    private const string CancelRenewalProgressKey = "cancel_renewal";

    private readonly StackPanel _body = new();
    private readonly TextBlock _statusText = new();
    private readonly Dictionary<string, string> _selectedBillingCycles = new();
    private PaymentCatalogResponse? _catalog;
    private UserPlanInfo? _planInfo;
    private string? _checkoutInProgress;

    public PaymentSubscriptionWindow()
    {
        Title = L10n.SubscriptionPageTitle;
        Width = 860;
        Height = 720;
        MinWidth = 720;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Icon = new BitmapImage(new Uri("pack://application:,,,/LobsterInput;component/Resources/Images/lobster.ico"));
        Background = Brush("DsBgBrush");
        Foreground = Brush("DsFgBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;

        var root = new Grid { Margin = new Thickness(30, 26, 30, 24) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new Grid { Margin = new Thickness(0, 0, 0, 18) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var titleStack = new StackPanel();
        titleStack.Children.Add(new TextBlock
        {
            Text = L10n.SubscriptionPageTitle,
            FontSize = 24,
            FontWeight = FontWeights.Bold,
            Foreground = Brush("DsFgBrush")
        });
        titleStack.Children.Add(new TextBlock
        {
            Text = L10n.SubscriptionPageSubtitle,
            FontSize = 12,
            Foreground = Brush("DsFgMutedBrush"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 8, 0, 0)
        });
        header.Children.Add(titleStack);

        var refresh = Button(L10n.BtnRefresh, "DsButtonDefaultStyle");
        refresh.Click += async (_, _) => await LoadCatalogAsync();
        Grid.SetColumn(refresh, 1);
        header.Children.Add(refresh);
        root.Children.Add(header);

        _statusText.FontSize = 12;
        _statusText.Foreground = Brush("DsAccentBrush");
        _statusText.TextWrapping = TextWrapping.Wrap;
        _statusText.Visibility = Visibility.Collapsed;
        _statusText.Margin = new Thickness(0, 0, 0, 12);
        Grid.SetRow(_statusText, 1);
        root.Children.Add(_statusText);

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = _body
        };
        Grid.SetRow(scroll, 2);
        root.Children.Add(scroll);

        Content = root;
        Loaded += async (_, _) => await LoadCatalogAsync();
    }

    private async Task LoadCatalogAsync()
    {
        _body.Children.Clear();
        ShowStatus("");
        _body.Children.Add(Caption(L10n.SubscriptionLoading));

        try
        {
            _catalog = await ApiClient.Instance.FetchPaymentCatalogAsync();
            _planInfo = await FetchPlanInfoSafeAsync();
            RenderCatalog();
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("PaymentSubscription.LoadCatalog", ex);
            _body.Children.Clear();
            _body.Children.Add(Caption(L10n.SubscriptionLoadFailed));
        }
    }

    private void RenderCatalog()
    {
        _body.Children.Clear();
        if (_catalog is null) return;

        if (!_catalog.SubscriptionModule.Enabled)
        {
            _body.Children.Add(Caption(L10n.SubscriptionLoadFailed));
            return;
        }

        _body.Children.Add(SectionLabel("\uE8D7", L10n.SubscriptionCurrentPlan));
        _body.Children.Add(CurrentPlanCard(_catalog));

        if (_catalog.CreditsTopup.Available)
            _body.Children.Add(TopupCard(_catalog));

        _body.Children.Add(SectionLabel("\uE8C7", L10n.SubscriptionAvailablePlans));
        foreach (var plan in _catalog.Subscriptions.OrderBy(p => p.Rank))
            _body.Children.Add(PlanCard(plan, _catalog));
    }

    private UIElement CurrentPlanCard(PaymentCatalogResponse catalog)
    {
        var current = catalog.CurrentPlan;
        var name = catalog.Subscriptions.FirstOrDefault(p => p.PlanCode == current.PlanCode)?.Name
                   ?? LocalizedPlanName(current.PlanCode);

        var left = new StackPanel
        {
            Children =
            {
                TitleLine("\uE8D7", name),
                Caption($"{current.PlanCreditsUsed} / {current.PlanCreditsTotal}")
            }
        };
        AppendRenewalInfo(left);

        return Card(TwoColumn(
            left,
            RightText(L10n.SubscriptionCredits(current.PlanCreditsRemaining))));
    }

    // ── 自动续费管理（三态）──
    // 1. auto_renew && renewal_cancellable：显示下次续费日期 + 「取消自动续费」按钮
    // 2. auto_renew && !renewal_cancellable：仅提示可在订阅设备的应用商店中管理
    // 3. !auto_renew：不新增 UI
    private void AppendRenewalInfo(StackPanel host)
    {
        var plan = _planInfo;
        if (plan is null || !plan.AutoRenew) return;

        if (!plan.RenewalCancellable)
        {
            host.Children.Add(Caption(L10n.SubscriptionAutoRenewManaged));
            return;
        }

        var renewalDate = FormatRenewalDate(plan.NextRenewalAt);
        var caption = Caption(renewalDate is null
            ? L10n.SubscriptionAutoRenewOnNoDate
            : L10n.SubscriptionAutoRenewOn(renewalDate));
        caption.Margin = new Thickness(0, 0, 12, 0);
        caption.VerticalAlignment = VerticalAlignment.Center;

        var isLoading = _checkoutInProgress == CancelRenewalProgressKey;
        var cancelButton = Button(
            isLoading ? L10n.Loading : L10n.SubscriptionCancelRenewal,
            "DsButtonDefaultStyle");
        cancelButton.FontSize = 12;
        cancelButton.Padding = new Thickness(10, 4, 10, 4);
        cancelButton.IsEnabled = _checkoutInProgress is null;
        cancelButton.Opacity = cancelButton.IsEnabled ? 1 : 0.45;
        cancelButton.Click += async (_, _) => await ConfirmCancelRenewalAsync(renewalDate);

        host.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 8, 0, 0),
            Children = { caption, cancelButton }
        });
    }

    private async Task ConfirmCancelRenewalAsync(string? renewalDate)
    {
        if (_checkoutInProgress is not null) return;

        var message = renewalDate is null
            ? L10n.SubscriptionCancelRenewalConfirmNoDate
            : L10n.SubscriptionCancelRenewalConfirm(renewalDate);
        var result = AppConfirmDialog.Show(
            this,
            L10n.SubscriptionCancelRenewal,
            message,
            L10n.SubscriptionCancelRenewal);
        if (result != AppConfirmDialogResult.Primary) return;

        _checkoutInProgress = CancelRenewalProgressKey;
        RenderCatalog();

        var status = "";
        var isError = false;
        try
        {
            var response = await ApiClient.Instance.CancelSubscriptionRenewalAsync();
            switch (response.Status)
            {
                case "cancelled":
                case "already_cancelled":
                    status = L10n.SubscriptionCancelRenewalSuccess;
                    break;
                case "apple_managed":
                    status = L10n.SubscriptionAutoRenewManaged;
                    break;
                default:
                    status = L10n.SubscriptionCancelRenewalFailed;
                    isError = true;
                    break;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("PaymentSubscription.CancelRenewal", ex);
            status = L10n.SubscriptionCancelRenewalFailed;
            isError = true;
        }
        finally
        {
            _checkoutInProgress = null;
        }

        await LoadCatalogAsync();
        ShowStatus(status, isError);
    }

    /// 拉取 /config/plan 套餐信息（含自动续费状态），失败不影响目录渲染；成功时同步全局 AuthStore
    private static async Task<UserPlanInfo?> FetchPlanInfoSafeAsync()
    {
        try
        {
            var info = await ApiClient.Instance.FetchUserPlanInfoAsync();
            AuthStore.Instance.UpdatePlanInfo(info);
            return info;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("PaymentSubscription.FetchPlanInfo", ex);
            return null;
        }
    }

    private static string? FormatRenewalDate(string? isoDate)
    {
        if (string.IsNullOrWhiteSpace(isoDate)) return null;
        if (!DateTime.TryParse(isoDate,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var date))
            return null;
        return date.ToLocalTime().ToString("d", CultureInfo.CurrentCulture);
    }

    private UIElement TopupCard(PaymentCatalogResponse catalog)
    {
        var topup = catalog.CreditsTopup;
        var buttonText = TopupButtonText(topup);
        var grid = TwoColumn(
            new StackPanel
            {
                Children =
                {
                    TitleLine("\uE948", L10n.SubscriptionTopupTitle),
                    Caption(L10n.SubscriptionTopupDesc)
                }
            },
            CheckoutButton(buttonText, _checkoutInProgress == "topup", _checkoutInProgress is null, async () =>
            {
                _checkoutInProgress = "topup";
                RenderCatalog();
                await CreateTopupCheckoutAsync(catalog.ActiveProvider);
            }));

        return Card(grid);
    }

    private UIElement PlanCard(PaymentSubscriptionPlan plan, PaymentCatalogResponse catalog)
    {
        var options = SortedBillingOptions(plan).ToList();
        var option = SelectedBillingOption(plan, options);
        var state = PurchaseStateFor(plan, option, catalog);
        var buttonText = state switch
        {
            PurchaseState.Current => L10n.SubscriptionCurrentPlanAction,
            PurchaseState.LowerTier => L10n.SubscriptionLowerPlanAction,
            PurchaseState.Upgrade => L10n.SubscriptionUpgradeProrated,
            _ => L10n.SubscriptionSubscribe
        };
        var loadingKey = option is null ? "" : $"{plan.PlanCode}:{option.Cycle}";
        var isPurchasableState = state is PurchaseState.Available or PurchaseState.Upgrade;
        var isEnabled = isPurchasableState && option != null && _checkoutInProgress is null;

        var right = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };
        if (option != null)
        {
            if (options.Count > 1)
                right.Children.Add(BillingCycleSelector(plan, options, option));
            right.Children.Add(new TextBlock
            {
                Text = BillingPriceText(option),
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                Foreground = isPurchasableState ? Brush("DsFgBrush") : Brush("DsFgSubtleBrush"),
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 0, 0, option.IsProratedUpgrade ? 2 : 8)
            });
            if (option.IsProratedUpgrade)
            {
                right.Children.Add(new TextBlock
                {
                    Text = L10n.SubscriptionProratedNote,
                    FontSize = 11,
                    Foreground = Brush("DsFgMutedBrush"),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Margin = new Thickness(0, 0, 0, 8)
                });
            }
        }
        right.Children.Add(CheckoutButton(buttonText, _checkoutInProgress == loadingKey, isEnabled, async () =>
        {
            if (option is null) return;
            _checkoutInProgress = loadingKey;
            RenderCatalog();
            await CreateSubscriptionCheckoutAsync(_catalog?.ActiveProvider ?? "", plan, option);
        }));

        var card = Card(TwoColumn(
            new StackPanel
            {
                Children =
                {
                    TitleLine("\uE735", plan.Name),
                    Caption(L10n.SubscriptionCredits(plan.Credits))
                }
            },
            right));
        var anyOptionPurchasable = options.Any(o => IsOptionPurchasable(plan, o, catalog));
        card.Opacity = anyOptionPurchasable ? 1 : 0.72;
        return card;
    }

    private async Task CreateSubscriptionCheckoutAsync(string provider, PaymentSubscriptionPlan plan, PaymentBillingOption option)
    {
        var status = "";
        var isError = false;
        try
        {
            var checkout = await ApiClient.Instance.CreateSubscriptionCheckoutAsync(
                provider,
                option.ProductCode ?? $"{plan.PlanCode}_{option.Cycle}",
                "",
                option.Currency ?? "",
                plan.PlanCode,
                option.Cycle);
            OpenCheckout(checkout.CheckoutUrl);
            _ = RefreshAfterCheckoutAsync();
            status = L10n.SubscriptionCheckoutOpened;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("PaymentSubscription.CreateSubscriptionCheckout", ex);
            status = L10n.SubscriptionCheckoutFailed;
            isError = true;
        }
        finally
        {
            _checkoutInProgress = null;
            RenderCatalog();
            ShowStatus(status, isError);
        }
    }

    private async Task CreateTopupCheckoutAsync(string provider)
    {
        var status = "";
        var isError = false;
        try
        {
            var checkout = await ApiClient.Instance.CreateCreditsTopupCheckoutAsync(
                provider,
                _catalog?.CreditsTopup.ProductCode ?? "credits_topup",
                "",
                _catalog?.CreditsTopup.Currency ?? "");
            OpenCheckout(checkout.CheckoutUrl);
            _ = RefreshAfterCheckoutAsync();
            status = L10n.SubscriptionCheckoutOpened;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("PaymentSubscription.CreateTopupCheckout", ex);
            status = L10n.SubscriptionCheckoutFailed;
            isError = true;
        }
        finally
        {
            _checkoutInProgress = null;
            RenderCatalog();
            ShowStatus(status, isError);
        }
    }

    private void OpenCheckout(string checkoutUrl)
    {
        if (!Uri.TryCreate(checkoutUrl, UriKind.Absolute, out _))
        {
            ShowStatus(L10n.SubscriptionCheckoutFailed, isError: true);
            return;
        }

        Process.Start(new ProcessStartInfo(checkoutUrl) { UseShellExecute = true });
    }

    private static async Task RefreshAfterCheckoutAsync()
    {
        foreach (var delay in new[] { 3, 5, 8, 13, 21, 34 })
        {
            await Task.Delay(TimeSpan.FromSeconds(delay));
            try
            {
                var info = await ApiClient.Instance.FetchUserPlanInfoAsync();
                Application.Current.Dispatcher.Invoke(() => AuthStore.Instance.UpdatePlanInfo(info));
            }
            catch (Exception ex)
            {
                DebugTrace.LogError("PaymentSubscription.RefreshAfterCheckout", ex);
            }
        }
    }

    private PurchaseState PurchaseStateFor(PaymentSubscriptionPlan plan, PaymentBillingOption? option, PaymentCatalogResponse catalog)
    {
        if (!catalog.CurrentPlan.Paid) return PurchaseState.Available;

        if (option?.Purchasable is bool purchasable)
        {
            // 服务端权威可购判定(新后端)
            if (purchasable)
            {
                return option.IsProratedUpgrade || plan.PlanCode == catalog.CurrentPlan.PlanCode
                    ? PurchaseState.Upgrade
                    : PurchaseState.Available;
            }
            return option.BlockedReason == "duplicate_purchase"
                ? PurchaseState.Current
                : PurchaseState.LowerTier;
        }

        // 旧后端兜底:套餐级逻辑
        if (plan.PlanCode == catalog.CurrentPlan.PlanCode) return PurchaseState.Current;

        var currentRank = catalog.Subscriptions.FirstOrDefault(p => p.PlanCode == catalog.CurrentPlan.PlanCode)?.Rank;
        return currentRank.HasValue && plan.Rank <= currentRank.Value
            ? PurchaseState.LowerTier
            : PurchaseState.Available;
    }

    private bool IsOptionPurchasable(PaymentSubscriptionPlan plan, PaymentBillingOption option, PaymentCatalogResponse catalog) =>
        PurchaseStateFor(plan, option, catalog) is PurchaseState.Available or PurchaseState.Upgrade;

    private static IEnumerable<PaymentBillingOption> SortedBillingOptions(PaymentSubscriptionPlan plan) =>
        plan.BillingOptions.OrderBy(option => BillingCycleRank(option.Cycle));

    private PaymentBillingOption? SelectedBillingOption(PaymentSubscriptionPlan plan, IReadOnlyCollection<PaymentBillingOption> options)
    {
        if (options.Count == 0) return null;
        if (_selectedBillingCycles.TryGetValue(plan.PlanCode, out var selectedCycle))
        {
            var selected = options.FirstOrDefault(option => option.Cycle == selectedCycle);
            if (selected != null) return selected;
        }

        var fallback = (_catalog is null ? null : options.FirstOrDefault(option => IsOptionPurchasable(plan, option, _catalog)))
                       ?? options.FirstOrDefault(option => option.Cycle == "monthly")
                       ?? options.First();
        _selectedBillingCycles[plan.PlanCode] = fallback.Cycle;
        return fallback;
    }

    private UIElement BillingCycleSelector(PaymentSubscriptionPlan plan, IEnumerable<PaymentBillingOption> options, PaymentBillingOption selected)
    {
        var selector = new ComboBox
        {
            MinWidth = 120,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 0, 8),
            IsEnabled = _checkoutInProgress is null
        };
        foreach (var option in options)
        {
            selector.Items.Add(new ComboBoxItem
            {
                Content = BillingCycleTitle(option.Cycle),
                Tag = option.Cycle
            });
        }
        selector.SelectedItem = selector.Items
            .OfType<ComboBoxItem>()
            .FirstOrDefault(item => string.Equals(item.Tag as string, selected.Cycle, StringComparison.Ordinal));
        selector.SelectionChanged += (_, _) =>
        {
            if (selector.SelectedItem is not ComboBoxItem item || item.Tag is not string cycle) return;
            _selectedBillingCycles[plan.PlanCode] = cycle;
            RenderCatalog();
        };
        return selector;
    }

    private static string BillingPriceText(PaymentBillingOption option)
    {
        var price = PriceText(option.EffectivePriceCents, option.Currency);
        return option.Cycle == "monthly"
            ? L10n.SubscriptionPriceMonthly(price)
            : $"{price} / {BillingCycleTitle(option.Cycle)}";
    }

    private static int BillingCycleRank(string? cycle) => cycle switch
    {
        "weekly" => 10,
        "monthly" => 20,
        "quarterly" => 30,
        "yearly" or "annual" => 40,
        _ => 100
    };

    private static string BillingCycleTitle(string? cycle) => cycle switch
    {
        "weekly" => L10n.PlanWeekly,
        "monthly" => L10n.PlanMonthly,
        "quarterly" => "季度",
        "yearly" or "annual" => L10n.PlanYearly,
        _ => string.IsNullOrWhiteSpace(cycle) ? "-" : cycle
    };

    private static string TopupButtonText(PaymentCreditsTopup topup)
    {
        var credits = topup.Amount.HasValue ? L10n.SubscriptionCredits(topup.Amount.Value) : L10n.SubscriptionTopupAction;
        if (!topup.PriceCents.HasValue) return credits;
        return $"{credits} - {PriceText(topup.PriceCents.Value, topup.Currency)}";
    }

    private static string PriceText(int cents, string? currency)
    {
        var code = string.IsNullOrWhiteSpace(currency) ? "USD" : currency.ToUpperInvariant();
        var symbol = code switch
        {
            "USD" => "US$",
            "CNY" => "¥",
            "EUR" => "€",
            "GBP" => "£",
            _ => $"{code} "
        };
        return $"{symbol}{(cents / 100m).ToString("0.##", CultureInfo.InvariantCulture)}";
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

    private void ShowStatus(string message, bool isError = false)
    {
        _statusText.Text = message;
        _statusText.Foreground = isError ? Brushes.OrangeRed : Brush("DsAccentBrush");
        _statusText.Visibility = string.IsNullOrWhiteSpace(message) ? Visibility.Collapsed : Visibility.Visible;
    }

    private static Grid TwoColumn(UIElement left, UIElement right)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(left);
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);
        return grid;
    }

    private static Border Card(UIElement content) =>
        new()
        {
            Style = (Style)Application.Current.FindResource("DsCardStyle"),
            Padding = new Thickness(18, 14, 18, 14),
            Margin = new Thickness(0, 0, 0, 12),
            Child = content
        };

    private static StackPanel SectionLabel(string icon, string title) =>
        new()
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 12, 0, 8),
            Children =
            {
                new TextBlock
                {
                    Text = icon,
                    FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
                    Foreground = Brush("DsFgSubtleBrush"),
                    FontSize = 13,
                    Margin = new Thickness(0, 0, 8, 0)
                },
                new TextBlock
                {
                    Text = title,
                    Foreground = Brush("DsFgMutedBrush"),
                    FontSize = 12,
                    FontWeight = FontWeights.SemiBold
                }
            }
        };

    private static StackPanel TitleLine(string icon, string title) =>
        new()
        {
            Orientation = Orientation.Horizontal,
            Children =
            {
                new TextBlock
                {
                    Text = icon,
                    FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
                    Foreground = Brush("DsFgSubtleBrush"),
                    FontSize = 13,
                    Margin = new Thickness(0, 0, 8, 0)
                },
                new TextBlock
                {
                    Text = title,
                    Foreground = Brush("DsFgBrush"),
                    FontSize = 15,
                    FontWeight = FontWeights.SemiBold
                }
            }
        };

    private static TextBlock Caption(string text) =>
        new()
        {
            Text = text,
            Foreground = Brush("DsFgMutedBrush"),
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0)
        };

    private static TextBlock RightText(string text) =>
        new()
        {
            Text = text,
            Foreground = Brush("DsFgBrush"),
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center
        };

    private static Button Button(string text, string styleKey) =>
        new()
        {
            Content = text,
            Style = (Style)Application.Current.FindResource(styleKey),
            Padding = new Thickness(14, 8, 14, 8),
            Cursor = Cursors.Hand
        };

    private static Button CheckoutButton(string text, bool isLoading, bool isEnabled, Func<Task> action)
    {
        var button = Button(isLoading ? L10n.Loading : text, isEnabled ? "DsButtonPrimaryStyle" : "DsButtonDefaultStyle");
        button.MinWidth = 92;
        button.IsEnabled = isEnabled;
        button.Opacity = isEnabled ? 1 : 0.45;
        button.Click += async (_, _) => await action();
        return button;
    }

    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);

    private enum PurchaseState
    {
        Available,
        Upgrade,
        Current,
        LowerTier
    }
}
