# MacVisio 0.23.4

This release brings the qualified M2 native-editor work to the stable update channel: document/window workflows, branching and off-page flowcharts, command search, rich-text find/replace and Undo/Redo, keyboard authoring, object-aware diagnostics, safe-copy handling and PDF/SVG output.

The app is Developer ID signed, notarised and stapled. Actual upgrades from published0.23.3 verify signature rejection, interrupted-download recovery, exact installation and preservation of settings/documents. The installed app natively edits, saves and reopens a Unicode label with matching public VSDX text.

Apple Silicon and macOS27.0.1 or later are required. The compiled product text matches the M2 candidate with745 Swift tests (12 fixture-dependent skips, zero failures); updated release tooling passed87 Python tests, followed by16 focused exception-policy checks. Japanese and VoiceOver operation testing were excluded by the owner. Full Visio compatibility is not claimed.

The owner explicitly approved publication with a performance exception. Controlled50ms input and33ms frame targets remain unqualified. This decision is bound to this exact archive in the policy and retained manifest; it is never described as a performance pass. See [candidate and approval evidence](delivery/M2-STABLE-0.23.4.md).
