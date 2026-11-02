from __future__ import annotations
import json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'runtime'))
from aec_runtime import BimBridgeRuntime,AuditTrail
from aec_runtime import family_sessions as f,job_provider
from aec_runtime.job_backend import RuntimeJobBackend
from aec_runtime.jobs import FailedOperation,UnknownOutcome

class BackendTests(unittest.TestCase):
 def setUp(self):
  self.runtime=Mock();self.backend=RuntimeJobBackend(self.runtime)
  self.parking=dict(id='parking-id',title='parking',path='C:/test/parking.rvt')
  self.family=dict(id='family-id',title='BB_test',path='C:/test/test/BB_test.rfa')
  self.info=dict(instanceId='instance',document=self.parking,capabilities=['family.session','task.coordination'])
  self.runtime.document_info.return_value=self.info
  self.context=dict(taskId='task',token='private-token',parkingDocument=self.parking,document=self.family,familyDocument=self.family)
  self.job=dict(jobId='test',documentName='BB_test',templatePath='C:/template.rft',buildCode='return 1;',verifyCode='return 2;',expectedDimensions=dict(widthMm=1,depthMm=2,heightMm=3))
 def test_actual_capture_envelope_unwraps_native_result(self):
  # This is the baseline capture provider/native shape, including both statuses.
  native=dict(requestId='native-1',status='succeeded',kind='execute',mode='read',result=dict(path='capture.png',viewId=52),elapsedMilliseconds=200)
  actual=dict(status='succeeded',provider='revit.connector.v1',tool='capture_view',result=native)
  self.assertEqual(self.backend._value(actual),dict(path='capture.png',viewId=52))
  actual['result']['status']='failed'
  with self.assertRaises(FailedOperation):self.backend._value(actual)
 def test_failure_cleanup_aborts_open_session_even_when_parking_active(self):
  self.context['document']=self.parking
  self.context['familyFailureEvidence']=dict(status='failed',result=dict(lifecycle=dict(sessionOpen=True)))
  self.runtime.invoke_provider.side_effect=[{'dryRun':True},{'status':'succeeded','result':dict(closed=True)},dict(status='completed')]
  self.assertTrue(self.backend.cleanup('instance',self.job,self.context))
  actions=[c.args[2].get('action')for c in self.runtime.invoke_provider.call_args_list]
  self.assertIn('abort',actions)
  self.assertEqual(self.runtime.invoke_provider.call_args_list[-1].args[1],'task_release')
  self.assertGreaterEqual(self.runtime.document_info.call_count,3)
 def test_failure_cleanup_no_lifecycle_evidence_never_releases(self):
  self.context.pop('familyDocument');self.context['familyFailureEvidence']={'status':'failed','result':{}}
  self.assertFalse(self.backend.cleanup('instance',self.job,self.context));self.runtime.invoke_provider.assert_not_called()
 def test_verified_dimensions_fail_closed(self):
  for values in [dict(passed=True,widthMm=1,depthMm=2,heightMm=5),dict(passed=False,widthMm=1,depthMm=2,heightMm=3),dict(passed=True,widthMm=True,depthMm=2,heightMm=3)]:
   with self.assertRaises(FailedOperation):self.backend._verify_dimensions(values,self.job['expectedDimensions'])
  self.backend._verify_dimensions(dict(geometryValid=True,widthMm=1,depthMm=2,zMinMm=0,zMaxMm=3),self.job['expectedDimensions'])
 def test_runtime_exceptions_are_unknown_and_never_retried(self):
  self.runtime.invoke_provider.side_effect=TimeoutError()
  with self.assertRaises(UnknownOutcome):self.backend._invoke('p','tool',{})
  self.assertEqual(self.runtime.invoke_provider.call_count,1)

class FamilyProjectionTests(unittest.TestCase):
 def setUp(self):
  self.runtime=BimBridgeRuntime(audit=AuditTrail())
  self.instance=dict(instanceId='i',processId=1,application='revit',applicationVersion='2024',document=dict(id='doc',title='parking',path='C:/p.rvt'),capabilities=['family.session','task.coordination'])
  self.args=dict(instanceId='i',action='begin',jobId='job',documentName='BB_test',templatePath=str(Path(tempfile.gettempdir())/'template.rft'),taskId='t',taskToken='secret')
 def test_discovery_and_read_access_blocked(self):
  self.assertEqual(self.runtime.provider_schema(f.PROVIDER_ID,'family_session')['access'],'write')
  self.assertTrue(self.runtime.search_provider_tools('family',f.PROVIDER_ID,5)['tools'])
  with self.assertRaises(ValueError):self.runtime.invoke_provider(f.PROVIDER_ID,'family_session',self.args,'read',False,30)
 def test_dry_run_plans_and_never_posts_or_opens_document(self):
  with patch.object(f.coordination,'_live_instance',return_value=self.instance),patch.object(f,'execute_connector_operation')as execute:
   result=self.runtime.invoke_provider(f.PROVIDER_ID,'family_session',self.args,'write',True,30)
  self.assertFalse(result['result']['executed']);execute.assert_not_called()
 def test_wire_credentials_outside_domain_options(self):
  with patch.object(f.coordination,'_live_instance',return_value=self.instance),patch.object(f,'execute_connector_operation',return_value={'status':'succeeded','result':{}})as execute:
   self.runtime.invoke_provider(f.PROVIDER_ID,'family_session',self.args,'write',False,30)
  args,kw=execute.call_args
  self.assertEqual(kw,dict(task_id='t',task_token='secret'));self.assertNotIn('taskId',args[2]);self.assertNotIn('instanceId',args[2])
  self.assertNotIn('secret',str(self.runtime.audit.records()))
 def test_template_on_other_action_rejected(self):
  values={k:v for k,v in self.args.items()if k!='instanceId'};values['action']='abort'
  with self.assertRaises(ValueError):f.validate(values)
 def test_family_transaction_does_not_claim_rollback_or_commit(self):
  from aec_runtime.verification import normalize_execution_result
  r=normalize_execution_result(dict(capabilityId='revit.family.session',intent='write',correlationId='test'),provider_id='host',host_evidence={},provider_result=dict(status='succeeded',result={}),audit_id='audit')
  self.assertEqual(r['transaction']['status'],'not_applicable');self.assertFalse(r['transaction']['rolledBack'])
 def test_job_provider_discoverability_and_no_side_effect_preview(self):
  self.assertEqual(self.runtime.provider_schema(job_provider.PROVIDER_ID,'job_run')['access'],'write')
  result=self.runtime.invoke_provider(job_provider.PROVIDER_ID,'job_run',dict(runId='example',instanceIds=['one','two']),'write',True,30)
  self.assertFalse(result['executed'])
  with self.assertRaises(ValueError):self.runtime.invoke_provider(job_provider.PROVIDER_ID,'job_run',dict(runId='../escape',instanceIds=['one']),'write',False,30)

class JobMetadataBoundaryTests(unittest.TestCase):
 def setUp(self):self.runtime=BimBridgeRuntime(audit=AuditTrail())
 def test_invalid_preview_scalars_fail_before_store_creation(self):
  for values in [dict(runId='test',instanceIds=['i'],waitForSeal='yes'),dict(runId='test',instanceIds=['i'],idleTimeoutSeconds=True),dict(runId='test',instanceIds=['i'],idleTimeoutSeconds=float('inf'))]:
   with patch.object(job_provider,'JobStore')as store:
    with self.assertRaises(ValueError):job_provider.invoke(self.runtime,'job_run',values,'write',True,30)
    store.assert_not_called()
 def test_local_metadata_audit_contains_only_bound_ids_and_action(self):
  from test_jobs import package
  with tempfile.TemporaryDirectory()as directory,patch.object(job_provider,'store_directory',return_value=Path(directory)):
   result=job_provider.invoke(self.runtime,'job_submit',dict(runId='test',job=package()),'write',False,30)
  records=self.runtime.audit.records();self.assertEqual(len(records),2)
  for record in records:
   self.assertEqual(set(record['details']),{'action','runId','jobId','contentHash'})
   self.assertEqual(record['details']['contentHash'],result['contentHash'])
  self.assertNotIn('return 1;',str(records));self.assertNotIn('approvalGrant',str(records))

if __name__=='__main__':unittest.main()
