[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FixtureDirectory,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$FixtureName,
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'

function Get-ErrorDetails {
    param([System.Exception]$Exception)

    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Exception.HResult), 0)
    [ordered]@{
        type    = $Exception.GetType().FullName
        message = $Exception.Message
        hresult = ('0x{0:X8}' -f $unsigned)
    }
}

function Normalize-VisioText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "\r\n?", "`n")
}

function Add-ShapeSnapshot {
    param(
        [object]$Shape,
        [AllowNull()][string]$ParentId,
        [hashtable]$ExpectedById,
        [System.Collections.Generic.List[object]]$Output
    )

    $shapeId = ([string]$Shape.ID).Trim()
    $cellValues = [ordered]@{}
    $expectedShape = $ExpectedById[$shapeId]
    if ($null -ne $expectedShape) {
        foreach ($cellName in $expectedShape.cells.PSObject.Properties.Name) {
            if ($Shape.CellExistsU([string]$cellName, 0)) {
                $cellValues[[string]$cellName] = [double]$Shape.CellsU([string]$cellName).ResultIU
            } else {
                $cellValues[[string]$cellName] = $null
            }
        }
    }

    $formulas = [ordered]@{}
    $data = [ordered]@{}
    if ($null -ne $expectedShape) {
        foreach ($name in $expectedShape.formulas.PSObject.Properties.Name) {
            $formulas[$name] = if ($Shape.CellExistsU([string]$name, 0)) { [string]$Shape.CellsU([string]$name).FormulaU } else { $null }
        }
        foreach ($name in $expectedShape.data.PSObject.Properties.Name) {
            if ([string]$name -notmatch '^Prop\.') { throw "Shape Data snapshots require a Prop. cell: $name" }
            $data[$name] = if ($Shape.CellExistsU([string]$name, 0)) { [string]$Shape.CellsU([string]$name).ResultStrU(0) } else { $null }
        }
    }
    $masterId = $null
    if ($null -ne $expectedShape -and $null -ne $expectedShape.PSObject.Properties['masterID']) {
        $master = $Shape.Master
        if ($null -ne $master) { $masterId = ([string]$master.ID).Trim() }
    }

    $Output.Add([ordered]@{
        id       = $shapeId
        parentID = $ParentId
        text     = (Normalize-VisioText ([string]$Shape.Text))
        cells    = $cellValues
        formulas = $formulas
        data     = $data
        masterID = $masterId
    })

    for ($childIndex = 1; $childIndex -le $Shape.Shapes.Count; $childIndex++) {
        Add-ShapeSnapshot -Shape $Shape.Shapes.Item($childIndex) -ParentId $shapeId -ExpectedById $ExpectedById -Output $Output
    }
}

function Get-DocumentSnapshot {
    param([object]$Document, [object]$ExpectedPages)

    $pages = New-Object 'System.Collections.Generic.List[object]'
    for ($pageIndex = 1; $pageIndex -le $Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        $expectedPage = if ($pageIndex -le $ExpectedPages.Count) { $ExpectedPages[$pageIndex - 1] } else { $null }
        $expectedById = @{}
        if ($null -ne $expectedPage) {
            foreach ($expectedShape in $expectedPage.shapes) {
                $expectedById[[string]$expectedShape.id] = $expectedShape
            }
        }

        $shapes = New-Object 'System.Collections.Generic.List[object]'
        for ($shapeIndex = 1; $shapeIndex -le $page.Shapes.Count; $shapeIndex++) {
            Add-ShapeSnapshot -Shape $page.Shapes.Item($shapeIndex) -ParentId $null -ExpectedById $expectedById -Output $shapes
        }
        $connects = New-Object 'System.Collections.Generic.List[object]'
        if ($null -ne $expectedPage -and $null -ne $expectedPage.PSObject.Properties['connects']) {
            for ($connectionIndex = 1; $connectionIndex -le $page.Connects.Count; $connectionIndex++) {
                $connection = $page.Connects.Item($connectionIndex)
                $connects.Add([ordered]@{ fromShape = ([string]$connection.FromSheet.ID).Trim(); fromCell = [string]$connection.FromCell.Name; toShape = ([string]$connection.ToSheet.ID).Trim(); toCell = [string]$connection.ToCell.Name })
            }
        }
        $pages.Add([ordered]@{
            index      = $pageIndex
            name       = [string]$page.NameU
            background = [bool]$page.Background
            width      = [double]$page.PageSheet.CellsU('PageWidth').ResultIU
            height     = [double]$page.PageSheet.CellsU('PageHeight').ResultIU
            shapes     = $shapes.ToArray()
            connects   = $connects.ToArray()
        })
    }
    return $pages.ToArray()
}

function Get-MasterSnapshot {
    param([object]$Document)
    $masters = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 1; $index -le $Document.Masters.Count; $index++) {
        $master = $Document.Masters.Item($index)
        $masters.Add([ordered]@{ id = ([string]$master.ID).Trim(); name = [string]$master.NameU; shapeCount = [int]$master.Shapes.Count })
    }
    return $masters.ToArray()
}

function Find-TextLeaf {
    param([object]$Shape, [int]$PageIndex)

    if ($null -ne $script:MutationTarget) { return }
    $children = [int]$Shape.Shapes.Count
    $text = Normalize-VisioText ([string]$Shape.Text)
    if (($children -eq 0) -and ![string]::IsNullOrWhiteSpace($text)) {
        $script:MutationTarget = [pscustomobject]@{ Shape = $Shape; PageIndex = $PageIndex; Text = $text }
        return
    }
    for ($childIndex = 1; $childIndex -le $children; $childIndex++) {
        Find-TextLeaf -Shape $Shape.Shapes.Item($childIndex) -PageIndex $PageIndex
        if ($null -ne $script:MutationTarget) { return }
    }
}

function Set-PhaseError {
    param([System.Collections.IDictionary]$Phase, [System.Exception]$Exception)
    $Phase.status = 'failed'
    $Phase.error = Get-ErrorDetails $Exception
}

$manifest = $null
$fixture = $null
$application = $null
$document = $null
$reopened = $null
$applicationQuit = $false
$startedUtc = [DateTime]::UtcNow
$fixturePath = Join-Path ([IO.Path]::GetFullPath($FixtureDirectory)) $FixtureName
$artifactRoot = [IO.Path]::GetFullPath($ArtifactDirectory)
$null = New-Item -ItemType Directory -Force -Path $artifactRoot
$result = [ordered]@{
    file        = $FixtureName
    format      = [IO.Path]::GetExtension($FixtureName).TrimStart('.').ToLowerInvariant()
    case        = $null
    inputSha256 = $null
    status      = 'failed'
    phases      = [ordered]@{
        open      = [ordered]@{ status = 'skipped'; error = $null }
        inspect   = [ordered]@{ status = 'skipped'; pages = $null; error = $null }
        mutation  = [ordered]@{ status = 'skipped'; pageIndex = $null; shapeId = $null; property = 'text'; originalValue = $null; newValue = $null; error = $null }
        saveAs    = [ordered]@{ status = 'skipped'; path = $null; error = $null }
        close     = [ordered]@{ status = 'skipped'; error = $null }
        reopen    = [ordered]@{ status = 'skipped'; pages = $null; error = $null }
        exportPdf = [ordered]@{ status = 'skipped'; path = $null; bytes = $null; error = $null }
        exportSvg = [ordered]@{ status = 'skipped'; paths = @(); error = $null }
    }
    environment = $null
    artifacts   = [ordered]@{}
    startedUtc  = $startedUtc.ToString('o')
    endedUtc    = $null
}

try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixture = @($manifest.fixtures | Where-Object { $_.file -ceq $FixtureName }) | Select-Object -First 1
    if ($null -eq $fixture) { throw "Fixture is absent from the manifest: $FixtureName" }
    $result.case = [string]$fixture.case
    $result.inputSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($result.inputSha256 -ne ([string]$fixture.sha256).ToLowerInvariant()) {
        throw "Guest input SHA-256 does not match manifest for $FixtureName"
    }

    $application = New-Object -ComObject Visio.Application
    $application.Visible = $false
    $application.AlertResponse = 7
    $version = [string]$application.Version
    $visioPath = [string]$application.Path
    $visioExe = Join-Path $visioPath 'VISIO.EXE'
    $visioProductVersion = if (Test-Path -LiteralPath $visioExe) { [Diagnostics.FileVersionInfo]::GetVersionInfo($visioExe).ProductVersion } else { $null }
    $result.environment = [ordered]@{
        visioVersion        = $version
        visioProductVersion = $visioProductVersion
        visioExecutable     = $visioExe
        visioArchitecture   = 'x86 COM automation'
        powershellVersion   = $PSVersionTable.PSVersion.ToString()
        powershellBitness   = if ([IntPtr]::Size -eq 4) { 32 } else { 64 }
    }

    try {
        $document = $application.Documents.Open([string]$fixturePath)
        $result.phases.open.status = 'passed'
    } catch {
        Set-PhaseError $result.phases.open $_.Exception
    }

    if ($null -ne $document) {
        try {
            $result.phases.inspect.pages = Get-DocumentSnapshot -Document $document -ExpectedPages $fixture.expected.pages
            if ($null -ne $fixture.expected.PSObject.Properties['masters']) { $result.phases.inspect['masters'] = @(Get-MasterSnapshot -Document $document) }
            $result.phases.inspect.status = 'passed'
        } catch {
            Set-PhaseError $result.phases.inspect $_.Exception
        }

        if ($result.phases.inspect.status -eq 'passed') {
            $expectedShapeCount = 0
            foreach ($page in $fixture.expected.pages) { $expectedShapeCount += @($page.shapes).Count }
            if ($expectedShapeCount -eq 0) {
                $result.phases.mutation.status = 'skipped'
                $result.phases.mutation.reason = 'No shapes in authored empty-document fixture.'
            } else {
                try {
                    $script:MutationTarget = $null
                    for ($pageIndex = 1; $pageIndex -le $document.Pages.Count; $pageIndex++) {
                        $page = $document.Pages.Item($pageIndex)
                        for ($shapeIndex = 1; $shapeIndex -le $page.Shapes.Count; $shapeIndex++) {
                            Find-TextLeaf -Shape $page.Shapes.Item($shapeIndex) -PageIndex $pageIndex
                            if ($null -ne $script:MutationTarget) { break }
                        }
                        if ($null -ne $script:MutationTarget) { break }
                    }
                    if ($null -eq $script:MutationTarget) { throw 'No non-group leaf with nonempty text is available for the required edit.' }
                    $oldText = [string]$script:MutationTarget.Text
                    $newText = $oldText + ' [MacVisio differential smoke]'
                    $script:MutationTarget.Shape.Text = $newText
                    $result.phases.mutation.status = 'passed'
                    $result.phases.mutation.pageIndex = [int]$script:MutationTarget.PageIndex
                    $result.phases.mutation.shapeId = ([string]$script:MutationTarget.Shape.ID).Trim()
                    $result.phases.mutation.property = 'text'
                    $result.phases.mutation.originalValue = $oldText
                    $result.phases.mutation.newValue = $newText
                } catch {
                    Set-PhaseError $result.phases.mutation $_.Exception
                }
            }
        }

        if (($result.phases.inspect.status -eq 'passed') -and ($result.phases.mutation.status -in @('passed', 'skipped'))) {
            try {
                $savedPath = Join-Path (Join-Path $artifactRoot 'saved') $FixtureName
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $savedPath)
                $document.SaveAs([string]$savedPath)
                $result.phases.saveAs.status = 'passed'
                $result.phases.saveAs.path = $savedPath
                $result.artifacts.savedDocument = $savedPath
            } catch {
                Set-PhaseError $result.phases.saveAs $_.Exception
            }
        }

        try {
            $document.Close()
            $document = $null
            $result.phases.close.status = 'passed'
        } catch {
            Set-PhaseError $result.phases.close $_.Exception
        }
    }

    if (($result.phases.saveAs.status -eq 'passed') -and ($result.phases.close.status -eq 'passed')) {
        try {
            $reopened = $application.Documents.Open([string]$result.phases.saveAs.path)
            $result.phases.reopen.pages = Get-DocumentSnapshot -Document $reopened -ExpectedPages $fixture.expected.pages
            if ($null -ne $fixture.expected.PSObject.Properties['masters']) { $result.phases.reopen['masters'] = @(Get-MasterSnapshot -Document $reopened) }
            $result.phases.reopen.status = 'passed'
        } catch {
            Set-PhaseError $result.phases.reopen $_.Exception
        }

        if ($result.phases.reopen.status -eq 'passed') {
            try {
                $pdfPath = Join-Path (Join-Path $artifactRoot 'pdf') ([IO.Path]::GetFileNameWithoutExtension($FixtureName) + '.pdf')
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pdfPath)
                $reopened.ExportAsFixedFormat(1, [string]$pdfPath, 1, 0, 0, 0, $false, $true, $true, $true, $false, [Type]::Missing)
                $pdfInfo = Get-Item -LiteralPath $pdfPath
                if ($pdfInfo.Length -le 0) { throw 'Visio produced an empty PDF.' }
                $result.phases.exportPdf.status = 'passed'
                $result.phases.exportPdf.path = $pdfPath
                $result.phases.exportPdf.bytes = [long]$pdfInfo.Length
                $result.artifacts.pdf = $pdfPath
            } catch {
                Set-PhaseError $result.phases.exportPdf $_.Exception
            }

            try {
                $svgDirectory = Join-Path $artifactRoot 'svg'
                $null = New-Item -ItemType Directory -Force -Path $svgDirectory
                $svgPaths = New-Object 'System.Collections.Generic.List[string]'
                for ($pageIndex = 1; $pageIndex -le $reopened.Pages.Count; $pageIndex++) {
                    $svgPath = Join-Path $svgDirectory ('{0}-page-{1:D3}.svg' -f [IO.Path]::GetFileNameWithoutExtension($FixtureName), $pageIndex)
                    $reopened.Pages.Item($pageIndex).Export([string]$svgPath)
                    if (!(Test-Path -LiteralPath $svgPath) -or (Get-Item -LiteralPath $svgPath).Length -le 0) {
                        throw "Visio produced an empty or missing SVG for page $pageIndex."
                    }
                    $svgPaths.Add($svgPath)
                }
                $result.phases.exportSvg.status = 'passed'
                $result.phases.exportSvg.paths = $svgPaths.ToArray()
                $result.artifacts.svg = $svgPaths.ToArray()
            } catch {
                Set-PhaseError $result.phases.exportSvg $_.Exception
            }
        }
    }
} catch {
    if ($result.phases.open.status -eq 'skipped') {
        Set-PhaseError $result.phases.open $_.Exception
    } elseif ($result.phases.inspect.status -eq 'skipped') {
        Set-PhaseError $result.phases.inspect $_.Exception
    }
} finally {
    if ($null -ne $reopened) {
        try { $reopened.Close() } catch { if ($result.phases.close.status -eq 'passed') { Set-PhaseError $result.phases.close $_.Exception } }
    }
    if ($null -ne $document) {
        try { $document.Close() } catch { if ($result.phases.close.status -eq 'passed') { Set-PhaseError $result.phases.close $_.Exception } }
    }
    if ($null -ne $application) {
        try { $application.Quit(); $applicationQuit = $true } catch { }
    }
    $result.artifacts.applicationQuit = $applicationQuit
    $result.endedUtc = [DateTime]::UtcNow.ToString('o')
    $requiredPhases = @('open','inspect','saveAs','close','reopen','exportPdf','exportSvg')
    $allPassed = $true
    foreach ($phaseName in $requiredPhases) {
        if ($result.phases[$phaseName].status -ne 'passed') { $allPassed = $false }
    }
    if ($result.phases.mutation.status -notin @('passed','skipped')) { $allPassed = $false }
    if (($result.phases.mutation.status -eq 'skipped') -and ($null -ne $fixture)) {
        $actualExpectedShapes = 0
        foreach ($expectedPage in $fixture.expected.pages) { $actualExpectedShapes += @($expectedPage.shapes).Count }
        if ($actualExpectedShapes -ne 0) { $allPassed = $false }
    }
    if ($applicationQuit -ne $true) { $allPassed = $false }
    if ($allPassed) { $result.status = 'passed' } else { $result.status = 'failed' }
    $parentDirectory = Split-Path -Parent $ResultPath
    $null = New-Item -ItemType Directory -Force -Path $parentDirectory
    $result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if ($result.status -eq 'passed') { exit 0 } else { exit 1 }
