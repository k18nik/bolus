"""YAZIO v15 catalog adapter, based on the user-supplied API description.

Only public product search is used. No user login, diary access or writes.
Nutrients are per base unit (g OR ml), not per displayed serving.
"""
from decimal import Decimal, InvalidOperation
import httpx
from app.config import settings

BASE_URL='https://yzapi.yazio.com/v15'

class YazioError(Exception):
    pass

def nutrient(value, maximum):
    if isinstance(value,bool) or not isinstance(value,(int,float,str)):
        raise ValueError('Missing or invalid nutrient')
    try:number=Decimal(str(value))*100
    except InvalidOperation:raise ValueError('Invalid nutrient')
    if not number.is_finite() or not 0<=number<=maximum:raise ValueError('Invalid nutrient range')
    return float(round(number,4))

def normalize_product(product):
    if not isinstance(product,dict):raise ValueError('Invalid product')
    unit=product.get('base_unit')
    if unit not in ('g','ml'):raise ValueError('Unknown nutrition basis')
    identity=product.get('product_id');name=product.get('name');brand=product.get('producer') or ''
    if not isinstance(identity,str) or not 1<=len(identity)<=100:raise ValueError('Invalid identity')
    if not isinstance(name,str) or not name.strip() or len(name)>150:raise ValueError('Invalid name')
    if not isinstance(brand,str) or len(brand)>100:raise ValueError('Invalid brand')
    nutrients=product.get('nutrients')
    if not isinstance(nutrients,dict):raise ValueError('Missing nutrients')
    values={out:nutrient(nutrients.get(source),1000 if out=='calories' else 100) for out,source in (
        ('carbs','nutrient.carb'),('protein','nutrient.protein'),('fat','nutrient.fat'),('calories','energy.energy'))}
    # Missing fiber/sugar remain unknown; zero carbohydrate is accepted only explicitly.
    for out,source in [('fiber','nutrient.fiber'),('sugar','nutrient.sugar')]:
        values[out]=nutrient(nutrients[source],100) if nutrients.get(source) is not None else None
    serving='100 мл' if unit=='ml' else '100 г'
    return {'external_id':identity,'name':name.strip(),'brand':brand,'provider':'yazio',
            'base_unit':unit,'grams':100 if unit=='g' else None,'serving_weight':100,
            'serving':serving,'serving_name':serving,'is_verified':product.get('is_verified') is True,**values}

class YazioProvider:
    def __init__(self):self.warnings=[]

    async def search(self,query):
        self.warnings=[]
        params={'query':query,'countries':settings.yazio_country,'locales':settings.yazio_locale,
                # Required by the live catalog despite being optional in the supplied Swagger.
                # Fixed API compatibility parameter, never taken from the user's medical profile.
                'sex':settings.yazio_search_sex}
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(12,connect=5),follow_redirects=False) as client:
                response=await client.get(BASE_URL+'/products/search',params=params)
        except httpx.RequestError:raise YazioError('YAZIO временно не отвечает. Повторите поиск позже.')
        if response.status_code in (401,403):raise YazioError('YAZIO ограничил публичный поиск. Сейчас доступны ваши продукты и ручной ввод.')
        if response.status_code==429:raise YazioError('YAZIO ограничил частоту поиска. Повторите немного позже.')
        if response.status_code!=200:raise YazioError('YAZIO временно не выполнил поиск.')
        try:body=response.json()
        except ValueError:raise YazioError('YAZIO вернул некорректный ответ.')
        if not isinstance(body,list):raise YazioError('Формат ответа YAZIO изменился. Сейчас доступны ваши продукты.')
        result=[];seen=set();skipped=0
        for raw in body[:100]:
            try:food=normalize_product(raw)
            except (ValueError,TypeError):skipped+=1;continue
            if food['external_id'] not in seen:result.append(food);seen.add(food['external_id'])
            if len(result)>=30:break
        if skipped:self.warnings.append('Часть продуктов YAZIO пропущена: состав или единицы измерения не указаны корректно.')
        return result

    async def barcode(self,barcode):
        # No barcode endpoint exists in the supplied API description.
        return None
