# Multi-agent tasks

Parallelize preparation, then queue a whole bounded task per exact Revit instance.
The connector enforces ownership across separate MCP processes. The Runtime does
not start agents. This is a development capability with Revit 2024 live testing;
it is not present in older installed Hosts until separately released and installed.

1. Discover providers, search for task coordination, inspect each exact schema.
2. Submit a name, owner label, exact instance and 10–300 second lease. Preview the
   write first. Submission returns a task snapshot and a private token once.
3. Poll with task ID/token until `active`. Renew while waiting as well as working.
4. Read the live document identity. Use the task step wrapper only for an explicit
   dynamic-code capability when structured modeling capabilities are absent. Both
   code read and code write use the destructive write projection. Supply exact
   document title, preferably document ID, and preview before executing.
5. Verify dimensions, parameters, native categories and IDs. Capture the focused
   view with the discovered capture tool's `taskId` and `taskToken` fields.
6. Release after terminal results and required verification. Queue status never
   exposes tokens. Control operations do not alter the model or grant approval.

`queued` and `active` leases expire. An expired/cancelled task with an admitted
request becomes `draining` until that native request is terminal. Do not infer
completion from an MCP timeout, automatically repeat a possibly committed write,
or substitute another provider. An application-global provider unable to join the
gate is refused on a coordination-enabled host. Connector restart invalidates
tokens and loses the transient queue; saved models are not automatically replayed.

## Prepared jobs and resident workers

When discovery advertises prepared family jobs and native family sessions, prefer
that workflow for a batch over manually handing every operation between agents.
The development Host can keep saved parking projects open in two exact Revit
instances while creating, verifying, saving and closing individual family
documents. The furniture bootstrap under `tests/revit` remains a development
launcher fixture; document lifecycle is a separate structured Host capability.

1. Prepare one immutable package per family: stable job ID, absolute RFT template,
   safe document name, build and verification code, source metadata and expected
   dimensions. Use the discovered schema; code remains an explicit high-risk
   execution capability, not a read-only shortcut.
2. Discover the job provider and inspect submit, run, status, seal, review and
   reconciliation schemas. Submit ready packages without holding a Revit lease.
3. Run with one or two explicitly selected saved parking instances. A finite
   streaming session may wait for later submissions; seal it when all producers
   have finished. The ordinary batch mode drains already-ready work and returns.
4. The Runtime acquires and renews the existing task lease, drives each native
   stage through policy, saves the artifact and returns the instance to parking.
   A file and screenshot delivery is `awaiting_review`, not a passed visual check.
5. Inspect the actual focused native image outside the Revit lease, then record
   an explicit review bound to the job content hash. Failed reviews require a
   new, explicitly identified repair task; do not overwrite the delivered job.
6. An unknown result or interrupted scheduler quarantines the affected instance.
   Inspect the saved files and exact original parking identity before explicit
   reconciliation. Reconciliation never puts the interrupted write back in the
   ready queue. A replacement process has a new instance identity and no old
   ownership credentials; never silently move an ambiguous mutation to it.

This development scope is live-tested against Revit 2024 only. Discovery may
show it absent in older installed Hosts. Installation and release remain
separate explicit actions; do not replace the installed Host merely to expose a
development capability during an ordinary user task.
