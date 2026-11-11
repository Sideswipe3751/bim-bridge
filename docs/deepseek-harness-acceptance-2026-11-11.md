# DeepSeek Harness acceptance evidence — 2026-11-11 (Revit 2024)

This is an operating record for the experimental DeepSeek Harness adapter. It is
not an independent certification and it does not promote any product/version into
the support matrix.

## Environment

| Item | Value |
|---|---|
| Harness | DeepSeek Harness `0.1.5-rc.2`, profile `web-agents`, `patchReload: live` |
| Adapter entry | `adapters/deepseek-harness/skills/bim-bridge/scripts/Start-BimBridgeDshMcp.ps1` |
| Host state | `%LOCALAPPDATA%\BIM Bridge\install-state.json`, `2.0.0-alpha.1`, schema 4 |
| Connector | the selected Revit 2024 instance, `1.1.0-rc.3`, Revit 2024.1 (24.1.11.26) |
| Document | the test model under `%TEMP%` (disposable copy) |
| Test object | One conduit (`Rigid Nonmetallic Conduit (RNC)`) |
| Model saved | No. The parameter was restored to its pre-test value. |

The Skill was discovered from `%USERPROFILE%\.dsh\skills\bim-bridge` (a junction to
the repository Skill), and the MCP row was generated with
`Get-BimBridgeDshMcpConfig.ps1 -Style cordis-patch`, so the tools appeared in the
session as `mcp__bim-bridge__aec_*`.

## Sequence and results

| # | Step | Tool | Result |
|---|---|---|---|
| 1 | Tool discovery | `tools/list` through the DSH MCP client | 10 tools registered |
| 2 | Instance discovery | `aec_list_instances` | the selected Revit 2024 instance with document and capabilities |
| 3 | Document identity | `aec_get_document_info` | test model, connector `1.1.0-rc.3` |
| 4 | Selection read | `aec_get_selection` | 2 conduits |
| 5 | Parameter read | `aec_execute_read` | `Comments` `""`, `Mark` `null`, 246 ms |
| 6 | Bounded write | `aec_execute_write` | `Comments` set to `BIM Bridge DSH write test 2026-11-11`, 252 ms |
| 7 | Read-back after write | `aec_execute_read` | committed value returned, 208 ms |
| 8 | Intentional failure | `aec_execute_write` | `failed`, `rolledBack: true`, `InvalidOperationException`, 252 ms |
| 9 | Read-back after rollback | `aec_execute_read` | pre-failure value unchanged, 219 ms |
| 10 | Restore | `aec_execute_write` | `Comments` cleared, 229 ms |
| 11 | Final read-back | `aec_execute_read` | `Comments` `""`, 229 ms |

## Five acceptance fields for this build

| # | Field | Result |
|---|---|---|
| 1 | Product installed | PASS — Revit 2024.1 |
| 2 | Runtime recognized | PASS — `document.info` through `transaction.rollback` |
| 3 | Matching connector deployed | PASS — the selected Revit 2024 instance |
| 4 | MCP discoverable | PASS — 10 tools; instance listed |
| 5 | DSH end-to-end result | PASS — reads, bounded write, rollback, restore, each read back |

## Scope limits

- Only Revit 2024 was exercised. Revit 2025 and 2027 are **NOT RUN**: their
  connectors are deployed, but no disposable document was open in those builds
  during this run, so the write sequence could not be executed.
- AutoCAD 2024–2027 are **NOT RUN / BLOCKED**: `%LOCALAPPDATA%\BIM Bridge\connectors`
  contains only `revit`, and no AutoCAD connector descriptor was present. The
  earlier independent verification recorded the same missing deployment as a
  blocker.
- The other connector descriptor on this machine belonged to
  a process that had exited; it was removed after this run. Until then, calls
  without an exact `instanceId` failed as ambiguous.
- The write path reaches the Host through the compatibility projection
  (`compatibility_v1`), so the Runtime records
  `legacy_adapter_approval_authority` and does not require a request-bound grant.
  Consent is the agent host's responsibility; the Skill states the target and
  reads back after a write.
