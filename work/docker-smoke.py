import httpx,time,json,concurrent.futures
from datetime import datetime,timezone,timedelta
from zoneinfo import ZoneInfo
from pathlib import Path
base='http://localhost:8080'
with httpx.Client(base_url=base,timeout=30) as c:
 assert c.get('/api/health').status_code==200
 assert c.get('/').status_code==200
 assert c.post('/api/auth/demo').status_code==200
 csrf=c.cookies['csrf'];c.headers['x-csrf-token']=csrf
 user=c.get('/api/users/me').json()
 latest=c.get('/api/glucose/latest');assert latest.status_code==200
 analytics=c.get('/api/analytics?days=2&hours=24');assert analytics.status_code==200
 ts=lambda:datetime.now(timezone.utc).isoformat()
 payload={'glucose':10.2,'carbs':40,'timestamp':ts(),'measured_at':ts()}
 calc=c.post('/api/bolus/calculate',json=payload);calc.raise_for_status();r=calc.json();assert r['calculation_status']=='ok',r
 cookies=dict(c.cookies)
 def confirm():
  with httpx.Client(base_url=base,cookies=cookies,headers={'x-csrf-token':csrf},timeout=20) as x:
   r=x.post('/api/bolus/'+r_id+'/confirm',json={'actual_units':1.1,'administered_at':ts()});r.raise_for_status();return r.json()
 r_id=r['calculation_id']
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lambda _:confirm(),range(2)))
 assert results[0]['entry_id']==results[1]['entry_id']
 today=datetime.now(ZoneInfo('Europe/Moscow')).date()
 jobs=[]
 for fmt in ['pdf','xlsx','csv','json']:
  res=c.post('/api/reports',json={'type':'doctor','format':fmt,'date_from':str(today-timedelta(days=6)),'date_to':str(today)});res.raise_for_status();jobs.append((res.json()['id'],fmt))
 deadline=time.monotonic()+45
 while time.monotonic()<deadline:
  index={j['id']:j for j in c.get('/api/reports').json()}
  if all(index[j]['status']=='completed' for j,_ in jobs):break
  if any(index[j]['status']=='failed' for j,_ in jobs):raise RuntimeError('Celery report failed')
  time.sleep(.5)
 sizes={}
 for job,fmt in jobs:
  res=c.get('/api/reports/'+job+'/download');res.raise_for_status();sizes[fmt]=len(res.content)
  if fmt=='pdf':assert res.content.startswith(b'%PDF')
  if fmt=='json':assert res.json()['schema_version']=='1.0'
 assert c.get('/api/foods/favorites').status_code==200
 result={'stack':'Docker Compose / PostgreSQL / Redis / Celery / Nginx','health':'ok','concurrent_confirm':'one InsulinEntry','async_reports':sizes,'latest_glucose':'ok','rolling_analytics':'ok','favorites_migration':'ok'}
 Path('work/docker-smoke-result.json').write_text(json.dumps(result,indent=2))
 print(json.dumps(result))
