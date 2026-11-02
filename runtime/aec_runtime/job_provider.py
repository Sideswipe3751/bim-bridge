"""Small provider projection over the neutral local JobStore/JobScheduler API."""
from __future__ import annotations
import copy
import os
import math
import re
from pathlib import Path
from .jobs import JobStore,JobScheduler,_SAFE_NAME,validate_job,content_hash
from .job_backend import RuntimeJobBackend

PROVIDER_ID='bimbridge.jobs.v1'
_TEXT={'type':'string','minLength':1,'maxLength':200}
_RUN={'type':'string','pattern':_SAFE_NAME.pattern}
_INSTANCES={'type':'array','minItems':1,'maxItems':2,'uniqueItems':True,'items':_TEXT}
_PROPERTIES={
 'job_submit':{'runId':_RUN,'job':{'$ref':'https://bim-bridge.local/protocol/v2/bim-bridge-contract.schema.json#/$defs/familyJobPackage'}},
 'job_status':{'runId':_RUN},
 'jobs_seal':{'runId':_RUN},
 'job_run':{'runId':_RUN,'instanceIds':_INSTANCES,'waitForSeal':{'type':'boolean'},'idleTimeoutSeconds':{'type':'number','exclusiveMinimum':0,'maximum':300}},
 'job_reconcile':{'runId':_RUN,'instanceIds':_INSTANCES,'instanceId':_TEXT},
 'job_review':{'runId':_RUN,'jobId':_RUN,'contentHash':{'type':'string','pattern':'^[a-f0-9]{64}$'},'passed':{'type':'boolean'},'reviewer':_TEXT,'evidence':{'type':'string','minLength':1,'maxLength':4096}},
}
_DESCRIPTIONS={'job_submit':'Submit an immutable prepared family package to a bounded durable FIFO.',
 'jobs_seal':'Seal a finite prepared-job producer session; waiting workers drain then return.',
 'job_status':'Inspect execution facts and outstanding visual reviews without exposing package code.',
 'job_run':'Dispatch the ready FIFO to one or two exact resident instances using existing Runtime policy and task leases; blocks until workers drain or quarantine.',
 'job_reconcile':'Explicitly inspect a quarantined instance; never replay its interrupted job.',
 'job_review':'Record an explicit human or agent visual inspection bound to the delivered package hash and evidence.'}

def schema(name):
 if name not in _PROPERTIES:raise ValueError('Unknown job tool')
 read=name=='job_status'
 return {'provider':PROVIDER_ID,'access':'read'if read else'write','tool':{'name':name,'description':_DESCRIPTIONS[name],
  'inputSchema':{'type':'object','properties':copy.deepcopy(_PROPERTIES[name]),'required':[k for k in _PROPERTIES[name] if k not in {'waitForSeal','idleTimeoutSeconds'}],'additionalProperties':False},
  'annotations':{'readOnlyHint':read,'destructiveHint':not read,'idempotentHint':read,'openWorldHint':False}}}

def descriptor(probe=False):
 return {'id':PROVIDER_ID,'displayName':'BIM Bridge Prepared Family Jobs','version':'1','application':'revit','source':'builtin-runtime','status':'ready','toolCount':len(_PROPERTIES),'error':None}

def search(query,limit=20):
 words=query.lower().replace('_',' ').split()
 return {'tools':[{'provider':PROVIDER_ID,'name':name,'description':desc,'access':schema(name)['access'],'blocked':False}for name,desc in _DESCRIPTIONS.items()if not words or any(w in(name+' '+desc).lower()for w in words)][:limit],'errors':[]}

def store_directory(run_id):
 root=Path(os.environ.get('BIM_BRIDGE_JOB_DIR')or(Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'BIM Bridge/jobs'))
 return root/run_id

def invoke(runtime,name,arguments,access,dry_run=False,timeout=30):
 spec=schema(name)
 if access!=spec['access']or type(dry_run)is not bool:raise ValueError('Job access/dry-run mismatch')
 if not isinstance(arguments,dict)or not set(spec['tool']['inputSchema']['required'])<=set(arguments)or set(arguments)-set(_PROPERTIES[name]):raise ValueError('Invalid job tool fields')
 run_id=arguments['runId']
 if not isinstance(run_id,str)or not _SAFE_NAME.fullmatch(run_id):raise ValueError('Invalid runId')
 for key,value in arguments.items():
  rule=_PROPERTIES[name][key];kind=rule.get('type')
  if kind=='string'and(not isinstance(value,str)or not value.strip()or len(value)>rule.get('maxLength',4096)or ('pattern'in rule and re.fullmatch(rule['pattern'],value)is None)):
   raise ValueError('Invalid '+key)
  if kind=='boolean'and type(value)is not bool:raise ValueError('Invalid '+key)
  if kind=='number'and(type(value)not in(int,float)or not math.isfinite(value)or not 0<value<=rule['maximum']):raise ValueError('Invalid '+key)
 if name=='job_submit':validate_job(arguments['job'])
 ids=arguments.get('instanceIds')
 if ids is not None and(not isinstance(ids,list)or not 1<=len(ids)<=2 or any(not isinstance(i,str)or not i.strip()or len(i)>200 for i in ids)or len(set(ids))!=len(ids)):raise ValueError('Choose one or two exact instances')
 if name=='job_reconcile'and arguments['instanceId']not in ids:raise ValueError('Reconcile instance is not a worker')
 if dry_run:return {'dryRun':True,'executed':False,'tool':name,'runId':run_id}
 metadata={'action':name,'runId':run_id}
 if name=='job_submit':metadata.update(jobId=arguments['job']['jobId'],contentHash=content_hash(arguments['job']))
 for key in ['jobId','contentHash']:
  if key in arguments:metadata[key]=arguments[key]
 runtime.audit.record('', 'jobs.requested', metadata)
 store=JobStore(store_directory(run_id))
 if name=='job_submit':result=store.submit(arguments['job'])
 elif name=='job_status':result=store.snapshot()
 elif name=='jobs_seal':result=store.seal()
 elif name=='job_review':result=store.record_review(arguments['jobId'],arguments['contentHash'],arguments['passed'],reviewer=arguments['reviewer'],evidence=arguments['evidence'])
 else:
  scheduler=JobScheduler(store,RuntimeJobBackend(runtime,timeout_seconds=timeout),ids)
  result=scheduler.reconcile(arguments['instanceId'])if name=='job_reconcile'else scheduler.run(wait_for_seal=arguments.get('waitForSeal',False),idle_timeout_seconds=arguments.get('idleTimeoutSeconds',60))
 runtime.audit.record('', 'jobs.completed', metadata)
 return result
