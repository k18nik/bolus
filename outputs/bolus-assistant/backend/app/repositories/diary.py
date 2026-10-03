from datetime import datetime,timezone,timedelta,date
from zoneinfo import ZoneInfo
from sqlalchemy import select
from app.models.entities import Entry,Profile,AuditLog,User,Cycle
from app.iob.engine import AdministeredDose,calculate_iob

def utc(dt): return dt.astimezone(timezone.utc).isoformat()
def entry_dict(e): return {'id':e.id,'kind':e.kind,'occurred_at':e.occurred_at,'data':e.data,'version':e.version,'updated_at':e.updated_at}
def profile_for(db,user_id): return db.scalar(select(Profile).where(Profile.user_id==user_id,Profile.status=='active').order_by(Profile.version.desc()))
def audit(db,user_id,action,entity_type,entity_id,old=None,new=None): db.add(AuditLog(user_id=user_id,action=action,entity_type=entity_type,entity_id=entity_id,old_value=old,new_value=new))
def period_entries(db,user_id,from_date:date,to_date:date,tz:str):
    zone=ZoneInfo(tz)
    start=utc(datetime.combine(from_date,datetime.min.time(),zone))
    end=utc(datetime.combine(to_date+timedelta(days=1),datetime.min.time(),zone))
    rows=db.scalars(select(Entry).where(Entry.user_id==user_id,Entry.occurred_at>=start,Entry.occurred_at<end).order_by(Entry.occurred_at)).all()
    return [entry_dict(e) for e in rows]
def current_iob(db,user_id,at):
    rows=db.scalars(select(Entry).where(Entry.user_id==user_id,Entry.kind=='insulin',Entry.occurred_at>=utc(at-timedelta(hours=8)),Entry.occurred_at<=utc(at))).all()
    doses=[AdministeredDose(e.data['units'],datetime.fromisoformat(e.occurred_at),e.data.get('dia',4),e.data['insulin_type']) for e in rows if e.data['insulin_type']=='rapid']
    return calculate_iob(doses,at)
