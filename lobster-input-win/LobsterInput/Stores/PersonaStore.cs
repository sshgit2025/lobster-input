using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;

namespace LobsterInput.Stores;

public sealed partial class PersonaStore : ObservableObject
{
    public static PersonaStore Instance { get; } = new();

    [ObservableProperty]
    private List<PersonaItem> _personas = new();

    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private string? _errorMessage;

    private readonly ApiClient _api = ApiClient.Instance;

    public PersonaItem? ActivePersona =>
        Personas.FirstOrDefault(p => p.IsActive);

    public bool CanCreate =>
        Personas.Count(p => !p.IsBuiltin) < PersonaConstants.MaxCount;

    private PersonaStore()
    {
        LanguageManager.Instance.PropertyChanged += OnLanguageChanged;
    }

    public async Task LoadAsync()
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            Personas = await _api.ListPersonasAsync();
            NormalizeActivePersonas();
            OnPropertyChanged(nameof(CanCreate));
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
        }

        IsLoading = false;
    }

    public async Task<PersonaItem?> CreateAsync(
        string name, string? description, PersonaPrompts prompts)
    {
        try
        {
            var activeId = ActivePersona?.Id;
            var item = await _api.CreatePersonaAsync(name, description, prompts);
            var createActivatedItem = item.IsActive;
            item.IsActive = false;
            Personas.Add(item);
            OnPropertyChanged(nameof(Personas));
            OnPropertyChanged(nameof(CanCreate));
            OnPropertyChanged(nameof(ActivePersona));

            if (createActivatedItem)
            {
                if (!string.IsNullOrWhiteSpace(activeId))
                    await ActivateAsync(activeId);
                else
                    await DeactivateAllAsync();
            }

            return item;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
            return null;
        }
    }

    public async Task<bool> UpdateAsync(
        string id, string? name, string? description, PersonaPrompts? prompts)
    {
        try
        {
            var updated = await _api.UpdatePersonaAsync(id, name, description, prompts);
            var idx = Personas.FindIndex(p => p.Id == id);
            if (idx >= 0)
            {
                updated.IsActive = Personas[idx].IsActive;
                Personas[idx] = updated;
                NormalizeActivePersonas(updated.IsActive ? updated.Id : null);
                OnPropertyChanged(nameof(Personas));
                OnPropertyChanged(nameof(ActivePersona));
            }
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
            return false;
        }
    }

    public async Task<bool> DeleteAsync(string id)
    {
        try
        {
            await _api.DeletePersonaAsync(id);
            Personas.RemoveAll(p => p.Id == id);
            OnPropertyChanged(nameof(Personas));
            OnPropertyChanged(nameof(CanCreate));
            OnPropertyChanged(nameof(ActivePersona));
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
            return false;
        }
    }

    public async Task<bool> ActivateAsync(string id)
    {
        try
        {
            var activated = await _api.ActivatePersonaAsync(id);
            if (string.IsNullOrWhiteSpace(activated.Id))
                activated.Id = id;
            activated.IsActive = true;

            for (var i = 0; i < Personas.Count; i++)
            {
                if (Personas[i].Id == activated.Id)
                    Personas[i] = activated;
                else
                    Personas[i].IsActive = false;
            }
            OnPropertyChanged(nameof(Personas));
            OnPropertyChanged(nameof(ActivePersona));
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
            return false;
        }
    }

    public async Task<bool> DeactivateAllAsync()
    {
        try
        {
            var activeId = ActivePersona?.Id;
            await _api.DeactivateAllPersonasAsync();
            foreach (var persona in Personas)
                persona.IsActive = false;
            OnPropertyChanged(nameof(Personas));
            OnPropertyChanged(nameof(ActivePersona));
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
            return false;
        }
    }

    private void NormalizeActivePersonas(string? preferredActiveId = null)
    {
        string? keepId = null;
        if (!string.IsNullOrWhiteSpace(preferredActiveId) &&
            Personas.Any(p => p.Id == preferredActiveId && p.IsActive))
        {
            keepId = preferredActiveId;
        }
        else
        {
            keepId = Personas.FirstOrDefault(p => p.IsActive)?.Id;
        }

        if (string.IsNullOrWhiteSpace(keepId))
            return;

        foreach (var persona in Personas)
            persona.IsActive = persona.Id == keepId;
    }

    private async void OnLanguageChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(LanguageManager.Current))
            return;
        if (IsLoading || Personas.Count == 0)
            return;

        await LoadAsync();
    }
}
