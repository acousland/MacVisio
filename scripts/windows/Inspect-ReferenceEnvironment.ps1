# Read-only inventory: no COM activation, installer, process termination, or product-key collection.
$ErrorActionPreference = 'Stop'
$errors = New-Object 'System.Collections.Generic.List[object]'
function Read-Values($Root, $Path, $Names) {
    $key = $Root.OpenSubKey($Path, $false)
    if ($null -eq $key) { return $null }
    try {
        $values = [ordered]@{}
        foreach ($name in $Names) { $values[$name] = $key.GetValue($name, $null) }
        return $values
    } finally { $key.Dispose() }
}
$views = New-Object 'System.Collections.Generic.List[object]'
foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
    $machine = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    $classes = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::ClassesRoot, $view)
    try {
        $com = Read-Values $classes 'Visio.Application\CLSID' @('')
        $server = $null
        if ($null -ne $com -and $null -ne $com['']) { $server = Read-Values $classes ('CLSID\' + $com[''] + '\LocalServer32') @('') }
        $uninstalls = New-Object 'System.Collections.Generic.List[object]'
        $key = $machine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', $false)
        if ($null -ne $key) {
            try {
                foreach ($name in $key.GetSubKeyNames()) {
                    $item = Read-Values $key $name @('DisplayName','DisplayVersion','Publisher')
                    if ($null -ne $item -and [string]$item.DisplayName -match 'Visio|Office|Access Database Engine') { $uninstalls.Add($item) }
                }
            } finally { $key.Dispose() }
        }
        $drivers = New-Object 'System.Collections.Generic.List[object]'
        $driverKey = $machine.OpenSubKey('SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers', $false)
        if ($null -ne $driverKey) {
            try {
                foreach ($name in $driverKey.GetValueNames()) {
                    $detail = Read-Values $machine ('SOFTWARE\ODBC\ODBCINST.INI\' + $name) @('Driver','DriverODBCVer')
                    $version = $null
                    if ($null -ne $detail -and (Test-Path -LiteralPath ([string]$detail.Driver))) { $version = [Diagnostics.FileVersionInfo]::GetVersionInfo([string]$detail.Driver).FileVersion }
                    $drivers.Add([ordered]@{ name = $name; registration = $driverKey.GetValue($name); fileVersion = $version })
                }
            } finally { $driverKey.Dispose() }
        }
        $views.Add([ordered]@{
            registryView = $view.ToString()
            visioClsid = if ($null -ne $com) { $com[''] } else { $null }
            visioServer = if ($null -ne $server) { $server[''] } else { $null }
            clickToRun = Read-Values $machine 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration' @('VersionToReport','Platform','ProductReleaseIds','UpdateChannel')
            officeUninstalls = $uninstalls.ToArray()
            odbcDrivers = $drivers.ToArray()
        })
    } catch { $errors.Add([ordered]@{ phase = $view.ToString(); type = $_.Exception.GetType().FullName; message = $_.Exception.Message }) }
    finally { $machine.Dispose(); $classes.Dispose() }
}
$os = Get-CimInstance Win32_OperatingSystem
$executables = New-Object 'System.Collections.Generic.List[object]'
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Select-Object -Unique) {
    if ([string]::IsNullOrWhiteSpace($base)) { continue }
    foreach ($relative in @('Microsoft Office\root\Office16\VISIO.EXE','Microsoft Office\Office16\VISIO.EXE')) {
        $path = Join-Path $base $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $file = Get-Item -LiteralPath $path
            $executables.Add([ordered]@{ path = $path; productVersion = $file.VersionInfo.ProductVersion; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() })
        }
    }
}
$processes = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^(VISIO|setup|OfficeClickToRun|OfficeC2RClient)$' } | ForEach-Object { [ordered]@{ name = $_.ProcessName; id = $_.Id } })
$services = @(Get-Service -Name ClickToRunSvc -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; status = $_.Status.ToString() } })
$fonts = @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'Fonts') -File | ForEach-Object { [ordered]@{ file = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
[ordered]@{
    schemaVersion = 1
    collectedUtc = [DateTime]::UtcNow.ToString('o')
    probe = 'read-only registry, file and process inventory; COM not activated'
    os = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture }
    culture = [Globalization.CultureInfo]::CurrentCulture.Name
    uiCulture = [Globalization.CultureInfo]::CurrentUICulture.Name
    powerShell = [ordered]@{ version = $PSVersionTable.PSVersion.ToString(); bitness = [IntPtr]::Size * 8; x86Available = (Test-Path -LiteralPath (Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe')) }
    registryViews = $views.ToArray()
    visioExecutables = $executables.ToArray()
    relevantProcesses = $processes
    clickToRunServices = $services
    fonts = $fonts
    licenseVerification = 'unverified; no activation or product-key query performed'
    errors = $errors.ToArray()
} | ConvertTo-Json -Depth 12 -Compress
