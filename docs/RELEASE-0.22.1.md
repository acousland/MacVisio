MacVisio 0.22.1 fixes missing group labels and improves VSDX opening performance.

- Group shapes honor cached Visio DisplayMode settings. Group labels render above member backgrounds when the group is in front; nested groups retain sibling order. The canvas and PNG/PDF/SVG exports share this ordering.
- Cached HideText values suppress hidden labels while retaining their source text.
- Per-import style caches avoid repeatedly resolving the same line, fill, and text style chains. A local three-page drawing opens and renders its first viewport in about 1.9 seconds, compared with 4.3 seconds in 0.22.0 (three runs per build on the same machine).
- Successful opens no longer show a blocking compatibility sheet. Use **Import notes** in the status bar to review retained compatibility warnings.

Validation: 387 Swift tests, including raster group-label regressions, style isolation, nested groups, and group display modes. All three pages of the affected drawing were rendered locally; an unchanged save preserves every original package part. Private drawings and previews are excluded from the repository and release.

Requires Apple Silicon and macOS 27 or newer. Expand the ZIP and move MacVisio.app to Applications, or use **MacVisio > Check for Updates…**.

Full Visio feature parity remains unfinished. Advanced layout and unsupported features may still differ; binary VSD writing remains experimental.
