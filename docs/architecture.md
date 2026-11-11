# BIM Bridge architecture contract

Last reviewed: 2026-11-02 (resident family jobs and bounded ready-queue scheduling;
instance task coordination, concurrent audit journals,
and disposable Revit 2024 furniture acceptance; prior adapter, staging and version
authority contracts retained)

This document is the canonical architecture contract for BIM Bridge. Read it
before changing source code, build logic, tests, Autodesk manifests, provider
routing, packaging, or installation behavior. If a change makes this document
inaccurate, update the document in the same change.

## Status and architecture decision

The product is **BIM Bridge**. Codex is not the owner of the Autodesk execution
system. The durable engine is an agent-independent **BIM Bridge Runtime**.
Codex, DeepSeek Harness, MCP clients, a CLI, and future Autodesk or third-party
agents are adapters over the same versioned **BIM Bridge Contract**.

Artifacts created by releases through `1.1.0-rc.3` use `AEC Codex`,
`aec-codex`, and `%LOCALAPPDATA%\AEC Codex`. The `2.0.0-alpha.1` development
line introduces the `bim-bridge` Codex plugin, `bim-bridge-local` MCP
registration, `%LOCALAPPDATA%\BIM Bridge` state, and BIM Bridge Autodesk
manifests. The installer treats the old paths as explicit migration inputs and
removes only known legacy-owned components. Version-1 `aec_*` MCP tool names
and legacy connector discovery remain compatibility identifiers until their
contracts can change independently. BIM Bridge 2.x host and Autodesk adapter
assemblies use `BimBridge.*` identities; `Aec.Codex.*` assemblies are accepted
only as explicit legacy migration inputs and are never emitted by a 2.x build.
New runtime configuration accepts `BIM_BRIDGE_*` environment names first and
the legacy `AEC_CODEX_*` names as fallbacks.

This is an evolutionary redesign, not a rewrite. The authenticated connector,
Revit shared adapter, runtime resolver, transaction implementation, structured
provider gateway, and unattended certification work remain valuable and move
behind clearer boundaries. Current source paths may remain in place while
ownership is extracted; logical boundaries must be established and tested
before large directory moves.

**Current implementation milestone:** package and locally validate the
agent-independent runtime behind the Codex adapter, plus experimental thin
Tencent WorkBuddy, Kimi Code, and DeepSeek Harness adapters that mount the same
installed stdio MCP projection. All three adapters perform read-only Host
preflight and delegate through a verified wrapper to the neutral Host launcher.
WorkBuddy provides a repository Marketplace Plugin that bundles its Skill and
relocatable MCP declaration; Kimi provides a native Kimi plugin manifest; DeepSeek
Harness provides a stdio MCP configuration template and a Skill, and it resolves
both `dsh` and its bundled Node interpreter without depending on `PATH`. None of
them installs or repairs the Host, and none is independently certified. Future
agent packages may reuse the same read-only status, explicit consent, host
bootstrap, and restart lifecycle, but must not fork the runtime or host binaries.
This sequencing constraint does not make Codex, WorkBuddy, Kimi, or DeepSeek
Harness the owner of runtime behavior.

As of this review, unattended live acceptance has passed on the certification
machine for Revit 2024.1 on .NET Framework 4.8, Revit 2025.4 on .NET 8, Revit
2026.5 on .NET 10, and Revit 2027.2 on .NET 10. AutoCAD 2024 (R24.3), 2025
(R25.0), 2026 (R25.1), and 2027 (R26.0) also passed against their exact adapters,
including MCP routing, read, write, readback, rollback, cleanup, clean shutdown,
and descriptor cleanup. The machine-compared version 1 protocol/tool snapshot
is frozen and broad runtime extraction has passed its current compatibility
tests.

The frozen version 1 compatibility fixture is
`protocol/v1/baseline.json`. It machine-compares the ten Codex MCP tool schemas
and annotations, supported MCP protocol versions, five connector routes, bearer
authentication shape, execute modes, and normalized request statuses. Contract
version 2 begins beside it at `protocol/v2/aec-contract.schema.json`; the v1
fixture remains authoritative for the current production facade until an
explicit compatibility decision updates it.

The current Phase 2 through Phase 5 implementation lives in
`runtime/aec_runtime`. It owns host discovery and authenticated request polling,
staged provider lifecycle and classification, the capability registry,
deterministic route plans, runtime-owned adapter sessions, signed request-bound
grants, direct contract-v2 host execution, read-back verification orchestration,
normalized results, and a redacted hash-chained execution journal. The Codex
STDIO MCP process is a version 1 projection over the same service.
`provider_gateway.py` is only a legacy import shim. The ten-tool MCP surface and
five connector routes remain the production compatibility facade.

The version 1 compatibility fixture was deliberately revised on 2026-08-14 to
classify arbitrary in-process query code as destructive/ambient-authority code
rather than as a read-only tool. Tool names and connector routes did not change.

Revit 2024, 2025, 2026, and 2027 and AutoCAD 2024, 2025, 2026, and 2027 have
passed their current version-specific acceptance gates. On 2026-08-14 the user
explicitly started the packaging phase, lifting the release-installer freeze for
this certified scope. The new installer remains a development alpha until its
release archive, signed manifest, checksum, and cross-machine gates pass.

## Architectural invariants

1. **The BIM Bridge Runtime is agent-independent.** It must not import Codex,
   DeepSeek Harness, Claude, or another agent SDK. Agent-specific instructions,
   tool presentation, approval UI, and lifecycle hooks live only in adapters.
2. **The versioned BIM Bridge Contract is the center of the system.** MCP is the first
   public transport adapter, not the business-logic owner. A second adapter must
   not create a second request, result, error, capability, or policy model.
3. **The BIM Bridge Runtime never loads Autodesk assemblies.** Autodesk API assemblies
   are loaded only inside the exact matching Autodesk process.
4. **Host connectors are thin policy-enforcement points.** They own process
   registration, authentication, target-document checks, Autodesk UI-thread
   dispatch, native transaction/document locking, bounded compilation, and
   result collection. They do not perform agent reasoning or provider routing.
5. **Product behavior is shared by product, not copied by year.** Revit and
   AutoCAD each have a shared implementation. Per-release builds contain only
   exact SDK references, assembly identity, manifest metadata, runtime-family
   selection, and bounded compatibility shims.
6. **Runtime and API variants are explicit.** A release year is not assumed to
   identify one runtime for its servicing lifetime. The resolved installed API
   build is part of routing and certification evidence.
7. **Product/version support has one machine-readable source of truth.** Build,
   diagnostics, certification, packaging, and installation consume the same
   matrix; no adapter or installer maintains another year list.
8. **Capabilities and providers are separate concepts.** A capability describes
   what can be done; a provider describes one eligible execution mechanism.
   Provider availability never changes the meaning, risk, or result schema of a
   capability.
9. **Routing is deterministic and fail-closed.** A denial, invalid input,
   transaction failure, destructive-operation refusal, or possibly committed
   mutation is never retried through a different provider. Fallback is allowed
   only before execution when capability or provider availability is absent.
10. **Safety policy is independent of the calling agent.** The runtime owns
    immutable denies, risk classification, target scoping, and approval
    requirements. The active agent adapter owns the single user-facing approval
    experience, but a trusted runtime/broker authority signs the resulting
    request-bound grant. Adapters cannot authenticate themselves or mint grants.
    Host connectors do not add a second approval dialog.
11. **Verification is first-class evidence, not a prompt convention.** Results
    declare execution, transaction, change, verification, and rollback facts.
    Repair is a new explicit request; it is never a silent mutation retry.
12. **A successful compile is not certification.** Each exact Autodesk
    runtime/API build variant must pass load, routing, read, write, rollback,
    shutdown, dependency, policy, and cleanup tests before release packaging.
13. **The installer consumes certified decisions; it does not make them.** It
    discovers installed products, resolves them through the single version
    matrix, and deploys only matching entries already marked certified.

## Ownership model

| Layer | Owns | Must not own |
| --- | --- | --- |
| Agent adapter | tool/UI projection, agent lifecycle, approval presentation, contract translation | Autodesk calls, provider policy, transactions, business routing |
| Protocol adapter | MCP/CLI/HTTP framing and version negotiation | a parallel domain model or special-case behavior |
| BIM Bridge Runtime | host directory, capability registry, deterministic route plan, policy, provider supervision, verification orchestration, normalized errors, audit correlation | agent loops, model calls, Autodesk assemblies |
| Provider adapter | capability metadata and one execution mechanism | global policy or undisclosed fallback |
| Host bridge | authenticated local transport and request lifecycle | Autodesk APIs or product-specific transactions |
| Product host | UI-thread dispatch, exact document, native transactions/locks, API compatibility, dynamic compiler | agent SDKs, external MCP routing, approval UI |

`BimBridge.Host` currently combines the host bridge contract and transport.
That is acceptable during migration because its public types are neutral
host-protocol types and do not reference an agent SDK.

## Target topology

```text
Codex       WorkBuddy       Kimi Code       DeepSeek Harness       CLI / tests
  |             |               |                  |                   |
  +------------------------- agent / protocol adapters -------------------+
                               |
                  Versioned BIM Bridge Contract
                               |
             +-----------------+------------------+
             |         BIM Bridge Runtime          |
             | host directory / capabilities      |
             | routing / policy / audit            |
             | provider supervision / verification|
             +----------+---------------+----------+
                        |               |
             structured providers      host providers
             Autodesk / approved MCP   Revit / AutoCAD / future
                        |               |
                        |        authenticated loopback bridge
                        |               |
                        +------ exact Autodesk process
```

The first migration keeps the runtime embedded in the existing local STDIO MCP
process. A permanent background daemon is not required. If simultaneous Codex,
DeepSeek, and CLI clients later need shared provider processes or audit state, a
single-user loopback broker may host the same runtime interfaces; broker mode
must not introduce different routing or policy semantics.

## Versioned BIM Bridge Contract

The contract is defined as language-neutral schemas under `protocol/`. Version
1 connector endpoints remain supported while version 2 is introduced beside
them. Adapters translate transport messages to the same domain objects.

An execution request contains at least:

- a correlation ID and contract version;
- an exact host selector for mutations: application, resolved release/API
  variant, process/instance ID, and document identity;
- a stable capability ID and typed arguments;
- declared intent (`read` or `write`), timeout, cancellation, dry-run, and
  idempotency constraints;
- optional provider preference as a constrained hint, never a command to bypass
  routing policy;
- optional preconditions and postcondition/verification specification;
- a runtime-issued authenticated adapter session and, when required, a signed,
  non-replayable approval grant bound to the session, request hash, target,
  effect summary, issuer, and expiry.

An execution result contains at least:

- normalized status: `succeeded`, `succeeded_unverified`, `partial`, `failed`,
  `rejected`, `expired`, or `cancelled`;
- chosen capability/provider and exact host evidence;
- transaction/document-lock outcome and `rolledBack` evidence;
- normalized created, modified, and deleted identifiers when observable;
- verification strength, checks, issues, and evidence;
- warnings and structured errors with a stable code, stage, retryability, and
  provider-native diagnostic details kept in a bounded evidence field;
- timings and audit correlation IDs.

The caller does not select `native`, `mcp`, or `csharp` as an unrestricted mode.
It requests a capability. Dynamic code remains an explicit high-risk capability
(`revit.code.read`, `revit.code.write`, and AutoCAD equivalents), not an
invisible fallback for every failed operation.

## Capabilities, routing, and providers

The capability registry is data, not prompt prose. Every entry declares:

- stable capability ID, application, intent, input/output schemas, and risk;
- supported product/API variants and required host capabilities;
- candidate providers and their trust tier;
- targeting strength (exact instance/document or application-global);
- dry-run, idempotency, cancellation, transaction, rollback, and verification
  guarantees.

Every provider implements the same conceptual lifecycle: describe health and
capabilities, validate/plan without mutation, execute once, normalize evidence,
and optionally verify. It may be a deterministic host operation, an official or
approved structured MCP tool, or an explicit dynamic-code host capability.

`revit.view.capture` is a deterministic low-risk host capability. The shared
Revit product host exports one existing printable view with native
`ImageExportOptions`; it does not compile caller-supplied code or modify the
model. Output is constrained to BIM Bridge's current-user capture directory and
returns the exact file and view identity. The Codex v1 adapter projects this
built-in host operation through its existing provider discovery/schema/read-call
tools, and the connector carries it as a backward-compatible structured
operation on `/v1/execute`. No eleventh MCP tool or sixth connector route is
introduced.

`revit.conduit.ends` and `revit.conduit.connect` are deterministic Revit host
operations. The `bimbridge.conduit.v1` provider exposes endpoint inspection
and connection through the existing MCP provider tools and the existing
`/v1/execute` route. Requests bind the exact instance and active document and
honor the existing task gate. The host validates explicit endpoint indices,
executes the route in its ordinary model transaction, and checks connector
links and the untouched ends before commit. The write preview validates
arguments and routing without dispatching a mutation. The capability uses
shared Revit source and does not depend on another installed add-in.

The resolver first removes ineligible candidates by target, runtime/API variant,
health, trust, and policy. It then prefers the narrowest deterministic provider.
An agent may request an eligible provider for reproducibility, but policy has the
final decision. No routing step may hide a provider switch after mutation might
have started.

The resulting execution plan is a deterministic, inspectable route/effect plan,
not an LLM workflow planner. Decomposing a user's broad goal into multiple AEC
requests remains the calling agent's responsibility.

Third-party providers remain pinned child processes. This process boundary
isolates lifecycle and crashes but is not, by itself, an OS security sandbox.
Provider generations are parsed and validated before an atomic switch; replaced
processes drain in-flight requests before shutdown. Their tool names
and schemas are discovered at runtime. Provider-specific tools may be projected
for advanced clients, but they are not the stable BIM Bridge Contract. Arbitrary-code
or command tools from external providers remain blocked.

## Policy and approval

The runtime is the policy decision point; product hosts are enforcement points;
agent adapters are approval presenters. This preserves one human interaction
without making Codex or DeepSeek the owner of AEC safety.

Policy evaluates adapter identity, host/document target, capability risk,
effect estimate, provider trust, dry-run evidence, and configured access mode.
`Full Access` may satisfy configurable approval rules but never overrides
immutable denies, authentication, exact-target requirements, transaction
ownership, or unsafe-scope limits. Unknown third-party adapters default to the
most restrictive policy.

An approval response is scoped to one request or a narrowly defined batch and
cannot be reused for another document, capability, effect summary, or expired
session. Contract v2 accepts only sessions registered by the runtime and grants
signed by its approval authority. The signing key is never exposed to an agent
adapter and rotates when the embedded runtime restarts, invalidating old grants.
The version 1 Codex flow remains an explicitly weaker compatibility authority.

## Verification and repair

The runtime owns verification specifications and result normalization; the
provider or product host performs checks where the strongest guarantee exists.

- For a native host operation, required postconditions should run before a
  Revit `TransactionGroup` is assimilated or before an AutoCAD transaction is
  committed when the API permits it. A failed required check then rolls back
  atomically.
- For an external provider that cannot keep the native transaction open, the
  result must state `succeeded_unverified` or `partial` until independent
  read-back completes. It must never imply atomic rollback.
- Verification failure produces structured issues and repair eligibility. The
  agent may propose a repair, but execution requires a new policy evaluation
  and, when applicable, a new approval.
- Automatic retry is limited to proven non-mutating transport/availability
  failures and must preserve the same idempotency key.

## Multi-client task coordination (development, Revit 2024 live scope)

Parallel agent preparation stays in the calling agent adapters. The Runtime does
not spawn agents, invoke models, or retain reasoning. The contract-v2
`taskControl`, `taskSnapshot`, and `taskSubmission` definitions describe neutral
instance-scoped ownership. The Runtime projects these through the discoverable
built-in `bimbridge.coordination.v1` provider and the existing ten MCP tools;
there is no additional MCP top-level tool or HTTP route.

Independent stdio Runtime processes share one enforcement authority in the exact
Autodesk connector process. `TaskCoordinator` is an Autodesk-free host lifecycle
primitive, not an agent scheduler or provider-policy engine. The Runtime still
owns capability, policy, risk, and routing decisions. The connector admits one
task at a time in FIFO order, and one native request at a time under its token.
An execution step must bind the current document identity, and the product host
rechecks that identity on its UI thread. Cached document information remains
available for discovery; legacy execution, selection and view capture cannot
interleave with an owned task. Capture accepts ownership credentials through its
discovered provider schema. Contract-v2 structured selection and verification
carry the same credentials through the read-only `selection.read` operation on
the existing execute route; tokenless legacy selection remains available only
outside an owned task. Tokens are private capability handles, not claims of
agent identity, approval grants, or a security boundary against a malicious
same-user process. Logs redact both `token` and `taskToken`.

The public queue board is the existing read-only `task_status` provider tool.
It reads one exact instance, including when there is no active document, with
ordinary connector authentication and no task lease. Its single snapshot
includes `currentTaskId` for the active or draining holder, plus the existing
task rows and one-based FIFO positions for queued rows. Each submitted task
records the connector's validated active model title at submission as
`documentTitle`; paths and path-derived document IDs are excluded. The title
is display metadata and does not change when the instance switches documents.
Execution still requires its own exact current-document check. Owner labels
are caller-supplied display text, not verified agent identities. Older
connectors can omit the additive fields.

Task control is a synchronous `task.control` operation on `/v1/execute`, with an
exact instance target and read intent only for status. Other actions continue
to require the exact document. Leases last 10–300 seconds and use
a monotonic clock. Waiting tasks must renew their waiting lease; granting starts
a fresh active lease. Expiry or cancellation first cancels any admitted request
that has not started. An already running native request enters `draining`: no new
request is admitted and ownership cannot transfer until that request is terminal.
A transport timeout never proves native execution
stopped. Release with an in-flight request is refused. Restarting the connector
invalidates all old ownership tokens; it never replays mutations. Clients must
rediscover, inspect saved outputs and explicitly resubmit after a restart. Queue
and terminal history are each bounded to 128 tasks and are not durable job storage.

Application-global external providers cannot atomically participate in this
instance gate. The Runtime refuses their execution when a coordination-capable
connector for that application is discovered; it does not silently invoke them
beside a lease. General provider reservation and durable distributed scheduling
remain future work. AutoCAD and other Revit versions are not newly certified by
this feature's Revit 2024 tests.

`tests/revit/BimBridge.Revit.FurnitureBootstrap` is a development fixture, not a
production family lifecycle capability. An explicitly configured cold child can
create a disposable RFA, let the connector own all agent modeling transactions,
then save and exit. A final cold project session loads verified RFAs and places
native family instances. Its fixed checkout output root, run/session token,
no-existing-document gate, no-overwrite checks, and temporary signed development
manifest lifecycle isolate it from user projects. Native document creation,
save/load and test assembly occur outside connector modeling transactions in
this fixture. Installed Host binaries, public installation behavior, version
matrix certification and release packaging are unchanged.

### Resident family jobs (development, Revit 2024 live scope)

Prepared family jobs are agent-neutral data, not model invocations. The Runtime
owns a bounded local ready queue and deterministic workers over explicitly
selected connector instances. A worker acquires the existing instance task lease
and runs begin, modeling, structured verification, standard view preparation,
capture and save/close before releasing ownership. Agent research and repair
remain outside the worker and never hold a native execution lease while waiting
for a model. There is no new agent SDK dependency or always-on installed daemon.

Job packages are content-bound and persisted with atomic state replacement and
a cross-process run lock. Equal job identity and content can be submitted again
without replaying a completed delivery; changed content under an existing job
identity is rejected. An interrupted in-flight stage or unknown mutation outcome
requires reconciliation and quarantines the affected worker. It is never
automatically replayed on another instance. A known terminal failure may release
its worker only after bounded cleanup and exact parking-document readback.
This local queue is not a distributed scheduler or a general reservation protocol
for application-global third-party providers.
Batch runs drain ready work. Finite producer sessions may wait for later ready
submissions until an explicit seal, with a bounded idle deadline; they never
install a permanent daemon. Execution delivery is `awaiting_review` and is not
visual acceptance. A separate explicit review binds the package content hash,
reviewer and actual image evidence before a job can become `succeeded`.
CLI failure/unknown/incomplete execution outcomes return nonzero; a successful
physical delivery still reports pending review when it has not been inspected.
Submit/status/seal/review are local queue metadata operations, not Autodesk
execution grants. Their redacted audit records identify the run, job and content
hash without recording package code. A review is an explicit caller acceptance
statement, not a new independent native verification. Each Host stage of run and
reconciliation continues through the ordinary Runtime capability policy and
instance task gate. State, package and per-stage evidence have explicit UTF-8
size/count bounds; oversized or damaged evidence fails closed with a bounded
digest and identity summary rather than being replayed or silently discarded.

`revit.family.session` is an explicit structured lifecycle capability exposed
through discoverable provider tools and the existing execute route. The shared
Revit host owns document creation, activation, standard view preparation,
save/close and abort. All actions require the instance task lease and exact
current document identity. A session binds its created family and saved parking
project to the same task owner; it cannot adopt another caller's document.
File outputs are constrained to the configured family workspace, have bounded
job/document names, reject redirecting links and traversal, and never overwrite
an existing delivery. Document lifecycle actions run outside the ordinary
generated-code modeling transaction; failures must not claim atomic rollback of
file creation or document activation. View preparation owns its explicit native
transaction. Ordinary modeling keeps the existing transaction-group guarantees.

The development furniture bootstrap additionally supports a resident parking
project. It starts only an explicitly requested disposable child; per-family
lifecycle goes through the connector rather than an Idling finish-marker poll.
The original marker mechanism remains solely for bounded final test shutdown
after all family documents have returned to parking. Resident testing uses the
same signed temporary manifests and restores installed manifests. It neither
upgrades the installed Host nor changes installer behavior or matrix certification.
Additive request timestamps distinguish received, native start and completion;
save evidence distinguishes native save start/end from dispatch waiting.

The connector and Runtime both honor the same `BIM_BRIDGE_INSTANCE_DIR` (legacy
`AEC_CODEX_INSTANCE_DIR` fallback) so disposable children can use an isolated
descriptor directory without altering installed discovery state. Request start
is atomic with cancellation (`TryStart`); a cancelled terminal request cannot
later enter a product executor after the gate has admitted another owner.

## Execution journal

Runtime audit events are redacted before they enter an append-only, hash-chained
JSONL execution journal under the current user's BIM Bridge state directory.
Independent Runtime processes coordinate each day's append through a retained
sidecar lock (`msvcrt` on Windows, `flock` on Unix). Thread and process lock
acquisition are bounded; each writer re-reads the last complete hash under that
lock before append and flush. A damaged or incomplete final record fails closed
rather than silently starting a new chain. Existing historical records are never
rewritten by this mechanism.
The journal records requests, route and policy decisions, exact targets, state
transitions, provider identity, transaction/rollback facts, verification, and
normalized results. It does not record model reasoning or chain-of-thought.

The hash chain is tamper-evident evidence, not a signature against a malicious
same-user process. Read-only operations may be reconstructed from journal data.
A mutating replay is always a new execution request with fresh target validation,
policy evaluation, idempotency handling, and approval.

## Agent adapters

The Codex package is a thin adapter containing its skill, product metadata,
MCP launch configuration, and Codex-specific approval/tool annotations. Routing
rules currently written in the skill move into runtime registry and policy data;
the skill keeps only user guidance and adapter operation instructions.

Every agent adapter uses the same session-bootstrap lifecycle and neutral Host
status semantics. On its first activation in a relevant task, it runs a
read-only probe against the shared install state and may add only its own
platform-registration evidence. The probe may report credential-free descriptor
filesystem evidence from the current BIM Bridge directory and legacy fallback,
but it does not parse or expose connector tokens and does not replace the
Runtime's authoritative descriptor validation and target selection.
When installation, repair, or upgrade is needed, it presents the exact version,
source, digest, locations, running-product constraints, and rollback behavior,
then invokes the shared host installer only after affirmative consent in that
task. The adapter performs only its own platform registration; it must not fork
the host installer, Autodesk payload, or installation state model. A skill can
be selected implicitly after a relevant user request, but does not imply a
background session-start hook on platforms that do not provide one.

The experimental Tencent WorkBuddy adapter is a repository Marketplace Plugin
that bundles a Skill, a relocatable stdio MCP declaration, and a verified
launcher wrapper. It reads the neutral Host install state, validates the recorded
launcher location and SHA-256, and delegates to the same MCP projection. The
WorkBuddy Plugin manager owns adapter installation, registration, update, and
removal; the adapter does not discover or mutate private WorkBuddy configuration
files and does not install, repair, upgrade, or uninstall the Host.
`CODEBUDDY.md` constrains WorkBuddy development to the adapter, its tests, and
its documentation unless the user explicitly expands scope. This adapter is not
certified until independent WorkBuddy end-to-end acceptance passes.

The experimental Kimi Code adapter is a repository-root Kimi plugin plus a
Kimi-format Skill, a project-MCP configuration fallback, and a verified launcher
wrapper. The plugin manifest uses only relative paths within the managed plugin
copy; the wrapper then validates the installed neutral Host launcher location
and recorded SHA-256 before delegation. The adapter does not edit Kimi user or
project configuration and does not install, repair, upgrade, or uninstall the
Host. Kimi's plugin and MCP approval UI remains the single agent-facing approval
surface, while BIM Bridge retains policy and exact-target enforcement. This
adapter is not certified until independent Kimi end-to-end acceptance passes.

DeepSeek Harness integration starts by mounting the same BIM Bridge MCP server, because
DeepSeek's tool registry already accepts MCP-discovered tools. A later native
plugin may expose an ergonomic `ctx.aec` service to other Harness plugins, but it
must be a client of the versioned BIM Bridge Contract and contain no copied runtime or
Autodesk logic. DeepSeek Harness is currently a developer preview with explicit
compatibility-breaking changes expected, so all Cordis imports and configuration
remain inside that adapter.

The project does not fork DeepSeek Harness, implement its agent loop, manage its
model/session history, or copy its permission system. The same non-goals apply to
Codex and future agent platforms.

Official DeepSeek references:

- [DeepSeek Harness repository and developer-preview notice](https://github.com/deepseek-ai/deepseek-harness)
- [DeepSeek Harness architecture and capability seams](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md)
- [DeepSeek Harness extension plugin shapes](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cookbook/extension-cookbook.md)

### DeepSeek Harness adapter contract

The working tree contains an experimental DeepSeek Harness adapter
(`adapters/deepseek-harness/**`, documented in `docs/deepseek-harness-adapter.md`).
It is a thin stdio-MCP client of the installed Host: it mounts the existing
`bim-bridge` MCP server, bridges tools only, and adds no Runtime, Host, provider
policy, or Autodesk logic. It does not install, repair, upgrade, or uninstall the
Host and never writes agent configuration.

**Shim and bundled-Node discovery.** The adapter must work on a machine where
DeepSeek Harness was never added to `PATH`, without adding a `PATH` entry and
without a machine-wide Node installation. Both the read-only status probe and the
launcher wrapper therefore resolve two executables themselves, in a fixed order,
and report the source of the candidate they used:

| `dsh` candidate order | reported source | `node.exe` candidate order | reported source |
| --- | --- | --- | --- |
| `BIM_BRIDGE_DSH_COMMAND` | `BIM_BRIDGE_DSH_COMMAND` | `BIM_BRIDGE_DSH_NODE` | `BIM_BRIDGE_DSH_NODE` |
| `dsh` on the process `PATH` | `PATH` | `node.exe` on the process `PATH` | `PATH` |
| `%LOCALAPPDATA%\Programs\DeepSeekHarness\bin\dsh.cmd` | `dsh_install` | `%LOCALAPPDATA%\Programs\DeepSeekHarness\node-*-win-*\node.exe` (newest directory name first) | `bundled_node` |
| `<dshHome>\node_modules\.bin\dsh.cmd` | `dsh_home` | — | — |

The invariants that make this contract, not a heuristic:

- **Fixed documented candidates only.** No directory tree is searched for DeepSeek
  Harness, and no private agent configuration file is parsed. The script
  interface being discovered is the same `dsh` entry point an operator invokes.
- **An override is terminal, not a hint.** When `BIM_BRIDGE_DSH_COMMAND` or
  `BIM_BRIDGE_DSH_NODE` is set, that value is the answer; a missing override is
  reported as missing and is never silently replaced by a discovered
  installation. Otherwise a status check could report success for a different
  installation than the one it was pointed at.
- **Existence is required.** A candidate is accepted only when it exists on disk,
  so a stale directory never becomes a phantom `installed: true`. With no
  candidate the status is `deepseek_harness_not_found` and the action is
  `install_deepseek_harness`.
- **Discovery never writes and never edits `PATH`** — neither the process `PATH`
  nor the persisted user `PATH`. The launcher wrapper prepends the resolved Node
  directory to the **child's** environment only, so the delegated Host process can
  rely on `node` without a global installation. A resolution failure is not fatal
  there: the wrapper's exit semantics depend only on its Host-containment checks.
- **Dependency-free execution in the spawn environment.** DeepSeek Harness spawns
  MCP stdio servers with a scrubbed environment whose `PSModulePath` can leave
  `Microsoft.PowerShell.Utility` partially loaded, so `Get-FileHash` may be absent
  while `ConvertFrom-Json` resolves. Hashing and link inspection therefore go
  through .NET and Win32 rather than through cmdlets, and both adapter scripts are
  tested against that rule.

**Wrapper integrity contract.** The launcher refuses to start unless, in order:
`install-state.json` exists with `schemaVersion` 4; the recorded launcher is
lexically inside `<StateRoot>\host\`; the launcher exists and resolves to its
final on-disk path; the launcher itself is not a reparse point; the resolved path
remains inside the Host root; the launcher has a single hard link; and the
recorded SHA-256 is 64 hexadecimal characters and matches the file. Failures are
diagnosed on stderr only and exit `1`; stdout carries nothing but MCP protocol.
On success the wrapper sets `BIM_BRIDGE_AGENT_ADAPTER=deepseek-harness` for the
delegated process and propagates its exit code. A local install-hash check is not
equivalent to release signature verification.

## Target repository ownership

The end state is organized by responsibility, but extraction precedes movement:

```text
protocol/                       # versioned AEC schemas and compatibility
runtime/aec_runtime/            # agent/transport/Autodesk-free core
  hosts/ capabilities/ routing/ policy/ verification/ providers/ audit/
adapters/
  mcp/                          # public MCP projection
  codex/                        # Codex plugin and skill
  workbuddy/                    # experimental WorkBuddy Skill/MCP adapter
  kimi/                         # experimental Kimi Plugin/Skill/MCP adapter
  deepseek-harness/             # optional thin Cordis adapter, later
  cli/                          # diagnostics and automation
src/
  BimBridge.Host/               # neutral connector transport/lifecycle
  BimBridge.Revit/              # shared Revit host plus runtime/API variants
  BimBridge.AutoCAD/            # shared AutoCAD host plus runtime/API variants
  BimBridge.AutoCAD2024/        # legacy build/package compatibility shim only
eng/                            # single Autodesk matrix, build, certification
tests/
  protocol/ runtime/ providers/ hosts/ adapters/ live/
installer/                      # transactional host packaging and migration
```

The existing `plugins/aec-codex/mcp-server/aec_mcp_server.py` currently mixes
MCP framing, instance discovery, routing, provider supervision, and validation.
It is the extraction source for `runtime/aec_runtime`, not code to duplicate.
`provider_gateway.py` is now a compatibility import for runtime provider
infrastructure. The current MCP server is a thin projection over the unified
runtime service. Physical package/namespace renames wait for the packaging phase
and must preserve the version 1 compatibility fixtures.

## Explicitly rejected alternatives

- **Do not turn BIM Bridge into a DeepSeek-only plugin.** DeepSeek is an adapter
  over the BIM Bridge Contract and may be replaced without changing Autodesk hosts.
- **Do not keep Codex as the routing and safety core.** That would force every
  future agent to reproduce Codex prompt policy and make behavior diverge.
- **Do not create an always-on daemon before it is needed.** Extract a pure
  runtime behind the existing STDIO process first; introduce broker deployment
  only for measured multi-client requirements.
- **Do not expose one model tool for every provider tool.** Capability search
  and a bounded stable surface prevent schema growth; provider-specific schemas
  remain discoverable for advanced use.
- **Do not let an LLM freely choose a provider after failure.** The runtime
  resolves eligible routes before execution and prevents unsafe fallback.
- **Do not force one dynamic compiler across incompatible runtime families.**
  Keep the compiler seam stable and select implementations by tested runtime
  evidence.
- **Do not move every directory in the first implementation phase.** Contract
  tests and behavior-preserving extraction precede structural cleanup.

## Revit runtime matrix

| Revit release/API line | Target framework | Runtime family | Dynamic compiler | Add-in isolation |
| --- | --- | --- | --- | --- |
| 2024 | `net48` | `netfx` | CodeDOM | unavailable |
| 2025 through the .NET 8 servicing line | `net8.0-windows` | `modern` | Roslyn | preferred when supported |
| 2025 after Autodesk's .NET 10 servicing migration | `net10.0-windows` | `modern` | Roslyn | preferred when supported |
| 2026 through 2026.4 | `net8.0-windows` | `modern` | Roslyn | required for BIM Bridge |
| 2026.5 and later | `net10.0-windows` | `modern` | Roslyn | required for BIM Bridge |
| 2027 | `net10.0-windows` | `modern` | Roslyn | required for BIM Bridge |
| 2028+ | declared after Autodesk publishes requirements | new or existing family | selected by family | required when available |

Revit 2024 requires .NET Framework 4.8. Revit 2025 and the original Revit 2026
line use .NET 8. Autodesk migrated serviced 2025/2026 product lines to .NET 10;
the installed Revit 2026.5 API on the certification machine already requires
`System.Runtime` 10. Revit 2027 also uses .NET 10. Build selection therefore
reads the installed `RevitAPI.runtimeconfig.json` for matrix entries whose
runtime can change during servicing, validates the detected target against the
entry's allowed targets, and records the resolved runtime in build and test
evidence. A future release or service update must never be assigned a runtime
by guessing from its year.

Official references:

- [Revit 2024 development requirements](https://help.autodesk.com/cloudhelp/2024/ENU/Revit-API/files/Revit_API_Developers_Guide/Introduction/Getting_Started/Welcome_to_the_Revit_Platform_API/Revit_API_Revit_API_Developers_Guide_Introduction_Getting_Started_Welcome_to_the_Revit_Platform_API_Development_Requirements_html.html)
- [Revit 2025 migration to .NET 8](https://help.autodesk.com/cloudhelp/2025/ENU/Revit-API/files/Revit_API_Developers_Guide/Introduction/Getting_Started/Using_the_Autodesk_Revit_API/Revit_API_Revit_API_Developers_Guide_Introduction_Getting_Started_Using_the_Autodesk_Revit_API_NET8_Update_html.html)
- [Revit 2026 add-in dependency isolation](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-API/files/Revit_API_Developers_Guide/Introduction/Add_In_Integration/Revit_API_Revit_API_Developers_Guide_Introduction_Add_In_Integration_Add_in_Dependency_Isolation_html.html)
- [Autodesk 2025/2026 product-line .NET 10 servicing update](https://blog.autodesk.io/autodesk-desktop-products-2025-2026-net-10-updates/)
- [Revit 2027 migration to .NET 10 and API changes](https://help.autodesk.com/view/RVT/2027/ENU/?guid=f7165618-24c9-4160-a7a4-09979fe4a981)

## AutoCAD runtime matrix

| AutoCAD release/API line | Target framework | Runtime family | Dynamic compiler | Bundle series |
| --- | --- | --- | --- | --- |
| 2024 / 24.3 | `net48` | `netfx` | CodeDOM | `R24.3` |
| 2025 before its announced .NET 10 servicing migration | `net8.0-windows` | `modern` | host-shipped Roslyn | `R25.0` |
| 2025 after its announced .NET 10 servicing migration | `net10.0-windows` | `modern` | host-shipped Roslyn | `R25.0` |
| 2026 before 2026.1.2 | `net8.0-windows` | `modern` | host-shipped Roslyn | `R25.1` |
| 2026.1.2 and later | `net10.0-windows` | `modern` | host-shipped Roslyn | `R25.1` |
| 2027 | `net10.0-windows` | `modern` | host-shipped Roslyn | `R26.0` |

AutoCAD 2025 and 2026 resolve the installed runtime from
`acdbmgd.runtimeconfig.json` and validate it against their matrix allow-list.
AutoCAD 2027 is fixed to .NET 10 and verifies that installed metadata agrees.
The 2026.1.2 update on the current development machine already reports
`net10.0`; its adapter therefore builds for `net10.0-windows` rather than
guessing from the release year. Modern AutoCAD already ships the matching
Roslyn assemblies inside the host, so each exact adapter references those
assemblies without copying a competing compiler version into the bundle.

Official references:

- [AutoCAD managed .NET compatibility](https://help.autodesk.com/cloudhelp/2027/ENU/AutoCAD-Customization/files/GUID-A6C680F2-DE2E-418A-A182-E4884073338A.htm)
- [Autodesk 2025/2026 product-line .NET 10 servicing update](https://blog.autodesk.io/autodesk-desktop-products-2025-2026-net-10-updates/)

## Version authority

Two version numbers exist in this repository. They mean different things, they
are declared in different places, and only one of them may be derived from the
other. Neither may be guessed.

| Value | Authoritative source | Current value | Meaning |
| --- | --- | --- | --- |
| Package version (SemVer) | `Directory.Build.props` `<Version>` | `2.0.0-alpha.4` | The release/package identity the installer, release manifest, release notes, and Host state directory publish. A prerelease label belongs here. |
| Assembly identity | `Directory.Build.props` `<AssemblyVersion>` / `<FileVersion>` | `2.0.0.0` | The CLR assembly identity of `BimBridge.*` binaries. |
| Autodesk bundle version | `eng/Get-BimBridgeVersion.ps1` mapping, asserted against every declared site | `2.0.0` | The stable numeric value rendered into `ApplicationPackage/@AppVersion` and `ComponentEntry/@Version`. |

`eng/Get-BimBridgeVersion.ps1` is the single source of the mapping. It reads
`Directory.Build.props` and applies one explicit rule: **strip the SemVer
prerelease and build-metadata segments, keep the dotted numeric core**. So
`2.0.0-alpha.4` maps to `2.0.0`, `1.1.0-rc.3` to `1.1.0`, and an unparsable
version throws instead of mapping to something plausible.

Why the Autodesk value is not simply the package version: for an AutoCAD bundle
manifest, `ComponentEntry/@Version` is the **minimum required AutoCAD product
version**, so it is not package identity and a prerelease string is not "the
same version with a suffix". Writing `2.0.0-alpha.4` there could change Autodesk
load gating, which is why the mapping is a deliberate, documented transformation
rather than a copy. `ApplicationPackage/@AppVersion` and `ComponentEntry/@Version`
receive the same derived value from one substitution point
(`src/BimBridge.AutoCAD/PackageContents.template.xml` `{{APP_VERSION}}`).

`tests/architecture/Test-BimBridgeVersionAuthority.ps1` holds every declared
Autodesk AppVersion to the mapped value: the
`eng/AutodeskVersionMatrix.ps1` parameter default, the
`eng/Build-AutoCADAdapters.ps1` call site, the positional
`installer/Install-BimBridge.ps1` call site, the legacy
`src/BimBridge.AutoCAD2024/PackageContents.xml`, and the staged bundle under
`artifacts/staging/**`. The same test asserts that this document names both
values, so the documented contract and the code cannot drift apart silently.
Replacing those three literals with calls to the helper is a follow-up for the
files' owners; until then a drift fails that test rather than shipping.

## Single version matrix

The repository contains one machine-readable MSBuild matrix at
`eng/Autodesk.Versions.props`. Each Revit entry owns at least:

- release year and support status;
- runtime family, runtime-resolution policy, default target framework, and
  allowed serviced target frameworks;
- expected installation/API reference location;
- adapter assembly and artifact names;
- add-in manifest behavior, including isolation;
- dynamic compiler implementation;
- structured-provider availability;
- certification state and required test suite.

The parameterized Revit project at
`src/BimBridge.Revit/BimBridge.Revit.csproj`, shared matrix
resolver `eng/RevitVersionMatrix.ps1`, adapter build, and live-test entry point
consume this matrix today. For a runtime-migrating release the resolver reads
the installed API's runtime metadata and emits artifacts under the resolved
target framework directory. The generic adapter is built through the matrix
script with an explicit version and is intentionally not added to the ordinary
solution build, which remains usable on machines without every Revit release.
Diagnostics, documentation tables, packaging, and the installer must
also derive version behavior from the matrix. They must not maintain parallel
hard-coded lists of years or assume that one release year always maps to one
runtime artifact.

The matrix is named for Autodesk rather than Revit deliberately. AutoCAD
multi-version entries now live in this same source with product-qualified
properties for target/runtime resolution, supported target frameworks, assembly
identity, bundle series, dynamic compiler, support status, and certification;
no separate AutoCAD year list is allowed. The
long-term support key is `(product, release, resolved API/runtime variant)`, not
just a four-digit year. Certification state attaches to that exact key. Build
scripts may expose product-specific views of the matrix, but those views are
derived and never independently edited.

Each release entry therefore distinguishes target frameworks that the shared
source can support from the exact target frameworks certified for distribution.
The signed release manifest is a derived snapshot of those certified variants,
so lightweight adapter preflight can identify an installed but uncertified
Autodesk runtime as skipped before Host mutation. A skipped runtime does not
block compatible installed products. Release packaging copies every and only
the matrix-certified variants and fails if any declared artifact is absent; it
must never select whichever single output happens to exist on the packaging
machine.

## Shared Revit implementation

The shared Revit engine owns:

- application startup and shutdown;
- `ExternalEvent` creation and dispatch;
- connector instance registration and refresh;
- active document and selection reporting;
- read request execution;
- write transaction groups, commit, failure, and rollback semantics;
- capability reporting and audit results.

The parameterized version build owns only:

- the exact Revit API references;
- target framework and assembly identity;
- generated `.addin` metadata;
- a bounded compatibility implementation for real API differences.

All shared sources live under `src/BimBridge.Revit` and compile into the
`BimBridge.Revit` namespace and `BimBridge.Revit<year>.dll` assembly identity.
The same project is evaluated
once per requested matrix entry and emits a distinct assembly/output directory
for that Revit release. Avoid scattered
`REVIT2027`-style conditional compilation; put unavoidable differences in the
central compatibility boundary with tests.

`src/BimBridge.Revit2024` contains a project/manifest compatibility shim that
preserves the legacy installer and build input paths. The BIM Bridge installer
consumes the neutral matrix-built output instead. The shim imports the neutral
adapter properties and contains no Revit business source; remove it with the
legacy installer binding, never copy it for newer releases.

## Shared AutoCAD implementation

All AutoCAD product behavior lives under `src/BimBridge.AutoCAD`. The shared
implementation owns extension startup and shutdown, connector registration,
active-document and selection reads, document locking, native transactions,
rollback evidence, dynamic-code execution, and exact adapter identity checks.
The same project is evaluated once per resolved matrix entry and emits
`BimBridge.AutoCAD<year>.dll` into a version/runtime-specific output directory.

Per-release variation is limited to the exact installed managed API references,
target framework/runtime family, assembly metadata, Autodesk bundle series, and
a bounded compatibility mapping for observed API release identifiers. The
current 2024 through 2027 APIs require no copied product implementation.
`src/BimBridge.AutoCAD2024` is a legacy build/package input shim that imports the
shared adapter properties and contains no C# business source; it must not be
copied for later years.

One generated `BIM Bridge.bundle` may contain several certified variants. Each
matrix-derived component has an exact `SeriesMin`/`SeriesMax` and loads its DLL
and private dependencies from a release-specific subdirectory. Pending or
experimental entries are never included merely because the product is present.

## Dynamic code compilation

The connector exposes separate read and write fallback tools whose C# method
bodies are compiled inside the selected Revit process.

- The .NET Framework runtime service uses CodeDOM.
- Modern .NET runtime services use Roslyn.
- The shared executor depends on a compiler interface and contains no runtime
  or year checks.
- Compiler dependencies must ship beside the matching adapter and must be
  included in dependency-isolation tests.

Compiler uniformity is not an architectural goal by itself. Revit 2024 keeps
CodeDOM for the certified baseline because it is native to the .NET Framework
runtime and has the smallest dependency surface. Roslyn targeting `net48` may
later be evaluated as an alternate runtime-family implementation for improved
diagnostics or analysis, but only behind `IRevitCodeCompiler` and only after
load/dependency/security tests. Upper layers must never distinguish CodeDOM
from Roslyn.

AutoCAD uses the same compiler-interface rule inside its own product boundary:
2024 retains CodeDOM, while 2025 and later compile through the Roslyn version
shipped by the exact AutoCAD host. Revit and AutoCAD do not share Autodesk API
code or transaction implementations.

Generated code receives the documented Autodesk context variables and runs with
the Autodesk process and user's OS permissions. A `read` mode expresses query
intent and transaction behavior; it is not a security sandbox because code can
reach ambient host and OS APIs. All arbitrary dynamic code is therefore a
critical capability and requires approval. Low-risk reads must use structured,
precompiled capabilities.

## Add-in manifests and dependency isolation

Add-in manifests are generated from the version matrix and one template. A
manifest is not copied and edited by year.

Modern Revit adapters should run outside Revit's default assembly context when
the version supports it. Revit 2026 and later use the stable `BIM.Bridge`
context name and `<UseRevitContext>False</UseRevitContext>` so Roslyn, JSON, and other
private dependencies do not collide with Revit, Dynamo, or unrelated add-ins.

Current-user add-in locations remain version-specific:
`%APPDATA%\Autodesk\Revit\Addins\<year>`. All-user locations must be obtained
from the version matrix because Autodesk changed their security/location rules
in Revit 2027.

## Transactions and rollback

Every Revit write executes in one `TransactionGroup` and one bounded
`Transaction` unless an explicitly documented operation requires a different
native pattern. Generated code does not own these objects.

An exception or failed commit rolls back the request and returns
`rolledBack: true`. Success is reported only after commit and transaction-group
assimilation. A failed structured-provider mutation must not be retried through
dynamic code as a way around its safety boundary.

Connector-owned Revit transactions install one shared, non-interactive failure
preprocessor. Native warnings are captured in the execution result and removed
from Revit's modal failure pipeline; native errors are captured, force rollback,
and return a failed result with `rolledBack: true`. The product host must never
wait for an agent or user to click a Revit failure dialog, and it must not use UI
automation to dismiss one.

## Automated certification

Testing is layered:

1. Contract tests cover schema evolution, version negotiation, normalization,
   idempotency, and version 1 compatibility without an agent or Autodesk.
2. Runtime tests cover host selection, capability resolution, policy,
   deterministic routing, provider failure boundaries, verification, approval
   grant scope, audit correlation, timeouts, and cancellation.
3. Provider tests cover capability metadata, targeting, dry-run behavior,
   result normalization, and refusal to fall back after a rejected or possibly
   mutating call.
4. Matrix builds compile each host adapter against the exact installed Autodesk
   API. Compatibility tests exercise the bounded per-version API surface.
5. A separate development smoke-test driver launches the exact Revit executable
   and creates a disposable project without depending on a person at the UI.
6. Live acceptance verifies connector discovery, version/document routing,
   selection/read behavior, a representative write and read-back, intentional
   failure with complete rollback, clean document close, and connector cleanup
   on Revit shutdown.
7. Adapter contract tests prove Codex, MCP, CLI, and later DeepSeek projections
   create equivalent BIM Bridge requests and interpret equivalent results. End-to-
   end tests are additive; one agent's success never certifies another adapter.

The smoke-test driver may create a project from an installed template, save it
under a disposable test directory, then open and activate it. It must never use
a production model. Each run emits a machine-readable report containing the
Revit build, process ID, adapter version, document identity, checks performed,
and pass/fail evidence.

`eng/Run-RevitLiveAcceptance.ps1 -Version <year>` is the live certification
entry point. It uses one in-process bootstrap source compiled against the same
resolved matrix entry and one Autodesk-free external .NET driver. The bootstrap
activates only when its child Revit process receives a random request path,
validates a run ID and token, refuses an already active document, and permits
file creation only beneath
`artifacts/certification/revit/<year>/<run-id>`. The external driver probes
structured providers first, then performs all Revit interaction through the
version-independent MCP tools and an exact connector instance ID.

`eng/Run-AutoCADLiveAcceptance.ps1 -Version <year>` is the matrix-driven AutoCAD
certification entry point. With `-IsolateCurrentUserPlugins` it temporarily moves
only the installed current-user `BIM Bridge.bundle`, loads the exact signed test
adapter with a generated AutoCAD script, and restores the production bundle in
`finally`. Its external driver performs exact MCP routing, selection, read,
committed write/read-back, intentional rollback/read-back, cleanup, save to a
disposable certification DWG, clean process shutdown, and descriptor cleanup.
The driver archives an exact stale test descriptor if failure requires forced
process termination; it never attaches to an existing AutoCAD process or opens
a user drawing.

Every run writes `report.json` in its run directory. The driver verifies load,
exact version/process/document routing, selection, read, committed write and
read-back, intentional exception with `rolledBack: true`, rollback read-back,
runtime dependency location, test-element cleanup, clean Revit shutdown, and
connector descriptor cleanup. It never attaches a certification run to an
already running Revit process of the same exact release.

Live-test add-ins must have a valid trusted Authenticode signature before the
default entry point launches Revit. The driver does not click or suppress
Autodesk's publisher prompt; it fails fast with `untrusted_binary` evidence.
`-AllowUnsigned` exists only for an explicitly prepared development machine
whose Revit trust policy already permits those exact artifacts, and is not a
release or CI mode.

An installed production manifest that owns the same add-in ID blocks live
certification by default. On a dedicated certification machine,
`-TemporarilyDisableConflictingManifests` may move only the exact conflicting
manifest out of Revit's `*.addin` discovery pattern for the duration of the
run. The entry point must restore every moved manifest in `finally`, including
after build, launch, driver, or cleanup failure; it must never overwrite a path
that became occupied while the test was running.

`-IsolateCurrentUserAddins` extends the same reversible mechanism to every
pre-existing `*.addin` in the selected Revit year's current-user add-in
directory. Certification uses this mode when an unrelated or unsigned
current-user add-in could display a modal prompt or otherwise contaminate the
result. It does not alter all-user manifests, installed binaries, trust stores,
or Autodesk security settings, and follows the same no-overwrite restoration
rule.

`eng/Initialize-RevitLiveTestTrust.ps1` creates or reuses one self-signed
current-user development code-signing certificate, stores its non-exportable
private key only in `Cert:\CurrentUser\My`, and trusts the public certificate
only in the current user's Root and TrustedPublisher stores. Its non-secret
state is recorded below `%LOCALAPPDATA%\BIM Bridge\development-trust`. When that
state exists, the live-test entry point signs only the generated adapter and
bootstrap DLLs inside this repository after every build and verifies their
Authenticode status before deployment. This trust is development-only and
must never be reused as release signing or installed by the release installer.

## Migration sequence

The redesign proceeds through compatibility gates. A later phase does not begin
by deleting the previous working path.

### Phase 0: freeze and complete the baseline

**Status: complete.** The exact reports and frozen version 1 fixture are stored
in the repository artifacts and protocol tests; installer work remained frozen.

- preserve the passing Revit 2025, 2026, and 2027 reports;
- certify Revit 2024 and establish an AutoCAD 2024 unattended baseline;
- record the current MCP tool schemas and connector protocol fixtures;
- make no release-installer changes.

### Phase 1: introduce contract version 2 beside version 1

**Status: complete for the schema boundary.** Contract-v2 schemas, golden
examples, negative fixtures, and compatibility tests exist beside version 1.

- add schemas for targets, capabilities, requests, results, errors,
  verification, policy decisions, and approval grants;
- add golden compatibility and negative tests;
- keep current MCP tool names and connector `/v1` endpoints as a facade.

### Phase 2: extract the agent-free runtime

**Status: complete for the current production surface.** Host and provider
lifecycle behavior is owned by `runtime/aec_runtime`; legacy modules are import
facades only.

- move descriptor discovery, target selection, validation, and request polling
  out of `aec_mcp_server.py` into importable runtime modules;
- move provider lifecycle and classification out of `provider_gateway.py`;
- keep the MCP server as the only production adapter until behavior parity and
  existing MCP tests pass.

### Phase 3: make capabilities and providers explicit

**Status: complete for the current connector and structured-provider paths.**
The registry emits deterministic inspectable route plans, records targeting and
trust, honors only eligible provider preferences, and forbids fallback after an
execution attempt starts.

- add the registry and provider interface;
- encode current precedence, targeting limitations, and no-fallback rules as
  data and tests rather than skill prose;
- wrap connector operations, structured MCP tools, and dynamic code without
  changing their host implementation.

### Phase 4: add policy, verification, and correlated audit

**Status: embedded agent-free slice implemented; shared host path live-certified,
direct v2 adapter certification pending.** Exact write targets are revalidated by
the product host on its UI thread before execution. Runtime-issued sessions,
signed non-replayable grants, direct v2 execution, read-back verification,
normalized evidence, and a redacted hash-chained journal are implemented and
tested. On 2026-08-14 the same host execution path passed unattended live
acceptance through the version 1 Codex compatibility facade on Revit 2024.1,
2025.4, 2026.5, 2027.2, and AutoCAD 2024. This does not certify a future direct
version 2 agent adapter. The version 1 Codex facade continues to recognize Codex
as its weaker legacy approval authority.

- introduce deterministic risk/effect planning and request-bound approval
  challenges while retaining the version 1 Codex compatibility path;
- normalize transaction, change, rollback, and verification evidence;
- do not add autonomous repair or an LLM to the runtime.

### Phase 5: thin the Codex adapter

**Status: complete for the ten-tool facade, with the 2026-08-14 security
annotation revision.** The MCP process owns STDIO
framing, version negotiation, schemas, and argument validation; all host,
provider, routing, and policy behavior is delegated to `BimBridgeRuntime`.

- replace routing policy in the skill with runtime capability discovery;
- keep Codex-specific tool annotations, installation hooks, and approval
  presentation only;
- rerun all existing Codex-to-Revit and Codex-to-AutoCAD acceptance tests.

### Phase 6: add DeepSeek Harness compatibility

**Status: MCP-mount slice implemented as an experimental adapter; native-plugin
slice still deferred.** The thin stdio-MCP adapter described under "DeepSeek
Harness adapter contract" mounts the certified `bim-bridge` MCP server, and its
read-only status, wrapper containment, and PATH-less discovery are covered by its
own test suite. No `ctx.aec` service exists, Contract v2 is untouched, the
adapter is not independently certified, and this does not start the
Codex-independent sequencing decision that the rest of the phase depends on.

- first mount the certified BIM Bridge MCP adapter as a Harness MCP plugin
  (implemented for the experimental adapter);
- optionally add a small `ctx.aec` service wrapper only after the version 2
  contract is stable;
- pin the tested Harness version because its developer preview permits breaking
  changes, and test the adapter independently from the BIM Bridge Runtime.

### Phase 7: generalize AutoCAD versions

**Status: complete for AutoCAD 2024-2027.** AutoCAD 2024 has been extracted into
the shared, matrix-driven product host. Exact builds and unattended live
acceptance pass for AutoCAD 2024 (`net48`), 2025 (`net8.0-windows`), 2026
(`net10.0-windows`), and 2027 (`net10.0-windows`).

- convert AutoCAD 2024 into a shared AutoCAD host plus matrix-driven variants;
- reuse the same contract, runtime, capability, policy, and certification
  layers; do not reuse Revit transaction code or API compatibility shims.

### Phase 8: redesign packaging and installation

**Status: published Codex-only alpha preview; stable cross-machine gate pending.** The lightweight
`bim-bridge` plugin and Skill bootstrap are separated from the transactional
Windows Host installer. The installer uses the Autodesk matrix, deploys the
four certified Revit and four certified AutoCAD runtime variants when present, records hashes,
refuses loaded Autodesk processes, migrates known legacy-owned components, and
rolls back files and MCP registrations on failure. The immutable preview archive
is pinned by SHA-256 in a detached-signature-verified manifest. Stable promotion
and adapting other agents remain separate future gates.

- package the certified runtime, selected agent adapters, providers, and exact
  host variants;
- retain one recoverable installation transaction and one aggregated restart;
- support Codex-only, DeepSeek-only, both, or runtime/CLI deployments without
  changing host binaries.

## Licensing and legal materials

The unreleased licensing-transition working tree offers original BIM Bridge
code under PolyForm Noncommercial 1.0.0 or a separately executed commercial
license from Sideswipe3751. Existing Apache-2.0 grants and immutable releases
remain unchanged; third-party components retain their own licenses. See
`docs/license-transition.md` for the boundary and preserved license record.
New Host and public-submission archives include `LICENSE`, `NOTICE`,
`LICENSE-APACHE-2.0`, `THIRD_PARTY_NOTICES.md`, `COMMERCIAL.md`,
`COMMERCIAL_LICENSE_TEMPLATE.md`, and `docs/license-transition.md`.
This changes legal-material inclusion and metadata only: it introduces no
runtime license check, agent dependency, installer consent flow, or alteration
to signed release manifests and their pinned artifacts.

## Installer boundary

The packaging phase is active for the Codex-only alpha preview. The Codex
plugin is deliberately lightweight: it ships the Skill, a read-only status
probe, and an approved bootstrap wrapper, but does not own or auto-start an MCP
server. The Windows Host installer separately deploys the agent-independent
runtime and matching certified Autodesk connectors, then registers the external
`bim-bridge-local` MCP. The installer consumes certified artifacts and the version matrix; it does not decide
compatibility itself.

The public GitHub repository is a Codex Repo Marketplace, a WorkBuddy Plugin
Marketplace, and a Kimi repository Plugin source. The same short user request
containing its repository URL may authorize the active agent to install only its
own lightweight adapter. It does not authorize another agent's adapter or native
Host mutation. After the platform's required reload or restart boundary, the
installed Skill performs the same bundled read-only status check and presents
the exact Host plan before obtaining current-task consent. For ordinary remote
users, an unavailable or signature-invalid Host release must remain fail-closed;
an agent must not substitute a cloned development source, source build, unpinned
download, or standalone Skill installation for the signed release path.

Install state hashes the launcher, MCP/runtime source, Autodesk adapters and
manifests, and the critical private-Python bootstrap binaries. It does not hash
every standard-library or optional package file on every Skill activation;
packaged-archive checksum verification protects the complete release payload,
while the bounded installed-file set keeps the per-task read-only status probe
responsive.

Its required behavior is:

- support a lightweight agent package that can bootstrap the shared native host
  after a read-only status check and explicit current-task approval; installing
  the agent package alone is not consent to modify Autodesk or host state;
- discover installed Autodesk versions;
- deploy only matching, certified artifacts;
- report and leave incompatible installed Autodesk versions untouched while
  continuing to deploy other matching certified connectors;
- keep connector support separate from optional provider support;
- refuse unsafe replacement of assemblies loaded by a running Autodesk process;
- apply all selected versions as one recoverable installation transaction;
- restore every previous target if any version fails;
- record installed files and hashes per product/version;
- aggregate restart requirements so one final restart is sufficient.

Release-package validation combines two gates. The archive-level gate verifies
every exact certified product/runtime variant from the matrix, independent of
what is installed on the packaging machine. The installer's read-only
`-ValidateOnly` path then resolves Autodesk products actually installed on the
validation machine and verifies their exact packaged connector, manifest, and
private-Python inputs without creating staging directories or changing MCP
registration. An installed runtime that is supported by source but not listed
as certified for that release is reported as skipped before mutation; it does
not fail or roll back connectors for other compatible versions. Any stale BIM
Bridge manifest for a skipped Revit version is removed inside the same
recoverable transaction so Autodesk cannot load an incompatible connector.

Autodesk product discovery is shared by the lightweight read-only status probe
and the packaged Host installer. It accepts a product/version keyed explicit
override when supplied, otherwise checks validated Windows installer registry
records before falling back to matrix-derived Program Files paths. A candidate
is installed only when its expected product executable and API assembly are
both present; the resolved path and discovery source are retained as status and
install-state evidence. Runtime-generated Python `__pycache__` directories and
`.pyc` files are neither release inputs nor immutable install-state records.

For the legacy migration, known installer-owned paths and the
`aec-codex-local` registration may be removed inside the same rollback boundary.
Unknown data and development trust under the legacy state root are preserved.
The alpha does not install optional structured providers. An agent package must
not modify native state merely because a task started: bootstrap happens on the
first relevant Skill activation, and mutation still requires explicit consent
in that task.

After a successful install or repair, the installer may remove only stale
`staging-*` and `rollback-*` directories that resolve directly beneath the BIM
Bridge state root. It must never broaden that cleanup to the state root itself
or to unknown legacy directories.

## Staged packages, builder output, and gaps

The matrix builders are also the offline staging path. `-BundleDirectory` writes
a repository-local development package and nothing else: no Autodesk location,
no user state, and no registry entry is written by a builder. The staged
layouts, and which document is authoritative for each, are contract:

| Artifact | Written by | `relativePath` / path base | Authority |
| --- | --- | --- | --- |
| `autocad/BIM Bridge.bundle/PackageContents.xml` | `eng/Build-AutoCADAdapters.ps1` via `New-AutoCADPackageContents` | `ModuleName="./Contents/Windows/<year>/<assembly>.dll"`, relative to the bundle root with forward slashes | the matrix renderer and the bundle manifest schema |
| `revit/bundle-manifest.json` (the Revit staging index) | `eng/Build-RevitAdapters.ps1` | relative to the bundle root with forward slashes; each entry carries the same value in `path` and `relativePath` | the builder implementation and `eng/RevitVersionMatrix.ps1` |
| `artifacts/integration-regression/staging-manifest.json` (the integration manifest) | `artifacts/integration-regression/New-IntegrationManifest.ps1` | **relative to the staging root**, i.e. one directory above the Revit bundle root, and it additionally records a `targetPath` for each future installation location | the integration generator |

Two distinct manifest schemas exist, so the same field name means two different
bases. This is a deliberate, documented fact rather than an inconsistency to be
"fixed" in code: the Revit builder's index is a machine-mergeable fragment whose
paths must be resolvable from the package the integrator assembles, while the
integration manifest describes a package that also contains the AutoCAD bundle.
Neither schema may be described using the other's base, and no consumer may
assume `relativePath` means "relative to whatever directory I happen to hold".

**Builder output contract.** Both builders emit JSON on standard output, and the
shape is decided by one rule that is identical for both of them:

| Invocation | Standard output |
| --- | --- |
| No staging parameter and no envelope parameter | A **top-level JSON array** of per-release result rows — the legacy contract that existing callers iterate after `ConvertFrom-Json`. |
| Any explicit staging parameter (`-BundleDirectory`, or the Revit `-RenderManifestDirectory`) | A **JSON object** (the envelope). AutoCAD returns `results` and `bundle`; Revit returns `results`, `renderedManifests`, `gaps`, and `bundle`. |

The field set inside that envelope is the intentional, documented asymmetry:
Revit's `bundle` carries `releases`, `fileCount`, and `unavailableReleases`, which
AutoCAD's does not, because AutoCAD neither renders add-in manifests nor reports
unavailable releases. **Explicit staging intent must never silently discard the
bundle summary**: the run that created a staged bundle is the only run whose
output describes it, so a builder that wrote a bundle and then printed the array
would lose that description with no error and no other artifact to recover it
from.

`-Envelope` is therefore an accepted, redundant spelling of "staging intent" and
is **not** required alongside `-BundleDirectory`: passing `-BundleDirectory` alone
already selects the envelope, exactly as the Revit builder does. The reverse is
also fixed — an envelope-only invocation (`-Envelope` without a staging
directory) reports `bundle = null` for AutoCAD and never invents a staged path.

No in-repository consumer parses this JSON: the installer, both live-acceptance
entry points, and the architecture tests check exit codes or the script source.
The contract is nevertheless closed, because the array-versus-object choice is
observable to any out-of-repository caller and used to be an asymmetry between
the two builders. A change to either shape is an interface change that must be
reflected here.

**Output-contract status.** The rule above is stated as the contract and not as a
description of a transition period. Two behaviours are made uniform by it: the
array-versus-envelope selection itself, and the single staging-intent rule that
selects it. `-Envelope` remains an accepted parameter for AutoCAD callers that
already pass it; it is simply no longer the only way to reach the envelope. Any
builder or test that still treats `-BundleDirectory` without `-Envelope` as an
array contradicts this section and is a defect to fix there, not a second
interpretation of the contract.

**Output-contract coverage.** The default-array half of the contract is asserted
by `tests/architecture/Test-AutoCADVersionArchitecture.ps1` and
`tests/architecture/Test-RevitVersionArchitecture.ps1`: each runs its builder with
no staging parameter and requires output that starts with `[` and carries neither
`results` nor `bundle`. The envelope half is asserted by both tests for both
staging parameters: Revit through `-BundleDirectory` and
`-RenderManifestDirectory`, AutoCAD through `-Envelope` and, separately, through a
*successful* staging run that passes `-BundleDirectory` without `-Envelope` and
requires the object shape, a named bundle directory and a non-empty bundle summary.
That last case was previously uncovered — nothing failed if AutoCAD withheld the
envelope whenever `-Envelope` was omitted — so both halves of the contract are now
asserted per builder.

**Deletion containment guard.** Both builders are allowed to delete exactly one
thing: a staging directory they own, inside the namespace
`<canonical repository root>\artifacts\staging`. They default to their own
subdirectory (`artifacts\staging\autocad-bundles` and
`artifacts\staging\revit-bundles`), and a caller-supplied `-StagingRoot` moves the
*staging root* without moving the containment namespace. Every deletion target —
`-BundleDirectory`, the Revit `-RenderManifestDirectory`, and the staging root
itself — passes the same assertion chain, whose rules are contract and are
implemented identically in `eng/Build-AutoCADAdapters.ps1` and
`eng/Build-RevitAdapters.ps1`:

- **Raw traversal segments are refused before any canonicalisation.**
  `Assert-InContainmentNamespace` first splits the *raw* input path on `[\\/]` and
  refuses the value if any segment is exactly `..` (case-sensitive), and only then
  calls `[IO.Path]::GetFullPath`. The check covers both the deletion candidate and
  the staging root, because both are inputs to the same assertion. This order is
  the rule: `GetFullPath` collapses `..`, so a normalisation-first
  implementation silently accepts `foo\..\bar`, and a path that folds back inside
  the namespace — `artifacts\staging\x\..\artifacts\staging\y` — would be refused
  only as "outside the repository artifacts staging area", which misreports a
  deliberate traversal refusal as a containment verdict. A traversal refusal must
  always name traversal.
- **Every existing intermediate segment between the containment root and the
  staging root is classified.** `Get-SafeStagingRoot` walks the segments from the
  canonical containment root down to the requested staging root and throws on the
  first existing link-style reparse point, before it classifies the staging root
  itself. A staging root is a namespace and may be named before it exists, so
  segments that do not exist are skipped rather than created; only existing
  segments can carry a link, and classifying just the final staging root left a
  junction or symbolic link in an intermediate segment free to redirect the later
  recursive delete outside the repository staging namespace. The failure is
  fail-closed: the invocation throws, nothing is deleted, and any file outside the
  namespace is left byte-identical.
- **Link classification is by reparse tag, not by attributes.** Only the
  directory-junction/mount-point tag (`0xA0000003`) and the symbolic-link tag
  (`0xA000000C`) can redirect a recursive delete, and only those two are refused.
  A host that classifies every synced folder as a reparse point (the cloud
  placeholder tag of a synced working copy, `0x9000e01a`) must keep working, so a
  non-link reparse point is not treated as an escape — a guard that refuses on the
  reparse *attribute* instead of the tag would refuse the repository's own working
  copy. A tag that cannot be read is the exception: the tag is what decides, so a
  read failure is refused instead of assumed benign, and a tag value that is not
  an eight-digit hexadecimal tag is refused rather than read as a non-link. A host
  that reports the reparse attribute for a synced directory and then answers that
  the path is not a reparse point is the one accepted non-link outcome, because
  there is no tag that could redirect anything.
- **Containment is proven on canonical paths with separator-terminated,
  case-insensitive prefixes**, checked against both the staging root and the
  `artifacts\staging` namespace, so a sibling such as `artifacts\staging-evil` is
  not inside the namespace.
- **The staging root is never itself a deletion target**, and a deletion candidate
  is canonicalised through its deepest existing ancestor with the link-style
  reparse points of that ancestor chain rejected.
- **The chain from the repository root down to and including the containment root
  is classified too.** Classifying only the segments *after* the containment root
  left the namespace's own anchor unverified: `artifacts` and `artifacts\staging`
  are the two components a recursive delete ultimately depends on, and the
  canonicalising step resolves a path through a link instead of reporting it, so
  a link there is invisible to every check that trusts the canonical value.
  Every existing segment of the canonical repository root → `artifacts` →
  `artifacts\staging` chain is therefore walked and classified with the same
  reparse-tag rule as the segments
  below it, and the containment root itself is classified as well, not only the
  requested staging root. Until this rule existed, a junction or symbolic link at
  the containment root — the precise thing an attacker-controlled staging layout
  would use — was never classified, so the namespace could be relocated by the
  anchor the rest of the guard trusted.
- **A missing containment root is not an escape, and a segment that cannot be
  trusted is a refusal.** A first run has no `artifacts\staging` yet, so an absent
  segment is skipped rather than created or rejected, exactly as below the
  containment root. An existing segment that cannot be inspected, that is not a
  directory, or whose reparse tag cannot be read fails closed: the tag decides
  whether the segment is a link escape, so an unreadable tag cannot be treated as
  the permissive case. These classifications run in the same validation pass as
  the rest of the assertion chain, which is why the refusal happens before any
  write and before any removal.

**Deletion-time re-check contract.** The guard above is a *contract about the
moment of deletion*, not only about the moment the build starts:

- **Every recursive force-removal is immediately preceded by its own complete
  guard invocation, and it removes only the path that invocation returns.**
  Concretely, `Assert-ContainedStagingDirectory` is called again at the removal
  site and the removal target is the value it returns from that call. Between the
  preflight and a removal there can be a long build, and the target can be
  replaced by a junction or symbolic link in that window; a path proven
  safe earlier is not proven safe at deletion time. Each removal site therefore
  calls the full assertion chain again in its own right and passes the canonical
  path returned by *that* call to the removal, never a path retained from an
  earlier check.
- **The preflight is preserved and is still required, but it is never sufficient
  authorisation for a later removal.** An unsafe input must keep being refused
  before any build work starts, so the up-front validation stays; a removal that
  relies on it alone contradicts this contract.
- **The same rule governs the Revit render-manifest path.** Overwriting, clearing
  or writing `-RenderManifestDirectory` content is a mutation of the containment
  namespace and is authorised the same way: re-derived by the guard at the point
  of use, not enabled by an earlier result.
- **The re-check is not short-circuited by the preflight's target having
  disappeared.** It re-derives the canonical path through the deepest existing
  ancestor and makes its own existence decision, so a target that is absent at
  deletion time is still classified rather than deleted on the strength of an
  earlier verdict; a re-check that trusts a stale existence test and skips the
  guard degrades to an unguarded removal and contradicts this section.
- **Adjacency is structure, so it is asserted structurally.** The guard call and
  the removal it authorises are adjacent statements — no other write, removal or
  path-producing operation between them — and the assertion applies to every
  recursive force-removal site in both builders, not to a sample. A removal
  authorised by a path computed before intervening work fails the structure
  assertion even when the guard itself is still called somewhere earlier.
- **Both builders carry the same structure with their own evidence.** The two
  implementations are semantically symmetric — same refusal classes, same
  rejection timing, same canonical-path source — and differ only in error text
  (`bundle directory` versus `staging directory`) and in their default staging
  subdirectory name. Symmetry is required to be proven by paired assertions in
  the two architecture tests, one per builder, rather than by reading one
  builder's source and assuming the other matches.

**Path-guard regression coverage.** The guard contract above is carried per
builder by `tests/architecture/Test-AutoCADVersionArchitecture.ps1` and
`tests/architecture/Test-RevitVersionArchitecture.ps1`, which are the independent
evidence for it and are required to exit 0. Each test drives the pure guard
functions without dot-sourcing a builder into the test
scope, requires a traversal refusal (not an `outside the` verdict) for a raw `..`
input and for a traversal that folds back inside the staging namespace, requires a
*deletion-time* containment failure when an intermediate junction inside the
repository staging namespace points at a controlled external directory, and
requires every external witness or sentinel file to survive unchanged.

The regression coverage required for the two rules above lives in those same two
tests, in the same style, rather than in a new file. Per builder, that coverage
must: place a controlled junction as the containment root itself and require a
refusal before any write or removal, with the external witness file's SHA-256 and
content unchanged; require that a non-link reparse tag (the cloud placeholder tag
of a synced working copy) is *not* refused, because a host that classifies every
synced folder as a reparse point must keep building, while a segment whose
reparse tag cannot be read is refused; and show, from the builder's own parsed
structure, that each recursive force-removal site is preceded directly by a guard
invocation whose returned canonical path is the removal target. The execution half
replaces the target with a controlled junction after the preflight and requires
the removal to be refused with the outside witness intact. All fixtures are
run-scoped scratch directories under the system temp root, never a real user
profile, repository root or Autodesk installation directory; a fixture the host
refuses to create fails the test instead of being skipped, so a missing negative
case cannot pass silently.

`tests/architecture/Test-ArchitecturePathGuard.ps1` does **not** exist in the
working tree, and it is no longer a required new file: the two per-builder tests
above already carry the independent regression for both rules, which is why this
section previously describing it as "the required new test" was inaccurate. A
separate consolidated test file would only de-duplicate that coverage; it is not
a gap in the contract.

**Unavailable-release gap semantics.** A requested Autodesk release whose product
is not installed, whose API reference is absent, or whose runtime cannot be
resolved is reported as an explicit `gap`, never as a fabricated success and
never as a silent skip:

- The `results` entry for that release has `status = "unavailable"`, a `reason`,
  and a stable `gap` id of the form `revit-<year>-not-installed`.
- The `gaps` entry is the full evidence record built by
  `New-RevitUnavailableGap`: `id`, `year`, `product`, `missing` and
  `expectedPath` (the first probed path that was absent), `probeCommand`, the
  per-path `probeEvidence`, `observed`, `blockedTask`, `impact`, `severity =
  "blocking"`, and `fakeSuccess = false`.
- The staged Revit index carries the same records in `unavailableReleases`, and
  the integration manifest republishes them as `revitUnavailableReleases`.
- Without `-SkipUnavailable` the builder fails closed and throws instead of
  staging a partial package.

Revit 2026 is the current instance of this case: it is not installed on the
certification machine, so the staged package deliberately contains no Revit 2026
connector and declares `revit-2026-not-installed`. The matrix entry stays
`certified`, and absence of an installed product never removes an entry from the
matrix. A skipped runtime does not block compatible installed products, and any
stale manifest for the skipped release is removed inside the installer's
recoverable transaction rather than left for Autodesk to load.

## Adding a future Revit release

1. Verify Autodesk's runtime, SDK, API, add-in location, and isolation changes.
2. Add one version-matrix entry with support status `experimental`.
3. Build the parameterized adapter; its manifest is generated from the shared
   template.
4. Compile shared code against the exact new Revit API.
5. Add a compatibility shim only for observed API differences.
6. Run the complete unattended live acceptance suite for every supported
   runtime/API build variant that will be shipped.
7. Change status to `certified` only after evidence is recorded for the exact
   variant; never infer certification of a .NET 10 service update from a .NET 8
   result for the same release year.
8. Allow packaging and installation only for certified entries.

The normal case should require a matrix entry and certification, not a copied
codebase. Autodesk runtime or API breaks may require a new runtime service or a
small compatibility implementation, but must not leak version checks through
the shared engine.

## Architecture change rule

An implementation change requires an architecture update in the same change
when it alters any of the following:

- trust or process boundaries;
- supported product/version/runtime matrix;
- source ownership between shared and version-specific layers;
- connector protocol, capabilities, routing, or approval semantics;
- dynamic compilation or dependency loading;
- transaction and rollback guarantees;
- automated certification requirements;
- packaging, install, repair, upgrade, restart, or uninstall behavior.

Small implementation details that preserve these contracts do not require a
document edit, but reviewers must still verify the document before making the
change.
