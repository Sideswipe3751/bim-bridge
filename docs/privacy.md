# BIM Bridge privacy policy

Effective date: August 11, 2026

BIM Bridge is source-available software that connects an authorized agent adapter to
Autodesk AutoCAD and Revit running on the same Windows computer. The BIM Bridge project does not
operate a hosted MCP service, advertising service, analytics service, or user
account system.

## Data the project collects

BIM Bridge itself does not collect or sell personal information and does not
send telemetry to the project maintainers. Connector discovery records,
authentication tokens, installation state, and provider configuration are
stored under the current Windows user's profile. Authentication tokens are
generated locally and are not included in diagnostic output.

The runtime also stores a local, redacted, hash-chained execution journal under
`%LOCALAPPDATA%\BIM Bridge\journal`. It contains execution identifiers, routes,
policy decisions, target metadata, transaction and verification evidence, and
normalized results. Session tokens, approval grants, signatures, nonces, and
dynamic source code are redacted before journal persistence. The journal is not
sent to the project maintainers.

When you ask Codex to inspect or change a drawing or model, relevant document
metadata, entity or element properties, selections, paths, and requested
operation results may be passed between the local Autodesk connector and your
Codex session. Your use of Codex and OpenAI services is governed separately by
the terms and privacy policy applicable to your OpenAI account.

When you request or authorize visual verification, a focused image or export
of the relevant Autodesk view may also be passed to your Codex session for
analysis. BIM Bridge instructs the agent adapter to avoid capturing the full desktop,
unrelated applications, or unrelated project content. BIM Bridge does not send
those images to the project maintainers or operate a service that stores them.

## Network access

The installer downloads a version-pinned BIM Bridge release from GitHub and
verifies its SHA-256 before execution. Local connectors bind only to loopback
addresses. Pinned third-party providers run locally; BIM Bridge does not expose
them as a public internet service.

## Storage and deletion

BIM Bridge stores current state under `%LOCALAPPDATA%\BIM Bridge`, Autodesk's
per-user add-in folders under `%APPDATA%`, and a local Codex MCP registration.
During an explicit migration, the installer removes only known legacy-owned
components beneath `%LOCALAPPDATA%\AEC Codex` and preserves unknown legacy
data. The uninstall workflow removes BIM Bridge host components and the MCP
registration while preserving the Codex plugin. Autodesk
documents changed at the user's request remain the user's responsibility.
Journal files are ordinary per-user JSONL files and may be deleted by the user
when they are no longer needed, provided no active diagnostic or compliance
workflow depends on them.

## Contact

For privacy questions, open a private security report or maintainer contact
through the repository at <https://github.com/Sideswipe3751/bim-bridge/security>.
