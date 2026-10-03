from fastapi import APIRouter,Depends,HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.db import get_db
from app.config import settings
from app.models.entities import AISettings,AIInsight,now
from app.services.security import current_user,rate_limit
from app.repositories.diary import audit
from app.ai.contracts import AISettingsInput,ChatInput
from app.ai.service import encrypt_key,require_ai,check_connection,build_context,generate_insight
from app.ai.providers import PROVIDERS

router=APIRouter(prefix='/api/ai')

@router.get('/settings')
def get_settings(user=Depends(current_user),db:Session=Depends(get_db)):
    row=db.scalar(select(AISettings).where(AISettings.user_id==user.id))
    usage=list(db.scalars(select(AIInsight.usage).where(AIInsight.user_id==user.id)))
    provider=row.provider if row else 'openai'
    return {'enabled':settings.feature_ai,'provider':provider,'provider_name':PROVIDERS[provider]['name'],'base_url':PROVIDERS[provider]['base_url'],'providers':PROVIDERS,'key_configured':bool(row and row.encrypted_key),'model':row.model if row else settings.openai_model,'consent':row.consent if row else False,'last_check':row.last_check if row else None,'requests':len(usage),'total_tokens':sum(r.get('total_tokens',0) for r in usage)}

@router.put('/settings')
def save_settings(payload:AISettingsInput,user=Depends(current_user),db:Session=Depends(get_db)):
    row=db.scalar(select(AISettings).where(AISettings.user_id==user.id))
    if row and row.provider!=payload.provider and row.encrypted_key and not payload.api_key:
        raise HTTPException(422,'При смене провайдера введите его API-ключ заново. Сохранённый ключ не отправляется другому сервису автоматически.')
    encrypted=encrypt_key(payload.api_key.get_secret_value()) if payload.api_key else None
    connection_changed=not row or row.provider!=payload.provider or row.model!=payload.model or bool(encrypted)
    if not row:row=AISettings(user_id=user.id);db.add(row)
    if encrypted:row.encrypted_key=encrypted
    row.model=payload.model;row.provider=payload.provider;row.consent=payload.consent;row.updated_at=now()
    if connection_changed:row.last_check=None
    audit(db,user.id,'ai_settings_change','ai_settings',user.id,new={'provider':row.provider,'model':row.model,'consent':row.consent,'key_updated':bool(encrypted)})
    db.commit();return get_settings(user,db)

@router.delete('/settings/key')
def forget_key(user=Depends(current_user),db:Session=Depends(get_db)):
    row=db.scalar(select(AISettings).where(AISettings.user_id==user.id))
    if row:row.encrypted_key=None;row.consent=False;row.last_check=None;db.commit()
    return {'removed':True}

@router.post('/test')
async def test_connection(user=Depends(current_user),db:Session=Depends(get_db)):
    row,key=require_ai(db,user,needs_consent=False);rate_limit('ai-test:'+user.id,10,3600)
    usage=await check_connection(key,row.model,row.provider)
    result={'connected':True,'provider':row.provider,'model':row.model,'checked_at':now(),'usage':usage}
    row.last_check=result;db.commit();return result

@router.post('/chat')
async def chat(payload:ChatInput,user=Depends(current_user),db:Session=Depends(get_db)):
    row,key=require_ai(db,user);rate_limit('ai:'+user.id,20,3600)
    context=build_context(db,user,payload.days,payload.calculation_id)
    response,usage=await generate_insight(key,row.model,payload.question,context,row.provider)
    insight=AIInsight(user_id=user.id,question=payload.question,response=response,context=context,model=row.model,provider=row.provider,usage=usage,calculation_id=payload.calculation_id)
    db.add(insight);db.flush();audit(db,user.id,'ai_insight','ai_insight',insight.id,new={'model':row.model,'total_tokens':usage['total_tokens']});db.commit()
    return insight_dict(insight)

def insight_dict(row):return {k:getattr(row,k) for k in ('id','question','response','provider','model','usage','calculation_id','created_at')}

@router.get('/history')
def history(user=Depends(current_user),db:Session=Depends(get_db)):
    return [insight_dict(row) for row in db.scalars(select(AIInsight).where(AIInsight.user_id==user.id).order_by(AIInsight.created_at.desc()).limit(30))]
