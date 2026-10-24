# MacVisio 0.23.5 stable release candidate

Version 0.23.5/build 30, Apple Silicon, macOS 27.0.1 minimum, stable channel and the existing latest-release Sparkle feed.

Archive: `build/releases/stable-candidates/0.23.5/MacVisio-0.23.5.zip`.

SHA256: `655874c0a5deb865952c4ffc54e8f445566e898ed8895988aec5f096bedf84cd`.

Bundle source: `7124801f9cac6a91220c9e37c51282b772e064ed`. Apple notarisation `484f0164-7fbc-4c73-9d13-ead75f5b0ccd` is Accepted; Developer ID team 5NF98M544G, stapled ticket and Gatekeeper pass. The full Swift suite (745 tests, 13 fixture-dependent skips, 0 failures) and 93 Python tests passed on the bundle source.

**Change.** Only VSDX package writing changed since 0.23.4: every VSDX drawing now carries a minimal `visio/windows.xml` part, without which Visio 2019 refuses the file. The source diff is VisioFormat.swift +1 and VisioPreservation.swift +23 lines. All bundled frameworks and helpers are byte-identical to 0.23.4 once code signatures are removed; only the main executable, Info.plist and CodeResources differ. Security, keyboard and content-rights evidence is carried forward on that basis and recorded as such.

**Updates.** The official Sparkle CLI updated a copy of the exact accepted 0.23.4 app through signed loopback feeds. A tampered feed, a tampered archive and an interrupted download were each rejected with the prior bundle and test document unchanged; the valid feed then installed the exact 0.23.5 bundle. A second install preserved appearance, library, recents, pins, removals, update preferences and document bytes. Codesign and Gatekeeper pass on the installed copy.

**Native check.** Computer use drove the updated 0.23.5 app: it opened an 8-shape, 8-connector flow, changed a label through the inspector, saved, closed without a prompt, reopened with the label intact and quit normally. Visio Professional 2019 16.0.10730.20102 opened that saved file with the edited label. Clicking a Recent row on the Home window did not open the drawing; this is recorded for follow-up and the reopen used Finder.

**Visio.** In the Windows 11 ARM64 reference (unactivated Visio 2019), all seven synthetic VSDX fixtures pass open, inspection, text edit, Save As, reopen, PDF and SVG with no comparator differences. Experimental binary VSD output still fails to open and is outside the declared slice. See [Windows validation](../WINDOWS-VALIDATION.md).

**Performance exception.** The owner replied: **"Yes to both, publish with performance exception."** The archive hash above is pinned in the release policy. The manifest keeps `controlled-latency: waived_by_owner` and `accepted_with_exception`; the 50 ms input and 33 ms frame targets remain unqualified and no performance pass is claimed. Japanese and VoiceOver testing remain excluded by user instruction.

Gate records and retained evidence are under `build/releases/stable-candidates/0.23.5/`; raw candidate, notarisation, updater and native records are under `build/stable-0.23.5/`. These remain local.
