using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Stores;

namespace LobsterInput.Views;

public partial class PersonaView : UserControl
{
    private readonly PersonaStore _store = PersonaStore.Instance;
    private bool _personaActionInFlight;

    public PersonaView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _store.PropertyChanged += OnStoreChanged;
        LanguageManager.Instance.PropertyChanged += OnLanguageChanged;
        RefreshLabels();
        await _store.LoadAsync();
        RefreshList();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _store.PropertyChanged -= OnStoreChanged;
        LanguageManager.Instance.PropertyChanged -= OnLanguageChanged;
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            RefreshLabels();
            RefreshList();
        });
    }

    private async void OnLanguageChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(LanguageManager.Current))
            return;

        Dispatcher.Invoke(RefreshLabels);
        if (_store.Personas.Count == 0)
            await _store.LoadAsync();
    }

    private void RefreshLabels()
    {
        PersonaPageTitle.Text = L10n.PagePersona;
        PageDesc.Text = L10n.PersonaPageDesc;
        CreateBtn.Content = L10n.PersonaNewPersona;
        EmptyCreateBtn.Content = L10n.PersonaNewPersona;
        LoadingText.Text = L10n.Loading;
        NoSelectionText.Text = L10n.PersonaPageDesc;
        LimitHint.Text = L10n.PersonaLimitReached(PersonaConstants.MaxCount);
    }

    private void RefreshList()
    {
        LoadingText.Visibility = _store.IsLoading
            ? Visibility.Visible
            : Visibility.Collapsed;

        CreateBtn.Visibility = _store.CanCreate ? Visibility.Visible : Visibility.Collapsed;
        CreateBtn.IsEnabled = _store.CanCreate;
        EmptyCreateBtn.IsEnabled = _store.CanCreate;
        CountHint.Text = L10n.PersonaCountHint(
            _store.Personas.Count(p => !p.IsBuiltin), PersonaConstants.MaxCount);
        LimitHint.Visibility = _store.CanCreate ? Visibility.Collapsed : Visibility.Visible;

        var showEmpty = !_store.IsLoading && _store.Personas.Count == 0;
        EmptyPanel.Visibility = showEmpty ? Visibility.Visible : Visibility.Collapsed;
        PersonaScroll.Visibility = showEmpty || _store.IsLoading
            ? Visibility.Collapsed
            : Visibility.Visible;

        PersonaList.ItemsSource = null;
        PersonaList.ItemsSource = _store.Personas
            .Select(p => new PersonaListItem(p, !_personaActionInFlight))
            .ToList();
    }

    private void OnCreateClick(object sender, RoutedEventArgs e)
    {
        if (!_store.CanCreate) return;
        var window = new PersonaEditWindow(null) { Owner = Window.GetWindow(this) };
        window.ShowDialog();
    }

    private void OnPersonaEditClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is not FrameworkElement element || element.Tag is not PersonaItem item) return;
        if (item.IsBuiltin) return;
        var window = new PersonaEditWindow(item) { Owner = Window.GetWindow(this) };
        window.ShowDialog();
    }

    private async void OnPersonaCardClick(object sender, MouseButtonEventArgs e)
    {
        if (IsEventFromButton(e)) return;
        if (sender is not FrameworkElement element || element.Tag is not PersonaItem item) return;

        e.Handled = true;
        await ActivatePersonaAsync(item);
    }

    private async void OnPersonaCardKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Enter or Key.Space)) return;
        if (sender is not FrameworkElement element || element.Tag is not PersonaItem item) return;

        e.Handled = true;
        await ActivatePersonaAsync(item);
    }

    private async void OnPersonaActivateClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is not FrameworkElement element || element.Tag is not PersonaItem item) return;

        await ActivatePersonaAsync(item);
    }

    private async void OnPersonaDeleteClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is not FrameworkElement element || element.Tag is not PersonaItem item) return;
        if (item.IsBuiltin) return;

        var result = AppConfirmDialog.Show(
            Window.GetWindow(this),
            L10n.Delete,
            L10n.DeleteConfirm,
            L10n.Delete);
        if (result != AppConfirmDialogResult.Primary) return;

        await _store.DeleteAsync(item.Id);
    }

    private async Task ActivatePersonaAsync(PersonaItem item)
    {
        if (_personaActionInFlight) return;

        _personaActionInFlight = true;
        RefreshList();
        try
        {
            if (item.IsActive)
                await _store.DeactivateAllAsync();
            else
                await _store.ActivateAsync(item.Id);
        }
        finally
        {
            _personaActionInFlight = false;
            RefreshList();
        }
    }

    private static bool IsEventFromButton(RoutedEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject current)
            return false;

        while (current != null)
        {
            if (current is Button)
                return true;

            current = VisualTreeHelper.GetParent(current);
        }

        return false;
    }
}

internal sealed class PersonaListItem(PersonaItem item, bool canRunActivationAction)
{
    public PersonaItem Item { get; } = item;
    public string Name => Item.Name;
    public string? Description => Item.Description;
    public bool IsActive => Item.IsActive;
    public bool IsBuiltin => Item.IsBuiltin;
    public bool IsUserPersona => !Item.IsBuiltin;
    public bool CanRunActivationAction { get; } = canRunActivationAction;
    public string ActiveBadgeText => L10n.PersonaActivated;
    public string ActiveStateText => IsActive ? L10n.PersonaActivated : L10n.PersonaActivateBtn;
    public string ActivateButtonText => L10n.PersonaActivateBtn;
    public string DeactivateButtonText => L10n.PersonaDeactivateBtn;

    public bool HasTranscribePrompt => HasText(Item.Prompts.TranscribePrompt);
    public bool HasRewritePrompt => HasText(Item.Prompts.RewritePrompt);
    public bool HasIntentHint => HasText(Item.Prompts.IntentHint);
    public bool TranscribeEnabled => Item.Prompts.TranscribeEnabled && HasTranscribePrompt;
    public bool RewriteEnabled => Item.Prompts.RewriteEnabled && HasRewritePrompt;
    public bool IntentEnabled => Item.Prompts.IntentEnabled && HasIntentHint;

    public bool HasPromptSummary =>
        IsUserPersona && (HasTranscribePrompt || HasRewritePrompt || HasIntentHint);

    private static bool HasText(string? value) =>
        !string.IsNullOrWhiteSpace(value);
}
