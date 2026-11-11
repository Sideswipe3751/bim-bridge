# Per-version acceptance record

This phase covers only the seven product builds actually installed on this
machine. That list bounds this work and its acceptance; it is **not** a new
product support matrix. Compatibility continues to be decided by
`eng/Autodesk.Versions.props` and the Runtime. Never hard-code these versions in
adapter logic.

## The five questions, recorded separately

For each product build, record all five. They are different questions and must
never be collapsed into one "pass":

| # | Field | Meaning |
|---|---|---|
| 1 | product installed | the product executable exists on this machine |
| 2 | runtime recognized | the shared Runtime recognises the installed runtime |
| 3 | matching connector deployed | the Host records a matching connector for that product/year |
| 4 | MCP discoverable | the BIM Bridge MCP server lists the tool during `tools/list` |
| 5 | DSH end-to-end result | DeepSeek Harness itself loaded and called a BIM Bridge tool |

Result values: `PASS`, `FAIL`, `BLOCKED`, `NOT RUN`. Nothing unexecuted or
unverifiable may be recorded as `PASS`. A product with no matching connector or a
failed connection is `BLOCKED` with a reason — do not substitute another year, and
do not install a Host to make it pass.

## Route the work by product

Use the connector route that matches each product. Do not invent a route and do
not borrow another year's connector.

## Required sequence per version

All Autodesk writes are serial. Never operate on the same instance or document
concurrently.

1. Create a disposable, task-owned RVT or DWG. Never reuse a real project.
2. Verify exact instance/document discovery.
3. Read a known value.
4. Dry-run when the tool supports it.
5. Perform exactly one bounded write.
6. Read back and confirm the change structurally.
7. Trigger an intentional failure and confirm the rollback, then read back again.
8. For anything appearance-related, additionally inspect the target view.
9. Clean up the test object and the disposable document.

## What to record

Product build (FileVersion), API/runtime family, Host and adapter versions, the
PID of the process you started, document identity, object IDs, transaction and
rollback results, and the evidence location for each step.

## Scope exclusions

- Revit 2026 is not installed and must not be downloaded or tested.
- No other product or year is in scope, even if the repository mentions it.
- Do not start or stop Autodesk processes this task did not start.
- Do not install, repair, upgrade, or uninstall any Autodesk product or the Host.

## Recorded acceptance — 2026-11-11 (Revit 2024)

Target: a disposable copy of the test model under `%TEMP%` on instance
the selected Revit 2024 instance (connector `1.1.0-rc.3`), through a real DeepSeek Harness
`0.1.5-rc.2` session. Nothing was saved; the test parameter was restored.

| # | Field | Result |
|---|---|---|
| 1 | Product installed | PASS — Revit 2024.1 (24.1.11.26) |
| 2 | Runtime recognized | PASS — connector capabilities listed |
| 3 | Matching connector deployed | PASS — the selected Revit 2024 instance |
| 4 | MCP discoverable | PASS — 10 tools; instance listed |
| 5 | DSH end-to-end result | PASS — reads, bounded write, rollback, restore, each read back |

The other six installed builds are **NOT RUN**: Revit 2025/2027 had no disposable
document open, and AutoCAD has no deployed connector (`connectors` contains only
`revit`). Full evidence:
[`docs/deepseek-harness-acceptance-2026-11-11.md`](../../../../../docs/deepseek-harness-acceptance-2026-11-11.md).
