from datetime import datetime,timezone,timedelta,date
from pathlib import Path
from zoneinfo import ZoneInfo
import hashlib, secrets
from fastapi import APIRouter,Depends,HTTPException,Request,Response,UploadFile,File,BackgroundTasks,Query
from fastapi.responses import FileResponse
from sqlalchemy import select,delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from app.db import get_db
from app.config import settings
from app.models.entities import User,AuthSession,Profile,Entry,Calculation,CustomFood,Cycle,ReportJob,uid,now
from app.schemas.domain import *
from app.services.security import current_user,login_session,rate_limit,hasher,verify_password,DUMMY_HASH
from app.services.demo import seed_demo
from app.repositories.diary import entry_dict,profile_for,audit,period_entries,current_iob,utc
from app.bolus.engine import calculate,select_segment,ALGORITHM_VERSION
from app.analytics.engine import summarize,hourly_profile,daily_breakdown,activity_response
from app.cycle.engine import cycle_status
from app.food.providers import search_foods
from app.imports.apple_health import parse_apple_health
from app.services.insulins import insulin_metadata,is_dose_multiple

router=APIRouter(prefix='/api')

def public_user(user):return {k:getattr(user,k) for k in ('id','name','email','timezone','locale','glucose_unit','theme_id','mascot_id','is_demo')}
def owned(db,model,id,user):
    row=db.get(model,id)
    if not row or row.user_id!=user.id:raise HTTPException(404,'Запись не найдена')
    return row

def check_auth_origin(request):
    origin=request.headers.get('origin')
    if origin and origin!=settings.allowed_origin:raise HTTPException(403,'Недопустимый источник запроса')
    rate_limit('auth:'+(request.client.host if request.client else 'unknown'),12,60)

@router.get('/health')
def health():return {'status':'ok','algorithm_version':ALGORITHM_VERSION}
@router.get('/config')
def config():return {'feature_ai':settings.feature_ai,'feature_personalization':False,'feature_cycle':settings.feature_cycle,'feature_barcode':False,'feature_cgm':False,'clinical_use_enabled':settings.clinical_use_enabled,'demo_enabled':settings.demo_enabled}

@router.post('/auth/register',status_code=201)
def register(payload:AuthInput,request:Request,response:Response,db:Session=Depends(get_db)):
    check_auth_origin(request)
    user=User(email=str(payload.email).lower(),password_hash=hasher.hash(payload.password),name=payload.name)
    db.add(user)
    try:db.commit()
    except IntegrityError:db.rollback();raise HTTPException(409,'Не удалось зарегистрироваться с этим адресом')
    login_session(db,user,response);return public_user(user)
@router.post('/auth/login')
def login(payload:AuthInput,request:Request,response:Response,db:Session=Depends(get_db)):
    check_auth_origin(request);user=db.scalar(select(User).where(User.email==str(payload.email).lower()))
    valid=verify_password(payload.password,user.password_hash if user else DUMMY_HASH)
    if not user or not valid:raise HTTPException(401,'Проверьте email и пароль')
    login_session(db,user,response);return public_user(user)
@router.post('/auth/demo')
def demo(request:Request,response:Response,db:Session=Depends(get_db)):
    if not settings.demo_enabled:raise HTTPException(404)
    check_auth_origin(request);user=seed_demo(db);login_session(db,user,response);return public_user(user)
@router.post('/auth/logout')
def logout(request:Request,response:Response,user=Depends(current_user),db:Session=Depends(get_db)):
    token=request.cookies.get('session','');db.execute(delete(AuthSession).where(AuthSession.id==hashlib.sha256(token.encode()).hexdigest()));db.commit();response.delete_cookie('session');response.delete_cookie('csrf');return {'ok':True}
@router.get('/users/me')
def me(user=Depends(current_user)):return public_user(user)
@router.patch('/users/me')
def preferences(payload:Preferences,user=Depends(current_user),db:Session=Depends(get_db)):
    for k,v in payload.model_dump().items():setattr(user,k,v)
    user.updated_at=now();db.commit();return public_user(user)
@router.delete('/users/me')
def delete_account(user=Depends(current_user),db:Session=Depends(get_db)):
    for job in db.scalars(select(ReportJob).where(ReportJob.user_id==user.id)):
        if job.file_path:Path(job.file_path).unlink(missing_ok=True)
    db.delete(user);db.commit();return {'deleted':True}

@router.get('/profile')
def get_profile(user=Depends(current_user),db:Session=Depends(get_db)):
    p=profile_for(db,user.id);return {'id':p.id,'version':p.version,**p.data} if p else None
@router.get('/profile/history')
def profile_history(user=Depends(current_user),db:Session=Depends(get_db)):
    return [{'id':p.id,'version':p.version,'valid_from':p.valid_from,'valid_to':p.valid_to,'source':p.source,'status':p.status,'data':p.data} for p in db.scalars(select(Profile).where(Profile.user_id==user.id).order_by(Profile.version.desc()))]
@router.put('/profile')
def save_profile(payload:ProfileInput,user=Depends(current_user),db:Session=Depends(get_db)):
    if not payload.confirmed:raise HTTPException(422,'Подтвердите параметры профиля')
    # Serialize profile versions per user on PostgreSQL.
    db.scalar(select(User).where(User.id==user.id).with_for_update())
    old=profile_for(db,user.id);version=old.version+1 if old else 1
    if old:old.status='archived';old.valid_to=now()
    p=Profile(user_id=user.id,version=version,data=payload.model_dump());db.add(p);db.flush();audit(db,user.id,'therapy_profile_change','profile',p.id,old.data if old else None,p.data);db.commit();return {'id':p.id,'version':version,**p.data}

def save_entry(db,user,kind,occurred,data,client_id):
    existing=db.scalar(select(Entry).where(Entry.user_id==user.id,Entry.client_id==client_id))
    if existing:return entry_dict(existing)
    if occurred>datetime.now(timezone.utc)+timedelta(minutes=5):raise HTTPException(422,'Время записи находится в будущем')
    row=Entry(user_id=user.id,kind=kind,occurred_at=utc(occurred),data=data,client_id=client_id);db.add(row)
    try:
        db.flush();audit(db,user.id,'entry_create',kind,row.id,new=data);db.commit()
    except IntegrityError:
        db.rollback();existing=db.scalar(select(Entry).where(Entry.user_id==user.id,Entry.client_id==client_id))
        if existing:return entry_dict(existing)
        raise
    return entry_dict(row)

@router.post('/glucose',status_code=201)
def add_glucose(payload:GlucoseInput,user=Depends(current_user),db:Session=Depends(get_db)):
    data=payload.model_dump(mode='json',exclude={'client_id','measured_at'});data['value_mmol']=payload.value/(18 if payload.unit=='mg/dL' else 1)
    return save_entry(db,user,'glucose',payload.measured_at,data,payload.client_id)
@router.post('/insulin',status_code=201)
def add_insulin(payload:InsulinInput,user=Depends(current_user),db:Session=Depends(get_db)):
    data=prepare_insulin(db,user,payload)
    return save_entry(db,user,'insulin',payload.administered_at,data,payload.client_id)

def prepare_insulin(db,user,payload):
    profile=db.scalar(select(Profile).where(Profile.user_id==user.id,Profile.valid_from<=utc(payload.administered_at)).order_by(Profile.version.desc())) or profile_for(db,user.id)
    if payload.insulin_type=='rapid' and not profile:raise HTTPException(422,'Настройте DIA в профиле перед записью быстрого инсулина')
    data=payload.model_dump(mode='json',exclude={'client_id','administered_at'})
    if not data['insulin_name'] and profile:data['insulin_name']=profile.data.get('rapid_insulin_name' if payload.insulin_type=='rapid' else 'basal_insulin_name','')
    try:data.update(insulin_metadata(data['insulin_name'],payload.insulin_type))
    except ValueError as e:raise HTTPException(422,str(e))
    step=profile.data.get('bolus_increment' if payload.insulin_type=='rapid' else 'basal_increment',0.1) if profile else 0.1
    if not is_dose_multiple(payload.units,step):raise HTTPException(422,f'Доза должна быть кратна шагу устройства {step:g} ЕД')
    data['dose_increment']=step
    data['dia']=profile.data['insulin_action_duration'] if profile and payload.insulin_type=='rapid' else None
    data['action_model']='linear-remaining-v1.0.0' if payload.insulin_type=='rapid' else 'basal-excluded'
    return data
@router.post('/meals',status_code=201)
def add_meal(payload:MealInput,user=Depends(current_user),db:Session=Depends(get_db)):
    data=payload.model_dump(mode='json',exclude={'client_id','eaten_at'})
    for nutrient in ('carbs','protein','fat','calories'):data['total_'+nutrient]=round(sum(getattr(i,nutrient) for i in payload.items),4)
    return save_entry(db,user,'meal',payload.eaten_at,data,payload.client_id)
@router.post('/activity',status_code=201)
def add_activity(payload:ActivityInput,user=Depends(current_user),db:Session=Depends(get_db)):
    data=payload.model_dump(mode='json',exclude={'client_id','occurred_at'});data['source']='manual'
    return save_entry(db,user,'activity',payload.occurred_at,data,payload.client_id)
@router.post('/notes',status_code=201)
def add_note(payload:NoteInput,user=Depends(current_user),db:Session=Depends(get_db)):
    return save_entry(db,user,'note',payload.occurred_at,{'note':payload.note},payload.client_id)
@router.get('/diary')
def diary(date_from:date|None=None,date_to:date|None=None,kind:str|None=None,user=Depends(current_user),db:Session=Depends(get_db)):
    today=datetime.now(ZoneInfo(user.timezone)).date();df=date_from or today;dt=date_to or today
    if dt<df or (dt-df).days>366:raise HTTPException(422,'Период должен быть от 1 до 367 дней')
    rows=period_entries(db,user.id,df,dt,user.timezone);return sorted([e for e in rows if not kind or e['kind']==kind],key=lambda e:e['occurred_at'],reverse=True)
@router.delete('/diary/{entry_id}')
def remove_entry(entry_id:str,version:int=Query(ge=1),user=Depends(current_user),db:Session=Depends(get_db)):
    entry=owned(db,Entry,entry_id,user)
    if entry.version!=version:raise HTTPException(409,'Запись изменилась. Обновите дневник.')
    audit(db,user.id,'entry_delete',entry.kind,entry.id,old=entry.data)
    calc=db.scalar(select(Calculation).where(Calculation.user_id==user.id,Calculation.confirmed_entry_id==entry.id))
    if calc:
        # Preserve immutable historical calculation and actual confirmation; deletion is audited.
        audit(db,user.id,'confirmed_insulin_entry_delete','calculation',calc.id,old={'entry_id':entry.id})
    db.delete(entry);db.commit();return {'deleted':True}

@router.get('/iob')
def iob(user=Depends(current_user),db:Session=Depends(get_db)):
    at=datetime.now(timezone.utc);return {'iob':round(current_iob(db,user.id,at),3),'at':utc(at),'model':'linear-remaining-v1.0.0','experimental':True}
@router.post('/bolus/calculate')
def bolus(payload:BolusInput,user=Depends(current_user),db:Session=Depends(get_db)):
    if not user.is_demo and not settings.clinical_use_enabled:raise HTTPException(403,'Расчёт отключён в настройках этой установки.')
    profile=profile_for(db,user.id)
    if not profile or not profile.data.get('confirmed'):raise HTTPException(422,'Сначала подтвердите терапевтический профиль')
    at=datetime.now(timezone.utc)
    if abs((at-payload.timestamp).total_seconds())>60:raise HTTPException(422,'Обновите время расчёта')
    carbs=payload.carbs
    if payload.meal_id:
        meal=owned(db,Entry,payload.meal_id,user)
        if meal.kind!='meal':raise HTTPException(422,'Некорректный приём пищи')
        carbs=meal.data['total_carbs']
    segment=select_segment(profile.data['segments'],at.astimezone(ZoneInfo(user.timezone)).strftime('%H:%M'))
    inputs={'glucose':payload.glucose/(18 if payload.unit=='mg/dL' else 1) if payload.glucose is not None else None,'unit':'mmol/L','original_unit':payload.unit,'original_glucose':payload.glucose,'carbs':carbs,**segment,'dia':profile.data['insulin_action_duration'],'max_bolus':profile.data['max_bolus'],'iob':current_iob(db,user.id,at),'measured_at':payload.measured_at.isoformat(),'calculated_at':at.isoformat(),'timezone':user.timezone,'profile_id':profile.id,'profile_version':profile.version,'meal_id':payload.meal_id,'iob_model':'linear-remaining-v1.0.0'}
    inputs.update(bolus_increment=profile.data.get('bolus_increment',0.1),rapid_insulin_name=profile.data.get('rapid_insulin_name',''),basal_insulin_name=profile.data.get('basal_insulin_name',''),**insulin_metadata(profile.data.get('rapid_insulin_name',''),'rapid'))
    result=calculate(inputs,at);row=Calculation(user_id=user.id,calculated_at=utc(at),input_snapshot=inputs,calculation_snapshot=result,algorithm_version=ALGORITHM_VERSION)
    db.add(row);db.flush();audit(db,user.id,'bolus_calculation','calculation',row.id,new={'algorithm_version':ALGORITHM_VERSION,'status':result['calculation_status']});db.commit()
    return {'calculation_id':row.id,**result,'profile_version':profile.version,'insulin_name':inputs['rapid_insulin_name'],'demo':user.is_demo}
@router.get('/bolus/history')
def bolus_history(user=Depends(current_user),db:Session=Depends(get_db)):
    return [{'id':c.id,'calculated_at':c.calculated_at,'actual_bolus':c.actual_bolus,'algorithm_version':c.algorithm_version,'input_snapshot':c.input_snapshot,'calculation_snapshot':c.calculation_snapshot} for c in db.scalars(select(Calculation).where(Calculation.user_id==user.id).order_by(Calculation.calculated_at.desc()).limit(100))]
@router.post('/bolus/{calculation_id}/confirm')
def confirm_bolus(calculation_id:str,payload:ConfirmInput,user=Depends(current_user),db:Session=Depends(get_db)):
    row=db.scalar(select(Calculation).where(Calculation.id==calculation_id,Calculation.user_id==user.id).with_for_update())
    if not row:raise HTTPException(404,'Расчёт не найден')
    if row.actual_bolus is not None:return {'entry_id':row.confirmed_entry_id,'actual_units':row.actual_bolus,'already_confirmed':True}
    if row.calculation_snapshot['calculation_status']!='ok':raise HTTPException(409,'Расчёт заблокирован')
    at=datetime.now(timezone.utc);calculated=datetime.fromisoformat(row.calculated_at)
    if (at-calculated).total_seconds()>900:raise HTTPException(409,'Расчёт устарел. Выполните новый расчёт.')
    if payload.administered_at<calculated-timedelta(minutes=1) or payload.administered_at>at+timedelta(minutes=1):raise HTTPException(422,'Проверьте время введения')
    if payload.actual_units>row.input_snapshot['max_bolus']:raise HTTPException(422,'Превышен максимальный болюс. Для исторического факта используйте ручную запись.')
    step=row.input_snapshot.get('bolus_increment',0.1)
    if not is_dose_multiple(payload.actual_units,step):raise HTTPException(422,f'Доза должна быть кратна шагу устройства {step:g} ЕД')
    profile=db.get(Profile,row.input_snapshot['profile_id'])
    data={'units':payload.actual_units,'insulin_type':'rapid','insulin_name':profile.data['rapid_insulin_name'],'purpose':'meal_and_correction' if row.input_snapshot['carbs'] else 'correction','dia':row.input_snapshot['dia'],'action_model':row.input_snapshot['iob_model'],'related_bolus_calculation_id':row.id,'related_meal_id':row.input_snapshot.get('meal_id'),'note':''}
    data.update(dose_increment=step,**insulin_metadata(data['insulin_name'],'rapid'))
    entry=Entry(user_id=user.id,kind='insulin',client_id='bolus-'+row.id,occurred_at=utc(payload.administered_at),data=data);db.add(entry)
    try:db.flush()
    except IntegrityError:
        db.rollback();existing=db.scalar(select(Entry).where(Entry.user_id==user.id,Entry.client_id=='bolus-'+row.id));return {'entry_id':existing.id,'actual_units':existing.data['units'],'already_confirmed':True}
    row.actual_bolus=payload.actual_units;row.confirmed_entry_id=entry.id;audit(db,user.id,'bolus_confirmation','calculation',row.id,new=data);db.commit();return {'entry_id':entry.id,'actual_units':payload.actual_units}

@router.get('/foods/search')
async def foods(q:str=Query(default='',max_length=150),user=Depends(current_user),db:Session=Depends(get_db)):
    q=q.strip()
    rate_limit('food-search:'+user.id,60,60)
    result,warnings=await search_foods(q,allow_reference_catalog=user.is_demo)
    custom=[{'external_id':f.id,'provider':'custom','grams':f.data.get('serving_weight',100),'serving':f.data.get('serving_name','100 г'),**f.data} for f in db.scalars(select(CustomFood).where(CustomFood.user_id==user.id)) if q.lower() in f.name.lower()]
    return {'foods':custom+result,'warnings':warnings}
@router.post('/foods/custom',status_code=201)
def custom_food(payload:FoodInput,user=Depends(current_user),db:Session=Depends(get_db)):
    food=CustomFood(user_id=user.id,name=payload.name,data=payload.model_dump());db.add(food);db.commit();return {'id':food.id,**food.data}
@router.get('/foods/barcode/{barcode}')
def barcode(barcode:str,user=Depends(current_user)):raise HTTPException(501,'Сканирование штрихкодов запланировано для версии 1.1')
@router.post('/recipes',status_code=201)
def recipe(payload:RecipeInput,user=Depends(current_user),db:Session=Depends(get_db)):
    total={n:sum(getattr(i,n) for i in payload.ingredients) if all(getattr(i,n) is not None for i in payload.ingredients) else None for n in ('carbs','protein','fat','calories','fiber','sugar')}
    data={'name':payload.name,'brand':'Мои блюда','base_unit':'g','serving_name':'100 г','serving_weight':100,**{n:round(v/payload.cooked_weight*100,4) if v is not None else None for n,v in total.items()},'recipe':payload.model_dump(),'total':total,'per_serving':{n:round(v/payload.servings,4) if v is not None else None for n,v in total.items()}}
    f=CustomFood(user_id=user.id,name=payload.name,data=data,is_recipe=True);db.add(f);db.commit();return {'id':f.id,**data}
@router.get('/recipes')
def recipes(user=Depends(current_user),db:Session=Depends(get_db)):return [{'id':f.id,**f.data} for f in db.scalars(select(CustomFood).where(CustomFood.user_id==user.id,CustomFood.is_recipe==True))]

@router.get('/cycle')
def get_cycle(user=Depends(current_user),db:Session=Depends(get_db)):
    cycles=list(db.scalars(select(Cycle).where(Cycle.user_id==user.id).order_by(Cycle.start_date.desc())))
    if not cycles:return {'current':None,'history':[]}
    c=cycles[0];today=datetime.now(ZoneInfo(user.timezone)).date()
    return {'current':{'id':c.id,'start_date':c.start_date,**cycle_status(date.fromisoformat(c.start_date),c.cycle_length,today,date.fromisoformat(c.actual_ovulation_date) if c.actual_ovulation_date else None)},'history':[{'id':c.id,'start_date':c.start_date,'end_date':c.end_date,'cycle_length':c.cycle_length} for c in cycles]}
@router.post('/cycle',status_code=201)
def add_cycle(payload:CycleInput,user=Depends(current_user),db:Session=Depends(get_db)):
    if not settings.feature_cycle:raise HTTPException(404)
    if payload.start_date>datetime.now(ZoneInfo(user.timezone)).date():raise HTTPException(422,'Начало цикла не может быть в будущем')
    c=Cycle(user_id=user.id,**payload.model_dump(mode='json'));db.add(c);db.commit();return {'id':c.id,**payload.model_dump(mode='json')}

@router.get('/analytics')
def analytics(days:int=Query(default=7,ge=1,le=366),hours:int|None=Query(default=None,ge=1,le=24),date_from:date|None=None,date_to:date|None=None,user=Depends(current_user),db:Session=Depends(get_db)):
    dt=date_to or datetime.now(ZoneInfo(user.timezone)).date();df=date_from or dt-timedelta(days=days-1)
    if dt<df or (dt-df).days>366:raise HTTPException(422,'Некорректный период')
    rows=period_entries(db,user.id,df,dt,user.timezone)
    if hours:rows=[e for e in rows if datetime.fromisoformat(e['occurred_at'])>=datetime.now(timezone.utc)-timedelta(hours=hours)]
    metrics=summarize(rows,1 if hours else (dt-df).days+1,user.timezone)
    daily=daily_breakdown(rows,df,dt,user.timezone)
    return {'period':{'from':str(df),'to':str(dt)},'metrics':metrics,'daily':daily,'hourly':hourly_profile(rows,user.timezone),'activity_response':activity_response(rows),'activity_minutes':sum(e['data']['duration_minutes'] for e in rows if e['kind']=='activity'),'patterns':[],'entries':rows}

@router.post('/imports/apple-health')
async def apple_import(file:UploadFile=File(...),user=Depends(current_user),db:Session=Depends(get_db)):
    content=await file.read(20*1024*1024+1)
    try:rows=parse_apple_health(content)
    except Exception as exc:
        if isinstance(exc,HTTPException):raise
        raise HTTPException(422,str(exc) if isinstance(exc,ValueError) else 'Не удалось прочитать файл Apple Health')
    inserted=0;skipped=0
    for r in rows:
        if db.scalar(select(Entry.id).where(Entry.user_id==user.id,Entry.client_id==r['client_id'])):skipped+=1;continue
        if 'local_date' in r:r['occurred_at']=utc(datetime.combine(date.fromisoformat(r.pop('local_date')),datetime.min.time(),ZoneInfo(user.timezone)))
        if datetime.fromisoformat(r['occurred_at'])>datetime.now(timezone.utc)+timedelta(minutes=5):skipped+=1;continue
        db.add(Entry(user_id=user.id,**r));inserted+=1
    audit(db,user.id,'apple_health_import','import',uid(),new={'inserted':inserted,'skipped':skipped});db.commit()
    return {'inserted':inserted,'skipped':skipped,'source':'apple_health','message':'Тренировки учтены в дневнике и аналитике. Доза инсулина не изменена.'}

@router.post('/reports',status_code=202)
def report_create(payload:ReportInput,background:BackgroundTasks,user=Depends(current_user),db:Session=Depends(get_db)):
    rate_limit('report:'+user.id,10,3600)
    if payload.include_ai:raise HTTPException(422,'AI-резюме пока недоступно')
    job=ReportJob(user_id=user.id,type=payload.type,format=payload.format,date_from=str(payload.date_from),date_to=str(payload.date_to),options=payload.model_dump(mode='json'))
    db.add(job);db.commit()
    from app.reports.tasks import build_report
    if settings.task_always_eager:background.add_task(build_report.delay,job.id)
    else:
        try:build_report.delay(job.id)
        except Exception:job.status='failed';job.error='Очередь отчётов временно недоступна';db.commit();raise HTTPException(503,job.error)
    return {'id':job.id,'status':job.status}
@router.get('/reports')
def reports(user=Depends(current_user),db:Session=Depends(get_db)):
    return [{k:getattr(j,k) for k in ('id','type','format','date_from','date_to','status','progress','created_at','completed_at','expires_at','error')} for j in db.scalars(select(ReportJob).where(ReportJob.user_id==user.id).order_by(ReportJob.created_at.desc()))]
@router.get('/reports/{job_id}/download')
def report_download(job_id:str,user=Depends(current_user),db:Session=Depends(get_db)):
    j=owned(db,ReportJob,job_id,user)
    if j.status!='completed' or not j.file_path:raise HTTPException(409,'Отчёт ещё не готов')
    if j.expires_at and datetime.fromisoformat(j.expires_at)<datetime.now(timezone.utc):raise HTTPException(410,'Срок хранения отчёта истёк')
    if not Path(j.file_path).exists():raise HTTPException(410,'Файл больше недоступен')
    return FileResponse(j.file_path,filename=f'bolus-{j.type}-{j.date_from}.{Path(j.file_path).suffix[1:]}',headers={'Cache-Control':'no-store'})
@router.delete('/reports/{job_id}')
def report_delete(job_id:str,user=Depends(current_user),db:Session=Depends(get_db)):
    j=owned(db,ReportJob,job_id,user)
    if j.file_path:Path(j.file_path).unlink(missing_ok=True)
    db.delete(j);db.commit();return {'deleted':True}
@router.get('/export/{dataset}')
def dataset_export(dataset:Literal['glucose','insulin','meals','bolus','cycle'],days:int=Query(default=30,ge=1,le=366),user=Depends(current_user),db:Session=Depends(get_db)):
    from app.reports.generator import tables_for,csv_bytes
    today=datetime.now(ZoneInfo(user.timezone)).date();rows=period_entries(db,user.id,today-timedelta(days=days-1),today,user.timezone)
    calcs=list(db.scalars(select(Calculation).where(Calculation.user_id==user.id)))
    calcs=[c for c in calcs if today-timedelta(days=days-1)<=datetime.fromisoformat(c.calculated_at).astimezone(ZoneInfo(user.timezone)).date()<=today]
    cycles=list(db.scalars(select(Cycle).where(Cycle.user_id==user.id)))
    tables=tables_for(rows,[],calcs,cycles,[],user.timezone,user.glucose_unit)
    return Response(csv_bytes(tables[{'glucose':'Glucose','insulin':'Insulin','meals':'Meals','bolus':'Bolus Calculations','cycle':'Cycle'}[dataset]]),media_type='text/csv; charset=utf-8',headers={'Content-Disposition':f'attachment; filename="{dataset}.csv"','Cache-Control':'no-store'})
@router.get('/personalization')
def personalization(user=Depends(current_user)):return {'enabled':False,'candidates':[],'message':'Персонализация появится после проверки извлечения эпизодов. Параметры не меняются автоматически.'}
@router.get('/themes')
def themes():return [{'id':k,'name':v} for k,v in [('light','Minimal Light'),('dark','Minimal Dark'),('cat','Cat Café'),('pink','Pink Pastel'),('dino','Dino'),('oled','OLED Black')]]
@router.get('/mascots')
def mascots():return ['cat','pig','dinosaur','rabbit','otter','panda']

@router.get('/foods/favorites')
def favorite_foods(user=Depends(current_user),db:Session=Depends(get_db)):
    from app.models.entities import FoodFavorite
    return [{'favorite_id':f.id,**f.data} for f in db.scalars(select(FoodFavorite).where(FoodFavorite.user_id==user.id))]
@router.post('/foods/favorites',status_code=201)
def favorite_food(payload:FavoriteInput,user=Depends(current_user),db:Session=Depends(get_db)):
    from app.models.entities import FoodFavorite
    key=payload.provider+':'+payload.external_id
    f=db.scalar(select(FoodFavorite).where(FoodFavorite.user_id==user.id,FoodFavorite.food_key==key))
    if not f:f=FoodFavorite(user_id=user.id,food_key=key,data=payload.model_dump());db.add(f);db.commit()
    return {'favorite_id':f.id,**f.data}
@router.delete('/foods/favorites/{favorite_id}')
def remove_favorite(favorite_id:str,user=Depends(current_user),db:Session=Depends(get_db)):
    from app.models.entities import FoodFavorite
    f=owned(db,FoodFavorite,favorite_id,user);db.delete(f);db.commit();return {'deleted':True}
@router.get('/foods/recent')
def recent_foods(user=Depends(current_user),db:Session=Depends(get_db)):
    seen=set();result=[]
    for e in db.scalars(select(Entry).where(Entry.user_id==user.id,Entry.kind=='meal').order_by(Entry.occurred_at.desc()).limit(30)):
        for item in e.data.get('items',[]):
            key=(item.get('food_source',''),item.get('food_id',''),item['name_snapshot'])
            if key in seen:continue
            seen.add(key);unit='ml' if item.get('unit')=='ml' else 'g'
            quantity=item.get('amount') if unit=='ml' else item.get('grams',100)
            if not quantity:continue
            result.append({'external_id':item.get('food_id') or e.id,'provider':item.get('food_source','snapshot'),'name':item['name_snapshot'],'brand':'Недавно в дневнике','base_unit':unit,'serving_weight':100,'serving_name':'100 мл' if unit=='ml' else '100 г',**{k:round(item.get(k,0)/quantity*100,4) if item.get(k,0) is not None else None for k in ('carbs','protein','fat','calories','fiber','sugar')}})
    return result[:20]

@router.get('/glucose/latest')
def latest_glucose(user=Depends(current_user),db:Session=Depends(get_db)):
    row=db.scalar(select(Entry).where(Entry.user_id==user.id,Entry.kind=='glucose').order_by(Entry.occurred_at.desc(),Entry.created_at.desc(),Entry.id.desc()))
    return entry_dict(row) if row else None
