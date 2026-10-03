"""Deterministic linear-remaining model for a research prototype; not pharmacokinetic validation."""
from dataclasses import dataclass
from datetime import datetime
from math import isfinite
from typing import Protocol

class InsulinActionModel(Protocol):
    version: str
    def remaining(self, elapsed_hours: float, dia_hours: float) -> float: ...

class LinearActionModel:
    version='linear-remaining-v1.0.0'
    def remaining(self, elapsed_hours: float, dia_hours: float) -> float:
        if not all(isfinite(x) for x in (elapsed_hours,dia_hours)) or not 2<=dia_hours<=8:
            raise ValueError('Invalid action duration')
        if elapsed_hours < 0: return 0.0
        return max(0.0, min(1.0, 1.0-elapsed_hours/dia_hours))

@dataclass(frozen=True)
class AdministeredDose:
    units: float
    administered_at: datetime
    dia_hours: float
    insulin_type: str='rapid'

def calculate_iob(doses: list[AdministeredDose], at: datetime, model: InsulinActionModel|None=None) -> float:
    model=model or LinearActionModel()
    total=0.0
    for dose in doses:
        if dose.insulin_type=='basal': continue
        if not isfinite(dose.units) or dose.units<0: raise ValueError('Invalid actual dose')
        total += dose.units*model.remaining((at-dose.administered_at).total_seconds()/3600,dose.dia_hours)
    return total
