MacVisio 0.22.0 adds a dark editor theme and a Visio-style ribbon with File, Home, Insert, Design, Data, Review, and View tabs.

- Choose Dark, Light, or System under **View > Appearance**. The choice applies across document windows; drawing and export colors stay unchanged.
- Updated Shapes and Format panes, horizontal/vertical rulers, scrolling page tabs, and selection-aware native editing controls.
- Selected `THEMEVAL` line weights/caps and bounded `BITAND`, `BITOR`, and `BITXOR` calculations.
- Experimental binary VSD exports include 1-D connector markers and endpoint coordinates, including grouped connectors. Older native documents remain readable after the theme metadata update.

Validation: 378 Swift tests, independent VSD/VSDX conversion/rendering checks, and native launch/Save routing checks pass. The download and Sparkle feed are signed.

Requires Apple Silicon and macOS 27 or newer. Expand the ZIP and move MacVisio.app to Applications, or use **MacVisio > Check for Updates…**.

Full Visio feature parity remains unfinished. Binary VSD writing is experimental; endpoint glue and Microsoft Visio open/edit/save acceptance remain unverified.
