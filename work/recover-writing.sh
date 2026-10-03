cat > outputs/bolus-assistant/backend/app/reports/generator.py <<'EOF'
import csv, io, json, os, zipfile
from pathlib import Path
from datetime import datetime,timezone,timedelta,date
from zoneinfo import ZoneInfo
from xml.sax.saxutils import escape
from sqlalchemy import select
from app.config import settings
from app.db import SessionLocal
from app.models.entities import User,Entry,Profile,Calculation,Cycle,CustomFood,ReportJob,AuditLog,now
from app.repositories.diary import period_entries,entry_dict
from app.analytics.engine import summarize,hourly_profile

SHEETS={'Glucose':'glucose','Insulin':'insulin','Meals':'meal','Activities':'activity','Activity Summaries':'activity_summary'}
def safe_cell(value):
    if isinstance(value,(dict,list)): value=json.dumps(value,ensure_ascii=False)
    if isinstance(value,str) and value.startswith(('=','+','-','@','\t','\r')): return "'"+value
    return value

def tables_for(entries,profiles,calculations,cycles,foods,tz,unit):
    tables={}
    for name,kind in SHEETS.items():
        records=[]
        for e in entries:
            if e['kind']!=kind: continue
            data=dict(e['data']);data.pop('items',None)
            if kind=='glucose':
                data['value']=round(data['value_mmol']*(18 if unit=='mg/dL' else 1),2);data['unit']=unit
            records.append({'id':e['id'],'timestamp':datetime.fromisoformat(e['occurred_at']).astimezone(ZoneInfo(tz)).isoformat(),**data})
        tables[name]=records
    tables['Meal Items']=[{'meal_id':e['id'],**i} for e in entries if e['kind']=='meal' for i in e['data'].get('items',[])]
    tables['Cycle']=[{'id':c.id,'start_date':c.start_date,'end_date':c.end_date,'cycle_length':c.cycle_length} for c in cycles]
    tables['Bolus Calculations']=[{'id':c.id,'calculated_at':c.calculated_at,'algorithm_version':c.algorithm_version,'actual_bolus':c.actual_bolus,'input_snapshot':c.input_snapshot,'calculation_snapshot':c.calculation_snapshot} for c in calculations]
    tables['Therapy Profiles']=[{'id':p.id,'version':p.version,'valid_from':p.valid_from,'valid_to':p.valid_to,'source':p.source,'data':p.data} for p in profiles]
    tables['Foods']=[{'id':f.id,'name':f.name,'is_recipe':f.is_recipe,'data':f.data} for f in foods]
    tables['Notes']=[{'id':e['id'],'timestamp':e['occurred_at'],**e['data']} for e in entries if e['kind']=='note']
    tables['Patterns']=[]
    return tables

def columns(rows): return list(dict.fromkeys(k for row in rows for k in row)) or ['No data']
def csv_bytes(rows):
    out=io.StringIO(); writer=csv.DictWriter(out,fieldnames=columns(rows));writer.writeheader()
    for row in rows: writer.writerow({k:safe_cell(v) for k,v in row.items()})
    return out.getvalue().encode('utf-8-sig')

def create_pdf(path,user,job,metrics,entries,profiles):
    from reportlab.pdfgen import canvas
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    font_path=Path(__file__).parent/'DejaVuSans.ttf'
    if font_path.exists(): pdfmetrics.registerFont(TTFont('Diary',str(font_path)));font='Diary'
    else: font='Helvetica'
    c=canvas.Canvas(str(path),pagesize=A4);w,h=A4
    c.setTitle('Bolus · Diabetes Report'); page=0
    factor=18 if user.glucose_unit=='mg/dL' else 1
    def text(x,y,t,size=10,color='#2b4140'):
        c.setFillColor(color);c.setFont(font,size);c.drawString(x,y,str(t))
    def start(title):
        nonlocal page
        page+=1;text(42,h-52,'BOLUS / DIABETES REPORT',20);text(42,h-77,title,12)
        text(42,h-97,f'{job.date_from} — {job.date_to} · {user.glucose_unit} · {user.timezone}',9)
        c.setStrokeColorRGB(.88,.92,.9);c.line(42,h-115,w-42,h-115)
    def finish():
        text(42,30,f'Generated {now()[:16]} UTC · Research prototype · Sample-based range percentages',7)
        text(w-70,30,str(page),9);c.showPage()
    start({'doctor':'Отчёт для врача','summary':'Сводка','glucose':'Глюкоза','insulin':'Инсулин','nutrition':'Питание','cycle':'Цикл','raw':'Исходные данные','personalization':'Персонализация'}[job.type])
    y=h-150
    items=[('Средняя глюкоза',None if metrics['mean_glucose'] is None else round(metrics['mean_glucose']*factor,1)),('В диапазоне / TIR (по измерениям)',metrics['tir']),('Ниже диапазона / TBR',metrics['tbr']),('Выше диапазона / TAR',metrics['tar']),('CV, %',metrics['coefficient_of_variation']),('Инсулин в сутки, ЕД',metrics['daily_insulin']),('Базальный в сутки, ЕД',metrics['basal_insulin']),('Болюсный в сутки, ЕД',metrics['bolus_insulin']),('Углеводы в сутки, г',metrics['carbs_per_day']),('Количество измерений',metrics['sample_size'])]
    if not job.options.get('include_nutrition',True): items=[x for x in items if 'Углеводы' not in x[0]]
    for label,value in items:
        text(45,y,label,11);text(425,y,'—' if value is None else str(value),12);y-=28
    text(45,y-10,'Диапазон: 3,9–10 ммоль/л. Процент измерений не равен времени CGM.',8)
    text(45,y-30,'Выявленные паттерны: недостаточно проверенных сопоставимых эпизодов.',8)
    text(45,y-50,'AI-резюме не включено. Метрики рассчитаны детерминированно.',8)
    finish()
    if job.options.get('include_graphs',True) and metrics['sample_size']:
        start('Профиль глюкозы по часам')
        profile=hourly_profile(entries,user.timezone);x0=60;y0=350;gw=475;gh=300
        c.setFillColorRGB(.91,.96,.93);c.rect(x0,y0+3.9/20*gh,gw,6.1/20*gh,stroke=0,fill=1)
        for v in [0,5,10,15,20]:
            c.setStrokeColorRGB(.9,.92,.92);c.line(x0,y0+v/20*gh,x0+gw,y0+v/20*gh);text(30,y0+v/20*gh,str(v*factor),8)
        for hour in [0,6,12,18,23]:text(x0+hour/23*gw-8,y0-20,str(hour)+':00',8)
        c.setStrokeColorRGB(.14,.5,.41);c.setLineWidth(2)
        for a,b in zip(profile,profile[1:]):c.line(x0+a['hour']/23*gw,y0+a['mean']/20*gh,x0+b['hour']/23*gw,y0+b['mean']/20*gh)
        text(45,280,'Каждая точка — среднее записанных измерений за этот час.',10)
        text(45,258,'Промежутки между измерениями не восстанавливаются.',10);finish()
    start('Терапевтический профиль')
    y=h-150
    active=next((p for p in reversed(profiles) if p.valid_from[:10]<=job.date_to),None)
    if active:
        text(45,y,f'Версия {active.version} · действует с {active.valid_from[:10]}',10);y-=35
        text(45,y,'Время             ICR, г/ЕД       ISF, ммоль/л/ЕД       Цель',11);y-=28
        for s in active.data['segments']:
            text(45,y,f"{s['start_time']}–{s['end_time']}       {s['icr']}                 {s['isf']}                  {s['target']}",10);y-=25
        y-=20
        for line in [f"DIA: {active.data['insulin_action_duration']} ч",f"Max bolus: {active.data['max_bolus']} ЕД",f"Rapid: {active.data['rapid_insulin_name']}",f"Basal: {active.data['basal_insulin_name']}"]:
            text(45,y,line,10);y-=24
    else:text(45,y,'Профиль не настроен',11)
    finish();c.save()

def generate_report(job_id):
    with SessionLocal() as db:
        job=db.get(ReportJob,job_id)
        if not job or job.status=='completed': return
        user=db.get(User,job.user_id)
        if not user:return
        job.status='processing';job.progress=10;db.commit()
        try:
            df=date.fromisoformat(job.date_from);dt=date.fromisoformat(job.date_to)
            entries=period_entries(db,user.id,df,dt,user.timezone)
            metrics=summarize(entries,(dt-df).days+1,user.timezone)
            profiles=list(db.scalars(select(Profile).where(Profile.user_id==user.id).order_by(Profile.version)))
            calculations=list(db.scalars(select(Calculation).where(Calculation.user_id==user.id)))
            calculations=[c for c in calculations if df<=datetime.fromisoformat(c.calculated_at).astimezone(ZoneInfo(user.timezone)).date()<=dt]
            cycles=list(db.scalars(select(Cycle).where(Cycle.user_id==user.id)))
            foods=list(db.scalars(select(CustomFood).where(CustomFood.user_id==user.id)))
            tables=tables_for(entries,profiles,calculations,cycles,foods,user.timezone,user.glucose_unit)
            if not job.options.get('include_nutrition',True):
                for name in ('Meals','Meal Items','Foods'):tables.pop(name,None)
            if not job.options.get('include_cycle',True):tables.pop('Cycle',None)
            out=Path(settings.report_dir).resolve();out.mkdir(parents=True,exist_ok=True)
            extension='zip' if job.format=='csv' else job.format
            path=out/f'{job.id}.{extension}'
            if job.format=='json':
                # Full backup always includes all rows, independent of selected report period.
                all_entries=[entry_dict(e) for e in db.scalars(select(Entry).where(Entry.user_id==user.id))]
                all_calcs=list(db.scalars(select(Calculation).where(Calculation.user_id==user.id)))
                backup=tables_for(all_entries,profiles,all_calcs,cycles,foods,user.timezone,user.glucose_unit)
                backup['Audit']=[{'action':a.action,'entity_type':a.entity_type,'entity_id':a.entity_id,'old_value':a.old_value,'new_value':a.new_value,'timestamp':a.timestamp} for a in db.scalars(select(AuditLog).where(AuditLog.user_id==user.id))]
                path.write_text(json.dumps({'schema_version':'1.0','exported_at':now(),'user':{k:getattr(user,k) for k in ('id','email','name','timezone','locale','glucose_unit','weight_unit','theme_id','mascot_id','created_at')},'entries':all_entries,'datasets':backup},ensure_ascii=False,indent=2),encoding='utf-8')
            elif job.format=='csv':
                with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as archive:
                    for name,rows in tables.items():archive.writestr(name.lower().replace(' ','_')+'.csv',csv_bytes(rows))
                    archive.writestr('summary.csv',csv_bytes([metrics]))
            elif job.format=='xlsx':
                from openpyxl import Workbook
                from openpyxl.styles import Font,PatternFill
                wb=Workbook();wb.remove(wb.active)
                for name,rows in {'Summary':[{'period':f'{df} — {dt}','timezone':user.timezone,'glucose_unit':'mmol/L (summary)','export_unit':user.glucose_unit,**metrics}],**tables}.items():
                    ws=wb.create_sheet(name);keys=columns(rows);ws.append(keys)
                    for row in rows: ws.append([safe_cell(row.get(k)) for k in keys])
                    ws.freeze_panes='A2';ws.auto_filter.ref=ws.dimensions
                    for cell in ws[1]:cell.font=Font(bold=True,color='FFFFFF');cell.fill=PatternFill('solid',fgColor='237F6C')
                    for col in ws.columns:ws.column_dimensions[col[0].column_letter].width=24
                wb.save(path)
            else:create_pdf(path,user,job,metrics,entries,profiles)
            # Account deletion or job deletion while processing must not resurrect orphan files.
            db.expire_all()
            if not db.get(User,user.id) or not db.get(ReportJob,job_id):path.unlink(missing_ok=True);return
            job.file_path=str(path);job.status='completed';job.progress=100;job.completed_at=now();job.expires_at=(datetime.now(timezone.utc)+timedelta(days=7)).isoformat();db.commit()
        except Exception:
            db.rollback();job=db.get(ReportJob,job_id)
            if job:job.status='failed';job.error='Не удалось создать отчёт. Попробуйте ещё раз.';db.commit()
            raise
EOF
cat > outputs/bolus-assistant/backend/app/reports/tasks.py <<'EOF'
from celery import Celery
from app.config import settings
from app.reports.generator import generate_report
celery=Celery('bolus',broker=settings.redis_url or 'memory://',backend=settings.redis_url or 'cache+memory://')
celery.conf.update(task_always_eager=settings.task_always_eager,task_serializer='json',accept_content=['json'],result_serializer='json',task_time_limit=120,worker_hijack_root_logger=False)
@celery.task(name='reports.generate',ignore_result=True)
def build_report(job_id:str):generate_report(job_id)
EOF
cat > outputs/bolus-assistant/backend/app/api/routes.py <<'EOF'
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
from app.analytics.engine import summarize,hourly_profile
from app.cycle.engine import cycle_status
from app.food.providers import search_foods
from app.imports.apple_health import parse_apple_health

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
def config():return {'feature_ai':False,'feature_personalization':False,'feature_cycle':settings.feature_cycle,'feature_barcode':False,'feature_cgm':False,'clinical_use_enabled':settings.clinical_use_enabled,'demo_enabled':settings.demo_enabled}

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
    profile=profile_for(db,user.id)
    if payload.insulin_type=='rapid' and not profile:raise HTTPException(422,'Настройте DIA в профиле перед записью быстрого инсулина')
    data=payload.model_dump(mode='json',exclude={'client_id','administered_at'});data['dia']=profile.data['insulin_action_duration'] if profile else 4;data['action_model']='linear-remaining-v1.0.0'
    return save_entry(db,user,'insulin',payload.administered_at,data,payload.client_id)
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
    if not user.is_demo and not settings.clinical_use_enabled:raise HTTPException(403,'Расчёт доступен в демо. Клиническая валидация этой версии не выполнена.')
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
    result=calculate(inputs,at);row=Calculation(user_id=user.id,calculated_at=utc(at),input_snapshot=inputs,calculation_snapshot=result,algorithm_version=ALGORITHM_VERSION)
    db.add(row);db.flush();audit(db,user.id,'bolus_calculation','calculation',row.id,new={'algorithm_version':ALGORITHM_VERSION,'status':result['calculation_status']});db.commit()
    return {'calculation_id':row.id,**result,'profile_version':profile.version,'demo':user.is_demo}
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
    profile=db.get(Profile,row.input_snapshot['profile_id'])
    data={'units':payload.actual_units,'insulin_type':'rapid','insulin_name':profile.data['rapid_insulin_name'],'purpose':'meal_and_correction' if row.input_snapshot['carbs'] else 'correction','dia':row.input_snapshot['dia'],'action_model':row.input_snapshot['iob_model'],'related_bolus_calculation_id':row.id,'related_meal_id':row.input_snapshot.get('meal_id'),'note':''}
    entry=Entry(user_id=user.id,kind='insulin',client_id='bolus-'+row.id,occurred_at=utc(payload.administered_at),data=data);db.add(entry)
    try:db.flush()
    except IntegrityError:
        db.rollback();existing=db.scalar(select(Entry).where(Entry.user_id==user.id,Entry.client_id=='bolus-'+row.id));return {'entry_id':existing.id,'actual_units':existing.data['units'],'already_confirmed':True}
    row.actual_bolus=payload.actual_units;row.confirmed_entry_id=entry.id;audit(db,user.id,'bolus_confirmation','calculation',row.id,new=data);db.commit();return {'entry_id':entry.id,'actual_units':payload.actual_units}

@router.get('/foods/search')
async def foods(q:str=Query(default='',max_length=150),user=Depends(current_user),db:Session=Depends(get_db)):
    result,warnings=await search_foods(q)
    custom=[{'external_id':f.id,'provider':'custom','grams':f.data.get('serving_weight',100),'serving':f.data.get('serving_name','100 г'),**f.data} for f in db.scalars(select(CustomFood).where(CustomFood.user_id==user.id)) if q.lower() in f.name.lower()]
    return {'foods':custom+result,'warnings':warnings}
@router.post('/foods/custom',status_code=201)
def custom_food(payload:FoodInput,user=Depends(current_user),db:Session=Depends(get_db)):
    food=CustomFood(user_id=user.id,name=payload.name,data=payload.model_dump());db.add(food);db.commit();return {'id':food.id,**food.data}
@router.get('/foods/barcode/{barcode}')
def barcode(barcode:str,user=Depends(current_user)):raise HTTPException(501,'Сканирование штрихкодов запланировано для версии 1.1')
@router.post('/recipes',status_code=201)
def recipe(payload:RecipeInput,user=Depends(current_user),db:Session=Depends(get_db)):
    total={n:sum(getattr(i,n) for i in payload.ingredients) for n in ('carbs','protein','fat','calories','fiber','sugar')}
    data={'name':payload.name,'brand':'Мои блюда','serving_name':'100 г','serving_weight':100,**{n:round(v/payload.cooked_weight*100,4) for n,v in total.items()},'recipe':payload.model_dump(),'total':total,'per_serving':{n:round(v/payload.servings,4) for n,v in total.items()}}
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
def analytics(days:int=Query(default=7,ge=1,le=366),date_from:date|None=None,date_to:date|None=None,user=Depends(current_user),db:Session=Depends(get_db)):
    dt=date_to or datetime.now(ZoneInfo(user.timezone)).date();df=date_from or dt-timedelta(days=days-1)
    if dt<df or (dt-df).days>366:raise HTTPException(422,'Некорректный период')
    rows=period_entries(db,user.id,df,dt,user.timezone);metrics=summarize(rows,(dt-df).days+1,user.timezone)
    daily=[]
    for offset in range((dt-df).days+1):
        day=df+timedelta(days=offset);r=[e for e in rows if datetime.fromisoformat(e['occurred_at']).astimezone(ZoneInfo(user.timezone)).date()==day]
        workouts=[e for e in r if e['kind']=='activity']
        daily.append({'date':day.isoformat(),**summarize(r,1,user.timezone),'activity_minutes':sum(e['data']['duration_minutes'] for e in workouts)})
    # Context observations, no causal claims and no dosing modifiers.
    activity_response=[]
    for e in rows:
        if e['kind']!='activity':continue
        start=datetime.fromisoformat(e['occurred_at']);end=start+timedelta(minutes=e['data']['duration_minutes'])
        before=[g for g in rows if g['kind']=='glucose' and start-timedelta(minutes=60)<=datetime.fromisoformat(g['occurred_at'])<=start]
        after=[g for g in rows if g['kind']=='glucose' and end<=datetime.fromisoformat(g['occurred_at'])<=end+timedelta(hours=2)]
        if before and after:
            a=before[-1]['data']['value_mmol'];b=after[0]['data']['value_mmol'];activity_response.append({'activity_id':e['id'],'name':e['data']['name'],'before':a,'after':b,'change':round(b-a,2),'source':e['data'].get('source','manual')})
    return {'period':{'from':str(df),'to':str(dt)},'metrics':metrics,'daily':daily,'hourly':hourly_profile(rows,user.timezone),'activity_response':activity_response,'activity_minutes':sum(e['data']['duration_minutes'] for e in rows if e['kind']=='activity'),'patterns':[],'entries':rows}

@router.post('/imports/apple-health')
async def apple_import(file:UploadFile=File(...),user=Depends(current_user),db:Session=Depends(get_db)):
    content=await file.read(20*1024*1024+1)
    try:rows=parse_apple_health(content)
    except (ValueError,Exception) as exc:
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
@router.post('/ai/chat')
def ai_chat(user=Depends(current_user)):raise HTTPException(501,'AI-ассистент запланирован для версии 1.1')
@router.get('/themes')
def themes():return [{'id':k,'name':v} for k,v in [('light','Minimal Light'),('dark','Minimal Dark'),('cat','Cat Café'),('pink','Pink Pastel'),('dino','Dino'),('oled','OLED Black')]]
@router.get('/mascots')
def mascots():return ['cat','pig','dinosaur','rabbit','otter','panda']
EOF
cat > outputs/bolus-assistant/backend/app/main.py <<'EOF'
import json,logging,time,secrets
from contextlib import asynccontextmanager
from fastapi import FastAPI,Request
from fastapi.middleware.cors import CORSMiddleware
from app.config import settings
from app.api.routes import router

@asynccontextmanager
async def lifespan(app):
    if settings.environment=='production' and not settings.secure_cookies:
        raise RuntimeError('Production requires SECURE_COOKIES=true and HTTPS termination')
    yield

app=FastAPI(title='Bolus Assistant',version='1.0.0',lifespan=lifespan)
app.add_middleware(CORSMiddleware,allow_origins=[settings.allowed_origin],allow_credentials=True,allow_methods=['GET','POST','PUT','PATCH','DELETE'],allow_headers=['Content-Type','X-CSRF-Token'])
logger=logging.getLogger('bolus.requests')
@app.middleware('http')
async def request_context(request:Request,call_next):
    request_id=secrets.token_hex(8);start=time.monotonic()
    response=await call_next(request)
    response.headers['X-Request-ID']=request_id
    response.headers['Cache-Control']='no-store'
    response.headers['X-Content-Type-Options']='nosniff'
    # No query strings, user identifiers, bodies, email or medical payloads in process logs.
    logger.info(json.dumps({'request_id':request_id,'method':request.method,'status':response.status_code,'duration_ms':round((time.monotonic()-start)*1000)}))
    return response
app.include_router(router)
EOF
cat > outputs/bolus-assistant/backend/alembic.ini <<'EOF'
[alembic]
script_location = alembic
prepend_sys_path = .
sqlalchemy.url = sqlite:///./bolus.db
EOF
cat > outputs/bolus-assistant/backend/alembic/env.py <<'EOF'
from alembic import context
from app.db import Base,engine
from app.models import entities
config=context.config
if context.is_offline_mode():
    context.configure(url=str(engine.url),target_metadata=Base.metadata,literal_binds=True)
    with context.begin_transaction():context.run_migrations()
else:
    with engine.connect() as connection:
        context.configure(connection=connection,target_metadata=Base.metadata,render_as_batch=engine.dialect.name=='sqlite')
        with context.begin_transaction():context.run_migrations()
EOF
cat > outputs/bolus-assistant/backend/alembic/versions/0001_initial.py <<'EOF'
"""Initial schema, version 1.0."""
from alembic import op
from app.db import Base
from app.models import entities
revision='0001'
down_revision=None
branch_labels=None
depends_on=None
def upgrade(): Base.metadata.create_all(bind=op.get_bind())
def downgrade(): Base.metadata.drop_all(bind=op.get_bind())
EOF
