"""Explanation-only schema. No dosing tools or executable profile changes."""
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from typing import Literal
class InsightResponse(BaseModel):
    model_config=ConfigDict(extra='forbid')
    summary: str
    observations: list[str]
    possible_explanations: list[str]
    questions: list[str]
    safety_flags: list[str]

class AISettingsInput(BaseModel):
    model_config=ConfigDict(extra='forbid')
    provider: Literal['openai','tokenn']='openai'
    api_key: SecretStr|None=Field(default=None)
    model: str=Field(default='gpt-4.1-mini',min_length=3,max_length=100,pattern=r'^gpt-[a-zA-Z0-9._-]+$')
    consent: bool

class ChatInput(BaseModel):
    model_config=ConfigDict(extra='forbid')
    question: str=Field(min_length=1,max_length=2000)
    days: int=Field(default=14,ge=1,le=90)
    calculation_id: str|None=Field(default=None,max_length=36)
class AIContextBuilder:
    ALLOWED={'mean_glucose','tir','tbr','tar','sample_size','coverage_method','daily_insulin','basal_insulin','bolus_insulin','carbs_per_day','corrections_per_day','coefficient_of_variation','days'}
    def build(self, aggregates:dict) -> dict:
        return {k:v for k,v in aggregates.items() if k in self.ALLOWED}
# Deliberately no model tools for dosing, therapy editing, or insulin delivery.
