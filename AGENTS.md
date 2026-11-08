# Repository instructions

## Architecture gate

Before changing code, build logic, tests, Autodesk manifests, provider routing,
packaging, or installer behavior, read `docs/architecture.md` in full.

Treat that document as the repository's architecture contract:

- preserve its architectural invariants;
- keep the BIM Bridge Runtime independent from Codex, DeepSeek Harness, and other
  agent SDKs; agent-specific behavior belongs in thin adapters;
- preserve the single versioned BIM Bridge Contract and capability/provider/policy
  boundaries rather than adding transport-specific domain models;
- use its shared-core, runtime-family, compatibility-layer, and version-matrix
  boundaries for Autodesk version work;
- do not add a new year by copying an existing full adapter or hard-coding a
  second version list;
- keep the release installer frozen after the Revit 2024-2027 certification
  gate until the user explicitly starts the packaging phase;
- update `docs/architecture.md` in the same change whenever an implementation
  decision makes it incomplete or inaccurate.

In the final report for a code change, state whether the architecture contract
was preserved or updated.

## Multi-agent family work

For multi-agent Revit family production, benchmarking, or optimization, read
`docs/multi-agent-family-lessons.md` and `docs/resident-family-jobs.md` before
planning the run. Treat recorded timings and process IDs as historical evidence,
not current session state. Keep exact native readback and actual image review;
do not relax acceptance criteria to improve a benchmark.

When preparing Canadian IKEA furniture production in this local checkout, check
`output/ikea-canada-catalog-20261102/START_HERE.md` if present. It points to the
local SQLite catalogue, source-coverage evidence, and batch proposal helper.
The dated catalogue is a snapshot, not live inventory; verify each selected SKU's
current source and complete measurement diagram before modeling.

## Installation requests

When a user asks an agent to install BIM Bridge from this GitHub repository,
follow `INSTALL.md`. Treat the repository as a Codex Repo Marketplace and use
the documented Marketplace and Plugin commands. Do not replace the public flow
with a source build, a standalone Skill copy, an unpinned remote script, or an
unpublished development Host.

Adding the Marketplace and Plugin is separate from installing the native Host.
After the required Codex restart and new-task boundary, let the installed Skill
run its bundled read-only status check and obtain explicit current-task consent
after presenting the exact Host mutation plan.
