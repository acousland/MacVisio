# Actual macOS app recovery qualification

**WP-05-T04 passes its local M1 recovery criterion.** The exact qualified executable `5560ddf` was exercised as a normal local `.app`, interrupted, and relaunched without an input file or explicit recovery initializer. This closes the prior gap between checkpoint/CLI readback and actual NSDocument automatic recovery.

The [machine record](../evidence/M1-RECOVERY-QUALIFICATION.json) retains source/wrapper executable hashes, process identities, UI observations, saved model verification, fresh-process public output and artifact digests. The wrapper uses a unique bundle identifier, unchanged document classes/types, `LSHandlerRank=None` and disabled update checks. It leaves the real app and default document associations alone. Its source executable bytes match the native/full-suite candidate exactly.

## Observed journey

1. Launch the isolated bundle normally. The initial process used process-local `NSQuitAlwaysKeepsWindows=YES`, `ApplePersistenceIgnoreState=NO` and update checks disabled. No `--launch-check`, `--open-check`, `--fresh` or file operands were used.
2. Through the actual native UI, create the flowchart template and change/commit the page name to `M1 recovery checkpoint 20261016`. The Untitled editor showed 8 shapes, 8 connectors, page UUID `4A8D749A-E3A0-4B36-9DD4-BCF195CA345F` and Edited. No explicit Save occurred.
3. Allow the native loop and normal deactivation. Validate the owned executable path/hash and PID, then send SIGKILL only to PID **63306**.
4. Relaunch the same bundle through normal LaunchServices with no file or diagnostic arguments. The new process is **63462**. Home fronts the application, but Window already lists a restored Untitled editor. Select that existing editor: its exact page name/UUID/counts and Edited indicator match the unsaved document. No Open, direct recovery initializer or checkpoint path was used.
5. After that observation, use native Save As to the owned `Recovered UI.macvisio`. The UI becomes clean. Independent JSON decoding verifies the exact UUID/name, eight nodes and eight edges. A fresh actual `MacVisio --convert` process reads the recovered native file and emits public VSDX whose public page name matches.
6. Quit the probe normally and verify that no owned process remains.

An early query found no app-specific Saved Application State directory or autoreopen preference. That was not a recovery failure: framework bookkeeping need not appear at those guessed locations, and Home can cover a successfully restored document. Actual automatic restoration under a different PID and matching independently saved content are the decisive observations. No private state key or recovery file was synthesized. A contemplated periodic-autosave change was not built or retained; production source remained identical to the qualified candidate.

## Reproduction and limits

Use a fresh owned bundle ID, directory and unique page marker for a repeat. Copy the candidate executable and pinned framework; retain exact byte hashes and document type/class entries. Avoid assigning a default-handler rank or replacing an installed app. Use native UI to create/commit an unsaved document, normal idle/deactivation, validated owned-process termination, and ordinary no-file relaunch. Inspect all windows before concluding that Home means recovery failed. Save/parse a recovered result only after automatic restoration is visibly established.

The probe qualifies one current-host local app-bundle recovery path. It does not establish a fixed autosave interval, all kernel/write interruption points, all supported macOS versions, signed/notarized installer/update journeys or same-original overwrite from an unverified recovered source baseline. The existing interrupted writer/write-failure/external-conflict tests remain complementary evidence. Those broader release gates stay open without blocking the accepted local M1 checkpoint.
