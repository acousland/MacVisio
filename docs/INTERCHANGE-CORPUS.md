# Public-content Windows comparison corpus

`MacVisio --prepare-interchange-fixtures NEW_EMPTY_DIRECTORY` generates seven synthetic drawings in both VSDX and experimental VSD, plus a JSON manifest. It refuses a nonempty destination. The cases cover the five native templates, shared background pages, and a separate groups/ports/Unicode/Shape Data/layers/scaled-page example. No user document or installer asset is copied into this corpus.

The VSDX files omit `macvisio/document.json` and its package relationship. The VSD files omit `MacVisioModel`. Thus neither a native reopen nor the Windows comparison can use private metadata to conceal missing public graphics or semantics. The manifest records file hashes and expected page/shape content taken directly from the authored VSDX XML. Binary expectations deliberately omit cells whose full binary semantics are not yet implemented. These expectations are test inputs, not Windows results.

Use the isolated development app rather than overwriting an app that is already running:

```sh
MACVISIO_APP_DIR="$PWD/build/Compatibility/MacVisio.app" scripts/build-app.sh
build/Compatibility/MacVisio.app/Contents/MacOS/MacVisio --prepare-interchange-fixtures build/WindowsValidation/fixtures
```

The Windows runner described in [WINDOWS-VALIDATION.md](WINDOWS-VALIDATION.md) should open each input in actual Microsoft Visio, record its version and public contents, edit only the isolated synthetic document, save/close/reopen, and collect errors per phase. A COM call returning successfully alone does not establish appearance or full behavior.

For a VSDX saved without intentional content edits, compare its direct cached public values:

```sh
python3 scripts/compare-vsdx.py build/WindowsValidation/fixtures/flowchart.vsdx build/WindowsValidation/results/flowchart.vsdx --report build/WindowsValidation/flowchart-comparison.json
```

The comparison tool checks page identity/name/background linkage and explicitly authored dimensions/scale; shape identity/group parentage/text and explicitly authored transform cells. It follows OPC relationships and ignores MacVisio metadata. It exits 0 for a match, 1 for differences, or 2 for an invalid input/error. Detailed reports can contain drawing text, so keep reports from private drawings local. Its normal terminal output prints counts only.

This bounded comparison does not evaluate inherited masters/styles, all formulas, fields, themes, geometry rows, data/glue semantics or rendering. Differences may need interpretation when Visio moves a value into an inherited definition or normalizes text. Do not interpret a match as complete file compatibility. Binary public parsing and actual Windows acceptance are separate checks.
