"""A4, Unicode, deterministic report rendering; no network or AI."""
from collections import defaultdict
from datetime import datetime,date,timedelta,timezone
from pathlib import Path
from statistics import mean
from zoneinfo import ZoneInfo
from xml.sax.saxutils import escape
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet,ParagraphStyle
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Table,TableStyle,PageBreak,KeepTogether
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.graphics.shapes import Drawing,Line,Rect,String,PolyLine,Circle
from app.analytics.engine import summarize,hourly_profile
from app.cycle.engine import cycle_status,PHASE_LABELS

FONT='Diary'
def render_pdf(path,user,job,metrics,entries,profiles,cycles):
    pdfmetrics.registerFont(TTFont(FONT,str(Path(__file__).parent/'DejaVuSans.ttf')))
    styles=getSampleStyleSheet()
    for style in styles.byName.values():style.fontName=FONT
    styles.add(ParagraphStyle('ReportTitle',fontName=FONT,fontSize=24,leading=31,textColor=colors.HexColor('#237f6c'),spaceAfter=12))
    styles.add(ParagraphStyle('Section',fontName=FONT,fontSize=14,leading=20,spaceBefore=15,spaceAfter=13,textColor=colors.HexColor('#284a40')))
    styles.add(ParagraphStyle('Note',fontName=FONT,fontSize=8,leading=12,textColor=colors.HexColor('#75817e'),spaceAfter=10))
    styles['Normal'].fontSize=10;styles['Normal'].leading=15
    story=[];factor=18 if user.glucose_unit=='mg/dL' else 1;unit=user.glucose_unit
    df=date.fromisoformat(job.date_from);dt=date.fromisoformat(job.date_to);zone=ZoneInfo(user.timezone)
    def p(t,style='Normal'):return Paragraph(escape(str(t)),styles[style])
    def section(t):story.append(p(t,'Section'))
    def note(t):story.append(p(t,'Note'))
    def table(headers,rows,widths=None):
        content=[[p(h) for h in headers]]+[[p('—' if c is None else c) for c in row] for row in rows]
        t=Table(content,colWidths=widths or [511/len(headers)]*len(headers),repeatRows=1,hAlign='LEFT')
        t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#eaf3ed')),('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),10),('RIGHTPADDING',(0,0),(-1,-1),10),('TOPPADDING',(0,0),(-1,-1),9),('BOTTOMPADDING',(0,0),(-1,-1),9),('LINEBELOW',(0,0),(-1,-1),.35,colors.HexColor('#e5eae7')),('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,colors.HexColor('#fafcfb')])]))
        story.extend([t,Spacer(1,14)])
    def f(value,digits=2):return '—' if value is None else f'{value:.{digits}f}'
    def chart(title,points,x_labels,y_label,minimum_top=1,range_band=None,bar=False,color='#359679'):
        section(title)
        if not points:note('Нет данных в выбранном периоде.');return
        drawing=Drawing(511,205);left=44;bottom=30;width=450;height=148
        max_y=max(minimum_top,max(y for _,y in points)*1.15);max_x=max(1,max(x for x,_ in points))
        if y_label=='%':max_y=100
        if range_band:
            lo,hi=range_band;drawing.add(Rect(left,bottom+lo/max_y*height,width,(hi-lo)/max_y*height,fillColor=colors.HexColor('#edf6ef'),strokeColor=None))
        for i in range(5):
            y=bottom+i/4*height;drawing.add(Line(left,y,left+width,y,strokeColor=colors.HexColor('#e3eae6'),strokeWidth=.4));drawing.add(String(4,y-3,f(max_y*i/4),fontName=FONT,fontSize=7,fillColor=colors.HexColor('#7c8985')))
        drawing.add(String(3,191,y_label,fontName=FONT,fontSize=8,fillColor=colors.HexColor('#62766c')))
        for x,label in x_labels:
            xx=left+x/max_x*width;drawing.add(String(xx,bottom-16,str(label),fontName=FONT,fontSize=7,textAnchor='middle',fillColor=colors.HexColor('#7c8985')))
        if bar:
            bw=min(34,width/max(len(points),1)*.58)
            for x,y in points:drawing.add(Rect(left+x/max_x*width-bw/2,bottom,bw,y/max_y*height,fillColor=colors.HexColor(color),strokeColor=None))
        else:
            pts=[]
            for x,y in points:pts.extend([left+x/max_x*width,bottom+y/max_y*height])
            if len(pts)>=4:drawing.add(PolyLine(pts,strokeColor=colors.HexColor(color),strokeWidth=1.6))
            for x,y in points[::max(1,len(points)//100)]:drawing.add(Circle(left+x/max_x*width,bottom+y/max_y*height,1.5,fillColor=colors.HexColor(color),strokeColor=None))
        story.append(drawing)
    names={'doctor':'Отчёт для врача','summary':'Общая сводка','glucose':'Глюкоза','insulin':'Инсулин','nutrition':'Питание','cycle':'Менструальный цикл','raw':'Исходные данные','personalization':'Персонализация'}
    story.append(p('BOLUS / DIABETES REPORT','ReportTitle'));story.append(p(names[job.type],'Section'))
    note(f'Период: {df} - {dt} | Единицы глюкозы: {unit} | Часовой пояс: {user.timezone}')
    if user.is_demo:note('ДЕМОНСТРАЦИОННЫЕ ДАННЫЕ. Не использовать для медицинских решений.')
    metric_rows=[['Средняя глюкоза',f(metrics['mean_glucose']*factor) if metrics['mean_glucose'] is not None else '—'],['TIR / в диапазоне, % измерений',f(metrics['tir'])],['TBR / ниже диапазона, % измерений',f(metrics['tbr'])],['TAR / выше диапазона, % измерений',f(metrics['tar'])],['CV / коэффициент вариации, %',f(metrics['coefficient_of_variation'])],['Всего инсулина в сутки, ЕД',f(metrics['daily_insulin'])],['Базальный / болюсный в сутки, ЕД',f(metrics['basal_insulin'])+' / '+f(metrics['bolus_insulin'])]]
    if job.options.get('include_nutrition',True):metric_rows.append(['Углеводы в сутки, г',f(metrics['carbs_per_day'])])
    metric_rows.append(['Записанных измерений',metrics['sample_size']]);table(['Показатель','Значение'],metric_rows,[365,146])
    note(f'Диапазон: {3.9*factor:.1f}-{10*factor:.1f} {unit}. При ручном вводе доля измерений не равна доле времени CGM. Дни без записей входят в знаменатель суточных сумм; отсутствие записи не означает отсутствие инсулина или еды.')
    note('Метрики рассчитаны сервером. AI-резюме не включено. Отчёт описывает наблюдения, не устанавливает диагноз.')
    daily=[]
    for offset in range((dt-df).days+1):
        day=df+timedelta(days=offset);rows=[e for e in entries if datetime.fromisoformat(e['occurred_at']).astimezone(zone).date()==day]
        daily.append((day,summarize(rows,1,user.timezone)))
    labels=[(i,d.strftime('%d.%m')) for i,(d,_) in enumerate(daily) if i%max(1,len(daily)//6)==0]
    if job.options.get('include_graphs',True):
        story.append(PageBreak())
        if job.type in ('doctor','summary','glucose','raw'):
            points=hourly_profile(entries,user.timezone)
            chart('Суточный профиль глюкозы',[(r['hour'],r['mean']*factor) for r in points],[(h,f'{h:02d}:00') for h in (0,6,12,18,23)],unit,15*factor,(3.9*factor,10*factor))
            note('Средние значения по часам на основе фактических измерений. Не является CGM/AGP-профилем.')
            start=datetime.combine(df,datetime.min.time(),zone)
            chart('Глюкоза за выбранный период',[((datetime.fromisoformat(e['occurred_at'])-start).total_seconds()/86400,e['data']['value_mmol']*factor) for e in entries if e['kind']=='glucose'],labels,unit,15*factor,(3.9*factor,10*factor))
            story.append(PageBreak())
            chart('Распределение измерений',[(i,metrics[k] or 0) for i,k in enumerate(('tbr','tir','tar'))],[(0,'Ниже'),(1,'В диапазоне'),(2,'Выше')],'%',100,bar=True)
            chart('Средняя глюкоза по дням',[(i,m['mean_glucose']*factor) for i,(_,m) in enumerate(daily) if m['mean_glucose'] is not None],labels,unit,15*factor,(3.9*factor,10*factor))
            story.append(PageBreak())
        if job.type in ('doctor','summary','insulin','raw'):
            chart('Фактически введённый инсулин по дням',[(i,m['daily_insulin']) for i,(_,m) in enumerate(daily)],labels,'ЕД / сутки',1,bar=True,color='#9c90bd')
            purposes=defaultdict(float)
            for e in entries:
                if e['kind']=='insulin':purposes[e['data']['purpose']]+=e['data']['units']
            keys=['meal','correction','meal_and_correction','basal','manual','other']
            chart('Распределение инсулина по назначению',[(i,purposes[k]) for i,k in enumerate(keys)],list(enumerate(['Еда','Коррекция','Еда + корр.','Базальный','Вручную','Другое'])),'ЕД за период',1,bar=True,color='#9c90bd')
            story.append(PageBreak())
        if job.options.get('include_nutrition',True) and job.type in ('doctor','summary','nutrition','raw'):
            chart('Углеводы по дням',[(i,m['carbs_per_day']) for i,(_,m) in enumerate(daily)],labels,'г / сутки',1,bar=True,color='#d4ad73')
            by_meal=defaultdict(float)
            for e in entries:
                if e['kind']=='meal':by_meal[e['data'].get('meal_type','snack')]+=e['data']['total_carbs']
            keys=['breakfast','lunch','dinner','snack']
            chart('Углеводы по приёмам пищи',[(i,by_meal[k]) for i,k in enumerate(keys)],list(enumerate(['Завтрак','Обед','Ужин','Перекус'])),'г за период',1,bar=True,color='#d4ad73')
            story.append(PageBreak())
    if job.options.get('include_nutrition',True) and job.type in ('doctor','summary','nutrition','raw'):
        section('Питание за период');meals=[e for e in entries if e['kind']=='meal'];n=(dt-df).days+1
        table(['Показатель','В сутки'],[['Энергия, ккал',f(sum(e['data']['total_calories'] for e in meals)/n)],['Белки, г',f(sum(e['data']['total_protein'] for e in meals)/n)],['Жиры, г',f(sum(e['data']['total_fat'] for e in meals)/n)],['Приёмов пищи',f(len(meals)/n)]],[365,146])
        foods=defaultdict(list)
        for e in meals:
            for i in e['data'].get('items',[]):foods[i['name_snapshot']].append(i['carbs'])
        section('Продукты и блюда');table(['Продукт','Раз','Средние углеводы, г'],[[name,len(values),f(mean(values))] for name,values in sorted(foods.items(),key=lambda x:-len(x[1]))[:40]],[305,66,140])
        story.append(PageBreak())
    if job.options.get('include_cycle',True) and cycles:
        section('Цикл и глюкоза');by_phase=defaultdict(list)
        ordered=sorted(cycles,key=lambda c:c.start_date)
        for e in entries:
            if e['kind']!='glucose':continue
            day=datetime.fromisoformat(e['occurred_at']).astimezone(zone).date()
            cycle=next((c for c in reversed(ordered) if c.start_date<=day.isoformat()),None)
            if cycle:
                phase=cycle_status(date.fromisoformat(cycle.start_date),cycle.cycle_length,day,date.fromisoformat(cycle.actual_ovulation_date) if cycle.actual_ovulation_date else None)['phase'];by_phase[phase].append(e['data']['value_mmol'])
        table(['Фаза (расчётная)','Измерений','Средняя, '+unit,'В диапазоне, %'],[[PHASE_LABELS[phase],len(v),f(mean(v)*factor),f(sum(3.9<=x<=10 for x in v)/len(v)*100)] for phase,v in by_phase.items()],[224,80,105,102])
        note('Фазы приблизительны. Сравнение не учитывает различия в питании, активности и терапии; персональные коэффициенты не рассчитываются.')
        table(['Начало','Длина, дней','Фактическая овуляция'],[[c.start_date,c.cycle_length,c.actual_ovulation_date] for c in ordered if c.start_date<=job.date_to],[180,150,181]);story.append(PageBreak())
    section('Терапевтический профиль')
    relevant=[p for p in profiles if p.valid_from[:10]<=job.date_to and (not p.valid_to or p.valid_to[:10]>=job.date_from)]
    if not relevant:note('В выбранном периоде нет сохранённого терапевтического профиля.')
    for profile in relevant:
        section(f'Версия {profile.version} - с {profile.valid_from[:10]}')
        table(['Время','ICR, г/ЕД','ISF, ммоль/л/ЕД','Цель','Коррекция выше'],[[s['start_time']+' - '+s['end_time'],s['icr'],s['isf'],s['target'],s['correct_above']] for s in profile.data['segments']],[115,86,110,90,110])
        note(f"DIA: {profile.data['insulin_action_duration']} ч | max bolus: {profile.data['max_bolus']} ЕД")
        note(f"Шаг болюсного устройства: {profile.data.get('bolus_increment',0.1):g} ЕД | шаг базального: {profile.data.get('basal_increment',0.1):g} ЕД")
        note(f"Быстрый инсулин: {profile.data['rapid_insulin_name']} | Базальный: {profile.data['basal_insulin_name']}")
    section('Выявленные паттерны')
    note('Автоматический анализ сопоставимых эпизодов и персональные предложения пока отключены. Наличие отдельных высоких или низких измерений не меняет профиль.')
    section('Активность и Apple «Здоровье»')
    workouts=[e for e in entries if e['kind']=='activity']
    table(['Тренировок / записей','Длительность, мин','Из Apple Health'],[[len(workouts),f(sum(e['data']['duration_minutes'] for e in workouts)),sum(e['data'].get('source')=='apple_health' for e in workouts)]],[180,180,151])
    note('Дневные сводки Apple Health не суммируются с тренировками повторно. Активность не меняет рассчитанную дозу инсулина.')
    generated=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    def footer(canvas,doc):
        canvas.saveState();canvas.setFont(FONT,7);canvas.setFillColor(colors.HexColor('#7a8781'));canvas.drawString(42,28,f'Bolus | {generated} | {unit}');canvas.drawRightString(A4[0]-42,28,f'Страница {doc.page}');canvas.restoreState()
    doc=SimpleDocTemplate(str(path),pagesize=A4,rightMargin=42,leftMargin=42,topMargin=40,bottomMargin=51,title='Bolus - Diabetes Report',author='Bolus Assistant')
    doc.build(story,onFirstPage=footer,onLaterPages=footer)
