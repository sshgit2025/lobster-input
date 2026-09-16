using System;
using System.Collections.Generic;
using LobsterInput.Helpers;

namespace LobsterInput.Localization;

public abstract class LocalizationPack : ILocalizationPack
{
    private readonly Lazy<IReadOnlyDictionary<string, string>> _strings;

    protected LocalizationPack(AppLanguage language)
    {
        Language = language;
        _strings = new Lazy<IReadOnlyDictionary<string, string>>(BuildStrings, isThreadSafe: true);
    }

    public AppLanguage Language { get; }

    public IReadOnlyDictionary<string, string> Strings => _strings.Value;

    protected abstract void AddStrings(IDictionary<string, string> strings);

    protected static void AddRange(
        IDictionary<string, string> target,
        IReadOnlyDictionary<string, string> source)
    {
        foreach (var item in source)
        {
            target[item.Key] = item.Value;
        }
    }

    private IReadOnlyDictionary<string, string> BuildStrings()
    {
        var strings = new Dictionary<string, string>(StringComparer.Ordinal);
        AddStrings(strings);
        return strings;
    }
}
