# DeepSeek Harness adapter

This page documents the experimental DeepSeek Harness (DSH) compatibility layer
for BIM Bridge. It is the DSH sibling of [the Kimi adapter](kimi-adapter.md) and
[the WorkBuddy adapter](workbuddy-adapter.md).

Phase 1 scope: **DSH → existing BIM Bridge stdio MCP → shared Runtime →
already-installed Autodesk connectors.** Nothing more. `ctx.aec` is not
implemented, the Contract v2 workstream is not touched, and no new Runtime, Host,
or Autodesk connector is developed here. Starting this phase does not mean that
Contract v2, DSH live certification, or a new Host release has passed.

## Verified platform facts

Verified against DSH `0.1.5-rc.2` on this machine:

| Fact | Value |
|---|---|
| CLI | `dsh` |
| MCP command | none — `dsh --help` exposes only `web` and `plugin` |
| MCP mechanism | `@deepseek-ai/dsh-mcp-client` Cordis plugin, one config row per server |
| Tool naming | `mcp__<serverName>__<rawName>` |
| Bridged capability | tools only (resources and prompts are unsupported) |
| Plugin install | `dsh plugin --profile <name> add -w <spec>` (a DSH bundle declares `dsh.bundle.patch`) |
| Skill discovery | `<name>/SKILL.md` under scanned roots, incl. `<dshHome>/skills` and `customSkillDirs` |

Accepted `dsh-mcp-client` fields used by this adapter: `serverName`, `transport`
(`stdio`), `command`, `args`, `cwd`, `toolCallTimeoutMs`, `failOnStartupError`,
and the `reconnect.*` family. Connection, `initialize`, and `tools/list` timeouts
are **not** configurable through this plugin; they are inherited from the MCP SDK.

## Discovery without a global PATH

The adapter must work on a machine where DeepSeek Harness was never added to the
user's `PATH`. It therefore resolves `dsh` and the Node interpreter itself, in a
fixed order, and reports which candidate it used. Nothing here writes to disk, and
nothing here edits `PATH` — neither the process `PATH` nor the persisted user
`PATH`.

| Order | `dsh` candidate | `commandSource` |
|---|---|---|
| 1 | `BIM_BRIDGE_DSH_COMMAND` | `BIM_BRIDGE_DSH_COMMAND` |
| 2 | `Get-Command dsh` on the process `PATH` | `PATH` |
| 3 | `%LOCALAPPDATA%\Programs\DeepSeekHarness\bin\dsh.cmd` | `dsh_install` |
| 4 | `<dshHome>\node_modules\.bin\dsh.cmd` | `dsh_home` |

| Order | `node.exe` candidate | `nodeSource` |
|---|---|---|
| 1 | `BIM_BRIDGE_DSH_NODE` | `BIM_BRIDGE_DSH_NODE` |
| 2 | `node.exe` on the process `PATH` | `PATH` |
| 3 | `%LOCALAPPDATA%\Programs\DeepSeekHarness\node-*-win-*\node.exe` | `bundled_node` |

Three properties of this order matter:

- **It is the installation's own entry point.** The per-user
  `bin\dsh.cmd` already prepends its bundled Node directory and delegates to the
  local checkout's `node_modules\.bin\dsh.cmd`. Resolving it is what makes the
  adapter work with neither `dsh` nor `node` on `PATH`.
- **Every candidate is a fixed, documented path.** No directory tree is scanned to
  find DeepSeek Harness, so discovery cannot wander into unrelated directories or
  pick up an unintended installation.
- **An override is terminal, not a hint.** When `BIM_BRIDGE_DSH_COMMAND` or
  `BIM_BRIDGE_DSH_NODE` is set, that value is the answer: a missing override is
  reported as missing instead of being silently replaced by a discovered
  installation. Otherwise a status check could report success for a different
  installation than the one it was pointed at.

A discovered candidate is only accepted when it exists on disk, so a stale
directory never becomes a phantom `installed: true`. When no candidate resolves,
the status is `deepseek_harness_not_found` and the action is
`install_deepseek_harness` — the same result as before this discovery existed.

The launcher wrapper applies the same interpreter resolution for the process it
delegates to: it prepends the resolved Node directory to the **child's**
environment only, so a delegated Host (and anything it spawns) can rely on
`node` without a machine-wide installation. The persisted user `PATH` stays
untouched. A resolution failure is never fatal here — the wrapper's job is Host
containment, and its exit semantics depend only on the containment checks.

## Architecture contract

Preserved, not extended:

- the Runtime stays independent of every agent SDK;
- there is one versioned BIM Bridge Contract;
- existing `aec_*` tool names, schemas, risk annotations, and connector routes are
  untouched;
- Runtime capability discovery, provider routing, authentication, policy, and
  verification semantics are untouched;
- the Host keeps its exact instance/document checks, native transactions, and
  rollback;
- `eng/Autodesk.Versions.props` and the Runtime remain the only Autodesk version
  matrix.

The shim, bundled-Node discovery, and wrapper-integrity rules above are the
normative contract in `docs/architecture.md` § "DeepSeek Harness adapter
contract"; this page is the adapter-facing description of the same behaviour. The
package/SemVer identity and the Autodesk bundle's stable numeric version are
different values with one documented mapping — `docs/architecture.md` § "Version
authority". This adapter introduces no DSH-specific Runtime, Host, provider
policy, or domain model. It does not impersonate Codex, does not create or reuse
an approval grant, and does not switch provider or generate dynamic retries after
a denied or possibly-executed write.

## Test suite scope and shared-worktree behaviour

`tests/adapters/deepseek-harness/Test-DeepSeekHarnessAdapter.ps1` runs against an
isolated temporary state root and a fake Host, and proves the real installation
was untouched by hashing its install-state and the shared protocol baseline
before and after.

This repository is one shared working tree with no worktree isolation, so the
suite deliberately does **not** infer ownership violations from the dirty tree:

- the adapter's own read-only files are hashed before and after the run and must
  be identical (hard assertion, always on);
- the shared layer the adapter must not modify is observed and reported with
  attribution — a concurrent edit by another member to a path that was already
  dirty is expected, and a change to a path that was clean at the start is
  reported as unattributed;
- the hard shared-layer statement is an opt-in gate. Point it at an explicit,
  reviewed baseline:

  ```powershell
  pwsh -NoProfile -File tests\adapters\deepseek-harness\Test-DeepSeekHarnessAdapter.ps1 `
    -OwnershipBaselinePath tests\adapters\deepseek-harness\ownership-baseline.txt
  ```

  or set `BIM_BRIDGE_DSH_OWNERSHIP_BASELINE` to the same path. Every shared-layer
  path that `git status --porcelain --untracked-files=no` reports dirty must then
  appear in the baseline, and a path outside it fails the gate. Without a
  baseline the gate reports `SKIP` rather than inventing a verdict from the dirty
  tree. The same baseline plus the same worktree always yields the same result.

## Wrapper integrity contract

`Start-BimBridgeDshMcp.ps1` refuses to start unless every check passes, in order:

1. `install-state.json` exists under the state root and its `schemaVersion` is `4`;
2. the recorded launcher path is lexically inside `<StateRoot>\host\`;
3. the launcher file exists and can be resolved to its final on-disk path;
4. the launcher itself is not a reparse point;
5. the final path after following directory aliases remains inside the Host root;
6. the launcher has a single hard link, so an in-root alias cannot name bytes also linked outside the Host root;
7. a recorded SHA-256 exists, is 64 hexadecimal characters, and matches the file.

On failure the diagnostic goes to **stderr only** and the process exits `1`.
stdout carries nothing but the MCP protocol. On success the wrapper sets
`BIM_BRIDGE_AGENT_ADAPTER=deepseek-harness` for the delegated process and
propagates its exit code.

A local install-hash check is not equivalent to release signature verification.

## Read-only status

`Get-BimBridgeDshStatus.ps1` returns JSON with `status` and `recommendedAction`:

| `status` | Cause | `recommendedAction` |
|---|---|---|
| `healthy` | DSH and Host both usable | `none` |
| `deepseek_harness_not_found` | no candidate resolved, including the per-user installation | `install_deepseek_harness` |
| `not_installed` | no install-state | `install_host` |
| `needs_repair` | unreadable/incompatible state, or a missing/changed critical file | `repair_host` |

It also reports the DSH home and the profiles present, the resolved `dsh` command
and Node interpreter with the source each came from, the Host's recorded connector
deployment, and running Revit/AutoCAD processes. It writes nothing and never edits
DSH configuration.

## Local machine inventory (this phase's acceptance scope only)

Seven installed builds bound this work. This is a work and acceptance boundary,
**not** a new support matrix, and it is never hard-coded into adapter logic.

| Product | Installed build (FileVersion) |
|---|---|
| Revit 2024 | 24.1.11.26 |
| Revit 2025 | 25.4.60.9 |
| Revit 2027 | 27.2.0.39 |
| AutoCAD 2024 | R24.3.222.0.0 |
| AutoCAD 2025 | R25.0.171.0.0 |
| AutoCAD 2026 | R25.1.179.0.0 |
| AutoCAD 2027 | R26.0.118.0.0 |

Excluded: Revit 2026 (not installed, must not be downloaded or tested), any other
product or year, installing/downloading/upgrading Autodesk products, and
cross-machine certification or future-version support.

Product install, runtime recognition, connector deployment, MCP discoverability,
and DSH end-to-end results are recorded as five separate fields per build; see
`adapters/deepseek-harness/skills/bim-bridge/references/acceptance.md`.

## Known environment observations

- The installed Host state records version `2.0.0-alpha.1`, while `INSTALL.md`
  describes the published `2.0.0-alpha.4` preview. This adapter reports the state
  it finds and does not attempt to reconcile or upgrade it.
- The Host recordings deploy a Revit **2026** connector and list Revit 2026 even
  though Revit 2026 is not installed, and record **no** AutoCAD 2025/2026/2027
  connectors although those products are installed. This is consistent with the
  Host status check under-reporting AutoCAD 2025–2027. The adapter reports this
  verbatim as `host.recordedProducts` and does not repair or reinterpret it.
- The per-user `PATH` on this machine contains
  `%LOCALAPPDATA%\Programs\DeepSeekHarness\bin`, but the PATH a running process
  actually inherited does not: it carries only the bundled Node and package-manager
  directories. In that state `Get-Command dsh` fails while the entry point exists
  on disk, which is precisely the case the discovery order above resolves. This
  adapter adds no PATH entry anywhere and only reads the environment it is given.
- A connector descriptor can outlive its process. The Runtime lists every
  descriptor it can read and does not check whether the recorded `processId` is
  alive, so one stale descriptor makes an unqualified call fail as ambiguous.
  Pass the exact `instanceId`, or remove the stale descriptor; the adapter never
  deletes one.

## Verified end-to-end (2026-11-11)

One build was exercised through a real DeepSeek Harness session, not only through
the adapter suite. The harness ran the `web-agents` profile with this adapter's
cordis row and Skill against a disposable copy of the test model under
`%TEMP%`, on instance the selected Revit 2024 instance with connector `1.1.0-rc.3`.

| Step | Result |
|---|---|
| Tool discovery | 10 `mcp__bim-bridge__aec_*` tools registered in the session |
| Instance discovery | the selected Revit 2024 instance listed with its document and capabilities |
| Document and selection reads | document identity, then two conduit elements |
| Read code | both conduits' `Comments`/`Mark` values returned |
| Bounded write | `Comments` set on one conduit, confirmed by a separate read-back |
| Rollback | a write that threw returned `rolledBack: true`; read-back showed the pre-failure value |
| Restore | `Comments` cleared, final read-back empty |

Verdict: **PASS** for the Revit 2024 read/write/rollback path on this machine.
The other six installed builds are **NOT RUN**. This is an operating record, not
an independent certification, and the suite remains the regression gate. Full
evidence: [the 2026-11-11 acceptance record](deepseek-harness-acceptance-2026-11-11.md).

## Limits

- Resources and prompts are not bridged by `dsh-mcp-client`; only tools are.
- Adapter code changes require restarting the DSH process when the active
  profile's `patchReload` is not `live`; a browser refresh does not replace
  already-loaded Host modules.
- This adapter does not install, repair, upgrade, or uninstall the native Host,
  and does not modify Autodesk install directories, add-in directories,
  certificates, or trust settings.
