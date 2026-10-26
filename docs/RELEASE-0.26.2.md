# MacVisio 0.26.2

This release fixes saving edited Visio drawings and dragging shapes between containers.

**Saving**

- Saving an edited Visio drawing in place no longer stops with "This save may change unsupported source behavior". Three things wrongly triggered it:
  - shapes that were only recalculated from their unchanged formulas were treated as edited;
  - moving or resizing a shape placed from a master was treated as changing what it inherits;
  - `FILENAME()` was always empty, so title-block fields that read the file name failed.
- Moving, resizing or changing the container of a shape no longer marks its other formulas for review.

**Containers**

These behaviours were measured with real drags in Visio 2019.

- A dragged shape joins the container its centre lands in; with nested containers it joins the innermost one.
- A shape leaves a container once its centre is outside it, even if it still overlaps the edge.
- Containers set to expand as needed, which is Visio's default, grow to keep their members inside their margin and clear of the heading.
- Containers with members can be moved, carrying their members, and resized. Moving a container with its members undoes as one step.
- Containers and shapes placed from Visio masters are no longer refused as unproven. This also allows them to be copied and deleted.
- Placeholders that Visio leaves for deleted members no longer make a container read-only.
- Containers on locked layers stay locked, as in Visio.

This release was signed and notarised after the automated test suite passed. At the owner's direction, the full stable qualification gates (update installation, performance, Visio interchange and the hands-on check) were not rerun.

Apple Silicon and macOS 27.0.1 or later are required.
