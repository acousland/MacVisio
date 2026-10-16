# Accepted M1 engineering checkpoint

**M1 is locally accepted and ready for M2 integration.** Qualified code is `5560ddf44255f56c0559485f9c9dfe904b3b3dc5` on `codex/m1-editing-foundation`; subsequent commits record qualification without changing that code. [M1-HANDOFF.json](M1-HANDOFF.json) is the machine-readable gate. All 25 WP-05–WP-09 tasks have passing local implementation/contract evidence.

M2 may integrate the actual branch commits and build against the document transaction/save, indexed runtime, calculation, retained scene/UI, job/resource and source-rebasing contracts. Resolve integration conflicts while preserving M2's prepared slices and rerun affected/full native checks. M3's M1 prerequisite is satisfied through M2's eventual accepted integration; M3 still needs its accepted M2 checkpoint and applicable M0 inputs.

## Acceptance evidence

- Cancelled-gesture/save and exact snapshot/token hazards have deterministic regressions and a documented historical-intermittency disposition; original timer-driven coverage remains. Three consecutive full foundation Release suites pass, plus final native Release qualification.
- Final source Release suite: 607 tests, 13 optional installer/reference skips, zero failures. All five native/refusal checks pass without native skips. All 43 incremental/async calculation checks and save/undo/close/runtime/render/UI/lifecycle checks pass.
- Twelve public scaling traces and thirty exact 1,000-shape/500-connector native interaction traces pass; each verifies routed input, committed edit, exact snapshot save/readback and unchanged input/executable hashes. The observed script latency and all performance limits remain explicit.
- Actual local app-bundle recovery passes: an unsaved edited document survived SIGKILL of its verified process and automatically reappeared after ordinary no-file relaunch under a new PID. Page UUID, unique committed name, 8 shapes, 8 connectors and Edited state matched. Only after automatic recovery was observed, native Save As produced matching independently decoded/public content and a clean UI.
- Existing invalid/write-failure, interrupted staging writer, external/symlink/queued conflict, autosave/preview and recovered-checkpoint tests provide the complementary failure cases.
- Import/formatter checks cover nine pure and 25 critical files; Python tests pass. Explicit cache/undo/job budgets and twenty-cycle editor/resource evidence pass within their stated fixture/accounting scope.

See [full qualification](M1-QUALIFICATION.md), [task ledger](M1-TASK-EVIDENCE.json), [native evidence](../evidence/M1-NATIVE-QUALIFICATION.json), and [actual recovery evidence](../evidence/M1-RECOVERY-QUALIFICATION.json).

## Gates that remain open

This accepts the local engineering checkpoint. It does not accept G1/G2, a stable release or Windows Visio compatibility. The original M1 task criteria and milestone exits distinguish local invariants from the specification's numerical release targets.

The 50 ms single-input, 33 ms compositor frame and 100 ms save-stall gates remain unaccepted. The measured three-event/raster script p95 is 246.7404 ms on a shared/uncontrolled host; it does not substitute for those metrics. Standard/large workload and platform matrices, signed/notarized shipping installation/update/recovery, VoiceOver/IME, exact-build reference and independent interchange qualification remain with their owning M0/M2/M3/release work. These gates remain mandatory; they no longer prevent M2 from integrating accepted M1 contracts.

The recovery probe uses an isolated uniquely identified local app wrapper with the exact tested executable. It qualifies native NSDocument automatic recovery on this host, not shipping bundle signing/install acceptance. It exercises normal idle/deactivation checkpoint opportunity, not a guaranteed periodic recovery deadline. Recovery of a named original without a known source baseline remains fail-closed, with Save As/Revert available. All limits in the qualification record remain in force.
