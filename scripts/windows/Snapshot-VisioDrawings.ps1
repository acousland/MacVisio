[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Build = '',
    [string]$Recipes = ''
)
# Round-trip reference (M3, G2). In build mode, runs each recipe in Recipes (a PowerShell file defining
# Build-<Name> functions) to author a drawing with Visio's own UI-level automation and saves it to
# OutputDirectory\visio-<name>.vsdx. Then every .vsdx in InputDirectory and OutputDirectory is opened
# and described: pages, layers, shapes (recursively), key cell results and formulas, text, field
# displays, User/Prop rows, connection points, geometry rows, container membership, connects, masters
# and styles. The snapshot is what Visio itself understands, so comparing two snapshots shows what a
# round trip through MacVisio changed.

$ErrorActionPreference = 'Stop'
$cellNames = @('PinX','PinY','Width','Height','LocPinX','LocPinY','Angle','FlipX','FlipY','BeginX','BeginY','EndX','EndY',
    'LineWeight','LineColor','LinePattern','LineCap','Rounding','BeginArrow','EndArrow','BeginArrowSize','EndArrowSize','FillForegnd','FillBkgnd','FillPattern',
    'FillForegndTrans','ShdwPattern','TxtPinX','TxtPinY','TxtWidth','TxtHeight','TxtAngle','LeftMargin','RightMargin','TopMargin','BottomMargin','VerticalAlign',
    'Char.Size','Char.Font','Char.Color','Char.Style','Para.HorzAlign','Para.SpLine','LayerMember','ObjType','ShapeRouteStyle','ConLineRouteExt','ConLineJumpStyle',
    'GlueType','WalkPreference','LockWidth','LockHeight','LockMoveX','LockMoveY','LockRotate','LockDelete','LockTextEdit','NoObjHandles','HideText',
    'ColorSchemeIndex','EffectSchemeIndex','ConnectorSchemeIndex','FontSchemeIndex','ThemeIndex','QuickStyleLineColor','QuickStyleFillColor','QuickStyleType',
    'QuickStyleVariation','Relationships','DisplayLevel','ContainerMemberCount')
$pageCells = @('PageWidth','PageHeight','DrawingScale','PageScale','DrawingSizeType','DrawingScaleType','PageLeftMargin','PageTopMargin','PrintPageOrientation',
    'PaperKind','CenterX','CenterY','ColorSchemeIndex','EffectSchemeIndex','ThemeIndex','RouteStyle','LineJumpStyle','PageLockReplace')

function Get-ErrorRecord([System.Exception]$Exception) {
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Exception.HResult), 0)
    [ordered]@{ type = $Exception.GetType().FullName; message = $Exception.Message; hresult = ('0x{0:X8}' -f $unsigned) }
}
function Text([AllowNull()][string]$Value) { if ($null -eq $Value) { '' } else { $Value -replace "\r\n?", "`n" } }
function CellRecord($Cell) {
    $record = [ordered]@{ formula = [string]$Cell.FormulaU; value = $null; text = $null; units = $null; error = $null }
    try { $record.units = [int]$Cell.Units } catch { }
    try { $record.error = [int]$Cell.Error } catch { }
    try { $record.value = [double]$Cell.ResultIU } catch { }
    try { $record.text = [string]$Cell.ResultStrU(0) } catch { }
    $record
}
function RowCells($Shape, [int]$Section, [int]$Row) {
    $cells = [ordered]@{}
    $count = [int]$Shape.RowsCellCount($Section, $Row)
    for ($cell = 0; $cell -lt $count; $cell++) {
        # Keyed by column: unnamed cells' local names embed the row index, which renumbering changes.
        try { $c = $Shape.CellsSRC($Section, $Row, $cell); $cells["c$cell"] = CellRecord $c } catch { }
    }
    $cells
}
function NamedRows($Shape, [int]$Section, [string]$Prefix) {
    $rows = [ordered]@{}
    if (-not $Shape.SectionExists($Section, 0)) { return $rows }
    for ($row = 0; $row -lt $Shape.RowCount($Section); $row++) {
        $name = [string]$Shape.CellsSRC($Section, $row, 0).RowNameU
        $rows[$name] = RowCells $Shape $Section $row
    }
    $rows
}
function Describe-Shape($Shape, $ParentId, $Output) {
    $id = ([string]$Shape.ID).Trim()
    $cells = [ordered]@{}
    foreach ($name in $cellNames) { if ($Shape.CellExistsU($name, 0)) { $cells[$name] = CellRecord $Shape.CellsU($name) } }
    $geometry = @()
    for ($g = 0; $g -lt $Shape.GeometryCount; $g++) {
        $section = 10 + $g
        $rows = @()
        for ($r = 0; $r -lt $Shape.RowCount($section); $r++) { $rows += [string]$Shape.RowType($section, $r) }
        $geometry += ,$rows
    }
    $connections = @()
    if ($Shape.SectionExists(7, 0)) {
        for ($r = 0; $r -lt $Shape.RowCount(7); $r++) {
            $connections += [ordered]@{ x = [double]$Shape.CellsSRC(7, $r, 0).ResultIU; y = [double]$Shape.CellsSRC(7, $r, 1).ResultIU; type = [int]$Shape.CellsSRC(7, $r, 5).ResultIU }
        }
    }
    $fields = @()
    # Text field formulas (Text Fields section, index 8).
    if ($Shape.SectionExists(8, 0)) { for ($r = 0; $r -lt $Shape.RowCount(8); $r++) { $fields += [string]$Shape.CellsSRC(8, $r, 0).FormulaU } }
    $containers = @()
    try { foreach ($c in @($Shape.MemberOfContainers)) { if ($c) { $containers += [int]$c } } } catch { }
    $members = @()
    try { if ($Shape.ContainerProperties) { foreach ($m in @($Shape.ContainerProperties.GetMemberShapes(0))) { if ($m) { $members += [int]$m } } } } catch { }
    $masterName = $null
    try { if ($Shape.Master) { $masterName = [string]$Shape.Master.NameU } } catch { }
    $Output.Add([ordered]@{
        id = $id; parent = $ParentId; nameU = [string]$Shape.NameU; type = [int]$Shape.Type; oneD = [bool]$Shape.OneD; master = $masterName
        text = Text ([string]$Shape.Characters.Text); styles = @([string]$Shape.LineStyle, [string]$Shape.FillStyle, [string]$Shape.TextStyle)
        cells = $cells; user = NamedRows $Shape 242 'User'; data = NamedRows $Shape 243 'Prop'; controls = NamedRows $Shape 9 'Controls'
        geometry = $geometry; connections = $connections; fieldFormulas = $fields; containers = $containers; members = $members
        hyperlinks = [int]$Shape.Hyperlinks.Count; layers = [int]$Shape.LayerCount
    })
    for ($i = 1; $i -le $Shape.Shapes.Count; $i++) { Describe-Shape $Shape.Shapes.Item($i) $id $Output }
}
function Describe-Document($Document) {
    $pages = @()
    for ($p = 1; $p -le $Document.Pages.Count; $p++) {
        $page = $Document.Pages.Item($p)
        $shapes = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 1; $i -le $page.Shapes.Count; $i++) { Describe-Shape $page.Shapes.Item($i) $null $shapes }
        $connects = @()
        for ($c = 1; $c -le $page.Connects.Count; $c++) {
            $connect = $page.Connects.Item($c)
            $connects += [ordered]@{ from = ([string]$connect.FromSheet.ID).Trim(); fromCell = [string]$connect.FromCell.Name; to = ([string]$connect.ToSheet.ID).Trim(); toCell = [string]$connect.ToCell.Name }
        }
        $layers = @()
        for ($l = 1; $l -le $page.Layers.Count; $l++) {
            $layer = $page.Layers.Item($l)
            $layers += [ordered]@{ name = [string]$layer.NameU; visible = [string]$layer.CellsC(4).FormulaU; print = [string]$layer.CellsC(5).FormulaU; lock = [string]$layer.CellsC(7).FormulaU; color = [string]$layer.CellsC(2).FormulaU }
        }
        $sheet = [ordered]@{}
        foreach ($name in $pageCells) { if ($page.PageSheet.CellExistsU($name, 0)) { $sheet[$name] = CellRecord $page.PageSheet.CellsU($name) } }
        $background = $null
        try { if ($page.BackPage) { $background = [string]$page.BackPage.NameU } } catch { }
        $pages += [ordered]@{ index = $p; name = [string]$page.NameU; background = [bool]$page.Background; backPage = $background
            sheet = $sheet; user = NamedRows $page.PageSheet 242 'User'; layers = $layers; shapes = $shapes.ToArray(); connects = $connects }
    }
    $masters = @()
    for ($m = 1; $m -le $Document.Masters.Count; $m++) { $master = $Document.Masters.Item($m); $masters += [ordered]@{ name = [string]$master.NameU; shapes = [int]$master.Shapes.Count } }
    $styles = @()
    for ($s = 1; $s -le $Document.Styles.Count; $s++) { $styles += [string]$Document.Styles.Item($s).NameU }
    [ordered]@{ pages = $pages; masters = $masters; styles = $styles; user = NamedRows $Document.DocumentSheet 242 'User'
        title = [string]$Document.Title; creator = [string]$Document.Creator }
}

$application = New-Object -ComObject Visio.InvisibleApp
$application.Visible = $false
$application.AlertResponse = 1
$report = [ordered]@{ visioVersion = [string]$application.Version; built = @(); drawings = [ordered]@{}; errors = @() }
try {
    if ($Build -and $Recipes) {
        . $Recipes
        foreach ($name in $Build.Split(',')) {
            $document = $null
            try {
                $document = $application.Documents.Add('')
                & "Build-$name" $application $document
                $path = Join-Path $OutputDirectory "visio-$name.vsdx"
                $document.SaveAsEx($path, 2 + 4)
                $report.built += $name
            } catch { $report.errors += [ordered]@{ build = $name; error = Get-ErrorRecord $_.Exception } }
            finally { if ($document) { try { $document.Saved = $true; $document.Close() } catch { } } }
        }
    }
    $files = @(Get-ChildItem -LiteralPath $InputDirectory -Filter '*.vsdx') + @(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.vsdx')
    foreach ($file in $files) {
        $document = $null
        try {
            $document = $application.Documents.OpenEx([string]$file.FullName, 2 + 64)
            $report.drawings[$file.Name] = Describe-Document $document
        } catch { $report.errors += [ordered]@{ open = $file.Name; error = Get-ErrorRecord $_.Exception } }
        finally { if ($document) { try { $document.Saved = $true; $document.Close() } catch { } } }
    }
}
finally {
    try { $application.Quit() } catch { }
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'snapshots.json') -Encoding UTF8
exit 0
