using System;
using System.Collections.Generic;
using System.Linq;
using LobsterInput.Helpers;
using LobsterInput.Localization.Packs;

namespace LobsterInput.Localization;

public sealed class LocalizationRegistry
{
    private static readonly Lazy<LocalizationRegistry> DefaultRegistry = new(
        CreateDefault,
        isThreadSafe: true);

    private readonly IReadOnlyDictionary<AppLanguage, ILocalizationPack> _packs;

    public LocalizationRegistry(IEnumerable<ILocalizationPack> packs)
    {
        _packs = packs.ToDictionary(pack => pack.Language);
    }

    public static LocalizationRegistry Default => DefaultRegistry.Value;

    public string Get(AppLanguage language, string key)
    {
        foreach (var candidate in GetFallbackChain(language))
        {
            if (_packs.TryGetValue(candidate, out var pack) &&
                pack.Strings.TryGetValue(key, out var value))
            {
                return value;
            }
        }

        return key;
    }

    public IReadOnlyCollection<AppLanguage> AvailableLanguages => _packs.Keys.ToArray();

    private static LocalizationRegistry CreateDefault()
    {
        return new LocalizationRegistry(new ILocalizationPack[]
        {
            new ZhLocalizationPack(),
            new ZhHantLocalizationPack(),
            new YueLocalizationPack(),
            new RuLocalizationPack(),
            new KoLocalizationPack(),
            new EnLocalizationPack(),
        });
    }

    private static IEnumerable<AppLanguage> GetFallbackChain(AppLanguage language)
    {
        yield return language;

        if (language is AppLanguage.ZhHant or AppLanguage.Yue)
        {
            yield return AppLanguage.Zh;
        }

        if (language != AppLanguage.En)
        {
            yield return AppLanguage.En;
        }

        if (language != AppLanguage.Zh &&
            language is not AppLanguage.ZhHant and not AppLanguage.Yue)
        {
            yield return AppLanguage.Zh;
        }
    }
}
