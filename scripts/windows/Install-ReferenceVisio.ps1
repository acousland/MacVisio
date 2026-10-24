# Installs the supplied Visio Professional 2019 media as the M0 reference (WP-01-T02).
# Run in the guest's interactive desktop session from an elevated Windows PowerShell,
# not over Lima SSH: Click-to-Run setup needs a desktop session and silently exits or
# returns 1603 from the non-interactive SSH session used by earlier attempts.
#
#   -Mode Preflight  read-only: mounts the ISO, reads its payload version and channel,
#                    writes configuration.xml and prints the plan. Installs nothing.
#   -Mode Install    runs the same checks, then installs with logging enabled.
#
# On ARM64 the install runs the media's own Office\Setup32.exe instead of ODT /configure:
# current ODT ignores OfficeClientEdition="32" on ARM (its log reports platformToInstall=x64,
# isArm=1) and then blocks x64 Office older than version 2105. Setup32.exe installed this
# 16.0.10730 build cleanly on Windows 11 ARM64 on 2026-10-24.
#
# No product key is supplied or queried and no activation setting is changed.
param(
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [Parameter(Mandatory = $true)][string]$OdtSetup,
    [ValidateSet('Preflight', 'Install')][string]$Mode = 'Preflight',
    [ValidateSet('32', '64')][string]$Edition = '32',
    [string]$WorkRoot = 'C:\MacVisioReferenceSetup'
)
$ErrorActionPreference = 'Stop'

# FFN roots published by Microsoft for Click-to-Run channels. An unknown root stops
# the run rather than guessing a channel, which caused the earlier mismatched attempt.
$channels = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current'
    'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'PerpetualVL2019'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'MonthlyEnterprise'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'SemiAnnual'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'SemiAnnualPreview'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'CurrentPreview'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'BetaChannel'
}

function Write-Step($Text) { Write-Host ('==> ' + $Text) }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from an elevated (Administrator) Windows PowerShell.' }
if ([Environment]::UserInteractive -eq $false -or $env:SSH_CONNECTION) { throw 'Run from the guest desktop session, not over SSH.' }
if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw "ISO not found: $IsoPath" }
if (-not (Test-Path -LiteralPath $OdtSetup -PathType Leaf)) { throw "ODT setup.exe not found: $OdtSetup" }
$odtSignature = Get-AuthenticodeSignature -LiteralPath $OdtSetup
if ($odtSignature.Status -ne 'Valid' -or $odtSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "ODT setup.exe signature is not a valid Microsoft signature: $($odtSignature.Status)" }

$c2r = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
if ($null -ne $c2r) { Write-Warning ("Existing Click-to-Run configuration: " + $c2r.ProductReleaseIds + ' ' + $c2r.Platform + ' ' + $c2r.VersionToReport + '. Mixed bitness or channels make ODT fail; review before installing.') }

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
$logs = Join-Path $WorkRoot 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

Write-Step "Mounting $IsoPath"
$image = Get-DiskImage -ImagePath $IsoPath
if (-not $image.Attached) { $image = Mount-DiskImage -ImagePath $IsoPath -PassThru }
$letter = ($image | Get-Volume).DriveLetter
if (-not $letter) { throw 'The mounted ISO has no drive letter.' }
$source = $letter + ':\'
$data = Join-Path $source 'Office\Data'
if (-not (Test-Path -LiteralPath $data)) { throw "No Office\Data payload on $source" }

$versions = @(Get-ChildItem -LiteralPath $data -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } | ForEach-Object Name)
if ($versions.Count -ne 1) { throw ('Expected one payload version under Office\Data, found: ' + ($versions -join ', ')) }
$version = $versions[0]
$bits = if ($Edition -eq '64') { '64' } else { '32' }
$cab = Join-Path $data ("v${bits}_$version.cab")
if (-not (Test-Path -LiteralPath $cab)) { $cab = Join-Path $data "v$bits.cab" }
if (-not (Test-Path -LiteralPath $cab)) { throw "The media has no $bits-bit payload descriptor (v$bits.cab)." }

$descriptorDir = Join-Path $WorkRoot 'descriptor'
New-Item -ItemType Directory -Force -Path $descriptorDir | Out-Null
& expand.exe ('-F:VersionDescriptor.xml') $cab $descriptorDir | Out-Null
$descriptorPath = Join-Path $descriptorDir 'VersionDescriptor.xml'
if (-not (Test-Path -LiteralPath $descriptorPath)) { throw "VersionDescriptor.xml was not found in $cab" }
[xml]$descriptor = Get-Content -LiteralPath $descriptorPath -Raw
$ffn = $descriptor.SelectSingleNode('//DeliveryMechanism').GetAttribute('FFNRoot').ToLowerInvariant()
$channel = $channels[$ffn]
if (-not $channel) { throw "Unknown channel FFN root $ffn; record it in WINDOWS-VALIDATION.md before choosing a channel." }

$streams = @(Get-ChildItem -LiteralPath (Join-Path $data $version) -Filter 'stream.*.dat' | ForEach-Object Name)
$languages = @($streams | ForEach-Object { if ($_ -match '^stream\.x(86|64)\.([a-z]{2}-[a-z]{2})\.dat$') { $Matches[2] } } | Sort-Object -Unique)
$archStream = if ($bits -eq '64') { 'stream.x64.x-none.dat' } else { 'stream.x86.x-none.dat' }
if ($streams -notcontains $archStream) { throw "The media lacks $archStream for the $bits-bit edition." }
$language = if ($languages -contains 'en-us') { 'en-us' } elseif ($languages.Count -gt 0) { $languages[0] } else { throw 'The media has no language stream.' }

# Retail media installs the Retail product ID; a Volume ID would also need a VL channel and key.
$product = 'VisioPro2019Retail'
$configPath = Join-Path $WorkRoot 'configuration.xml'
$config = @"
<Configuration>
  <Add SourcePath="$source" Version="$version" OfficeClientEdition="$bits" Channel="$channel" AllowCdnFallback="FALSE">
    <Product ID="$product">
      <Language ID="$language" />
    </Product>
  </Add>
  <Updates Enabled="FALSE" />
  <Display Level="Full" AcceptEULA="FALSE" />
  <Logging Level="Standard" Path="$logs" />
</Configuration>
"@
Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8

$plan = [ordered]@{
    mode = $Mode; iso = $IsoPath; source = $source; version = $version; channel = $channel; ffnRoot = $ffn
    edition = $bits; product = $product; language = $language; languages = $languages
    os = (Get-CimInstance Win32_OperatingSystem).Caption; osArchitecture = $env:PROCESSOR_ARCHITECTURE
    odt = $OdtSetup; odtVersion = (Get-Item -LiteralPath $OdtSetup).VersionInfo.FileVersion
    configuration = $configPath; logs = $logs
}
$plan | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkRoot 'plan.json') -Encoding UTF8
$plan | Format-List | Out-String | Write-Host
Write-Host $config

if ($Mode -eq 'Preflight') { Write-Step "Preflight complete. Nothing was installed. Rerun with -Mode Install."; return }

$started = Get-Date
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    if ($bits -ne '32') { throw 'This Visio build can only be installed as 32-bit on ARM64.' }
    $mediaSetup = Join-Path $source 'Office\Setup32.exe'
    $mediaSignature = Get-AuthenticodeSignature -LiteralPath $mediaSetup
    if ($mediaSignature.Status -ne 'Valid' -or $mediaSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "Setup32.exe signature is not a valid Microsoft signature: $($mediaSignature.Status)" }
    Write-Step "Running the media's Office\Setup32.exe (ARM64; setup windows will appear)"
    $process = Start-Process -FilePath $mediaSetup -WorkingDirectory (Split-Path -Parent $mediaSetup) -PassThru -Wait
} else {
    Write-Step 'Running Office Deployment Tool /configure (setup windows will appear)'
    $process = Start-Process -FilePath $OdtSetup -ArgumentList @('/configure', "`"$configPath`"") -WorkingDirectory (Split-Path -Parent $OdtSetup) -PassThru -Wait
}
$exit = $process.ExitCode
$elapsed = [int]((Get-Date) - $started).TotalSeconds

# ODT and Click-to-Run also log to the temp folders; gather anything written during this run.
foreach ($folder in @($env:TEMP, (Join-Path $env:windir 'Temp'))) {
    Get-ChildItem -LiteralPath $folder -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started } |
        Copy-Item -Destination $logs -ErrorAction SilentlyContinue
}

$clsid = (Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\Visio.Application\CLSID' -ErrorAction SilentlyContinue).'(default)'
$exe = @("$env:ProgramFiles\Microsoft Office\root\Office16\VISIO.EXE", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\VISIO.EXE") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$result = [ordered]@{
    exitCode = $exit; seconds = $elapsed; visioExecutable = $exe
    visioVersion = if ($exe) { (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } else { $null }
    visioExecutableSha256 = if ($exe) { (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash } else { $null }
    comClsid = $clsid; logs = @(Get-ChildItem -LiteralPath $logs -File | ForEach-Object Name)
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkRoot 'install-result.json') -Encoding UTF8
$result | Format-List | Out-String | Write-Host
if ($exit -ne 0 -or -not $exe -or -not $clsid) { Write-Warning "Visio is not installed and registered. Send $WorkRoot\install-result.json and the logs folder for diagnosis."; exit 1 }
Write-Step 'Visio installed. Launch it once from Start, accept the licence and activate with your own entitlement before running the acceptance harness.'
