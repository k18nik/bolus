from datetime import datetime, date
from typing import Literal, Annotated
from zoneinfo import ZoneInfo
from pydantic import BaseModel, Field, ConfigDict, EmailStr, AwareDatetime, field_validator, model_validator
from app.services.insulins import check_insulin_type, DOSE_STEPS

class StrictModel(BaseModel):
    model_config=ConfigDict(extra='forbid',allow_inf_nan=False)
Positive=Annotated[float,Field(gt=0)]
Nonnegative=Annotated[float,Field(ge=0)]

class AuthInput(StrictModel):
    email: EmailStr
    password: str=Field(min_length=12,max_length=128)
    name: str=Field(default='Мой дневник',min_length=1,max_length=80)

class Segment(StrictModel):
    start_time: str=Field(pattern=r'^([01]\d|2[0-3]):[0-5]\d$')
    end_time: str=Field(pattern=r'^(([01]\d|2[0-3]):[0-5]\d|24:00)$')
    icr: float=Field(gt=0,le=200)
    isf: float=Field(gt=0,le=30)
    target: float=Field(ge=3.9,le=15)
    correct_above: float=Field(ge=3.9,le=30)
    @model_validator(mode='after')
    def valid(self):
        if self.end_time<=self.start_time or self.correct_above<self.target: raise ValueError('Проверьте время и порог коррекции')
        return self

class ProfileInput(StrictModel):
    diabetes_type: Literal['type1','type2','other']='type1'
    insulin_therapy_type: Literal['MDI','PUMP','OTHER']='MDI'
    rapid_insulin_name: str=Field(default='',max_length=80)
    basal_insulin_name: str=Field(default='',max_length=80)
    bolus_increment: float=1.0
    basal_increment: float=1.0
    max_bolus: float=Field(gt=0,le=50)
    insulin_action_duration: float=Field(ge=2,le=8)
    segments: list[Segment]=Field(min_length=1,max_length=24)
    confirmed: bool
    @field_validator('bolus_increment','basal_increment')
    @classmethod
    def step(cls,v):
        if v not in DOSE_STEPS: raise ValueError('Допустимый шаг: 0,1; 0,25; 0,5; 1 или 2 ЕД')
        return v
    @model_validator(mode='after')
    def coverage(self):
        check_insulin_type(self.rapid_insulin_name,'rapid')
        check_insulin_type(self.basal_insulin_name,'basal')
        ordered=sorted(self.segments,key=lambda s:s.start_time)
        if ordered[0].start_time!='00:00' or ordered[-1].end_time!='24:00' or any(a.end_time!=b.start_time for a,b in zip(ordered,ordered[1:])): raise ValueError('Профиль должен покрывать все 24 часа без пропусков')
        self.segments=ordered
        return self

class Preferences(StrictModel):
    name: str=Field(min_length=1,max_length=80)
    timezone: str
    glucose_unit: Literal['mmol/L','mg/dL']='mmol/L'
    theme_id: Literal['light','dark','cat','pink','dino','oled']='light'
    mascot_id: Literal['cat','pig','dinosaur','rabbit','otter','panda']='cat'
    @field_validator('timezone')
    @classmethod
    def tz(cls,v):
        try: ZoneInfo(v)
        except Exception: raise ValueError('Неизвестный часовой пояс')
        return v

class GlucoseInput(StrictModel):
    value: float=Field(gt=0,le=1000)
    unit: Literal['mmol/L','mg/dL']='mmol/L'
    measured_at: AwareDatetime
    source: Literal['manual','CGM','glucometer','import']='manual'
    trend: Literal['rapid_down','down','slight_down','stable','slight_up','up','rapid_up','unknown']='unknown'
    note: str=Field(default='',max_length=2000)
    client_id: str=Field(min_length=1,max_length=64)
    @model_validator(mode='after')
    def plausible(self):
        if not .5 <= self.value/(18 if self.unit=='mg/dL' else 1)<=55: raise ValueError('Значение вне допустимых границ. Проверьте единицы.')
        return self

class InsulinInput(StrictModel):
    units: float=Field(gt=0,le=200)
    insulin_type: Literal['rapid','basal']='rapid'
    insulin_name: str=Field(default='',max_length=80)
    purpose: Literal['meal','correction','meal_and_correction','basal','manual','other']='manual'
    administered_at: AwareDatetime
    note: str=Field(default='',max_length=2000)
    client_id: str=Field(min_length=1,max_length=64)
    @model_validator(mode='after')
    def consistent(self):
        check_insulin_type(self.insulin_name,self.insulin_type)
        if (self.insulin_type=='basal')!=(self.purpose=='basal'): raise ValueError('Тип инсулина и назначение должны совпадать')
        return self

class Nutrients(StrictModel):
    carbs: float=Field(ge=0,le=1000)
    protein: float=Field(default=0,ge=0,le=1000)
    fat: float=Field(default=0,ge=0,le=1000)
    calories: float=Field(default=0,ge=0,le=10000)
    fiber: float|None=Field(default=0,ge=0,le=1000)
    sugar: float|None=Field(default=0,ge=0,le=1000)

class FoodInput(Nutrients):
    base_unit: Literal['g','ml']='g'
    name: str=Field(min_length=1,max_length=150)
    brand: str=Field(default='',max_length=100)
    serving_name: str=Field(default='100 г',max_length=80)
    serving_weight: float=Field(default=100,gt=0,le=10000)
    barcode: str|None=Field(default=None,max_length=32)

class MealItem(Nutrients):
    name_snapshot: str=Field(min_length=1,max_length=150)
    food_source: str=Field(default='manual',max_length=40)
    food_id: str=Field(default='',max_length=100)
    grams: float|None=Field(default=None,gt=0,le=10000)
    amount: float=Field(gt=0,le=10000)
    unit: Literal['g','ml','serving']='g'
    @model_validator(mode='after')
    def quantity_basis(self):
        if self.unit!='ml' and self.grams is None:raise ValueError('Укажите массу продукта в граммах')
        if self.unit=='g' and self.grams!=self.amount:raise ValueError('Количество в граммах должно совпадать с массой')
        return self

class MealInput(StrictModel):
    name: str=Field(default='Приём пищи',max_length=150)
    meal_type: Literal['breakfast','lunch','dinner','snack']='lunch'
    eaten_at: AwareDatetime
    items: list[MealItem]=Field(min_length=1,max_length=100)
    note: str=Field(default='',max_length=2000)
    client_id: str=Field(min_length=1,max_length=64)

class RecipeInput(StrictModel):
    name: str=Field(min_length=1,max_length=150)
    ingredients: list[MealItem]=Field(min_length=1,max_length=100)
    cooked_weight: float=Field(gt=0,le=50000)
    servings: int=Field(ge=1,le=100)

class ActivityInput(StrictModel):
    name: str=Field(min_length=1,max_length=100)
    duration_minutes: int=Field(gt=0,le=1440)
    occurred_at: AwareDatetime
    intensity: Literal['low','moderate','high']='moderate'
    note: str=Field(default='',max_length=2000)
    client_id: str=Field(min_length=1,max_length=64)

class NoteInput(StrictModel):
    note: str=Field(min_length=1,max_length=2000)
    occurred_at: AwareDatetime
    client_id: str=Field(min_length=1,max_length=64)

class CycleInput(StrictModel):
    start_date: date
    cycle_length: int=Field(default=28,ge=15,le=90)
    end_date: date|None=None
    actual_ovulation_date: date|None=None
    @model_validator(mode='after')
    def ordered(self):
        if self.end_date and self.end_date<self.start_date: raise ValueError('Дата окончания раньше начала')
        if self.actual_ovulation_date and self.actual_ovulation_date<self.start_date: raise ValueError('Дата овуляции раньше начала')
        return self

class BolusInput(StrictModel):
    glucose: float|None=Field(default=None,gt=0,le=1000)
    unit: Literal['mmol/L','mg/dL']='mmol/L'
    carbs: float=Field(ge=0,le=500)
    timestamp: AwareDatetime
    measured_at: AwareDatetime
    meal_id: str|None=None

class ConfirmInput(StrictModel):
    actual_units: float=Field(gt=0,le=50)
    administered_at: AwareDatetime

class ReportInput(StrictModel):
    type: Literal['doctor','summary','glucose','insulin','nutrition','cycle','raw','personalization']='doctor'
    format: Literal['pdf','xlsx','csv','json']='pdf'
    date_from: date
    date_to: date
    include_graphs: bool=True
    include_nutrition: bool=True
    include_cycle: bool=True
    include_ai: bool=False
    @model_validator(mode='after')
    def period(self):
        if self.date_to<self.date_from or (self.date_to-self.date_from).days>366: raise ValueError('Выберите период до 366 дней')
        return self

class FavoriteInput(FoodInput):
    external_id: str=Field(min_length=1,max_length=100)
    provider: str=Field(min_length=1,max_length=40)

class DiaryBatchInput(StrictModel):
    client_id: str=Field(min_length=1,max_length=50)
    glucose: GlucoseInput|None=None
    meal: MealInput|None=None
    insulin: list[InsulinInput]=Field(default_factory=list,max_length=2)
    activity: ActivityInput|None=None
    note: NoteInput|None=None
    cycle: CycleInput|None=None
    @model_validator(mode='after')
    def nonempty(self):
        if not any((self.glucose,self.meal,self.insulin,self.activity,self.note,self.cycle)):
            raise ValueError('Заполните хотя бы один раздел')
        return self
