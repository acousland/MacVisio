# WP-07 implementation and qualification evidence

State: implemented; all 24 owned focused tests pass in grouped run 7. Full-suite and M1 acceptance remain pending the parent's broader native lifecycle disposition. No subagent commits or builds were run; the M1 parent owns the shared index/build and commits.

## Delivered implementation

- Bounded context-free expression cache, keyed by exact formula and parser limit. Resolved values remain inside immutable page contexts.
- Retained node dependency graph with all-branch references, public/parent identity and explicit conservative policies. Numeric-only control literal changes preserve dependency shape; source identity changes rebuild references.
- Geometry/field affected-closure evaluation, retained issue maps, one request clock for volatile fields and explicit changed-ID convergence propagation.
- Exact change-set adapters update retained dependency signatures and immutable node host maps by affected IDs. Initial/structural/compatibility fallback work remains reported.
- Selected rich-text synchronization consumes existing indexes; no full lookup reconstruction is needed for ordinary selected changes.
- Zero-evaluation committed control baseline; native Canvas previews only presentation and solves once on release (parent integration).
- Immutable-input calculation jobs, exact owner/snapshot/revision result gate and cooperative cancellation at pass/page/node/cell-reference boundaries.
- AppKit text measurement marshalled one immutable record at a time to main. Non-AppKit calculation remains on its owned worker. Main record count, off-main count and maximum nonpreemptable duration are recorded.
- M0 calculation span, uncached-cell, actual evaluated-object and actual text-measurement hooks integrated. Separate CalculationWork counters expose detailed local work and fallback scanning.

## Focused regressions

`Tests/MacVisioTests/IncrementalCalculationTests.swift` initially contained 19 tests covering cross-node geometry/field equivalence, insertion, retained sessions, unsupported/circular diagnostic/cache behavior, page/ordinal changes, volatile clock behavior, AppKit text/group dependencies, field diagnostic retention/fix, pure worker/full equivalence, main-owned text worker/equivalence, cancellation during measurement, selected rich text/known baseline, source ID rebinding, inactive branches, bounded parser cache/strict parser limits, repeated control helper calculations and warm 40-versus-4000-node work. The parent added the twentieth nonlinear prepared-control baseline regression.

The warm scaling test prints actual geometry/field/cell/formula/signature/host/comparison counts. The text-worker test prints main-owned record count and maximum record duration. Parent logs are the authoritative execution evidence; no timing or suite pass is claimed here before those logs exist.

## Acceptance limits

Full/incremental comparison qualifies invalidation within the existing evaluator. It does not establish Windows/Visio semantic parity. Unsupported formulas preserve their existing source/cached-value/diagnostic behavior.

The parent must verify the native zero-calculation gesture events, asynchronous pending-edit/result publication, cancellation/supersession, undo/save contracts and full-suite compatibility before marking WP-07 accepted. Every AppKit text record remains nonpreemptable; measured maximum duration constrains cancellation/UI latency. Structural rebuilds and the initial change-set producer remain explicit O(n) work.

## First grouped execution (not acceptance)

`build/m1-evidence/foundation-debug6.log` confirms source/module compilation and executed the initial 17 calculation tests. Fifteen passed; two failed fixture setup assumptions and were corrected pending a new grouped run. The retained-session fixture created a new empty session after a separate full evaluator, so its first edit on an untouched page correctly recorded cold host preparation; it now primes the actual retained session and retains the same strict warm work bounds. The volatile-date fixture omitted the date picture required by the existing formatter; it now uses a supported date picture/type and asserts both exact request-clock Value and formatted display. No production evaluator semantics were widened for either fixture.

The warm scaling test passed in that grouped run at both 40 and 4000 formula nodes per page (three pages): 4 geometry-node evaluations, 2 field-node evaluations, 14 uncached cell evaluations, 10 formula evaluations, 0 fallback input-comparison nodes, 9 dependency-source comparisons and 9 host-node preparations. The text-worker test passed with 2 main-owned measurement records and 0 off-main records. The process-wide measurement maximum at that point was approximately 0.813 ms, an upper bound for those records rather than a per-job sample distribution. These are local fixture observations, not p95 or a general text-size latency claim.

The grouped process later failed/crashed in separate lifecycle/export/native-opening tests. This run cannot close the milestone or replace a complete regression run. The M1 parent retains those dispositions and owns subsequent grouped/full qualification.

## Native asynchronous integration qualification (pending grouped rerun)

The parent implemented `MacVisioDocument.replaceInEditor`, which keeps ordinary/small synchronous compatibility calls while native drawings with at least 2000 nodes use an owned request, forked session, exact identity gate and cancellable progress sheet. An explicit `forceAsync` scheduling hook permits tests without presenting windows. Pending results retain the committed snapshot for save, and only a successful current result reaches the transaction/undo boundary.

`AsyncCalculationContractTests.swift` adds five deterministic native tests on 2200-node fixtures: return pending plus main-queue heartbeat and exactly one undo; immediate cancellation preserves all committed identity/undo state; a newer committed revision rejects the pending result; actual native save during pending calculation captures the committed snapshot and undo returns to its saved identity; and public-save archive rebasing survives a later calculation commit. The public-save test occupies both owned workers with semaphore gates, performs and completes the save while calculation remains queued, then releases the workers and checks resource ID, lineage, bindings and parts. It uses no elapsed-time race assumption.

The default-pin instrumentation test additionally compares full state and confirms direct LocPin formula attempts are recorded separately from typed/field formula evaluations. The original warm benchmark does not contain LocPin formulas, so its previous counts remain comparable.

## Grouped execution 7

`build/m1-evidence/foundation-debug7.log` confirms all 19 `IncrementalCalculationTests` and all 5 `AsyncCalculationContractTests` pass together, including the corrected warm-session/date fixtures, identifier allocation, default-pin instrumentation and deterministic public-save/source-rebase race. This is the first clean grouped pass of the full owned calculation slice.

The native 2200-node request returned pending after approximately 9.34 ms of main-thread request preparation and serviced the queued heartbeat. Both 40/4000-node warm fixtures again reported 4 geometry nodes, 2 field nodes, 14 uncached cells, 10 typed/field formulas, 0 fallback comparison nodes, 9 dependency-source comparisons and 9 host-node preparations. The accumulated main-only text measurement maximum at the text-worker test was approximately 0.418 ms; it is a process maximum, not p95 or a general record-size guarantee.

The grouped process subsequently crashed with an unowned-reference failure in a separate native opening/lifecycle path. Therefore this focused calculation pass does not close the full M1 regression gate. The parent owns that root-cause disposition and full rerun.

## Pending follow-up qualification

After the 24-test pass, five further native regressions were added (current total 29): cancelled insertion restores node/edge selections in two editors; a stale insertion cannot replace the selection of a newer committed edit; actual 2200-node Canvas control release returns pending before its control solve and saves the committed snapshot before one undoable commit; control preparation cancels without state/undo changes; and a stale gesture baseline is rejected before scheduling. These follow-up tests have not yet been executed by the subagent; the parent owns the next grouped build/run. Source/test edits are frozen for that run.

Two additional pending regressions qualify page presentation during an owned calculation: ordinary edits preserve the latest active page and keep that view through undo, while an explicit add/activate-page command retains its intended target. Current owned test count is 31 (19 incremental + 12 native async); the new follow-up cases remain pending the parent-run build.

The control presentation regression additionally changes the viewed page between baseline capture and release, then verifies the accepted control edit and its undo preserve that latest page.

Six further pending regressions close Save finalization on large active text: active inspector text is accepted before both the first and queued Save snapshots, with one undo; cancelled inline text fails its held Save before writing and drains a later Save of committed content; a superseded held text Save neither writes nor acknowledges newer state; close cancels held and queued saves exactly once; direct synchronous serialization rejects newly asynchronous text; and deterministic shared-service admission saturation fails text submission and the owning Save without serializing prior text. Queue saturation relies on main-owned completion/removal, without a timing sleep or worker-duration assumption. These tests preserve the existing already-pending calculation snapshot regression. Current owned count is 38 (19 incremental + 19 native async), before the parent's additional nonlinear control baseline regression. No new execution pass is claimed here.

Four additional pending close regressions verify that a clean document cannot close before newly finalized large text is accepted: cancellation refuses the original callback and bounds repeated close admission, direct close refuses the waiting callback exactly once, supersession refuses without replacing newer content, and a successful named-document continuation follows AppKit's autosave policy and writes accepted text before reporting permission to close. Delegate identity, Boolean and context pointer are checked through the actual Objective-C callback. Together with the parent's nonlinear prepared-control regression, the current owned count is 43 (20 incremental + 23 native async). These additions await the grouped build/run.

Grouped debug 11 compiled the close slice and passed cancellation/admission regressions, then deadlocked the named-document success test at AppKit's synchronous activity admission. The captured sample is `build/m1-evidence/debug11-sample.txt`; this run is failed qualification. The continuation now leaves calculation completion on a fresh main turn and uses asynchronous AppKit activity admission, with `continueActivity` around nested `super.canClose`, as required by the SDK's documented nesting rules. Exact request/accepted identity is checked both before admission and when admitted. The successful-close fixture now holds an actual earlier AppKit activity, verifies main heartbeat and completed calculation while close waits, then releases it and checks autosave and delegate success. The post-acceptance supersession fixture changes state while that activity holds the close handoff and verifies refusal. These fixes await the next parent-run build.

Grouped debug 12 compiled, then exposed an invalid ordering in that added activity fixture: it acquired a serialization activity before publishing text, so AppKit's required undo-group notification waited for the fixture's unreleased activity before the new close handoff was reached (`build/m1-evidence/debug12-sample.txt`). The original named-document successful close regression is restored without a manual hold. The queue/supersession regression instead acquires its activity at `didAcceptTextForClose`, a narrow boundary after accepted publication and undo-group completion, verifies heartbeat, then mutates the value model identity without invoking AppKit change-count machinery under the held activity. This corrects the fixture's SDK contract; the publication path is unchanged. The next parent run must qualify both the original successful close and this corrected queued refusal.

## Final parent qualification

Code candidate `7db0a8b` passes all 43 owned calculation checks (20 incremental and 23 native async) within the full Debug run and three consecutive full Release runs. Each entire suite executed 607 tests, 16 explicitly skipped, zero failures. None of the calculation checks skipped. The retained logs and their SHA-256 values are recorded in [M1 qualification](M1-QUALIFICATION.md) and [machine evidence](../evidence/M1-LOCAL-QUALIFICATION.json).

The first Release run's 2200-node request returned pending after 5.7625 ms and delivered its main heartbeat. Its two main-owned measurement records reported a process maximum of 0.2338 ms. Both 40/4000-node warm cases retained 4 geometry nodes, 2 field nodes, 14 uncached cells, 10 typed/field formula evaluations, zero fallback input-comparison nodes, nine dependency-source comparisons and nine host preparations. These are local observations, not p95. Full commit-input/final comparisons, initial setup and structural/dynamic fallbacks remain outside that bounded engine counter claim.

The corrected close-activity regressions pass in every final full run. The successful path accepts text, completes one undo transaction, then admits close through AppKit's asynchronous activity nesting. The queued supersession case holds only after accepted publication/undo completion and refuses stale close permission. Historical debug11/debug12 failures and samples remain retained; the final record documents their distinct production/fixture dispositions.

The unlocked native follow-up `5560ddf` changes only the benchmark driver/harness. Its full Release suite passes 607 tests, 13 optional installer/reference skips, zero failures. All 42 corpus/interaction native attempts pass. See the [current qualification record](M1-QUALIFICATION.md) for measured script latency and the separate still-unaccepted controlled input/frame and shipping installation/platform gates.

The subsequent [actual app-bundle recovery qualification](M1-RECOVERY-QUALIFICATION.md) passes on the unchanged candidate. All local M1 tasks are now accepted for the [engineering handoff](M1-ENGINEERING-HANDOFF.md); M2 may integrate. Numerical performance, reference and shipping release acceptance remain separate.
