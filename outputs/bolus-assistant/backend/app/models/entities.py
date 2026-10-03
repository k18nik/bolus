import uuid
from datetime import datetime, timezone
from sqlalchemy import String, Float, Integer, Boolean, JSON, ForeignKey, UniqueConstraint, Text
from sqlalchemy.orm import Mapped, mapped_column
from app.db import Base

def uid(): return str(uuid.uuid4())
def now(): return datetime.now(timezone.utc).isoformat()

class User(Base):
    __tablename__='users'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    email: Mapped[str]=mapped_column(String(254),unique=True,index=True)
    password_hash: Mapped[str]=mapped_column(Text)
    name: Mapped[str]=mapped_column(String(80),default='Мой дневник')
    timezone: Mapped[str]=mapped_column(String(80),default='Europe/Moscow')
    locale: Mapped[str]=mapped_column(String(10),default='ru')
    glucose_unit: Mapped[str]=mapped_column(String(10),default='mmol/L')
    weight_unit: Mapped[str]=mapped_column(String(10),default='kg')
    theme_id: Mapped[str]=mapped_column(String(30),default='light')
    mascot_id: Mapped[str]=mapped_column(String(30),default='cat')
    is_demo: Mapped[bool]=mapped_column(Boolean,default=False)
    created_at: Mapped[str]=mapped_column(String,default=now)
    updated_at: Mapped[str]=mapped_column(String,default=now)

class Owned:
    user_id: Mapped[str]=mapped_column(ForeignKey('users.id',ondelete='CASCADE'),index=True)

class AuthSession(Owned, Base):
    __tablename__='sessions'
    id: Mapped[str]=mapped_column(String(64),primary_key=True)
    csrf: Mapped[str]=mapped_column(String(64))
    expires_at: Mapped[str]=mapped_column(String)

class Profile(Owned, Base):
    __tablename__='therapy_profiles'
    __table_args__=(UniqueConstraint('user_id','version'),)
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    version: Mapped[int]=mapped_column(Integer)
    valid_from: Mapped[str]=mapped_column(String,default=now)
    valid_to: Mapped[str|None]=mapped_column(String,nullable=True)
    source: Mapped[str]=mapped_column(String,default='manual')
    status: Mapped[str]=mapped_column(String,default='active')
    data: Mapped[dict]=mapped_column(JSON)

class Entry(Owned, Base):
    __tablename__='entries'
    __table_args__=(UniqueConstraint('user_id','client_id'),)
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    client_id: Mapped[str]=mapped_column(String(64))
    kind: Mapped[str]=mapped_column(String(20),index=True)
    occurred_at: Mapped[str]=mapped_column(String,index=True)
    data: Mapped[dict]=mapped_column(JSON)
    version: Mapped[int]=mapped_column(Integer,default=1)
    created_at: Mapped[str]=mapped_column(String,default=now)
    updated_at: Mapped[str]=mapped_column(String,default=now)

class Calculation(Owned, Base):
    __tablename__='bolus_calculations'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    calculated_at: Mapped[str]=mapped_column(String,default=now)
    input_snapshot: Mapped[dict]=mapped_column(JSON)
    calculation_snapshot: Mapped[dict]=mapped_column(JSON)
    actual_bolus: Mapped[float|None]=mapped_column(Float,nullable=True)
    confirmed_entry_id: Mapped[str|None]=mapped_column(String,nullable=True)
    algorithm_version: Mapped[str]=mapped_column(String)

class CustomFood(Owned, Base):
    __tablename__='custom_foods'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    name: Mapped[str]=mapped_column(String(150))
    data: Mapped[dict]=mapped_column(JSON)
    is_recipe: Mapped[bool]=mapped_column(Boolean,default=False)

class Cycle(Owned, Base):
    __tablename__='cycles'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    start_date: Mapped[str]=mapped_column(String)
    end_date: Mapped[str|None]=mapped_column(String,nullable=True)
    cycle_length: Mapped[int]=mapped_column(Integer,default=28)
    actual_ovulation_date: Mapped[str|None]=mapped_column(String,nullable=True)

class ReportJob(Owned, Base):
    __tablename__='report_jobs'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    type: Mapped[str]=mapped_column(String)
    format: Mapped[str]=mapped_column(String)
    date_from: Mapped[str]=mapped_column(String)
    date_to: Mapped[str]=mapped_column(String)
    options: Mapped[dict]=mapped_column(JSON,default=dict)
    status: Mapped[str]=mapped_column(String,default='queued')
    progress: Mapped[int]=mapped_column(Integer,default=0)
    file_path: Mapped[str|None]=mapped_column(String,nullable=True)
    created_at: Mapped[str]=mapped_column(String,default=now)
    completed_at: Mapped[str|None]=mapped_column(String,nullable=True)
    expires_at: Mapped[str|None]=mapped_column(String,nullable=True)
    error: Mapped[str|None]=mapped_column(String,nullable=True)

class AuditLog(Owned, Base):
    __tablename__='audit_logs'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    action: Mapped[str]=mapped_column(String)
    entity_type: Mapped[str]=mapped_column(String)
    entity_id: Mapped[str]=mapped_column(String)
    old_value: Mapped[dict|None]=mapped_column(JSON,nullable=True)
    new_value: Mapped[dict|None]=mapped_column(JSON,nullable=True)
    timestamp: Mapped[str]=mapped_column(String,default=now)

class FoodFavorite(Owned, Base):
    __tablename__='food_favorites'
    __table_args__=(UniqueConstraint('user_id','food_key'),)
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    food_key: Mapped[str]=mapped_column(String(160))
    data: Mapped[dict]=mapped_column(JSON)

class AISettings(Owned, Base):
    __tablename__='ai_settings'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    __table_args__=(UniqueConstraint('user_id'),)
    encrypted_key: Mapped[str|None]=mapped_column(Text,nullable=True)
    provider: Mapped[str]=mapped_column(String(20),default='openai')
    last_check: Mapped[dict|None]=mapped_column(JSON,nullable=True)
    model: Mapped[str]=mapped_column(String(100),default='gpt-4.1-mini')
    consent: Mapped[bool]=mapped_column(Boolean,default=False)
    updated_at: Mapped[str]=mapped_column(String,default=now)

class AIInsight(Owned, Base):
    __tablename__='ai_insights'
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    question: Mapped[str]=mapped_column(Text)
    response: Mapped[dict]=mapped_column(JSON)
    context: Mapped[dict]=mapped_column(JSON)
    model: Mapped[str]=mapped_column(String(100))
    provider: Mapped[str]=mapped_column(String(20),default='openai')
    usage: Mapped[dict]=mapped_column(JSON)
    calculation_id: Mapped[str|None]=mapped_column(String(36),nullable=True)
    created_at: Mapped[str]=mapped_column(String,default=now)

class DiaryBatch(Owned, Base):
    __tablename__='diary_batches'
    __table_args__=(UniqueConstraint('user_id','client_id'),)
    id: Mapped[str]=mapped_column(String(36),primary_key=True,default=uid)
    client_id: Mapped[str]=mapped_column(String(64))
    payload_hash: Mapped[str]=mapped_column(String(64))
    result: Mapped[dict]=mapped_column(JSON)
