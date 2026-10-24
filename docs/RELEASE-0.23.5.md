# MacVisio 0.23.5

This release fixes VSDX output for Microsoft Visio 2019. Visio 2019 refused to open VSDX drawings saved by MacVisio ("some parts are missing or invalid") because the package had no window-state part. MacVisio now writes a minimal `visio/windows.xml`, with its relationship and content type, in every VSDX drawing it saves.

In Visio Professional 2019 (16.0.10730.20102) on Windows 11 ARM64, all seven synthetic VSDX comparison drawings now open, report the expected pages, shapes, IDs, parents, text and cached cells, accept a text edit, save, reopen and export to PDF and SVG. Experimental binary `.vsd` output still does not open in Visio 2019. Full Visio compatibility is not claimed. See [Windows validation](WINDOWS-VALIDATION.md).

Apple Silicon and macOS 27.0.1 or later are required. The app is Developer ID signed, notarised and stapled. An exact 0.23.4 app updated to it through signed Sparkle feeds after tampered-feed, tampered-archive and interrupted-download cases were rejected; settings and documents were preserved.

The owner approved publication with the same performance exception as 0.23.4: the controlled 50 ms input and 33 ms frame targets remain unqualified, and no performance pass is claimed. See [candidate evidence](delivery/STABLE-0.23.5.md).
