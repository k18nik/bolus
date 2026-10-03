import httpx,time
from datetime import datetime,timedelta
from zoneinfo import ZoneInfo
from pathlib import Path
with httpx.Client(base_url='http://127.0.0.1:8001',timeout=30) as c:
 c.post('/api/auth/demo').raise_for_status();c.headers['x-csrf-token']=c.cookies['csrf']
 today=datetime.now(ZoneInfo('Europe/Moscow')).date()
 r=c.post('/api/reports',json={'type':'doctor','format':'pdf','date_from':str(today-timedelta(days=13)),'date_to':str(today)})
 r.raise_for_status();jobid=r.json()['id']
 for _ in range(20):
  jobs=c.get('/api/reports').json();j=next(j for j in jobs if j['id']==jobid)
  if j['status']=='completed':break
  if j['status']=='failed':raise RuntimeError(j['error'])
  time.sleep(.3)
 pdf=c.get('/api/reports/'+jobid+'/download');pdf.raise_for_status();Path('work/qa-doctor-report.pdf').write_bytes(pdf.content)
 from pypdf import PdfReader
 r=PdfReader('work/qa-doctor-report.pdf');print('PDF pages:',len(r.pages));print('Page lengths:',[len(p.extract_text()) for p in r.pages])
