# SD-2026-10-24-01 — Accessibility and VoiceOver permanently out of scope

State: **approved**. Approved by the repository owner on 24 October 2026, in direct instruction to the delivery agent.

Owner's words, in answer to whether to run a real VoiceOver pass for the M0–M2 close-out: **"No need for VoiceOver or accessability features. De-scope them permanantly"**.

Covered requirements: MV-ACC-01 (accessibility tree for controls, canvas objects, text, relations and data), MV-ACC-02 (visible keyboard focus and keyboard alternatives for required workflows) and MV-ACC-03 (alternative text, reading order, accessible link text and non-colour cues).

Effect: these requirements are excluded from MacVisio's scope. They no longer gate a milestone or a release, and the stable release policy no longer has an `accessibility` gate. This extends the 16 October 2026 removal of VoiceOver operation testing. Existing accessibility code and keyboard navigation remain in the product and are not removed by this decision; they are simply no longer qualified or claimed. Full Visio Professional 2019 parity, which includes these obligations, can no longer be claimed.
