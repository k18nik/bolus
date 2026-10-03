"""Bounded, streaming Apple Health XML import: workouts + daily activity summaries only."""
import io, hashlib, zipfile
from datetime import datetime
from xml.etree.ElementTree import iterparse, ParseError
from app.repositories.diary import utc

MAX_UNCOMPRESSED=60*1024*1024
WORKOUTS={'Walking':'Ходьба','Running':'Бег','Cycling':'Велосипед','Swimming':'Плавание','Yoga':'Йога','TraditionalStrengthTraining':'Силовая тренировка','FunctionalStrengthTraining':'Функциональная тренировка','Hiking':'Поход','Other':'Тренировка'}

def parse_apple_health(content:bytes) -> list[dict]:
    if len(content)>20*1024*1024: raise ValueError('Максимальный размер файла — 20 МБ')
    if content.startswith(b'PK'):
        with zipfile.ZipFile(io.BytesIO(content)) as z:
            files=[i for i in z.infolist() if i.filename.endswith('export.xml')]
            if len(files)!=1 or files[0].file_size>MAX_UNCOMPRESSED: raise ValueError('Нужен один export.xml размером до 60 МБ')
            with z.open(files[0]) as f: content=f.read(MAX_UNCOMPRESSED+1)
    if len(content)>MAX_UNCOMPRESSED: raise ValueError('Слишком большой XML')
    # UTF-8/UTF-16 entity declarations must not reach the parser.
    checked=content.replace(b'\x00',b'').upper()
    if b'<!ENTITY' in checked or b'<!DOCTYPE' in checked and b'SYSTEM' in checked: raise ValueError('Внешние XML-сущности запрещены')
    rows=[]
    try:
        for _,el in iterparse(io.BytesIO(content),events=('end',)):
            a=el.attrib
            if el.tag=='Workout':
                start=datetime.strptime(a['startDate'],'%Y-%m-%d %H:%M:%S %z')
                end=datetime.strptime(a['endDate'],'%Y-%m-%d %H:%M:%S %z')
                minutes=(end-start).total_seconds()/60
                if not 0<minutes<=1440: raise ValueError('Некорректная длительность тренировки')
                kind=a.get('workoutActivityType','').replace('HKWorkoutActivityType','')
                identity=f"{a.get('sourceName','')}:{a['startDate']}:{a['endDate']}:{kind}"
                rows.append({'client_id':'health-'+hashlib.sha256(identity.encode()).hexdigest()[:48],'occurred_at':utc(start),'kind':'activity','data':{'name':WORKOUTS.get(kind,kind or 'Тренировка'),'duration_minutes':round(minutes,1),'intensity':'unknown','source':'apple_health','source_name':a.get('sourceName','Apple Health'),'ended_at':utc(end),'note':'Импортировано из Apple «Здоровье»'}})
            elif el.tag=='ActivitySummary':
                day=a['dateComponents']; energy=float(a.get('activeEnergyBurned',0)); exercise=float(a.get('appleExerciseTime',0))
                if not 0<=energy<=30000 or not 0<=exercise<=1440: raise ValueError('Некорректная сводка активности')
                rows.append({'client_id':'health-day-'+day,'kind':'activity_summary','local_date':day,'data':{'name':'Активность за день','active_energy':energy,'energy_unit':a.get('activeEnergyBurnedUnit','kcal'),'exercise_minutes':exercise,'source':'apple_health','note':'Дневная сводка; не суммируется с тренировками'}})
            el.clear()
            if len(rows)>10000: raise ValueError('В одном импорте допускается до 10 000 записей')
    except (ParseError,KeyError,OverflowError) as exc: raise ValueError('Не удалось прочитать экспорт Apple Health') from exc
    if not rows: raise ValueError('В файле нет тренировок или сводок активности')
    return rows
