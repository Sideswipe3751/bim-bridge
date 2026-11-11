---
name: bim-bridge
description: Inspect, model, draw, and verify local Autodesk Revit and AutoCAD sessions through the installed BIM Bridge Host and MCP Runtime.
type: prompt
whenToUse: Use when the user asks to set up, diagnose, inspect, draw, model, change, or verify BIM Bridge, Revit, or AutoCAD.
disableModelInvocation: false
---

# BIM Bridge for Kimi Code

Use the configured `bim-bridge` MCP server as the only route into Revit or
AutoCAD. The existing `aec_*` MCP tool names are shared version-1 compatibility
identifiers. Do not rename them or create a Kimi-only request model.

## First activation gate

At the first activation in every Kimi Code session concerning BIM Bridge,
Revit, or AutoCAD, run this read-only command:

```powershell
& "${KIMI_SKILL_DIR}\scripts\Get-BimBridgeKimiStatus.ps1"
```

Resolve `${KIMI_SKILL_DIR}` through Kimi's Skill placeholder. Run the probe
again only after the Host, plugin, MCP configuration, Kimi Code version, or
Autodesk process state changes.

- Continue to MCP only when `status` is `healthy`.
- For `kimi_code_not_found`, explain that this adapter targets Kimi Code CLI.
- For `not_installed` or `needs_repair`, read `references/setup.md`, report the
  exact evidence, and stop. This experimental adapter does not mutate the Host.
- Installing this plugin or loading this Skill is not permission to modify
  Autodesk, `%LOCALAPPDATA%\BIM Bridge`, or Kimi configuration.

## MCP workflow

1. Call the provider discovery tool with probing enabled; do not assume a
   provider name or precedence.
2. Search available provider tools and inspect the selected schema before
   supplying arguments.
3. Read the target document, current selection, and affected objects before a
   write.
4. Preview writes with `dryRun: true` when the selected tool supports it.
5. Execute only the user-authorized bounded change against the exact
   application, process, instance, and document.
6. Do not fall back to arbitrary Autodesk code after a structured write is
   denied, invalid, failed, or may have started mutation.
7. Read back identifiers, geometry, properties, counts, and relationships that
   define success.
8. When appearance or spatial coordination matters, use the discovered focused
   view-capture capability after structured verification.

For the queue board, discover `task_status` and call it through
`aec_call_provider_read` with the exact `instanceId`. Use `currentTaskId` to
find the holder, `queuePosition` to order waiting tasks, and `owner` and
`documentTitle` for the applicant label and submission model. No task token
is needed. Report missing model metadata as unknown on older connectors.

## Kimi permissions and safety

- Kimi Code is the single user-facing approval layer. Keep normal approval mode
  for write acceptance testing and do not create a blanket permanent allow rule
  for `mcp__bim-bridge__*`.
- `--yolo` or `--auto` does not weaken BIM Bridge authentication, target checks,
  policy, transactions, or rollback, and must not be presented as a safety
  bypass.
- Dynamic-code reads and writes have ambient Autodesk-process and OS authority;
  treat both as critical capabilities.
- Never switch providers or Autodesk instances after mutation may have started.
- Stop on target, authentication, transaction, or version mismatch.
- Do not claim completion until required structured readback and focused visual
  checks pass.

For setup and debugging, read `references/setup.md`.
