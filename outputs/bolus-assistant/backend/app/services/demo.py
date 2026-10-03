from datetime import datetime,timezone,timedelta
from zoneinfo import ZoneInfo
import secrets, math
from app.models.entities import User,Profile,Entry,Cycle,uid
from app.services.security import hasher

def seed_demo(db):
    user=User(email=f'demo-{secrets.token_hex(12)}@example.invalid',name='Анна',password_hash=hasher.hash(secrets.token_urlsafe(32)),is_demo=True)
    db.add(user);db.flush()
    db.add(Profile(user_id=user.id,version=1,data={'diabetes_type':'type1','insulin_therapy_type':'MDI','rapid_insulin_name':'Новорапид','basal_insulin_name':'Тресиба','max_bolus':10,'insulin_action_duration':4,'confirmed':True,'segments':[{'start_time':'00:00','end_time':'06:00','icr':12,'isf':2.5,'target':6,'correct_above':7},{'start_time':'06:00','end_time':'11:00','icr':8,'isf':2,'target':6,'correct_above':7},{'start_time':'11:00','end_time':'18:00','icr':10,'isf':2,'target':6,'correct_above':7},{'start_time':'18:00','end_time':'24:00','icr':11,'isf':2.2,'target':6,'correct_above':7}]}))
    now=datetime.now(timezone.utc); zone=ZoneInfo(user.timezone); today=now.astimezone(zone).date()
    def add(kind,dt,data):
        if dt<=now: db.add(Entry(user_id=user.id,client_id=uid(),kind=kind,occurred_at=dt.astimezone(timezone.utc).isoformat(),data=data))
    for offset in range(14):
        day=today-timedelta(days=offset)
        for index,hour in enumerate([0,2,4,6,7,8,9,10,11,12,13,14,15,16,18,20,22]):
            v=round(6.8+1.0*math.sin(hour*.8+offset*.4)+(2.5 if hour in (9,14) else 0),1)
            add('glucose',datetime.combine(day,datetime.min.time(),zone)+timedelta(hours=hour,minutes=10),{'value_mmol':v,'value':v,'unit':'mmol/L','source':'manual','trend':'stable','note':''})
        for hour,name,carbs,cal,units in [(8,'Овсяная каша с бананом',42,310,4.8),(13,'Паста с курицей, овощной салат',48,485,4.5),(19,'Рис с овощами',36,380,3.2)]:
            dt=datetime.combine(day,datetime.min.time(),zone)+timedelta(hours=hour)
            add('meal',dt,{'name':name,'meal_type':'breakfast' if hour==8 else 'lunch' if hour==13 else 'dinner','total_carbs':carbs,'total_protein':22,'total_fat':12,'total_calories':cal,'items':[{'name_snapshot':name,'food_source':'demo','food_id':'','amount':250,'unit':'g','grams':250,'carbs':carbs,'protein':22,'fat':12,'calories':cal}],'note':''})
            add('insulin',dt-timedelta(minutes=5),{'units':units,'insulin_type':'rapid','insulin_name':'Новорапид','purpose':'meal','dia':4,'note':''})
        add('insulin',datetime.combine(day,datetime.min.time(),zone)+timedelta(hours=7),{'units':14,'insulin_type':'basal','insulin_name':'Тресиба','purpose':'basal','dia':4,'note':''})
        add('activity',datetime.combine(day,datetime.min.time(),zone)+timedelta(hours=16,minutes=30),{'name':'Прогулка','duration_minutes':32,'intensity':'moderate','note':'','source':'manual'})
    add('glucose',now-timedelta(minutes=8),{'value_mmol':6.8,'value':6.8,'unit':'mmol/L','source':'manual','trend':'stable','note':''})
    add('insulin',now-timedelta(hours=2,minutes=24),{'units':3,'insulin_type':'rapid','insulin_name':'Новорапид','purpose':'meal','dia':4,'note':''})
    db.add(Cycle(user_id=user.id,start_date=(today-timedelta(days=17)).isoformat(),cycle_length=28))
    db.commit();return user
