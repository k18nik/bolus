from typing import Protocol
import httpx
from app.config import settings
from app.food.yazio import YazioProvider,YazioError

class FoodProvider(Protocol):
    async def search(self, query:str) -> list[dict]: ...
    async def barcode(self, barcode:str) -> dict|None: ...

# Seed catalog is explicitly named; it is never presented as a live provider response.
CATALOG=[
 {'external_id':'pasta','name':'Макароны, отварные','brand':'Базовый каталог','carbs':30.9,'protein':5.8,'fat':.9,'calories':158,'fiber':1.8,'sugar':.6},
 {'external_id':'cola','name':'Cola','brand':'Базовый каталог','carbs':10.6,'protein':0,'fat':0,'calories':42,'fiber':0,'sugar':10.6},
 {'external_id':'chicken','name':'Куриная грудка','brand':'Базовый каталог','carbs':0,'protein':31,'fat':3.6,'calories':165,'fiber':0,'sugar':0},
 {'external_id':'oats','name':'Овсяная каша на воде','brand':'Базовый каталог','carbs':12,'protein':2.5,'fat':1.5,'calories':71,'fiber':1.7,'sugar':.3},
 {'external_id':'banana','name':'Банан','brand':'Базовый каталог','carbs':22.8,'protein':1.1,'fat':.3,'calories':89,'fiber':2.6,'sugar':12.2},
 {'external_id':'apple','name':'Яблоко','brand':'Базовый каталог','carbs':13.8,'protein':.3,'fat':.2,'calories':52,'fiber':2.4,'sugar':10.4},
 {'external_id':'bread','name':'Хлеб цельнозерновой','brand':'Базовый каталог','carbs':41,'protein':13,'fat':4.2,'calories':247,'fiber':7,'sugar':6},
 {'external_id':'cottage','name':'Творог 5%','brand':'Базовый каталог','carbs':3,'protein':17,'fat':5,'calories':121,'fiber':0,'sugar':3},
 {'external_id':'egg','name':'Яйцо куриное','brand':'Базовый каталог','carbs':.7,'protein':12.6,'fat':9.5,'calories':143,'fiber':0,'sugar':.4},
 {'external_id':'flour','name':'Мука пшеничная','brand':'Базовый каталог','carbs':76.3,'protein':10.3,'fat':1,'calories':364,'fiber':2.7,'sugar':.3},
 {'external_id':'sugar','name':'Сахар','brand':'Базовый каталог','carbs':100,'protein':0,'fat':0,'calories':400,'fiber':0,'sugar':100},
 {'external_id':'rice','name':'Рис, отварной','brand':'Базовый каталог','carbs':28.2,'protein':2.7,'fat':.3,'calories':130,'fiber':.4,'sugar':0},
 {'external_id':'salad','name':'Овощной салат','brand':'Базовый каталог','carbs':4,'protein':1,'fat':.2,'calories':22,'fiber':1.4,'sugar':2.5}
]
for food in CATALOG: food.update(provider='seed',grams=100,serving='100 г',serving_weight=100)

class USDAProvider:
    async def search(self,query):
        async with httpx.AsyncClient(timeout=8) as client:
            res=await client.get('https://api.nal.usda.gov/fdc/v1/foods/search',params={'api_key':settings.usda_api_key,'query':query,'pageSize':20});res.raise_for_status()
            result=[]
            for food in res.json().get('foods',[]):
                nutrients={n['nutrientId']:n.get('value',0) for n in food.get('foodNutrients',[])}
                result.append({'external_id':str(food['fdcId']),'name':food['description'],'brand':food.get('brandName',''),'provider':'usda','grams':100,'serving_weight':100,'serving':'100 г','carbs':nutrients.get(1005,0),'protein':nutrients.get(1003,0),'fat':nutrients.get(1004,0),'calories':nutrients.get(1008,0),'fiber':nutrients.get(1079,0),'sugar':nutrients.get(2000,0)})
            return result
    async def barcode(self, barcode): return None

async def search_foods(query:str,allow_reference_catalog=False):
    query=query.strip()
    if len(query)<2:return [],[]
    warnings=[]
    providers=[]
    if settings.yazio_enabled:providers.append(YazioProvider())
    if settings.usda_api_key: providers.append(USDAProvider())
    for provider in providers:
        try:
            result=await provider.search(query)
            warnings.extend(getattr(provider,'warnings',[]))
            if result:
                if isinstance(provider,USDAProvider):warnings.append('Показаны результаты резервного каталога USDA.')
                return result,warnings
        except YazioError as exc:warnings.append(str(exc))
        except (httpx.HTTPError,ValueError,KeyError,TypeError):warnings.append('Резервный каталог USDA временно недоступен.')
    if not allow_reference_catalog:return [],warnings or ['Во внешней базе ничего не найдено. Попробуйте другое название или создайте свой продукт.']
    terms={'pasta':'макароны','cola':'cola','oats':'овсяная','rice':'рис'}
    q=terms.get(query.lower(),query.lower())
    return [f for f in CATALOG if q in f['name'].lower() or q in f['brand'].lower()],warnings+['Показан встроенный справочный каталог. Проверяйте состав на упаковке.']
