# BIM Bridge

[![CI](https://github.com/Sideswipe3751/bim-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/Sideswipe3751/bim-bridge/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Sideswipe3751/bim-bridge?include_prereleases)](https://github.com/Sideswipe3751/bim-bridge/releases)

BIM Bridge connects Codex—and, through the versioned contract, future agent
adapters—to Autodesk Revit and AutoCAD. Its agent-independent runtime combines
dynamically discovered structured tools with authenticated, version-aware host
connectors for inspection, bounded execution, policy-controlled writes,
verification, and correlated audit evidence.

> [!IMPORTANT]
> BIM Bridge 2.0 is a development alpha. Use disposable drawings and models
> for write testing, keep backups, and review the support matrix below.

## One-sentence installation

Copy the same sentence into Codex, Tencent WorkBuddy, or Kimi Code:

> Install and configure BIM Bridge from https://github.com/Sideswipe3751/bim-bridge.

The current agent reads the repository installation contract and installs only
its own thin adapter: Codex uses its Repo Marketplace, WorkBuddy uses its Plugin
Marketplace, and Kimi uses its repository plugin. See
[INSTALL.md](INSTALL.md) for the deterministic agent procedure and security
boundaries. Installing an agent plugin is not consent to modify Autodesk or
install the native Host.

### Codex

Codex adds the Repo Marketplace and installs the lightweight **BIM Bridge**
plugin. The installed Skill performs the read-only Host preflight and presents
the exact native plan before asking for separate consent.

### Tencent WorkBuddy

WorkBuddy installs the repository's `bim-bridge` Marketplace plugin, which
contributes both the WorkBuddy Skill and the verified stdio MCP declaration:

```text
/plugin marketplace add https://github.com/Sideswipe3751/bim-bridge
/plugin install bim-bridge@bim-bridge
```

Restart or reload WorkBuddy plugins and start a new task. This replaces the
earlier manual Skill import and JSON-paste development flow.

### Kimi Code

Kimi Code uses the same one-sentence request and its repository plugin entry:

```text
/plugins install https://github.com/Sideswipe3751/bim-bridge/tree/main
/reload
```

Start a new session and ask Kimi to check BIM Bridge. The repository-root Kimi
plugin contributes the Skill and the verified stdio MCP launcher. Plugin
installation still does not authorize native Host installation or repair; the
experimental adapter reports an unavailable Host and stops. See
[the Kimi adapter guide](docs/kimi-adapter.md).

## Capabilities

- Discovers local Revit and AutoCAD sessions without exposing a network port
  beyond loopback.
- Routes structured operations through pinned Revit and AutoCAD MCP providers.
- Previews writes before execution and keeps the active agent adapter as the
  single user-facing approval layer.
- Falls back to authenticated, explicitly approved Autodesk API code when a
  structured tool does not cover the required operation. Arbitrary query code
  is treated as ambient-authority code, not as a low-risk read tool.
- Uses native transactions or undo groups when atomic rollback is appropriate.
- Installs per Windows user and rolls installation changes back on failure.
- Includes a private, version-pinned Python runtime; end users do not need to
  install or configure Python.

### Revit conduit connections (development)

The `bimbridge.conduit.v1` provider in a matching development Host exposes
`get_conduit_ends` and `connect_conduits`. Read the two conduits by element ID
and specify the endpoint index (0 or 1) for each. Calls require the Revit
`instanceId` and active `documentTitle`. Use the provider write tool with
`dryRun: true` to preview the request before executing it.

The router joins straight, same-diameter conduits directly, with one elbow,
or with a bridging conduit and two elbows. It preserves the opposite ends
and their connections, and returns the route and created element IDs. It
uses Revit's project fittings and does not perform clash detection.

## Support matrix

| Product | Version | Runtime | Status |
| --- | --- | --- | --- |
| AutoCAD | 2024 / R24.3 | .NET Framework 4.8 | Unattended live acceptance passed |
| AutoCAD | 2025 / R25.0 | .NET 8 | Unattended live acceptance passed |
| AutoCAD | 2026 / R25.1 | .NET 10 | Unattended live acceptance passed |
| AutoCAD | 2027 / R26.0 | .NET 10 | Unattended live acceptance passed |
| Revit | 2024.1 | .NET Framework 4.8 | Unattended live acceptance passed |
| Revit | 2025.4 | .NET 8 | Unattended live acceptance passed |
| Revit | 2026.5 | .NET 10 | Unattended live acceptance passed |
| Revit | 2027.2 | .NET 10 | Unattended live acceptance passed |

No Autodesk version is considered certified until its exact connector and a
representative set of read/write operations pass inside that product.

## Architecture

- `runtime/aec_runtime`: BIM Bridge Runtime host discovery, provider
  supervision, capability routing, policy, verification, and audit.
- `plugins/bim-bridge`: lightweight Codex Skill and approved Host bootstrap.
- `adapters/workbuddy`: experimental Tencent WorkBuddy Marketplace Plugin,
  Skill, and MCP adapter over the same installed neutral Host.
- `adapters/kimi`: experimental Kimi Code Plugin, Skill, and MCP adapter over
  that same Host.
- `plugins/aec-codex/mcp-server`: version-1 compatibility MCP projection over
  the agent-independent runtime; packaged by the Host installer, not owned by
  the new Codex plugin.
- `protocol`: versioned BIM Bridge discovery and request contracts.
- `providers`: pinned upstream builds, security patches, schema snapshots, and
  controlled update commands.
- `src`: shared bridge, one matrix-driven Revit adapter, and Autodesk connector projects.
- `eng`: the single Autodesk version matrix and reusable adapter build entry points.
- `tests`: MCP, bridge, provider-bundle, and live acceptance tests.
- `installer`: current-user install, repair, uninstall, bootstrap, and release
  packaging scripts.
- `docs`: architecture, security, compatibility, and live-test notes.

Connectors publish short-lived descriptors under the current user's profile.
The MCP host accepts only `127.0.0.1` connector URLs and authenticates every
request with a per-process bearer token. See [the architecture notes](docs/architecture.md).

## Installation status

Prerequisites:

- Windows x64
- Codex, Tencent WorkBuddy, or Kimi Code for the matching agent adapter
- AutoCAD 2024–2027 and/or one of the certified Revit releases listed above

BIM Bridge 2.0.0-alpha.4 is available as a signed preview Host release. The
lightweight agent plugin remains separate from the native Host. For Codex:

```powershell
codex plugin marketplace add Sideswipe3751/bim-bridge --ref main
codex plugin add bim-bridge@bim-bridge
```

To replace an already installed older Plugin, refresh the Marketplace and
recreate its installed cache:

```powershell
codex plugin marketplace upgrade bim-bridge
codex plugin remove bim-bridge@bim-bridge
codex plugin add bim-bridge@bim-bridge
```

Restart Codex and start a new task about BIM Bridge. The installed Skill verifies
the detached release-manifest signature and pinned Host SHA-256 before offering
installation. Ordinary remote users must not substitute a source build or an
unpinned download.

Repository contributors may instead clone the repository and add its root as a
local marketplace. That development-only path is documented in
[INSTALL.md](INSTALL.md) and must not be presented as the public install path.

The first task performs a read-only preflight. It reports the exact release,
SHA-256, prerequisites, running Autodesk applications, and current-user paths
before asking for permission. Only after the user confirms does Codex run the
approved host installer. The installer deploys the private runtime and
registers the external local MCP as `bim-bridge-local`.

Autodesk products installed outside Program Files are discovered from their
Windows installer registration. The same validated discovery code is used by
preflight and installation, and an explicit product-path override is available
for installations whose registration is incomplete.

Restart Codex and the Autodesk applications after host installation, then
start another new task for the health check. In Revit, click **Revit MCP
Switch** once per session to start the structured-provider listener. See
[the first-run guide](docs/first-run-setup.md) for the complete states and
recovery flow.

Ask BIM Bridge to repair or uninstall the host in a task. Both operations show
their planned current-user changes and require confirmation.

## Build and install from source

A Revit adapter build requires the .NET SDK and that exact Revit release at its
default path. Build every locally available matrix entry with:

```powershell
& .\eng\Build-RevitAdapters.ps1 -SkipUnavailable -Configuration Release
```

The Codex-only development installer discovers installed products from the
single Autodesk matrix and deploys only certified matching variants. Close all
Revit and AutoCAD sessions, then run:

```powershell
& .\installer\Install-BimBridge.ps1 -Action Install -MigrateLegacy
```

This installs the local Host and `bim-bridge-local` MCP registration. The
lightweight Codex plugin is installed separately; structured providers are not
included by default.

The installer builds the matrix-selected adapters, installs the connectors for
the current user, and restores the previous installation if any step fails.

Check pinned upstreams without activating them:

```powershell
& .\providers\Update-AecProviders.ps1 -Action Check
```

Provider activation is versioned. Server and schema updates take effect in a
new Codex task; a changed Revit provider add-in also requires a Revit restart.
`-Action Rollback` swaps back to the previous active provider configuration.

## Test

Run the dependency-free MCP tests and shared bridge tests:

```powershell
python -m unittest discover -s tests\mcp -p "test_*.py"
dotnet run --project tests\BimBridge.Host.Tests -c Release -f net10.0
& .\tests\architecture\Test-RevitVersionArchitecture.ps1
& .\tests\architecture\Test-AutoCADVersionArchitecture.ps1
& .\tests\adapters\workbuddy\Test-WorkBuddyAdapter.ps1
& .\tests\adapters\kimi\Test-KimiAdapter.ps1
```

When verified provider artifacts are available, also run:

```powershell
& .\providers\Test-ProviderBundles.ps1
```

The Autodesk 2024 manual acceptance sequence is documented in
[docs/live-test-2024.md](docs/live-test-2024.md).

## Release status

The current repository state is a published alpha preview. The immutable Windows
x64 Host archive, SHA-256, and detached release-manifest signature are available
from the GitHub prerelease. Stable promotion remains gated on independent
cross-machine installation and upgrade evidence.

## Contributing and security

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request. Please report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md), not in a public issue.

## Licensing

**BIM Bridge — Free for Noncommercial Use, Commercial License Required**

The post-transition original code is offered by Sideswipe3751 under
[PolyForm Noncommercial License 1.0.0](LICENSE), with the required copyright
notice in [NOTICE](NOTICE). Noncommercial use is free; you may view, copy,
modify, and share source code according to the license. Its express permissions
also cover the organizations listed in its Noncommercial Organizations section,
including government institutions; organization type alone does not imply a fee.

Commercial uses outside those permissions, such as ordinary paid BIM project
work or commercial software integration, require a separate commercial license.
See [COMMERCIAL.md](COMMERCIAL.md) for scope, individual/seat/enterprise licensing,
and **Contact for Pricing**. Contact: **TODO: provide commercial licensing contact**.
The [commercial agreement template](COMMERCIAL_LICENSE_TEMPLATE.md) is a draft
for legal review and grants no rights until a completed agreement is executed.

Previously published Apache-2.0 code retains its existing rights, including
commercial use under that license. The change is not retroactive; see
[the transition record](docs/license-transition.md) and the preserved
[Apache-2.0 text](LICENSE-APACHE-2.0). The repository remains Public and
source-available; the noncommercial license is not OSI-approved open source.
Third-party components keep their own licenses and notices; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Trademarks

Autodesk, AutoCAD, and Revit are trademarks or registered trademarks of
Autodesk, Inc. BIM Bridge is not affiliated with or endorsed by Autodesk.
