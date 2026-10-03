"""Pure deterministic engine. Never imports AI, network, persistence, or frontend code."""
from datetime import datetime
from decimal import Decimal, ROUND_FLOOR
from app.safety.validation import validate_inputs, validate_result

ALGORITHM_VERSION='bolus-v1.1.0'

def calculate(data: dict, at: datetime) -> dict:
    errors=validate_inputs(data,at)
    result={'algorithm_version':ALGORITHM_VERSION,'calculation_status':'blocked','recommended_bolus':None,'warnings':errors,'meal_bolus':0.0,'raw_correction_bolus':0.0,'correction_bolus':0.0,'iob':data.get('iob',0),'iob_adjustment':0.0,'cycle_adjustment':0.0,'personalization_adjustment':0.0}
    if errors: return result
    d=lambda key: Decimal(str(data[key]))
    meal=d('carbs')/d('icr')
    raw=(d('glucose')-d('target'))/d('isf')
    # Correct Above gates positive correction only. Below-target glucose reduces total.
    correction=raw if d('glucose')>d('correct_above') or raw<0 else Decimal('0')
    before_iob=meal+correction
    adjustment=min(d('iob'),max(Decimal('0'),before_iob))
    unrounded=max(Decimal('0'),before_iob-adjustment)
    errors=validate_result(float(unrounded),data['max_bolus'])
    # Legacy snapshots without a step preserve the original 0.1 U policy.
    increment=Decimal(str(data.get('bolus_increment',0.1)))
    rounded=(unrounded/increment).to_integral_value(rounding=ROUND_FLOOR)*increment
    result.update(meal_bolus=float(meal),raw_correction_bolus=float(raw),correction_bolus=float(correction),iob_adjustment=float(adjustment),unrounded_bolus=float(unrounded),rounding_increment=float(increment),rounding_adjustment=float(unrounded-rounded))
    if errors:
        result['warnings']=errors
        return result
    result.update(calculation_status='ok',recommended_bolus=float(rounded),warnings=['below_target'] if raw<0 else [])
    return result

def select_segment(segments: list[dict], local_time: str) -> dict:
    matches=[s for s in segments if s['start_time']<=local_time<s['end_time']]
    if len(matches)!=1: raise ValueError('Invalid therapy time coverage')
    return dict(matches[0])
