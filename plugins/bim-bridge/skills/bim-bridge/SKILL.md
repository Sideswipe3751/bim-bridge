---
name: bim-bridge
description: Bootstrap, set up, repair, upgrade, diagnose, control, inspect, draw, model, and verify local Autodesk Revit and AutoCAD sessions through BIM Bridge. At the first activation of every Codex task concerning BIM Bridge, Revit, or AutoCAD, use this skill to run the read-only session bootstrap before any MCP or Autodesk call. Also use when the user asks to install or configure BIM Bridge, check connector health, discover open Autodesk applications, inspect a project or drawing, query the current selection, read model or entity data, create, update, or delete Revit elements and AutoCAD entities, or validate completed CAD/BIM work with structured readback and focused visual checks.
---

# BIM Bridge

Use BIM Bridge as the only route into Revit or AutoCAD. The Codex plugin and
skill IDs are `bim-bridge`; the existing `aec_*` MCP tool names and
Legacy `Aec.Codex.*` assemblies are migration inputs only. BIM Bridge 2.x host
and Autodesk adapter assemblies use `BimBridge.*` identities.
Keep all Autodesk API operations inside the target application's connector.

## Session bootstrap gate

At the first activation in every relevant task, before calling a BIM Bridge MCP
tool or performing any Autodesk operation, run
`../../scripts/Get-BimBridgeHostStatus.ps1`. Resolve this path relative to this
`SKILL.md`; it points to the script shipped in the same plugin. The check is
read-only and returns JSON. Run it once per task unless an install, repair,
upgrade, restart, or other relevant external-state change makes the result
stale. Do not download a status script or substitute a remembered path.

Implicit invocation lets Codex select this skill when a user first asks about
BIM Bridge, Revit, or AutoCAD. It does not create a background hook in a task
where the skill has not been invoked. Never claim that an idle task performed a
check or installation.

- Continue to the MCP workflow only when the status is `healthy`.
- For `not_installed`, `needs_prerequisite`, `needs_repair`,
  `needs_upgrade`, or `restart_required`, read [setup.md](references/setup.md)
  and follow that workflow.
- For install, repair, or upgrade, present the exact plan and obtain affirmative
  user consent in the current task before running the mutating installer. After
  a successful mutation, stop Autodesk work and require the restart/new-task
  verification described in `setup.md`.
- Do not install, repair, upgrade, or uninstall native components during the
  read-only check.
- Do not treat installing this Codex plugin as consent to modify Autodesk,
  AppData, the local MCP registration, or other local software.

## Workflow

1. Call `aec_list_providers` with `probe: true` and use the Runtime's discovered
   provider and capability metadata; do not assume a provider precedence from prose.
2. Call `aec_search_provider_tools`, inspect the selected tool with
   `aec_get_provider_tool_schema`, then use `aec_call_provider_read` or
   `aec_call_provider_write` as classified.
3. For a write, call the write tool with `dryRun: true` first. A gateway
   preview does not execute; a provider preview delegates simulation to the
   upstream MCP. Execute with `dryRun: false` only when the request authorizes
   the change under the current Codex approval policy.
4. If discovery proves no structured capability covers the operation, call
   `aec_list_instances` before requesting the explicit dynamic-code capability.
5. If more than one compatible instance is running, identify the target from
   the application, version, and document. Ask only when the user's intent does
   not determine a unique target.
6. Read current state before changing it. Prefer document, selection, query,
   and property tools over arbitrary code.
7. Use a write tool only when the user requested a change. Keep the operation
   inside one native transaction when atomic rollback is appropriate.
8. For drawing, modeling, creation, or layout work, read
   [drawing-quality.md](references/drawing-quality.md) and run the completion
   and verification loop below.
9. Read back the affected objects and report concrete identifiers and results.

## Parallel preparation and exclusive host tasks

For a multi-agent modeling request, agents may prepare independent specifications
and code in parallel. Discover the installed task coordination tools through the
normal provider search/schema workflow; do not assume an older Host supports them.
For the queue board, discover `task_status` and call it through
`aec_call_provider_read` with the exact `instanceId`. Match `currentTaskId` to
its task row and show queued rows by `queuePosition`. Show `owner` as a
caller-supplied label and `documentTitle` as the model at submission; report
missing model metadata as unknown on older connectors. No task token is needed.
Submit one named task against an explicit instance, retain its private task token,
and poll until active before any Autodesk execution. Renew queued and active leases
before expiry. Do not share tokens with unrelated agents or log them.

Keep the task for the complete bounded modeling and verification sequence. Each
step must name the current expected document; re-read after waiting. Code steps
remain explicit critical dynamic-code operations even for query intent, and use
the write provider tool with preview first. Coordination is not a reason to bypass
structured-capability discovery, approval, transaction or target requirements.
Pass task credentials to a discovered capture capability for visual verification.
Release only after all admitted steps have terminal results. Cancel unused queued
tasks. A timeout or draining state is not permission to transfer ownership, replay
a write, or send it to another instance. After a connector restart, rediscover and
inspect saved results before submitting a new task. See
[multi-agent tasks](references/multi-agent-tasks.md) for the development workflow.

## Completion and verification loop

For every creation or update whose result can be checked:

1. Translate the request into concrete success criteria, including the target
   document, units, geometry, placement, quantity, properties, and relevant
   drawing or model conventions. Resolve material ambiguity before writing.
2. After the write, perform a structured readback of the affected objects.
   Verify identifiers, types, geometry, dimensions, placement, layers or
   categories, properties, counts, and relationships relevant to the request.
3. When appearance, layout, annotation, or spatial coordination matters,
   perform a focused visual check after the structured check. Prefer a
   discovered read-only provider or connector view-capture/export tool.
   Otherwise use an available Codex screenshot capability only when the user
   requested or authorized visual verification. Do not invent a capture tool.
4. Limit visual capture to the target view or affected region. Do not capture
   the full desktop, unrelated applications, or unrelated project content.
5. Compare both checks with the success criteria. Treat structured data as the
   authority for exact geometry and properties; use the image to detect
   clipping, overlap, alignment, scale, readability, and other visual defects.
6. If a material check fails, diagnose the cause, apply the smallest bounded
   correction, and repeat every affected check. After two unsuccessful
   correction passes, stop and report the unresolved issue instead of entering
   an unbounded edit loop.
7. Do not claim completion until required checks pass. Report the affected
   identifiers, checks performed, corrections made, and any limitation such as
   unavailable or unauthorized visual capture.

## Tool selection

- Use `aec_get_document_info` for product, version, active document, units, and
  capabilities.
- Use `aec_get_selection` before making assumptions about the user's selection.
- Discover every structured provider and tool dynamically. Do not encode a
  provider name, precedence, or remembered schema in the adapter instructions.
- Use `aec_execute_read` only when no structured read tool covers the required
  Autodesk API surface. It executes arbitrary in-process code with ambient host
  and OS authority, so honor its destructive annotation even when the intended
  Autodesk operation is a query.
- Use `aec_execute_write` only when no structured create/update tool covers the
  request. Treat it as potentially destructive because arbitrary code can
  delete or overwrite data.
- Never send Revit API code to AutoCAD or AutoCAD API code to Revit.
- Do not fall back to generated code merely because a structured call was
  denied, invalid, or failed during a mutation. Fallback is for missing
  capability, not a way around a provider safety boundary.

## Approval and safety

- Let Codex apply the user's action-approval policy. Do not ask for or simulate
  a second approval inside Revit or AutoCAD.
- Do not bypass a tool's destructive annotation or disguise a write as a read.
- Use explicit object identifiers and bounded queries. Avoid document-wide
  writes unless the request clearly requires them.
- Verify that a disposable document is active before development smoke tests.
- Stop when the connector reports a version, document, transaction, or API
  context mismatch; do not retry a write against another instance implicitly.

## References

- Read [multi-agent-tasks.md](references/multi-agent-tasks.md) for parallel
  preparation, instance ownership, prepared family jobs and resident workers.
- Read [setup.md](references/setup.md) for installation, repair, upgrade,
  restart, health-check, and uninstall requests.
- Read [protocol.md](references/protocol.md) when diagnosing discovery, routing,
  authentication, request status, or connector compatibility.
- Read [tool-routing.md](references/tool-routing.md) before generating fallback
  Autodesk API code or combining several write operations.
- Read [providers.md](references/providers.md) for provider precedence,
  previews, blocked tools, version updates, and fallback rules.
- Read [drawing-quality.md](references/drawing-quality.md) for drawing,
  modeling, creation, layout, annotation, and post-write verification tasks.
