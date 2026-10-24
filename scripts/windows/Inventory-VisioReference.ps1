# Observes the installed reference Visio (WP-01-T02, WP-02-T02, WP-04-T03). Run from 32-bit Windows PowerShell
# in the signed-in desktop session (see run-visio-acceptance.py --desktop-session). Read-only towards the
# installation: it creates scratch drawings in memory, never saves them, and changes no settings.
param([Parameter(Mandatory = $true)][string]$OutputDirectory, [string]$FunctionCandidates)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
function Write-Json($name, $value, $depth = 5) { ConvertTo-Json -InputObject $value -Depth $depth -Compress | Set-Content -LiteralPath (Join-Path $OutputDirectory $name) -Encoding UTF8 }
$log = Join-Path $OutputDirectory 'progress.log'
function Step($m) { "$(Get-Date -f s) $m" | Add-Content $log }

$app = New-Object -ComObject Visio.Application
$app.Visible = $false; $app.AlertResponse = 7
$exe = Join-Path ([string]$app.Path) 'VISIO.EXE'
Write-Json 'application.json' ([ordered]@{
    version = [string]$app.Version; build = [string]$app.Build; language = [int]$app.Language; path = [string]$app.Path
    fileVersion = (Get-Item $exe).VersionInfo.FileVersion; productVersion = (Get-Item $exe).VersionInfo.ProductVersion
    sha256 = (Get-FileHash $exe).Hash; automationClient = "x86 Windows PowerShell $($PSVersionTable.PSVersion)"
})
Step 'application'

# --- Type library: objects, members, events and constant enumerations (cells, sections, rows, commands, formats).
$typeLibPath = Get-ChildItem ([string]$app.Path) -Filter 'VISLIB.DLL' -ErrorAction SilentlyContinue | Select-Object -First 1
$typeLib = [ordered]@{ path = $null; interfaces = @(); events = @(); enums = [ordered]@{} }
if ($typeLibPath) {
    $typeLib.path = $typeLibPath.FullName
    Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using CT = System.Runtime.InteropServices.ComTypes; using System.Collections.Generic;
public static class TL {
  [DllImport("oleaut32.dll", CharSet=CharSet.Unicode)] static extern int LoadTypeLibEx(string f, int k, out CT.ITypeLib t);
  public static List<object[]> Read(string path) {
    CT.ITypeLib lib; Marshal.ThrowExceptionForHR(LoadTypeLibEx(path, 2, out lib));
    var r = new List<object[]>();
    for (int i = 0; i < lib.GetTypeInfoCount(); i++) {
      CT.ITypeInfo info; lib.GetTypeInfo(i, out info);
      string name, doc, help; int ctx; info.GetDocumentation(-1, out name, out doc, out ctx, out help);
      IntPtr pAttr; info.GetTypeAttr(out pAttr); var attr = (CT.TYPEATTR)Marshal.PtrToStructure(pAttr, typeof(CT.TYPEATTR));
      var members = new List<string>();
      if (attr.typekind == CT.TYPEKIND.TKIND_ENUM) {
        for (int v = 0; v < attr.cVars; v++) { IntPtr pv; info.GetVarDesc(v, out pv); var vd = (CT.VARDESC)Marshal.PtrToStructure(pv, typeof(CT.VARDESC));
          string[] n = new string[1]; int c; info.GetNames(vd.memid, n, 1, out c);
          object val = Marshal.GetObjectForNativeVariant(vd.desc.lpvarValue); members.Add(n[0] + "=" + val); info.ReleaseVarDesc(pv); }
      } else {
        for (int f = 0; f < attr.cFuncs; f++) { IntPtr pf; info.GetFuncDesc(f, out pf); var fd = (CT.FUNCDESC)Marshal.PtrToStructure(pf, typeof(CT.FUNCDESC));
          string[] n = new string[1]; int c; info.GetNames(fd.memid, n, 1, out c); members.Add(n[0]); info.ReleaseFuncDesc(pf); }
      }
      r.Add(new object[] { name, attr.typekind.ToString(), members.ToArray(), (int)attr.wTypeFlags });
      info.ReleaseTypeAttr(pAttr);
    }
    return r;
  } }
"@
    foreach ($t in [TL]::Read($typeLibPath.FullName)) {
        $name, $kind, $members, $flags = $t
        if ($kind -eq 'TKIND_ENUM') { $typeLib.enums[$name] = @($members) }
        elseif ($kind -in 'TKIND_DISPATCH', 'TKIND_INTERFACE', 'TKIND_COCLASS') {
            $entry = [ordered]@{ name = $name; kind = $kind; members = @($members | Sort-Object -Unique) }
            if ($name -like 'EVisio*' -or $name -like '*Events*' -or $name -like 'E*' -and $kind -eq 'TKIND_DISPATCH' -and $name -match '^E[A-Z]') { $typeLib.events += $entry } else { $typeLib.interfaces += $entry }
        }
    }
}
Write-Json 'typelib.json' $typeLib 4
Step "typelib interfaces=$($typeLib.interfaces.Count) events=$($typeLib.events.Count) enums=$($typeLib.enums.Count)"
# 32-bit PowerShell has a small address space; release the type-library data before probing.
$typeLib = $null; [GC]::Collect()

# --- ShapeSheet functions: a name Visio does not know fails with #NAME?; any other result means it exists.
$functions = @()
if ($FunctionCandidates -and (Test-Path $FunctionCandidates)) {
    $doc = $app.Documents.Add(''); $shape = $doc.Pages.Item(1).DrawRectangle(1, 1, 2, 2)
    [void]$shape.AddSection(242)  # visSectionUser
    [void]$shape.AddNamedRow(242, 'Probe', 0)
    $cell = $shape.CellsU('User.Probe')
    foreach ($name in Get-Content $FunctionCandidates | Where-Object { $_ -match '^[A-Z][A-Z0-9_]*$' }) {
        $state = 'recognized'; $detail = $null
        try { $cell.FormulaForceU = "$name()" } catch { $detail = ($_.Exception.Message -replace '\s+', ' ').Trim() }
        if ($detail -and $detail -match 'Unknown function name|NAME\?') {
            # Retry with plausible arguments; only a name error on every shape means the function is absent.
            $retry = $null
            foreach ($argumentList in '1', '1,1', '"a"', '"a",1', '1,1,1') {
                try { $cell.FormulaForceU = "$name($argumentList)"; $retry = 'ok'; break } catch { $retry = ($_.Exception.Message -replace '\s+', ' ').Trim() }
            }
            if ($retry -ne 'ok' -and $retry -match 'Unknown function name|NAME\?') { $state = 'not_recognized' }
            $detail = $retry
        }
        $functions += [ordered]@{ name = $name; state = $state; detail = $detail }
    }
    $doc.Saved = $true; $doc.Close()
}
Write-Json 'functions.json' $functions
Step "functions=$($functions.Count)"

# --- Content: installed stencils and templates, with master names per stencil (opened read-only, hidden, docked).
$contentRoot = Join-Path ([string]$app.Path) 'Visio Content'
$content = [ordered]@{ root = $contentRoot; stencils = @(); templates = @() }
if (Test-Path $contentRoot) {
    $files = Get-ChildItem $contentRoot -Recurse -File -Include *.vssx, *.vstx, *.vss, *.vst
    foreach ($file in $files | Where-Object { $_.Extension -in '.vstx', '.vst' }) {
        $content.templates += [ordered]@{ file = $file.FullName.Substring($contentRoot.Length + 1); bytes = $file.Length }
    }
    foreach ($file in $files | Where-Object { $_.Extension -in '.vssx', '.vss' }) {
        $item = [ordered]@{ file = $file.FullName.Substring($contentRoot.Length + 1); bytes = $file.Length; masters = @(); error = $null }
        try {
            $stencil = $app.Documents.OpenEx($file.FullName, 2 + 4 + 64)  # read-only + docked + hidden
            for ($m = 1; $m -le $stencil.Masters.Count; $m++) { $item.masters += [string]$stencil.Masters.Item($m).NameU }
            $stencil.Close()
        } catch { $item.error = ($_.Exception.Message -replace '\s+', ' ').Trim() }
        $content.stencils += $item
    }
}
Write-Json 'content.json' $content
Step "templates=$($content.templates.Count) stencils=$($content.stencils.Count)"

# --- Filters, add-ins and integration prerequisites.
$filters = @(Get-ChildItem 'Registry::HKEY_CLASSES_ROOT' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '.*' } | ForEach-Object {
    $progId = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).'(default)'
    if ($progId -like 'Visio.*') { [ordered]@{ extension = $_.PSChildName; progId = $progId } }
})
$addons = @(); for ($i = 1; $i -le $app.Addons.Count; $i++) { $a = $app.Addons.Item($i); $addons += [ordered]@{ name = [string]$a.NameU; enabled = [int]$a.Enabled } }
$odbc = @((Get-ItemProperty 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers' -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name })
$odbc32 = @((Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI\ODBC Drivers' -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name })
$officeApps = [ordered]@{}
foreach ($progId in 'Excel.Application', 'Word.Application', 'Access.Application', 'PowerPoint.Application', 'Excel.Sheet.12') {
    $officeApps[$progId] = Test-Path "Registry::HKEY_CLASSES_ROOT\$progId\CLSID"
}
# Probes: CAD import, OLE insertion and document protection on a scratch drawing.
$probes = [ordered]@{}
$doc = $app.Documents.Add(''); $page = $doc.Pages.Item(1)
$dxf = Join-Path $OutputDirectory 'probe.dxf'
@('0','SECTION','2','ENTITIES','0','LINE','8','0','10','0','20','0','11','100','21','100','0','ENDSEC','0','EOF') | Set-Content $dxf -Encoding ASCII
try { $s = $page.Import($dxf); $probes.cadDxfImport = "imported: $($s.Type) type shape" } catch { $probes.cadDxfImport = 'failed: ' + ($_.Exception.Message -replace '\s+', ' ').Trim() }
try { $o = $page.InsertObject('Excel.Sheet', 0x10); $probes.oleExcelSheet = 'inserted' } catch { $probes.oleExcelSheet = 'failed: ' + ($_.Exception.Message -replace '\s+', ' ').Trim() }
try { $o = $page.InsertObject('Paint.Picture', 0x10); $probes.olePaintPicture = 'inserted' } catch { $probes.olePaintPicture = 'failed: ' + ($_.Exception.Message -replace '\s+', ' ').Trim() }
try { $probes.documentProtectionProperty = [int]$doc.Protection(); } catch { try { $probes.documentProtectionProperty = [string]$doc.Protection } catch { $probes.documentProtectionProperty = 'unavailable: ' + $_.Exception.Message } }
try { $probes.dataRecordsetsCollection = [int]$doc.DataRecordsets.Count } catch { $probes.dataRecordsetsCollection = 'unavailable: ' + $_.Exception.Message }
$doc.Saved = $true; $doc.Close()
Write-Json 'integrations.json' ([ordered]@{ filters = $filters; addons = $addons; odbcDrivers64 = $odbc; odbcDrivers32 = $odbc32; officeApplications = $officeApps; probes = $probes
    rightsManagement = [ordered]@{ msipcInstalled = (Test-Path "$env:windir\System32\msipc.dll") -or (Test-Path "${env:ProgramFiles}\Active Directory Rights Management Services Client 2.1") } })
Step 'integrations'

# --- Fonts the reference must render with (WP-01-T02).
$fontKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$fonts = @($fontKey.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { ($_.Name -replace '\s*\(.*\)$', '') })
Write-Json 'fonts.json' ([ordered]@{ count = $fonts.Count; required = [ordered]@{
    'Arial' = $fonts -contains 'Arial'; 'Calibri' = $fonts -contains 'Calibri'; 'Segoe UI' = $fonts -contains 'Segoe UI'
    'Times New Roman' = $fonts -contains 'Times New Roman'; 'Courier New' = $fonts -contains 'Courier New'; 'Symbol' = $fonts -contains 'Symbol' }
    all = @($fonts | Sort-Object -Unique) })
$app.Quit()
Step 'done'
