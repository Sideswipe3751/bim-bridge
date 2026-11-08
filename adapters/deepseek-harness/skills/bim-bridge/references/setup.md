# DeepSeek Harness adapter setup

This experimental adapter connects DeepSeek Harness (DSH) to an already installed
neutral BIM Bridge Host. It does not install, repair, upgrade, or uninstall that
Host, and it does not modify any Autodesk product.

## What is verified about DSH

Verified on DSH `0.1.5-rc.2`:

- DSH has **no `dsh mcp` command**. `dsh --help` exposes only `web` and `plugin`.
- MCP servers are registered by the Cordis plugin `@deepseek-ai/dsh-mcp-client`,
  one configuration row per server.
- Skills are discovered from scanned roots as `<name>/SKILL.md` (see
  `@deepseek-ai/dsh-skill-filesystem`); the standard roots are
  `<projectRoot>/.dsh/skills`, `<projectRoot>/.agents/skills`, `<dshHome>/skills`,
  plus any `customSkillDirs`.
- The frontmatter keys are `name` and `description` (both required) plus the
  optional `whenToUse`, `metadata`, `disable-model-invocation`, and
  `user-invocable`. The two invocation keys are hyphenated and accept YAML
  booleans or `true`/`false`, `yes`/`no`, `on`/`off`, and `1`/`0`; a rejected
  spelling or a non-boolean value drops the whole Skill with a warning, so it
  becomes indistinguishable from a Skill that does not exist.
- DSH plugins are pnpm packages installed per profile with
  `dsh plugin --profile <name> add -w <spec>`; a bundle package must declare
  `dsh.bundle.patch` in its `package.json`.

Anything below that this adapter cannot verify without mutating real DSH
configuration is marked **UNVERIFIED**.

## Finding DeepSeek Harness without a global PATH

A `dsh` on `PATH` is not required and must not be assumed. The scripts resolve the
entry point themselves, in this order:

1. `BIM_BRIDGE_DSH_COMMAND` — an explicit override, used as-is and terminal: if it
   is set but missing, discovery fails rather than falling back;
2. `dsh` on the process `PATH`;
3. `%LOCALAPPDATA%\Programs\DeepSeekHarness\bin\dsh.cmd` — the per-user launcher,
   which prepends its bundled Node directory and delegates to the local checkout's
   `node_modules\.bin\dsh.cmd`;
4. `<dshHome>\node_modules\.bin\dsh.cmd`.

The Node interpreter is resolved the same way, through `BIM_BRIDGE_DSH_NODE`,
`node.exe` on `PATH`, then the bundled
`%LOCALAPPDATA%\Programs\DeepSeekHarness\node-*-win-*\node.exe`. The launcher
wrapper prepends the resolved Node directory to the environment of the process it
delegates to, and only to that process.

Nothing in this order writes to disk, scans a directory tree, or edits `PATH` —
neither the process `PATH` nor the persisted user `PATH`. Set either override only
when DeepSeek Harness lives somewhere this order does not cover; setting one that
does not exist is reported as missing, not silently ignored.

## Read-only status

Run the bundled read-only status check first:

```powershell
& "<SKILL_DIR>\scripts\Get-BimBridgeDshStatus.ps1"
```

Continue only when `status` is `healthy`. The check reports the DSH executable and
version together with the source each was resolved from, the DSH home and the
profiles that exist, the BIM Bridge install-state path and schema, the installed
Host version, launcher/Python/MCP-server integrity, the connector deployment
recorded by the Host, and any running Revit or AutoCAD processes. It writes
nothing.

## Registration

Generate the server row with the absolute path of this adapter's verified
launcher wrapper:

```powershell
# The row DeepSeek Harness actually loads:
& "<SKILL_DIR>\scripts\Get-BimBridgeDshMcpConfig.ps1" -Style cordis-patch

# The same server in the shape the other BIM Bridge adapters template:
& "<SKILL_DIR>\scripts\Get-BimBridgeDshMcpConfig.ps1" -Style mcp-servers
```

Paste the `cordis-patch` output into a profile patch overlay. The generated row
sets `failOnStartupError: true` on purpose: a Host that cannot start must be a
visible failure, not a silently missing tool set.

The checked-in `adapters/deepseek-harness/mcp.template.json` is documentation
only. It contains a `<ABSOLUTE_PATH_TO_SKILL>` placeholder that must be replaced;
never use it unchanged.

## Loading the Skill

DSH does not read this repository's `adapters/` tree by itself. Point a scanned
skill root at it, or copy the `bim-bridge` skill directory into one of the
standard roots. **UNVERIFIED:** the exact reload behaviour depends on the active
profile's `patchReload` setting (`live` for `web`/`web-team`, `startup` for
`headless`). A change that is not picked up live requires restarting the DSH
process — a browser refresh does not replace already-loaded Host modules.

## Tool names

Bridged tools appear as `mcp__bim-bridge__<rawName>`. Only MCP tools are bridged;
resources and prompts are not available.

## Host unavailable

If status is `not_installed` or `needs_repair`, stop. Host mutation belongs to the
shared signed BIM Bridge release and installer workflow, after explicit user
consent. Do not source-build an unpublished Host, do not copy another agent's
bootstrap scripts, and do not repair the Host from this adapter.
