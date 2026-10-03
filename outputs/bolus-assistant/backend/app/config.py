from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field
from typing import Literal

class Settings(BaseSettings):
    database_url: str = 'sqlite:///./bolus.db'
    redis_url: str = ''
    secure_cookies: bool = False
    environment: str = 'development'
    allowed_origin: str = 'http://127.0.0.1:3000'
    report_dir: str = './report_files'
    task_always_eager: bool = True
    feature_ai: bool = False
    feature_personalization: bool = False
    feature_cycle: bool = True
    feature_barcode: bool = False
    feature_cgm: bool = False
    demo_enabled: bool = False
    clinical_use_enabled: bool = False
    openai_model: str = 'gpt-4.1-mini'
    app_encryption_key: str = ''
    yazio_enabled: bool = True
    yazio_country: str = Field(default='RU',pattern=r'^[A-Z]{2}$')
    yazio_locale: str = Field(default='ru_RU',pattern=r'^[a-z]{2}_[A-Z]{2}$')
    yazio_search_sex: Literal['male','female'] = 'male'
    usda_api_key: str = ''
    model_config = SettingsConfigDict(env_file='.env', extra='ignore')

settings = Settings()
