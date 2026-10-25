[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Drawing = 'visio-flowchart.vsdx'
)
# Visio 2019 UI reference: opens a drawing in visible Visio, then for every ribbon tab selects it, records
# the tab's groups and commands through UI Automation (name, control type, enabled, size) and saves a
# screenshot. Also records the window's other panes (Shapes, status bar, page tabs) and their bounds.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Win { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
'@
$A = [System.Windows.Automation.AutomationElement]; $T = [System.Windows.Automation.TreeScope]
$C = [System.Windows.Automation.ControlType]
function Shot($name) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $OutputDirectory "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
function Describe($element, $depth, $maxDepth) {
    $info = $element.Current
    $r = $info.BoundingRectangle
    $node = [ordered]@{ name = $info.Name; type = $info.ControlType.ProgrammaticName -replace 'ControlType\.', ''; automationId = $info.AutomationId
                        className = $info.ClassName; enabled = $info.IsEnabled; offscreen = $info.IsOffscreen
                        bounds = if ($r.IsEmpty) { $null } else { @([int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height) }; children = @() }
    if ($depth -lt $maxDepth) {
        $kids = $element.FindAll($T::Children, [System.Windows.Automation.Condition]::TrueCondition)
        $node.children = @(foreach ($k in $kids) { Describe $k ($depth + 1) $maxDepth })
    }
    $node
}
$report = [ordered]@{ tabs = @(); window = $null; errors = @() }
$app = $null
try {
    $app = New-Object -ComObject Visio.Application
    $app.Visible = $true
    $null = $app.Documents.Open([string](Join-Path $InputDirectory $Drawing))
    Start-Sleep -Seconds 4
    $hwnd = [IntPtr]$app.WindowHandle32
    [Win]::ShowWindow($hwnd, 3) | Out-Null; [Win]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Seconds 2
    $root = $A::FromHandle($hwnd)
    $report.version = [string]$app.Version
    Shot 'window-default'
    $report.window = Describe $root 0 7
    $tabCondition = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $C::TabItem)
    $tabs = @($root.FindAll($T::Descendants, $tabCondition))
    foreach ($tab in $tabs) {
        $name = $tab.Current.Name
        try {
            $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $pattern.Select(); Start-Sleep -Milliseconds 1500
        } catch { $report.errors += "select $name : $($_.Exception.Message)"; continue }
        $safe = ($name -replace '[^A-Za-z0-9]', '')
        Shot "tab-$safe"
        # The lower ribbon for the selected tab.
        $ribbon = $root.FindFirst($T::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, 'Lower Ribbon')))
        $report.tabs += [ordered]@{ name = $name; ribbon = if ($ribbon) { Describe $ribbon 0 8 } else { $null } }
    }
    # Back to Home for the default layout.
    foreach ($tab in $tabs) { if ($tab.Current.Name -eq 'Home') { $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } }
    Start-Sleep -Seconds 1
    # Backstage (File) view.
    [System.Windows.Forms.SendKeys]::SendWait('%f'); Start-Sleep -Seconds 2; Shot 'backstage'
    $report.backstage = Describe $A::FromHandle($hwnd) 0 6
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}'); Start-Sleep -Seconds 1
    # A selected shape shows the contextual state; right-click shows the shape context menu.
    $page = $app.ActivePage; $shape = $page.Shapes.Item(2)
    $app.ActiveWindow.Select($shape, 2); Start-Sleep -Seconds 1; Shot 'shape-selected'
    $report.selected = Describe $A::FromHandle($hwnd) 0 7
}
catch { $report.errors += $_.Exception.Message }
finally {
    try { foreach ($d in @($app.Documents)) { $d.Saved = $true } ; $app.Quit() } catch { }
}
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'visio-ui.json') -Encoding UTF8
exit 0
