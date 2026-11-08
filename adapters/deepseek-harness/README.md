# BIM Bridge for DeepSeek Harness

This directory contains the experimental DeepSeek Harness (DSH) compatibility
layer. It reuses the installed, agent-independent BIM Bridge Host and the existing
stdio MCP projection. It contains no Autodesk implementation, no DSH-specific
Runtime, and no second Autodesk version matrix.

Verified against DSH `0.1.5-rc.2`.

## What is different from the other adapters

Kimi Code and WorkBuddy each read an MCP declaration file that their own platform
understands. DSH does not have one: there is no `dsh mcp` command, and MCP servers
are registered as `@deepseek-ai/dsh-mcp-client` rows inside a profile's composed
Cordis configuration. This adapter therefore ships:

- the verified launcher wrapper and status/config scripts (same contract as the
  other adapters);
- `mcp.template.json` in the shared template shape, for documentation;
- a generator that emits the row DSH actually loads.

## Setup

DeepSeek Harness does not have to be on the user's `PATH`. The scripts resolve
`dsh` and the Node interpreter themselves, preferring an explicit override, then
the process `PATH`, then the per-user installation under
`%LOCALAPPDATA%\Programs\DeepSeekHarness` (whose `bin\dsh.cmd` already carries the
bundled Node directory). Nothing is written and no `PATH` is edited. See
[the adapter guide](../../docs/deepseek-harness-adapter.md#discovery-without-a-global-path)
for the full order and the two override variables.

1. Confirm the neutral Host is healthy:

   ```powershell
   & .\adapters\deepseek-harness\skills\bim-bridge\scripts\Get-BimBridgeDshStatus.ps1
   ```

2. Generate the DSH server row:

   ```powershell
   & .\adapters\deepseek-harness\skills\bim-bridge\scripts\Get-BimBridgeDshMcpConfig.ps1 -Style cordis-patch
   ```

   Paste the output into a profile patch overlay. The generator is read-only: it
   never writes DSH user configuration.

3. Make the Skill discoverable by pointing a scanned skill root (or
   `customSkillDirs`) at `adapters/deepseek-harness/skills`, then reload or restart
   as the active profile's `patchReload` requires.

   Keep the Skill's frontmatter to the keys `name`, `description`, `whenToUse`,
   `disable-model-invocation`, `user-invocable`, and `metadata`. The invocation
   keys are hyphenated, and a rejected spelling such as `disableModelInvocation`
   or a non-boolean value makes the whole Skill disappear from the catalog with
   only a warning.

4. Confirm the tools appear as `mcp__bim-bridge__<rawName>`.

The MCP wrapper verifies the installed Host launcher location and SHA-256 before
delegating stdio to it. A local hash check is not equivalent to release signature
verification, and this adapter does not claim otherwise.

## Current boundary

This initial version requires the neutral BIM Bridge Host to be installed and
healthy. It reports and stops on a missing or changed Host. Host install, repair,
upgrade, uninstall, signing, and release publishing are outside this adapter.

See [the adapter guide](../../docs/deepseek-harness-adapter.md) for acceptance
criteria.
