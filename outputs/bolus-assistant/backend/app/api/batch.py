"""One optional-fields form commits atomically; retries never duplicate an event."""
import hashlib,json
from datetime import datetime,timezone,timedelta
from fastapi import APIRouter,Depends,HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.db import get_db
from app.models.entities import DiaryBatch,Entry,Cycle,User
from app.schemas.domain import DiaryBatchInput
from app.services.security import current_user
from app.repositories.diary import utc,entry_dict,audit
from app.api.routes import prepare_insulin

router=APIRouter(prefix='/api')

@router.post('/diary/batch',status_code=201)
def batch(payload:DiaryBatchInput,user=Depends(current_user),db:Session=Depends(get_db)):
    digest=hashlib.sha256(json.dumps(payload.model_dump(mode='json'),sort_keys=True).encode()).hexdigest()
    db.scalar(select(User).where(User.id==user.id).with_for_update())
    previous=db.scalar(select(DiaryBatch).where(DiaryBatch.user_id==user.id,DiaryBatch.client_id==payload.client_id))
    if previous:
        if previous.payload_hash!=digest:raise HTTPException(409,'Этот запрос уже сохранён с другими данными. Обновите форму.')
        return previous.result
    rows=[]
    def add(kind,event,time_field,data):
        occurred=getattr(event,time_field)
        if occurred>datetime.now(timezone.utc)+timedelta(minutes=5):raise HTTPException(422,'Время записи находится в будущем')
        rows.append(Entry(user_id=user.id,kind=kind,occurred_at=utc(occurred),client_id=payload.client_id+':'+str(len(rows)),data=data))
    if payload.glucose:
        e=payload.glucose;d=e.model_dump(mode='json',exclude={'client_id','measured_at'});d['value_mmol']=e.value/(18 if e.unit=='mg/dL' else 1);add('glucose',e,'measured_at',d)
    if payload.meal:
        e=payload.meal;d=e.model_dump(mode='json',exclude={'client_id','eaten_at'})
        for nutrient in ('carbs','protein','fat','calories'):d['total_'+nutrient]=round(sum(getattr(i,nutrient) for i in e.items),4)
        add('meal',e,'eaten_at',d)
    for e in payload.insulin:add('insulin',e,'administered_at',prepare_insulin(db,user,e))
    if payload.activity:
        e=payload.activity;d=e.model_dump(mode='json',exclude={'client_id','occurred_at'});d['source']='manual';add('activity',e,'occurred_at',d)
    if payload.note:add('note',payload.note,'occurred_at',{'note':payload.note.note})
    cycle=None
    if payload.cycle:
        e=payload.cycle
        if e.start_date>datetime.now(timezone.utc).date()+timedelta(days=1):raise HTTPException(422,'Начало цикла находится в будущем')
        cycle=Cycle(user_id=user.id,**{k:str(v) if v is not None and k!='cycle_length' else v for k,v in e.model_dump().items()});db.add(cycle)
    db.add_all(rows);db.flush()
    for row in rows:audit(db,user.id,'entry_create',row.kind,row.id,new=row.data)
    if cycle:audit(db,user.id,'cycle_create','cycle',cycle.id,new=payload.cycle.model_dump(mode='json'))
    result={'entries':[entry_dict(e) for e in rows],'cycle_id':cycle.id if cycle else None,'count':len(rows)+bool(cycle)}
    db.add(DiaryBatch(user_id=user.id,client_id=payload.client_id,payload_hash=digest,result=result));db.commit()
    return result
