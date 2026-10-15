# M0 reference and feasibility evidence

16 October 2026 (Australia/Melbourne). Baseline code/planning: `7c270124993bac09967109f95e603ebb47bd98ff`. This worktree is `codex/m0-reference-foundation`; the original checkout is read-only evidence input.

## Current reference observation

`inspect-reference-environment.py` ran a read-only script in the already-running Lima `mondrian-win` guest. The script uses explicit Registry32/Registry64 reads, standard Office executable paths, process/service enumeration, font file hashes and ODBC registrations. It never invokes an installer, activates COM, queries product keys, reads data-source names/credentials, or stops a process/guest. Raw inventories remain in ignored `build/M0/reference/`; a small hash-linked summary is committed alongside this note.

The 2026-10-15T23:17:07Z inventory (16 October locally) found Windows 11 Pro ARM64 version 10.0.26300, en-GB culture/UI, PowerShell 5.1.26100.9711 (64-bit), and x86 PowerShell available. Both COM registry views have no `Visio.Application` CLSID, Click-to-Run configuration, or Office/Visio uninstall entry. Neither standard Office16 executable path contained Visio. No VISIO/setup/OfficeClickToRun/OfficeC2RClient process or ClickToRunSvc was present. These are bounded negative observations, not a scan of every disk or license account.

Both ODBC views register SQL Server with file version `10.0.26100.9711 (WinBuild.160101.0800)`. The 32-bit view also registers legacy Access/Excel/text/dBase/Paradox/Oracle names, but the probe could not resolve their driver file versions. A registration is not a working connection or a Visio database import. Exact drivers, source versions, licensing and database-reverse-engineering applicability remain unresolved.

A fresh isolated one-file synthetic `blank.vsdx` run used the existing Windows harness with a 30-second per-file timeout. It failed at COM activation with `0x80040154` (`REGDB_E_CLASSNOTREG`); inspect, mutation, save, close, reopen, PDF and SVG remained skipped. The comparator retained 12 differences. No Visio round-trip, repair-prompt, rendering or edition/build acceptance is claimed. The run used its own guest temporary directory and did not start/stop a VM or disturb another application.

## Installation and freeze prerequisites

Existing private evidence documents signed media and failed/no-op installer attempts on 14–15 October. This turn did not repeat those attempts. Signed media does not establish license entitlement, activation or support for this exact Windows ARM/build combination. The current environment has no reference application to freeze or restore.

The documented [Visio deployment guide](https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/deployment-guide-for-visio) uses ODT for volume-licensed Visio 2019; the [Office 2019 deployment guide](https://learn.microsoft.com/en-us/office/2019/deploy) specifies the PerpetualVL2019 channel for volume products. This does not validate the prior Retail-product/channel combination. Microsoft’s [Visio end-of-support notice](https://techcommunity.microsoft.com/blog/microsoft_365blog/everything-you-should-know-about-visio-2016-and-visio-2019-end-of-support/4265894) says existing installations continue to run after end of support in October 2025. Thus preserving the requested historical exact-build baseline requires an appropriately licensed historical reference; substituting a newer release changes the baseline. Sources were checked on 16 October 2026; no license purchase, activation change or unsupported deployment was performed.

Required external inputs are an existing entitled Visio Professional 2019 reference image or a verified installation source/entitlement and host combination. Then record actual edition, exact executable build/hash, architecture/automation bitness, OS, locale, font names/hashes and relevant solution/driver/filter prerequisites. Launch/COM and the real smoke must pass before image qualification. License status remains unverified, never inferred from install success.

Restore qualification must use a **powered-off, separately owned reference image**, not a copy of this live user guest disk. Record image hash and authorized storage, restore a disposable reference clone, compare the environment manifest and rerun the same synthetic smoke. No image snapshot/restore has been executed. WP-01-T02/T03/T04 remain blocked.

## Bounded feasibility disposition

L-task children are defined in [M0-CHILD-SLICES.md](M0-CHILD-SLICES.md). They are feasibility obligations, not reductions in the full baseline.

| Area | Observed/local evidence | Decision and remaining reference obligation |
| --- | --- | --- |
| Binary VSD | `BINARY-VSD.md` and `BinaryVisioTests` distinguish genuine public CFB graphics/1-D endpoint records from checked `MacVisioModel` recovery. Existing public parser tests omit private metadata; unchanged original bytes and opaque root streams have regression coverage. Complete formula/master/data/glue serialization is absent or unresolved. | Preserve current experimental graphics writer and byte-preserving unchanged path. Do not choose a full semantic direct/adapter implementation from these results. Exact-build formula/master/data/glue and edited-object preservation probes still required for WP-04-T01. |
| Native API versus Windows bridge | Current `main.swift` exposes conversion/render/profile commands, while the current guest has no Visio COM registration and the bridge smoke fails activation. Native model/CLI operations do not execute unmodified COM/VBA/VSL/VSTO/ActiveX code. | Keep a native facade and explicit Windows bridge as separate potential support paths; unmodified script/add-in execution is untested. WP-31 requires API/event/transaction/version cases and bridge lifecycle/security work. |
| OLE and protected files | No existing Mac runtime path proves Windows object activation or rights-managed edit support; this probe does not access protected content or change trust settings. | WP-32 must add named object/server versions, entitled protected fixtures and fail-safe preservation before execution; no bypass or inferred native equivalence. |
| CAD | No exact-build Visio filter inventory or versioned CAD round-trip evidence exists. | WP-28 needs DWG/DXF generation/version fixtures, filter availability and physical-scale/unit checks. A graphics conversion is not CAD semantics. |
| Database | Current 32/64-bit ODBC names/file versions are retained as prerequisites only; no server, schema, credentials or Visio solution was used. | WP-26 must settle exact-build applicability and source/driver matrix with authorized synthetic schema import. Registration is not acceptance. |

Cost drivers remain unresolved runtime member/catalog size, exact-build availability, public binary record ownership, add-in/server bitness and lifecycle, licensed drivers/objects, rights enforcement, and bidirectional semantic/visual comparison. No estimate or scope exclusion is approved by this note.

## Harness changes and limits

The Windows worker/comparator optionally capture/compare `formulas` (FormulaU by cell), `data` (Prop. cells via ResultStrU), shape `masterID`, page `connects` (from/to sheet/cell), and document `masters` (ID/name/top-level shape count). These are requested public snapshots. String equality is intentionally conservative and does not establish formula execution, complete master definition/inheritance, external-data semantics or rendered fidelity. Failed/skipped phases still fail the comparison.

`prepare-public-validation-copy.py` requires a schema-1, explicitly synthetic, hash-bound VSDX corpus and creates a new sibling/output directory. It strips `macvisio/` parts and their native relationships/content-type overrides only in that copy. Source hashes remain unchanged; public image parts with MacVisio-generated names are retained. The Windows host now inspects actual native metadata parts/relationships as well as the manifest assertion. Binary VSD stripping is not implemented by this ZIP utility. A separate permissioned private corpus path remains required; this public path never accepts confidential documents.

The optional COM fields have local comparator negative tests and guest PowerShell syntax validation. Real COM execution is blocked by the absent reference. Reverse-direction Mac reimport/normalization, graphics/export inspection and full independent round trips remain unimplemented/unaccepted child work; this additive tooling does not close WP-03-T03.

The bounded local VSD probe ran the existing 14 `BinaryVisioTests` on this worktree's built candidate: all passed. This includes independent libvisio public graphics/Unicode/curves/images/1-D endpoints, unchanged-byte preservation and edited opaque-root-stream retention. `build/M0/binary-tests.log` retains the run. It does not test public formula/master/data/glue semantics in Visio, and it does not close the direct-versus-adapter feasibility decision.

Two single debug profiles exercised the generated 100-object balanced public drawing without saving its input; [local-probe-summary.json](local-probe-summary.json) retains observed stages/counters and hashes. Open imported 67 nonconnector shapes and 33 connectors and reported one warning. Programmatic insert/undo/redo passed. No real input-event, save/close or delivered heartbeat evidence exists in those runs. No p95 or absolute performance gate is accepted from a single uncontrolled-cache diagnostic.

[feasibility-decisions.json](feasibility-decisions.json) records 27 bounded downstream proposals across binary formats, automation, foreign/protected content, CAD, source/driver and Office integration work. Each proposal retains requirement IDs, source/test anchors, actual local evidence hashes, costs, dependencies, fixtures/checks and an explicitly deferred decision. Runtime prerequisites prevent selecting or accepting a full compatibility approach.
