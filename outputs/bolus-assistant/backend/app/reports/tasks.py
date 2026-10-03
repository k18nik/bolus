from celery import Celery
from app.config import settings
from app.reports.generator import generate_report
celery=Celery('bolus',broker=settings.redis_url or 'memory://',backend=settings.redis_url or 'cache+memory://')
celery.conf.update(task_always_eager=settings.task_always_eager,task_serializer='json',accept_content=['json'],result_serializer='json',task_time_limit=120,worker_hijack_root_logger=False)
@celery.task(name='reports.generate',ignore_result=True)
def build_report(job_id:str):generate_report(job_id)
