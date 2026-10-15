# Document workflow

This note describes the document-opening and window workflow implemented by MacVisio and the Microsoft Visio behavior used as a reference. It records a Mac adaptation; it does not claim Visio 2024 parity.

## Microsoft reference evidence

Microsoft's current Visio and Office support pages document the main file tasks: opening files from **File > Open**, using recent files, pinning recent files, and creating a drawing from a template. Visio's template guidance describes choosing a template when creating a new drawing. The Visio 2024 product page describes the 2024 release but does not specify a start-window layout or multi-document lifecycle.

- [Open files from the File menu](https://support.microsoft.com/en-us/office/collab-files/open-files-from-the-file-menu)
- [Customize the list of recently used files in Office apps](https://support.microsoft.com/en-us/office/collab-files/customize-the-list-of-recently-used-files-in-office-apps)
- [Select a template in Visio](https://support.microsoft.com/en-us/visio/visio/select-a-template-in-visio)
- [Add a stencil to a template in Visio](https://support.microsoft.com/en-us/visio/add-a-stencil-to-a-template-in-visio)
- [What's new in Visio 2024](https://support.microsoft.com/en-us/visio/what-s-new-in-visio-2024)
- [Keyboard shortcuts for Visio](https://support.microsoft.com/en-us/accessibility/visio/keyboard-shortcuts-for-visio)

The published Visio shortcut reference is for Windows. It supports the existence of documented Visio commands and shortcuts, but does not establish Mac shortcut choices. Microsoft's available documentation does not establish the exact Visio 2024 Home screen arrangement, whether closing the last drawing returns to a start screen, or the exact menu placement of **Switch Windows** in Visio 2024. Microsoft's [Visio 2013 start-screen article](https://support.microsoft.com/en-gb/visio/turn-off-the-start-screen) is historical and is not evidence for Visio 2024 behavior.

There was no live Visio 2024 comparison available for this work. The inspected QEMU guest had no Visio executable at the checked 32-bit or 64-bit Office 16 paths and no Visio COM registration; a local Visio 2019 ISO was available, but was not treated as a Visio 2024 runtime. These implementation details and the documentation above support a reference-informed design, not a claim of runtime parity.

## MacVisio behavior

MacVisio uses separate native drawing windows. Home is a welcome window, not a drawing document. At startup it shows Home when launched without an incoming file; it does not automatically create a Flowchart. When macOS restores open documents, the restored drawings remain available behind Home.

The welcome window provides **Home**, **New**, and **Open** sections. Home lists recent local drawing paths and supports pinning. This recent list stores URLs only; showing Home does not open or read drawing contents. File > Open (⌘O) shows the Open section; Browse Files (⇧⌘O) opens a native file chooser and supports multiple selections. Opening a recent item uses the normal open path, while successful saves and Save As operations also add the saved path to recents. Opening a URL that is already open activates its existing drawing window rather than creating a duplicate.

New opens a template chooser; **New Blank Drawing** creates a blank drawing directly. Drawings open in their own windows. Switching documents keeps each drawing's current diagram, dirty state, selection, and view state. **View > Switch Windows** lists open drawings and marks the active one. **Window > Next Drawing** and **Previous Drawing** cycle through them; Control-Tab and Control-Shift-Tab are the primary shortcuts, with Control-F6 and Control-Shift-F6 as alternates.

Closing one drawing leaves other drawings open. Closing the last drawing returns to Home, while **Close All Drawings** uses the native document close flow and returns to Home when all drawings have closed. Unsaved-change handling is provided by AppKit's document/window close flow. The welcome window's **Back to drawing** action returns to the active drawing, and its Save, Save As, and Close Drawing actions operate on that drawing. The File menu also provides **Home** so the welcome window can be opened while drawings remain open.

The principal Mac keyboard shortcuts are:

| Action | Shortcut |
| --- | --- |
| New Diagram chooser | ⌘N |
| New Blank Drawing | ⇧⌘N |
| Open screen | ⌘O |
| Browse files directly | ⇧⌘O |
| Close drawing | ⌘W |
| Close all drawings | ⌥⌘W |
| Next / previous drawing | Control-Tab / Control-Shift-Tab |
| Alternate next / previous drawing | Control-F6 / Control-Shift-F6 |

The **New Diagram** chooser is the default ⌘N action; direct template actions are also available from the File menu. On document open, import currently runs synchronously before the drawing window is shown. The welcome window has an opening-progress presentation, but it does not make document import asynchronous.

## Design choices and acceptance checks

Some behavior is an intentional MacVisio policy because the available Microsoft sources do not specify it for Visio 2024: showing Home after the last drawing closes, showing Home at startup when no file was supplied, putting **Switch Windows** under View while cycling commands live under Window, and the Mac-specific shortcut mapping. Treat these as product decisions that can be revised, not verified Visio 2024 behavior.

The current workflow should continue to satisfy these checks:

- Launch without a file and show Home without creating an untitled drawing; launch with a file and show that drawing.
- Create two drawings as separate windows; opening the same normalized file URL again activates the existing instance.
- Keep each drawing's selection, zoom/view, edits, and dirty state when switching away and back.
- Update the active check in **View > Switch Windows** as drawings are activated or closed.
- Closing one drawing preserves the others; closing the last drawing shows Home; closing all follows the native unsaved-changes flow.
- Home recents and pins persist locally and do not load drawing contents until a user opens an item.
- Use **Back to drawing** to return from Home without closing or replacing the current drawing.
