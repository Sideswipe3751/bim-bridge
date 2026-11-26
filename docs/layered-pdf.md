# Layered PDF over MCP

The built-in `bimbridge.layered_pdf.v1` provider imports the existing Layered PDF
exporter into BIM Bridge. It creates **one PDF page**, with a switchable OCG
layer for every visible placed viewport, grouped by source sheet. The base
sheet supplies paper coordinates and the Sheet Base layer. OCG-aware readers
such as Bluebeam can switch the resulting layers independently.

This is a development capability. It requires a rebuilt native connector and
the adjacent composer, not the original ribbon plugin. Updating only the agent
plugin does not update installed native binaries. The published signed Host
release and native installation are unchanged by this source change.

## Build

Run the existing matrix builder for an installed release:

```powershell
./eng/Build-RevitAdapters.ps1 -Version 2024 -Configuration Release
```

It builds the shared Revit source and core DLL and publishes the self-contained
Windows x64 composer under the adapter's `Composer` directory. PDFsharp 6.2.4
runs only in that separate process, never inside Revit or Python. The same
matrix builder's development staging includes the core, composer and PDFsharp
license. No separately installed .NET 8 runtime is needed for the composer.
The compatibility shim project alone does not publish the composer.

## Discover and inspect

Use `aec_list_providers`, `aec_search_provider_tools` and
`aec_get_provider_tool_schema` as usual. The provider has two tools:

| Tool | Access | Purpose |
| --- | --- | --- |
| `list_layered_pdf_sheets` | read | Return printable sheets, visible viewport IDs/names, paper sizes, saved PDF setup names and composer availability. |
| `export_layered_pdf` | write | Export explicit source sheets and overlay their viewport layers on one page. |

Read call:

```json
{
  "provider": "bimbridge.layered_pdf.v1",
  "toolName": "list_layered_pdf_sheets",
  "arguments": {
    "instanceId": "<exact instance returned by discovery>",
    "documentTitle": "<exact active project title>"
  }
}
```

Call `aec_call_provider_write` with `dryRun: true` first, then `false`:

```json
{
  "provider": "bimbridge.layered_pdf.v1",
  "toolName": "export_layered_pdf",
  "dryRun": true,
  "timeoutSeconds": 300,
  "arguments": {
    "instanceId": "<exact discovered instance>",
    "documentTitle": "<exact active project title>",
    "baseSheetId": 12345,
    "sheetIds": [12345, 23456],
    "fileStem": "coordination-overlay",
    "includeSheetAndDetail": true,
    "createBoxLayers": false
  }
}
```

Optional `setupName` selects a saved native PDF setup from the catalog. Omit it
for API defaults. The setup must use Sheet Size, Automatic orientation, Center,
Fit to Page and Vector Processing. Sheet IDs are Revit Element IDs, not sheet
numbers. The base sheet need not be active or in the source selection.

Both tools accept paired `taskId`/`taskToken` credentials for an already owned
instance. Neither bypasses an existing task lease. Direct contract-v2 requests
use `revit.layered_pdf.catalog` or `revit.layered_pdf.export` with the same domain
arguments and the ordinary authenticated session, target and policy model.
The ten existing top-level MCP schemas and five connector routes are unchanged.

## Output and limits

- 1-100 distinct source sheets and 1-250 visible viewports per export.
- Every source sheet must match the base sheet's paper size and orientation.
- New files go below `%LOCALAPPDATA%\BIM Bridge\exports\revit\<release>\<GUID>`.
  A safe `fileStem` controls only the PDF's filename; arbitrary output paths and
  replacement of existing deliveries are unavailable.
- The result contains path, SHA-256, byte length, source IDs, sheet and viewport
  layer counts, page count and `modelRestored`. Viewport layer count excludes
  Sheet Base and optional BOX copies.
- `createBoxLayers` retains the original view and adds `<view layer> BOX` for
  visible Conduit Fittings whose family name contains `box`, ignoring case, in
  views containing conduit. Host/direct-link ID ambiguity is reported and skipped.
- Unplaced standalone views, non-viewport schedules and the GUI's custom conduit
  markers and custom layer-group editor are outside this MCP slice. The imported
  engine retains its existing tested facilities for later structured extensions.
- The catalog reports at most 1,000 sheets and 251 visible viewports per sheet;
  a catalog is not an export plan. Native export validates the bounded selection.

Dry-run is a gateway preview. It validates schema, access, target routing and
policy without native export, file creation or native sheet/preset checks. The
real call validates current sheet identities and print settings on Revit's UI
thread before isolation. Temporary native changes use rollback-only groups and
the shared non-interactive failure preprocessor. `rolledBack` describes those
model changes, not file rollback. Native exports check the deadline between
pages; Revit's currently running export cannot be interrupted. Composition runs
after model restoration, with concurrent pipe draining and a bounded wait.
The composer reopens its staged output to verify one page and the exact OCG
count before publishing the final PDF. A failed call may retain diagnostic files.

## Validation

The original 32 core and 37 PDF composer tests cover geometry, Unicode names,
clipping, OCGs, layer grouping, BOX copies and conduit marker behavior. Added
Runtime and real stdio MCP tests cover discovery, schemas, dry-run without
dispatch, exact target/options transport, access refusal, task credentials,
validation and terminal failure propagation. Shared Host tests exercise the
authenticated HTTP route and native-side option/access/target requirements.

`eng/Run-RevitLiveAcceptance.ps1` now includes a disposable two-sheet fixture,
MCP discovery/preview/export, exact original viewport-ID readback and fixture
cleanup. This is separate from portable tests and does not use a user model.
Record current native acceptance evidence below before treating a build as
certified; a source build or fake connector test is not native acceptance.

Current local evidence (2026-11-25): Revit 2024/net48, 2025/net8 and
2027/net10 compiled. Revit 2026 is not installed. The Revit 2024 live run was
refused because that release already has a user session open. The Revit 2025
child exited during Autodesk licensing (`LicenseUpd(1) Adlsdk Error:(3)
vendor:SERVICE`) before the bootstrap loaded. Native export acceptance remains
pending; the existing signed release is not promoted by these builds.

Retained native Revit 2024 exports were also replayed through the imported
composer locally: one output page, three OCGs (Sheet Base plus two viewports),
235,459 bytes. Poppler rendering was visually inspected for the title block,
viewport content and clipping. These private diagnostic inputs and rendered
outputs are not committed. Rendering Sheet Base alone, each viewport separately,
and all layers together produced four distinct images, confirming independent
layer visibility. Replay verifies real native PDF composition, not a
fresh connector export or native transaction rollback.

Portable checks passed: 95 Runtime tests, 15 protocol tests, 3 adapter tests,
15 stdio MCP tests (including the new fake-connector transport test), 69 PDF
engine tests, and 9 shared Host tests on each of net10 and net48. The Revit
architecture suite passed 2,261 assertions, including real development staging
of the core DLL, self-contained composer and license notice. Runtime-resolution
and version-authority checks also passed. These counts do not include native
export acceptance.
