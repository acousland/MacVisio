# Mixed text editing and interchange

Version 0.10 retains indexed character and paragraph runs rather than reducing text to the first style. Supported character properties are font family, size, color/transparency, bold, italic, underline and strikethrough. Paragraph alignment is retained per run. Other cached row cells remain available for source-preserving saves; their retention does not implement their behavior.

Double-click a shape, select characters and use Command-B/I/U or Shape > Text Format > Show Fonts. The inline editor uses native attributed text with its own text Undo. Committing adds one document-level edit. Inspector formatting applies across the shape's runs. Numeric `Char.Size` calculation changes the default character row without flattening different styles. Plain text assignments retain unchanged prefix/suffix styles and inherit adjacent formatting for inserted characters.

## Public file behavior

VSDX `cp` and `pp` markers select character and paragraph row indexes. These are imported with local/master/style-sheet inheritance, including sparse indexes and Unicode text. Mixed styles survive fresh public exports after removing private metadata, supported source edits, master instances and native recovery. Unchanged source package parts retain their bytes. Unknown character/paragraph cells and unedited master definitions remain preserved.

Modern FaceName entries use required `NameU` attributes and are indexed by their order. Older MacVisio ID/Name declarations are accepted on read. Earlier code used the older declaration form and could lose font names in independent readers. Older private VSDX metadata is bypassed when it would conceal mixed text or modern font declarations. Pre-0.10 native JSON does not automatically reconstruct every old formatting cache; reimport the original public VSDX to recover it.

Fresh exports emit sequential character/paragraph rows for text segments. This also avoids the bundled reader's aggregation of reused indexes. Source-preserving edits retain existing row identities and fork partial formatting, preserving untouched formulas. The independent reader's handling of sparse/reused source indexes is limited; tests of those edits use public XML reimport, while independent checks cover fresh output. Windows Visio validation remains outstanding.

Foundation's XMLDocument drops whitespace-only text nodes even with preservation options. A bounded, non-executing XMLParser reconstructs ordered Text children so paragraph breaks between run markers survive unrelated geometry edits and metadata synchronization. External entities and DTDs remain rejected.

Experimental binary VSD emits multiple public character/paragraph records with UTF-16 counts and a shared font table. Legacy graphics import retains supported styles from the converter's SVG spans. Full original binary formulas, fields, data and glue remain incomplete. PNG/PDF rendering uses attributed text; mixed SVG output uses native line layout and styled spans in physical paper units.

## Evidence and remaining work

Seventeen additional tests bring the complete suite to 186 passing tests. They cover sparse public rows, Unicode, byte preservation, native JSON, public reimport without private metadata, partial formatting and opaque cells, paper font size during editing, text/document Undo, whole-shape formatting, independent VSDX/VSD styles, old metadata, rendered formats, ordinal fonts, untouched guarded rows, repeated native saves, paragraph-break preservation, inherited master text, default-character formulas, empty-text editing and a physical raster comparison at scale 1:50.

`Examples/RichText/project-handover` supplies native/VSDX/VSD/VSTX, PNG/SVG and a two-page PDF. Its second page uses scale 1:50. The native hierarchy render is [rich-text-editor-preview.png](rich-text-editor-preview.png). It shows bold/color/underline/italic/monospaced styles and paragraph alignment; it is an application-generated render, not a manual UI test.

Fields and their formatting, custom tabs, bullets, complete indentation/spacing, advanced character effects, right-to-left/complex-script parity, connector rich text, all indexed ShapeSheet text formulas and exact Windows layout remain required work. Fonts unavailable on this Mac may be substituted. Full Visio parity is not established by these checks.

## Primary references

- [Microsoft VSDX text runs](https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-vsdx/9aec7e65-2abe-4518-aaa7-650e2fd6ceff)
- [Character marker and row index](https://learn.microsoft.com/en-us/office/client-developer/visio/cp-element-text_type-complextypevisio-xml)
- [Character properties](https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-vsdx/c5dd2836-96ad-4795-9dc4-58db5ab84015)
- [Modern FaceName declaration](https://learn.microsoft.com/en-us/office/client-developer/visio/facename-element-facenames_type-complextypevisio-xml)
- The pinned libvisio source in `build/third-party/libvisio` supplies independent reader evidence, including font lookup and binary character record layout. No Windows runtime was observed.
