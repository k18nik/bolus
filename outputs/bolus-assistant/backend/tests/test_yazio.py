import asyncio
from datetime import datetime,timezone
import httpx,pytest
from app.config import settings
from app.food.yazio import YazioProvider,YazioError,normalize_product
from app.food.providers import search_foods

ORIGINAL_CLIENT=httpx.AsyncClient

def product(unit='g',**changes):
    return {'product_id':'catalog-1','name':'Макароны' if unit=='g' else 'Кола','producer':None,
            'base_unit':unit,'serving':'cup','amount':140,'serving_quantity':1,'is_verified':True,
            'nutrients':{'energy.energy':1.58,'nutrient.carb':.3086,'nutrient.protein':.058,'nutrient.fat':.0093},**changes}

def mock_http(monkeypatch,handler):
    monkeypatch.setattr(httpx,'AsyncClient',lambda **kwargs:ORIGINAL_CLIENT(transport=httpx.MockTransport(handler),**kwargs))

@pytest.fixture
def catalog_user(client,monkeypatch):
    monkeypatch.setattr(settings,'yazio_enabled',True)
    assert client.post('/api/auth/register',json={'email':'catalog@example.com','password':'catalog-test-password'}).status_code==201
    client.headers['x-csrf-token']=client.cookies['csrf']
    return client

def test_per_unit_not_per_serving_and_no_unknown_zero():
    food=normalize_product(product())
    assert food['carbs']==30.86 and food['calories']==158 and food['protein']==5.8
    assert food['serving_weight']==100 and food['base_unit']=='g'
    assert food['fiber'] is None and food['sugar'] is None
    assert normalize_product(product(amount=9000))==food
    nutrients=product()['nutrients'];nutrients['nutrient.carb']=0
    assert normalize_product(product(nutrients=nutrients))['carbs']==0

@pytest.mark.parametrize('value',[None,True,'NaN',float('inf'),-.2,'bad',2])
def test_bad_carbs_not_turned_into_zero(value):
    raw=product();raw['nutrients']['nutrient.carb']=value
    with pytest.raises(ValueError):normalize_product(raw)

@pytest.mark.parametrize('change',[{'base_unit':'oz'},{'nutrients':{}},{'name':''},{'product_id':None}])
def test_incomplete_or_unknown_basis_rejected(change):
    with pytest.raises(ValueError):normalize_product(product(**change))

def test_public_search_contract_and_invalid_product_isolation(catalog_user,monkeypatch):
    requests=[]
    def handle(request):
        requests.append(request)
        return httpx.Response(200,json=[product(),product(),product(product_id='bad',nutrients={})])
    mock_http(monkeypatch,handle)
    response=catalog_user.get('/api/foods/search',params={'q':'Макароны'})
    assert response.status_code==200 and len(response.json()['foods'])==1
    assert response.json()['warnings'] and response.json()['foods'][0]['provider']=='yazio'
    req=requests[0]
    assert req.url.host=='yzapi.yazio.com' and req.url.path=='/v15/products/search'
    assert dict(req.url.params)=={'query':'Макароны','countries':'RU','locales':'ru_RU','sex':'male'}
    assert req.method=='GET' and 'authorization' not in req.headers and 'cookie' not in req.headers
    assert req.content==b''

def test_short_search_never_calls_provider(catalog_user,monkeypatch):
    def unexpected(request):raise AssertionError('Unexpected network call')
    mock_http(monkeypatch,unexpected)
    for query in ('',' ','м'):
        assert catalog_user.get('/api/foods/search',params={'q':query}).json()=={'foods':[],'warnings':[]}

@pytest.mark.parametrize('status',[301,400,401,403,429,500])
def test_failed_provider_is_visible_and_preserves_custom(catalog_user,monkeypatch,status):
    mock_http(monkeypatch,lambda request:httpx.Response(status,json={'error':'private-debug-text'},headers={'location':'https://untrusted.invalid'}))
    assert catalog_user.post('/api/foods/custom',json={'name':'Макароны свои','carbs':30}).status_code==201
    response=catalog_user.get('/api/foods/search',params={'q':'Макароны'})
    data=response.json()
    assert len(data['foods'])==1 and data['foods'][0]['provider']=='custom'
    assert data['warnings'] and 'private-debug-text' not in response.text

def test_timeout_and_changed_format(monkeypatch):
    def timeout(request):raise httpx.ReadTimeout('private-debug-text')
    mock_http(monkeypatch,timeout)
    with pytest.raises(YazioError,match='временно'):asyncio.run(YazioProvider().search('food'))
    mock_http(monkeypatch,lambda request:httpx.Response(200,json={'items':[]}))
    with pytest.raises(YazioError,match='Формат'):asyncio.run(YazioProvider().search('food'))

def test_explicit_usda_fallback(monkeypatch):
    monkeypatch.setattr(settings,'yazio_enabled',True);monkeypatch.setattr(settings,'usda_api_key','test-usda')
    requests=[]
    def handle(req):
        requests.append(req.url.host)
        if req.url.host=='yzapi.yazio.com':return httpx.Response(503)
        return httpx.Response(200,json={'foods':[{'fdcId':1,'description':'Rice','foodNutrients':[{'nutrientId':1005,'value':28}]}]})
    mock_http(monkeypatch,handle)
    foods,warnings=asyncio.run(search_foods('rice'))
    assert requests==['yzapi.yazio.com','api.nal.usda.gov']
    assert foods[0]['provider']=='usda' and any('USDA' in w for w in warnings)

def test_liquid_snapshot_favorites_recents_recipe_and_old_history(catalog_user,monkeypatch):
    raw=product('ml');raw['nutrients']={'energy.energy':.41,'nutrient.carb':.1058,'nutrient.protein':0,'nutrient.fat':0}
    mock_http(monkeypatch,lambda request:httpx.Response(200,json=[raw]))
    food=catalog_user.get('/api/foods/search',params={'q':'Кола'}).json()['foods'][0]
    assert food['base_unit']=='ml' and food['grams'] is None and food['carbs']==10.58
    favorite={k:food[k] for k in ('external_id','provider','name','brand','serving_name','serving_weight','base_unit','carbs','protein','fat','calories','fiber','sugar')}
    assert catalog_user.post('/api/foods/favorites',json=favorite).status_code==201
    assert catalog_user.get('/api/foods/favorites').json()[0]['base_unit']=='ml'
    item={'name_snapshot':food['name'],'food_source':'yazio','food_id':food['external_id'],'grams':None,'amount':250,'unit':'ml',**{k:None if food[k] is None else food[k]*2.5 for k in ('carbs','protein','fat','calories','fiber','sugar')}}
    at=datetime.now(timezone.utc).isoformat()
    response=catalog_user.post('/api/meals',json={'name':'Напиток','eaten_at':at,'items':[item],'client_id':'cola'})
    assert response.status_code==201,response.text
    saved=response.json()
    assert saved['data']['total_carbs']==26.45 and saved['data']['items'][0]['grams'] is None
    recent=catalog_user.get('/api/foods/recent').json()[0]
    assert recent['base_unit']=='ml' and recent['carbs']==10.58 and recent['fiber'] is None
    recipe=catalog_user.post('/api/recipes',json={'name':'Напиток в рецепте','ingredients':[item],'cooked_weight':300,'servings':2})
    assert recipe.status_code==201,recipe.text
    assert recipe.json()['carbs']==8.8167 and recipe.json()['fiber'] is None
    raw['nutrients']['nutrient.carb']=.9
    catalog_user.get('/api/foods/search',params={'q':'Кола'})
    entry=next(e for e in catalog_user.get('/api/diary').json() if e['id']==saved['id'])
    assert entry['data']['total_carbs']==26.45
    invalid={**item,'unit':'g'}
    assert catalog_user.post('/api/meals',json={'eaten_at':at,'items':[invalid],'client_id':'bad'}).status_code==422
