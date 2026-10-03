from datetime import datetime, timedelta
from statistics import mean, median, pstdev
from zoneinfo import ZoneInfo

def summarize(entries: list[dict], days: int, timezone: str='UTC') -> dict:
    glucose=[e['data']['value_mmol'] for e in entries if e['kind']=='glucose']
    doses=[e['data'] for e in entries if e['kind']=='insulin']
    meals=[e['data'] for e in entries if e['kind']=='meal']
    n=len(glucose)
    avg=mean(glucose) if n else None
    # Manual samples are not continuous time coverage: intentionally label as sample-based.
    return {'sample_size':n,'coverage_method':'sample_based','mean_glucose':round(avg,2) if n else None,'median_glucose':median(glucose) if n else None,'min':min(glucose) if n else None,'max':max(glucose) if n else None,'standard_deviation':round(pstdev(glucose),2) if n else None,'coefficient_of_variation':round(pstdev(glucose)/avg*100,1) if n and avg else None,'tir':round(sum(3.9<=v<=10 for v in glucose)/n*100,1) if n else None,'tbr':round(sum(v<3.9 for v in glucose)/n*100,1) if n else None,'tar':round(sum(v>10 for v in glucose)/n*100,1) if n else None,'daily_insulin':round(sum(d['units'] for d in doses)/days,2),'basal_insulin':round(sum(d['units'] for d in doses if d['insulin_type']=='basal')/days,2),'bolus_insulin':round(sum(d['units'] for d in doses if d['insulin_type']!='basal')/days,2),'carbs_per_day':round(sum(m['total_carbs'] for m in meals)/days,1),'calories_per_day':round(sum(m['total_calories'] for m in meals)/days,1),'corrections_per_day':round(sum(d['purpose'] in ('correction','meal_and_correction') for d in doses)/days,2),'days':days}

def daily_breakdown(entries: list[dict], date_from, date_to, timezone: str) -> list[dict]:
    zone=ZoneInfo(timezone);daily=[]
    for offset in range((date_to-date_from).days+1):
        day=date_from+timedelta(days=offset);r=[e for e in entries if datetime.fromisoformat(e['occurred_at']).astimezone(zone).date()==day]
        workouts=[e for e in r if e['kind']=='activity']
        daily.append({'date':day.isoformat(),**summarize(r,1,timezone),'activity_minutes':sum(e['data']['duration_minutes'] for e in workouts)})
    return daily

def activity_response(entries: list[dict]) -> list[dict]:
    # Context observations, no causal claims and no dosing modifiers.
    result=[]
    for e in entries:
        if e['kind']!='activity':continue
        start=datetime.fromisoformat(e['occurred_at']);end=start+timedelta(minutes=e['data']['duration_minutes'])
        before=[g for g in entries if g['kind']=='glucose' and start-timedelta(minutes=60)<=datetime.fromisoformat(g['occurred_at'])<=start]
        after=[g for g in entries if g['kind']=='glucose' and end<=datetime.fromisoformat(g['occurred_at'])<=end+timedelta(hours=2)]
        if before and after:
            a=before[-1]['data']['value_mmol'];b=after[0]['data']['value_mmol'];result.append({'activity_id':e['id'],'name':e['data']['name'],'before':a,'after':b,'change':round(b-a,2),'source':e['data'].get('source','manual')})
    return result

def hourly_profile(entries: list[dict], timezone: str) -> list[dict]:
    buckets={h:[] for h in range(24)}
    for e in entries:
        if e['kind']=='glucose': buckets[datetime.fromisoformat(e['occurred_at']).astimezone(ZoneInfo(timezone)).hour].append(e['data']['value_mmol'])
    return [{'hour':h,'mean':round(mean(v),2),'count':len(v)} for h,v in buckets.items() if v]
