# Public synthetic M3 discovery fixture

`m3-intelligent.vsdx` is authored by `scripts/m3-public-evidence.py generate`.
It contains no user content, Microsoft stencil content, or native MacVisio metadata.
The adjacent manifest uses the committed M0 synthetic Windows runner schema,
including optional master/formula/data/glue checks. Page `name` expectations use
the runner's universal `NameU` contract; display names are retained separately in
public XML. Expected
text, dimensions and identities are authored in the generator, independently of
MacVisio's serializer and reopen model.

Two masters and two styles deliberately share display names but have distinct
IDs and universal names. Instances exercise inherited geometry, properties,
controls and named ports; local overrides; cross-shape formulas; mixed Unicode
text and character runs; an intelligent connector sheet with its own formula;
an Office theme; background links, scale and a nonprinting layer; and an opaque
public payload. This bounded fixture does not cover every M3 catalog entry.

`m3-physical.vsdx` independently authors a 1000 mm object at 1:50 on A4 paper,
with a visible nonprinting guide. Its expected output width is 20 mm at printer
scale 100%. The local Swift check measures page dimensions and the black object's
width in a rendered PDF; calibrated physical printing remains pending.

Run `python3 scripts/m3-public-evidence.py compare BEFORE.vsdx AFTER.vsdx` for
public structural differences (exit 1 means content changed). This is a strict
preservation oracle; reference Visio may legitimately rewrite formulas/structure.
Every such change needs a semantic or reference disposition, never automatic
acceptance. The oracle does not evaluate formulas or compare rendered output.
Local preservation and fixture mutation checks do not accept M3/G2.

Reference schema/design sources:

- [Microsoft: Masters element](https://learn.microsoft.com/en-us/office/client-developer/visio/masters-elementvisio-xml)
- [Microsoft: FormatScheme](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.drawing.formatscheme)
- [Microsoft: ThemeElements](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.drawing.themeelements)

Real exact-build Visio open/edit/save/reopen, repair-prompt checks, fonts,
rendered comparisons and bidirectional behavior remain pending. This is an
authored acceptance input, not a claim that a schema validator or Visio accepted it.
