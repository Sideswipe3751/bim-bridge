---
name: bim-bridge
description: Drive Autodesk Revit and AutoCAD through the installed BIM Bridge Runtime. Use when a task involves BIM Bridge, Revit, AutoCAD, a .rvt or .dwg model, or any aec_* tool.
type: prompt
whenToUse: The task mentions BIM Bridge, Revit, AutoCAD, RVT/DWG documents, or aec_* tools.
disable-model-invocation: false
---

# BIM Bridge on DeepSeek Harness

This Skill is the DeepSeek Harness thin adapter for BIM Bridge. It does not
implement Revit or AutoCAD behaviour, and it is not a second Runtime. All model
work is performed by the neutral `aec_*` tools that the installed bim-bridge MCP
server publishes.

## First activation in every task

Before the first BIM Bridge tool call in a task, run the bundled read-only status
check:

```powershell
& "<SKILL_DIR>\scripts\Get-BimBridgeDshStatus.ps1"
```

It returns JSON. Read `status` and `recommendedAction` before continuing:

| `status` | Meaning | Action |
|---|---|---|
| `healthy` | DSH and the installed Host are both usable | Continue |
| `deepseek_harness_not_found` | no `dsh` resolved, including the per-user installation | Report as an environment blocker |
| `not_installed` | no BIM Bridge install-state | Ask the user to install the Host |
| `needs_repair` | state unreadable, or a critical Host file is missing/changed | Ask the user to repair the Host |

The status check is read-only. It never installs, repairs, upgrades or removes
anything, and it never edits DSH configuration. It resolves DeepSeek Harness
without requiring a global `PATH` entry and reports the `commandSource` and
`nodeSource` it used; see `references/setup.md` for that order.

## How the tools appear

DeepSeek Harness registers MCP tools through `@deepseek-ai/dsh-mcp-client`. Each
BIM Bridge tool therefore appears under a server-qualified name:

```text
mcp__bim-bridge__aec_...
```

Call those tools normally. Only MCP **tools** are bridged: MCP resources and
prompts are not available in DeepSeek Harness, so do not look for them.

## Boundaries you must respect

- The Runtime is independent of every agent SDK. This adapter must never become
  a place where Revit/AutoCAD logic or a provider policy lives.
- There is exactly one BIM Bridge Contract and one Autodesk version matrix. Do not
  create a DSH-specific compatibility table, and do not hard-code the product
  versions that happen to be installed on this machine.
- Do not install, repair, upgrade or uninstall the native Host or any Autodesk
  product as part of an ordinary task.
- Do not impersonate Codex, and do not reuse or fabricate an approval grant.
- Do not retry a denied or possibly-already-executed write by switching provider
  or by generating new code dynamically.

## Writes

The MCP server enforces the policy and verification semantics, not this Skill.
Before a write, state exactly which document and which objects you intend to
change, prefer a dry-run when the tool offers one, and verify by reading back
afterwards. The Host performs exact instance/document checks and owns native
transactions and rollback; report a failed rollback as a failure rather than
retrying it as a fresh write.

See `references/setup.md` for registration and reload, and
`references/acceptance.md` for the per-version acceptance record.
