from datetime import datetime
from math import isfinite

def validate_inputs(data: dict, now: datetime) -> list[str]:
    errors=[]
    numeric=('carbs','icr','isf','target','correct_above','dia','iob','max_bolus')
    if any(not isinstance(data.get(k),(int,float)) or not isfinite(data[k]) for k in numeric):
        return ['invalid_numeric_input']
    glucose=data.get('glucose')
    if glucose is None: errors.append('missing_glucose')
    elif not isinstance(glucose,(int,float)) or not isfinite(glucose): errors.append('invalid_glucose')
    elif glucose<3.9 or glucose>30: errors.append('extreme_glucose')
    if data.get('unit')!='mmol/L': errors.append('unit_mismatch')
    step=data.get('bolus_increment',0.1)
    if isinstance(step,bool) or not isinstance(step,(int,float)) or not isfinite(step) or step not in (0.1,0.25,0.5,1.0,2.0):errors.append('invalid_dose_step')
    if not 0<data['icr']<=200: errors.append('invalid_icr')
    if not 0<data['isf']<=30: errors.append('invalid_isf')
    if not 2<=data['dia']<=8: errors.append('invalid_dia')
    if not 0<=data['iob']<=200: errors.append('unexpected_iob')
    if not 0<=data['carbs']<=500: errors.append('invalid_carbs')
    if not 0<data['max_bolus']<=50: errors.append('invalid_max_bolus')
    if not 3.9<=data['target']<=15 or not data['target']<=data['correct_above']<=30: errors.append('invalid_target')
    try:
        age=(now-datetime.fromisoformat(data['measured_at'])).total_seconds()
        if age>900: errors.append('stale_glucose')
        if age < -60: errors.append('future_glucose')
    except (KeyError,ValueError,TypeError): errors.append('missing_glucose_time')
    return errors

def validate_result(recommendation: float, max_bolus: float) -> list[str]:
    if not isfinite(recommendation): return ['invalid_result']
    if recommendation<0: return ['negative_bolus']
    if recommendation>max_bolus: return ['max_bolus_exceeded']
    return []
