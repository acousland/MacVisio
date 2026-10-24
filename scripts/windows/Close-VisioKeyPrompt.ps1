# Runs in the interactive session during unactivated-reference acceptance runs: closes Visio's
# "Enter your product key" prompt (as the user would with its close button) and logs every other
# visible Visio window so unexpected dialogs are diagnosable. Stops when $StopFile exists.
param([string]$StopFile, [string]$Log)
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class KW {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static List<object[]> Visible(uint[] pids) {
    var r = new List<object[]>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
      if (Array.IndexOf(pids, p) >= 0 && IsWindowVisible(h)) { var t = new StringBuilder(256); var c = new StringBuilder(256);
        GetWindowText(h, t, 256); GetClassName(h, c, 256); r.Add(new object[] { h, p, c.ToString(), t.ToString() }); }
      return true; }, IntPtr.Zero);
    return r; } }
"@
$seen = @{}; $closed = 0
"$(Get-Date -f s) watcher started" | Add-Content $Log
while (-not (Test-Path $StopFile)) {
  $pids = @(Get-Process VISIO -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
  if ($pids.Count) {
    foreach ($w in [KW]::Visible($pids)) {
      $h, $p, $class, $title = $w
      if ($class -eq 'MSO_BORDEREFFECT_WINDOW_CLASS') { continue }
      if ($class -eq 'NUIDialog' -and $title -eq 'Enter your product key') {
        [void][KW]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); $closed++
        "$(Get-Date -f s) closed key prompt (pid $p) #$closed" | Add-Content $Log
      } else {
        $key = "$p|$class|$title"
        if (-not $seen.ContainsKey($key)) { $seen[$key] = 1; "$(Get-Date -f s) visible window pid $p class '$class' title '$title'" | Add-Content $Log }
      }
    }
  }
  Start-Sleep -Milliseconds 700
}
"$(Get-Date -f s) watcher stopped; prompts closed: $closed" | Add-Content $Log
