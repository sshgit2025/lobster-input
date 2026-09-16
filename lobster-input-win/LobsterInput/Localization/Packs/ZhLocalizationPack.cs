using System.Collections.Generic;
using LobsterInput.Helpers;

namespace LobsterInput.Localization.Packs;

public sealed partial class ZhLocalizationPack : LocalizationPack
{
    public ZhLocalizationPack()
        : base(AppLanguage.Zh)
    {
    }

    protected override void AddStrings(IDictionary<string, string> strings)
    {
        AddCoreStrings(strings);
    }

    static partial void AddCoreStrings(IDictionary<string, string> strings);
}
