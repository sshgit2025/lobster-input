using System.Windows;
using System.Windows.Input;

namespace LobsterInput.Helpers;

public static class WindowChromeCommandBinder
{
    public static void Attach(Window window)
    {
        if (window.CommandBindings.OfType<CommandBinding>().Any(IsChromeBinding))
            return;

        window.CommandBindings.Add(new CommandBinding(
            SystemCommands.MinimizeWindowCommand,
            (_, _) => window.WindowState = WindowState.Minimized,
            (_, e) => e.CanExecute = true));

        window.CommandBindings.Add(new CommandBinding(
            SystemCommands.MaximizeWindowCommand,
            (_, _) => window.WindowState = WindowState.Maximized,
            (_, e) => e.CanExecute = window.ResizeMode != ResizeMode.NoResize));

        window.CommandBindings.Add(new CommandBinding(
            SystemCommands.RestoreWindowCommand,
            (_, _) => window.WindowState = WindowState.Normal,
            (_, e) => e.CanExecute = true));

        window.CommandBindings.Add(new CommandBinding(
            SystemCommands.CloseWindowCommand,
            (_, _) => window.Close(),
            (_, e) => e.CanExecute = true));
    }

    private static bool IsChromeBinding(CommandBinding binding) =>
        ReferenceEquals(binding.Command, SystemCommands.MinimizeWindowCommand) ||
        ReferenceEquals(binding.Command, SystemCommands.MaximizeWindowCommand) ||
        ReferenceEquals(binding.Command, SystemCommands.RestoreWindowCommand) ||
        ReferenceEquals(binding.Command, SystemCommands.CloseWindowCommand);
}
