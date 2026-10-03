"""Authenticated native HealthKit sync; observations never modify therapy or doses."""
from datetime import date,datetime,time,timedelta,timezone
from uuid import UUID
from zoneinfo import ZoneInfo
from pydantic import Field,model_validator,AwareDatetime
from fastapi import APIRouter,Depends,HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.schemas.domain import StrictModel
from app.models.entities import Entry,User,now
from app.db import get_db
from app.services.security import current_user,rate_limit
from app.repositories.diary import utc,audit

class WorkoutInput(StrictModel):
    id: UUID
    name: str=Field(min_length=1,max_length=100)
    source_name: str=Field(min_length=1,max_length=100)
    started_at: AwareDatetime
    ended_at: AwareDatetime
    duration_minutes: float=Field(gt=0,le=1440)
    active_energy: float|None=Field(default=None,ge=0,le=30000)
    distance_km: float|None=Field(default=None,ge=0,le=2000)
    @model_validator(mode='after')
    def times(self):
        if self.ended_at<=self.started_at or self.duration_minutes>(self.ended_at-self.started_at).total_seconds()/60+1:
            raise ValueError('Некорректное время тренировки')
        return self

class DayInput(StrictModel):
    date: date
    steps: int|None=Field(default=None,ge=0,le=500000)
    active_energy: float|None=Field(default=None,ge=0,le=30000)
    exercise_minutes: float|None=Field(default=None,ge=0,le=1440)
    distance_km: float|None=Field(default=None,ge=0,le=2000)
    @model_validator(mode='after')
    def observed(self):
        if all(getattr(self,k) is None for k in ('steps','active_energy','exercise_minutes','distance_km')):
            raise ValueError('В сводке нет доступных наблюдений')
        return self

class HealthKitInput(StrictModel):
    expected_user_id: str=Field(min_length=1,max_length=36)
    timezone: str
    workouts: list[WorkoutInput]=Field(default_factory=list,max_length=1000)
    days: list[DayInput]=Field(default_factory=list,max_length=90)
    @model_validator(mode='after')
    def valid(self):
        try:ZoneInfo(self.timezone)
        except Exception:raise ValueError('Неизвестный часовой пояс')
        if len({w.id for w in self.workouts})!=len(self.workouts) or len({d.date for d in self.days})!=len(self.days):
            raise ValueError('Повторные идентификаторы в одном пакете')
        return self

router=APIRouter(prefix='/api/imports')

@router.post('/healthkit')
def sync_healthkit(payload:HealthKitInput,user=Depends(current_user),db:Session=Depends(get_db)):
    if user.id!=payload.expected_user_id:raise HTTPException(409,'Аккаунт изменился. Снова откройте синхронизацию.')
    rate_limit('healthkit:'+user.id,20,3600)
    db.scalar(select(User).where(User.id==user.id).with_for_update())
    counts={'inserted':0,'updated':0,'unchanged':0}
    def upsert(client_id,kind,at,data):
        row=db.scalar(select(Entry).where(Entry.user_id==user.id,Entry.client_id==client_id))
        if row and kind=='activity_summary':data={**row.data,**data}
        if row and row.data==data and row.occurred_at==at:counts['unchanged']+=1;return
        if row:
            row.data=data;row.occurred_at=at;row.version+=1;row.updated_at=now();counts['updated']+=1
        else:db.add(Entry(user_id=user.id,client_id=client_id,kind=kind,occurred_at=at,data=data));counts['inserted']+=1
    for w in payload.workouts:
        if w.ended_at>datetime.now(timezone.utc)+timedelta(minutes=5):raise HTTPException(422,'Тренировка находится в будущем')
        data=w.model_dump(mode='json',exclude={'id','started_at','ended_at'},exclude_none=True)
        data.update(source='apple_health',source_kind='healthkit',external_id=str(w.id),ended_at=utc(w.ended_at),intensity='unknown',note='Импортировано из Apple «Здоровье»')
        upsert('healthkit-'+str(w.id),'activity',utc(w.started_at),data)
    today=datetime.now(ZoneInfo(payload.timezone)).date()
    for day in payload.days:
        if day.date>today:raise HTTPException(422,'Сводка активности находится в будущем')
        data=day.model_dump(mode='json',exclude={'date'},exclude_none=True)
        data.update(name='Активность за день',source='apple_health',source_kind='healthkit',local_date=str(day.date),timezone=payload.timezone,note='Дневная сводка; не суммируется с тренировками')
        if day.active_energy is not None:data['energy_unit']='kcal'
        upsert('health-day-'+str(day.date),'activity_summary',utc(datetime.combine(day.date,time.min,ZoneInfo(payload.timezone))),data)
    audit(db,user.id,'healthkit_sync','import',user.id,new=counts)
    db.commit()
    return {**counts,'source':'healthkit'}
