# Theme quick-style reference (WP-17-T03)

`Probe-VisioQuickStyles.ps1` applies three Visio 2019 themes (Office Theme, Linear, Integral) to a
rectangle and sweeps QuickStyleFill/Line/FontColor (0-8, 100, 200) and QuickStyleFill/Line/FontMatrix
(0-6, 100), plus QuickStyleVariation 0-3, recording the colors Visio resolves for THEMEVAL() fill,
line and text cells (`quickstyles.json`, the saved drawings carry each theme).

Rules MacVisio implements from it (`VisioQuickStyleReferenceTests`, 738 colors, all agree):

- Color selector: 0 dk1, 1 lt1, 2-7 accent1-6, 8 background, 100-106 and 200-206 variant colors;
  a monotone variation uses its first color for every variant selector.
- Matrix 1-6 indexes the theme's fillStyleLst, lnStyleLst and Visio fontStyles extension (connector
  scheme lists for connectors); 100-103 take the variation style's fill/line/font index; 0 is the
  classic root style.
- DrawingML shade and tint work in linear light; lumMod, lumOff and satMod work in HSL kept in
  1/100000 units; gradient fills report the placeholder color.
- QuickStyleVariation bit 2 replaces light text with the darker of the line and fill colors.

Import resolves Visio's `Themed` caches through these rules, so themed Visio drawings show Visio's
colors (`macvisio-flowchart.png`).
