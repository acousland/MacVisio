[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
# Container behaviour reference: how Visio 2019 treats a container's default resize policy and margin, and
# how a shape moved by the user (Selection.Move, as dragging does) joins, changes or leaves containers.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Mouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[Mouse]::SetProcessDPIAware() | Out-Null
$report = [ordered]@{ steps = @(); errors = @() }
$app = $null
function Members($container) { @($container.ContainerProperties.GetMemberShapes(0) | ForEach-Object { $_ }) }
function State($label) {
    $entry = [ordered]@{ label = $label }
    foreach ($name in 'outer', 'inner', 'other') {
        $c = $script:shapes[$name]
        $entry[$name] = [ordered]@{ members = @(Members $c | ForEach-Object { $script:page.Shapes.ItemFromID($_).Text })
            pinX = $c.Cells('PinX').ResultIU; pinY = $c.Cells('PinY').ResultIU; width = $c.Cells('Width').ResultIU; height = $c.Cells('Height').ResultIU }
    }
    $s = $script:shapes['box']
    $entry.box = [ordered]@{ pinX = $s.Cells('PinX').ResultIU; pinY = $s.Cells('PinY').ResultIU
        containers = @($s.MemberOfContainers | ForEach-Object { $script:page.Shapes.ItemFromID($_).Text }) }
    $script:report.steps += $entry
}
# Drawing coordinates (inches) to screen pixels, from the drawing window's client rectangle and visible view.
function Screen($x, $y) {
    # Calibrated from a screenshot at Zoom = -1 (whole page) on the 1920x1080 reference desktop.
    @([int](846.5 + 58.45 * $x), [int](930 - 58.35 * $y))
}
function Drag($shape, $dx, $dy) {
    $x = $shape.Cells('PinX').ResultIU; $y = $shape.Cells('PinY').ResultIU
    $from = Screen $x $y; $to = Screen ($x + $dx) ($y + $dy)
    [Mouse]::SetCursorPos($from[0], $from[1]); Start-Sleep -Milliseconds 150
    [Mouse]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 150
    for ($i = 1; $i -le 12; $i++) {
        [Mouse]::SetCursorPos([int]($from[0] + ($to[0] - $from[0]) * $i / 12), [int]($from[1] + ($to[1] - $from[1]) * $i / 12)); Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 300
    [Mouse]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
}
function MoveBox($dx, $dy) { Drag $script:shapes['box'] $dx $dy }
try {
    $app = New-Object -ComObject Visio.Application
    $app.Visible = $true
    $doc = $app.Documents.Add('')
    $doc.SnapEnabled = $false; $doc.GlueEnabled = $false
    $hwnd = [IntPtr]$app.WindowHandle32; [Mouse]::ShowWindow($hwnd, 3) | Out-Null; [Mouse]::SetForegroundWindow($hwnd) | Out-Null
    $script:page = $app.ActivePage
    $stencil = $app.Documents.OpenEx([string]$app.GetBuiltInStencilFile(2, 0), 64)
    $master = $stencil.Masters.Item(1)
    $report.master = $master.Name
    function Container($text, $x, $y, $w, $h) {
        $c = $script:page.Drop($master, $x, $y)
        $c.Text = $text
        $c.Cells('Width').ResultIU = $w; $c.Cells('Height').ResultIU = $h
        $c
    }
    $script:shapes = @{}
    $script:shapes.outer = Container 'Outer' 4 5 6 6
    $script:shapes.inner = Container 'Inner' 3 4 2 2
    $script:shapes.other = Container 'Other' 9 5 2 2
    $outer = $script:shapes.outer
    $report.policy = [ordered]@{ resize = $outer.ContainerProperties.ResizeBehavior; margin = $outer.ContainerProperties.GetMargin(65)
        hasResizeCell = [bool]$outer.CellExists('User.msvSDContainerResize', 0); hasMarginCell = [bool]$outer.CellExists('User.msvSDContainerMargin', 0)
        locked = $outer.ContainerProperties.LockMembership
        userCells = @(for ($i = 0; $i -lt $outer.RowCount(242); $i++) { $outer.CellsSRC(242, $i, 0).RowNameU + '=' + $outer.CellsSRC(242, $i, 0).FormulaU }) }
    $script:shapes.box = $script:page.DrawRectangle(6, 3, 6.5, 3.5)
    $script:shapes.box.Text = 'Box'
    $app.ActiveWindow.Zoom = -1; Start-Sleep -Seconds 1
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $OutputDirectory 'screen.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
    $l = 0; $t = 0; $wd = 0; $h = 0; $app.ActiveWindow.GetWindowRect([ref]$l, [ref]$t, [ref]$wd, [ref]$h)
    $vl = 0.0; $vt = 0.0; $vw = 0.0; $vh = 0.0; $app.ActiveWindow.GetViewRect([ref]$vl, [ref]$vt, [ref]$vw, [ref]$vh)
    $report.geometry = @($b.Width, $b.Height, $l, $t, $wd, $h, $vl, $vt, $vw, $vh, (Screen 6.25 3.25))
    State 'drawn inside outer (not moved)'
    MoveBox 0 0.25; State 'nudged inside outer'
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $OutputDirectory 'after-drag.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
    MoveBox -3 1; State 'moved into inner'
    MoveBox 6 0; State 'moved into other'
    MoveBox 0.6 0; State 'moved partly over the edge of other, centre inside'
    MoveBox 0.5 0; State 'moved mostly out of other, centre outside but overlapping'
    MoveBox 3 0; State 'moved fully out of other'
    MoveBox -8.35 0.5; State 'moved back into outer only'
    MoveBox 0 2.8; State 'moved across the outer top edge, centre inside'
    MoveBox 0 2; State 'moved above outer'
    # Moving a container carries its members; resizing a container keeps them.
    MoveBox 0 -6.3; State 'moved back into inner'
    # Drag the inner container by its top heading strip.
    Drag $script:shapes.inner 0.5 0; State 'inner container dragged'
    $doc.SaveAs([string](Join-Path $OutputDirectory 'containers.vsdx'))
}
catch { $report.errors += $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber }
finally {
    try { foreach ($d in @($app.Documents)) { $d.Saved = $true }; $app.Quit() } catch { }
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'containers.json') -Encoding UTF8
exit 0
