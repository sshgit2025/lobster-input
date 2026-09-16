using System.Collections.Generic;
using LobsterInput.Helpers;

namespace LobsterInput.Localization.Packs;

public sealed partial class RuLocalizationPack : LocalizationPack
{
    public RuLocalizationPack()
        : base(AppLanguage.Ru)
    {
    }

    protected override void AddStrings(IDictionary<string, string> strings)
    {
        AddCoreStrings(strings);
    }

    static partial void AddCoreStrings(IDictionary<string, string> strings);
}
