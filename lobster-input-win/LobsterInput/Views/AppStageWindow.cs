using System.ComponentModel;
using System.Windows;
using System.Windows.Media.Imaging;
using LobsterInput.Helpers;

namespace LobsterInput.Views;

public class AppStageWindow : Window
{
    private bool _allowClose;

    protected AppStageWindow(string title, double width, double height, UIElement? content)
    {
        Title = title;
        Width = width;
        Height = height;
        MinWidth = width;
        MinHeight = height;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = true;
        Icon = new BitmapImage(new Uri("pack://application:,,,/LobsterInput;component/Resources/Images/lobster.ico"));
        SetResourceReference(StyleProperty, "WindowsChromeWindowStyle");
        WindowChromeCommandBinder.Attach(this);
        WindowInteropTools.AttachWindowFramePreferences(this);

        if (content != null)
            Content = content;
    }

    protected void SetStageContent(UIElement content)
    {
        Content = content;
    }

    public void BringStageToFront()
    {
        Show();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    public void CloseForTransition()
    {
        _allowClose = true;
        Close();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            Hide();
            return;
        }

        base.OnClosing(e);
    }
}
