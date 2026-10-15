# Requirement and runtime evidence ledger

This documentation/source inventory is the local WP-02 foundation. It preserves all **154** requirement IDs and the feature snapshot exactly: 148 baseline/native obligations and six extensions. It does not qualify Microsoft Visio compatibility. The exact reference executable build remains unknown, every compatibility dimension is unverified, and every requirement remains unaccepted.

`requirement-ledger.json` links each requirement to its normative specification line, unchanged feature classification and note, repository evidence document, acceptance contract, applicability basis, delivery work packages, acceptance owner, unresolved fixture prerequisite, and five separate evidence dimensions. Snapshot counts remain 9 Implemented, 88 Partial, 31 Not implemented, 13 Unverified, six Planned extension, four Not evidenced, two Blocked and one Experimental. An Implemented snapshot record is local support evidence; it does not automatically pass any evidence dimension.

`runtime-inventory.json` is a **bounded inventory**, with 171 stable entries and one planned semantic qualification child per entry. The counts include an explicit unknown-remainder entry in every category:

| Category | Entries including unknown remainder | Observation boundary |
| --- | ---: | --- |
| Commands | 33 | Literal command-line switches in `main.swift`; no claim to the full menu/ribbon/context/shortcut catalog. |
| Solutions | 16 | Fifteen baseline solution requirements from the snapshot; graphics/content import does not implement solution behavior. |
| Masters | 1 | Unknown named-master catalog; aggregate historical parser counts are retained separately. |
| Cells | 22 | Geometry/text key arrays in `ShapeSheetEngine.swift`; no complete owner/section/row inventory claim. |
| Functions | 73 | Explicit dispatch labels/name comparisons in four evaluator source files; no complete runtime or contextual semantic support claim. |
| Filters | 14 | Thirteen documented filter families/versions or grouped graphics paths; not an observed installed-filter list. |
| APIs/events | 6 | Five documented API/event/trust workflow gaps; named type-library members and event order remain unknown. |
| Integrations | 6 | Five documented integration/applicability workflows; exact components, drivers and licensing remain unresolved. |

The historical library summary records installer build `16.0.10730.20102`, 856 parsed libraries and 12,108 decoded master occurrences. It explicitly records `windowsValidated: false`. An installer package version is not the frozen version of a running/activated reference executable, and these counts cannot close the named-master denominator. No private library or user drawing is copied into the ledger.

Before implementation, WP-02-T02 was divided into seven small children: C01 commands, C02 solutions, C03 masters, C04 cells/functions, C05 filters, C06 APIs/events and C07 integrations. Their source/document boundaries are implemented; their runtime qualification remains pending WP-01. T04 has a stable child case per bounded entry, mapped to the exact requirement and downstream work packages. Every unknown remainder also has a child; expanding that child requires enumerating named members and adding individual semantic workflow cases. A broad family record is not exhaustive member coverage, and missing baseline members must not become extensions to reduce the denominator.

## Generate and validate

From the repository root:

```sh
python3 scripts/build-evidence-ledger.py --write
python3 scripts/build-evidence-ledger.py
python3 -m unittest discover -s scripts/tests -p test_evidence_ledger.py -v
```

Generation is deterministic for the canonical inputs, hashes the requirements/specification/snapshot, reconciles snapshot states against the backlog, and checks source anchors. Regeneration preserves recorded dimension evidence, fixtures, applicability decisions and reference records. It refuses to discard an existing stable record; reconcile renamed/removed members explicitly. The checked-in inventory has the current source boundaries; adding source dispatch labels or command switches requires regeneration and review. Structural validation is executable evidence of ledger consistency only.

The validator rejects requirement-ID/count drift, snapshot status promotion, changed canonical scope/ownership, broken or unsafe local links, missing unknown remainders, missing/changed workflow children, incomplete five-dimension records, false catalog completion, and acceptance without all five passing dimensions, a fixture and a verified exact-build reference. Changing applicability or excluding an obligation requires a separate decision with ID, approved state, approver, rationale, covered requirement IDs and a local approval artifact. No exclusions or approved scope changes currently exist.

## Evidence contract

The five dimensions are **preservation**, **rendering**, **editing**, **behavior** and **interchange**. A parser result, source occurrence, successful syntax parse or local test cannot promote a dimension to compatibility acceptance. Current source tests are pointers/prerequisites, not imported dimension results. The validator does not run Visio or infer semantic correctness from a status string.

A future passing dimension must link an immutable synthetic-only local JSON artifact with a SHA-256 hash. Its descriptor needs `kind: reference_workflow`, `exact_build`, `outcome: passed` and `synthetic: true`. The underlying normalized report must match the subject requirement/inventory ID, dimension and exact build, and contain `schema_version: 1`, `kind: reference_workflow`, `outcome: passed`, `synthetic: true`, a nonempty `run_id`, and nonempty `checks` with IDs, passing outcomes, explicit `expected` and `observed` values. The checks must implement the actual semantic acceptance contract; this schema is a consistency guard, not independent verification of the report author's assertions. Reports should link the original runner result and its input/output hashes in their check evidence. Existing Windows reports require an explicit reviewed dimension assessment before normalization; an open/save result alone is insufficient for all dimensions.

Interchange additionally requires `private_metadata_removed: true` and `bidirectional: true` in both descriptor and report, with actual results covering both directions. Requirement acceptance also requires every artifact's exact build to match the frozen reference. Unsupported dimensions stay unverified/failed; do not use “not applicable” to bypass them without an approved scope decision. Keep failed runs and intermittent results; a clean isolated rerun does not resolve intermittency.

All public fixtures and reports must remain synthetic. Do not add user documents, installer/library assets, private text, product keys or license material. Private evidence remains in a permissioned local path outside the public ledger; record a prerequisite here until a redacted synthetic acceptance case is available. Detailed reports from private drawings must not be published. Existing synthetic corpus and Windows tooling policy remain authoritative in [INTERCHANGE-CORPUS.md](../INTERCHANGE-CORPUS.md) and [WINDOWS-VALIDATION.md](../WINDOWS-VALIDATION.md).

## Remaining acceptance work

WP-02-T01 passes its local import/reconciliation contract. T02's bounded source inventory and T04's bounded child expansion exist, but their full exact-build runtime inventories remain pending. T03's evidence/decision representation and guards are implemented; compatibility acceptance remains pending the actual reference and semantic runs. The package cannot be accepted until WP-01 provides a licensed supported installed/registered reference, freezes executable build/edition/bitness/OS/fonts, and supplies real launch/COM and public-content round-trip evidence. Then enumerate each unknown category remainder and assign actual fixtures/outcomes. No task count, parser count, structural validator pass or test-only fabricated record is runtime compatibility evidence.
