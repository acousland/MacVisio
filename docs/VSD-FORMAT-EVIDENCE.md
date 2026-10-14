# VSD v11 binary format evidence

This ledger records source-derived reader behavior and observations from real VSD files. It guides a binary serializer prototype. It is **not** a Microsoft format specification or evidence that Microsoft Visio accepts generated files. No Windows Visio runtime was available for these observations. Unknown fields and shorter, parser-sufficient payloads must not be described as validated Windows output.

## Provenance and reproduction boundary

The local reference source is `build/third-party/libvisio`, commit `d6c9d6492131dbb8bb568e1d38b38890ae2a865a`. Source links in this ledger use this commit so line references remain stable:

- [VSDParser.cpp](https://github.com/LibreOffice/libvisio/blob/d6c9d6492131dbb8bb568e1d38b38890ae2a865a/src/lib/VSDParser.cpp)
- [VSDDocumentStructure.h](https://github.com/LibreOffice/libvisio/blob/d6c9d6492131dbb8bb568e1d38b38890ae2a865a/src/lib/VSDDocumentStructure.h)
- [VisioDocument.cpp](https://github.com/LibreOffice/libvisio/blob/d6c9d6492131dbb8bb568e1d38b38890ae2a865a/src/lib/VisioDocument.cpp)
- [VSDInternalStream.cpp](https://github.com/LibreOffice/libvisio/blob/d6c9d6492131dbb8bb568e1d38b38890ae2a865a/src/lib/VSDInternalStream.cpp)

All scalar offsets below are decimal and relative to a payload, unless prefixed `0x` or explicitly identified as stream offsets. Integers are little endian; doubles are IEEE 754 binary64 little endian. A source reader skipping a byte does not establish that byte's Windows meaning.

| Fixture | Local path | SHA-256 |
|---|---|---|
| FormatLine | `Tests/MacVisioTests/Fixtures/Visio11FormatLine.vsd` | `55ca3aae6fe1ac96150cea0783aeac8059eee2575c0c46760fd9f7828fa683bd` |
| NoBg | `Tests/MacVisioTests/Fixtures/no-bgcolor.vsd` | `e114f8252a297964a63b2390b76447ac81de5fc3190cf9b54f9caa86cdb531aa` |
| Plan | `build/third-party/libvisio/src/test/data/Visio11PlanWithDimensions.vsd` | `8fbd687000f3b7d3d3d409ff2e1a4a4ab95f5c38f5c6ca734ac3799a2b504a87` |

The fixtures were inspected by a bounded, read-only Python CFB/FAT/miniFAT reader and the decompression algorithm transcribed from `VSDInternalStream.cpp`. File hashes above bind the observations. Payload offsets are in decompressed internal streams; they are not CFB physical-file offsets. No fixture was modified.

## CFB and document header

**Observed in all three files:** CFB sector size 512, mini-sector size 64. The root directory entry CLSID is `00021a14-0000-0000-c000-000000000046`, with stored bytes:

```text
14 1a 02 00 00 00 00 00 c0 00 00 00 00 00 00 46
```

The CFB header CLSID at file offset 8 is all zero. Each file has streams `VisioDocument`, `VisioInformation`, `\x05SummaryInformation`, and `\x05DocumentSummaryInformation`. The two property streams were not analyzed here. `VisioInformation` is exactly 28 bytes, identical in all three fixtures:

```text
fe ff 00 00 04 00 02 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00
```

**Source established:** `VisioDocument.cpp:29–70` checks 21 magic bytes (`Visio (TM) Drawing\r\n\0`) and version byte at `0x1a`; version 11 selects `VSDParser` at lines 87–105. `VSDParser.cpp:113–125` seeks to a trailer pointer at `0x24`. Neither `VisioInformation` nor root CLSID is consulted by this binary reader. Whether Windows requires them is unverified.

| VisioDocument offset | Observed value / interpretation |
|---|---|
| `0x00..0x14` | 21-byte magic above; source checked |
| `0x15..0x19` | Zero in all three fixtures |
| `0x1a` | `0b` version; source checked |
| `0x1b` | Zero |
| `0x1c` | u32 exactly equal to VisioDocument stream length: FormatLine 47689, NoBg 31683, Plan 197784; inferred stream-size field |
| `0x20..0x23` | `00 84 01 00` in all three; semantics unknown |
| `0x24..0x35` | 18-byte trailer pointer; source checked |
| `0x36..0x7f` | Variable and partly pointer-looking bytes; semantics unknown. The reference reader does not use them. |

Full first `0x80` VisioDocument bytes, preserved as evidence rather than a template:

```text
FormatLine:
00 56 69 73 69 6f 20 28 54 4d 29 20 44 72 61 77 69
10 6e 67 0d 0a 00 00 00 00 00 00 0b 00 49 ba 00 00
20 00 84 01 00 14 00 00 00 bc ca 01 0d fb b8 00 00
30 4e 01 00 00 52 00 00 00 00 00 00 00 00 00 00 00
40 00 00 00 00 00 00 00 00 e3 37 08 77 00 c5 d0 08
50 88 fc 7c 0e 34 00 00 c0 00 00 00 00 08 00 00 00
60 d8 e5 7c 0e 37 fb 42 10 e3 37 08 77 60 2d 26 5b
70 00 ba d0 08 01 00 00 00 e3 37 08 77 60 2d 26 5b

NoBg:
00 56 69 73 69 6f 20 28 54 4d 29 20 44 72 61 77 69
10 6e 67 0d 0a 00 00 00 00 00 00 0b 00 c3 7b 00 00
20 00 84 01 00 14 00 00 00 84 b3 9f 10 7a 7a 00 00
30 49 01 00 00 52 00 00 00 00 00 34 00 b6 36 a3 78
40 18 00 00 00 5c a0 04 60 00 b0 9c 0f b6 36 a3 78
50 c8 73 ab 0f 6c 89 33 00 01 00 00 00 a8 1b ab 0f
60 02 00 00 00 b0 89 33 00 bb 38 58 78 7c 3c a4 78
70 18 00 00 00 bb 38 58 78 00 00 34 00 00 00 00 00

Plan:
00 56 69 73 69 6f 20 28 54 4d 29 20 44 72 61 77 69
10 6e 67 0d 0a 00 00 00 00 00 00 0b 00 98 04 03 00
20 00 84 01 00 14 00 00 00 a4 d7 8f 01 45 03 03 00
30 53 01 00 00 52 00 00 00 00 00 27 04 02 00 00 00
40 48 fe 27 04 20 1a 25 37 38 fe 27 04 20 1a 25 37
50 6f f5 18 37 48 fe 27 04 30 1a 25 37 02 00 00 00
60 f4 02 19 37 00 00 3e 00 01 00 00 00 00 10 3f 00
70 02 10 00 00 00 00 3e 00 02 10 00 00 90 0f b6 04
```

## Pointers and pointer-table containers

`VSDParser.cpp:199–217,219–290,294–368` establishes:

```text
Pointer (18 bytes):
  +0  u32 Type
  +4  u32 unknown (reader skips; fixture often looks like an address)
  +8  u32 Offset (relative to VisioDocument stream)
  +12 u32 Length (stored stream length)
  +16 u16 Format
```

`Format & 2` selects compression. The high nibble selects processing: `0,4` blob, `5` blob then pointer table, `8,c,d` chunk stream. A Page pointer's low bit marks foreground (1) versus background (0); source at lines 312–320. Compression uses the LZSS variant in `VSDInternalStream.cpp:20–79`; uncompressed output can avoid this step.

For a pointer container, set `shift = compressed ? 4 : 0`. At decompressed offset `shift`, read u32 `O`. The pointer metadata is at `O+shift-4`: u32 listSize, s32 pointerCount, u32 skipped/reserved, then `pointerCount` 18-byte pointers. If listSize > 1, that many u32 pointer indices follow, defining order. If listSize <= 1, the parser reads no order and iterates pointer indices. Type-zero pointers are ignored.

**Observed FormatLine pointers:** trailer at `VisioDocument+0x24`: type `0x14`, offset `0xb8fb`, length334, format`0x52`; decompressed632. Its index13 points to Pages. Pages index0 points to its foreground Page:

| Type | Offset | Stored length | Format | Decompressed length |
|---|---|---:|---|---:|
| Pages `0x27` | `0x84b7` | 104 | `0x54` | 104 |
| Page `0x15` | `0x1bad` | 26658 | `0xd7` | 138305 |
| FontFaces `0xd8` | `0x8b88` | 482 | `0x54` | 482 |
| FontFace `0xd7`, index4 Calibri | `0x8695` | 60 | `0x42` | 110 |

FormatLine Pages bytes begin:

```text
14 00 00 00 5c 00 00 00 00 00 00 00 00 00 00 00
01 00 00 00 04 00 00 00 00 00 00 00
15 00 00 00 e4 27 fb 0e ad 1b 00 00 22 68 00 00 d7 00
```

Thus O=20, metadata at16, listSize1, pointerCount4, reserved0, first pointer at28. A minimal equivalent container can place metadata at4 (O=8), then pointer records at16. That is a source-based construction, not an observed fixture layout or verified Windows layout.

## Chunk header, trailers, and levels

`VSDParser.cpp:50–103,424–444` defines a 19-byte chunk header:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | u32 | chunkType |
| 4 | u32 | id |
| 8 | u32 | list (often next available child row ID; meaning inferred from gaps) |
| 12 | u32 | dataLength |
| 16 | u16 | relative level |
| 18 | u8 | unknown/format byte |

The parser adds the enclosing stream level **after** computing trailer length. It seeks to `headerStart+19+dataLength+trailerLength` after each chunk. Leading zero padding is skipped. There is no observed alignment padding requirement between these chunks.

Trailer length algorithm, exactly reflecting the reader:

```text
T = 8 if list != 0 or type in {71,70,6b,6a,69,66,65,2c} else 0
if list != 0
   or (relativeLevel == 2 and unknown == 55)
   or (relativeLevel == 2 and unknown == 54 and type == aa)
   or (relativeLevel == 3 and unknown not in {50,54}): T += 4
if type in {64,65,66,69,6a,6b,6f,71,92,a9,b4,b6,b9,c7}
   and T not in {12,4}: T += 4
if type in {1f,c9,2d,d1}: T = 0
```

Types/unknown bytes in that pseudocode are hexadecimal. Some trailer bytes belong to the list's logical child data; they cannot all be replaced with zeros.

**Observed FormatLine Page stream hierarchy**, all offsets in its decompressed Page stream:

| Offset | Type | ID | List | Data bytes | Relative level | Unknown | Trailer bytes |
|---|---|---:|---:|---:|---:|---|---:|
| `0x0000` | Page `15` | FFFFFFFF | 106 | 96 | 0 | 00 | 12 |
| `0x007f` | PageSheet `46` | 0 | 4 | 68 | 1 | d6 | 12 |
| `0x00e2` | PropList `68` | 0 | 3 | 36 | 2 | 54 | 12 |
| `0x0125` | PageProps `92` | 0 | 0 | 132 | 3 | 55 | 4 |
| `0x01c0` | XForm `9b` | 1 | 0 | 145 | 3 | 55 | 4 |
| `0x03c7` | ShapeList `65` | 2 | 105 | 424 | 2 | 54 | 12 |
| `0x058e` | ShapeID `83` | 0 | 0 | 10 | 3 | 55 | 4 |
| `0x12b0` | Shape `48` | 1 | 5 | 72 | 1 | 54 | 12 |
| `0x154b` | Line `85` | 4 | 0 | 132 | 3 | 55 | 4 |
| `0x1742` | GeomList `6c` | 4 | 4 | 40 | 2 | 55 | 12 |
| `0x1789` | Geometry `89` | 0 | 0 | 3 | 3 | 55 | 4 |
| `0x17a3` | MoveTo `8a` | 1 | 0 | 20 | 3 | 55 | 4 |
| `0x17ce` | LineTo `8b` | 2 | 0 | 20 | 3 | 55 | 4 |
| `0x37eb` | Text `0e` | 2 | 0 | 26 | 2 | 50 | 0 |
| `0x3818` | CharList `69` | 3 | 1 | 28 | 2 | 54 | 12 |
| `0x3853` | CharIX `94` | 0 | 0 | 88 | 3 | 55 | 4 |

The omitted entries between these offsets are other rows and shapes. PageSheet in Plan uses unknown54, so d6 is not universal. NoBg nested shape chunks are also level1: Group1 parent0, Shape2 parent1. Plan has Group1 parent0, Group2 parent1, Shape3 parent2, each at level1. Parent IDs, rather than relative chunk nesting, encode group membership in these Page streams. Shape sections are at level2; their scalar/geometry/Char/Para rows are level3.

## Logical list bodies: the trailer carries child IDs

Source list readers: `VSDParser.cpp:916–986,1188–1209`; shape-order resolution: `VSDShapeList.cpp:46–87`.

The observed physical logical body of a list is:

```text
+0  u32 S (subHeaderLength, normally24 for section lists)
+4  u32 C (childrenListLength in bytes, normally4*N)
+8  S bytes of subheader
+8+S  C bytes of u32 child-row IDs
+8+S+C  u32 zero separator
```

The chunk's declared `dataLength` is **S+C**, while its physical body is **S+C+12**. This is why a 12-byte trailer exists. The subheader is measured from offset8, not from offset0. For standard section lists S24, observed subheader u32s at offsets8,12,16,20,24,28 are `0,0,0,N,header.list,0`. If row IDs have gaps, `header.list` may exceed N.

FormatLine GeomList at`0x1742`: S24,C16,N4,header.list4, declared length40. Logical children `[0,1,2,3]` start at offset32: first two are in declared data, final two in the trailer's first8 bytes. Trailer last4 is zero.

FormatLine CharList at`0x3818`: S24,C4,N1,header.list1,declared28. Its physical bytes:

```text
18 00 00 00 04 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 01 00 00 00 01 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00
```

The child row ID0 is at physical offset32 (trailer offset4). A generic serializer must construct the full logical body and then derive dataLength by subtracting12. Appending12zeros after an already complete list body changes parsing.

ShapeList order consists of **row IDs**, each resolved through a ShapeID chunk's payload. ShapeID has observed length10: u32 actual shape ID, u32 shape type (`48` or `47`), u16zero. Source only reads the first u32. In FormatLine the top-level ShapeList has100 order entries but list105, reflecting deleted/gapped row IDs. `getShapesOrder` falls back to ascending row-map order only when no explicit order exists; emit a proper ShapeList to preserve stacking order. A group's ShapeList describes its children; the PageSheet ShapeList describes top-level shapes.

## Page and shape fixed headers

All use the logical list-body convention above, but S is96 for Page and68 for PageSheet/Shape/Group. `readPage` only reads backgroundPageID@8 (`VSDParser.cpp:1074–1078`). `readPageSheet` consumes no payload (`1889–1893`). `readShape` reads only parent, masters and styles through offset54 (`1269–1297`). Other semantics below are observed or inferred explicitly.

**Page, FormatLine at Page stream`0x0000`:** S96,C0, declared96, physical108. Full physical body:

```text
60 00 00 00 00 00 00 00 ff ff ff ff 00 00 7e 10
13 38 00 00 00 00 00 00 00 00 71 3d 0a d7 a3 70
f9 3f 14 0a 85 42 a1 50 0e 40 ef a1 7b e8 1e 3a
20 40 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 ff ff ff ff ff ff ff ff 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
6a 00 00 00 00 00 00 00 00 00 00 00
```

Observed Page fields: @8 u32 FFFFFFFF (no background); @54..65 allzero; @66..73 eight FF; @74..95zero; @96 u32 header.list; @100 u32zero; @104 finalseparator. Earlier page bytes include plausible view coordinates but their meaning is not established. @96 is within the declared96-byte subheader measured from offset8 and is physically in the trailer, not a child ID.

**PageSheet, FormatLine at`0x007f`:** S68,C0,declared68,physical80. Its bytes@8..53 are:

```text
03 00 ff ff ff ff ff ff ff ff ff ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff 00 00 00 00 ff ff
ff ff 00 00 00 00 ff ff ff ff 00 00 00 00
```

@54..67zero; @68 u32header.list4; @72zero; @76separatorzero. Plan uses flagsu16@8=6 and list9. No runtime role for these flags is established.

**Shape/Group fixed fields** (source-established meanings marked S):

| Offset | Type | Evidence |
|---:|---|---|
| 0 | u32 | S68 observed |
| 4 | u32 | Children bytes C, commonly4 for Shape and0 for Group |
| 8 | u16 | Unknown flags; FormatLine Shape1 `0002`, NoBg Shape2 `0026`, Plan Shape3 `0008` |
| 10 | u32 | S: parent ID; 0 top-level, actual group ID for member |
| 14 | u32 | Observed equals shape ID in these fixtures; reader skips |
| 18 | u32 | S: master page index, or FFFFFFFF |
| 22 | u32 | FFFFFFFF observed; skipped |
| 26 | u32 | S: master shape ID, or FFFFFFFF |
| 30 | u32 | FFFFFFFF observed; skipped |
| 34 | u32 | S: fill style ID, FFFFFFFF for unspecified |
| 38 | u32 | FFFFFFFF observed; skipped |
| 42 | u32 | S: line style ID |
| 46 | u32 | FFFFFFFF observed; skipped |
| 50 | u32 | S: text style ID |
| 54 | u16 | Observed `0010` on FormatLine connector1; `0000` on NoBg shape2/Plan shape3/groups; inferred connector flag |
| 56 | 8 bytes | Zero in these samples |
| 64 | u32 | 1 on sampled ordinary Shapes with C4; 0 on sampled Groups with C0; unknown meaning |
| 68 | u32 | Observed equals header.list (next section ID inferred) |
| 72 | u32 | Zero observed |
| 76 | C bytes | Section child-row ID list; Shape samples C4 contain last geometry section ID, not every section |
| 76+C | u32 | Zero separator |

Thus a Shape with C4 has84 physical body bytes, `dataLength=72`; a Group with C0 has80 physical bytes, `dataLength=68`. A simpler C0 Shape also exists in NoBg (`Page+0x3be0`, len68). The section child list is not necessarily an exhaustive list of all parsed sections: reader sequentially processes chunks regardless.

## Parsed scalar payload schemas

Rows below are source-established reader offsets, with observed physical suffix lengths separately identified. A parsed-prefix minimum is **not** a validated Windows payload length. Units are display metadata: source comments establish cached spatial values are inches; font size is also in inches (e.g.12pt=1/6in). Observed unit bytes include `40` drawing units, `3f` page units, `30` type units, `32` points, `46` millimeters, `50` angle units. Their constants are in `VSDDocumentStructure.h:130–194`.

### XForm `9b`, TextXForm `9c`, XForm1D `9d`

`VSDParser.cpp:1127–1177`:

| Field | Unit-byte offset | Double offset |
|---|---:|---:|
| PinX | 0 | 1 |
| PinY | 9 | 10 |
| Width | 18 | 19 |
| Height | 27 | 28 |
| LocPinX | 36 | 37 |
| LocPinY | 45 | 46 |
| Angle (radians) | 54 | 55 |

XForm then flipX u8@63,flipY u8@64 (nonzero true). TextXForm stops before flips. Shortest observed XForm69bytes in NoBg: suffix@65..68=`00 01 0f 00`; other shapes include formula blocks after a fixed prefix. TextXForm shortest observed69bytes as well, though the reader only consumes63. XForm1D stores BeginX,BeginY,EndX,EndY as four successive unit+double pairs at0/1,9/10,18/19,27/28; shortest observed38bytes (36parsed+2unknown).

### PageProps `92`

`VSDParser.cpp:1240–1266`: six unit+double pairs at0/1,9/10,18/19,27/28,36/37,45/46: pageWidth,pageHeight,shadowOffsetX,shadowOffsetY,pageScale,drawingScale. Reader computes absolute pageScale/drawingScale, treating drawingScale0 as1. Parsedprefix54; observed132bytes in all three fixtures. Remaining fields/formula masks are not established by this reader.

### Line `85`

`VSDParser.cpp:857–878`:

```text
0 u8 width unit; 1 double width
9 u8 color ID (skipped); 10..13 RGBA, where A is transparency
14 u8 line pattern
15 u8 rounding unit; 16 double rounding
24 u8 skipped; 25 u8 start marker; 26 u8 end marker; 27 u8 line cap
```

Parsedprefix28; shortest observed35. NoBg shortest suffix@28..34=`02 00 01 04 00 00 00`. Its prefix uses width1/96in, solid pattern1, no arrows, cap0. Marker-ID meaning is a separate mapping in the content collector; Boolean arrow model must choose a real marker ID rather than blindly copy1.

### FillAndShadow `86`

`VSDParser.cpp:2070–2134`:

```text
0 fg color ID; 1..4 fg RGBA
5 bg color ID; 6..9 bg RGBA
10 fillPattern
11 shadow fg ID; 12..15 shadow fg RGBA
16 shadow bg ID; 17..20 shadow bg RGBA
21 shadowPattern
22 skipped shadow type; 23 skipped X unit; 24 double shadowOffsetX
32 skipped Y unit; 33 double shadowOffsetY
```

A means transparency,0opaque/255transparent. Color indices are consulted only when both cached colors are zero. Parsedprefix41; shortest observed61. NoBg suffix@41..60=`50 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f0 3f 01 04 00`. Source does not interpret that suffix.

### TextBlock `87`

`VSDParser.cpp:881–913`:

```text
0/1,9/10,18/19,27/28: unit+double left,right,top,bottom margins
36 u8 vertical alignment
37 u8 background color index (0 or255 transparent)
38..41 RGBA cached background
42 unit; 43 double defaultTabStop
51..62 twelve skipped bytes
63 u8 textDirection
```

Parsedprefix64. Shortest observed102 in NoBg; samples have a fixed92-byte area then formula blocks. Filled backgrounds use palette index minus1 in the reader.

## Geometry rows

Sources: `VSDParser.cpp:783–805` (elliptical arc),`833–854` (ellipse),`1081–1124` (basic geometry). Coordinates are local bottom-up shape coordinates in inches. Row IDs ordered by GeomList matter; a repeated first point closes a polygon in the fixtures. No standalone ClosePath chunk was identified here.

| Type | Parsed payload |
|---|---|
| Geometry `89` | u8flags@0:bit0 noFill,bit1 noLine,bit2 noShow; shortest observed3bytes (extra masks unknown) |
| MoveTo `8a` | unit@0,doubleX@1,unit@9,doubleY@10; shortest20bytes (18parsed+2unknown) |
| LineTo `8b` | Same as MoveTo |
| ArcTo `8c` | Three unit+double pairs: endX,endY,bow; prefix27,observed29+ |
| Ellipse `8f` | Six unit+double pairs: centerX,centerY,leftX,leftY,topX,topY; prefix54 |
| EllipticalArcTo `90` | Six unit+double pairs: endX,endY,midX,midY,angle,eccentricity; prefix54 |

FormatLine Geomflags at`Page+0x1789`=`01 01 2f`; MoveTo at`0x17a3`=`40`+double0+`40`+double0+`01 03`. Other shortest NoBg Move/Line suffixes are`00 00`; the suffix is not uniformly fixed. Bézier output requires either geometry-appropriate NURBS records or a chosen approximation; a LineTo with cubic control bytes appended does not encode a cubic.

## UTF-16 text, Char, Para, and font streams

**Text `0e`**: `VSDParser.cpp:1895–1914` skips8 bytes then reads `dataLength-8` raw bytes as UTF16LE. FormatLine at`Page+0x37eb`: 8zero bytes then `Collosal\n`, no NUL terminator, total26. Reference `readText` does not discard the final2 bytes despite its nearby comment. Use UTF16 code units for counts, not Unicode scalar or UTF8-byte counts. How Windows treats missing final paragraph markers remains unverified.

**CharIX `94`**, `VSDParser.cpp:1917–1981`:

| Offset | Field |
|---:|---|
| 0 | u32 character count (0 observed for a default/all-text run) |
| 4 | u16 font-face ID |
| 6 | u8 color ID, skipped |
| 7..10 | RGBA, A transparency |
| 11 | u8 flags:1bold,2italic,4underline,8smallcaps |
| 12 | u8 flags:1allcaps,2initcaps |
| 13 | u8 flags:1superscript,2subscript |
| 14 | u16 width scaling/10000 (10000=`10 27`) |
| 16..17 | Skipped; observed00 followed by font-size unit |
| 18 | double font size in inches |
| 26 | u8flags:1doubleunderline,4strikeout,32doublestrikeout |
| 27..87 | Not consumed by this reader; fixed-area/mask/language fields unknown |

Shortest observed88bytes. FormatLine Char at`Page+0x3853` uses font4, 6pt (1/12in), no styles; NoBg shortest default Char uses font4,12pt, locale-looking bytes`06 04` at69,70 and finalbyte2. These opaque suffixes must not be asserted unnecessary to Visio.

**ParaIX `95`**, `VSDParser.cpp:1985–2043`:

```text
0 u32 charCount
4/5 unit+double first indent
13/14 left indent
22/23 right indent
31/32 line spacing (negative values can be relative factors)
40/41 before spacing
49/50 after spacing
58 u8 alignment;59 u8 bullet type
60..63 skipped
64 u16 bullet fontID
66..67 skipped
68 double bullet font size
76 skipped unit;77 double text position after bullet
85 u32 flags
89..122 skipped
123... variable blocks
```

Variable block: u32 blockLength including itself; u8 blockType;u8 blockIdx; payload. A bullet string block has type2,idx8,then skippedbyte,u8UTF16-unit count,then count*2 bytes UTF16LE. Zero blockLength terminates. Reader seeks to each block end. NoBg Para at style stream`0x25b`,chunk`0x1485` is133bytes: fixed123 plus a10byte block changing alignment; sampled default Para is312bytes. Parsed fixed minimum123 is inferred from source, not an observed complete Windows row.

**FontFace `d7`**, `VSDParser.cpp:1745–1759`: font-face ID is the pointer index from the FontFaces container; blob reader skips4 bytes then reads up to32 UTF16LE units, stopping atNUL. FormatLine font4 (Calibri), compressed pointer at`VisioDocument+0x8695`,decompressed110bytes:

```text
66 00 00 00 45 01 00 00 43 00 61 00 6c 00 69 00
62 00 72 00 69 00 00 00 00 00 00 00 00 00 00 00
```

The leading`66 00 00 00` is the4-byte decompressed compression prefix (102). Blob shift4 removes it. The reader then skips4bytes (`45 01 00 00`) and finds the font name at decompressed offset8. For an uncompressed blob without that compression prefix, font name belongs atoffset4, not8. The name is in a64-byte field; remaining font metadata is not consumed by `readFont`. In all sampled font streams, total110 decompressedbytes=4compression-prefix+106blobbytes. FontFaces itself is a pointer-table container (type`d8`,FormatLineformat54). Define fontfaces before char rows; reader explicitly processes these containers before other root pointers regardless normal pointer order.

## Serializer implications and unresolved evidence

- Supported reader behavior is enough to construct a meaningful prototype, but a libvisio round trip only proves libvisio compatibility.
- Correct section levels, logical-list body lengths, ShapeID maps, and pointer offsets must be tested independently of embedded native metadata. A ZIP named `.vsd` does not satisfy these structures.
- Preserve existing binary streams when possible. The reader ignores many expression/mask/theme/data sections; regenerating only consumed prefixes loses document behavior.
- Full Windows payload suffixes, formula bytecode, protection, glue, metadata, document/style/page flags, print settings, image/OLE/CAD structures, theme behavior, and Windows repair behavior remain unresolved here.
- Root CLSID, document header stream-size field, VisioInformation, and conventional fixed areas are observed evidence. Their necessity, allowed alternatives, and interactions require Microsoft Visio open/edit/save/reopen verification.
