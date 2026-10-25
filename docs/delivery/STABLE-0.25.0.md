# MacVisio 0.25.0 stable release candidate

0.25.0 (build 33) is the first M3 increment. It targets Apple Silicon on the stable channel, requires macOS 27.0.1 or later, and is served by the latest-release Sparkle feed. M3/G2 is not accepted by this release.

Archive: `build/releases/stable-candidates/0.25.0/MacVisio-0.25.0.zip`, SHA-256 `a42415475b79e761c8c8d9aacf84d2949a97e45449c1577289144b091c1e74db`.

**Build and signing.** The bundle was built from `a9c03994c575d21a12c0e35423db63ab652bcf58` and signed with Developer ID team 5NF98M544G. Apple notarisation `3fff8a15-228a-4566-ae68-211baef69eb3` was accepted, the ticket is stapled and Gatekeeper passes. On the bundle source, 1,165 Swift tests passed with 13 fixture-dependent skips and no failures, and 115 Python tests passed.

**Gates.** All six were accepted with no exceptions.

- **Platform / native.** On the 0.25.0 app installed by Sparkle from 0.24.0, the Visio 2019-authored flowchart:
  - had a Process shape added through Shape > Insert Process;
  - saved in place through File > Save, closed through File > Close, and reopened by clicking its Home Recent row (6 shapes, 4 connectors);
  - opened in Visio 2019 with 6 shapes, 4 connectors and 8 connections.
- **Installed update.** The exact published 0.24.0 app:
  - rejected a tampered feed and a tampered archive, and was unharmed by an interrupted download;
  - then installed the exact 0.25.0 bundle;
  - kept its settings and document bytes. Codesign and Gatekeeper pass.
- **Performance.** MV-NFR-02 ran three times on the signed executable. Drag p95 was 30.9–31.2 ms and pan p95 32.3–33.2 ms, against a 50 ms target; frame p95 was 16.7 ms against 33 ms. For save interruption, 40 of 40 trials kept the previous file or produced a readable new one.
- **Compatibility.**
  - Candidate-generated fixtures pass every phase in Visio Professional 2019 16.0.10730.20102: 7/7 VSDX, with glue and 0 differences.
  - Visio's saved copies reimport identically.
  - Binary VSD remains experimental and outside the declared slice.
  - M3 reference results on the bundle source:
    - 2,383 formula and field cases: 2,316 agree, 67 disposed.
    - 22 round-trip outputs and 9 authored drawings: 0 differences.
    - 738 quick-style colours agree.
    - The host matrix records 53 open findings, which are not claimed.
- **Security / content rights.** Reading limits are unchanged. Bundled third-party files are byte-identical to 0.24.0 apart from code signatures.

**Superseded candidate.** Build 32 was not published. Its native check found that an ordinary Save of a Visio stencil drawing was refused after inserting a shape, which was fixed in `5987a22`.

**Scope exclusions.** Accessibility is out of scope ([SD-2026-10-24-01](../evidence/decisions/SD-2026-10-24-01-accessibility.md)). Japanese input is untested ([SD-2026-10-24-02](../evidence/decisions/SD-2026-10-24-02-japanese-input.md)).

Raw records are kept under `build/stable-0.25.0/`.
