using System.Globalization;
using System.Windows.Data;

namespace LobsterInput.Converters;

public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        return value is not bool boolValue || !boolValue;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        return value is not bool boolValue || !boolValue;
    }
}
