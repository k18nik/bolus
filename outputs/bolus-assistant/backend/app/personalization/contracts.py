from pydantic import BaseModel, Field, ConfigDict
from typing import Literal
class PatternEvidence(BaseModel):
    model_config=ConfigDict(extra='forbid')
    sample_size: int=Field(ge=10)
    confidence: float=Field(ge=0,le=1)
    effect_size: float
    date_from: str
    date_to: str
    episode_type: Literal['correction','meal','fasting','exercise']
class PersonalizationCandidate(BaseModel):
    evidence: PatternEvidence
    status: Literal['proposed','rejected','accepted']='proposed'
    requires_user_confirmation: Literal[True]=True
# V2: no automatic profile writes. Candidate application is intentionally unavailable.
