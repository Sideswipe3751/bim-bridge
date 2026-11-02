"""Runtime-policy backend for resident family jobs; no Autodesk imports."""
from __future__ import annotations
import math
import time
from .jobs import FailedOperation,UnknownOutcome
from .coordination import COORDINATION_PROVIDER_ID
from .family_sessions import PROVIDER_ID

class RuntimeJobBackend:
 def __init__(self,runtime,*,timeout_seconds=120):
  if type(timeout_seconds)is not int or not 1<=timeout_seconds<=300:raise ValueError('Invalid timeout_seconds')
  self.runtime,self.timeout=runtime,timeout_seconds

 def _invoke(self,provider,tool,args,access='write',preview=True):
  try:
   if preview and access=='write':self.runtime.invoke_provider(provider,tool,args,access,True,self.timeout)
   return self.runtime.invoke_provider(provider,tool,args,access,False,self.timeout)
  except Exception as exc:raise UnknownOutcome('Runtime call failed; outcome requires inspection')from exc

 @staticmethod
 def _value(result):
  if not isinstance(result,dict):raise UnknownOutcome('Invalid Runtime evidence')
  current=result
  while True:
   if current.get('status')!='succeeded':
    if current.get('status')in {'failed','rejected','cancelled','expired'}:raise FailedOperation('Terminal native request failure',evidence=current)
    raise UnknownOutcome('Nonterminal Runtime result')
   value=current.get('result',current.get('output'))
   if not isinstance(value,dict):raise UnknownOutcome('Missing native result')
   # Provider envelope -> native request -> result. Every envelope status is
   # checked; a successful outer transport never hides a failed native request.
   if 'status' in value and ('requestId' in value or 'provider' in value) and ('result'in value or 'output'in value):
    current=value
    continue
   return value

 def _info(self,instance):
  try:info=self.runtime.document_info({'application':'revit','instanceId':instance})
  except Exception as exc:raise UnknownOutcome('Cannot confirm live instance/document')from exc
  if info.get('instanceId')!=instance or 'family.session'not in info.get('capabilities',[]):raise UnknownOutcome('Live host identity/capability changed')
  return info

 def inspect(self,instance):
  info=self._info(instance);parking=info.get('document')or{}
  if not parking.get('id')or not parking.get('path','').lower().endswith('.rvt'):raise FailedOperation('Resident worker requires a saved parking project')
  return {'parkingDocument':parking,'document':parking}

 def acquire(self,instance,job,lease_seconds):
  info=self._info(instance);parking=info.get('document')or{}
  if not parking.get('id')or not parking.get('path')or not parking['path'].lower().endswith('.rvt'):raise FailedOperation('Resident worker requires a saved parking project')
  result=self._invoke(COORDINATION_PROVIDER_ID,'task_submit',dict(instanceId=instance,name=job['jobId'],owner='runtime.family-jobs',leaseSeconds=lease_seconds))
  task=result.get('task',result);token=result.get('token')
  if not isinstance(task,dict)or not task.get('taskId')or not token:raise UnknownOutcome('No task lease credentials returned')
  context=dict(taskId=task['taskId'],token=token,parkingDocument=parking,document=parking)
  deadline=time.monotonic()+300;renew_at=time.monotonic()+lease_seconds/3
  while task.get('status')=='queued':
   if time.monotonic()>deadline:raise UnknownOutcome('Timed out waiting for task lease')
   if time.monotonic()>=renew_at:self.renew(instance,context,lease_seconds);renew_at=time.monotonic()+lease_seconds/3
   time.sleep(.1);task=self._invoke(COORDINATION_PROVIDER_ID,'task_poll',dict(instanceId=instance,taskId=context['taskId'],token=token),preview=False);task=task.get('task',task)
  if task.get('status')!='active':raise UnknownOutcome('Task lease is not active')
  return context

 def renew(self,instance,context,lease_seconds):
  result=self._invoke(COORDINATION_PROVIDER_ID,'task_renew',dict(instanceId=instance,taskId=context['taskId'],token=context['token'],leaseSeconds=lease_seconds),preview=False)
  if result.get('task',result).get('status')not in {'active','queued'}:raise UnknownOutcome('Lease renewal not active')

 def _guard(self,instance,context):
  live=self._info(instance);expected=context['document'];actual=live.get('document')or{}
  if any(actual.get(k)!=expected.get(k)for k in ['id','title']):raise UnknownOutcome('Live document changed during job')
  return actual

 def _family(self,action,instance,job,context):
  self._guard(instance,context)
  args=dict(instanceId=instance,action=action,jobId=job['jobId'],documentName=job['documentName'],taskId=context['taskId'],taskToken=context['token'])
  if action=='begin':args['templatePath']=job['templatePath']
  raw=self._invoke(PROVIDER_ID,'family_session',args)
  if raw.get('status')!='succeeded':context['familyFailureEvidence']=raw
  return {**self._value(raw), "lifecycleEvidence": raw}

 def stage(self,name,instance,job,context):
  if name in {'begin','prepare_view','save_close'}:
   value=self._family(name,instance,job,context)
   if value.get('jobId')!=job['jobId']or not isinstance(value.get('document'),dict):raise UnknownOutcome('Family lifecycle identity missing')
   if name=='begin'and value['document'].get('title')!=job['documentName']:raise UnknownOutcome('Created family name mismatch')
   if name=='prepare_view'and(type(value.get('viewId'))is not int or value['viewId']<=0):raise FailedOperation('No printable 3D view')
   if name=='save_close'and(value.get('saved')is not True or value.get('closed')is not True or not value.get('artifactPath')):raise UnknownOutcome('Delivery was not confirmed saved and closed')
   return value
  if name in {'build','verify'}:
   doc=self._guard(instance,context)
   args=dict(instanceId=instance,taskId=context['taskId'],token=context['token'],documentTitle=doc['title'],documentId=doc['id'],description='Prepared family job '+job['jobId']+' '+name,mode='write'if name=='build'else'read',code=job['buildCode'if name=='build'else'verifyCode'],timeoutSeconds=self.timeout)
   result=self._invoke(COORDINATION_PROVIDER_ID,'task_step',args);value=self._value(result)
   if name=='verify':self._verify_dimensions(value,job['expectedDimensions'])
   return {name+'Evidence':result}
  if name=='capture':
   doc=self._guard(instance,context)
   raw=self._invoke('revit.connector.v1','capture_view',dict(instanceId=instance,taskId=context['taskId'],taskToken=context['token'],documentTitle=doc['title'],viewId=context['viewId'],fileStem=job['jobId']),access='read',preview=False)
   value=self._value(raw)
   if not value.get('path'):raise FailedOperation('Capture path missing')
   return {'captureEvidence':value,'captureNativeEvidence':raw}
  if name=='release':
   self._guard(instance,context)
   result=self._invoke(COORDINATION_PROVIDER_ID,'task_release',dict(instanceId=instance,taskId=context['taskId'],token=context['token']),preview=False)
   if result.get('task',result).get('status')not in {'completed','released'}:raise UnknownOutcome('Task release not confirmed')
   return {'releaseEvidence':result}
  raise ValueError('Unknown job stage')

 @staticmethod
 def _verify_dimensions(value,expected):
  if value.get('passed',value.get('geometryValid'))is not True:raise FailedOperation('Structured verification did not pass')
  actual=dict(value)
  if 'heightMm'not in actual and 'zMaxMm'in actual and 'zMinMm'in actual:actual['heightMm']=actual['zMaxMm']-actual['zMinMm']
  for name in ['widthMm','depthMm','heightMm']:
   number=actual.get(name)
   if type(number)not in(int,float)or not math.isfinite(number)or abs(number-expected[name])>expected.get('toleranceMm',1):raise FailedOperation('Dimension mismatch: '+name)

 def cleanup(self,instance,job,context):
  if not context.get('taskId'):return False
  info=self._info(instance);current=info.get('document')or{};parking=context['parkingDocument']
  failed=context.get('familyFailureEvidence')or{}
  lifecycle=(failed.get('result')or{}).get('lifecycle')or{}
  if failed and 'sessionOpen'not in lifecycle:return False
  if context.get('familyDocument')or lifecycle.get('sessionOpen')is True or current.get('id')!=parking.get('id'):
   # A terminal native failure permits one explicit abort, never a code retry.
   context['document']=current
   value=self._family('abort',instance,job,context)
   if value.get('closed')is not True:return False
  confirmed=self._info(instance).get('document')or{}
  if any(confirmed.get(k)!=parking.get(k)for k in ['id','title','path']):return False
  context['document']=parking
  self.stage('release',instance,job,context)
  return True

 def reconcile(self,instance,record):
  # Inspection never invents credentials or reruns mutations. The operator must
  # restore the original parking project and clear connector ownership first.
  info=self._info(instance)
  status=self._invoke(COORDINATION_PROVIDER_ID,'task_status',{'instanceId':instance},access='read',preview=False)
  tasks=status.get('tasks',[]);doc=info.get('document')or{}
  acquired=[h.get('result',{})for h in record.get('history',[])if h.get('stage')=='acquire'and h.get('outcome','succeeded')=='succeeded']
  inspected=[h.get('result',{})for h in record.get('history',[])if h.get('stage')=='inspect'and h.get('outcome','succeeded')=='succeeded']
  parking=acquired[-1].get('parkingDocument',{})if acquired else inspected[-1].get('parkingDocument',{})if inspected else{}
  safe=bool(parking.get('id'))and all(doc.get(k)==parking.get(k)for k in ['id','title','path'])and not any(t.get('status')in {'active','queued','draining'}for t in tasks)
  return {'safeClean':safe,'document':doc,'taskStatus':status}
