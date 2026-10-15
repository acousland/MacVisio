# Public synthetic benchmark corpus and measurement contract

This is WP-03 local tooling evidence, not Visio compatibility or product performance acceptance. Inputs are authored from constants and generated geometry; no user document, private model or guest session is read. Architecture-review observations remain separate in `ARCHITECTURAL-REVIEW.md`; the generator does not copy those drawing contents. Targets come from `PRODUCT-SPEC.md` §8 and are never populated with generator timings.

Before implementation, the L tasks are bounded as follows:

| Child | Contract and owner | Acceptance / remaining prerequisite |
| --- | --- | --- |
| WP-03-T03-A | Corpus worker: versioned public expected pages, formula/image/hierarchy counts, hashes and synthetic restrictions; compatible input for existing Windows runner | Local package/content tests; no native metadata or external relationships |
| WP-03-T03-B | M0 reference/comparison owner: cells, masters, data/glue and graphics semantic comparison in both directions | Real reference phases and public cached values; matching native metadata cannot qualify |
| WP-03-T03-C | M0 reference owner: retain actual exact-build Windows open/edit/save/reopen/export failures and artifacts | Blocked until licensed supported exact-build Visio is runnable; no fabricated success |
| WP-03-T04-A | Corpus worker: bounded adapter invocation, all samples retained, count/phase completeness and p50/p95/max | At least 30 successful measured samples for each fixture/cache condition; failures cannot be replaced by selected reruns |
| WP-03-T04-B | M0 instrumentation owner / downstream app: implement stage/work-count adapter and explicit cache preparation | Real open/edit/save/close stages and named hardware/build; adapter process wall time is separately recorded |
| WP-03-T04-C | Downstream recovery/memory owner: real injected-fault recovery and 20-cycle memory evidence | Each declared fault preserves last valid file/checkpoint; 20 consecutive complete cycles, no inferred leak result |

## Generate

```sh
python3 scripts/generate-benchmark-corpus.py --output build/M0/benchmarks
```

The output must be new or empty and is ignored by Git. Generation is deterministic (fixed ZIP timestamps, sorted entries, no clock/random/private content). Defaults produce 16 size/variant drawings plus exact interaction, standard and large specification drawings (19 total). Sizes 100/1,000/5,000/20,000 count **all** shape objects including connectors, groups and images. `shapes` excludes connectors and includes groups/images. Separate `spec-interaction` (1 page, 1,000 shapes, 500 connectors), `spec-standard` (10 pages, 2,000 shapes, 1,000 connectors) and `spec-large` (50 pages, 20,000 shapes, 10,000 connectors) are used for the absolute open/save/RSS targets; a 20,000-total-object case cannot substitute for the latter. Variants are balanced, formula-heavy, image-heavy, and hierarchy (16 nested shapes per chain). Formula counts count authored `F` cells; image counts count foreign image shapes, including repeated use of a generated PNG. No raster substitutes for the intelligent shape count.

`manifest.json` uses the existing Windows schema version 1: `syntheticOnly: true`, safe `.vsdx` names, SHA-256, byte sizes, `containsNativeMetadata: false`, and independent authored `expected.pages`. `benchmarkSchemaVersion: 1` adds exact counts, variant and target profile. PNGs are generated patterns. VSDX contains only public OPC/XML/media parts. Consumers verify the actual archive, not just the manifest assertion. The existing Windows comparator only checks its documented public subset; formula/image presence in a manifest is not formula/graphics equivalence evidence.

## Measure adapter protocol

`run-benchmark-samples.py` takes `--fixtures`, one or more `--fixture NAME`, `--environment FILE`, `--cache cold|warm`, `--mode performance|memory|recovery`, `--report FILE`, and an adapter argv after `--`. It never opens a guest or chooses a running app session. The adapter is a separately authorized app driver. It receives `--fixture PATH --result PATH --cache CONDITION --sample INDEX --mode MODE` and must write schema-version-1 JSON. Default performance qualification requests 30 samples; memory requires at least 20 cycles, recovery at least 30 trials. Absolute p95 target evaluation always requires 30 samples, including when another mode requests fewer cycles. Every attempt is retained including timeouts, nonzero exits, malformed JSON, failed phases and count mismatches. A failed attempt prevents the entire report from qualifying. No discarded warmup or cold/warm pooling is implicit.

Environment JSON requires nonempty `hardware`, `os`, `appBuild`, `storage`, `memoryBytes` (integer), `cacheProcedure`, and `controlledHardware` (boolean). Absolute target evaluation additionally requires `architecture: "AppleSilicon"`, at least 16 GiB memory, `localSSD: true`, and controlled hardware. Shared CI can establish protocol/count completeness but cannot pass absolute gates. Cache preparation is performed and reported by the adapter on **each** sample (`cachePreparation.status: "passed"`, `method` nonempty). A cold label without a verifiable named preparation is not qualified cold evidence.

Result contract:

```json
{
  "schemaVersion": 1,
  "fixtureSha256": "<input hash>",
  "cacheCondition": "warm",
  "sampleIndex": 1,
  "mode": "performance",
  "cachePreparation": {"status": "passed", "method": "documented preparation"},
  "phases": {
    "open": {"status": "passed", "elapsedMs": 1},
    "event": {"status": "passed", "elapsedMs": 1}
  },
  "workCounts": {
    "objects": 100, "shapes": 67, "connectors": 33,
    "formulaCells": 0, "images": 0, "maxGroupDepth": 0,
    "visitedObjects": 100, "evaluatedCells": 0, "drawnObjects": 100
  },
  "metrics": {"peakRssBytes": 1},
  "fault": {"name": "write failure", "injected": true,
    "lastValidFilePreserved": true, "checkpointRecoverable": true}
}
```

The example is abbreviated and is **not** accepted as a complete result. All modes require `open,event,commit,calculation,textLayout,scenePreparation,route,draw,snapshot,encoding,save,close` phases, finite nonnegative milliseconds and positive instrumented visited/drawn work. `evaluatedCells` must be positive for formula fixtures. Static corpus counts must equal the independent manifest; the harness does not assume every edit evaluates all formulas or draws all objects. `recovery` additionally requires the recovery phase and explicit injected fault/preservation/checkpoint booleans. `memory` requires peak RSS per cycle. Optional metrics `inputToFeedbackMs`, `frameTimeMs`, `maxMainThreadSaveStallMs` and `maxPostOpenStallMs` are necessary to evaluate their corresponding absolute gates. Phase aggregates and metrics use nearest-rank p95, median p50, maximum, and retain exact sample count.

Targets are stored separately from observations in reports. Open-to-usable-viewport (adapter `open`) and save measurements apply only to the exact named spec profiles. RSS thresholds and UI stall thresholds are evaluated separately; missing metrics are `unaccepted`, never pass. Input/frame targets additionally require an explicitly named drag/pan trace in `environment.interactionTrace` and the exact single-page 1,000-shape interaction fixture and exactly 1,000 active-page shapes in `result.activePageShapes`; the general matrix is not that trace. Memory samples produce cycle observations; no generic RSS sequence alone proves absence of a sustained leak, so memory acceptance requires independent review. Recovery output retains individual named faults; the runner cannot certify fault coverage from a sample count.

Private fixtures require a separate permissioned local directory and runner contract. This public runner refuses a non-synthetic manifest, symlinks, hash/count changes, native metadata, unsafe ZIP targets, DTDs/entities and external package relationships. Do not relabel confidential drawings as synthetic. Commit scripts, contracts and small evidence summaries; keep full local run output and archives under ignored `build/`.

## Retained local evidence and acceptance boundary

[`benchmark-manifest-summary.json`](benchmark-manifest-summary.json) binds the generator and measurement runner hashes to each of the 19 generated fixture hashes, archive sizes, exact object/formula/image/depth counts and page counts. The full manifest and archives are retained at `build/M0/benchmarks`; `build/M0/benchmark-generation.txt` and `build/M0/benchmark-structural-validation.json` retain the local structural run. The existing host Windows fixture validator accepted all 19 inputs, and the independent public VSDX snapshotter recounted every page/object cardinality. No guest or Visio process was involved in those checks.

`python3 -m unittest scripts.tests.test_benchmark_corpus scripts.tests.test_interchange_checks -v` passed 21 tests in 14.272 seconds (test execution time, not a product benchmark). Output is retained in `build/M0/benchmark-tests.txt`. Tests cover full exact corpus counts, repeatable bytes, public comparison input compatibility, native metadata/external relationship/link/hash/count rejection, phase completeness, duplicate/nonfinite evidence rejection, 30-sample qualification, absolute hardware/trace gates, memory/recovery prerequisites, and retention of a deliberate adapter failure among 30 attempts. Fabricated adapter records exist only inside temporary unit-test directories and are never product observations.

WP-03-T01's public fixture foundation and WP-03-T03-A/T04-A tooling contracts are implemented locally. WP-03-T02 product instrumentation and T03-B/C bidirectional real reference comparison are separate work. WP-03-T04-B/C still require the real adapter and actual controlled hardware, recovery/fault and memory-cycle evidence. WP-03-T05's public contract/hashes/confidentiality policy are documented here; full package acceptance remains unaccepted until those dependencies pass. The image-heavy fixtures intentionally measure image-instance loading with a shared generated 16×16 asset; distinct high-resolution bitmap memory stress is an additional fixture family if that claim is needed.
