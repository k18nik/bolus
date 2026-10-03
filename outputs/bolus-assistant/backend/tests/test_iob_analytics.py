from datetime import datetime,timezone,timedelta
from math import nan
import pytest
from hypothesis import given,strategies as st
from app.iob.engine import LinearActionModel,AdministeredDose,calculate_iob
from app.analytics.engine import summarize,hourly_profile
from app.cycle.engine import cycle_status
AT=datetime(2026,10,2,12,tzinfo=timezone.utc)

def test_linear_boundaries():
    m=LinearActionModel()
    assert m.remaining(0,4)==1
    assert m.remaining(2,4)==.5
    assert m.remaining(4,4)==0
    assert m.remaining(8,4)==0
    assert m.remaining(-1,4)==0
    with pytest.raises(ValueError):m.remaining(0,0)
    with pytest.raises(ValueError):m.remaining(nan,4)

def test_actual_only_basal_excluded():
    doses=[AdministeredDose(4,AT-timedelta(hours=2),4),AdministeredDose(2,AT-timedelta(hours=1),4),AdministeredDose(20,AT,4,'basal')]
    assert calculate_iob(doses,AT)==3.5
    assert calculate_iob([],AT)==0
    with pytest.raises(ValueError):calculate_iob([AdministeredDose(-1,AT,4)],AT)

@given(elapsed=st.floats(min_value=0,max_value=20),dia=st.floats(min_value=2,max_value=8),units=st.floats(min_value=0,max_value=100))
def test_iob_bounds_and_monotonicity(elapsed,dia,units):
    m=LinearActionModel()
    assert 0<=m.remaining(elapsed,dia)*units<=units
    assert m.remaining(elapsed+.1,dia)<=m.remaining(elapsed,dia)

def test_analytics_known_values():
    entries=[{'kind':'glucose','occurred_at':AT.isoformat(),'data':{'value_mmol':v}} for v in [3,5,7,13]]
    entries += [{'kind':'insulin','data':{'units':4,'insulin_type':'rapid','purpose':'correction'}},{'kind':'insulin','data':{'units':12,'insulin_type':'basal','purpose':'basal'}},{'kind':'meal','data':{'total_carbs':80,'total_calories':500}}]
    m=summarize(entries,2)
    assert m['mean_glucose']==7 and m['median_glucose']==6
    assert (m['tir'],m['tbr'],m['tar'])==(50,25,25)
    assert m['daily_insulin']==8 and m['basal_insulin']==6 and m['bolus_insulin']==2
    assert m['carbs_per_day']==40 and m['corrections_per_day']==.5
    assert hourly_profile(entries,'Europe/Moscow')[0]['hour']==15
    assert summarize([],7)['mean_glucose'] is None
    assert summarize([],7)['tir'] is None

def test_cycle_no_rollover():
    start=AT.date()
    assert cycle_status(start,28,start)['phase']=='menstrual'
    assert cycle_status(start,28,start+timedelta(days=17))['phase']=='early_luteal'
    assert cycle_status(start,28,start+timedelta(days=24))['phase']=='late_luteal'
    assert cycle_status(start,28,start+timedelta(days=30))['phase']=='unknown'
