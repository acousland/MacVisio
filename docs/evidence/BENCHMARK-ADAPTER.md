# Real synthetic product benchmark adapter

`profile-benchmark-adapter.py` implements the adapter interface expected by
`run-benchmark-samples.py`. It validates the selected fixture's entire corpus using
the existing generator/validator, independently retains its exact fixture counts,
pre-reads the complete selected fixture, and launches a fresh product process with
`--benchmark-sample FIXTURE RESULT`. The report retains the resolved executable path and its SHA-256 before launch,
then checks the executable hash and validates the original corpus path again after
the process returns. Linked fixture files and linked corpus directories are refused
before resolving them. Inputs and prior attempt files are never overwritten.

Warm means **filesystem bytes pre-read, fresh app process**. Validation itself
also reads the fixture data. No app route/text/image cache warm-up or OS cache
flush is claimed. Cold-cache, memory-cycle and recovery modes fail explicitly;
this adapter supplies no fault injection, RSS peak/leak evidence or cold result.

Example using a new output path outside the immutable corpus:

```sh
python3 scripts/profile-benchmark-adapter.py \
  --app .build/m0-instrumentation/out/Products/Debug/MacVisio \
  --fixture build/M0/benchmarks/objects-100-balanced.vsdx \
  --result build/M0/adapter-one.json --cache warm --sample 1 --mode performance
```

Pass `python3 scripts/profile-benchmark-adapter.py --app ABSOLUTE_EXECUTABLE` after
`--` in the corpus runner. Use at least 30 attempts per fixture/cache condition;
the runner retains every attempt and its validation errors. A smaller immutable
subset corpus can retain exact fixture bytes and their authored manifest entries;
its separate manifest hash and original corpus provenance must both be recorded.

## What the product actually does

The app creates its own document without registering or activating another
document. It reads the synthetic VSDX, checks generated page/shape text markers,
creates an editor, lays it out and rasterizes its viewport. The owned editor is briefly shown for native window event routing. The Python validator
is the authoritative corpus/metadata/hash guard; the app's marker check is an
additional refusal, not a replacement for that guard.

The trace creates NSEvent mouse-down/up instances at a visible unlocked shape and
posts them and a right-arrow key event to the NSApplication event queue, then dispatches each through NSApplication, NSWindow hit testing and the responder chain. It verifies canvas keyboard focus and all three owned event deliveries. It
checks that selection exists, committed document state changes, and calculation
issues are absent. It rasterizes feedback, then saves the captured committed state
asynchronously to a new native file in its own unique temporary directory. It
waits for the completion callback, decodes the saved file, checks exact model
agreement, closes the owned document and removes its temporary output.

This is a synthesized native event-loop trace. It does not qualify hardware
input routing, dragging, panning, compositor/frame deadlines, VoiceOver, or the
historical suite-context saved-state intermittency. `eventTrace` records this
scope. The runner environment should not supply an interaction-gate trace name
based on this sample alone.

Native routing requires an unlocked macOS graphics session and a key benchmark
window. The product checks the graphics session before routing and reports an
explicit event-phase failure when it is locked or unavailable. It activates its
owned window and verifies key-window admission before dispatch. It never replaces
a failed native route with direct Canvas handler calls. The three native
`BenchmarkProfileTests` explicitly skip when this prerequisite is absent; refusal
tests still run. The M1 qualification session reported
`CGSSessionScreenIsLocked = 1`, so its native trace and frame/performance gates
remain unaccepted. See [M1 qualification](../delivery/M1-QUALIFICATION.md).

The main run loop is pumped between stages and while waiting for save completion;
actual main-queue heartbeat deliveries and scheduling gaps are recorded. The
collector remains process-local and opt-in. `importWarningCount` and
`calculationIssueCount` remain visible even when the scripted operation completes.

## Phase and count semantics

`open.elapsedMs` measures read through editor setup and first rasterized viewport.
`event.elapsedMs` measures the mouse/key script through rasterized feedback.
`save.elapsedMs` measures save invocation through callback, excluding readback
verification; failed verification still fails the save phase. `close.elapsedMs`
measures the synchronous document close call. Other observed phase durations are
inclusive instrumented work totals, explicitly labelled in each phase. They are
diagnostic aggregates, can overlap, and cannot be added into an end-to-end total.
See [INSTRUMENTATION.md](INSTRUMENTATION.md) for their actual scope.

A phase is `passed` only when its measured operation completed; absent stage
observations remain `not_observed`. Product/timeout/unsupported-mode/validation
failures are retained as failed phases. The corpus runner rejects missing phases
and failed attempts. A passed phase is not feature or compatibility acceptance.

Runtime counts come only from the product collector. Fixture object/shape/edge,
formula, image and hierarchy counts come only from the independently validated
manifest; a product report cannot override them. Import warnings, calculation
issue counts, raw instrumentation, driver exit status and the event trace are
retained. `inputToFeedbackMs` measures synthesized-event to raster feedback. No
`frameTimeMs`, peak RSS or save-specific maximum main-thread stall is invented
from a synchronous paint duration or an entire-run heartbeat maximum. Their
absence keeps the corresponding absolute gates unaccepted.

## Local verification

When the unlocked-session prerequisite is available, `BenchmarkProfileTests` covers a real synthetic read/event/commit/calculation/
draw/snapshot/async-save/close run, actual heartbeat delivery, byte-for-byte input
preservation, unchanged document-controller registration, refusal of non-synthetic
content, and preservation of existing result/input files. Logs and direct sample
results remain under ignored `build/M0/`; public fixtures remain immutable.

`python3 -m unittest scripts.tests.test_benchmark_adapter -v` retains six reproducible refusal checks for cold/memory/recovery modes, linked fixture/corpus paths and existing reports. These mock only the no-launch paths and do not produce performance evidence. A calculation-error regression additionally ensures that a completed calculation span with issues remains a failed phase.
