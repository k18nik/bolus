"""Temporary UI test account; never uses or edits the owner's data."""
import httpx,json
from pathlib import Path
email='yazio-ui-20261003@example.com'
password='yazio-ui-test-only-20261003'
with httpx.Client(base_url='http://localhost:8080',timeout=30) as client:
    response=client.post('/api/auth/register',json={'email':email,'password':password,'name':'Проверка YAZIO'})
    assert response.status_code==201, f'Could not create isolated UI account ({response.status_code})'
    user=response.json()
    client.headers['X-CSRF-Token']=client.cookies['csrf']
    profile={'rapid_insulin_name':'Фиасп','basal_insulin_name':'Тресиба','bolus_increment':1,'basal_increment':1,'max_bolus':15,'insulin_action_duration':4,'confirmed':True,'segments':[{'start_time':'00:00','end_time':'24:00','icr':10,'isf':2,'target':6,'correct_above':7}]}
    assert client.put('/api/profile',json=profile).status_code==200
    for query in ('макароны','Coca Cola'):
        response=client.get('/api/foods/search',params={'q':query})
        assert response.status_code==200
        result=response.json()
        assert any(food['provider']=='yazio' for food in result['foods']), result['warnings']
        print(json.dumps({'query':query,'results':len(result['foods']),'units':sorted({f.get('base_unit','g') for f in result['foods']}),'warnings':result['warnings']},ensure_ascii=False))
    (Path(__file__).parent/'yazio_ui_account.json').write_text(json.dumps({'id':user['id'],'email':email}))
