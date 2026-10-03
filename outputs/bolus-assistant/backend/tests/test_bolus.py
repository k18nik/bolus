import json,math
from pathlib import Path
from datetime import datetime,timezone,timedelta
import pytest
from hypothesis import given,settings,strategies as st
from app.bolus.engine import calculate,select_segment
from app.safety.validation import validate_result
AT=datetime(2026,10,2,12,tzinfo=timezone.utc)
def data(**kw):
    return {'glucose':10.2,'unit':'mmol/L','carbs':62,'icr':10,'isf':2,'target':6,'correct_above':7,'dia':4,'iob':.9,'max_bolus':15,'measured_at':AT.isoformat(),**kw}

@pytest.mark.parametrize('inputs,expected',[
 ({'glucose':6,'carbs':50,'iob':0},5),
 ({'glucose':10,'carbs':0,'iob':0},2),
 ({'glucose':10.2,'carbs':62,'iob':.9},7.4),
 ({'glucose':5,'carbs':50,'iob':0},4.5),
 ({'glucose':6.9,'carbs':50,'iob':0},5),
 ({'glucose':7,'carbs':0,'iob':0},0),
 ({'glucose':10,'carbs':0,'iob':8},0),
 ({'glucose':6,'carbs':0,'iob':0},0),
 ({'glucose':6,'carbs':1,'icr':3,'iob':0},.3),
])
def test_examples(inputs,expected):
    result=calculate(data(**inputs),AT)
    assert result['calculation_status']=='ok'
    assert result['recommended_bolus']==expected

@pytest.mark.parametrize('key,value,reason',[
 ('glucose',None,'missing_glucose'),('glucose',3.8,'extreme_glucose'),('glucose',30.1,'extreme_glucose'),('glucose',math.nan,'invalid_glucose'),('icr',0,'invalid_icr'),('icr',-1,'invalid_icr'),('isf',0,'invalid_isf'),('dia',1,'invalid_dia'),('iob',-1,'unexpected_iob'),('iob',201,'unexpected_iob'),('iob',math.inf,'invalid_numeric_input'),('carbs',-1,'invalid_carbs'),('max_bolus',0,'invalid_max_bolus'),('target',2,'invalid_target'),('unit','mg/dL','unit_mismatch'),('measured_at',(AT-timedelta(minutes=16)).isoformat(),'stale_glucose'),('measured_at',(AT+timedelta(minutes=2)).isoformat(),'future_glucose'),('measured_at','invalid','missing_glucose_time')
])
def test_blocked(key,value,reason):
    result=calculate(data(**{key:value}),AT)
    assert result['recommended_bolus'] is None
    assert reason in result['warnings']

def test_max_blocks_before_rounding():
    result=calculate(data(glucose=6,carbs=50.1,icr=10,iob=0,max_bolus=5),AT)
    assert result['calculation_status']=='blocked'
    assert 'max_bolus_exceeded' in result['warnings']

def test_segments():
    segments=[{'start_time':'00:00','end_time':'06:00','icr':12,'isf':2.5},{'start_time':'06:00','end_time':'24:00','icr':8,'isf':2}]
    assert select_segment(segments,'05:59')['icr']==12
    assert select_segment(segments,'06:00')['icr']==8
    assert select_segment(segments,'23:59')['isf']==2
    with pytest.raises(ValueError):select_segment([], '08:00')

def test_golden():
    cases=json.loads((Path(__file__).parent/'golden/bolus_cases.json').read_text())
    assert len(cases)>=100
    for case in cases:
        result=calculate(data(**case['input']),AT)
        assert result['calculation_status']==case['expected_status'],case['id']
        assert result['recommended_bolus']==case['expected_bolus'],case['id']

@given(glucose=st.floats(min_value=3.9,max_value=30),carbs=st.floats(min_value=0,max_value=500),icr=st.floats(min_value=.1,max_value=100),isf=st.floats(min_value=.1,max_value=20),iob=st.floats(min_value=0,max_value=200),maximum=st.floats(min_value=.1,max_value=50))
@settings(max_examples=350)
def test_properties(glucose,carbs,icr,isf,iob,maximum):
    r=calculate(data(glucose=glucose,carbs=carbs,icr=icr,isf=isf,iob=iob,max_bolus=maximum),AT)
    if r['calculation_status']=='ok':
        assert math.isfinite(r['recommended_bolus'])
        assert 0<=r['recommended_bolus']<=maximum
    else:assert r['recommended_bolus'] is None

def test_result_guards():
    assert validate_result(math.nan,10)==['invalid_result']
    assert validate_result(-1,10)==['negative_bolus']
