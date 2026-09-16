$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class WinFocus {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public static IntPtr CursorHwnd = IntPtr.Zero;
  public static bool Find(IntPtr h, IntPtr l) {
    if (!IsWindowVisible(h)) return true;
    uint pid; GetWindowThreadProcessId(h, out pid);
    try {
      if (Process.GetProcessById((int)pid).ProcessName.Equals("Cursor", StringComparison.OrdinalIgnoreCase)) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        if (sb.ToString().Contains("Chrome_WidgetWin")) { CursorHwnd = h; return false; }
      }
    } catch { }
    return true;
  }
}
'@
[WinFocus]::EnumWindows([WinFocus+EnumProc]{ param($a,$b) [WinFocus]::Find($a,$b) }, [IntPtr]::Zero)
if ([WinFocus]::CursorHwnd -ne [IntPtr]::Zero) {
  [WinFocus]::SetForegroundWindow([WinFocus]::CursorHwnd) | Out-Null
  Start-Sleep -Seconds 5
}
$exe = Join-Path $PSScriptRoot 'bin\Release\net8.0-windows\FocusProbe.exe'
$out = Join-Path $env:TEMP 'focusprobe-out3.txt'
& $exe *>&1 | Tee-Object -FilePath $out
Write-Host "Saved to $out"
