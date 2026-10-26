# MacVisio 0.26.1

This release fixes large Visio drawings that failed to open, refused edits or were slow to edit.

**Opening and editing**

- **Embedded objects:** a drawing containing an embedded (OLE) object with an empty text block no longer fails to open with "Invalid rich text runs".
- **Containers:** edits are no longer refused with "This container has members…" when MacVisio recalculates a container's size from its own formulas.
- **Speed on large drawings:** editing a large drawing no longer recalculates every shape on every page. On a 6,600-shape drawing:
  - moving a shape takes 0.14 s instead of 6.6 s;
  - inserting a shape takes about 1 s instead of 7 s;
  - selecting, undoing and switching pages take well under a second.

**Appearance, compared with Visio 2019**

- Shapes and connectors are drawn in Visio's page order, so connectors are no longer hidden behind filled frames.
- Text that is taller than its text block overflows it, as in Visio, instead of disappearing. This affected small title-block and footer labels.
- Text is placed using each shape's vertical alignment and margins, so container headings sit at the top.
- Title blocks show the page's own field values instead of the template placeholder text.
- The Case setting (all caps, initial caps) and corner rounding are drawn.
- Visio's dashed and dotted line patterns are drawn.

This release was signed and notarised after the automated test suite passed. At the owner's direction, the full stable qualification gates (update installation, performance, Visio interchange and the hands-on check) were not rerun.

Apple Silicon and macOS 27.0.1 or later are required.
