[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
# Quick-style reference (WP-17-T03): with a theme applied, sweeps the QuickStyle color/matrix selectors on
# a rectangle and records the colors Visio resolves for THEMEVAL() fill, line and text cells. Saves the
# drawing so the theme XML (fill/line style lists, variants) can be compared with the results.
$ErrorActionPreference = 'Stop'
$application = New-Object -ComObject Visio.InvisibleApp
$application.Visible = $false
$application.AlertResponse = 1
$records = New-Object 'System.Collections.Generic.List[object]'
$errors = @()
try {
    foreach ($theme in @('Office Theme', 'Linear', 'Integral')) {
        $document = $application.Documents.Add('')
        $page = $document.Pages.ItemU(1)
        try { $page.SetTheme($theme) } catch { $errors += "SetTheme($theme): $($_.Exception.Message)" }
        $shape = $page.DrawRectangle(1, 1, 3, 2)
        $shape.Text = 'Quick'
        $cells = @('FillForegnd', 'FillBkgnd', 'FillPattern', 'LineColor', 'LineWeight', 'LinePattern', 'Char.Color', 'ShdwForegnd', 'FillForegndTrans', 'Rounding')
        function Snap($label) {
            $values = [ordered]@{}
            foreach ($name in $cells) { try { $values[$name] = [string]$shape.CellsU($name).ResultStrU(0) } catch { $values[$name] = 'ERR' } }
            $selectors = [ordered]@{}
            foreach ($name in @('QuickStyleFillColor', 'QuickStyleFillMatrix', 'QuickStyleLineColor', 'QuickStyleLineMatrix', 'QuickStyleFontColor', 'QuickStyleFontMatrix', 'QuickStyleVariation', 'QuickStyleType', 'ColorSchemeIndex', 'VariationColorIndex')) {
                try { $selectors[$name] = [string]$shape.CellsU($name).ResultStrU(0) } catch { }
            }
            $records.Add([ordered]@{ theme = $theme; case = $label; selectors = $selectors; values = $values })
        }
        Snap 'default'
        foreach ($color in @(100, 0, 1, 2, 3, 4, 5, 6, 7, 8, 200)) {
            foreach ($matrix in @(100, 0, 1, 2, 3, 4, 5, 6)) {
                $shape.CellsU('QuickStyleFillColor').FormulaForceU = [string]$color
                $shape.CellsU('QuickStyleFillMatrix').FormulaForceU = [string]$matrix
                $shape.CellsU('QuickStyleLineColor').FormulaForceU = [string]$color
                $shape.CellsU('QuickStyleLineMatrix').FormulaForceU = [string]$matrix
                $shape.CellsU('QuickStyleFontColor').FormulaForceU = [string]$color
                $shape.CellsU('QuickStyleFontMatrix').FormulaForceU = [string]$matrix
                Snap "color=$color matrix=$matrix"
            }
        }
        foreach ($variation in @(0, 1, 2, 3)) {
            $shape.CellsU('QuickStyleFillColor').FormulaForceU = '100'; $shape.CellsU('QuickStyleFillMatrix').FormulaForceU = '100'
            $shape.CellsU('QuickStyleVariation').FormulaForceU = [string]$variation
            Snap "variation=$variation"
        }
        $document.SaveAsEx((Join-Path $OutputDirectory ("quickstyles-" + ($theme -replace ' ', '') + ".vsdx")), 2 + 4)
        $document.Saved = $true; $document.Close()
    }
}
catch { $errors += $_.Exception.Message }
finally { try { $application.Quit() } catch { } }
[ordered]@{ records = $records.ToArray(); errors = $errors } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'quickstyles.json') -Encoding UTF8
exit 0
