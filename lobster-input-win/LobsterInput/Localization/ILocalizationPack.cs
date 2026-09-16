using System.Collections.Generic;
using LobsterInput.Helpers;

namespace LobsterInput.Localization;

public interface ILocalizationPack
{
    AppLanguage Language { get; }

    IReadOnlyDictionary<string, string> Strings { get; }
}
