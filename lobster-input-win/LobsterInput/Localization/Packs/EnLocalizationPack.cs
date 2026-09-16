using System.Collections.Generic;
using LobsterInput.Helpers;

namespace LobsterInput.Localization.Packs;

public sealed partial class EnLocalizationPack : LocalizationPack
{
    public EnLocalizationPack()
        : base(AppLanguage.En)
    {
    }

    protected override void AddStrings(IDictionary<string, string> strings)
    {
        AddCoreStrings(strings);
    }

    static partial void AddCoreStrings(IDictionary<string, string> strings);
}
