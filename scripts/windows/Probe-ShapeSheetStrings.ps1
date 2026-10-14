[CmdletBinding()]
param(
    [string]$FixturePath = (Join-Path $PSScriptRoot '..\..\Tests\MacVisioTests\Fixtures\visio-string-functions-boundaries.json'),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function ConvertTo-ErrorRecord {
    param([System.Exception]$Exception)

    $unsignedHResult = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Exception.HResult), 0)
    return [ordered]@{
        type    = $Exception.GetType().FullName
        message = $Exception.Message
        hresult = ('0x{0:X8}' -f $unsignedHResult)
    }
}

function ConvertFrom-BStr {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $units = New-Object 'System.Collections.Generic.List[int]'
    $hexUnits = New-Object 'System.Collections.Generic.List[string]'
    $escapedUnits = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $codeUnit = [int]$Value[$index]
        $units.Add($codeUnit)
        $hexUnits.Add($codeUnit.ToString('X4', [Globalization.CultureInfo]::InvariantCulture))
        $escapedUnits.Add(('\u{0:X4}' -f $codeUnit))
    }

    $wellFormed = $true
    for ($index = 0; $index -lt $Value.Length; ) {
        $codeUnit = [int]$Value[$index]
        if ($codeUnit -ge 0xD800 -and $codeUnit -le 0xDBFF) {
            if ($index + 1 -ge $Value.Length) {
                $wellFormed = $false
                break
            }
            $next = [int]$Value[$index + 1]
            if ($next -lt 0xDC00 -or $next -gt 0xDFFF) {
                $wellFormed = $false
                break
            }
            $index += 2
            continue
        }
        if ($codeUnit -ge 0xDC00 -and $codeUnit -le 0xDFFF) {
            $wellFormed = $false
            break
        }
        $index++
    }

    return [ordered]@{
        text                 = if ($wellFormed) { $Value } else { $null }
        utf16Length          = $Value.Length
        utf16CodeUnits       = $units.ToArray()
        utf16Hex             = [string]::Join(' ', $hexUnits.ToArray())
        utf16Escaped         = [string]::Join('', $escapedUnits.ToArray())
        wellFormedUnicode    = $wellFormed
    }
}

$fixtureFullPath = [IO.Path]::GetFullPath($FixturePath)
$fixture = Get-Content -LiteralPath $fixtureFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $fixture.cases -or $fixture.cases.Count -eq 0) {
    throw "The fixture contains no formula cases: $fixtureFullPath"
}

$application = $null
$visioVersion = $null
$document = $null
$page = $null
$shape = $null
$cell = $null
$records = New-Object 'System.Collections.Generic.List[object]'
$fatalError = $null

try {
    # Start a dedicated invisible instance; never attach to or alter a user's Visio session.
    $application = New-Object -ComObject Visio.InvisibleApp
    $application.Visible = $false
    $visioVersion = [string]$application.Version
    $document = $application.Documents.Add('')
    $page = $document.Pages.ItemU(1)
    $shape = $page.DrawRectangle(1, 5, 5, 1)

    # VisSectionUser is 242 and visTagDefault is 0 in the Visio type library.
    $userSection = 242
    if (-not $shape.SectionExists($userSection, 1)) {
        $null = $shape.AddSection($userSection)
    }
    $null = $shape.AddNamedRow($userSection, 'Probe', 0)
    $cell = $shape.CellsU('User.Probe')

    foreach ($case in $fixture.cases) {
        $record = [ordered]@{
            formula        = [string]$case.formula
            expected        = [string]$case.expected
            purpose         = [string]$case.purpose
            formulaU        = $null
            cellError       = $null
            cellErrorName   = $null
            result          = $null
            status          = $null
            errorStage      = $null
            error           = $null
        }

        try {
            # ShapeSheet formula strings use a leading equals sign.
            $cell.FormulaU = '=' + [string]$case.formula
            $record.formulaU = [string]$cell.FormulaU
        }
        catch {
            $record.status = 'FormulaError'
            $record.errorStage = 'FormulaU'
            $record.error = ConvertTo-ErrorRecord $_.Exception
            $records.Add([pscustomobject]$record)
            continue
        }

        try {
            $cellError = [int]$cell.Error
            $record.cellError = $cellError
            $record.cellErrorName = switch ($cellError) {
                0  { 'visErrorSuccess' }
                39 { 'visErrorDivideByZero' }
                47 { 'visErrorValue' }
                55 { 'visErrorReference' }
                61 { 'visErrorName' }
                68 { 'visErrorNumber' }
                74 { 'visErrorNotAvailable' }
                default { 'Unknown' }
            }
        }
        catch {
            $record.errorStage = 'Cell.Error'
            $record.error = ConvertTo-ErrorRecord $_.Exception
        }

        try {
            # ResultStrU(0) retrieves the evaluated string; .NET preserves its UTF-16 units.
            $rawResult = [string]$cell.ResultStrU(0)
            $record.result = ConvertFrom-BStr $rawResult
        }
        catch {
            if ($null -eq $record.error) {
                $record.errorStage = 'ResultStrU'
                $record.error = ConvertTo-ErrorRecord $_.Exception
            }
        }

        if ($null -ne $record.error) {
            $record.status = 'ReadError'
        }
        elseif ($record.cellError -ne 0) {
            $record.status = 'CellError'
        }
        else {
            $record.status = 'Success'
        }
        $records.Add([pscustomobject]$record)
    }
}
catch {
    $fatalError = ConvertTo-ErrorRecord $_.Exception
}
finally {
    if ($null -ne $document) {
        try { $document.Saved = $true } catch { }
        try { $document.Close() } catch { }
    }
    if ($null -ne $application) {
        try { $application.Quit() } catch { }
    }
}

$report = [ordered]@{
    source       = $fixtureFullPath
    visioVersion = $visioVersion
    caseCount    = $records.Count
    cases        = $records.ToArray()
    fatalError   = $fatalError
}
$json = $report | ConvertTo-Json -Depth 8
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    [Console]::Out.WriteLine($json)
}
else {
    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($outputFullPath, $json, $encoding)
    [Console]::Out.WriteLine($outputFullPath)
}

if ($null -ne $fatalError) {
    exit 1
}
