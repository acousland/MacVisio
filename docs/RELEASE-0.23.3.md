MacVisio 0.23.3 reduces the time spent opening and saving large VSDX drawings.

- Large native editing payloads omit duplicate page baselines. Omitted baselines are reconstructed by page UUID, retaining native identities, groups and inherited-shape bindings. Distinct baselines remain stored in full.
- Saving updates the package content-types hash without encoding the entire native envelope a second time.
- Existing metadata formats remain readable. Save an existing large drawing once to compact its metadata and improve subsequent opens. Opening alone does not change the source file.
- Small drawings retain the previous metadata schema. Older MacVisio versions fall back to public Visio content when opening a drawing with the new compact metadata; use this version to retain native editing identities.

Local testing on a complex three-page drawing measured saving at 4.46 seconds, down from 13.59 seconds, and reopening the saved copy at 2.77 seconds, down from 5.66 seconds. The maximum main-loop gap during saving remained 12 milliseconds; an edit made during saving remained dirty. The saved snapshot retained all 6,628 node identities, and all 52 public package parts were byte-identical. A normal-window open check took 2.72 seconds with a maximum 116-millisecond main-loop gap and no unintended document changes. Native metadata shrank from 262 MB to 132 MB before compression. These timings describe one drawing and machine, excluding cloud download time.

All 454 Swift tests and seven packaging tests pass. New coverage includes legacy metadata reads, compact binding validation, distinct-baseline retention, editing after compact restore, public-content reimport, stable small-file encoding and content-types hash integrity.

Requires Apple Silicon and macOS 27 or newer. Install using **MacVisio > Check for Updates…**, or expand the ZIP and move MacVisio.app to Applications. Full Visio compatibility remains unfinished; binary VSD writing remains experimental.
