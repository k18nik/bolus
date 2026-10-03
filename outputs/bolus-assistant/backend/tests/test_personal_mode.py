import json
from decimal import Decimal
from datetime import datetime,timezone,timedelta
import pytest,httpx
from cryptography.fernet import Fernet
from sqlalchemy import select
from fastapi.testclient import TestClient
from app.main import app
from app.config import settings
from app.db import SessionLocal
from app.models.entities import AISettings,AIInsight,Calculation,Entry,Cycle,AuditLog,Profile
from app.bolus.engine import calculate
from app.ai.service import validate_explanation
from fastapi import HTTPException
from hypothesis import given,strategies as st

ORIGINAL_ASYNC_CLIENT=httpx.AsyncClient

def now():return datetime.now(timezone.utc).isoformat()

@pytest.fixture
def personal(client,monkeypatch):
    monkeypatch.setattr(settings,'clinical_use_enabled',True)
    monkeypatch.setattr(settings,'feature_ai',True)
    monkeypatch.setattr(settings,'app_encryption_key',Fernet.generate_key().decode())
    assert client.post('/api/auth/register',json={'email':'personal@example.com','name':'Personal Test','password':'test-password-123'}).status_code==201
    client.headers['x-csrf-token']=client.cookies['csrf']
    p={'rapid_insulin_name':'Фиасп','basal_insulin_name':'Тресиба','bolus_increment':1,'basal_increment':1,'max_bolus':15,'insulin_action_duration':4,'confirmed':True,'segments':[{'start_time':'00:00','end_time':'24:00','icr':10,'isf':2,'target':6,'correct_above':7}]}
    assert client.put('/api/profile',json=p).status_code==200
    return client

def calc_payload(**values):return {'glucose':6,'carbs':35,'timestamp':now(),'measured_at':now(),**values}

def test_personal_step_snapshot_and_insulin_type(personal):
    r=personal.post('/api/bolus/calculate',json=calc_payload()).json()
    assert r['recommended_bolus']==3 and r['unrounded_bolus']==3.5 and r['rounding_increment']==1
    assert r['insulin_name']=='Фиасп' and not r['demo']
    assert personal.post('/api/bolus/'+r['calculation_id']+'/confirm',json={'actual_units':3.5,'administered_at':now()}).status_code==422
    p=personal.get('/api/profile').json();p.pop('id');p.pop('version');p['bolus_increment']=0.5
    assert personal.put('/api/profile',json=p).status_code==200
    # Current settings never override the device step in a saved calculation.
    assert personal.post('/api/bolus/'+r['calculation_id']+'/confirm',json={'actual_units':3.5,'administered_at':now()}).status_code==422
    assert personal.post('/api/bolus/'+r['calculation_id']+'/confirm',json={'actual_units':3,'administered_at':now()}).status_code==200
    assert personal.post('/api/insulin',json={'units':10,'insulin_type':'rapid','insulin_name':'Тресиба','purpose':'meal','administered_at':now(),'client_id':'bad-type'}).status_code==422
    before=personal.get('/api/iob').json()['iob']
    basal=personal.post('/api/insulin',json={'units':10,'insulin_type':'basal','purpose':'basal','administered_at':now(),'client_id':'basal'})
    assert basal.status_code==201,basal.text
    assert basal.json()['data']['insulin_name']=='Тресиба'
    assert basal.json()['data']['insulin_id']=='tresiba'
    assert abs(personal.get('/api/iob').json()['iob']-before)<.01
    history=personal.get('/api/bolus/history').json()[0]
    assert history['input_snapshot']['bolus_increment']==1
    assert history['input_snapshot']['insulin_id']=='fiasp'

@pytest.mark.parametrize('step,expected',[(1,3),(.5,3.5),(.25,3.75),(.1,3.7)])
def test_device_steps(step,expected):
    at=datetime.now(timezone.utc)
    d={'glucose':6,'carbs':37.5,'icr':10,'isf':2,'target':6,'correct_above':7,'dia':4,'iob':0,'max_bolus':15,'unit':'mmol/L','measured_at':at.isoformat(),'bolus_increment':step}
    assert calculate(d,at)['recommended_bolus']==expected

@given(carbs=st.integers(0,5000),step=st.sampled_from([.1,.25,.5,1,2]))
def test_rounding_never_exceeds_raw_and_is_deliverable(carbs,step):
    at=datetime.now(timezone.utc)
    result=calculate({'glucose':6,'carbs':carbs/10,'icr':10,'isf':2,'target':6,'correct_above':7,'dia':4,'iob':0,'max_bolus':50,'unit':'mmol/L','measured_at':at.isoformat(),'bolus_increment':step},at)
    dose=Decimal(str(result['recommended_bolus']))
    assert dose%Decimal(str(step))==0
    assert 0<=dose<=Decimal(str(result['unrounded_bolus']))<=50

@pytest.mark.parametrize('step',[0,-1,.3,float('nan'),float('inf'),True,'1'])
def test_invalid_step_blocks(step):
    at=datetime.now(timezone.utc)
    result=calculate({'glucose':6,'carbs':35,'icr':10,'isf':2,'target':6,'correct_above':7,'dia':4,'iob':0,'max_bolus':15,'unit':'mmol/L','measured_at':at.isoformat(),'bolus_increment':step},at)
    assert result['recommended_bolus'] is None and 'invalid_dose_step' in result['warnings']

def test_batch_optional_atomic_idempotent(personal):
    p={'client_id':'only-glucose','glucose':{'value':6.8,'measured_at':now(),'client_id':'g'}}
    a=personal.post('/api/diary/batch',json=p);b=personal.post('/api/diary/batch',json=p)
    assert a.status_code==201,a.text
    assert a.json()==b.json() and a.json()['count']==1
    changed={**p,'glucose':{**p['glucose'],'value':7}}
    assert personal.post('/api/diary/batch',json=changed).status_code==409
    invalid={'client_id':'failed','glucose':p['glucose'],'insulin':[{'units':1.5,'administered_at':now(),'client_id':'i'}]}
    assert personal.post('/api/diary/batch',json=invalid).status_code==422
    assert len(personal.get('/api/diary').json())==1
    assert personal.post('/api/diary/batch',json={'client_id':'empty'}).status_code==422
    mixed={'client_id':'mixed','cycle':{'start_date':now()[:10]},'activity':{'name':'Ходьба','duration_minutes':20,'occurred_at':now(),'client_id':'a'},'note':{'note':'Запись','occurred_at':now(),'client_id':'n'}}
    a=personal.post('/api/diary/batch',json=mixed);assert a.status_code==201,a.text
    assert a.json()['count']==3 and personal.post('/api/diary/batch',json=mixed).json()==a.json()
    with SessionLocal() as db:assert len(list(db.scalars(select(Cycle))))==1

def configure_ai(client,consent=True):
    response=client.put('/api/ai/settings',json={'api_key':'sk-test-secret-key-not-real-12345','consent':consent,'model':'gpt-4.1-mini'})
    assert response.status_code==200,response.text
    return response

def test_latest_glucose_same_measurement_time(personal):
    at=now()
    for client_id,value in [('earlier',6.8),('later',6)]:
        r=personal.post('/api/diary/batch',json={'client_id':client_id,'glucose':{'value':value,'measured_at':at,'client_id':client_id}})
        assert r.status_code==201,r.text
    assert personal.get('/api/glucose/latest').json()['data']['value_mmol']==6

def test_ai_secret_consent_and_isolation(personal):
    assert personal.post('/api/ai/chat',json={'question':'Наблюдения?'}).status_code==409
    r=configure_ai(personal,False)
    assert 'sk-test' not in r.text
    assert personal.post('/api/ai/chat',json={'question':'Наблюдения?'}).status_code==409
    with SessionLocal() as db:
        row=db.scalar(select(AISettings));assert 'sk-test' not in row.encrypted_key
        assert Fernet(settings.app_encryption_key.encode()).decrypt(row.encrypted_key.encode()).decode().startswith('sk-test')
        assert 'sk-test' not in json.dumps([a.new_value for a in db.scalars(select(AuditLog))])
    with TestClient(app) as other:
        other.post('/api/auth/register',json={'email':'other@example.com','password':'test-password-123'})
        other.headers['x-csrf-token']=other.cookies['csrf']
        assert not other.get('/api/ai/settings').json()['key_configured']
        assert other.get('/api/ai/history').json()==[]
    assert personal.delete('/api/ai/settings/key').status_code==200
    assert not personal.get('/api/ai/settings').json()['key_configured']

def insight(**kw):return {'summary':'Наблюдений пока мало.','observations':['Записанные значения требуют сопоставления с едой.'],'possible_explanations':[],'questions':['Есть ли измерения после тренировки?'],'safety_flags':['Ручные измерения не отражают весь день.'],**kw}

def mock_provider(monkeypatch,body,status=200):
    from app.ai import service
    calls=[];original=ORIGINAL_ASYNC_CLIENT
    def handle(request):calls.append(request);return httpx.Response(status,json=body)
    monkeypatch.setattr(service.httpx,'AsyncClient',lambda **kwargs:original(transport=httpx.MockTransport(handle),**kwargs))
    return calls

def test_real_api_contract_aggregate_context_and_no_dose_mutation(personal,monkeypatch):
    configure_ai(personal)
    calc=personal.post('/api/bolus/calculate',json=calc_payload()).json()
    personal.post('/api/notes',json={'note':'PRIVATE NOTE','occurred_at':now(),'client_id':'private'})
    calls=mock_provider(monkeypatch,{'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':json.dumps(insight())}]}],'usage':{'input_tokens':111,'output_tokens':42,'total_tokens':153}})
    response=personal.post('/api/ai/chat',json={'question':'Объясни расчёт','days':14,'calculation_id':calc['calculation_id']})
    assert response.status_code==200,response.text
    payload=json.loads(calls[0].content)
    assert str(calls[0].url)=='https://api.openai.com/v1/responses'
    assert payload['store'] is False and payload['text']['format']['strict'] is True and 'tools' not in payload
    context=payload['input'][1]['content']
    assert 'personal@example.com' not in context and 'PRIVATE NOTE' not in context and 'Personal Test' not in context
    assert 'fiasp' in context and 'tresiba' in context
    assert response.json()['usage']['total_tokens']==153
    assert personal.get('/api/ai/settings').json()['total_tokens']==153
    with SessionLocal() as db:
        c=db.get(Calculation,calc['calculation_id']);assert c.actual_bolus is None and c.calculation_snapshot['recommended_bolus']==3
        assert len(list(db.scalars(select(Profile))))==1
        assert not list(db.scalars(select(Entry).where(Entry.kind=='insulin')))

@pytest.mark.parametrize('body',[{'status':'incomplete','output':[]},{'status':'completed','output':[{'type':'function_call','name':'set_bolus'}]},{'status':'completed','output':[{'type':'message','content':[{'type':'refusal'}]}]},{'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':json.dumps(insight(summary='Введите 3 ЕД инсулина'))}]}]}])
def test_ai_refusal_truncation_tool_and_dose_rejected(personal,monkeypatch,body):
    configure_ai(personal);mock_provider(monkeypatch,body)
    assert personal.post('/api/ai/chat',json={'question':'Анализ'}).status_code in (422,502)
    assert personal.get('/api/ai/history').json()==[]

@pytest.mark.parametrize('status',[401,429,500])
def test_ai_provider_errors_are_sanitized(personal,monkeypatch,status):
    configure_ai(personal);mock_provider(monkeypatch,{'error':'sk-test-secret-key-not-real-12345'},status)
    response=personal.post('/api/ai/chat',json={'question':'Анализ'})
    assert response.status_code in (422,429,502) and 'sk-test' not in response.text

def test_ai_forbidden_fields_and_dose_changes():
    for answer in [insight(bolus_units=5),insight(summary='Увеличьте дозу инсулина'),insight(summary='Take 2 units insulin')]:
        with pytest.raises(HTTPException):validate_explanation(answer)

def test_disabled_demo_rejects_old_sessions(demo,monkeypatch):
    monkeypatch.setattr(settings,'demo_enabled',False)
    assert demo.get('/api/users/me').status_code==401
    assert demo.post('/api/auth/demo').status_code==404

def test_tokenn_provider_destination_and_consent(personal,monkeypatch):
    r=personal.put('/api/ai/settings',json={'provider':'tokenn','model':'gpt-5.5','api_key':'sk-test-tokenn-not-real-key-12345','consent':False})
    assert r.status_code==200 and r.json()['base_url']=='https://api.tokenn.pro/v1'
    calls=mock_provider(monkeypatch,{'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'{"connected":true}'}]}],'usage':{'input_tokens':10,'output_tokens':5,'total_tokens':15}})
    assert personal.post('/api/ai/test').json()['connected'] is True
    assert str(calls[0].url)=='https://api.tokenn.pro/v1/responses'
    sent=json.loads(calls[0].content)
    assert 'aggregates' not in sent['input'] and 'personal@example.com' not in sent['input']
    assert sent['reasoning']['effort']=='none'
    assert personal.get('/api/ai/settings').json()['last_check']['usage']['total_tokens']==15
    assert personal.post('/api/ai/chat',json={'question':'Анализ'}).status_code==409
    assert personal.put('/api/ai/settings',json={'provider':'openai','model':'gpt-4.1-mini','consent':True}).status_code==422
    assert personal.put('/api/ai/settings',json={'provider':'unknown','model':'gpt-5.5','consent':True}).status_code==422
    assert personal.put('/api/ai/settings',json={'provider':'tokenn','model':'gpt-5.5','consent':True}).status_code==200
    assert personal.get('/api/ai/settings').json()['last_check']['connected'] is True
    calls=mock_provider(monkeypatch,{'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':json.dumps(insight())}]}],'usage':{'input_tokens':10,'output_tokens':20,'total_tokens':30}})
    response=personal.post('/api/ai/chat',json={'question':'Наблюдения?'})
    assert response.status_code==200,response.text
    assert response.json()['provider']=='tokenn'
    assert 'Точная схема JSON' in json.loads(calls[0].content)['input'][0]['content']
    assert personal.put('/api/ai/settings',json={'provider':'tokenn','model':'gpt-5.5-pro','consent':True}).json()['last_check'] is None

@pytest.mark.parametrize('body',[[],None,{'status':'completed','output':None},{'status':'completed','output':[None]},{'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':42}]}]}])
def test_malformed_provider_response_is_safe(personal,monkeypatch,body):
    configure_ai(personal);mock_provider(monkeypatch,body)
    response=personal.post('/api/ai/test')
    assert response.status_code==502
    assert personal.get('/api/ai/settings').json()['last_check'] is None

def test_provider_error_names_and_no_secret_leak(personal,monkeypatch):
    personal.put('/api/ai/settings',json={'provider':'tokenn','model':'gpt-5.5','api_key':'sk-test-not-real-tokenn-key-12345','consent':True})
    mock_provider(monkeypatch,{'error':{'code':'invalid_api_key','message':'sk-test-not-real-tokenn-key-12345'}},401)
    response=personal.post('/api/ai/test')
    assert response.status_code==422 and 'Tokenn' in response.json()['detail']
    assert 'sk-test' not in response.text
