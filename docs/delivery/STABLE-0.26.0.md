# MacVisio 0.26.0 stable release candidate

0.26.0 (build 34) lays out the editor like Visio 2019. It targets Apple Silicon on the stable channel, requires macOS 27.0.1 or later, and is served by the latest-release Sparkle feed. Interchange behaviour is unchanged from 0.25.0 and was re-verified.

Archive: `build/releases/stable-candidates/0.26.0/MacVisio-0.26.0.zip`, SHA-256 `e4a6cedebab41e7daf4cfa76820043ae3cb2e8fcce1a2d7abf357aa340fce92c`.

**Build and signing.** The bundle was built from `431bb6841161be25e092a70c1ceb4901a9a0ce98` and signed with Developer ID team 5NF98M544G. Apple notarisation `f99a2075-04cf-44ac-b662-73a600f6e263` was accepted, the ticket is stapled and Gatekeeper passes. On the bundle source, 1,169 Swift tests passed with 13 fixture-dependent skips and no failures, and 115 Python tests passed.

**Gates.** All six were accepted with no exceptions.

- **Platform / native.** On the 0.26.0 app installed by Sparkle from 0.25.0, the Visio 2019-authored flowchart:
  - had a shape added through the ribbon's Home > Tools > Rectangle;
  - saved in place through File view > Save, closed through File view > Close, and reopened by clicking its Home Recent row (6 shapes, 4 connectors);
  - opened in Visio 2019 with 6 shapes, 4 connectors and 8 connections.
- **Installed update.** The exact published 0.25.0 app:
  - rejected a tampered feed and a tampered archive, and was unharmed by an interrupted download;
  - then installed the exact 0.26.0 bundle;
  - kept its settings and document bytes. Codesign and Gatekeeper pass.
- **Performance.** MV-NFR-02 ran three times on the signed executable. Drag p95 was 41.0–41.8 ms and pan p95 32.3–32.4 ms, against a 50 ms target; frame p95 was 16.7 ms against 33 ms. For save interruption, 40 of 40 trials kept the previous file or produced a readable new one.
- **Compatibility.** Candidate-generated fixtures pass every phase in Visio Professional 2019 16.0.10730.20102: 7/7 VSDX, with glue and 0 differences. Visio's saved copies reimport identically. Binary VSD remains experimental and outside the declared slice.
- **Security / content rights.** Reading limits are unchanged. Bundled third-party files are byte-identical to 0.25.0 apart from code signatures.

**Interface scope.** The ribbon's tabs, groups and commands match Visio 2019's by name and order, checked against an inventory captured from Visio's UI Automation tree. Of Visio's 137 ribbon commands, 52 are available and the rest are shown unavailable. MacVisio's icons are its own.

**Scope exclusions.** Accessibility is out of scope ([SD-2026-10-24-01](../evidence/decisions/SD-2026-10-24-01-accessibility.md)). Japanese input is untested ([SD-2026-10-24-02](../evidence/decisions/SD-2026-10-24-02-japanese-input.md)).

Raw records are kept under `build/stable-0.26.0/`.
