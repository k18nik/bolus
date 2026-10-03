from datetime import datetime,timezone,timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

def payload(client):
    at=datetime.now(timezone.utc)
    return {'expected_user_id':client.get('/api/users/me').json()['id'],'timezone':'Europe/Moscow','workouts':[{'id':str(uuid4()),'name':'Ходьба','source_name':'Apple Watch','started_at':(at-timedelta(hours=1)).isoformat(),'ended_at':at.isoformat(),'duration_minutes':55,'active_energy':150}],'days':[{'date':at.astimezone(ZoneInfo('Europe/Moscow')).date().isoformat(),'steps':4000,'exercise_minutes':55}]}

def test_sync_upserts_observations_only(demo):
    p=payload(demo);iob=demo.get('/api/iob').json()['iob'];profile=demo.get('/api/profile').json()
    r=demo.post('/api/imports/healthkit',json=p);assert r.status_code==200,r.text
    assert r.json()['inserted']==2
    assert demo.post('/api/imports/healthkit',json=p).json()['unchanged']==2
    p['days'][0]['steps']=5000
    assert demo.post('/api/imports/healthkit',json=p).json()['updated']==1
    assert demo.get('/api/profile').json()==profile
    assert abs(demo.get('/api/iob').json()['iob']-iob)<.01

def test_healthkit_auth_validation_and_atomicity(client,demo):
    p=payload(demo);p['expected_user_id']='different-user'
    assert demo.post('/api/imports/healthkit',json=p).status_code==409
    p=payload(demo);p['days'][0]['steps']=-1
    assert demo.post('/api/imports/healthkit',json=p).status_code==422
    p=payload(demo);p['days'][0]['date']='2999-01-01'
    assert demo.post('/api/imports/healthkit',json=p).status_code==422
    p['days']=[]
    assert demo.post('/api/imports/healthkit',json=p).json()['inserted']==1
    p['workouts'].append(p['workouts'][0])
    assert demo.post('/api/imports/healthkit',json=p).status_code==422

def test_healthkit_missing_permissions_not_fabricated(demo):
    p=payload(demo);p['days']=[{'date':p['days'][0]['date'],'steps':120}]
    assert demo.post('/api/imports/healthkit',json=p).status_code==200
    rows=demo.get('/api/diary').json()
    day=next(r for r in rows if r['data'].get('source_kind')=='healthkit' and r['kind']=='activity_summary')
    assert day['data']['steps']==120 and 'exercise_minutes' not in day['data']
    p['days'][0]={'date':p['days'][0]['date'],'exercise_minutes':5}
    assert demo.post('/api/imports/healthkit',json=p).json()['updated']==1
    rows=demo.get('/api/diary').json()
    day=next(r for r in rows if r['data'].get('source_kind')=='healthkit' and r['kind']=='activity_summary')
    assert day['data']['steps']==120 and day['data']['exercise_minutes']==5
