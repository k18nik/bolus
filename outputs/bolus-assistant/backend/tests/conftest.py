import os,tempfile
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='bolus-tests-'))
os.environ['DATABASE_URL']='sqlite:///'+str(root/'test.db')
os.environ['REPORT_DIR']=str(root/'reports')
os.environ['TASK_ALWAYS_EAGER']='true'
os.environ['REDIS_URL']=''
os.environ['DEMO_ENABLED']='true'
os.environ['CLINICAL_USE_ENABLED']='false'
os.environ['YAZIO_ENABLED']='false'
os.environ['USDA_API_KEY']=''
import pytest
from fastapi.testclient import TestClient
from app.db import Base,engine
from app.main import app
from app.services.security import limits

@pytest.fixture(autouse=True)
def clean_database():
    Base.metadata.drop_all(engine);Base.metadata.create_all(engine);limits.clear()
    yield

@pytest.fixture
def client():
    with TestClient(app) as client:yield client

@pytest.fixture
def demo(client):
    r=client.post('/api/auth/demo');assert r.status_code==200,r.text
    client.headers['x-csrf-token']=client.cookies['csrf']
    return client
