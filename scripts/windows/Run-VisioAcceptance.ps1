[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FixtureDirectory,
    [Parameter(Mandatory = $true)][string]$WorkerPath,
    [Parameter(Mandatory = $true)][string]$ReportPath,
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [string]$InstanceName = 'unknown',
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$startedUtc = [DateTime]::UtcNow
$fixtureRoot = [IO.Path]::GetFullPath($FixtureDirectory)
$manifestPath = Join-Path $fixtureRoot 'manifest.json'
$reportFullPath = [IO.Path]::GetFullPath($ReportPath)
$artifactRoot = [IO.Path]::GetFullPath($ArtifactDirectory)
$workerFullPath = [IO.Path]::GetFullPath($WorkerPath)
$manifest = $null
$fixtures = @()
$runError = $null
$results = New-Object 'System.Collections.Generic.List[object]'
$environment = [ordered]@{
    qemuInstance       = $InstanceName
    guestHostname      = $env:COMPUTERNAME
    windowsProductName = $null
    windowsVersion     = $null
    windowsBuild       = $null
    osArchitecture     = $null
    visioVersion       = $null
    visioProductVersion = $null
    visioExecutable    = $null
    automationBitness  = 32
    timeoutSecondsPerFile = $TimeoutSeconds
}

function Get-PhaseError {
    param([System.Exception]$Exception)
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Exception.HResult), 0)
    [ordered]@{ type = $Exception.GetType().FullName; message = $Exception.Message; hresult = ('0x{0:X8}' -f $unsigned) }
}

function Write-Report {
    param([string]$Path, [object]$Value)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-EmptyResult {
    param([object]$Fixture, [string]$Status, [object]$ErrorObject, [string]$Reason)
    $phases = [ordered]@{}
    foreach ($phaseName in @('open','inspect','mutation','saveAs','close','reopen','exportPdf','exportSvg')) {
        $phases[$phaseName] = [ordered]@{ status = 'skipped'; error = $null }
    }
    if ($null -ne $ErrorObject) {
        $phases.open.status = 'failed'
        $phases.open.error = $ErrorObject
        foreach ($phaseName in @('inspect','mutation','saveAs','close','reopen','exportPdf','exportSvg')) {
            $phases[$phaseName].reason = $Reason
        }
    }
    [ordered]@{
        file        = [string]$Fixture.file
        format      = [string]$Fixture.format
        case        = [string]$Fixture.case
        inputSha256 = [string]$Fixture.sha256
        status      = $Status
        phases      = $phases
        environment = $null
        artifacts   = [ordered]@{}
        error       = $ErrorObject
    }
}

try {
    if (!(Test-Path -LiteralPath $fixtureRoot -PathType Container)) { throw "Fixture directory not found: $fixtureRoot" }
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Synthetic manifest not found: $manifestPath" }
    if (!(Test-Path -LiteralPath $workerFullPath -PathType Leaf)) { throw "Worker script not found: $workerFullPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1) { throw 'Unsupported fixture manifest schemaVersion; expected 1.' }
    if ($manifest.syntheticOnly -ne $true) { throw 'Refusing to run: manifest must set syntheticOnly=true.' }
    $fixtures = @($manifest.fixtures)
    if ($fixtures.Count -eq 0) { throw 'Manifest contains no fixtures.' }

    $seen = @{}
    foreach ($fixture in $fixtures) {
        $name = [string]$fixture.file
        if ($name -notmatch '^[A-Za-z0-9_.-]+\.vsd(x)?$') { throw "Unsafe fixture path or unsupported format: $name" }
        if ($seen.ContainsKey($name)) { throw "Duplicate manifest entry: $name" }
        $seen[$name] = $true
        if ($name -match '\.vsdx$' -and [string]$fixture.format -ne 'vsdx') { throw "Manifest format mismatch for $name" }
        if ($name -match '\.vsd$' -and [string]$fixture.format -ne 'vsd') { throw "Manifest format mismatch for $name" }
        if ($fixture.containsNativeMetadata -eq $true) { throw "Refusing native metadata fixture: $name" }
        if ($null -eq $fixture.expected.pages) { throw "Missing expected page snapshots: $name" }
        $path = Join-Path $fixtureRoot $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Listed synthetic fixture missing: $name" }
        if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked fixture: $name" }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne ([string]$fixture.sha256).ToLowerInvariant()) { throw "Host fixture SHA-256 mismatch: $name" }
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $environment.windowsProductName = [string]$os.Caption
    $environment.windowsVersion = [string]$os.Version
    $environment.windowsBuild = [string]$os.BuildNumber
    $environment.osArchitecture = [string]$os.OSArchitecture
    $x86PowerShell = Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (!(Test-Path -LiteralPath $x86PowerShell)) { throw "32-bit Windows PowerShell is unavailable: $x86PowerShell" }

    $activeVisio = @(Get-Process -Name VISIO -ErrorAction SilentlyContinue)
    if ($activeVisio.Count -gt 0) {
        throw 'A Visio process is already running. Close Visio before testing so the runner cannot attach to a user session.'
    }

    $null = New-Item -ItemType Directory -Force -Path $artifactRoot
    $resultsRoot = Join-Path $artifactRoot 'results'
    $null = New-Item -ItemType Directory -Force -Path $resultsRoot
    $abortAfterTimeout = $false
    foreach ($fixture in $fixtures) {
        $name = [string]$fixture.file
        $fixtureArtifactRoot = Join-Path (Join-Path $artifactRoot 'files') ([IO.Path]::GetFileNameWithoutExtension($name))
        $resultPath = Join-Path $resultsRoot ($name + '.json')
        $null = New-Item -ItemType Directory -Force -Path $fixtureArtifactRoot
        $safeName = $name.Replace("'", "''")
        $safeFixtureDirectory = $fixtureRoot.Replace("'", "''")
        $safeManifest = $manifestPath.Replace("'", "''")
        $safeArtifact = $fixtureArtifactRoot.Replace("'", "''")
        $safeResult = $resultPath.Replace("'", "''")
        $safeWorker = $workerFullPath.Replace("'", "''")
        $workerCommand = "& '$safeWorker' -FixtureDirectory '$safeFixtureDirectory' -ManifestPath '$safeManifest' -FixtureName '$safeName' -ArtifactDirectory '$safeArtifact' -ResultPath '$safeResult'; exit `$LASTEXITCODE"
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCommand))
        $argumentList = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encodedCommand)
        $outPath = Join-Path $fixtureArtifactRoot 'worker.stdout.txt'
        $errPath = Join-Path $fixtureArtifactRoot 'worker.stderr.txt'
        $workerProcess = $null
        try {
            $workerProcess = Start-Process -FilePath $x86PowerShell -ArgumentList $argumentList -PassThru -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (!$workerProcess.HasExited -and ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)) {
                Start-Sleep -Milliseconds 500
                $workerProcess.Refresh()
            }
            if (!$workerProcess.HasExited) {
                Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue
                $timeoutError = [ordered]@{ type = 'TimeoutException'; message = "Visio worker exceeded $TimeoutSeconds seconds for $name."; hresult = '0x800705B4' }
                $results.Add((New-EmptyResult -Fixture $fixture -Status 'failed' -ErrorObject $timeoutError -Reason 'Per-file worker timeout.'))
                $abortAfterTimeout = $true
            } elseif (Test-Path -LiteralPath $resultPath) {
                $fileResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $fileResult.environment) {
                    foreach ($key in @('visioVersion','visioProductVersion','visioExecutable')) {
                        if ([string]::IsNullOrWhiteSpace([string]$environment[$key]) -and ![string]::IsNullOrWhiteSpace([string]$fileResult.environment.$key)) {
                            $environment[$key] = [string]$fileResult.environment.$key
                        }
                    }
                }
                $results.Add($fileResult)
            } else {
                $details = [ordered]@{
                    type = 'WorkerFailure'
                    message = "Visio worker exited with code $($workerProcess.ExitCode) without producing a result report."
                    hresult = $null
                }
                $results.Add((New-EmptyResult -Fixture $fixture -Status 'failed' -ErrorObject $details -Reason 'Worker did not write its result file.'))
            }
        } catch {
            $results.Add((New-EmptyResult -Fixture $fixture -Status 'failed' -ErrorObject (Get-PhaseError $_.Exception) -Reason 'Worker process failed.'))
        }

        if ($abortAfterTimeout) {
            $remaining = $fixtures | Where-Object { [Array]::IndexOf($fixtures, $_) -gt [Array]::IndexOf($fixtures, $fixture) }
            foreach ($notRun in $remaining) {
                $notRunError = [ordered]@{ type = 'NotRun'; message = 'Not run because an earlier fixture exceeded its timeout.'; hresult = $null }
                $results.Add((New-EmptyResult -Fixture $notRun -Status 'failed' -ErrorObject $notRunError -Reason 'Not run after an earlier timeout.'))
            }
            break
        }
    }
} catch {
    $runError = Get-PhaseError $_.Exception
    if ($fixtures.Count -gt 0 -and $results.Count -eq 0) {
        foreach ($fixture in $fixtures) {
            $results.Add((New-EmptyResult -Fixture $fixture -Status 'failed' -ErrorObject $runError -Reason 'Runner validation or environment setup failed.'))
        }
    }
}

$endedUtc = [DateTime]::UtcNow
$allPassed = ($null -eq $runError) -and ($results.Count -eq $fixtures.Count)
foreach ($fileResult in $results) {
    if ($fileResult.status -ne 'passed') { $allPassed = $false }
}
$report = [ordered]@{
    schemaVersion = 1
    status        = if ($allPassed) { 'passed' } else { 'failed' }
    startedUtc    = $startedUtc.ToString('o')
    endedUtc      = $endedUtc.ToString('o')
    environment   = $environment
    errors        = if ($null -eq $runError) { @() } else { @($runError) }
    files         = $results.ToArray()
}
Write-Report -Path $reportFullPath -Value $report
if ($report.status -eq 'passed') { exit 0 } else { exit 1 }
