# Windows Visio differential validation

This workflow exercises authored synthetic `.vsdx` and experimental `.vsd` files in desktop Visio through its COM automation API. It records page metadata, a flattened parent-linked shape tree, text, selected ShapeSheet values in Visio internal units, one persisted text edit, Save As, close/reopen, and PDF/SVG exports. It writes a JSON report plus the saved drawings and exports for review.

The host runner accepts only a schema-version-1 `manifest.json` with `syntheticOnly: true`, verifies every listed file's SHA-256, and stages only the manifest and its listed `.vsd`/`.vsdx` files. It rejects linked files and any fixture marked as containing native metadata. Never point it at user documents, customer drawings, or a directory whose manifest does not explicitly identify a synthetic-only corpus.

## Current guest

The verified guest is the Lima instance `mondrian-win`, backed by QEMU 11.1.2 on ARM64. It runs Windows 11 Pro ARM64 build 26300, with 4 virtual CPUs, 6 GiB memory, and a 64 GiB expanding disk. It has Lima's SSH command channel and `limactl copy --backend=scp`; there is no configured WinRM or guest-agent channel. Windows PowerShell 5.1 is available both natively and as x86 at `%windir%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`.

The latest guest inventory found no Visio executable, uninstall entry, or `Visio.Application` COM registration. The supplied Visio 2019 ISO was copied to a private guest temp folder and its SHA-256 matched the host copy; its x86 `Setup32.exe` signature verified as Microsoft. The ISO contains both x86 and x64 payloads, including the x86 stream files for version 16.0.10730.20102. The first command incorrectly passed an ODT `/configure` file to the ISO's `Office\Setup32.exe`; the ISO `autorun.inf` shows its root `Setup.exe` launches that bootstrapper with `/AUTORUN`, so that no-op does not test the ODT configuration.

The signed Microsoft Office Deployment Tool 16.0.20326.20112 was then extracted into the same isolated setup folder. Its first `/configure` attempt exited with code 1603 and left no Visio registration or Click-to-Run service. A second attempt using the `PerpetualVL2019` channel with the Retail product ID stayed active and opened a connection to Microsoft's OCSP endpoint plus an HTTPS connection to 51.11.192.53 whose service could not be verified. The ISO's Click-to-Run metadata and local payload both contain the expected x86, en-us, Visio Professional 2019 Retail package, but no authoritative evidence confirms that the later channel/product combination is valid. Installer logs are absent or empty, so the ODT failure's cause is unresolved; the IP could not be identified as an Office endpoint from Microsoft's published endpoint sources. Only those test `setup.exe` processes were stopped; the final inventory still found no Visio executable or service. The installer artifacts remain under the guest temp path `MacVisio-Visio2019-Setup-20261014`. No activation setting was enabled, and no customer drawing was used. Windows Visio acceptance has not been recorded. Run the harness only after a licensed Visio desktop installation is actually present; it will report failed phases if COM activation is unavailable.

On 2026-10-15, the signed media's own `D:\Setup.exe /AUTORUN` entry was run in `mondrian-win`. It remained the sole setup process for the 120-second monitor, started no Click-to-Run process/service, and exited without installing Visio or exposing an observable UI or error. A separate official Office Deployment Tool run with a Retail VisioPro2019 configuration returned `1603` and likewise created no Visio registration or useful setup log. The ISO was dismounted, and a fresh 32/64-bit inventory again found no Visio executable, uninstall entry, Click-to-Run service, or `Visio.Application` COM registration. A one-file run of the synthetic acceptance corpus then confirmed Windows 11 ARM64 with x86 PowerShell and failed at COM activation with `REGDB_E_CLASSNOTREG` (`CLSID {00000000-0000-0000-0000-000000000000}`); inspection, mutation, Save As, reopen, PDF and SVG phases were skipped. The machine-readable report is `build/WindowsValidation/qemu-live-no-visio-20261015.json`. This leaves Windows Visio acceptance unrecorded; no activation or licensing settings were changed, and no customer drawing was used.

Microsoft documents x86 emulation on Windows 11 Arm and Office 2019's 32-bit/64-bit deployment configuration. This guest setup uses x86 Visio and x86 PowerShell for COM. These documents do not by themselves certify this particular Visio 2019 build on ARM; only a completed guest run provides runtime evidence:

- [How emulation works on Arm](https://learn.microsoft.com/en-ca/windows/arm/apps-on-arm-x86-emulation)
- [Deploy Office 2019](https://learn.microsoft.com/en-us/office/2019/deploy)
- [Office Deployment Tool download page](https://www.microsoft.com/en-us/download/details.aspx?id=49117) (guest-verified package version 16.0.20326.20112)
- [ODT configuration options](https://learn.microsoft.com/en-us/deployoffice/office-deployment-tool-configuration-options) and [supported product IDs](https://learn.microsoft.com/en-us/microsoft-365/troubleshoot/installation/product-ids-supported-office-deployment-click-to-run)
- [Microsoft 365 IP web service](https://learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-ip-web-service?view=o365-worldwide) (the observed address was not identified in the published list)
- [Supported Office Deployment Tool product IDs](https://learn.microsoft.com/en-us/microsoft-365/troubleshoot/installation/product-ids-supported-office-deployment-click-to-run)
- [Visio `ResultIU`](https://learn.microsoft.com/en-us/office/vba/api/visio.cell.resultiu) (internal length units are inches and angles are radians)
- [Visio PDF export](https://learn.microsoft.com/en-us/office/vba/api/visio.document.exportasfixedformat) and [page export formats](https://learn.microsoft.com/en-us/office/vba/api/visio.page.export)

## Run

Start only the intended QEMU guest with its wrapper; the validation runner never starts or stops a VM:

```sh
/Volumes/External/Mondrian-QEMU/start-vm.sh
```

Generate or select the synthetic fixture directory, then run:

```sh
python3 scripts/windows/run-visio-acceptance.py \
  --fixtures build/WindowsValidation/fixtures \
  --report build/WindowsValidation/windows-report.json \
  --artifacts build/WindowsValidation/windows-artifacts \
  --instance mondrian-win \
  --timeout-per-file 300
```

The runner requires the named Lima instance to already be `Running`. It creates a unique temporary work folder in the guest, transfers only the validated synthetic corpus and the two harness scripts, and runs one x86 PowerShell worker per file. Each worker has its own timeout. A timeout stops that worker and marks remaining cases as failed rather than pretending they ran. The runner does not shut down the VM, stop unrelated apps, or reuse a running Visio process; if Visio is already open, close it before starting so COM cannot attach to a user's session.

The default machine report is `build/WindowsValidation/windows-report.json`. PDF, SVG, and Save As outputs are copied to `build/WindowsValidation/windows-artifacts`. Each phase has `passed`, `failed`, or `skipped` status and a structured error when it fails. The overall report and each file result pass only when open, inspection, mutation (or the empty-file skip), Save As, close, reopen, PDF export, and SVG export pass. A failed or skipped export is not a visual acceptance.

Compare the guest snapshots with the authored manifest:

```sh
python3 scripts/compare-windows-report.py \
  build/WindowsValidation/fixtures/manifest.json \
  build/WindowsValidation/windows-report.json \
  --report build/WindowsValidation/windows-comparison.json
```

The comparator checks guest-computed input hashes, pages, background flags, dimensions, shape order, IDs, parent IDs, text, the expected cached cells, and the changed text after reopening. Inspect the saved `.vsd`/`.vsdx`, PDFs, and SVGs separately for visual fidelity. This smoke corpus does not establish complete Visio parity, the behavior of arbitrary customer files, ARM performance, licensing status, or activation.
