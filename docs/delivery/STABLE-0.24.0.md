# MacVisio 0.24.0 stable release candidate

Version 0.24.0/build 31, Apple Silicon, macOS 27.0.1 minimum, stable channel and latest-release Sparkle feed. Completes M0–M2.

Archive: `build/releases/stable-candidates/0.24.0/MacVisio-0.24.0.zip`, SHA-256 `6f070640a6b9e30cd46f239cd97dd69b14e747ea78eb7c0612fc55d9d8ad9fff`.

Bundle source `8653334c672e5a4e5318a94ed2c162ccbe6d1551` (also `main`). Apple notarisation `608004be-8d37-4b31-8373-a7b75343f4b5` Accepted; Developer ID team 5NF98M544G; stapled; Gatekeeper passes. 755 Swift tests (13 fixture-dependent skips, 0 failures) and 100 Python tests passed on the bundle source.

**Gates — all accepted, no exceptions.**

- *Platform / native:* the Sparkle-installed 0.24.0 app opened a drawing saved by MacVisio 0.23.x, rotated a shape through the Shape menu, saved and closed through the File menu, and reopened it by clicking its Home Recent row. The saved file gained Visio glue on all 8 connectors (16 triggers); Visio 2019 opened it with 16 connections and the rotated shape.
- *Installed update:* the exact published 0.23.5 app rejected a tampered feed, a tampered archive and an interrupted download with its bundle and test document unchanged, then installed the exact 0.24.0 bundle; settings and document bytes were preserved; codesign and Gatekeeper pass.
- *Performance:* MV-NFR-02 on the signed candidate executable, three runs: drag p95 41.8–42.3 ms, pan p95 32.3 ms, frame p95 16.7 ms (targets 50/33 ms). Save interruption: 40/40 trials kept the previous file or produced a readable new one. See [M2-PERFORMANCE](M2-PERFORMANCE.md).
- *Compatibility:* candidate-generated fixtures pass all phases in Visio Professional 2019 16.0.10730.20102 with glue and 0 differences (7/7 VSDX), and Visio's saved copies reimport identically. Binary VSD remains experimental and outside the declared slice.
- *Security / content rights:* reading limits unchanged and covered by the suite; bundled third-party content byte-identical to 0.23.5 apart from signatures.

Accessibility is out of scope ([SD-2026-10-24-01](../evidence/decisions/SD-2026-10-24-01-accessibility.md)); Japanese input is untested ([SD-2026-10-24-02](../evidence/decisions/SD-2026-10-24-02-japanese-input.md)). Two earlier 0.24.0 candidates were superseded before publication: the first edited legacy drawings without upgrading their glue, the second showed a stretched Recent-row menu. Raw records stay under `build/stable-0.24.0/`.
