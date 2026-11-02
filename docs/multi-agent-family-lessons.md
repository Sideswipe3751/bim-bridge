# Multi-agent family production: reusable lessons

Recorded 2026-11-02. This is project memory for later sessions, not a replacement
for the installed Skill bootstrap, current discovery, or the architecture contract.
The implementation and live evidence in this feature are scoped to Revit 2024.
They do not certify another Autodesk release or publish a signed Host update.

## Execution and ownership

- Use three producers for research/code and at most two explicitly selected,
  resident Revit workers on this machine. One agent owns a worker lease at a time;
  different workers may execute concurrently. Never hold a native lease while
  waiting for an agent to research or write code.
- Publish each immutable, offline-compiled package when ready. Do not wait for an
  entire ten-product group. Use the neutral Runtime ready queue and finite
  wait-for-seal session; seal after the last producer. The Runtime does not spawn
  agents or import an agent SDK.
- Native family creation, view preparation, save/close, and abort belong to the
  connector lifecycle. Reuse saved parking projects; avoid starting/exiting Revit
  for every family. Keep the exact document and process checks at every stage.
- A transport timeout does not prove rollback. Unknown outcomes require
  reconciliation and worker quarantine, never an automatic replay. A known failed
  task can release its worker only after cleanup and parking readback.
- On Windows, read queue state through `JobStore.snapshot()`. A bare state-file
  reader can deny delete sharing during atomic replacement. Bounded retries may
  replace the same already-flushed metadata file; they must never rerun a native
  callback. See the concurrent-reader acceptance fixture.

## Geometry and acceptance

- Reuse native-tested primitives, not just copied product names. In the second
  asset round, four-section soft lofts overshot bounds; rounded-profile extrusions
  were more predictable for simplified cushions. Include true curve extrema in
  arc segmentation when bounding-box checks otherwise miss them.
- Avoid overlapping transparent ribs and coplanar glass. Multiple capped torus
  sectors can expose internal dark discs; Boolean-union them into one solid where
  appropriate. Do not add hidden geometry to force a desired bounding box.
- Compile against the actual Revit 2024 metadata and C#5 compiler constraints.
  Compilation alone does not validate geometry, transactions, or appearance.
- Require native identifiers, category, positive solids, dimensions, materials,
  warnings, and successful save/close. Then inspect the actual native PNG and
  compare it to the exact SKU's source image: correct leg colour, skirt, knob,
  shade inclination, door/drawer count, and reference pose all matter.
- `awaiting_review` is physical delivery, not acceptance. Bind reviews to the
  package hash and actual PNG. If a later independent check finds a defect,
  withdraw the old pass and preserve that history. Repair with a new explicit
  revision; preserve the original package and dimensional standard. Stop after
  two unsuccessful correction passes as required by the Skill.
- Source pages can redirect while official search indexes still retain a SKU.
  Record index-only evidence and live redirects honestly; do not claim a dead
  product link is currently accessible. Separate catalogue dimensions from an
  inferred adjustable pose's footprint.
- These delivered examples are independent simplified fixed-size Furniture
  references, not official IKEA BIM or fully dimension-driven assets. Lamp
  references have no photometry, electrical connectors, or functional light.

## Final delivery

Prepare assembly and catalogue scripts while modeling proceeds. Provide enough
back-row spacing to avoid projected occlusion, then validate the loaded project's
thirty unique instances, dimensions and footprints. Inspect three final native
group captures and obtain native save confirmation before packaging. A bootstrap
saved marker can list only the initial fifteen placements; final structured
readback is the authority for the full thirty.

Deliver only selected accepted RFAs, the saved RVT, original native previews,
source/approximation notes, a local searchable catalogue, redacted attempt history
and SHA256 manifests. Retain failures in audit evidence but exclude their RFAs
from the asset catalogue. Never publish lease/request/finish tokens, descriptors,
machine-specific request files, Autodesk/Host binaries, or official product photos
and HTML. `output/` is local test data, not a source-release input.

An owned disposable parking process can save successfully while its final
ExitRevit request fails to exit. Record save and clean shutdown separately.
Terminate only the exact owned test process after matching its ready/saved paths
and executable; never treat forced termination as clean shutdown.

## Measured results and scope

| Observation | B02 new products | B03 new products |
| --- | ---: | ---: |
| First-pass accepted originals | 21/30 (70%) | 25/30 (83.3%) |
| Native execution attempts including repairs | 41 | 35 |
| Recorded research start to all thirty final family reviews | 1486.273 s | 625.394 s |
| Recorded research start to completed ZIP | 2255.559 s | 798.236 s |
| Main streaming-controller elapsed time | 162.963 s | 311.518 s |
| Explicit repair execution intervals | 47.762 + 10.081 s | 31.827 s |

B03's earlier-started stream spends more of its interval waiting for producers;
its longer controller time is not a regression in native execution speed. The
complete delivery interval fell by about 64.6%, but the products differ: B03 has
more dining chairs and fewer complex sofas. These are production observations,
not an isolated causal measurement of an algorithm speedup. Do not claim all
thirty new researched assets took only the streaming execution interval.

The earlier controlled prepared-package comparison used the same 31 packages
(thirty families plus one intentional failure): one worker 252.107 s, two workers
164.064 s, 1.537x throughput / 34.9% less elapsed time. It excluded research,
startup, visual review, and final project assembly. It cannot be divided into the
roughly 115-minute cold-workflow baseline to claim a 40x algorithm speedup.

Measure research/preparation, ready publication, store submission, worker start,
native stages, physical delivery, first visual review, final accepted revision,
assembly/save, and ZIP completion separately. Parallel worker-stage sums are busy
time, not elapsed time. Count thirty unique logical products across revisions;
never sum multiple accepted revisions of one product. An observed code-file write
or compiler duration is not a measurement of private model reasoning.

Local source evidence is retained under `output/multi-agent-2024/` in the
`resident-final-20261102-r6`, `ikea-assets-b02-20261102`, and
`ikea-assets-b03-20261102` run directories. Rediscover current instances and
capabilities in later sessions; do not reuse historical IDs or tokens.
