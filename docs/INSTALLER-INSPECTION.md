# Supplied installer inspection

Inspected 2026-10-14. Read-only mounted image: `/Volumes/16.0.10730.20102`. No installer or Windows executable was executed. No large application stream was extracted. This is static package evidence, not observed Visio behavior.

Follow-up in version 0.8 decoded and hash-checked all 856 stencil/template assets from the culture stream, without extracting the application engine. Actual native imports, public exports and a full parser coverage scan are recorded in [STENCIL-LIBRARIES.md](STENCIL-LIBRARIES.md). The original inventory observations below describe the earlier inspection boundary.

## Observations and evidence

| Finding | Evidence and search boundary |
| --- | --- |
| Office Click-to-Run installer build **16.0.10730.20102** | `Office/Data/v64_16.0.10730.20102.cab` → `VersionDescriptor.xml`, `Available Build` and `I640Version`; `s640.cab` → `MasterDescriptor.x-none.xml`, descriptor version. |
| 32-bit and 64-bit Windows payloads, with English US culture streams | The mounted filesystem contains 82 files totaling 3,548,432,295 bytes, including `Setup32.exe`, `Setup64.exe`, `stream.x86.x-none.dat`, `stream.x64.x-none.dat`, and their `en-us` streams. |
| Top-level setup is an Office bootstrapper | REA `inspect_pe_resources` on `Setup.exe`: PE32, machine 332 (x86), 429,328 bytes, 50 resource records; SHA-256 `5468963e71c183162cb01be461b777023968cefb9974e848e5fccf28bbce0a17`. Evidence ID `ev_8f8fb87cde76745c1fad6c4e5a75b14feaa975af0e48072f4a56199834addac4`. Its version resource at file offset 404,256 (2,084 bytes), decoded separately as UTF-16, names `Microsoft Office`, `DVDSetup.exe`, and version `16.0.10730.20102`. |
| Visio application is packaged inside the platform stream | `s640.cab` → `Stream.Platform.x-none.man.xml`: `root\Office16\VISIO.EXE`, 1,361,704 bytes, version `16.0.10730.20102`, SHA-256 `D252046CD961C193D1E33600D330F533D3BA8F324B291CE3DE89D349898C254C`. This hash is the manifest's declaration; executable bytes were not extracted or independently hashed. |
| Installer metadata describes multiple editions | `MasterDescriptor.x-none.xml` and `Stream.Platform.x-none.man.xml` define Professional/Standard, Retail/Volume, 2019 and 2016 Visio SKU branding. `C2RFireFlyData.xml` includes `visiopro2019retail`, `visiostd2019retail`, `visioproretail`, and `visiostdretail` setup combinations. |
| Templates and stencils are present in the packaged culture stream | `s641033.cab` → `Stream.Platform.Culture.man.xml` contains 1,953 sized file records, including **536 `.vssx` stencil** and **320 `.vstx` template** records. Examples: `Visio Content\1033\ACTDIR_M.VSTX`, `ACTDIR_U.VSTX`, `ADO_M.VSSX`, `ALARM_M.VSSX`, `ANALYTICS_M.VSSX`, and `Office16\1033\PROPRPT.VSSX`. These are inventory records; assets were not decoded, rendered, copied, or incorporated into the new app. |
| No Visio implementation source project was found | No `.cpp`, `.c`, `.h`, `.cs`, `.sln`, `.vcxproj`, or `.swift` files in the 82 visible mounted files. The 7,523 sized x64 platform manifest records have none of those extensions; the 1,953 culture records include only ancillary `OUTLPERF.H`. Compressed streams and the x86 manifest were not comprehensively searched for source content. |

## Inferences

- This image packages Windows Office/Visio application binaries and content. It does not supply a buildable native macOS Visio implementation in the inspected boundary.
- Build identity is confirmed. A single selected or licensed Visio edition cannot be established from these generic multi-SKU manifests alone.
- Template inventory can guide coverage planning; filenames alone do not establish shape geometry, formulas, behavior, or visual appearance.

## Unknowns and reconstruction limits

- Original runtime UI, command semantics, drawing engine behavior, ShapeSheet evaluation, document compatibility, add-ins, printing, and proprietary layout details remain unobserved.
- No application binary engine was ported, decompiled, or executed during this inspection. An independently implemented macOS editor must not be described as an exact binary port or as proven 1:1 Visio parity.
- REA's ISO archive opening was unsupported in the parent investigation. The mounted directory, CAB inventories, XML manifests, and portable PE resource parser provided the evidence above. Static PE icon groups do not establish actual shell/window rendering or runtime UI behavior.
