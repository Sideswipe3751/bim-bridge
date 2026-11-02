"""CLI adapter for the same prepared-job Runtime API; never launches Autodesk."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from .jobs import JobStore, JobScheduler
from .job_backend import RuntimeJobBackend


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-dir', required=True)
    actions = parser.add_subparsers(dest='action', required=True)
    submit = actions.add_parser('submit')
    submit.add_argument('--package', required=True)
    actions.add_parser('status')
    actions.add_parser('seal')
    run = actions.add_parser('run')
    run.add_argument('--instance-id', action='append', required=True)
    run.add_argument('--timeout-seconds', type=int, default=120)
    run.add_argument('--lease-seconds', type=int, default=120)
    run.add_argument('--wait-for-seal', action='store_true')
    run.add_argument('--idle-timeout-seconds', type=float, default=60)
    reconcile = actions.add_parser('reconcile')
    reconcile.add_argument('--instance-id', required=True)
    review = actions.add_parser('review')
    review.add_argument('--job-id', required=True)
    review.add_argument('--content-hash', required=True)
    review.add_argument('--result', choices=['passed', 'failed'], required=True)
    review.add_argument('--reviewer', required=True)
    review.add_argument('--evidence', required=True)
    args = parser.parse_args(argv)
    store = JobStore(args.run_dir)
    if args.action == 'submit':
        path = Path(args.package)
        if path.stat().st_size > 64 * 1024 * 1024:
            raise ValueError('Package input exceeds bounded queue size')
        value = json.loads(path.read_text(encoding='utf-8-sig'))
        values = value if isinstance(value, list) else [value]
        if not 1 <= len(values) <= 128:
            raise ValueError('Submit one through 128 prepared jobs')
        result = [store.submit(job) for job in values]
    elif args.action == 'status':
        result = store.snapshot()
    elif args.action == 'seal':
        result = store.seal()
    elif args.action == 'review':
        result = store.record_review(args.job_id, args.content_hash, args.result == 'passed', reviewer=args.reviewer, evidence=args.evidence)
    else:
        from .service import BimBridgeRuntime
        backend = RuntimeJobBackend(BimBridgeRuntime(), timeout_seconds=getattr(args, 'timeout_seconds', 120))
        instance_ids = args.instance_id if isinstance(args.instance_id, list) else [args.instance_id]
        scheduler = JobScheduler(store, backend, instance_ids, lease_seconds=getattr(args, 'lease_seconds', 120))
        result = scheduler.run(wait_for_seal=args.wait_for_seal, idle_timeout_seconds=args.idle_timeout_seconds) if args.action == 'run' else scheduler.reconcile(args.instance_id)
    exit_code = 0
    if args.action == 'run':
        jobs = list(result.get('jobs', {}).values())
        pending = [j['jobId'] for j in jobs if j.get('status') in {'ready', 'running', 'in_flight'}]
        failed = [j['jobId'] for j in jobs if j.get('status') in {'failed', 'needs_reconcile', 'review_failed'}]
        quarantined = [i for i, worker in result.get('instances', {}).items() if worker.get('status') == 'quarantined']
        waiting = [j['jobId'] for j in jobs if j.get('status') == 'awaiting_review']
        unsealed_timeout = args.wait_for_seal and result.get('sealed') is not True
        result['executionSummary'] = {'physicalExecutionComplete': not pending and not failed and not quarantined and not unsealed_timeout,
                                      'visualReviewPending': waiting, 'failedJobs': failed, 'pendingJobs': pending,
                                      'quarantinedInstances': quarantined, 'producerSessionUnsealed': unsealed_timeout}
        if pending or failed or quarantined or unsealed_timeout:
            exit_code = 1
    elif args.action == 'review' and args.result == 'failed':
        exit_code = 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
