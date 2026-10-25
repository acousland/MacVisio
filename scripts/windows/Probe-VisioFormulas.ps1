[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$Cases
)
# Builds the probe page described by the case file in a fresh invisible Visio, saves it as
# context.vsdx (so MacVisio evaluates against the identical drawing), then evaluates every case
# formula in a User cell on its host shape and records Visio's typed result.

$ErrorActionPreference = 'Stop'

function Get-ErrorRecord([System.Exception]$Exception) {
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Exception.HResult), 0)
    [ordered]@{ type = $Exception.GetType().FullName; message = $Exception.Message; hresult = ('0x{0:X8}' -f $unsigned) }
}

$spec = Get-Content -LiteralPath $Cases -Raw -Encoding UTF8 | ConvertFrom-Json
$records = New-Object 'System.Collections.Generic.List[object]'
$fieldRecords = New-Object 'System.Collections.Generic.List[object]'
$application = $null; $document = $null; $fatal = $null; $version = $null
try {
    $application = New-Object -ComObject Visio.InvisibleApp
    $application.Visible = $false
    $application.AlertResponse = 1
    $version = [string]$application.Version
    $document = $application.Documents.Add('')
    foreach ($property in @($spec.document.PSObject.Properties)) { if ($property) { $document.($property.Name) = [string]$property.Value } }
    $page = $document.Pages.ItemU(1)
    $page.NameU = [string]$spec.page.name
    $page.Name = [string]$spec.page.name
    $page.PageSheet.CellsU('PageWidth').FormulaU = [string]$spec.page.width
    $page.PageSheet.CellsU('PageHeight').FormulaU = [string]$spec.page.height
    foreach ($extra in @($spec.page.extraPages)) { if ($extra) { $added = $document.Pages.Add(); $added.NameU = [string]$extra; $added.Name = [string]$extra } }
    $shapes = @{}
    foreach ($item in $spec.shapes) {
        $r = $item.rect
        $shape = $page.DrawRectangle([double]$r[0], [double]$r[1], [double]$r[2], [double]$r[3])
        $shapes[[string]$item.key] = $shape
        if ($item.text) { $shape.Text = [string]$item.text }
        foreach ($property in @($item.cells.PSObject.Properties)) {
            $name = [string]$property.Name
            $parts = $name.Split('.')
            if ($parts.Count -eq 2 -and $parts[0] -in @('User', 'Prop')) {
                $section = if ($parts[0] -eq 'User') { 242 } else { 243 }
                if (-not $shape.SectionExists($section, 0)) { $null = $shape.AddSection($section) }
                if (-not $shape.CellExistsU($name, 0)) { $null = $shape.AddNamedRow($section, $parts[1], 0) }
            }
            $shape.CellsU($name).FormulaForceU = [string]$property.Value
        }
    }
    $host_ = $shapes[[string]$spec.host]
    $null = $host_.AddNamedRow(242, 'Probe', 0)
    $document.SaveAsEx((Join-Path $OutputDirectory 'context.vsdx'), 2 + 4)
    $cell = $host_.CellsU('User.Probe')
    foreach ($case in $spec.cases) {
        $record = [ordered]@{ id = [string]$case.id; formula = [string]$case.formula; accepted = $false; error = $null; cellError = $null
                              resultIU = $null; resultStr = $null; resultNoCast = $null; units = $null; stage = $null }
        try { $cell.FormulaForceU = [string]$case.formula; $record.accepted = $true }
        catch { $record.stage = 'FormulaForceU'; $record.error = Get-ErrorRecord $_.Exception; $records.Add([pscustomobject]$record); continue }
        try { $record.cellError = [int]$cell.Error } catch { }
        try { $record.units = [int]$cell.Units } catch { }
        try { $record.resultIU = [double]$cell.ResultIU } catch { $record.stage = 'ResultIU' }
        try { $record.resultStr = [string]$cell.ResultStrU(0) } catch { }
        try { $record.resultNoCast = [string]$cell.ResultStrU(252) } catch { }
        $records.Add([pscustomobject]$record)
    }
    # Text fields: insert one field into an otherwise empty shape, set its Format cell, read the display.
    $fieldShape = $page.DrawRectangle(6, 1, 8, 2)
    foreach ($field in @($spec.fields)) {
        if ($null -eq $field) { continue }
        $record = [ordered]@{ id = [string]$field.id; formula = [string]$field.formula; format = [string]$field.format; text = $null; error = $null }
        try {
            $fieldShape.Text = ''
            $null = $fieldShape.Characters.AddCustomFieldU([string]$field.formula, 0)
            $fieldShape.CellsU('Fields.Format').FormulaForceU = [string]$field.format
            $record.text = [string]$fieldShape.Characters.Text
        } catch { $record.error = Get-ErrorRecord $_.Exception }
        $fieldRecords.Add([pscustomobject]$record)
    }
}
catch { $fatal = Get-ErrorRecord $_.Exception }
finally {
    if ($null -ne $document) { try { $document.Saved = $true; $document.Close() } catch { } }
    if ($null -ne $application) { try { $application.Quit() } catch { } }
}
$report = [ordered]@{ visioVersion = $version; host = [string]$spec.host; cases = $records.ToArray(); fields = $fieldRecords.ToArray(); fatalError = $fatal }
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'visio-results.json') -Encoding UTF8
if ($null -ne $fatal) { exit 1 }
exit 0
