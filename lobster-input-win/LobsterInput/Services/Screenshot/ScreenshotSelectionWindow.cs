using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using LobsterInput.Helpers;
using WinForms = System.Windows.Forms;

namespace LobsterInput.Services.Screenshot;

internal sealed class ScreenshotSelectionWindow : Window
{
    private const int SWP_NOZORDER = 0x0004;
    private const int SWP_NOACTIVATE = 0x0010;
    private const int SWP_SHOWWINDOW = 0x0040;

    private BitmapSource? _snapshot;
    private readonly ScreenCaptureBounds _bounds;
    private readonly Image _image = new();
    private readonly Canvas _canvas = new();
    private readonly System.Windows.Shapes.Path _mask = new();
    private readonly Rectangle _selection = new();
    private readonly Rectangle[] _handles = new Rectangle[4];
    private readonly StackPanel _actions = new();
    private readonly StackPanel _toolbar = new();
    private readonly bool _requiresConfirmation;
    private readonly double _minSize = 18;
    // 多屏高亮：当前鼠标所在屏幕的像素区域
    private WinForms.Screen? _activeScreen;
    // MouseMove 节流：只在切换到不同屏幕时才重建遮罩
    private WinForms.Screen? _lastMouseScreen;

    private Point _start;
    private Rect _selectionRect = Rect.Empty;
    private Rect _dragStartSelection = Rect.Empty;
    private DragMode _dragMode = DragMode.None;

    // 标注工具状态
    private AnnotationTool _currentTool = AnnotationTool.None;
    private Color _penColor = Colors.Red;
    private readonly List<AnnotationData> _annotations = new();
    private AnnotationData? _currentAnnotation;
    private readonly List<UIElement> _annotationElements = new();
    private UIElement? _currentAnnotationElement;
    private Point _annotationStart;

    private enum DragMode { None, New, Move, TopLeft, TopRight, BottomLeft, BottomRight }
    private enum AnnotationTool { None, Pen, Rect, Ellipse }

    private sealed class AnnotationData
    {
        public AnnotationTool Tool { get; init; }
        public Color Color { get; init; }
        public double LineWidth { get; init; }
        public List<Point> Points { get; init; } = new();
        public Rect Bounds { get; set; }
        public UIElement? Element { get; set; }

        /// 命中检测（tolerance 为像素容差）
        public bool HitTest(Point p, double tolerance = 8)
        {
            switch (Tool)
            {
                case AnnotationTool.Pen:
                    for (var i = 1; i < Points.Count; i++)
                    {
                        if (DistanceToSegment(p, Points[i - 1], Points[i]) <= tolerance + LineWidth / 2)
                            return true;
                    }
                    return false;
                case AnnotationTool.Rect:
                case AnnotationTool.Ellipse:
                    var outer = new Rect(Bounds.Left - tolerance, Bounds.Top - tolerance,
                        Bounds.Width + tolerance * 2, Bounds.Height + tolerance * 2);
                    var inner = Bounds.Width > tolerance * 2 && Bounds.Height > tolerance * 2
                        ? new Rect(Bounds.Left + tolerance, Bounds.Top + tolerance,
                            Bounds.Width - tolerance * 2, Bounds.Height - tolerance * 2)
                        : Rect.Empty;
                    return outer.Contains(p) && (inner.IsEmpty || !inner.Contains(p));
                default: return false;
            }
        }

        public AnnotationData Clone() => new()
        {
            Tool = Tool, Color = Color, LineWidth = LineWidth,
            Points = new List<Point>(Points), Bounds = Bounds, Element = Element
        };

        private static double DistanceToSegment(Point p, Point a, Point b)
        {
            var dx = b.X - a.X; var dy = b.Y - a.Y;
            if (dx == 0 && dy == 0) return Distance(p, a);
            var t = Math.Clamp(((p.X - a.X) * dx + (p.Y - a.Y) * dy) / (dx * dx + dy * dy), 0, 1);
            return Distance(p, new Point(a.X + t * dx, a.Y + t * dy));
        }

        private static double Distance(Point a, Point b)
        {
            var dx = a.X - b.X; var dy = a.Y - b.Y;
            return Math.Sqrt(dx * dx + dy * dy);
        }
    }

    // Select 工具状态
    private int _selectedAnnotationIndex = -1;
    private Point _selectDragStart;
    private AnnotationData? _selectDragStartData;
    private int _selectHandleIndex = -1;          // -1=无手柄，0-7=8方向手柄
    private UIElement? _selectionHighlightElement; // 选中高亮框

    public ScreenshotCaptureResult Result { get; private set; } = ScreenshotCaptureResult.Cancelled;

    /// 旧构造（同步，保留兼容性）
    public ScreenshotSelectionWindow(BitmapSource snapshot, ScreenCaptureBounds bounds, bool requiresConfirmation)
        : this(bounds, requiresConfirmation)
    {
        _snapshot = snapshot;
        _image.Source = snapshot;
    }

    /// 新构造（异步模式，先弹窗后通过 ApplySnapshot 贴入截图）
    public ScreenshotSelectionWindow(ScreenCaptureBounds bounds, bool requiresConfirmation)
    {
        _bounds = bounds;
        _requiresConfirmation = requiresConfirmation;
        Left = bounds.PixelBounds.X;
        Top = bounds.PixelBounds.Y;
        Width = bounds.PixelBounds.Width;
        Height = bounds.PixelBounds.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        ShowInTaskbar = false;
        Focusable = true;
        Cursor = Cursors.Cross;
        Background = Brushes.Transparent;
        PreviewKeyDown += OnKeyDown;
        Loaded += (_, _) =>
        {
            Activate();
            Focus();
            Keyboard.Focus(this);
        };
        SourceInitialized += OnSourceInitialized;
        SizeChanged += (_, _) => UpdateVisuals();
        MouseMove += OnWindowMouseMove;
        BuildContent();
    }

    /// 截图完成后异步贴入，触发重绘
    public void ApplySnapshot(BitmapSource snapshot)
    {
        _snapshot = snapshot;
        _image.Source = snapshot;
        _image.Width = ActualWidth > 0 ? ActualWidth : Width;
        _image.Height = ActualHeight > 0 ? ActualHeight : Height;
        UpdateVisuals();
    }

    /// 截图失败时关闭窗口
    public void FailAndClose()
    {
        Result = ScreenshotCaptureResult.Failed;
        DialogResult = false;
    }

    /// 监听鼠标移动更新多屏高亮（节流：只在切换屏幕时重建遮罩）
    private void OnWindowMouseMove(object sender, MouseEventArgs e)
    {
        // 有选区时不需要高亮切换
        if (IsValidSelection) return;
        var pt = e.GetPosition(this);
        var screenPt = PointToScreen(pt);
        var active = WinForms.Screen.FromPoint(
            new System.Drawing.Point((int)screenPt.X, (int)screenPt.Y));
        // 只在屏幕切换时才重建遮罩，避免每次 MouseMove 都创建 GeometryGroup
        if (active.DeviceName == _lastMouseScreen?.DeviceName) return;
        _lastMouseScreen = active;
        _activeScreen = active;
        UpdateMask();
    }

    private void BuildContent()
    {
        _image.Stretch = Stretch.Fill;
        _image.Width = Width;
        _image.Height = Height;
        _canvas.Children.Add(_image);

        _mask.Fill = new SolidColorBrush(Color.FromArgb(108, 0, 0, 0));
        _canvas.Children.Add(_mask);

        _selection.Stroke = Brushes.DeepSkyBlue;
        _selection.StrokeThickness = 2;
        _selection.Fill = Brushes.Transparent;
        _selection.Visibility = Visibility.Collapsed;
        _canvas.Children.Add(_selection);

        for (var i = 0; i < _handles.Length; i++)
        {
            _handles[i] = new Rectangle
            {
                Width = 10, Height = 10, RadiusX = 3, RadiusY = 3,
                Fill = Brushes.DeepSkyBlue,
                Stroke = Brushes.White, StrokeThickness = 1,
                Visibility = Visibility.Collapsed
            };
            _canvas.Children.Add(_handles[i]);
        }

        var confirm = MakeActionButton("✓", Color.FromRgb(22, 163, 74));
        var cancel = MakeActionButton("×", Color.FromRgb(220, 38, 38));
        confirm.Click += (_, _) => ConfirmSelection();
        cancel.Click += (_, _) => CancelSelection();
        _actions.Orientation = Orientation.Horizontal;
        _actions.Background = Brushes.Transparent;
        _actions.Visibility = Visibility.Collapsed;
        _actions.Effect = new System.Windows.Media.Effects.DropShadowEffect
        {
            Color = Colors.Black, ShadowDepth = 0, BlurRadius = 10, Opacity = 0.28
        };
        _actions.Children.Add(confirm);
        _actions.Children.Add(cancel);
        _canvas.Children.Add(_actions);

        if (_requiresConfirmation)
        {
            BuildToolbar();
        }

        _canvas.MouseLeftButtonDown += OnMouseDown;
        _canvas.MouseMove += OnMouseMove;
        _canvas.MouseLeftButtonUp += OnMouseUp;
        _canvas.MouseRightButtonDown += (_, _) => CancelSelection();
        Content = _canvas;
        UpdateVisuals();
    }

    private void BuildToolbar()
    {
        _toolbar.Orientation = Orientation.Horizontal;
        _toolbar.Background = new SolidColorBrush(Color.FromArgb(184, 0, 0, 0));
        _toolbar.Visibility = Visibility.Visible;

        var border = new Border
        {
            CornerRadius = new CornerRadius(8),
            Child = _toolbar,
            Padding = new Thickness(6, 4, 6, 4),
            Visibility = Visibility.Collapsed
        };

        // 铅笔
        var penBtn = MakeToolButton("✏", AnnotationTool.Pen);
        _toolbar.Children.Add(penBtn);

        // 矩形
        var rectBtn = MakeToolButton("▭", AnnotationTool.Rect);
        _toolbar.Children.Add(rectBtn);

        // 椭圆
        var ellipseBtn = MakeToolButton("○", AnnotationTool.Ellipse);
        _toolbar.Children.Add(ellipseBtn);

        // 分隔线
        _toolbar.Children.Add(MakeSeparator());

        // 颜色
        var paletteColors = new[]
        {
            Colors.Red, Colors.Orange, Colors.Yellow,
            Colors.LimeGreen, Colors.DeepSkyBlue, Colors.White
        };
        foreach (var c in paletteColors)
        {
            var colorButton = MakeColorButton(c);
            _toolbar.Children.Add(colorButton);
            if (c == _penColor)
                colorButton.BorderThickness = new Thickness(2);
        }

        // 分隔线
        _toolbar.Children.Add(MakeSeparator());

        // 撤销
        var undoBtn = MakeIconButton("↩");
        undoBtn.Click += (_, _) => UndoLastAnnotation();
        _toolbar.Children.Add(undoBtn);

        // 将 border 放入 canvas（后续定位）
        _canvas.Children.Add(border);
        _toolbar.Tag = border;
    }

    private Button MakeToolButton(string text, AnnotationTool tool)
    {
        var btn = new Button
        {
            Content = text,
            Width = 30, Height = 30,
            Margin = new Thickness(2),
            FontSize = 15,
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(50, 255, 255, 255)),
            BorderBrush = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand,
            Tag = tool
        };
        btn.Click += (_, _) => SelectTool(tool, btn);
        return btn;
    }

    private Button MakeIconButton(string text)
    {
        return new Button
        {
            Content = text,
            Width = 30, Height = 30,
            Margin = new Thickness(2),
            FontSize = 15,
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(50, 255, 255, 255)),
            BorderBrush = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand
        };
    }

    private Button MakeColorButton(Color color)
    {
        var btn = new Button
        {
            Width = 18, Height = 18,
            Margin = new Thickness(3),
            Background = new SolidColorBrush(color),
            BorderBrush = Brushes.White,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand,
            Tag = color
        };
        btn.Click += (_, _) => SelectColor(color, btn);
        return btn;
    }

    private static FrameworkElement MakeSeparator()
    {
        return new Border
        {
            Width = 1, Height = 22,
            Margin = new Thickness(4, 0, 4, 0),
            Background = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255))
        };
    }

    private void SelectTool(AnnotationTool tool, Button clicked)
    {
        _currentTool = _currentTool == tool
            ? AnnotationTool.None
            : tool;
        DeselectAnnotation();
        Cursor = _currentTool == AnnotationTool.None   ? Cursors.Cross
               : Cursors.Pen;
        RefreshToolHighlight();
    }

    private void ExitAnnotationTool()
    {
        if (_currentTool == AnnotationTool.None) return;
        _currentTool = AnnotationTool.None;
        Cursor = Cursors.Arrow;
        RefreshToolHighlight();
    }

    private void RefreshToolHighlight()
    {
        foreach (var child in _toolbar.Children.OfType<Button>())
        {
            if (child.Tag is AnnotationTool t && t != AnnotationTool.None)
            {
                child.Background = (t == _currentTool)
                    ? new SolidColorBrush(Color.FromArgb(140, 0, 200, 220))
                    : new SolidColorBrush(Color.FromArgb(50, 255, 255, 255));
            }
        }
    }

    private void SelectColor(Color color, Button clicked)
    {
        _penColor = color;
        foreach (var child in _toolbar.Children.OfType<Button>())
        {
            if (child.Tag is Color)
                child.BorderThickness = new Thickness(0);
        }
        clicked.BorderThickness = new Thickness(2);
    }

    private void UndoLastAnnotation()
    {
        if (_selectedAnnotationIndex >= 0)
        {
            DeleteAnnotation(_selectedAnnotationIndex);
            return;
        }
        if (_annotations.Count == 0) return;
        var last = _annotations[^1];
        _annotations.RemoveAt(_annotations.Count - 1);
        if (last.Element != null) _canvas.Children.Remove(last.Element);
    }

    // MARK: - 标注绘制

    private void StartAnnotation(Point p)
    {
        _annotationStart = p;
        _currentAnnotation = new AnnotationData
        {
            Tool = _currentTool,
            Color = _penColor,
            LineWidth = _currentTool == AnnotationTool.Pen ? 3 : 2,
            Points = { p },
            Bounds = new Rect(p, p)
        };

        UIElement? el = _currentTool switch
        {
            AnnotationTool.Pen => CreatePolyline(new[] { p }, _penColor, 3),
            AnnotationTool.Rect => CreateOutlineRect(new Rect(p, p), _penColor, 2),
            AnnotationTool.Ellipse => CreateOutlineEllipse(new Rect(p, p), _penColor, 2),
            _ => null
        };

        if (el != null)
        {
            _canvas.Children.Add(el);
            _currentAnnotation.Element = el;
            _currentAnnotationElement = el;
        }
    }

    private void UpdateAnnotation(Point p)
    {
        if (_currentAnnotation == null) return;

        switch (_currentTool)
        {
            case AnnotationTool.Pen:
                // 抽样：相邻点距离 < 2px 时跳过，减少 Polyline 点集规模
                if (_currentAnnotation.Points.Count == 0 ||
                    Distance(_currentAnnotation.Points[^1], p) >= 2.0)
                {
                    _currentAnnotation.Points.Add(p);
                    if (_currentAnnotationElement is Polyline pl)
                        pl.Points.Add(p);
                }
                break;

            case AnnotationTool.Rect:
                var rRect = NormalizeRect(_annotationStart, p);
                _currentAnnotation.Bounds = rRect;
                if (_currentAnnotationElement is System.Windows.Shapes.Rectangle r)
                {
                    Canvas.SetLeft(r, rRect.Left);
                    Canvas.SetTop(r, rRect.Top);
                    r.Width = Math.Max(1, rRect.Width);
                    r.Height = Math.Max(1, rRect.Height);
                }
                break;

            case AnnotationTool.Ellipse:
                var eRect = NormalizeRect(_annotationStart, p);
                _currentAnnotation.Bounds = eRect;
                if (_currentAnnotationElement is System.Windows.Shapes.Ellipse e)
                {
                    Canvas.SetLeft(e, eRect.Left);
                    Canvas.SetTop(e, eRect.Top);
                    e.Width = Math.Max(1, eRect.Width);
                    e.Height = Math.Max(1, eRect.Height);
                }
                break;

        }
    }

    private void FinishAnnotation(Point p)
    {
        UpdateAnnotation(p);
        if (_currentAnnotation != null)
            _annotations.Add(_currentAnnotation);
        _currentAnnotation = null;
        _currentAnnotationElement = null;
    }

    private Polyline CreatePolyline(IEnumerable<Point> pts, Color color, double width)
    {
        var pl = new Polyline
        {
            Stroke = new SolidColorBrush(color),
            StrokeThickness = width,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            IsHitTestVisible = false
        };
        foreach (var p in pts) pl.Points.Add(p);
        return pl;
    }

    private System.Windows.Shapes.Rectangle CreateOutlineRect(Rect bounds, Color color, double width)
    {
        var r = new System.Windows.Shapes.Rectangle
        {
            Width = Math.Max(1, bounds.Width),
            Height = Math.Max(1, bounds.Height),
            Stroke = new SolidColorBrush(color),
            StrokeThickness = width,
            Fill = new SolidColorBrush(Color.FromArgb(40, color.R, color.G, color.B)),
            IsHitTestVisible = false
        };
        Canvas.SetLeft(r, bounds.Left);
        Canvas.SetTop(r, bounds.Top);
        return r;
    }

    private System.Windows.Shapes.Ellipse CreateOutlineEllipse(Rect bounds, Color color, double width)
    {
        var e = new System.Windows.Shapes.Ellipse
        {
            Width = Math.Max(1, bounds.Width),
            Height = Math.Max(1, bounds.Height),
            Stroke = new SolidColorBrush(color),
            StrokeThickness = width,
            Fill = new SolidColorBrush(Color.FromArgb(40, color.R, color.G, color.B)),
            IsHitTestVisible = false
        };
        Canvas.SetLeft(e, bounds.Left);
        Canvas.SetTop(e, bounds.Top);
        return e;
    }

    private static Rect NormalizeRect(Point a, Point b) =>
        new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y),
            Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y));

    private static double Distance(Point a, Point b)
    {
        var dx = a.X - b.X;
        var dy = a.Y - b.Y;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    // MARK: - Mouse Handlers

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        var p = e.GetPosition(_canvas);

        // 标注命中优先于绘制工具：点击已有标注会自动退出绘制态并选中对象
        if (_requiresConfirmation && IsValidSelection)
        {
            if (_selectedAnnotationIndex >= 0)
            {
                var hi = HitTestAnnotationHandle(p, _selectedAnnotationIndex);
                if (hi >= 0)
                {
                    ExitAnnotationTool();
                    _selectHandleIndex = hi;
                    _selectDragStart = p;
                    _selectDragStartData = _annotations[_selectedAnnotationIndex].Clone();
                    _canvas.CaptureMouse();
                    return;
                }
            }
            var hitIdx = HitTestAnnotations(p);
            if (hitIdx >= 0)
            {
                ExitAnnotationTool();
                SelectAnnotation(hitIdx);
                _selectDragStart = p;
                _selectDragStartData = _annotations[hitIdx].Clone();
                _selectHandleIndex = -1;
                _canvas.CaptureMouse();
                return;
            }

            if (_currentTool == AnnotationTool.None)
            {
                DeselectAnnotation();
            }
        }

        // 绘制工具
        if (_requiresConfirmation && _currentTool != AnnotationTool.None
            && IsValidSelection && _selectionRect.Contains(p))
        {
            _canvas.CaptureMouse();
            StartAnnotation(p);
            return;
        }

        if (IsMouseOverActions(p)) return;
        var mode = ModeAt(p);
        if (_requiresConfirmation &&
            _currentTool == AnnotationTool.None &&
            IsValidSelection &&
            _selectionRect.Contains(p) &&
            mode == DragMode.None)
        {
            return;
        }

        _start = p;
        _dragStartSelection = _selectionRect;
        _dragMode = mode;
        if (_dragMode == DragMode.None)
        {
            _dragMode = DragMode.New;
            _selectionRect = new Rect(_start, _start);
        }
        _selection.Visibility = Visibility.Visible;
        _actions.Visibility = Visibility.Collapsed;
        _canvas.CaptureMouse();
        UpdateVisuals();
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        var point = e.GetPosition(_canvas);

        // 标注对象拖拽
        if (_canvas.IsMouseCaptured && _selectDragStartData != null)
        {
            if (_selectedAnnotationIndex >= 0 && _selectDragStartData != null)
            {
                var dx = point.X - _selectDragStart.X;
                var dy = point.Y - _selectDragStart.Y;
                if (_selectHandleIndex >= 0)
                    ResizeAnnotation(_selectedAnnotationIndex, _selectHandleIndex, _selectDragStartData, dx, dy);
                else
                    MoveAnnotation(_selectedAnnotationIndex, _selectDragStartData, dx, dy);
                UpdateSelectionHighlight(_selectedAnnotationIndex);
            }
            return;
        }

        if (_currentAnnotation != null)
        {
            UpdateAnnotation(point);
            return;
        }

        if (_dragMode != DragMode.None)
            UpdateSelection(point);
        else
            Cursor = CursorForPoint(point);
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        var p = e.GetPosition(_canvas);

        if (_canvas.IsMouseCaptured && _selectDragStartData != null)
        {
            _canvas.ReleaseMouseCapture();
            _selectDragStartData = null;
            _selectHandleIndex = -1;
            return;
        }

        if (_currentAnnotation != null)
        {
            FinishAnnotation(p);
            _canvas.ReleaseMouseCapture();
            return;
        }

        if (_dragMode == DragMode.None) return;
        UpdateSelection(p);
        _dragMode = DragMode.None;
        _canvas.ReleaseMouseCapture();
        if (!_requiresConfirmation)
        {
            if (LongImageMode) { SelectForLongImage(); return; }
            ConfirmSelection();
            return;
        }
        PositionActions();
        PositionToolbar();
    }

    /// 长图模式：松开后不裁切，仅返回「屏幕像素坐标」的固定选区，交由 ScrollingCaptureWindow 滚动采集。
    public bool LongImageMode { get; set; }
    public Int32Rect? LongImagePixelRect { get; private set; }

    private void SelectForLongImage()
    {
        if (!IsValidSelection || _snapshot == null) { CancelSelection(); return; }
        var snapshot = _snapshot;
        var scaleX = snapshot.PixelWidth / Math.Max(1, ActualWidth);
        var scaleY = snapshot.PixelHeight / Math.Max(1, ActualHeight);
        int px = Math.Clamp((int)Math.Round(_selectionRect.Left * scaleX), 0, snapshot.PixelWidth - 1);
        int py = Math.Clamp((int)Math.Round(_selectionRect.Top * scaleY), 0, snapshot.PixelHeight - 1);
        int pw = Math.Max(1, Math.Min((int)Math.Round(_selectionRect.Width * scaleX), snapshot.PixelWidth - px));
        int ph = Math.Max(1, Math.Min((int)Math.Round(_selectionRect.Height * scaleY), snapshot.PixelHeight - py));
        // 转为虚拟屏幕像素坐标（加上虚拟屏原点）
        LongImagePixelRect = new Int32Rect(
            (int)Math.Round(_bounds.PixelBounds.X) + px,
            (int)Math.Round(_bounds.PixelBounds.Y) + py,
            pw, ph);
        Close();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        try
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var pixelBounds = _bounds.PixelBounds;
            SetWindowPos(
                hwnd, IntPtr.Zero,
                (int)Math.Round(pixelBounds.X),
                (int)Math.Round(pixelBounds.Y),
                (int)Math.Round(pixelBounds.Width),
                (int)Math.Round(pixelBounds.Height),
                SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);

            DebugTrace.Log(
                "Screenshot",
                $"selectionWindow px={pixelBounds.X:0},{pixelBounds.Y:0},{pixelBounds.Width:0}x{pixelBounds.Height:0}, dip={Width:0.##}x{Height:0.##}, actual={ActualWidth:0.##}x{ActualHeight:0.##}, snapshot={_snapshot?.PixelWidth ?? 0}x{_snapshot?.PixelHeight ?? 0}");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("Screenshot.SelectionWindow", ex);
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            if (_selectedAnnotationIndex >= 0 || _currentTool != AnnotationTool.None)
            {
                DeselectAnnotation();
                _currentTool = AnnotationTool.None;
                Cursor = Cursors.Cross;
                RefreshToolHighlight();
                e.Handled = true;
                return;
            }
            CancelSelection();
            e.Handled = true;
            return;
        }
        if ((e.Key == Key.Delete || e.Key == Key.Back) && _selectedAnnotationIndex >= 0)
        {
            DeleteAnnotation(_selectedAnnotationIndex);
            e.Handled = true;
        }
    }

    // MARK: - Selection Logic

    private void UpdateSelection(Point point)
    {
        _selectionRect = _dragMode switch
        {
            DragMode.New => Clamp(Normalize(new Rect(_start, point))),
            DragMode.Move => Clamp(new Rect(
                _dragStartSelection.X + point.X - _start.X,
                _dragStartSelection.Y + point.Y - _start.Y,
                _dragStartSelection.Width, _dragStartSelection.Height)),
            DragMode.TopLeft => Clamp(Normalize(new Rect(point,
                new Point(_dragStartSelection.Right, _dragStartSelection.Bottom)))),
            DragMode.TopRight => Clamp(Normalize(new Rect(
                new Point(_dragStartSelection.Left, point.Y),
                new Point(point.X, _dragStartSelection.Bottom)))),
            DragMode.BottomLeft => Clamp(Normalize(new Rect(
                new Point(point.X, _dragStartSelection.Top),
                new Point(_dragStartSelection.Right, point.Y)))),
            DragMode.BottomRight => Clamp(Normalize(new Rect(
                _dragStartSelection.TopLeft, point))),
            _ => _selectionRect
        };
        UpdateVisuals();
    }

    private void PositionActions()
    {
        if (!IsValidSelection) { _actions.Visibility = Visibility.Collapsed; return; }
        _actions.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var x = _selectionRect.Right - _actions.DesiredSize.Width;
        var y = _selectionRect.Bottom + 8;
        if (y + _actions.DesiredSize.Height > ActualHeight - 8)
            y = _selectionRect.Top - _actions.DesiredSize.Height - 8;
        Canvas.SetLeft(_actions, Math.Max(8, Math.Min(x, ActualWidth - _actions.DesiredSize.Width - 8)));
        Canvas.SetTop(_actions, Math.Max(8, Math.Min(y, ActualHeight - _actions.DesiredSize.Height - 8)));
        _actions.Visibility = Visibility.Visible;
    }

    private void PositionToolbar()
    {
        if (!_requiresConfirmation || !IsValidSelection) return;
        if (_toolbar.Tag is not Border border) return;

        border.Visibility = Visibility.Visible;
        border.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var tw = border.DesiredSize.Width;
        var th = border.DesiredSize.Height;
        var tx = Math.Max(8, Math.Min(_selectionRect.Left, ActualWidth - tw - 8));
        var ty = _selectionRect.Bottom + 42;
        if (ty + th > ActualHeight - 8)
            ty = Math.Max(8, _selectionRect.Top - th - 42);
        Canvas.SetLeft(border, tx);
        Canvas.SetTop(border, ty);
    }

    private void ConfirmSelection()
    {
        if (!IsValidSelection || _snapshot == null) { CancelSelection(); return; }
        try
        {
            var snapshot = _snapshot;
            var scaleX = snapshot.PixelWidth / Math.Max(1, ActualWidth);
            var scaleY = snapshot.PixelHeight / Math.Max(1, ActualHeight);
            var rect = new Int32Rect(
                Math.Clamp((int)Math.Round(_selectionRect.Left * scaleX), 0, snapshot.PixelWidth - 1),
                Math.Clamp((int)Math.Round(_selectionRect.Top * scaleY), 0, snapshot.PixelHeight - 1),
                Math.Max(1, Math.Min((int)Math.Round(_selectionRect.Width * scaleX), snapshot.PixelWidth)),
                Math.Max(1, Math.Min((int)Math.Round(_selectionRect.Height * scaleY), snapshot.PixelHeight)));
            if (rect.X + rect.Width > snapshot.PixelWidth)
                rect.Width = snapshot.PixelWidth - rect.X;
            if (rect.Y + rect.Height > snapshot.PixelHeight)
                rect.Height = snapshot.PixelHeight - rect.Y;

            var detached = CreateDetachedBitmap(snapshot, rect);
            if (_annotations.Count > 0)
                detached = ComposeAnnotations(detached, rect, scaleX, scaleY);
            ClipboardService.SetImage(detached);
            Result = ScreenshotCaptureResult.Copied;
            DialogResult = true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("Screenshot.SelectionWindow.Confirm", ex);
            Result = ScreenshotCaptureResult.Failed;
            DialogResult = false;
        }
    }

    private static BitmapSource CreateDetachedBitmap(BitmapSource source, Int32Rect rect)
    {
        var cropped = new CroppedBitmap(source, rect);
        BitmapSource bitmap = cropped.Format == PixelFormats.Pbgra32
            ? cropped
            : new FormatConvertedBitmap(cropped, PixelFormats.Pbgra32, null, 0);
        var stride = rect.Width * 4;
        var pixels = new byte[stride * rect.Height];
        bitmap.CopyPixels(pixels, stride, 0);
        var detached = BitmapSource.Create(rect.Width, rect.Height,
            source.DpiX, source.DpiY,
            PixelFormats.Pbgra32, null, pixels, stride);
        detached.Freeze();
        return detached;
    }

    private BitmapSource ComposeAnnotations(BitmapSource baseImage, Int32Rect sourceRect, double scaleX, double scaleY)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawImage(baseImage, new Rect(0, 0, baseImage.PixelWidth, baseImage.PixelHeight));
            dc.PushClip(new RectangleGeometry(new Rect(0, 0, baseImage.PixelWidth, baseImage.PixelHeight)));
            foreach (var annotation in _annotations)
                DrawAnnotation(dc, annotation, sourceRect, scaleX, scaleY);
            dc.Pop();
        }

        var rendered = new RenderTargetBitmap(
            baseImage.PixelWidth,
            baseImage.PixelHeight,
            baseImage.DpiX,
            baseImage.DpiY,
            PixelFormats.Pbgra32);
        rendered.Render(visual);
        rendered.Freeze();
        return rendered;
    }

    private static void DrawAnnotation(
        DrawingContext dc,
        AnnotationData annotation,
        Int32Rect sourceRect,
        double scaleX,
        double scaleY)
    {
        var brush = new SolidColorBrush(annotation.Color);
        brush.Freeze();
        var pen = new Pen(brush, Math.Max(1, annotation.LineWidth * Math.Max(scaleX, scaleY)))
        {
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round,
            LineJoin = PenLineJoin.Round
        };
        pen.Freeze();

        Point Map(Point p) => new(
            p.X * scaleX - sourceRect.X,
            p.Y * scaleY - sourceRect.Y);
        Rect MapRect(Rect r) => new(
            r.X * scaleX - sourceRect.X,
            r.Y * scaleY - sourceRect.Y,
            Math.Max(1, r.Width * scaleX),
            Math.Max(1, r.Height * scaleY));

        switch (annotation.Tool)
        {
            case AnnotationTool.Pen:
                for (var i = 1; i < annotation.Points.Count; i++)
                    dc.DrawLine(pen, Map(annotation.Points[i - 1]), Map(annotation.Points[i]));
                break;
            case AnnotationTool.Rect:
                dc.DrawRectangle(null, pen, MapRect(annotation.Bounds));
                break;
            case AnnotationTool.Ellipse:
                var ellipseRect = MapRect(annotation.Bounds);
                dc.DrawEllipse(null, pen,
                    new Point(ellipseRect.Left + ellipseRect.Width / 2, ellipseRect.Top + ellipseRect.Height / 2),
                    ellipseRect.Width / 2,
                    ellipseRect.Height / 2);
                break;
        }
    }

    private void CancelSelection()
    {
        Result = ScreenshotCaptureResult.Cancelled;
        DialogResult = false;
    }

    private bool IsMouseOverActions(Point p) =>
        _actions.Visibility == Visibility.Visible &&
        p.X >= Canvas.GetLeft(_actions) &&
        p.X <= Canvas.GetLeft(_actions) + _actions.ActualWidth &&
        p.Y >= Canvas.GetTop(_actions) &&
        p.Y <= Canvas.GetTop(_actions) + _actions.ActualHeight;

    private bool IsValidSelection =>
        !_selectionRect.IsEmpty && _selectionRect.Width >= _minSize && _selectionRect.Height >= _minSize;

    private void UpdateVisuals()
    {
        var visualWidth = ActualWidth > 0 ? ActualWidth : Width;
        var visualHeight = ActualHeight > 0 ? ActualHeight : Height;
        _image.Width = visualWidth;
        _image.Height = visualHeight;

        UpdateMask();

        _selection.Visibility = IsValidSelection ? Visibility.Visible : Visibility.Collapsed;
        if (IsValidSelection)
        {
            Canvas.SetLeft(_selection, _selectionRect.Left);
            Canvas.SetTop(_selection, _selectionRect.Top);
            _selection.Width = _selectionRect.Width;
            _selection.Height = _selectionRect.Height;
        }

        UpdateHandles();
        if (_actions.Visibility == Visibility.Visible)
            PositionActions();
    }

    private void UpdateMask()
    {
        var visualWidth = ActualWidth > 0 ? ActualWidth : Width;
        var visualHeight = ActualHeight > 0 ? ActualHeight : Height;
        var full = new Rect(0, 0, Math.Max(0, visualWidth), Math.Max(0, visualHeight));
        var geometry = new GeometryGroup { FillRule = FillRule.EvenOdd };
        geometry.Children.Add(new RectangleGeometry(full));

        if (IsValidSelection)
        {
            // 有选区时镂空选区
            geometry.Children.Add(new RectangleGeometry(_selectionRect));
            _mask.Fill = new SolidColorBrush(Color.FromArgb(108, 0, 0, 0));
            _mask.Data = geometry;
        }
        else if (_activeScreen != null && WinForms.Screen.AllScreens.Length > 1)
        {
            // 多屏时高亮鼠标所在屏幕：整体深遮罩 + 活跃屏减淡
            var pixelBounds = _bounds.PixelBounds;
            var scaleX = visualWidth / Math.Max(1, pixelBounds.Width);
            var scaleY = visualHeight / Math.Max(1, pixelBounds.Height);
            var ab = _activeScreen.Bounds;
            var localRect = new Rect(
                (ab.X - pixelBounds.X) * scaleX,
                (ab.Y - pixelBounds.Y) * scaleY,
                ab.Width * scaleX,
                ab.Height * scaleY);
            geometry.Children.Add(new RectangleGeometry(localRect));
            _mask.Fill = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0));
            _mask.Data = geometry;

            // 活跃屏浅遮罩叠加（通过独立元素实现减淡效果）
            // 使用 Tag 记录活跃屏高亮层，避免重复添加
            if (_canvas.Tag is not System.Windows.Shapes.Path activeHighlight)
            {
                activeHighlight = new System.Windows.Shapes.Path
                {
                    Fill = new SolidColorBrush(Color.FromArgb(51, 0, 0, 0)),
                    IsHitTestVisible = false
                };
                _canvas.Children.Insert(2, activeHighlight); // 在 mask 上方
                _canvas.Tag = activeHighlight;
            }
            activeHighlight.Data = new RectangleGeometry(localRect);
        }
        else
        {
            _mask.Fill = new SolidColorBrush(Color.FromArgb(108, 0, 0, 0));
            _mask.Data = geometry;
        }
    }

    private void UpdateHandles()
    {
        for (var i = 0; i < _handles.Length; i++)
            _handles[i].Visibility = IsValidSelection ? Visibility.Visible : Visibility.Collapsed;
        if (!IsValidSelection) return;
        var points = new[]
        {
            new Point(_selectionRect.Left, _selectionRect.Top),
            new Point(_selectionRect.Right, _selectionRect.Top),
            new Point(_selectionRect.Left, _selectionRect.Bottom),
            new Point(_selectionRect.Right, _selectionRect.Bottom)
        };
        for (var i = 0; i < _handles.Length; i++)
        {
            Canvas.SetLeft(_handles[i], points[i].X - _handles[i].Width / 2);
            Canvas.SetTop(_handles[i], points[i].Y - _handles[i].Height / 2);
        }
    }

    private DragMode ModeAt(Point point)
    {
        if (!IsValidSelection) return DragMode.None;
        if (HandleRect(DragMode.TopLeft).Contains(point)) return DragMode.TopLeft;
        if (HandleRect(DragMode.TopRight).Contains(point)) return DragMode.TopRight;
        if (HandleRect(DragMode.BottomLeft).Contains(point)) return DragMode.BottomLeft;
        if (HandleRect(DragMode.BottomRight).Contains(point)) return DragMode.BottomRight;
        return IsSelectionMoveBand(point)
            ? DragMode.Move
            : DragMode.None;
    }

    private bool IsSelectionMoveBand(Point point)
    {
        const double borderSize = 7;
        var outer = new Rect(
            _selectionRect.Left - borderSize,
            _selectionRect.Top - borderSize,
            _selectionRect.Width + borderSize * 2,
            _selectionRect.Height + borderSize * 2);
        var inner = new Rect(
            _selectionRect.Left + borderSize,
            _selectionRect.Top + borderSize,
            Math.Max(0, _selectionRect.Width - borderSize * 2),
            Math.Max(0, _selectionRect.Height - borderSize * 2));
        return outer.Contains(point) && !inner.Contains(point);
    }

    private Rect HandleRect(DragMode mode)
    {
        const double size = 14;
        var point = mode switch
        {
            DragMode.TopLeft => new Point(_selectionRect.Left, _selectionRect.Top),
            DragMode.TopRight => new Point(_selectionRect.Right, _selectionRect.Top),
            DragMode.BottomLeft => new Point(_selectionRect.Left, _selectionRect.Bottom),
            _ => new Point(_selectionRect.Right, _selectionRect.Bottom)
        };
        return new Rect(point.X - size / 2, point.Y - size / 2, size, size);
    }

    private Rect Normalize(Rect rect) =>
        new(Math.Min(rect.Left, rect.Right), Math.Min(rect.Top, rect.Bottom),
            Math.Abs(rect.Width), Math.Abs(rect.Height));

    private Rect Clamp(Rect rect)
    {
        var width = Math.Min(Math.Max(rect.Width, 1), ActualWidth > 0 ? ActualWidth : Width);
        var height = Math.Min(Math.Max(rect.Height, 1), ActualHeight > 0 ? ActualHeight : Height);
        var maxX = (ActualWidth > 0 ? ActualWidth : Width) - width;
        var maxY = (ActualHeight > 0 ? ActualHeight : Height) - height;
        return new Rect(
            Math.Max(0, Math.Min(rect.Left, maxX)),
            Math.Max(0, Math.Min(rect.Top, maxY)),
            width, height);
    }

    private static Cursor CursorForMode(DragMode mode) => mode switch
    {
        DragMode.Move => Cursors.SizeAll,
        DragMode.TopLeft or DragMode.BottomRight => Cursors.SizeNWSE,
        DragMode.TopRight or DragMode.BottomLeft => Cursors.SizeNESW,
        _ => Cursors.Cross
    };

    private Cursor CursorForPoint(Point point)
    {
        if (_selectedAnnotationIndex >= 0)
        {
            var handle = HitTestAnnotationHandle(point, _selectedAnnotationIndex);
            if (handle >= 0)
                return CursorForAnnotationHandle(handle);
        }
        if (HitTestAnnotations(point) >= 0) return Cursors.SizeAll;
        if (_currentTool != AnnotationTool.None) return Cursors.Pen;
        var selectionMode = ModeAt(point);
        if (selectionMode != DragMode.None) return CursorForMode(selectionMode);
        return _selectionRect.Contains(point) ? Cursors.Arrow : Cursors.Cross;
    }

    private static Cursor CursorForAnnotationHandle(int handleIdx) => handleIdx switch
    {
        0 or 4 => Cursors.SizeNWSE,
        2 or 6 => Cursors.SizeNESW,
        1 or 5 => Cursors.SizeNS,
        3 or 7 => Cursors.SizeWE,
        _ => Cursors.SizeAll
    };

    private static Button MakeActionButton(string text, Color color) =>
        new()
        {
            Content = text,
            Width = 30, Height = 30,
            Margin = new Thickness(3),
            FontSize = 16, FontWeight = FontWeights.Bold,
            Foreground = Brushes.White,
            Background = new SolidColorBrush(color),
            BorderBrush = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand
        };

    // MARK: - Select Tool Helpers

    private int HitTestAnnotations(Point p)
    {
        for (var i = _annotations.Count - 1; i >= 0; i--)
            if (_annotations[i].HitTest(p)) return i;
        return -1;
    }

    /// 8 个手柄顺序：TL, T, TR, R, BR, B, BL, L
    private static Point[] AnnotationHandlePoints(Rect b) => new[]
    {
        new Point(b.Left, b.Top),       new Point(b.Left + b.Width / 2, b.Top),
        new Point(b.Right, b.Top),      new Point(b.Right, b.Top + b.Height / 2),
        new Point(b.Right, b.Bottom),   new Point(b.Left + b.Width / 2, b.Bottom),
        new Point(b.Left, b.Bottom),    new Point(b.Left, b.Top + b.Height / 2)
    };

    private int HitTestAnnotationHandle(Point p, int idx)
    {
        var ann = _annotations[idx];
        if (ann.Tool is not (AnnotationTool.Rect or AnnotationTool.Ellipse)) return -1;
        var pts = AnnotationHandlePoints(ann.Bounds);
        for (var i = 0; i < pts.Length; i++)
            if (Distance(p, pts[i]) <= 8) return i;
        return -1;
    }

    private void SelectAnnotation(int idx)
    {
        DeselectAnnotation();
        _selectedAnnotationIndex = idx;
        UpdateSelectionHighlight(idx);
    }

    private void DeselectAnnotation()
    {
        _selectedAnnotationIndex = -1;
        if (_selectionHighlightElement != null)
        {
            _canvas.Children.Remove(_selectionHighlightElement);
            _selectionHighlightElement = null;
        }
    }

    private void UpdateSelectionHighlight(int idx)
    {
        if (_selectionHighlightElement != null)
        {
            _canvas.Children.Remove(_selectionHighlightElement);
            _selectionHighlightElement = null;
        }
        if (idx < 0 || idx >= _annotations.Count) return;
        var ann = _annotations[idx];
        Rect hb;
        if (ann.Tool is AnnotationTool.Rect or AnnotationTool.Ellipse)
        {
            hb = new Rect(ann.Bounds.Left - 4, ann.Bounds.Top - 4,
                ann.Bounds.Width + 8, ann.Bounds.Height + 8);
        }
        else
        {
            var xs = ann.Points.Select(pt => pt.X).ToList();
            var ys = ann.Points.Select(pt => pt.Y).ToList();
            hb = new Rect(xs.Min() - 4, ys.Min() - 4,
                xs.Max() - xs.Min() + 8, ys.Max() - ys.Min() + 8);
        }
        var panel = new Canvas { IsHitTestVisible = false };
        var border = new System.Windows.Shapes.Rectangle
        {
            Width = hb.Width, Height = hb.Height,
            Stroke = Brushes.White, StrokeThickness = 1.5,
            StrokeDashArray = new DoubleCollection { 4, 3 },
            Fill = Brushes.Transparent
        };
        Canvas.SetLeft(border, hb.Left); Canvas.SetTop(border, hb.Top);
        panel.Children.Add(border);
        // 8 手柄（Rect/Ellipse）
        if (ann.Tool is AnnotationTool.Rect or AnnotationTool.Ellipse)
        {
            foreach (var hp in AnnotationHandlePoints(ann.Bounds))
            {
                var h = new System.Windows.Shapes.Ellipse
                    { Width = 8, Height = 8, Fill = Brushes.White, Stroke = Brushes.Gray, StrokeThickness = 1 };
                Canvas.SetLeft(h, hp.X - 4); Canvas.SetTop(h, hp.Y - 4);
                panel.Children.Add(h);
            }
        }
        _canvas.Children.Add(panel);
        _selectionHighlightElement = panel;
    }

    private void MoveAnnotation(int idx, AnnotationData origin, double dx, double dy)
    {
        var ann = _annotations[idx];
        if (ann.Tool is AnnotationTool.Rect or AnnotationTool.Ellipse)
        {
            ann.Bounds = new Rect(origin.Bounds.Left + dx, origin.Bounds.Top + dy,
                origin.Bounds.Width, origin.Bounds.Height);
            if (ann.Element != null)
            {
                Canvas.SetLeft(ann.Element, ann.Bounds.Left);
                Canvas.SetTop(ann.Element, ann.Bounds.Top);
            }
        }
        else if (ann.Tool == AnnotationTool.Pen && ann.Element is Polyline pl)
        {
            pl.Points.Clear();
            for (var i = 0; i < origin.Points.Count; i++)
            {
                var np = new Point(origin.Points[i].X + dx, origin.Points[i].Y + dy);
                ann.Points[i] = np;
                pl.Points.Add(np);
            }
        }
    }

    private void ResizeAnnotation(int idx, int handleIdx, AnnotationData origin, double dx, double dy)
    {
        var ann = _annotations[idx];
        if (ann.Tool is not (AnnotationTool.Rect or AnnotationTool.Ellipse)) return;
        var ob = origin.Bounds;
        double left = ob.Left, top = ob.Top, right = ob.Right, bottom = ob.Bottom;
        // handleIdx 按 TL,T,TR,R,BR,B,BL,L 排列
        switch (handleIdx)
        {
            case 0: left += dx; top += dy; break;
            case 1: top += dy; break;
            case 2: right += dx; top += dy; break;
            case 3: right += dx; break;
            case 4: right += dx; bottom += dy; break;
            case 5: bottom += dy; break;
            case 6: left += dx; bottom += dy; break;
            case 7: left += dx; break;
        }
        if (right - left < 4) { if (handleIdx is 0 or 6 or 7) left = right - 4; else right = left + 4; }
        if (bottom - top < 4) { if (handleIdx is 0 or 1 or 2) top = bottom - 4; else bottom = top + 4; }
        ann.Bounds = new Rect(left, top, right - left, bottom - top);
        if (ann.Element != null)
        {
            Canvas.SetLeft(ann.Element, ann.Bounds.Left);
            Canvas.SetTop(ann.Element, ann.Bounds.Top);
            if (ann.Element is System.Windows.Shapes.Rectangle r)
            { r.Width = ann.Bounds.Width; r.Height = ann.Bounds.Height; }
            else if (ann.Element is System.Windows.Shapes.Ellipse e)
            { e.Width = ann.Bounds.Width; e.Height = ann.Bounds.Height; }
        }
    }

    private void DeleteAnnotation(int idx)
    {
        if (idx < 0 || idx >= _annotations.Count) return;
        var ann = _annotations[idx];
        if (ann.Element != null) _canvas.Children.Remove(ann.Element);
        _annotations.RemoveAt(idx);
        DeselectAnnotation();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int x, int y, int cx, int cy, int uFlags);
}
