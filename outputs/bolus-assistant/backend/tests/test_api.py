from datetime import datetime,timezone,timedelta
from fastapi.testclient import TestClient
from app.main import app
from app.db import SessionLocal
from app.models.entities import Calculation,Entry,Profile,User
from sqlalchemy import select

def timestamp():return datetime.now(timezone.utc).isoformat()
def glucose(**kw):return {'value':6.8,'unit':'mmol/L','measured_at':timestamp(),'client_id':'glucose-1',**kw}
def test_auth_isolation_csrf_and_delete(client):
    assert client.get('/api/diary').status_code==401
    assert client.post('/api/auth/register',json={'email':'one@example.com','password':'test-password-123','name':'One'}).status_code==201
    assert client.post('/api/glucose',json=glucose()).status_code==403
    client.headers['x-csrf-token']=client.cookies['csrf']
    entry=client.post('/api/glucose',json=glucose()).json()
    with TestClient(app) as other:
        other.post('/api/auth/register',json={'email':'two@example.com','password':'test-password-123','name':'Two'})
        other.headers['x-csrf-token']=other.cookies['csrf']
        assert other.get('/api/diary').json()==[]
        assert other.delete('/api/diary/'+entry['id']+'?version=1').status_code==404
    assert client.delete('/api/users/me').status_code==200
    assert client.get('/api/users/me').status_code==401
    with SessionLocal() as db:assert db.get(Entry,entry['id']) is None

def test_idempotent_entry(demo):
    payload=glucose()
    a=demo.post('/api/glucose',json=payload);b=demo.post('/api/glucose',json=payload)
    assert a.status_code==201 and a.json()['id']==b.json()['id']
    assert demo.delete('/api/diary/'+a.json()['id']+'?version=2').status_code==409

def test_validation_and_units(demo):
    assert demo.post('/api/glucose',json=glucose(value=180,unit='mmol/L')).status_code==422
    r=demo.post('/api/glucose',json=glucose(value=180,unit='mg/dL'))
    assert r.json()['data']['value_mmol']==10
    assert demo.post('/api/insulin',json={'units':2,'insulin_type':'basal','purpose':'meal','administered_at':timestamp(),'client_id':'bad'}).status_code==422

def test_meal_snapshot_recipe(demo):
    item={'name_snapshot':'Pasta','grams':100,'amount':100,'unit':'g','carbs':31,'protein':6,'fat':1,'calories':158}
    meal=demo.post('/api/meals',json={'name':'Lunch','meal_type':'lunch','eaten_at':timestamp(),'items':[item],'client_id':'meal-1'})
    assert meal.status_code==201,meal.text
    assert meal.json()['data']['total_carbs']==31
    recipe=demo.post('/api/recipes',json={'name':'Double','ingredients':[item,item],'cooked_weight':250,'servings':2})
    assert recipe.status_code==201,recipe.text
    assert recipe.json()['carbs']==24.8 and recipe.json()['per_serving']['carbs']==31

def test_calculation_server_profile_and_confirmation(demo):
    payload={'glucose':10.2,'unit':'mmol/L','carbs':50,'timestamp':timestamp(),'measured_at':timestamp()}
    assert demo.post('/api/bolus/calculate',json={**payload,'icr':1}).status_code==422
    before=demo.get('/api/iob').json()['iob']
    calc=demo.post('/api/bolus/calculate',json=payload)
    assert calc.status_code==200,calc.text
    r=calc.json();assert r['calculation_status']=='ok'
    assert abs(demo.get('/api/iob').json()['iob']-before)<.01
    confirm={'actual_units':2.2,'administered_at':timestamp()}
    a=demo.post('/api/bolus/'+r['calculation_id']+'/confirm',json=confirm)
    b=demo.post('/api/bolus/'+r['calculation_id']+'/confirm',json=confirm)
    assert a.status_code==200,a.text
    assert a.json()['entry_id']==b.json()['entry_id']
    assert 2.18<demo.get('/api/iob').json()['iob']-before<2.21
    history=demo.get('/api/bolus/history').json()[0]
    assert history['actual_bolus']==2.2 and history['algorithm_version']=='bolus-v1.1.0'
    assert 'profile_version' in history['input_snapshot']

def test_mgdl_same_result(demo):
    common={'carbs':50,'timestamp':timestamp(),'measured_at':timestamp()}
    a=demo.post('/api/bolus/calculate',json={**common,'glucose':10,'unit':'mmol/L'}).json()
    b=demo.post('/api/bolus/calculate',json={**common,'glucose':180,'unit':'mg/dL'}).json()
    assert a['recommended_bolus']==b['recommended_bolus']

def test_stale_blocked_and_cannot_confirm(demo):
    result=demo.post('/api/bolus/calculate',json={'glucose':10,'carbs':50,'timestamp':timestamp(),'measured_at':(datetime.now(timezone.utc)-timedelta(hours=1)).isoformat()}).json()
    assert result['calculation_status']=='blocked'
    assert demo.post('/api/bolus/'+result['calculation_id']+'/confirm',json={'actual_units':1,'administered_at':timestamp()}).status_code==409

def test_profile_versioning_no_rewrite(demo):
    old=demo.get('/api/profile').json();payload={k:v for k,v in old.items() if k not in ('id','version')};payload['segments'][0]['icr']=13
    assert demo.put('/api/profile',json=payload).json()['version']==2
    history=demo.get('/api/profile/history').json();assert len(history)==2
    assert history[1]['data']['segments'][0]['icr']==12
    payload['segments'][0]['end_time']='05:00'
    assert demo.put('/api/profile',json=payload).status_code==422

def test_real_account_calculator_disabled(client):
    client.post('/api/auth/register',json={'email':'real@example.com','password':'test-password-123','name':'Real'})
    client.headers['x-csrf-token']=client.cookies['csrf']
    assert client.post('/api/bolus/calculate',json={'glucose':10,'carbs':40,'timestamp':timestamp(),'measured_at':timestamp()}).status_code==403

def test_ai_contract_separation():
    from pathlib import Path
    from pydantic import ValidationError
    from app.ai.contracts import AIContextBuilder,InsightResponse
    import pytest
    assert AIContextBuilder().build({'email':'private','mean_glucose':7})=={'mean_glucose':7}
    with pytest.raises(ValidationError):InsightResponse(summary='',observations=[],possible_explanations=[],questions=[],safety_flags=[],bolus_units=5)
    for module in ['bolus','iob']:
        for f in (Path(__file__).parent.parent/'app'/module).glob('*.py'):
            assert 'import openai' not in f.read_text()
            assert 'from app.ai' not in f.read_text()
    routes=[r.path for r in app.routes if hasattr(r,'path')]
    assert not any(any(t in path for t in ['deliver_insulin','set_bolus','override_bolus']) for path in routes)

def test_favorites_and_recents(demo):
    food={'name':'Мой продукт','brand':'','serving_name':'100 г','serving_weight':100,'carbs':30,'protein':5,'fat':2,'calories':180,'external_id':'123','provider':'custom'}
    a=demo.post('/api/foods/favorites',json=food);b=demo.post('/api/foods/favorites',json=food)
    assert a.status_code==201 and a.json()['favorite_id']==b.json()['favorite_id']
    assert len(demo.get('/api/foods/favorites').json())==1
    assert demo.delete('/api/foods/favorites/'+a.json()['favorite_id']).status_code==200
    assert demo.get('/api/foods/recent').status_code==200
