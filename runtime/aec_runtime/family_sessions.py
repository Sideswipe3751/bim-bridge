"""Discoverable, task-owned native family lifecycle projection."""
from __future__ import annotations
import copy
from pathlib import Path
from . import coordination
from .hosts import execute_connector_operation, load_instances
from .jobs import _SAFE_NAME

PROVIDER_ID = 'bimbridge.family.v1'
_TOOL = {'name':'family_session','description':'Begin, prepare a focused 3D view, save and close, or abort one task-owned family in a resident Revit instance. Native lifecycle operations are not atomic model transactions.',
 'inputSchema':{'type':'object','properties':{'instanceId':{'type':'string','minLength':1},'action':{'enum':['begin','prepare_view','save_close','abort']},'jobId':{'type':'string','pattern':_SAFE_NAME.pattern},'documentName':{'type':'string','pattern':_SAFE_NAME.pattern},'templatePath':{'type':'string','maxLength':2048},'taskId':{'type':'string','minLength':1},'taskToken':{'type':'string','minLength':1}},'required':['instanceId','action','jobId','documentName','taskId','taskToken'],'additionalProperties':False},
 'annotations':{'readOnlyHint':False,'destructiveHint':True,'idempotentHint':False,'openWorldHint':False}}

def validate(arguments, intent='write'):
 if intent!='write' or not isinstance(arguments,dict):raise ValueError('Family lifecycle requires write intent')
 required={'action','jobId','documentName','taskId','taskToken'}
 if not required<=set(arguments) or set(arguments)-required-{'templatePath'}:raise ValueError('Invalid family session fields')
 if arguments['action'] not in {'begin','prepare_view','save_close','abort'}:raise ValueError('Invalid family action')
 for name in ['jobId','documentName']:
  if not isinstance(arguments[name],str) or not _SAFE_NAME.fullmatch(arguments[name]):raise ValueError('Invalid '+name)
 for name in ['taskId','taskToken']:
  if not isinstance(arguments[name],str) or not arguments[name].strip() or len(arguments[name])>512:raise ValueError('Invalid credentials')
 if arguments['action']=='begin':
  path=arguments.get('templatePath')
  if not isinstance(path,str) or len(path)>2048 or not Path(path).is_absolute() or Path(path).suffix.lower()!='.rft':raise ValueError('Begin requires absolute templatePath .rft')
 elif 'templatePath'in arguments:raise ValueError('templatePath is only valid for begin')
 return dict(arguments)

def descriptor(probe=False):
 instances,_=load_instances();ready=any('family.session'in i.get('capabilities',[])for i in instances)
 return {'id':PROVIDER_ID,'displayName':'BIM Bridge Family Sessions','version':'1','application':'revit','source':'builtin-host','status':'ready'if ready else 'unavailable'if probe else 'configured','toolCount':1,'error':None if ready or not probe else 'No connector advertises family.session'}

def schema(name):
 if name!='family_session':raise ValueError('Unknown family session tool')
 return {'provider':PROVIDER_ID,'tool':copy.deepcopy(_TOOL),'access':'write'}

def search(query,limit=20):
 words=query.lower().replace('_',' ').split();match=not words or any(w in 'family session begin prepare view save close abort resident'for w in words)
 return {'tools':[{'provider':PROVIDER_ID,'name':'family_session','description':_TOOL['description'],'access':'write','blocked':False}][:limit]if match else [],'errors':[]}

def execute(instance,arguments,intent,*,dry_run=False,timeout=30):
 values=validate(arguments,intent)
 if dry_run:return {'status':'succeeded','result':{'dryRun':True,'executed':False,'action':values['action']}}
 task_id,task_token=values.pop('taskId'),values.pop('taskToken')
 return execute_connector_operation(instance,'family.session',values,'write',timeout,task_id=task_id,task_token=task_token)

def invoke(runtime,name,arguments,access,dry_run=False,timeout=30):
 schema(name)
 if not isinstance(arguments,dict) or not isinstance(arguments.get('instanceId'),str):raise ValueError('Exact instanceId required')
 values=validate({k:v for k,v in arguments.items()if k!='instanceId'},access)
 if type(dry_run)is not bool or type(timeout)is not int or not 1<=timeout<=300:raise ValueError('Invalid family timeout/dryRun')
 instance=coordination._live_instance(arguments['instanceId'])
 if 'family.session'not in instance.get('capabilities',[]):raise RuntimeError('Host does not support family.session')
 request,plan=runtime._plan_connector(instance,'family.session','write',values)
 if dry_run:return execute(instance,values,access,dry_run=True,timeout=timeout)
 plan.mark_execution_started()
 try:result=execute(instance,values,access,timeout=timeout)
 except Exception:
  runtime.audit.record(request['correlationId'],'execution.failed',{'operation':'family.session','action':values['action']});raise
 runtime.audit.record(request['correlationId'],'execution.completed',{'operation':'family.session','action':values['action'],'status':result.get('status'),'jobId':values['jobId']})
 return result
