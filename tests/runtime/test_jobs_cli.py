from __future__ import annotations
import contextlib,io,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'runtime'))
from aec_runtime import jobs_cli

class JobCliTests(unittest.TestCase):
 def call(self,action,state,extra=None):
  with tempfile.TemporaryDirectory()as directory,patch.object(jobs_cli,'JobStore')as store,patch.object(jobs_cli,'JobScheduler')as scheduler,contextlib.redirect_stdout(io.StringIO())as output:
   store.return_value.record_review.return_value={'status':'review_failed'}
   scheduler.return_value.run.return_value=state
   args=['--run-dir',directory,action]+(extra or[])
   if action=='run':args+=['--instance-id','exact-instance']
   code=jobs_cli.main(args);return code,__import__('json').loads(output.getvalue())
 def test_run_quarantine_failed_and_ready_return_nonzero(self):
  for status in ['needs_reconcile','failed','ready','review_failed']:
   code,_=self.call('run',{'jobs':{'j':{'jobId':'j','status':status}},'instances':{},'sealed':True})
   self.assertNotEqual(code,0)
 def test_awaiting_review_returns_physical_success_and_explicit_review_pending(self):
  code,result=self.call('run',{'jobs':{'j':{'jobId':'j','status':'awaiting_review'}},'instances':{},'sealed':True})
  self.assertEqual(code,0);self.assertTrue(result['executionSummary']['physicalExecutionComplete']);self.assertEqual(result['executionSummary']['visualReviewPending'],['j'])
 def test_streaming_idle_without_seal_returns_nonzero(self):
  code,result=self.call('run',{'jobs':{},'instances':{},'sealed':False},['--wait-for-seal'])
  self.assertNotEqual(code,0);self.assertTrue(result['executionSummary']['producerSessionUnsealed'])
 def test_explicit_failed_review_is_recorded_but_exit_is_failure(self):
  code,result=self.call('review',{},['--job-id','j','--content-hash','a'*64,'--result','failed','--reviewer','test','--evidence','image.png'])
  self.assertNotEqual(code,0);self.assertEqual(result['status'],'review_failed')

if __name__=='__main__':unittest.main()
