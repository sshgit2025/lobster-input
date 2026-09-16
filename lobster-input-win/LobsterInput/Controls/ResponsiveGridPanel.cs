using System.Windows;
using System.Windows.Controls;

namespace LobsterInput.Controls;

public sealed class ResponsiveGridPanel : Panel
{
    public static readonly DependencyProperty MinItemWidthProperty =
        DependencyProperty.Register(
            nameof(MinItemWidth),
            typeof(double),
            typeof(ResponsiveGridPanel),
            new FrameworkPropertyMetadata(240d, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty MaxColumnsProperty =
        DependencyProperty.Register(
            nameof(MaxColumns),
            typeof(int),
            typeof(ResponsiveGridPanel),
            new FrameworkPropertyMetadata(3, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty ColumnGapProperty =
        DependencyProperty.Register(
            nameof(ColumnGap),
            typeof(double),
            typeof(ResponsiveGridPanel),
            new FrameworkPropertyMetadata(12d, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty RowGapProperty =
        DependencyProperty.Register(
            nameof(RowGap),
            typeof(double),
            typeof(ResponsiveGridPanel),
            new FrameworkPropertyMetadata(12d, FrameworkPropertyMetadataOptions.AffectsMeasure));

    private double[] _rowHeights = [];
    private int _columns = 1;
    private double _itemWidth;

    public double MinItemWidth
    {
        get => (double)GetValue(MinItemWidthProperty);
        set => SetValue(MinItemWidthProperty, value);
    }

    public int MaxColumns
    {
        get => (int)GetValue(MaxColumnsProperty);
        set => SetValue(MaxColumnsProperty, value);
    }

    public double ColumnGap
    {
        get => (double)GetValue(ColumnGapProperty);
        set => SetValue(ColumnGapProperty, value);
    }

    public double RowGap
    {
        get => (double)GetValue(RowGapProperty);
        set => SetValue(RowGapProperty, value);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (InternalChildren.Count == 0)
            return new Size(0, 0);

        var width = double.IsInfinity(availableSize.Width)
            ? MaxColumns * MinItemWidth + Math.Max(0, MaxColumns - 1) * ColumnGap
            : Math.Max(0, availableSize.Width);

        _columns = ResolveColumns(width);
        _itemWidth = ResolveItemWidth(width, _columns);

        var rowCount = (int)Math.Ceiling(InternalChildren.Count / (double)_columns);
        _rowHeights = new double[rowCount];

        for (var i = 0; i < InternalChildren.Count; i++)
        {
            var child = InternalChildren[i];
            child.Measure(new Size(_itemWidth, double.PositiveInfinity));
            var row = i / _columns;
            _rowHeights[row] = Math.Max(_rowHeights[row], child.DesiredSize.Height);
        }

        var height = _rowHeights.Sum() + Math.Max(0, rowCount - 1) * RowGap;
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        if (InternalChildren.Count == 0)
            return finalSize;

        _columns = ResolveColumns(finalSize.Width);
        _itemWidth = ResolveItemWidth(finalSize.Width, _columns);

        if (_rowHeights.Length == 0)
            _rowHeights = new double[(int)Math.Ceiling(InternalChildren.Count / (double)_columns)];

        var y = 0d;
        for (var i = 0; i < InternalChildren.Count; i++)
        {
            var row = i / _columns;
            var column = i % _columns;

            if (column == 0 && row > 0)
                y += _rowHeights[row - 1] + RowGap;

            var x = column * (_itemWidth + ColumnGap);
            var rowHeight = row < _rowHeights.Length ? _rowHeights[row] : InternalChildren[i].DesiredSize.Height;
            InternalChildren[i].Arrange(new Rect(x, y, _itemWidth, rowHeight));
        }

        return finalSize;
    }

    private int ResolveColumns(double width)
    {
        var maxColumns = Math.Max(1, MaxColumns);
        var minItemWidth = Math.Max(1, MinItemWidth);
        var columnGap = Math.Max(0, ColumnGap);
        var columns = (int)Math.Floor((Math.Max(0, width) + columnGap) / (minItemWidth + columnGap));
        return Math.Clamp(columns, 1, maxColumns);
    }

    private double ResolveItemWidth(double width, int columns)
    {
        var totalGap = Math.Max(0, columns - 1) * Math.Max(0, ColumnGap);
        return Math.Max(1, (Math.Max(0, width) - totalGap) / Math.Max(1, columns));
    }
}
