using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Models;
using LobsterInput.Services;

namespace LobsterInput.Stores;

public sealed partial class DictionaryStore : ObservableObject
{
    public static DictionaryStore Instance { get; } = new();

    public const int PageSize = 50;
    public const int MaxWordLength = 20;

    [ObservableProperty]
    private List<HotWordItem> _hotWords = new();

    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private string? _errorMessage;

    [ObservableProperty]
    private int _currentPage = 1;

    [ObservableProperty]
    private int _total;

    [ObservableProperty]
    private string _searchText = "";

    private string _loadedSearchText = "";

    public int TotalPages => Math.Max(1, (int)Math.Ceiling((double)Total / PageSize));
    public bool HasPrev => CurrentPage > 1;
    public bool HasNext => CurrentPage < TotalPages;

    private readonly ApiClient _api = ApiClient.Instance;

    private DictionaryStore() { }

    public async Task LoadAsync()
    {
        CurrentPage = 1;
        _loadedSearchText = SearchText;
        await FetchPageAsync(1, SearchText);
    }

    public Task GoToPageAsync(int page)
    {
        if (page < 1 || page > TotalPages) return Task.CompletedTask;
        return FetchPageAsync(page, _loadedSearchText);
    }

    public Task PrevPageAsync() => GoToPageAsync(CurrentPage - 1);

    public Task NextPageAsync() => GoToPageAsync(CurrentPage + 1);

    public async Task SearchAsync()
    {
        CurrentPage = 1;
        _loadedSearchText = SearchText;
        await FetchPageAsync(1, SearchText);
    }

    private async Task FetchPageAsync(int page, string search)
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var resp = await _api.ListHotWordsAsync(page, PageSize, search);
            HotWords = resp.Hotwords;
            Total = ResolveTotal(resp, page);
            CurrentPage = resp.Page > 0 ? resp.Page : page;
            NotifyPagingChanged();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
        }

        IsLoading = false;
    }

    public async Task<bool> AddAsync(string word)
    {
        try
        {
            var item = await _api.CreateHotWordAsync(word);
            if (MatchesLoadedSearch(item.Word))
                HotWords.Insert(0, item);
            Total++;
            OnPropertyChanged(nameof(HotWords));
            NotifyPagingChanged();
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
            return false;
        }
    }

    public async Task<bool> UpdateAsync(string id, string word)
    {
        try
        {
            var updated = await _api.UpdateHotWordAsync(id, word);
            var idx = HotWords.FindIndex(h => h.Id == id);
            if (idx >= 0)
            {
                HotWords[idx] = updated;
                OnPropertyChanged(nameof(HotWords));
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
            await _api.DeleteHotWordAsync(id);
            HotWords.RemoveAll(h => h.Id == id);
            Total = Math.Max(0, Total - 1);
            if (HotWords.Count == 0 && CurrentPage > 1)
                await GoToPageAsync(CurrentPage - 1);
            else
                OnPropertyChanged(nameof(HotWords));
            NotifyPagingChanged();
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToDisplayMessage();
            return false;
        }
    }

    private bool MatchesLoadedSearch(string word)
    {
        return string.IsNullOrWhiteSpace(_loadedSearchText)
               || word.Contains(_loadedSearchText, StringComparison.OrdinalIgnoreCase);
    }

    private static int ResolveTotal(HotWordListResponse resp, int page)
    {
        if (resp.Total > 0) return resp.Total;
        var seen = (page - 1) * PageSize + resp.Hotwords.Count;
        return resp.HasMore ? seen + 1 : seen;
    }

    private void NotifyPagingChanged()
    {
        OnPropertyChanged(nameof(TotalPages));
        OnPropertyChanged(nameof(HasPrev));
        OnPropertyChanged(nameof(HasNext));
    }
}
