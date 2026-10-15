# Editor appearance and ribbon

Local build 0.22.0 adds a desktop Visio-style ribbon, Shapes pane, Format Shape / Format Page pane, horizontal and vertical rulers, scrolling page tabs, and a status/zoom strip. Commands use the existing native editor actions. The ribbon has File, Home, Insert, Design, Data, Review, and View tabs; it exposes the supported MacVisio commands rather than implementing additional Visio features merely by adding a tab.

Dark appearance is the default. Choose **View > Appearance > Dark, Light, or System** in the ribbon. The choice is stored in `MacVisioAppearance` and applies to all document windows; System follows macOS. Native controls and custom pane, ruler, stencil-label, and page-tab colors adapt together. The drawing paper stays white. Changing app appearance does not recolor shapes, change the document, or change exported SVG/PDF content.

The arrangement follows Microsoft's documented [Visio ribbon and Shapes-window workflow](https://support.microsoft.com/en-us/visio/beginner-tutorial-for-visio). It is a native AppKit adaptation; exact Windows pixel equivalence and full Visio command parity are not claimed.

The combined Swift suite passes 378 tests. `EditorChromeTests` exercises actual ribbon tool actions, bold formatting with Undo, tab switching, selection-dependent controls, and appearance switching with unchanged diagram/SVG output. Native renders cover Dark, Light, View, and the minimum 1000-by-680 content size. Render a review image without changing the saved appearance preference:

```sh
build/MacVisio.app/Contents/MacOS/MacVisio --render-ui build/dark-ui-home.png --appearance dark
build/MacVisio.app/Contents/MacOS/MacVisio --render-ui build/light-ui-home.png --appearance light
build/MacVisio.app/Contents/MacOS/MacVisio --render-ui build/dark-ui-compact.png --appearance dark --compact-ui
build/MacVisio.app/Contents/MacOS/MacVisio --render-ui build/dark-ui-view.png --appearance dark --ribbon-tab View
```

The 0.22.0 packaged app passes bundle signature/dependency verification, independent VSD/VSDX conversion checks, and the native launch diagnostic including foreground Save routing. Local reports are `build/dark-ui-tests.log`, `build/dark-ui-bundle-verification.log`, and `build/dark-ui-launch-check.json`. These checks do not establish Microsoft Visio acceptance or full feature parity.
