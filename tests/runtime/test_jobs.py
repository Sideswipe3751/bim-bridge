from __future__ import annotations
import copy,json,sys,tempfile,threading,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'runtime'))
from aec_runtime.jobs import JobStore,JobScheduler,FailedOperation,UnknownOutcome,JobError,STAGES,validate_job


def package(name='job1'):
 return dict(jobId=name,templatePath=str(Path(tempfile.gettempdir())/'Metric Furniture.rft'),documentName='BB_'+name,buildCode='return 1;',verifyCode='return 2;',source='https://example.test/reference',expectedDimensions=dict(widthMm=100,depthMm=200,heightMm=300))


class FakeBackend:
 def __init__(self,fail=None,delay=.001):
  self.fail=fail;self.delay=delay;self.calls=[];self.guard=threading.Lock();self.active={};self.max_active=0;self.renewals=0;self.clean=True
 def acquire(self,instance,job,seconds):
  with self.guard:
   self.calls.append(('acquire',instance,job['jobId']));self.active[instance]=job['jobId'];self.max_active=max(self.max_active,len(self.active))
  return {'token':'private-token','taskId':'task-'+job['jobId']}
 def renew(self,*args):self.renewals+=1
 def stage(self,name,instance,job,context):
  with self.guard:
   assert self.active[instance]==job['jobId'];self.calls.append((name,instance,job['jobId']))
  time.sleep(self.delay)
  if self.fail and (job['jobId'],name)==self.fail[:2]:raise self.fail[2]('test failure')
  if name=='release':
   with self.guard:self.active.pop(instance)
  return {'value':name}
 def cleanup(self,instance,job,context):
  self.calls.append(('cleanup',instance,job['jobId']));self.active.pop(instance,None);return self.clean
 def reconcile(self,instance,row):return {'safeClean':self.clean}


class JobsTests(unittest.TestCase):
 def setUp(self):self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.store=JobStore(self.temp.name)
 def scheduler(self,backend=None,ids=None,**kw):return JobScheduler(self.store,backend or FakeBackend(),['one','two'] if ids is None else ids,**kw)
 def test_two_workers_fifo_claims_and_no_per_instance_interleave(self):
  for i in range(8):self.store.submit(package('j'+str(i)))
  backend=FakeBackend(delay=.01);result=self.scheduler(backend).run()
  self.assertEqual(backend.max_active,2)
  self.assertTrue(all(j['status']=='awaiting_review'for j in result['jobs'].values()))
  starts=[c[2]for c in backend.calls if c[0]=='acquire'];self.assertEqual(starts,['j'+str(i)for i in range(8)])
  for name in result['jobs']:
   phases=[c[0]for c in backend.calls if c[2]==name];self.assertEqual(phases,['acquire',*STAGES])
  self.assertNotIn('private-token',(Path(self.temp.name)/'state.json').read_text())
 def test_hash_binding_success_no_replay_and_capacity(self):
  self.store.submit(package());backend=FakeBackend();self.scheduler(backend).run();n=len(backend.calls)
  self.store.submit(package());self.scheduler(backend).run();self.assertEqual(n,len(backend.calls))
  changed=package();changed['buildCode']='return 3;'
  with self.assertRaises(JobError):self.store.submit(changed)
  with self.assertRaises(JobError):JobStore(self.temp.name,max_jobs=1).submit(package('second'))
 def test_known_terminal_failure_isolated_and_worker_reused_only_after_cleanup(self):
  for j in ['bad','good']:self.store.submit(package(j))
  backend=FakeBackend(('bad','build',FailedOperation));r=self.scheduler(backend,['one']).run()
  self.assertEqual(r['jobs']['bad']['status'],'failed');self.assertEqual(r['jobs']['good']['status'],'awaiting_review')
  self.assertIn(('cleanup','one','bad'),backend.calls)
 def test_unknown_write_quarantines_without_cleanup_or_release_or_replay(self):
  self.store.submit(package('bad'));self.store.submit(package('next'));b=FakeBackend(('bad','build',TimeoutError))
  scheduler=self.scheduler(b,['one']);r=scheduler.run()
  self.assertEqual(r['jobs']['bad']['status'],'needs_reconcile');self.assertEqual(r['jobs']['next']['status'],'ready')
  self.assertFalse(any(c[0]in ['release','cleanup']for c in b.calls));n=len(b.calls);scheduler.run();self.assertEqual(n,len(b.calls))
  b.clean=False
  with self.assertRaises(UnknownOutcome):scheduler.reconcile('one')
  b.clean=True;scheduler.reconcile('one');r=scheduler.run();self.assertEqual(r['jobs']['next']['status'],'awaiting_review');self.assertEqual(r['jobs']['bad']['status'],'failed')
 def test_interrupted_acquisition_is_not_automatically_replayed(self):
  self.store.submit(package());self.store.update(lambda s:s['jobs']['job1'].update(status='in_flight',stage='acquire',instanceId='one'))
  b=FakeBackend();r=self.scheduler(b,['one']).run();self.assertEqual(r['jobs']['job1']['status'],'needs_reconcile');self.assertEqual(b.calls,[])
 def test_content_tampering_and_partial_state_fail_closed(self):
  self.store.submit(package());p=Path(self.temp.name)/'state.json';state=json.loads(p.read_text());state['jobs']['job1']['package']['buildCode']='tampered';p.write_text(json.dumps(state))
  with self.assertRaises(JobError):self.store.snapshot()
  p.write_text('{')
  with self.assertRaises(ValueError):self.store.snapshot()
 def test_run_lock_prevents_two_controllers(self):
  from aec_runtime.audit import _journal_file_lock
  self.store.submit(package())
  with _journal_file_lock(Path(self.temp.name)/'run.lock',1):
   with self.assertRaises(TimeoutError):self.scheduler().run()
 def test_lease_is_renewed_during_long_native_work(self):
  self.store.submit(package());b=FakeBackend(delay=.02)
  # Shortened only the scheduler's wait interval for a deterministic unit fixture.
  scheduler=self.scheduler(b,['one']);scheduler.lease_seconds=.03;r=scheduler.run()
  self.assertGreater(b.renewals,0);self.assertEqual(r['jobs']['job1']['status'],'awaiting_review')
 def test_renew_failure_stops_before_next_stage(self):
  self.store.submit(package());b=FakeBackend(delay=.04);b.renew=lambda *a:(_ for _ in()).throw(TimeoutError())
  scheduler=self.scheduler(b,['one']);scheduler.lease_seconds=.03;r=scheduler.run();self.assertEqual(r['jobs']['job1']['status'],'needs_reconcile')
  self.assertNotIn('release',[c[0]for c in b.calls]);self.assertNotIn('cleanup',[c[0]for c in b.calls])
 def test_run_lock_is_shared_with_independent_process(self):
  import subprocess
  from aec_runtime.audit import _journal_file_lock
  script = "from pathlib import Path; from aec_runtime.audit import _journal_file_lock; import sys; exec('with _journal_file_lock(Path(sys.argv[1]), .05):\\n pass')"
  env = dict(__import__('os').environ, PYTHONPATH=str(Path(__file__).resolve().parents[2]/'runtime'))
  with _journal_file_lock(Path(self.temp.name)/'run.lock',1):
   result=subprocess.run([sys.executable,'-c',script,str(Path(self.temp.name)/'run.lock')],env=env,capture_output=True,text=True,timeout=10)
  self.assertNotEqual(result.returncode,0);self.assertIn('Timed out acquiring execution journal lock',result.stderr)

 def test_streaming_waits_for_late_producer_and_seals_without_second_run(self):
  backend=FakeBackend();answers=[];scheduler=self.scheduler(backend,['one'])
  worker=threading.Thread(target=lambda:answers.append(scheduler.run(wait_for_seal=True,idle_timeout_seconds=2)))
  worker.start();time.sleep(.1)
  producer=JobStore(self.temp.name);producer.submit(package('late1'));time.sleep(.1);producer.submit(package('late2'));producer.seal()
  worker.join(5);self.assertFalse(worker.is_alive());self.assertEqual(len(answers),1)
  self.assertEqual([c[2]for c in backend.calls if c[0]=='acquire'],['late1','late2'])
  self.assertTrue(all(j['status']=='awaiting_review'for j in answers[0]['jobs'].values()))
  with self.assertRaises(JobError):producer.submit(package('too-late'))
 def test_streaming_idle_timeout_leaves_state_unchanged(self):
  started=time.monotonic();result=self.scheduler(ids=['one']).run(wait_for_seal=True,idle_timeout_seconds=.05)
  self.assertLess(time.monotonic()-started,.5);self.assertFalse(result['sealed']);self.assertEqual(result['jobs'],{})

 def test_visual_review_is_explicit_hash_bound_and_retains_failed_review(self):
  row=self.store.submit(package());self.scheduler(ids=['one']).run()
  pending=self.store.snapshot()['jobs']['job1'];self.assertFalse(pending['complete']);self.assertEqual(pending['visualReviewStatus'],'pending')
  with self.assertRaises(JobError):self.store.record_review('job1','wrong',True,reviewer='test',evidence='capture.png')
  self.store.record_review('job1',row['contentHash'],False,reviewer='test',evidence='capture.png shows clipping')
  delivered=self.store.record_review('job1',row['contentHash'],True,reviewer='test',evidence='capture2.png reviewed')
  self.assertTrue(delivered['complete']);self.assertEqual(delivered['status'],'succeeded');self.assertEqual(len(delivered['reviews']),2)

 def test_oversized_native_failure_evidence_is_digested_and_quarantined(self):
  import hashlib
  from aec_runtime.jobs import _json_bytes, _redact, MAX_HISTORY_BYTES
  self.store.submit(package())
  evidence={'requestId':'native-large-failure','status':'failed','result':{'detail':'\u6f22'*(MAX_HISTORY_BYTES//2)}}
  class LargeFailureBackend(FakeBackend):
   def stage(inner,name,instance,job,context):
    if name=='build':raise FailedOperation('native failed',evidence=evidence)
    return super().stage(name,instance,job,context)
  backend=LargeFailureBackend();result=self.scheduler(backend,['one']).run();job=result['jobs']['job1']
  self.assertEqual(job['status'],'needs_reconcile');failure=job['history'][-1]
  digest=failure['evidence'];self.assertTrue(digest['truncated']);self.assertEqual(digest['requestId'],'native-large-failure');self.assertEqual(digest['status'],'failed')
  encoded=_json_bytes(_redact(evidence));self.assertEqual(digest['sha256'],hashlib.sha256(encoded).hexdigest());self.assertEqual(digest['sizeBytes'],len(encoded))
  self.assertLess(len(_json_bytes(failure)),MAX_HISTORY_BYTES);self.assertNotIn('cleanup',[c[0]for c in backend.calls])
 def test_utf8_oversized_success_is_not_accepted_as_small_character_count(self):
  from aec_runtime.jobs import MAX_HISTORY_BYTES
  self.store.submit(package())
  class LargeSuccessBackend(FakeBackend):
   def stage(inner,name,instance,job,context):
    if name=='build':return {'requestId':'large-success','status':'succeeded','detail':'\u6f22'*(MAX_HISTORY_BYTES//2)}
    return super().stage(name,instance,job,context)
  result=self.scheduler(LargeSuccessBackend(),['one']).run();self.assertEqual(result['jobs']['job1']['status'],'needs_reconcile')
  self.assertTrue(result['jobs']['job1']['history'][-1]['evidence']['truncated'])
 def test_state_file_row_history_review_and_capacity_bounds_fail_closed(self):
  from unittest.mock import patch
  self.store.submit(package());path=Path(self.temp.name)/'state.json';original=path.read_text();state=json.loads(original)
  variants=[]
  value=copy.deepcopy(state);value['jobs']={str(i):{}for i in range(129)};variants.append(value)
  value=copy.deepcopy(state);value['jobs']['job1']['history']=[{}]*33;variants.append(value)
  value=copy.deepcopy(state);value['jobs']['job1']['history']=[{'result':'x'*262144}];variants.append(value)
  value=copy.deepcopy(state);value['jobs']['job1']['reviews']=[{}]*129;variants.append(value)
  value=copy.deepcopy(state);value['jobs']['job1']['status']='invented';variants.append(value)
  for value in variants:
   path.write_text(json.dumps(value))
   with self.assertRaises(JobError):self.store.snapshot()
  path.write_text(original)
  with patch('aec_runtime.jobs.MAX_STATE_BYTES',len(original.encode('utf-8'))-1):
   with self.assertRaises(JobError):self.store.snapshot()
  with patch('aec_runtime.jobs.MAX_ROW_BYTES',1):
   with self.assertRaises(JobError):self.store.snapshot()
  self.assertEqual(path.read_text(),original)

 def test_windows_transient_replace_retries_same_fsynced_file_once_callback(self):
  from unittest.mock import patch
  import os
  self.store.submit(package());real_replace=os.replace;attempts=[];callback_count=[]
  error=PermissionError('sharing violation');error.winerror=32
  def replace(source,target):
   attempts.append((str(source),str(target)))
   if len(attempts)<3:raise error
   return real_replace(source,target)
  with patch('aec_runtime.jobs.os.replace',side_effect=replace):
   self.store.update(lambda state:(callback_count.append(1),state.update(sealed=True)))
  self.assertEqual(len(callback_count),1);self.assertEqual(len(attempts),3);self.assertEqual(len({a[0]for a in attempts}),1)
  self.assertTrue(self.store.snapshot()['sealed']);self.assertEqual(list(Path(self.temp.name).glob('*.tmp')),[])
 def test_windows_permanent_replace_failure_preserves_old_state_and_callback_not_replayed(self):
  from unittest.mock import patch
  self.store.submit(package());path=Path(self.temp.name)/'state.json';original=path.read_bytes();calls=[];callback_count=[]
  error=PermissionError('access denied');error.winerror=5
  def fail(source,target):calls.append(str(source));raise error
  started=time.monotonic()
  with patch('aec_runtime.jobs.os.replace',side_effect=fail):
   with self.assertRaises(PermissionError):self.store.update(lambda state:(callback_count.append(1),state.update(sealed=True)))
  self.assertGreater(len(calls),1);self.assertEqual(len(set(calls)),1);self.assertEqual(callback_count,[1]);self.assertLess(time.monotonic()-started,1.5)
  self.assertEqual(path.read_bytes(),original);self.assertFalse(self.store.snapshot()['sealed']);self.assertEqual(list(Path(self.temp.name).glob('*.tmp')),[])
 def test_nonsharing_replace_error_is_not_retried(self):
  from unittest.mock import patch
  self.store.submit(package());error=OSError('disk full');error.winerror=112
  with patch('aec_runtime.jobs.os.replace',side_effect=error)as replace:
   with self.assertRaises(OSError):self.store.seal()
  self.assertEqual(replace.call_count,1)

 def test_validation_bounds(self):
  for field,value in [('jobId','../escape'),('documentName','x.rfa'),('buildCode',''),('templatePath','relative.rft'),('source',float('nan'))]:
   item=package();item[field]=value
   with self.assertRaises((ValueError,TypeError)):validate_job(item)
  for value in [True,float('inf'),0,-1]:
   item=package();item['expectedDimensions']['widthMm']=value
   with self.assertRaises(ValueError):validate_job(item)
  for ids in [[],['same','same'],['a','b','c']]:
   with self.assertRaises(ValueError):self.scheduler(ids=ids)

if __name__=='__main__':unittest.main()
