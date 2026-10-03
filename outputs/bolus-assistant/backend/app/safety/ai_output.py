"""AI explanations are display-only and have no executable dosing fields."""
import re
from fastapi import HTTPException
from app.ai.contracts import InsightResponse

def validate_explanation(data):
    try:insight=InsightResponse.model_validate(data)
    except Exception:raise HTTPException(502,'Ответ AI не прошёл проверку структуры. Попробуйте снова.')
    text=' '.join([insight.summary,*insight.observations,*insight.possible_explanations,*insight.questions,*insight.safety_flags])
    dose=r'\d+(?:[.,]\d+)?\s*(?:ЕД|единиц\w*|units?|IU|U|МЕ)\b'
    imperative=r'(?:введи\w*|вкол\w*|увелич\w*|уменьш\w*|сниз\w*|отмен\w*|измени\w*|постав\w*)[^.!?\n]{0,70}(?:инсулин|болюс|доз\w*|ICR|ISF|DIA)|(?:inject|increase|decrease|change|take|administer)[^.!?\n]{0,60}(?:insulin|dose|bolus|ICR|ISF|DIA)'
    if len(text)>14000 or re.search(dose,text,re.I) or re.search(imperative,text,re.I):raise HTTPException(502,'Ответ AI содержит недопустимую рекомендацию по дозе и не показан. Расчёт доступен в калькуляторе.')
    return insight.model_dump()
