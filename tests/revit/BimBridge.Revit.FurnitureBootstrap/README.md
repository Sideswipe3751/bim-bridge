# Disposable furniture workflow fixture

This independent test add-in does nothing unless its child Revit process has
`BIM_BRIDGE_REVIT_FURNITURE_REQUEST` set to an existing request JSON path. It is
not a production capability or a workaround for running writes through read tools.
The existing connector continues to own every agent modeling transaction.

Build against the existing version matrix:

```powershell
dotnet build tests/revit/BimBridge.Revit.FurnitureBootstrap/BimBridge.Revit.FurnitureBootstrap.csproj -p:RevitVersion=2024 -p:RevitTargetFramework=net48
```

The output root is compiled as assembly metadata from this checkout:
`<repository>/output/multi-agent-2024`. The request must live directly inside
`<root>/<runId>`. All created RFA/RVT files, imported family files, finish markers,
and event reports are restricted to that same run directory. Only safe file names
are accepted. Redirecting symlink/junction tags are refused; OneDrive cloud
placeholder tags are allowed. Existing output documents are never overwritten.

The parent owns temporary manifest deployment/restoration, signature verification,
process launch/restart and the concurrency budget. Reuse existing development trust;
this fixture does not create certificates, change security settings, modify AppData,
or attach to an already running Revit. Use a cold child with no startup RVT argument.

Example family request (`kallax.request.json`):

```json
{
  "schemaVersion": 1,
  "runId": "furniture-20261101-test01",
  "token": "REPLACE_WITH_64_HEXADECIMAL_RANDOM_CHARACTERS",
  "version": "2024",
  "sessionId": "kallax",
  "mode": "family",
  "templatePath": "C:\\EXACT_INSTALLED_TEMPLATE_PATH\\Metric Furniture.rft",
  "documentName": "BB_IKEA_KALLAX_2x2_Reference.rfa"
}
```

On first Idling, the fixture refuses **any** already-open document, creates a
family from the exact RFT, saves it, closes the inactive document, then activates
the saved RFA. This follows the existing cold-start live-test bootstrap sequence
and does not attempt an arbitrary switch away from an existing active document.
It writes `kallax.ready.json` with process, build and exact document evidence.
It deliberately does not set `UIDocument.ActiveView` inside Idling: live Revit
2024 rejected that setter immediately after document activation. Capture the
desired existing 3D view explicitly by connector view ID instead.
The parent must confirm that report against connector discovery and hold the task
lease before the modeling agent writes. The parent must still dry-run and verify
through the normal BIM Bridge workflow. The output RFA initially contains only its
template; existence or `ready` does not mean the modeling task succeeded.

After modeling and structured/visual verification, create `kallax.finish.json`:

```json
{
  "runId": "furniture-20261101-test01",
  "sessionId": "kallax",
  "token": "SAME_64_HEXADECIMAL_RANDOM_CHARACTERS"
}
```

The fixture confirms the exact active test document and absence of any other
document, saves it without a transaction, writes `kallax.saved.json`, and posts
native clean ExitRevit. Shutdown writes `kallax.stopped.json`. The parent must
wait for process exit before launching the next cold family session. The token
is not echoed in reports. New sessions use distinct session IDs and RFA names
inside the same run directory.

Once all verified RFAs have been saved, start a cold project session:

```json
{
  "schemaVersion": 1,
  "runId": "furniture-20261101-test01",
  "token": "SAME_64_HEXADECIMAL_RANDOM_CHARACTERS",
  "version": "2024",
  "sessionId": "assembly",
  "mode": "project",
  "templatePath": "C:\\EXACT_INSTALLED_TEMPLATE_PATH\\DefaultMetric.rte",
  "documentName": "BB_IKEA_Furniture_Test.rvt",
  "families": [
    {"fileName": "BB_IKEA_KALLAX_2x2_Reference.rfa", "xMm": 0, "yMm": 0, "rotationDegrees": 0},
    {"fileName": "BB_IKEA_Lamp_Reference.rfa", "xMm": 2000, "yMm": 0, "rotationDegrees": 0},
    {"fileName": "BB_IKEA_Table_Reference.rfa", "xMm": 4000, "yMm": 0, "rotationDegrees": 0}
  ]
}
```

Assembly starts one fixture-owned native transaction, installs its failure
preprocessor, loads every RFA using the file-path `LoadFamily` overload, then
activates the first type and places one native `FamilyInstance` for each family.
The load, activation, placement and 3D view creation all commit together; any
failure rolls back that transaction with no fallback or automatic retry. The
file-path overload requires this target transaction, unlike the separate
family-document-to-target-document overload. It uses the nearest-to-zero level, millimetres
converted to feet, and creates a shaded fine-detail 3D view. Hosted/adaptive
families are outside this fixture's scope; use unhosted furniture/light geometry
families. Errors roll back the assembly transaction; warnings are removed from
the modal pipeline. Ready evidence includes placed element IDs. Confirm family
names, dimensions, count, placement and appearance via the connector before
claiming acceptance. Keep the assembled project open for review, or finish it
with `assembly.finish.json` after verification to save and exit.

Failure writes `<sessionId>.failed.json` only after request containment is trusted,
stops the fixture, and leaves the child open. It never force-kills, discards an
unexpected active document, or restarts itself. The parent handles a bounded
timeout, records partial saved artifacts as failed/unverified, and may restart
only this exact disposable child. Do not blindly reuse an existing RFA/RVT path
after a crash; inspect evidence or use a fresh run. A malformed/uncontained
request produces no filesystem report; the parent's readiness timeout is required.

Offline build success is not live Autodesk acceptance. Each exact startup,
activation, save, load and clean-exit sequence still needs observed live evidence.

For resident acceptance, use request `mode: "resident"`, an installed project
`.rte` and a unique `BB_Resident_Parking*.rvt` name. This mode creates only the
saved parking project and emits the same exact readiness evidence. The Host
`family.session` capability owns all subsequent family creation, activation,
save and close operations; the fixture does not model or poll per-family files.
`Start-RevitFurnitureTestSession.ps1 -FamilyWorkspace <run>/resident-families`
passes `BIM_BRIDGE_FAMILY_WORKSPACE` to that child only, restoring the launcher's
environment immediately afterwards. The parent must serially launch at most two
resident children through the existing signed temporary-manifest workflow.

Do not emit a finish marker after each resident family. At final shutdown the
normal token-bound finish marker is still supported, but only when the exact
parking project is active, unmodifiable, and the sole open document. An open
family or unrelated document makes shutdown fail closed.

`tests/live/resident_family_acceptance.py prepare` stages the thirty prior
verified jobs and two parking request files without launching Revit. `run`
invokes the neutral Runtime scheduler with one or two explicitly selected
resident instance IDs. `simulate` exercises deterministic failure isolation and
unknown-outcome restart fencing offline; it is not live certification.
`assembly-plan` refuses until all thirty family jobs succeeded, then stages the
existing fifteen-family bootstrap and connector-owned remaining fifteen plus
three category review views. It does not launch or close any process.

Transaction-overload references: [Autodesk developer support's file-path loading
example](https://forums.autodesk.com/t5/revit-api-forum/issue-with-revit-api-s-loadfamily/td-p/11792567)
and [Autodesk's Document.LoadFamily(String, Family) API reference](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-API-MainReference/files/html/67277d5a-0ddf-b617-c9c9-911ecb928af9.htm).
