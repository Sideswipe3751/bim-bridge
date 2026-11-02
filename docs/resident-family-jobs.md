# Prepared family jobs with resident Revit workers

This development feature separates agent preparation from Autodesk execution.
Live acceptance is scoped to Revit 2024. It does not update the installed Host,
installer, release package or supported-version certification matrix.

Use one or two explicitly selected Revit connectors advertising `family.session`
and `task.coordination`, each with a saved parking project active. Public users
must use the normal signed installation flow when a released Host is required;
the source-checkout commands below are development instructions, not a substitute
installer.

## Prepare and execute

Each package follows `familyJobPackage` in the single Contract v2 schema. It
contains `jobId`, `documentName` (a filename stem), absolute `templatePath`,
`buildCode`, `verifyCode`, `source` and `expectedDimensions`. Expected dimensions
include width/depth/height in millimetres and an optional positive tolerance.
Code remains an explicit ambient-authority capability; a package is not an
approval grant. Reusing a job ID with changed content is rejected.

In PowerShell, from this checkout:

```powershell
$env:PYTHONPATH = (Join-Path (Get-Location) 'runtime')
python -m aec_runtime.jobs_cli --run-dir output/my-job-state submit --package prepared-jobs.json
python -m aec_runtime.jobs_cli --run-dir output/my-job-state run --instance-id revit-2024-PID1 --instance-id revit-2024-PID2
python -m aec_runtime.jobs_cli --run-dir output/my-job-state status
```

CLI and the discovered prepared-job provider use the same `JobStore`, scheduler
and Runtime-policy backend. Discover provider schemas through the existing MCP
facade for submit, status, run, seal, review and reconciliation. There are no new
MCP top-level tools or connector routes. The provider store root is configured by
`BIM_BRIDGE_JOB_DIR`; its run IDs select children of that root. CLI `--run-dir`
instead selects the explicit local state directory.

For staggered producers, start `run --wait-for-seal --idle-timeout-seconds 120`.
Agents may submit later ready packages through independent clients. After the
last package, invoke `seal`. Workers drain and return; an unsealed idle deadline
returns an incomplete nonzero CLI result. This is a finite session, not an
installed background daemon. Default batch mode simply drains ready work.

## Native lifecycle and acceptance

Each fixed worker serially acquires a renewable instance lease, creates and
activates a new family, builds, verifies dimensions, prepares a bounded 3D view,
captures it, saves and closes the family, returns to its exact parking project,
and releases the lease. The other worker may execute in parallel. Preparation
and visual review do not hold a Revit lease.

The Host writes only beneath its process-configured
`BIM_BRIDGE_FAMILY_WORKSPACE` (default: current-user BIM Bridge `family-jobs`).
Names, existing deliveries and redirecting links are checked. Existing job
directories are never overwritten, including a failed job's reserved directory.
Native lifecycle is not a file-system transaction: failed activation can leave
a saved initial RFA. Only successful final save/close confirms physical delivery.
`hasSavedFile` and `isModified` distinguish a prior save from current saved content.

Execution produces `awaiting_review`. Inspect the actual captured PNG, then
record a review using the exact job content hash and explicit evidence:

```powershell
python -m aec_runtime.jobs_cli --run-dir output/my-job-state review --job-id cab01 --content-hash HASH --result passed --reviewer reviewer-name --evidence 'Inspected exact capture path: all parts visible, no clipping.'
```

Only a passed explicit review yields `succeeded` and `complete: true`. Review is
the caller's acceptance statement, not a second independent Host measurement.
For a failed review, submit an explicitly identified repair job rather than
overwriting the delivered artifact. Failed, quarantined or incomplete CLI runs
return nonzero. An execution-only zero exit still reports visual reviews pending.

## Failure and recovery

A known terminal failure allows one explicit abort and ownership release only
after the original parking identity is confirmed. Other ready tasks can continue.
Transport loss, lease loss, oversized evidence or interruption during a stage
quarantines that worker. Restarting a scheduler does not replay the stage.
Explicit reconciliation checks the recorded original parking document and that
connector ownership has drained; it never puts the interrupted job back in the
ready queue. A restarted Revit has a new instance ID and invalidates old tokens.
Restore/rediscover it and explicitly select it for later work; inspect any
uncertain saved output before authorizing a new repair or replacement job.

Atomic state writes, a cross-process run lock, bounded evidence and redacted
history protect crash recovery. A short sharing violation retries only the same
already-flushed state-file replacement, never a native mutation. This is not an
OS sandbox against a malicious process running as the same user.

## Development acceptance

`tests/live/resident_family_acceptance.py` prepares disposable parking requests
and corrected baseline packages, checks exact PID/document continuity, tests an
intentional build rollback plus cleanup and later success on that same worker,
and records explicit image reviews before allowing final project assembly.
The signed development launcher restores installed manifests and never replaces
installed binaries. Metrics distinguish prepared execution, startup, preparation,
visual review and shared project assembly; these scopes must not be conflated
with the earlier cold-start experiment.
